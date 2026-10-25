import CoreGraphics

/// Pure geometry for placing the desktop-pet window. Takes and returns plain CGRect/CGSize
/// (screen `visibleFrame`s), never touches AppKit windows — so every placement decision is
/// unit-testable and every failure path funnels to `bottomRight`, the single fail-safe spot
/// (she ALWAYS reappears at the bottom-right corner, never off-screen).
enum PetFramePlanner {
    /// Gap between her and the screen edge (QQ-pet style: hovering just above the Dock).
    static let margin: CGFloat = 8

    /// Bottom-right of `visible` (which must already exclude the menu bar + Dock).
    static func bottomRight(size: CGSize, in visible: CGRect) -> CGRect {
        let s = clamped(size: size, to: visible)
        return CGRect(x: visible.maxX - s.width - margin,
                      y: visible.minY + margin,
                      width: s.width,
                      height: s.height)
    }

    /// Never let her exceed 90% of the screen's dimensions.
    static func clamped(size: CGSize, to visible: CGRect) -> CGSize {
        CGSize(width: min(size.width, visible.width * 0.9),
               height: min(size.height, visible.height * 0.9))
    }

    /// Reject NaN / non-positive garbage from UserDefaults.
    /// (Uses `size.width`/`size.height`, NOT the `.width`/`.height` shortcuts — those return
    /// the ABSOLUTE value, so a stored width of -5 would sneak through. And checks each
    /// component via `Double.isFinite` — `CGRect.isFinite` is `package`-locked in the
    /// macOS 26 SDK, inaccessible from app code.)
    static func isValid(_ f: CGRect) -> Bool {
        f.origin.x.isFinite && f.origin.y.isFinite
            && f.size.width.isFinite && f.size.height.isFinite
            && f.size.width > 0 && f.size.height > 0
    }

    /// Restore priority: a valid stored frame that's still on its (live) anchor screen wins;
    /// anything else — no storage, anchor screen unplugged, frame off-screen — falls back to
    /// the bottom-right of the primary screen.
    static func restore(storedFrame: CGRect?, anchorVisible: CGRect?,
                        fallbackSize: CGSize, primaryVisible: CGRect) -> CGRect {
        if let stored = storedFrame, let anchor = anchorVisible,
           isValid(stored), stored.intersects(anchor) {
            return stored
        }
        return bottomRight(size: fallbackSize, in: primaryVisible)
    }

    // MARK: - UserDefaults string coding ("x,y,w,h")

    static func encode(_ f: CGRect) -> String {
        "\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)"
    }

    static func decode(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        let f = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        return isValid(f) ? f : nil
    }
}
