import Foundation
import Combine
import WebKit

// MARK: - ThreeVRMCharacterManager

/// Bridges Swift commands to a three-vrm WebGL scene running in a WKWebView.
///
/// Implements `CharacterControllerProtocol` so the conversation pipeline can drive
/// expressions, lip sync, and skeletal animations.
/// All rendering happens in JavaScript; this class only sends commands and receives events.
@MainActor
final class ThreeVRMCharacterManager: NSObject, ObservableObject, CharacterControllerProtocol {

    // MARK: - Published State

    /// Whether a VRM model has been loaded and is ready for rendering.
    @Published private(set) var isModelLoaded: Bool = false

    /// The current emotion being displayed.
    @Published private(set) var currentEmotion: Emotion = .neutral

    /// Current mouth-open value (0.0-1.0) for debug display.
    @Published private(set) var mouthOpenValue: Float = 0.0

    /// Name of the currently playing animation clip (for debug overlay).
    @Published private(set) var currentClipName: String?

    // MARK: - WebView

    /// The WKWebView instance, set by ThreeVRMRenderView after creation.
    var webView: WKWebView?

    /// Whether the three-vrm HTML/JS scene has finished loading.
    private var isWebViewReady = false

    /// Whether Desktop Pet mode is active. Gates the speech bubble (set by `AppDelegate`),
    /// so `setSpeechText` only renders the bubble when she's living on the desktop.
    var petModeActive: Bool = false

    /// The user touched her 3D body (JS `postBridge('touch')`): part is "head" (pat) or
    /// "body" (poke). Wired by `AppState` to the transport's touch reporting.
    var onTouch: ((String) -> Void)?

    // MARK: - Animation Data

    /// Raw JSON data for each animation clip, keyed by name.
    /// Loaded from the bundle once at model load time; sent to JS on demand.
    private var animationClipData: [String: Data] = [:]

    /// Track which blend shape names were active for the previous emotion.
    private var activeEmotionNames: [String] = []

    // MARK: - Inactivity Timer

    /// Seconds of inactivity before auto-playing the idle animation clip.
    private static let inactivityTimeout: TimeInterval = 10.0

    /// Timer that fires after inactivity timeout.
    private var inactivityTimer: Timer?

