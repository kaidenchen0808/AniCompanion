import SwiftUI

// MARK: - ChatView

/// A chat interface displaying the conversation history with a text input bar at the bottom.
///
/// User messages appear right-aligned in blue bubbles; assistant messages appear
/// left-aligned in gray bubbles. Includes a text input field, send button, and
/// microphone button for voice input. Auto-scrolls to the latest message.
struct ChatView: View {

    @ObservedObject var conversationController: ConversationController
    @ObservedObject var conversationHistory: ConversationHistory

    /// The current text input value.
    @State private var inputText: String = ""

    /// Focus state for the text input field.
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Message List

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Top-of-list sentinel: appearing (i.e. scrolled to the very top) pages
                        // older history in. No-op when there is nothing older.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { loadOlderIfNeeded(proxy: scrollProxy) }

                        let visibleMessages = conversationHistory.messages.filter { $0.role != .system && !$0.isHidden }
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(
                                visibleMessages[index - 1].timestamp, inSameDayAs: message.timestamp
                            ) {
                                DaySeparator(date: message.timestamp)
                            }
                            MessageBubbleView(
                                message: message,
                                isLastAssistant: message.role == .assistant && message.id == visibleMessages.last?.id,
                                onRegenerate: { Task { await conversationController.regenerate() } },
                                onDelete: { conversationHistory.removeById(message.id) }
                            )
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        // Streaming text or typing indicator (single view type for LazyVStack stability).
                        // Gated on `isStreaming` (not `isProcessing`) so the indicator disappears
                        // as soon as the response text is committed, rather than lingering through
                        // TTS playback while 小光 is still speaking.
                        if conversationController.isStreaming {
                            AssistantProcessingView(
                                streamingText: conversationController.streamingText,
                                thinkingText: conversationController.thinkingText
                            )
                            .id("typing-indicator")
                        }
                    }
                    // Entrance animation on NEW messages only (last-id keyed — top-paging
                    // prepends and mid-list deletions deliberately don't animate).
                    .animation(.easeOut(duration: 0.18), value: conversationHistory.messages.last?.id)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                // Bottom-scroll on NEW messages only (append changes the last id); prepending
                // older history or mid-list deletion must not yank the viewport.
                .onChange(of: conversationHistory.messages.last?.id) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
                .onChange(of: conversationController.isProcessing) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
                .onChange(of: conversationController.streamingText) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
            }

            // MARK: - Error Banner

            if let error = conversationController.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        conversationController.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // MARK: - Input Bar

            HStack(spacing: 8) {
                // Microphone button (push-to-talk). Disabled in full-duplex mode: there, the VPIO
                // engine owns the mic while she speaks, so opening STTService's engine here would
                // grab the same input device twice. In full-duplex you interrupt by just talking.
                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: conversationController.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(conversationController.isListening ? .red : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(conversationController.fullDuplexEnabled)
                .help(conversationController.fullDuplexEnabled
                    ? "Voice interruption is on — just talk to interrupt her"
                    : (conversationController.isListening
                        ? "Stop listening"
                        : (conversationController.isSpeaking ? "Interrupt & speak" : "Start voice input")))

                // Multi-line input field: auto-grows 1–6 lines (scrolls beyond),
                // Enter sends / Shift+Enter inserts a newline.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $inputText)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: inputEditorHeight)
                        .frame(maxHeight: 132, alignment: .topLeading)

                    if inputText.isEmpty {
                        Text("Type a message...")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 0)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .focused($isInputFocused)
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return (and any other modifier combo) falls through to a newline;
                    // bare Return sends. Note: IME candidate confirmation also lands here —
                    // if that proves annoying in practice, drop this and keep button-send.
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    sendMessage()
                    return .handled
                }

                // Send / Stop button
                if conversationController.isStreaming {
                    Button {
                        conversationController.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? .blue : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send message")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
        .background(Color.clear)
        .onAppear {
            isInputFocused = true
        }
    }

    // MARK: - Helpers

    /// Whether the send button should be enabled.
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Auto-grow height for the input editor: text height measured at a conservative
    /// width (real lines never get clipped — an underestimate just leaves slack),
    /// clamped to the single-line … 6-line band; beyond that the editor scrolls inside.
    private var inputEditorHeight: CGFloat {
        let attributed = NSAttributedString(
            string: inputText.isEmpty ? " " : inputText + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let bounds = attributed.boundingRect(
            with: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return min(max(bounds.height + 16, 36), 132)
    }

    /// Send the current input text as a message.
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        Task {
            await conversationController.sendMessage(text)
        }
    }

    /// Toggle voice input on or off.
    private func toggleVoiceInput() {
        if conversationController.isListening {
            conversationController.stopVoiceInput()
        } else {
            Task {
                await conversationController.startVoiceInput()
            }
        }
    }

    /// Scroll to the bottom of the message list.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if conversationController.isStreaming {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let lastMessage = conversationHistory.messages.last(where: { $0.role != .system && !$0.isHidden }) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    /// Page older history in at the top, anchored to the previous oldest message so the
    /// viewport stays put (no jump to bottom — the last-id onChange deliberately skips prepends).
    private func loadOlderIfNeeded(proxy: ScrollViewProxy) {
        guard let anchorId = conversationHistory.messages.first?.id else { return }
        guard conversationHistory.loadOlder(limit: 100) else { return }
        proxy.scrollTo(anchorId, anchor: .top)
    }
}

// MARK: - Day Separator

/// "Today" / "Yesterday" / date divider between chat days (Doubao-style).
private struct DaySeparator: View {

    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.06))
            )
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - MessageBubbleView

