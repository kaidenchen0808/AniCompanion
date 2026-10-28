import Foundation

/// In-memory conversation history with a sliding window for context management.
/// When a `HistoryStore` is injected, every mutation is mirrored to JSONL so the display
/// history survives restarts (the LLM context window is unaffected — see `contextMessages`).
@MainActor
final class ConversationHistory: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    /// Maximum number of messages to keep in context window for LLM calls.
    /// Older messages are still displayed in UI but not sent to the LLM.
    let maxContextMessages: Int

    /// Optional persistence sink — nil in tests/previews.
    private let store: HistoryStore?

    init(maxContextMessages: Int = 40, store: HistoryStore? = nil) {
        self.maxContextMessages = maxContextMessages
        self.store = store
    }

    /// Reload display history from disk (call once at startup, before any mutation).
    func restoreFromStore(limit: Int = 200) {
        guard let store else { return }
        messages = store.loadLast(limit)
    }

    /// Page older messages in at the top (display only — no disk writes, context untouched).
    /// Returns false when there is nothing older to load.
    @discardableResult
    func loadOlder(limit: Int = 100) -> Bool {
        guard let store, let oldest = messages.first else { return false }
        let older = store.loadBefore(oldest.id, limit: limit)
        guard !older.isEmpty else { return false }
        messages.insert(contentsOf: older, at: 0)
        return true
    }

    func addMessage(_ message: ChatMessage) {
        messages.append(message)
        store?.append(message)
    }

    func addUserMessage(_ content: String, isHidden: Bool = false) {
        addMessage(ChatMessage(role: .user, content: content, isHidden: isHidden))
    }

    func addAssistantMessage(_ content: String, thinking: String? = nil) {
        addMessage(ChatMessage(role: .assistant, content: content, thinking: thinking))
    }

    func addSystemMessage(_ content: String) {
        addMessage(ChatMessage(role: .system, content: content))
    }

    /// Messages to send to the LLM (most recent N messages).
    /// 较早轮次里的内联文件载荷压缩为头部摘要：全文每轮重发撑爆 token，滑出窗口后她又会
    /// "忘了"文件——压缩后文件名+头部细节常驻，可讨论的轮次大幅延长（2026-10-28 附件线收尾）。
    var contextMessages: [ChatMessage] {
        let startIndex = max(0, messages.count - maxContextMessages)
        let window = Array(messages[startIndex...])
        guard let lastUserIdx = window.lastIndex(where: { $0.role == .user }) else { return window }
        return window.enumerated().map { (i, m) in
            i == lastUserIdx ? m : Self.condenseFilePayloads(m)
        }
    }

    /// 较早消息里的 [文件 …]…[文件结束] 载荷压到头部 600 字（多载荷逐个处理；无载荷原样）。
    private static func condenseFilePayloads(_ m: ChatMessage) -> ChatMessage {
        let endMark = "[文件结束 —— 关于这个文件：]"
        guard m.content.contains("[文件 "), m.content.contains(endMark) else { return m }
        var out = ""
        var rest = Substring(m.content)
        let keep = 600
        while let start = rest.range(of: "[文件 ") {
            out += rest[..<start.lowerBound]
            let after = rest[start.lowerBound...]
            guard let end = after.range(of: endMark) else {
                out += after  // 残缺载荷（无结束标记）原样保留
                rest = ""
                break
            }
            let payload = after[..<end.lowerBound]
            if let nl = payload.firstIndex(of: "\n") {
                out += payload[...nl]  // 文件名行 + 换行
                let body = payload[payload.index(after: nl)...]
                out += body.prefix(keep)
                if body.count > keep { out += "…（已压缩，完整内容在更早消息）" }
            } else {
                out += payload
            }
            out += "[文件结束]"
            rest = after[end.upperBound...]
        }
        out += rest
        return ChatMessage(role: m.role, content: String(out), timestamp: m.timestamp, isHidden: m.isHidden, thinking: m.thinking)
    }

    func removeLastMessage() {
        guard !messages.isEmpty else { return }
        store?.removeLast()
        messages.removeLast()
    }

    /// Remove a single message by id (right-click delete) — mirrored to disk.
    @discardableResult
    func removeById(_ id: UUID) -> Bool {
        guard messages.contains(where: { $0.id == id }) else { return false }
        store?.remove(id: id)
        messages.removeAll { $0.id == id }
        return true
    }

    func clear() {
        store?.clear()
        messages.removeAll()
    }
}
