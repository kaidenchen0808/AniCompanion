import Foundation

/// Splits a finished (Markdown-stripped) reply into emotion-tag-led segments for SentenceParser.
///
/// SentenceParser attributes each sentence the most recent emotion tag seen *before* it — but
/// only when tags arrive at the head of the buffer. One bulk `feed` of the whole reply lets
/// `stripInlineEmotionTags` remove every tag up front and flatten the entire reply to the LAST
/// tag's emotion, losing the per-sentence expression arc (the pet's core experience).
/// Feeding segment-by-segment keeps each segment's leading tag in effect via
/// `stripLeadingEmotionTags`, preserving the arc — same attribution as the old streaming feed.
enum EmotionSegmenter {

    /// Split text at every emotion tag: the tag belongs to the text AFTER it (a tag opens a
    /// new segment). Text before the first tag forms its own leading segment.
    ///
    /// Empty/whitespace-only pieces are dropped — a tag-only piece feeds the parser nothing to
    /// speak, and blank seams between tags carry no text.
    static func segments(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: SentenceParser.emotionTagPattern) else {
            return [text]
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var segments: [String] = []
        var cutStart = text.startIndex
        for match in matches {
            guard let tagStart = Range(match.range, in: text)?.lowerBound,
                  tagStart > cutStart else { continue }   // leading/consecutive tag: no seam
            segments.append(String(text[cutStart..<tagStart]))
            cutStart = tagStart
        }
        segments.append(String(text[cutStart...]))

        return segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
