import Foundation

/// A single message in the conversation.
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    /// Whether this message should be hidden from the chat UI (e.g. proactive instructions).
    let isHidden: Bool
    /// The model's reasoning process (`delta.reasoning_content`), shown in a collapsible
    /// panel. nil for user messages, old records (JSONL decode tolerates the missing key),
    /// and brains that don't stream thinking. Never part of reply text, TTS, or context.
    let thinking: String?

    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date(), isHidden: Bool = false, thinking: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isHidden = isHidden
        self.thinking = thinking
    }

    /// Convert to OpenAI API message format.
    var apiMessage: [String: String] {
        ["role": role.rawValue, "content": content]
    }

    /// Strip emotion tags from content for display.
    var displayContent: String {
        content.replacingOccurrences(
            of: #"\[(neutral|happy|sad|angry|surprised|curious|excited|shy|love|smirk|sleepy|proud|disgusted|pain|laugh|bored)\]\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}