    /// Reset the inactivity timer. Called on every interaction.
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: Self.inactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onInactivityTimeout()
            }
        }
    }

    /// Called when the inactivity timer fires.
    private func onInactivityTimeout() {
        guard isModelLoaded else { return }
        // Only auto-play idle if nothing is currently playing
        guard currentClipName == nil else { return }
        // AnimationDirector may offer an idle variant (stretch, arms crossed, …);
        // nil (all on cooldown / missing clips) falls back to the plain idle.
        let variant = idleVariantProvider?()
        Log.character("[ThreeVRM] Inactivity timeout — playing \(variant ?? "idle")")
        playAnimation(named: variant ?? "idle")
    }

    /// Names of the animation clips loaded from Resources/Animations/ (for the
    /// AnimationDirector's existence checks and silent degradation).
    var availableAnimations: Set<String> { Set(animationClipData.keys) }

    /// Supplies an idle-variant clip name on inactivity timeouts (AnimationDirector;
    /// nil = play the plain `idle`). Set by `AppState`.
    var idleVariantProvider: (() -> String?)?

    // MARK: - Lip Sync

    private static let smoothingFactor: Float = 0.3
    private static let silenceThreshold: Float = 0.05
    private static let amplitudeScale: Float = 2.0
    private var previousSmoothedMouth: Float = 0.0

    // MARK: - Model Loading

    /// Load a VRM model. Finds the VRM file in the bundle and tells JS to load it.
    /// Also preloads animation clip JSON data from the Animations folder.
    func loadModel(named filename: String) {
        Log.character("[ThreeVRM] Loading model: \(filename)")
        isModelLoaded = false

        // Preload animation clip data from the bundle.
        preloadAnimationData()

        // Store the filename for initial WebView startup and later settings changes.
        pendingModelFilename = filename
        loadPendingModelIfPossible()
    }

    /// The filename to load once the webView is ready.
    private var pendingModelFilename: String?

    /// Called by ThreeVRMRenderView once the HTML page has finished loading.
    func onWebViewReady() {
        isWebViewReady = true
        loadPendingModelIfPossible()
    }

    private func loadPendingModelIfPossible() {
        guard isWebViewReady else { return }
        guard webView != nil else { return }
        guard let filename = pendingModelFilename else { return }

        // Resolve the model across the bundle + user-writable directory, then load it over the
        // custom vrm:// scheme (served by VRMURLSchemeHandler) so location doesn't matter.
        guard VRMModelStore.shared.resolve(filename: filename) != nil else {
            Log.character("[ThreeVRM] Model file not found (bundle or user dir): \(filename)")
            return
        }

        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let urlString = "\(VRMURLSchemeHandler.scheme)://model/\(encoded)"
        let js = "window.loadVRM('\(urlString)');"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] JS loadVRM error: \(error)")
            }
        }
    }

    // MARK: - Animation Data Preloading

    private func preloadAnimationData() {
        guard let animationsURL = Bundle.main.url(
            forResource: "Animations",
            withExtension: nil
        ) else {
            Log.character("[ThreeVRM] Animations folder not found in bundle")
            return
        }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: animationsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            for fileURL in fileURLs {
                let data = try Data(contentsOf: fileURL)
                let name = fileURL.deletingPathExtension().lastPathComponent
                animationClipData[name] = data
            }
        } catch {
            Log.character("[ThreeVRM] Failed to load animation data: \(error)")
        }

        Log.character("[ThreeVRM] Preloaded \(animationClipData.count) animation clip(s)")
    }

    // MARK: - CharacterControllerProtocol

    func setExpression(_ emotion: Emotion, blendDuration: TimeInterval) {
        resetInactivityTimer()
        currentEmotion = emotion

        // Build expression mappings from the Emotion's blend shape names.
        let mappings = emotion.threeVRMExpressionMappings

        // JSON-encode and send to JS.
        guard let data = try? JSONSerialization.data(withJSONObject: mappings),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let js = "window.setExpression(\(jsonString));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] setExpression error: \(error)")
            }
        }
    }

    func setMouthOpen(_ value: Float) {
        // Apply EMA smoothing.
        let thresholded = value < Self.silenceThreshold ? 0.0 : value
        let scaled = thresholded * Self.amplitudeScale
        let smoothed = previousSmoothedMouth * Self.smoothingFactor
                     + scaled * (1.0 - Self.smoothingFactor)
        previousSmoothedMouth = smoothed
        let clamped = min(max(smoothed, 0.0), 1.0)
        mouthOpenValue = clamped

        let js = "window.setMouthOpen(\(clamped));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func setSpeechText(_ text: String?) {
        guard petModeActive else { return }   // bubble only shows on the desktop pet
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // JSON-encode (in an array, for safe escaping) and pass the element to JS.
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.showBubble && window.showBubble(\(json)[0]);", completionHandler: nil)
        } else {
            webView?.evaluateJavaScript("window.hideBubble && window.hideBubble();", completionHandler: nil)
        }
    }

    func playIdleAnimation() {
        previousSmoothedMouth = 0.0
        mouthOpenValue = 0.0
        currentClipName = nil

        let js = "window.playIdleAnimation();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func playAnimation(named name: String) {
        resetInactivityTimer()
        guard let data = animationClipData[name],
              let jsonString = String(data: data, encoding: .utf8) else {
            Log.character("[ThreeVRM] Animation clip not found: '\(name)'")
            return
        }

        currentClipName = name
        Log.character("[ThreeVRM] Playing animation: '\(name)'")

        let js = "window.playAnimation(\(jsonString));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] playAnimation error: \(error)")
            }
        }
    }

    func stopAnimation() {
        resetInactivityTimer()
        if currentClipName != nil {
            Log.character("[ThreeVRM] Stopping animation: '\(currentClipName ?? "")'")
            currentClipName = nil
        }

        let js = "window.stopAnimation();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - WKScriptMessageHandler

extension ThreeVRMCharacterManager: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            handleBridgeMessage(message)
        }
    }

    private func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        switch event {
        case "modelLoaded":
            let success = body["success"] as? Bool ?? false
            if success {
                isModelLoaded = true
                resetInactivityTimer()
                Log.character("[ThreeVRM] Model loaded successfully (via bridge)")
                playAnimation(named: "wave")   // she greets on arrival (clip may be absent — silent)
            } else {
                Log.character("[ThreeVRM] Model load failed (via bridge)")
            }

        case "animationEnded":
            let name = body["name"] as? String ?? ""
            currentClipName = nil
            resetInactivityTimer()
            Log.character("[ThreeVRM] Animation ended: '\(name)'")

        case "touch":
            let part = body["part"] as? String ?? "body"
            Log.character("[ThreeVRM] Touched: \(part)")
            onTouch?(part)

        default:
            Log.character("[ThreeVRM] Unknown bridge event: \(event)")
        }
    }
}

