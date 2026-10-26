import Foundation

/// Detects macOS file paths in assistant replies so they can render as file cards
/// (or images, via `AniImageProvider`). Pure logic — unit-testable.
enum FilePathDetector {

    /// A candidate path found in text: the raw match plus its expanded absolute form.
    struct Match: Equatable {
        let raw: String
        let absolute: String
        var fileURL: URL { URL(fileURLWithPath: absolute) }
    }

    /// Known extensions we render as cards (images are handled by the markdown image
    /// pipeline instead — `![](path)` arrives as a URL there).
    static let cardExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md",
        "json", "csv", "zip", "tar", "gz", "mp3", "mp4", "mov", "wav",
        "swift", "ts", "js", "py", "sh", "yaml", "yml", "html", "css",
    ]

    /// Absolute-path or `~/`-relative path with a file extension, NOT inside a URL.
    /// - Bare `/Users/...`, `/tmp/...`, `~/...` with a dotted extension qualify.
    /// - `https://.../path/file.pdf` must NOT match (the `//` host part would
    ///   otherwise look like a path) — we reject matches preceded by a URL scheme.
    static func matches(in text: String) -> [Match] {
        // 先把 URL（http/https）与 markdown 链接目标抹成等长空格——保偏移稳定，
        // 且 URL 里的 /Users/... 路径段不会被误判（链接渲染归 markdown link 管）
        var sanitized = text
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://\S+|\]\(\S+?\)"#) {
            let ns = sanitized as NSString
            for m in urlRegex.matches(in: sanitized, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
                sanitized = ns.replacingCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
            }
        }
        // optional ~ or / leading; path chars; ends with .ext (2-5 letters)
        let pattern = #"(?:~|/(?:Users|tmp|var|opt|private|Applications))[/\w.\- ]*?\.\w{2,5}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
        var out: [Match] = []
        for m in regex.matches(in: sanitized, options: [], range: range) {
            guard let r = Range(m.range, in: sanitized) else { continue }
            let raw = String(sanitized[r]).trimmingCharacters(in: .whitespaces)
            // Trim trailing punctuation that regex's \w greediness can't capture cleanly
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "。，；、！）)]}"))
            let absolute = (cleaned as NSString).expandingTildeInPath
            out.append(Match(raw: cleaned, absolute: absolute))
        }
        return out
    }

    /// SF Symbol for a file extension (card iconography).
    static func symbol(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "doc", "docx", "txt", "md": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "mp3", "wav": return "waveform"
        case "mp4", "mov": return "film"
        case "zip", "tar", "gz": return "doc.zipper"
        case "swift", "ts", "js", "py", "sh", "yaml", "yml", "html", "css", "json": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
