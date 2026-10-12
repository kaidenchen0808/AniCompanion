import AppKit

// MARK: - PetDragView
//
// A transparent overlay placed over the character in Desktop Pet mode (added in AppKit by
// `AppDelegate`, on top of the bare WKWebView). Interaction is split by movement:
//   - press + move (>4pt) → drags the whole window (`performDrag` works even though a
//     borderless window isn't key)
//   - press + release without moving, single click → touch interaction: forwarded to the
//     three.js scene (`window.handleTap`), which raycasts her body and reports the part
//   - double-click → leaves pet mode
// The drag starts from the *original* mouse-down event once the threshold is crossed, so a
// click never moves the window and a drag never fires a touch.

final class PetDragView: NSView {
    var onExit: (() -> Void)?
    /// Called with the multiplicative scale factor (>1 grows, <1 shrinks). The handler keeps
    /// the aspect ratio and clamps to sane bounds.
    var onScale: ((CGFloat) -> Void)?
    /// Single click (no drag) at a window coordinate — AppDelegate forwards it into the
    /// three.js scene for the touch raycast.
    var onTap: ((NSPoint) -> Void)?

    private var pendingDragEvent: NSEvent?
    private var dragOrigin: NSPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        pendingDragEvent = event
        dragOrigin = event.locationInWindow
        isDragging = false
        // Don't performDrag yet — wait to see whether this is a click or a drag.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let origin = dragOrigin, let down = pendingDragEvent else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard hypot(dx, dy) > 4 else { return } // macOS standard click slop
        isDragging = true
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pendingDragEvent = nil
            dragOrigin = nil
            isDragging = false
        }
        guard !isDragging else { return }
        if event.clickCount == 2 {
            onExit?()
        } else {
            onTap?(event.locationInWindow)
        }
    }

    /// Two-finger / wheel scroll resizes the pet (scroll up = bigger).
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // Clamp per-tick so a fast flick doesn't jump the size.
        onScale?(1 + max(-0.08, min(0.08, delta * 0.004)))
    }

    /// Trackpad pinch resizes the pet.
    override func magnify(with event: NSEvent) {
        onScale?(1 + event.magnification)
    }
}