// MARK: - Emotion Extension

extension Emotion {

    /// Expression mappings for three-vrm: array of {name, value} dictionaries.
    ///
    /// These use the standard VRM expression presets that three-vrm normalizes from
    /// any VRM 0.x / 1.0 model (`happy`, `angry`, `sad`, `relaxed`, plus `neutral`).
    /// The default model (Alicia Solid) only ships these four emotion presets — it has
    /// no `surprised` expression — so the 16 emotions are bucketed onto them. Swap in a
    /// model with richer expressions and you can give each emotion a distinct preset.
    /// Emotion → weighted blend of the VRM standard presets. VRM 0.x models (Alicia)
    /// only expose happy/angry/sad/relaxed, so the 16 emotions are differentiated by
    /// *mixing* them at different weights instead of collapsing onto four faces.
    /// ('aa'/blink are unusable here: lip-sync rewrites 'aa' every frame and the idle
    /// blink timer zeroes 'blink' after each blink.)
    var threeVRMExpressionMappings: [[String: Any]] {
        func m(_ pairs: (String, Double)...) -> [[String: Any]] {
            pairs.map { ["name": $0.0, "value": $0.1] }
        }
        switch self {
        case .neutral:    return []                                            // no expression
        case .happy:      return m(("happy", 1.0))                             // baseline smile
        case .sad:        return m(("sad", 1.0))                               // baseline sorrow
        case .angry:      return m(("angry", 1.0))                             // baseline anger
        case .surprised:  return m(("happy", 1.0), ("sad", 0.5))               // brows-up startle (日系惊讶脸)
        case .curious:    return m(("relaxed", 1.0), ("happy", 0.4))           // interested, light smile
        case .excited:    return m(("happy", 1.0), ("relaxed", 0.45))          // beaming
        case .shy:        return m(("relaxed", 0.9), ("angry", 0.4))           // flustered blush
        case .love:       return m(("happy", 0.9), ("relaxed", 0.5))           // sweet adoration
        case .smirk:      return m(("relaxed", 0.9), ("happy", 0.45))          // mischievous half-smile
        case .sleepy:     return m(("relaxed", 0.85), ("sad", 0.45))           // drooping eyelids
        case .proud:      return m(("happy", 0.95), ("angry", 0.35))           // smug chin-up
        case .disgusted:  return m(("angry", 0.75), ("sad", 0.5))              // wrinkled distaste
        case .pain:       return m(("sad", 0.95), ("angry", 0.4))              // wince
        case .laugh:      return m(("happy", 1.0), ("relaxed", 0.45))          // full laughter
        case .bored:      return m(("relaxed", 0.85), ("sad", 0.45))           // listless slump
        }
    }
}
