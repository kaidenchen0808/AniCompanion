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

    func addAssistantMessage(_ content: String) {
        addMessage(ChatMessage(role: .assistant, content: content))
    }

    func addSystemMessage(_ content: String) {
        addMessage(ChatMessage(role: .system, content: content))
    }

    /// Messages to send to the LLM (most recent N messages).
    var contextMessages: [ChatMessage] {
        let startIndex = max(0, messages.count - maxContextMessages)
        return Array(messages[startIndex...])
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
