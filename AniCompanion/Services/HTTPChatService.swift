import Foundation
import Combine

/// Chat transport for any **OpenAI-compatible** HTTP gateway
/// (`POST /v1/chat/completions`, `stream: true`). [Hermes Agent](https://github.com/NousResearch/hermes-agent)
/// is the reference backend, but the same code drives Ollama, LM Studio, vLLM, OpenRouter,
/// etc. — only `serviceName` (for error text) and `healthCheckPath` differ between them.
///
/// Unlike the legacy WebSocket gateway, this is request/response: each `.chat` send
/// opens its own streaming HTTP request, parses the Server-Sent Events, and yields the
/// same `WSIncoming` events the pipeline already understands:
/// - each `chat.completion.chunk` delta → `.token(ref:, content:, source: "chat")`
/// - the `data: [DONE]` sentinel (or stream end) → `.done(ref:, source: "chat")`
/// - non-200 / transport failure → `.error(ref:, message:)`
///
/// There is no persistent socket, heartbeat, or reconnect loop. `connect()` probes
/// `GET {healthCheckPath}` (Hermes: `/health`, requiring a 200) so the UI's connection
/// indicator is honest; gateways without a health route pass `healthCheckPath: nil`, and
/// `connect()` falls back to a lenient base-URL reachability check. Server-pushed
/// notifications (the legacy `notify` event) have no HTTP equivalent yet.
@MainActor
final class HTTPChatService: ObservableObject, ChatTransport {

    // MARK: - Published State

    @Published private(set) var connectionState: WSConnectionState = .disconnected

    var connectionStatePublisher: AnyPublisher<WSConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    // MARK: - Public Stream

    let events: AsyncStream<WSIncoming>
    private let eventsContinuation: AsyncStream<WSIncoming>.Continuation

    // MARK: - Configuration

    /// Base URL of the gateway, e.g. `http://127.0.0.1:8642` (no trailing slash). The
    /// transport appends `/v1/chat/completions` to it.
    private let baseURL: String
    /// Bearer token (for Hermes, its `API_SERVER_KEY`). Empty string = unauthenticated.
    private let apiKey: String
    /// Model name sent with each request. Some gateways pick the model server-side and ignore it.
    private let model: String
    /// Gateway name used in user-facing error messages ("Hermes", "OpenAI-compatible", …).
    private let serviceName: String
    /// Health-probe path (e.g. `/health`) requiring a 200, or `nil` for a lenient base-URL
    /// reachability check when the gateway has no health route.
    private let healthCheckPath: String?
    private let session: URLSession

    // MARK: - Private State

    /// In-flight streaming requests keyed by chat ref, so `.cancel` can stop one.
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var healthTask: Task<Void, Never>?
    /// Polling task for backend-pushed notifications (see "Notification Polling" below).
    private var notificationPollTask: Task<Void, Never>?
    /// Flipped to false on a 404 from `/v1/notifications` — plain OpenAI-compatible gateways
    /// (Ollama, LM Studio, …) don't offer a push channel, so we stop asking them.
    private var notificationsSupported = true

    // MARK: - Initialization

    init(
        endpoint: String,
        apiKey: String,
        model: String = "hermes-agent",
        serviceName: String = "Hermes",
        healthCheckPath: String? = "/health"
    ) {
        self.baseURL = Self.normalizeBaseURL(endpoint)
        self.apiKey = apiKey
        self.model = model
        self.serviceName = serviceName
        self.healthCheckPath = healthCheckPath

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        let (stream, continuation) = AsyncStream<WSIncoming>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - ChatTransport

    func connect() {
        guard connectionState != .connected else { return }
        connectionState = .connecting
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            await self?.checkHealth()
        }
        startNotificationPolling()
    }

    func disconnect() {
        healthTask?.cancel()
        healthTask = nil
        stopNotificationPolling()
        stopRealtime()
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        connectionState = .disconnected
    }

    func send(_ message: WSOutgoing) async throws {
        switch message {
        case .chat(let id, let messages, let images, let skills):
            startChat(ref: id, messages: messages, images: images, skills: skills)
        case .cancel(let ref):
            activeTasks[ref]?.cancel()
            activeTasks[ref] = nil
        case .ack:
            // No server-push to acknowledge over HTTP. No-op.
            break
        }
    }

