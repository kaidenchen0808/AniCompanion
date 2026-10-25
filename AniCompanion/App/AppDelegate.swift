import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: - PetPanelWindow
//
// An NSPanel so pet mode can use `.nonactivatingPanel` — she floats above your other apps and
// receives drags/clicks WITHOUT making AniCompanion the frontmost app, so your editor keeps focus
// while she watches (only an NSPanel honors that style; a plain NSWindow ignores it).
//
// The `canBecomeKey`/`canBecomeMain` overrides keep her usable when borderless (a stock borderless
// window returns false for both, which silently kills focus and makes her look "dead").

final class PetPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - AppDelegate
//
// We create the main window ourselves so we fully own its NSWindow. Desktop Pet mode swaps
// the window between two states:
//   • Windowed: an NSHostingController hosting MainView (character + chat).
//   • Pet:      borderless + transparent, with the *bare* WKWebView as the contentView.
//
// Why the bare webView in pet mode: the character's WebGL canvas is genuinely transparent
// (drawsBackground=false + three.js alpha:true + transparent HTML), so putting it directly
// in a borderless `isOpaque=false` window lets the desktop show through. Routing it through
// SwiftUI instead reintroduces two opaque layers — the NSHostingController backing layer and
// ThreeVRMRenderView's RadialGradient — which is what blocked transparency before.
//
// The same WKWebView instance is reused the whole time (ThreeVRMWebView.makeNSView returns
// `characterManager.webView` if it exists), so toggling never reloads the model.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    let appState = AppState()

    private(set) var mainWindow: NSWindow?
    private var petCancellable: AnyCancellable?
    private var sceneReadyCancellable: AnyCancellable?
    private var framePersistWork: DispatchWorkItem?
    private var isPetActive = false

    /// Quiet mode is active (small translucent form at the bottom-right). Tracked separately from
    /// `appState.displayMode` for the same reason as `isPetActive` — never re-derive window state.
    private var isQuietActive = false
    private var quietCancellable: AnyCancellable?

    /// Quiet form size (QQ-pet corner-sticker scale). Deliberately NOT configurable — the resting
    /// form is a fixed tiny size; her real size (`currentPetSize`) is restored on wake.
    private static let quietSize = NSSize(width: 80, height: 86)

    /// Which side of her face the speech bubble currently sits on ("left"/"right"); flipped as
    /// she's dragged so it never runs off the screen edge. See `bubbleSide(for:)`.
    private var lastBubbleSide = "right"

    // QQ-pet scale (~1/6 of a laptop screen height). At this width the speech bubble renders
    // as an above-head banner (body.small-pet in vrm_scene.html); scaled up past ~360px it
    // becomes the classic side bubble in the transparent margin beside her face.
    private static let basePetSize = NSSize(width: 280, height: 300)
    private static let windowedSize = NSSize(width: 1000, height: 650)

    /// Current pet size — persists across toggles so a resized pet stays that size.
    private var currentPetSize = AppDelegate.basePetSize

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.initializeServices()

        // Restore the pet size she was last scaled to (written by scalePet); anything
        // malformed/non-positive falls through to basePetSize.
        let sizeParts = appState.petSizeStorage.split(separator: ",").compactMap { Double($0) }
        if sizeParts.count == 2, sizeParts[0] > 0, sizeParts[1] > 0 {
            currentPetSize = NSSize(width: sizeParts[0], height: sizeParts[1])
        }

        let window = PetPanelWindow(contentViewController: makeWindowedController())
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.windowedSize)
        window.isReleasedWhenClosed = false
        // NSPanels hide when the app deactivates by default; we never want that — in pet mode she
        // floats above your *other* apps, and in windowed mode she should act like a normal window.
        window.hidesOnDeactivate = false
        window.title = String(localized: "AI Agent | Xiaoguang", comment: "Window title — character name")
        window.center()
        // …and skip pet-first-launch on a fresh install: the setup wizard lives in the
        // windowed MainView (a sheet), and enterPet tears that view tree down mid-wizard.
        // First run stays windowed; after setup completes, launches go straight to pet.
        let startInPet = appState.launchInPetMode && appState.agentSetupCompleted
        if startInPet {
            // Hide the windowed form until pet mode is in place — the user sees her appear
            // at the bottom-right directly, never a 1000x650 window flashing by.
            window.alphaValue = 0
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        window.delegate = self   // windowDidMove → re-pick the bubble side as she's dragged

        // Drive the window's pet/normal state directly off the shared flag. Guarding on a
        // tracked bool (not the style mask) avoids the `.contains(.borderless)` tautology and
        // skips the launch-time `petMode == false` emission.
        petCancellable = appState.$petMode
            .receive(on: RunLoop.main)
            .sink { [weak self] petMode in
                guard let self, let window = self.mainWindow, petMode != self.isPetActive else { return }
                self.isPetActive = petMode
                self.appState.launchInPetMode = petMode   // remember the explicit choice
                petMode ? self.enterPet(window) : self.exitPet(window)
                if petMode, self.appState.displayMode == .quiet { self.enterQuiet() }   // before the reveal below
                if petMode { window.alphaValue = 1 }   // reveal only after enterPet reshaped the window
            }

        // Apply display-mode changes to the window (quiet ⇄ companion). Mirrors the petMode sink:
        // always persist the choice, but only reshape the window while the pet is actually active —
        // a windowed save persists and takes effect on the next enter-pet.
        // NOTE: `conversationController.isQuietMode` is owned by enterQuiet()/exitQuiet() below —
        // NOT set here. The sink's guard would skip the flag on launch-into-quiet (the petMode sink
        // calls enterQuiet() directly), and exitPet must clear it on the way to windowed mode.
        quietCancellable = appState.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.appState.displayModeStorage = mode.rawValue
                guard self.isPetActive, (mode == .quiet) != self.isQuietActive else { return }
                mode == .quiet ? self.enterQuiet() : self.exitQuiet()
            }

        // Launch-as-pet: the webView only exists once MainView mounts (windowed form), so
        // wait for the scene to be ready, then flip petMode — the sink above does the rest.
        if startInPet {
            sceneReadyCancellable = appState.characterManager.$isSceneReady
                .receive(on: RunLoop.main)
                .sink { [weak self] ready in
                    guard ready, let self, !self.isPetActive else { return }
                    self.appState.petMode = true
                    self.sceneReadyCancellable = nil   // fires once; drop the subscription
                }
            // Fail-safe: if the scene never reports ready (odd webview failure), show the
            // windowed form after 3s instead of leaving the app invisible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.isPetActive else { return }
                self.mainWindow?.alphaValue = 1
            }
        }
    }

    private func makeWindowedController() -> NSViewController {
        let controller = NSHostingController(rootView: MainView().environmentObject(appState))
        // Bridge SwiftUI's `.toolbar` (the 🐾 + ⚙️ buttons) and `.navigationTitle` into our
        // AppKit-owned window. Without this a hand-created NSHostingController shows no toolbar,
        // and the fresh controller made on exiting pet mode would come back bare.
        controller.sceneBridgingOptions = [.title, .toolbars]
        return controller
    }

    // MARK: - Pet mode

    private func enterPet(_ window: NSWindow) {
        guard let webView = appState.characterManager.webView else {
            // Character not loaded yet — make the toggle a graceful no-op.
            isPetActive = false
            appState.petMode = false
            return
        }

        appState.characterManager.petModeActive = true   // enable the speech bubble

        // `.nonactivatingPanel` lets her receive drags/clicks without making AniCompanion frontmost,
        // so your work app keeps focus. `.borderless` is 0, so this is effectively just the
        // non-activating flag. (Full assignment drops the windowed `.titled` mask.)
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.hasShadow = false                         // also avoids a 1px stroke on Tahoe
        window.level = .floating                         // always on top
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false                          // both load-bearing
        window.backgroundColor = .clear

        // Detach the SwiftUI host and the webView.
        window.contentViewController = nil
        webView.removeFromSuperview()

        // Place her at the remembered spot (or bottom-right on first run). Resize BEFORE
        // installing the webView — see the ordering gotcha in CLAUDE.md.
        let f = plannedPetFrame(for: window)
        window.setFrame(f, display: true)
        currentPetSize = f.size

        // Bare transparent webView (+ drag overlay) as the content, sized to fill.
        let bounds = NSRect(origin: .zero, size: currentPetSize)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.isOpaque = false
        container.layer?.backgroundColor = NSColor.clear.cgColor

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let drag = PetDragView(frame: bounds)
        drag.onExit = { [weak self] in self?.appState.petMode = false }
        drag.onScale = { [weak self] factor in self?.scalePet(by: factor) }
        drag.onTap = { [weak self] point in
            guard let self, let webView = self.appState.characterManager.webView else { return }
            // AppKit window coords (bottom-left origin) → WebView CSS coords (top-left origin)
            let jsX = point.x
            let jsY = webView.bounds.height - point.y
            webView.evaluateJavaScript("window.handleTap && window.handleTap(\(jsX), \(jsY))", completionHandler: nil)
        }
        drag.autoresizingMask = [.width, .height]
        container.addSubview(drag)                        // on top: click = touch her, drag = move window, double-click exits, scroll/pinch resizes

        window.contentView = container
        window.makeKeyAndOrderFront(nil)                  // must re-key after the mask change

        // Place the speech bubble beside her face, on whichever side has more screen room
        // (so it never runs off the edge). Recomputed as she's dragged — see windowDidMove.
        lastBubbleSide = bubbleSide(for: window)
        webView.evaluateJavaScript("window.setBubbleSide && window.setBubbleSide('\(lastBubbleSide)')", completionHandler: nil)

        // The WebGL scene re-fits on the JS 'resize' event, which isn't guaranteed to fire on
        // an AppKit reparent — dispatch it explicitly so three.js re-frames the full character.
        refitScene(webView)
    }

    // MARK: - Quiet mode (resting mini form)

    /// Shrink her to the translucent corner-sticker form: stop any in-flight speech, clear the
    /// bubble, dock bottom-right. The window's own alphaValue is untouched (the launch-time
    /// reveal in the petMode sink stays in charge of that).
    private func enterQuiet() {
        guard let window = mainWindow, let webView = appState.characterManager.webView else { return }
        isQuietActive = true
        appState.conversationController?.isQuietMode = true   // drop pushed notifications (owned HERE)
        appState.conversationController?.cancel()          // stop mid-sentence TTS
        appState.characterManager.setSpeechText(nil)       // hide the bubble
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        window.setFrame(PetFramePlanner.bottomRight(size: Self.quietSize, in: visible), display: true)
        webView.alphaValue = 0.4
        refitScene(webView)
    }

    /// Wake back to the companion form: full opacity, remembered spot (or bottom-right).
    private func exitQuiet() {
        guard let window = mainWindow, let webView = appState.characterManager.webView else { return }
        isQuietActive = false
        appState.conversationController?.isQuietMode = false  // resume pushed notifications
        webView.alphaValue = 1
        window.setFrame(plannedPetFrame(for: window), display: true)
        refitScene(webView)
    }

    /// Where the pet window should sit: the stored frame if its screen is still live,
    /// otherwise the bottom-right of the key screen (PetFramePlanner owns all the rules).
    private func plannedPetFrame(for window: NSWindow) -> NSRect {
        let screens = NSScreen.screens
        let primary = (window.screen ?? NSScreen.main ?? screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let stored = PetFramePlanner.decode(appState.petFrameStorage)
        let anchor = screens.first { screenID($0) == appState.petAnchorScreen }
        return PetFramePlanner.restore(storedFrame: stored,
                                       anchorVisible: anchor?.visibleFrame,
                                       fallbackSize: currentPetSize,
                                       primaryVisible: primary)
    }

    /// Stable per-display identity (CGDirectDisplayID via the device description) — how we
    /// recognize "the screen she was on" across launches. NSScreen exposes no identifier
    /// property of its own; NSScreenNumber is the canonical one (localizedName would collide
    /// on two identical monitors).
    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            .map { String($0) } ?? screen.localizedName
    }

    private func exitPet(_ window: NSWindow) {
        if isQuietActive {
            appState.characterManager.webView?.alphaValue = 1
            isQuietActive = false
            appState.conversationController?.isQuietMode = false   // windowed mode must not stay muted
        }
        framePersistWork?.cancel()   // a pending debounced save must not observe the windowed frame
        appState.characterManager.setSpeechText(nil)      // hide bubble (while still active)
        appState.characterManager.petModeActive = false

        let webView = appState.characterManager.webView
        webView?.removeFromSuperview()
        window.contentView = nil
        // A FRESH host re-mounts MainView, whose ThreeVRMRenderView reuses the same webView
        // (no reload). Chat history etc. live in AppState, so nothing is lost.
        window.contentViewController = makeWindowedController()

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.level = .normal
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary]

        var f = window.frame
        f.size = Self.windowedSize
        window.setFrame(f, display: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Re-fit at the windowed size (she's centered in both modes — nothing to un-pan).
        if let webView { refitScene(webView) }
    }

    /// Which side of her face to place the speech bubble — the side with more room between her
    /// and the screen edge, so a wide bubble never runs off-screen. (She's centered in the pet
    /// window, so the window's mid-X ≈ her on-screen position.)
    private func bubbleSide(for window: NSWindow) -> String {
        guard let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return "right" }
        return window.frame.midX <= screenFrame.midX ? "right" : "left"
    }

    /// As she's dragged around, flip the bubble to the roomier side once she crosses the midline
    /// — and remember where she lands (debounced, below). The flip guard is an `if`, not an early
    /// `return`, so the persistence below still runs on moves that don't cross the midline.
    func windowDidMove(_ notification: Notification) {
        guard isPetActive, !isQuietActive,
              let window = mainWindow,
              let webView = appState.characterManager.webView else { return }
        let side = bubbleSide(for: window)
        if side != lastBubbleSide {
            lastBubbleSide = side
            webView.evaluateJavaScript("window.setBubbleSide && window.setBubbleSide('\(side)')", completionHandler: nil)
        }
        persistPetFrameShortly()
    }

    /// Debounced (500ms) persistence of her position + anchor screen while she's dragged.
    private func persistPetFrameShortly() {
        guard isPetActive, let window = mainWindow else { return }
        framePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPetActive, window === self.mainWindow else { return }
            self.appState.petFrameStorage = PetFramePlanner.encode(window.frame)
            self.appState.petAnchorScreen = window.screen.map { self.screenID($0) } ?? ""
        }
        framePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Force the three.js scene to re-read its size and re-frame the camera.
    private func refitScene(_ webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
        }
    }

    /// Resize the pet by `factor`, keeping the aspect ratio and anchoring her feet (so she
    /// grows/shrinks in place). The WebView autoresizes and three.js re-frames automatically.
    private func scalePet(by factor: CGFloat) {
        guard isPetActive, !isQuietActive, let window = mainWindow else { return }
        let ratio = Self.basePetSize.width / Self.basePetSize.height
        let minHeight: CGFloat = 150
        let maxHeight: CGFloat = 1100
        let height = min(max(currentPetSize.height * factor, minHeight), maxHeight)
        currentPetSize = NSSize(width: height * ratio, height: height)

        var f = window.frame
        let centerX = f.midX
        let bottomY = f.minY                 // keep her feet planted
        f.size = currentPetSize
        f.origin.x = centerX - currentPetSize.width / 2
        f.origin.y = bottomY
        window.setFrame(f, display: true)
        appState.petSizeStorage = "\(currentPetSize.width),\(currentPetSize.height)"
    }

    // The main character window is an NSPanel (for non-activating pet mode), and AppKit does NOT
    // count panels toward the "last window closed" check — so returning true here quit the whole
    // app whenever an auxiliary window (Settings) closed. Return false: closing the windowed panel
    // returns her to pet form (see windowShouldClose); quitting is ⌘Q only.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Closing the windowed panel doesn't quit — she goes back to pet form and keeps sitting
    /// at the bottom-right. Quit is ⌘Q (standard menu) only.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, !isPetActive else { return true }
        appState.petMode = true   // enterPet reshapes this same window; no actual close
        return false
    }
}
