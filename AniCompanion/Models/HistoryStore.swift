import Foundation

/// Append-only JSONL chat-history store — one `ChatMessage` per line.
///
/// The display history lives on disk at `~/Library/Application Support/AniCompanion/history.jsonl`
/// and is decoupled from the LLM context window (`ConversationHistory.contextMessages` still
/// caps at 40 messages). Main-actor serialized by its only caller (`ConversationHistory`) —
/// no internal locking.
///
/// Decoupled from companion-layer's `chat_history` (her memory) by design: neither side reads
/// the other, and cross-end consistency is not a goal.
final class HistoryStore {

    /// Storage location (injectable for tests).
    let fileURL: URL

    /// Default store at `~/Library/Application Support/AniCompanion/history.jsonl`.
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AniCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("history.jsonl")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Reads

    /// The most recent `n` messages, oldest-first. Corrupt lines are skipped, not fatal.
    /// (File volume is a few hundred lines/day — full-line read then suffix is fine; revisit
    /// with tail-chunked reads only if this ever shows up in profiling.)
    func loadLast(_ n: Int) -> [ChatMessage] {
        let all = readAll()
        guard all.count > n else { return all }
        return Array(all[(all.count - n)...])
    }

    /// Up to `limit` messages strictly older than the one with `id` (for upward paging).
    /// Unknown anchor (or the oldest message) returns [] — no more history signal.
    func loadBefore(_ id: UUID, limit: Int) -> [ChatMessage] {
        let all = readAll()
        guard let anchor = all.firstIndex(where: { $0.id == id }) else { return [] }
        let upper = all.index(anchor, offsetBy: -min(limit, anchor), limitedBy: all.startIndex) ?? all.startIndex
        return Array(all[upper..<anchor])
    }

    private func readAll() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { lineData in
            try? decoder.decode(ChatMessage.self, from: lineData)
        }
    }

    // MARK: - Writes

    /// Append one message as a single JSONL line (creates the file on first write).
    func append(_ message: ChatMessage) {
        guard let line = try? JSONEncoder().encode(message) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        var lineWithNewline = line
        lineWithNewline.append(0x0A)
        try? handle.write(contentsOf: lineWithNewline)
    }

    /// Drop the newest line. Returns false when the store is empty.
    @discardableResult
    func removeLast() -> Bool {
        var all = readAll()
        guard !all.isEmpty else { return false }
        all.removeLast()
        rewrite(all)
        return true
    }

    /// Remove the message with `id` (rewrites the file). Returns false when not found.
    @discardableResult
    func remove(id: UUID) -> Bool {
        let all = readAll()
        let kept = all.filter { $0.id != id }
        guard kept.count != all.count else { return false }
        rewrite(kept)
        return true
    }

    /// Delete the file entirely.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func rewrite(_ messages: [ChatMessage]) {
        let encoder = JSONEncoder()
        var data = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
