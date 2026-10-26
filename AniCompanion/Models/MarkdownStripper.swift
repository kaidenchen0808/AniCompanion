import Foundation

/// Strips Markdown syntax so TTS reads natural spoken text.
/// Emotion tags ([happy] …) are NOT touched — SentenceParser extracts them downstream.
enum MarkdownStripper {

    /** Drop the trailing "---- 来源 ----" sources block (URLs are for the eyes,
     *  never for TTS). No block → text unchanged. */
    static func strippingSources(_ text: String) -> String {
        guard let range = text.range(of: "---- 来源 ----") else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strip(_ text: String) -> String {
        var s = text
        // Fenced code blocks (closed) → short spoken placeholder; keep language-free.
        s = s.replacingOccurrences(of: #"(?s)```[^\n`]*\n.*?```"#, with: "\n（代码）\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?s)~~~[^\n]*\n.*?~~~"#, with: "\n（代码）\n", options: .regularExpression)
        // Unclosed fence (stream cut mid-block): drop from the fence to the end.
        // Must run AFTER the closed-fence rule above — any ``` remaining here is unclosed by definition.
        s = s.replacingOccurrences(of: #"(?s)```[^\n]*\n?.*\z"#, with: "", options: .regularExpression)

        // Images → alt text; links → link text (must run BEFORE generic bracket rules).
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)

        // Emphasis / strikethrough markers.
        s = s.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__([^_\n]+)__"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!_)_([^_\n]+)_(?!_)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~([^~\n]+)~~"#, with: "$1", options: .regularExpression)

        // Inline code (after emphasis so `**` inside backticks is already gone).
        s = s.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)

        // Tables: drop separator rows, then join cells with a spoken comma.
        // NOTE: NSString.CompareOptions has no .anchorsMatchLines; use ICU inline flag (?m) for line anchors.
        s = s.replacingOccurrences(of: #"(?m)^\s*\|?[\s:\-|]+\|?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\|\s*"#, with: "，", options: .regularExpression)

        // Line prefixes: headings, blockquotes, list bullets, ordered markers, task boxes.
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}>\s?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\d+[.、)]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\[[ xX]\]\s+"#, with: "", options: .regularExpression)

        // Horizontal rules and blank-line runs.
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}(?:[-*_]\s*){3,}$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
