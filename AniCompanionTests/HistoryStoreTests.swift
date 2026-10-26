import XCTest
@testable import AniCompanion

final class HistoryStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Fixed timestamp so per-message dates don't depend on wall-clock time.
    private func msg(_ role: ChatMessage.Role, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func test_append_thenLoadLast_roundTrip() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        (0..<250).forEach { store.append(msg(.user, "m\($0)")) }
        XCTAssertEqual(store.loadLast(200).count, 200)
        XCTAssertEqual(store.loadLast(200).last?.content, "m249")
        XCTAssertEqual(store.loadLast(200).first?.content, "m50")   // 末尾 200 条 = m50..m249
    }

    func test_missingFile_returnsEmpty() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        XCTAssertEqual(store.loadLast(50), [])
    }

    func test_corruptLine_skippedNotFatal() {
        let url = dir.appendingPathComponent("history.jsonl")
        try! "not-json\n".write(to: url, atomically: true, encoding: .utf8)
        let store = HistoryStore(fileURL: url)
        store.append(msg(.assistant, "好的"))
        XCTAssertEqual(store.loadLast(10).count, 1)
        XCTAssertEqual(store.loadLast(10).first?.content, "好的")
    }

    func test_removeLast() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        store.append(msg(.user, "a"))
        store.append(msg(.assistant, "b"))
        XCTAssertTrue(store.removeLast())
        XCTAssertEqual(store.loadLast(10).map(\.content), ["a"])
        XCTAssertTrue(store.removeLast())
        XCTAssertFalse(store.removeLast())   // 已空
    }

    func test_removeById_rewritesFile() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        let keep = msg(.user, "keep")
        let drop = msg(.assistant, "drop")
        store.append(keep)
        store.append(drop)
        XCTAssertTrue(store.remove(id: drop.id))
        XCTAssertEqual(store.loadLast(10).map(\.id), [keep.id])
        XCTAssertFalse(store.remove(id: drop.id))   // 已不存在
    }

    func test_clear_removesFile() {
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore(fileURL: url)
        store.append(msg(.user, "x"))
        store.clear()
        XCTAssertEqual(store.loadLast(10), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_loadBefore_returnsOlderThanAnchor() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        (0..<300).forEach { store.append(msg(.user, "m\($0)")) }
        let loaded = store.loadLast(100)                         // m200..m299
        let older = store.loadBefore(loaded.first!.id, limit: 50) // m150..m199
        XCTAssertEqual(older.count, 50)
        XCTAssertEqual(older.last?.content, "m199")
        XCTAssertEqual(older.first?.content, "m150")
    }

    func test_loadBefore_unknownAnchor_returnsEmpty() {
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        store.append(msg(.user, "only"))
        XCTAssertEqual(store.loadBefore(UUID(), limit: 10), [])
    }

    func test_defaultPath_isInAppSupport() {
        let store = HistoryStore()   // 默认路径
        XCTAssertTrue(
            store.fileURL.path.contains("Application Support/AniCompanion"),
            "default path should live in App Support/AniCompanion, got \(store.fileURL.path)"
        )
    }
}
