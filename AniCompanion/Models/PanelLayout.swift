import Foundation

/// Pure layout math for the QQ-style main split (chat left / character right).
/// Kept free of SwiftUI so the clamping rules are unit-testable.
enum PanelLayout {

    /// Chat panel's share of the window width. 68% default (chat-dominant, QQ style)
    /// → she keeps ≈285pt at the 900pt minimum window; her 300pt `minWidth` floor
    /// wins in HStack arbitration, nudging chat back a hair — acceptable.
    static let defaultRatio: CGFloat = 0.68
    static let minRatio: CGFloat = 0.30
    static let maxRatio: CGFloat = 0.70

    /// Clamp a stored/raw ratio into the valid band. NaN (corrupt storage) falls back
    /// to the default instead of bricking the layout.
    static func computeRatio(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return defaultRatio }
        return min(max(raw, minRatio), maxRatio)
    }

    /// Chat panel width for the current window — the split tracks window resizing
    /// proportionally (both panels scale, QQ-style).
    static func chatWidth(ratio: CGFloat, windowWidth: CGFloat) -> CGFloat {
        windowWidth * computeRatio(ratio)
    }
}