/// A single chat message displayed as a rounded bubble.
///
/// User messages are right-aligned with a blue background; assistant messages
/// are left-aligned with a dark gray background.
private struct MessageBubbleView: View {

    let message: ChatMessage
    /// Regeneration is offered only on the very last assistant message.
    var isLastAssistant: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            // Role icon
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser, let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingPanel(text: thinking, isThinking: false)
                }

                if isUser {
                    Text(message.displayContent)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.blue.opacity(0.6))
                        )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownView(text: message.displayContent)

                        // Local file paths found in the reply → file cards (Quick Look on tap).
                        // Image paths are skipped here — they render inline via the markdown
                        // image pipeline when she formats them as ![](path).
                        let cards = FilePathDetector.matches(in: message.displayContent)
                            .filter { !isImagePath($0.absolute) }
                        if !cards.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(cards, id: \.raw) { FileCardView(match: $0) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
                }

                HStack(spacing: 8) {
                    if !isUser && hovering {
                        // Hover action bar (Doubao-style): copy + regenerate
                        HStack(spacing: 4) {
                            hoverButton(
                                icon: copied ? "checkmark" : "doc.on.doc",
                                help: copied ? "Copied" : "Copy",
                                action: copyMessage
                            )
                            if isLastAssistant {
                                hoverButton(
                                    icon: "arrow.clockwise",
                                    help: "Regenerate",
                                    action: { onRegenerate?() }
                                )
                            }
                        }
                        .transition(.opacity)
                    }

                    Text(formattedTimestamp)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .contextMenu {
                Button {
                    copyMessage()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if isLastAssistant {
                    Button {
                        onRegenerate?()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            // User icon
            if isUser {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .onHover { hovering = $0 }
    }

    /// Image extensions render via the markdown image pipeline, not as file cards.
    private func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// Small ghost icon button for the hover action bar.
    private func hoverButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Copy the tag-stripped Markdown source to the pasteboard.
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.displayContent, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    /// Format the message timestamp for display.
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - AssistantProcessingView

/// Combined view that shows either animated typing dots (waiting for first token)
/// or live streaming text. Uses a single view type so LazyVStack identity stays stable.
private struct AssistantProcessingView: View {

    let streamingText: String
    /// Live reasoning stream — shown in an expandable panel ABOVE the bubble (thinking
    /// arrives before the reply text; the dots stay visible while only thinking exists).
    var thinkingText: String = ""

    @State private var animating = false

    private var cleanedText: String {
        ConversationController.stripEmotionTags(from: streamingText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.purple.opacity(0.8))
                .frame(width: 24, height: 24)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                if !thinkingText.isEmpty {
                    ThinkingPanel(text: thinkingText, isThinking: true)
                }

                if cleanedText.isEmpty {
                    // Typing dots — waiting for first token
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .offset(y: animating ? -4 : 0)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                        .repeatForever()
                                        .delay(Double(index) * 0.15),
                                    value: animating
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
                } else {
                    // Live streaming text + blinking tail cursor
                    VStack(alignment: .trailing, spacing: 2) {
                        MarkdownView(text: cleanedText, textSelectionEnabled: false)
                        StreamingCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
                }
            }

            Spacer(minLength: 40)
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Thinking Panel

/// Collapsible reasoning panel (Doubao-style). Live: "思考中…" expanded with a pulsing
/// brain icon; settled on a message: "思考过程" collapsed by default.
private struct ThinkingPanel: View {

    let text: String
    var isThinking: Bool

    @State private var expanded: Bool
    @State private var pulsing = false

    init(text: String, isThinking: Bool) {
        self.text = text
        self.isThinking = isThinking
        // Live panels start expanded (watch her think in real time); committed ones collapsed.
        _expanded = State(initialValue: isThinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple.opacity(pulsing ? 0.9 : 0.45))
                    Text(isThinking ? "思考中…" : "思考过程")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .onAppear {
            guard isThinking else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Streaming Cursor

/// Blinking caret shown at the tail of the streaming bubble (Doubao-style "still typing").
private struct StreamingCursor: View {

    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.85))
            .frame(width: 2, height: 14)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Preview

#Preview {
    let history = ConversationHistory()
    let ws = ChatBackend.hermes.makeTransport(
        BackendConfig(endpoint: ChatBackend.hermes.defaultEndpoint, apiKey: "", model: ChatBackend.hermes.defaultModel)
    )
    let controller = ConversationController(
        chatTransport: ws,
        ttsService: MockTTSService(),
        audioPlayer: AudioPlayerService(),
        history: history
    )

    ChatView(
        conversationController: controller,
        conversationHistory: history
    )
    .frame(width: 360, height: 600)
    .preferredColorScheme(.dark)
}

// MARK: - Mock Services for Preview

private final class MockTTSService: TTSServiceProtocol, Sendable {
    let apiKey: String = ""
    let groupID: String = ""
    let voiceID: String = ""

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
