import Foundation

/// Coalesces high-frequency token deltas into low-frequency UI updates.
/// Purely a UI-layer concern: callers keep their own full text (rawResponse);
/// only the streamed display text flows through here. `flush()` guarantees no tail loss.
@MainActor
final class StreamThrottle {

    static let baseInterval: TimeInterval = 0.12
    static let longTextInterval: TimeInterval = 0.24
    /// Beyond this many characters, widen the interval so late-stream re-parses stay smooth.
    static let longTextThreshold = 4000

    private let onEmit: (String) -> Void
    private var buffer = ""
    private var lastEmit: Date?
    private var pending: Task<Void, Never>?
    private var totalLength = 0

    var currentInterval: TimeInterval { totalLength > Self.longTextThreshold ? Self.longTextInterval : Self.baseInterval }

    init(onEmit: @escaping (String) -> Void) {
        self.onEmit = onEmit
    }

    func push(_ delta: String) {
        guard !delta.isEmpty else { return }
        buffer += delta
        totalLength += delta.count
        if let last = lastEmit, Date().timeIntervalSince(last) < currentInterval {
            guard pending == nil else { return }
            let delay = currentInterval
            pending = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return } // cancelled → bail
                self?.pending = nil
                self?.emit()
            }
        } else {
            emit()
        }
    }

    /// Emit whatever is buffered right now — call when the stream ends or is cancelled.
    func flush() {
        pending?.cancel()
        pending = nil
        emit()
    }

    /// Reset for the next turn.
    func reset() {
        pending?.cancel()
        pending = nil
        buffer = ""
        lastEmit = nil
        totalLength = 0
    }

    private func emit() {
        guard !buffer.isEmpty else { return }
        let out = buffer
        buffer = ""
        lastEmit = Date()
        onEmit(out)
    }
}
