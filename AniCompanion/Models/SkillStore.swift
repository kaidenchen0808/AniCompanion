import Foundation

/// A locally discovered Claude Code skill (chat-side prompt injection source).
struct Skill: Identifiable, Equatable {
    let name: String
    let description: String
    /// Absolute path of the SKILL.md file.
    let path: String
    var id: String { name }
}

/// Scans `~/.claude/skills/*/SKILL.md` — all 94 of them, frontmatter-parsed,
/// broken directories silently skipped (they are inevitable at this count).
enum SkillStore {

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
    }

    /// Scan a skills root: parse each SKILL.md's frontmatter (name + description first
    /// line), sorted by name for a stable list.
    static func scan(root: URL) -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var out: [Skill] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let skill = parseSkill(at: entry.appendingPathComponent("SKILL.md")) else { continue }
            out.append(skill)
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Parse one SKILL.md: requires a `---` frontmatter block containing `name:`.
    static func parseSkill(at url: URL) -> Skill? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        var name = ""
        var description = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }   // frontmatter 结束
            if name.isEmpty, let v = value(of: line, key: "name") { name = v; continue }
            if description.isEmpty, let v = value(of: line, key: "description") { description = v }
        }
        guard !name.isEmpty else { return nil }
        return Skill(name: name, description: description, path: url.path)
    }

    private static func value(of line: String, key: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    }

    /// Fuzzy-ish filter: case-insensitive substring over name + description.
    static func filter(_ skills: [Skill], query: String) -> [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    /// The SKILL.md body (frontmatter stripped) capped at 4000 chars — the prompt-
    /// injection payload; some superpowers skills run thousands of words and would
    /// otherwise eat the whole context.
    static func loadBody(for skill: Skill, limit: Int = 4000) -> String {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: skill.path), encoding: .utf8) else { return "" }
        var body = raw
        if body.hasPrefix("---") {
            if let end = body.dropFirst(3).range(of: "\n---") {
                body = String(body[end.upperBound...])
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }
}