    func cancelLookup() {
        guard let url = URL(string: baseURL + "/api/lookup/cancel") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Notification Polling (backend push channel)
    //
    // The pipeline has a dormant `notify` path (`ConversationController.handleNotification`)
    // reserved for server-pushed messages. Backends that implement `GET /v1/notifications`
    // (e.g. companion-layer) can enqueue "she should say this now" messages; we poll for
    // them and emit `.notify` → `.token` → `.done` so they ride the normal TTS + playback
    // pipeline (skipped while the user is mid-chat, acked after playback). A 404 from a
    // plain OpenAI-compatible gateway disables polling for the lifetime of this transport.

    private static let notificationPollInterval: TimeInterval = 3

    private struct NotificationMessage: Codable {
        let id: String
        let text: String
        /// Optional body-animation clip the companion layer plays alongside the line
        /// (missing clips are dropped client-side, see AnimationDirector).
        let animation: String?
    }

    private struct NotificationsResponse: Codable {
        let notifications: [NotificationMessage]
        /// Poll fallback for the WS `status` frames: her in-flight lookup, nil when idle.
        let activeLookup: String?
    }

    /// Notify-pipeline entry shared by the 3s poll and the realtime WebSocket: each
    /// backend message rides `.notify` → `.token` → `.done` so it plays through the
    /// normal TTS + lip-sync + bubble path (ConversationController.handleNotification).
    /// A body-animation clip riding along fires `onSayAnimation` first — she moves, then speaks.
    private func emitNotification(id: String, text: String, animation: String? = nil) {
        if let animation, !animation.isEmpty {
            onSayAnimation?(animation)
        }
        let ref = "notif-\(id)"
        eventsContinuation.yield(.notify(ref: ref, source: "chat"))
        eventsContinuation.yield(.token(ref: ref, content: text, source: "chat"))
        eventsContinuation.yield(.done(ref: ref, source: "chat"))
    }

    /// Fires the animation clip attached to a backend-pushed say line (companion-layer
    /// touch/reaction reactions). Wired by `AppState` to the AnimationDirector.
    var onSayAnimation: ((String) -> Void)?

    /// Lookup-task status (WS `status` frames + poll fallback): non-nil text = an
    /// in-flight (or failed) background lookup she promised; nil = finished. Drives the
    /// persistent indicator above the input.
    var onLookupStatus: ((String?) -> Void)?

    private func startNotificationPolling() {
        guard notificationPollTask == nil, notificationsSupported else { return }
        notificationPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNotifications()
                try? await Task.sleep(for: .seconds(Self.notificationPollInterval))
            }
        }
    }

    private func stopNotificationPolling() {
        notificationPollTask?.cancel()
        notificationPollTask = nil
    }

    private func pollNotifications() async {
        guard let url = URL(string: baseURL + "/v1/notifications") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(NotificationsResponse.self, from: data)
                for message in decoded.notifications {
                    emitNotification(id: message.id, text: message.text, animation: message.animation)
                }
                // Poll fallback for lookup status (WS `status` frames when connected)
                onLookupStatus?(decoded.activeLookup)
                // companion-layer 广告实时能力 → 升级 WebSocket 长连（纯网关无此头，永不触发）
                upgradeToRealtimeIfAdvertised(http)
            case 404:
                notificationsSupported = false
                stopNotificationPolling()
            default:
                break // transient error — keep polling
            }
        } catch {
            // Network failure — keep polling while the app runs.
        }
    }

    // MARK: - Realtime WebSocket (companion-layer push channel)
    //
    // When the poll response advertises `X-Companion-Realtime: 1`, we open a persistent
    // WebSocket at `/v1/ws`: `{type:"say"}` frames arrive in <500ms instead of the 3s poll
    // cadence and ride the same emitNotification path. If the socket drops we fall back to
    // polling while retrying the socket with exponential backoff — she never goes quiet
    // just because the upgrade channel hiccuped.

    private var webSocketTask: URLSessionWebSocketTask?
    private var realtimeReconnectTask: Task<Void, Never>?
    private var realtimeSupported = false
    private var realtimeFailCount = 0

    /// Server commands (`{type:"command", action, payload}`) surface here. P4 wires this to
    /// e.g. model hot-swap; while nil the frames are just logged.
    var onServerCommand: ((String, [String: Any]?) -> Void)?

    private func upgradeToRealtimeIfAdvertised(_ http: HTTPURLResponse) {
        let advertised = (http.value(forHTTPHeaderField: "X-Companion-Realtime") ?? "") != ""
        guard advertised, !realtimeSupported else { return }
        realtimeSupported = true
        connectRealtime()
    }

    private func realtimeURL() -> URL? {
        var s = baseURL
        if s.hasPrefix("https://") { s = "wss" + s.dropFirst("https".count) }
        else if s.hasPrefix("http://") { s = "ws" + s.dropFirst("http".count) }
        return URL(string: s + "/v1/ws")
    }

    private func connectRealtime() {
        guard realtimeSupported, webSocketTask == nil, let url = realtimeURL() else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        // URLSessionWebSocketTask has no open-event without a session delegate; a ping
        // round-trip is the handshake probe — success stops the poll, failure backs off.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.webSocketTask === task else { return }
                if error == nil { self.onRealtimeConnected() } else { self.onRealtimeDisconnected() }
            }
        }
    }

    private func onRealtimeConnected() {
        realtimeFailCount = 0
        stopNotificationPolling() // WebSocket takes over the push channel
        receiveRealtimeLoop()
    }

    private func onRealtimeDisconnected() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        realtimeFailCount += 1
        startNotificationPolling() // fall back while the socket is down
        scheduleRealtimeReconnect()
    }

    private func scheduleRealtimeReconnect() {
        guard realtimeReconnectTask == nil else { return }
        // 2s → 4s → 8s → … capped at 30s; reset on successful connect
        let delay = min(30.0, pow(2.0, Double(realtimeFailCount)))
        realtimeReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.realtimeReconnectTask = nil }
            await MainActor.run { self?.connectRealtime() }
        }
    }

    private func receiveRealtimeLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handleRealtimeText(text) }
                    self.receiveRealtimeLoop()
                case .failure:
                    self.onRealtimeDisconnected()
                }
            }
        }
    }

    private func handleRealtimeText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "say":
            let id = object["id"] as? String ?? UUID().uuidString
            guard let content = object["text"] as? String, !content.isEmpty else { return }
            emitNotification(id: id, text: content, animation: object["animation"] as? String)
        case "status":
            // 代查任务状态（[lookup] 二段）：text 非 nil = 进行中/失败文案，nil = 结束
            if object["status"] as? String == "lookup" {
                let text = object["text"] as? String
                onLookupStatus?(text)
            }
        case "command":
            let action = object["action"] as? String ?? ""
            let payload = object["payload"] as? [String: Any]
            if let onServerCommand {
                onServerCommand(action, payload)
            } else {
                Log.pipeline("[realtime] command \(action) received (no handler wired)")
            }
        default:
            break // unknown / ack — nothing to do at this protocol version
        }
    }

    private func stopRealtime() {
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Touch Reporting (companion-layer /api/touch)

    /// Report a touch interaction (part = "head" | "body"): the companion layer replies with a
    /// persona line pushed back over the poll/WebSocket channel. Fire-and-forget — a failed
    /// report (or a plain gateway without the endpoint) must never disturb the app. Gated on
    /// `notificationsSupported` so we only talk to backends that are actually companion-layer.
    func reportTouch(_ part: String) {
        guard notificationsSupported, let url = URL(string: baseURL + "/api/touch") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["part": part])
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Health

    private func checkHealth() async {
        // With a known health route (Hermes: /health) we require a 200. Gateways without
        // one probe the base URL and accept *any* HTTP answer as "reachable" — a server
        // that responds at all is up, even if the base path 404s.
        let lenient = (healthCheckPath == nil)
        guard let url = URL(string: baseURL + (healthCheckPath ?? "")) else {
            connectionState = .disconnected
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, lenient || http.statusCode == 200 {
                connectionState = .connected
            } else {
                connectionState = .disconnected
            }
        } catch {
            if !Task.isCancelled { connectionState = .disconnected }
        }
    }

    // MARK: - Streaming Chat

    private func startChat(ref: String, messages: [[String: String]], images: [Data], skills: [[String: String]]) {
        // Replace any prior request reusing this ref.
        activeTasks[ref]?.cancel()
        let task = Task { [weak self] in
            await self?.streamChat(ref: ref, messages: messages, images: images, skills: skills)
            self?.activeTasks[ref] = nil
        }
        activeTasks[ref] = task
    }

    private func streamChat(ref: String, messages: [[String: String]], images: [Data], skills: [[String: String]]) async {
        guard let url = URL(string: baseURL + "/v1/chat/completions") else {
            eventsContinuation.yield(.error(ref: ref, message: "Invalid \(serviceName) endpoint URL: \(baseURL)"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["model": model, "messages": Self.encodeMessages(messages, images: images), "stream": true]
        if !skills.isEmpty {
            body["skills"] = skills  // / 技能面板选中项，网关拼进人格 system（不落库）
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            eventsContinuation.yield(.error(ref: ref, message: "Failed to encode chat request: \(error.localizedDescription)"))
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                connectionState = .disconnected
                eventsContinuation.yield(.error(ref: ref, message: "No HTTP response from \(serviceName)."))
                return
            }
            guard http.statusCode == 200 else {
                let message: String
                switch http.statusCode {
                case 401, 403:
                    message = "\(serviceName) rejected the API key (HTTP \(http.statusCode)). Check the API Key in Settings."
                default:
                    message = "\(serviceName) returned HTTP \(http.statusCode)."
                }
                eventsContinuation.yield(.error(ref: ref, message: message))
                return
            }

            // 200 + bytes flowing → the gateway is reachable.
            connectionState = .connected

            for try await line in bytes.lines {
                if Task.isCancelled { return }

                // SSE wire format is OpenAI-standard: `data: {json}` lines separated by
                // blank lines. (Hermes' docs mention `event:` lines, but the live server
                // emits plain `data:` lines.) Ignore everything that isn't a data line.
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty { continue }
                if payload == "[DONE]" {
                    eventsContinuation.yield(.done(ref: ref, source: "chat"))
                    return
                }
                if let content = Self.parseDeltaContent(payload) {
                    eventsContinuation.yield(.token(ref: ref, content: content, source: "chat"))
                } else if let reasoning = Self.parseDeltaReasoning(payload) {
                    eventsContinuation.yield(.reasoning(ref: ref, content: reasoning))
                }
            }

            // Stream ended without an explicit [DONE]; treat as complete.
            eventsContinuation.yield(.done(ref: ref, source: "chat"))

        } catch is CancellationError {
            // Cancelled via `.cancel(ref:)` — the controller drives its own teardown.
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            connectionState = .disconnected
            eventsContinuation.yield(.error(ref: ref, message: error.localizedDescription))
        }
    }

    // MARK: - Parsing

    /// Extracts `choices[0].delta.content` from a chunk JSON, or nil for role-only /
    /// finish chunks that carry no text.
    private static func parseDeltaContent(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Extracts `choices[0].delta.reasoning_content` (the model's thinking stream,
    /// DeepSeek-style convention emitted by companion-layer's claude-code brain).
    private static func parseDeltaReasoning(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let reasoning = delta["reasoning_content"] as? String,
              !reasoning.isEmpty else {
            return nil
        }
        return reasoning
    }

    /// Produce the JSON-ready `messages` array. Without images this is the plain text path
    /// (each message keeps its `String` content). With images, the **final user message**'s content
    /// becomes an OpenAI content-parts array — the original text plus one `image_url` part per frame
    /// (`data:image/jpeg;base64,…`) — which vision-capable models understand and text-only models
    /// reject with a clear error.
    private static func encodeMessages(_ messages: [[String: String]], images: [Data]) -> [[String: Any]] {
        var result: [[String: Any]] = messages.map { $0 as [String: Any] }
        guard !images.isEmpty,
              let idx = result.lastIndex(where: { ($0["role"] as? String) == "user" }) else {
            return result
        }

        var parts: [[String: Any]] = []
        if let text = result[idx]["content"] as? String, !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for data in images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]
            ])
        }
        result[idx]["content"] = parts
        return result
    }

    /// Trims a trailing slash so we can append `/v1/chat/completions` cleanly.
    private static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
