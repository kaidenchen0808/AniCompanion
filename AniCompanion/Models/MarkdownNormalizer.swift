import Foundation

/// Render-layer normalization: converts rich-format syntaxes the markdown engine
/// can't render natively into forms it can. Applied at the MarkdownView boundary —
/// NEVER in `displayContent` (copy must preserve the original).
enum MarkdownNormalizer {

    /// All transformations, order-stable.
    static func normalize(_ text: String) -> String {
        var s = text
        // $$...$$ block math → ```math fence (rendered by MathBlockView via the
        // codeBlock theme hook's fenceInfo). Inline $...$ stays literal (no inline
        // view hook exists; converting it would break the sentence flow).
        s = s.replacingOccurrences(
            of: #"\$\$\s*\n?([\s\S]*?)\n?\s*\$\$"#,
            with: "```math\n$1\n```",
            options: .regularExpression
        )
        // ==highlight== → bold (highlight color isn't expressible inline; bold is the
        // closest rich rendering)
        s = s.replacingOccurrences(of: #"==([^=\n]+)=="#, with: "**$1**", options: .regularExpression)
        // Common HTML emphasis tags → markdown equivalents
        s = s.replacingOccurrences(of: #"<b>([^<\n]+)</b>"#, with: "**$1**", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<strong>([^<\n]+)</strong>"#, with: "**$1**", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<i>([^<\n]+)</i>"#, with: "*$1*", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<em>([^<\n]+)</em>"#, with: "*$1*", options: .regularExpression)
        return s
    }
}
