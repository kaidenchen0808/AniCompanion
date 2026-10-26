import XCTest
@testable import AniCompanion

@MainActor
final class StreamThrottleTests: XCTestCase {

    func test_burstPushes_coalesceIntoTwoEmits() {
        var emissions: [String] = []
        let throttle = StreamThrottle { emissions.append($0) }
        // 10 次同步 push 远小于 120ms 节拍:第 1 次立即发射,后 9 次缓冲,
        // 测试同步跑完(不等 pending 定时器),flush 再发 1 次。
        (0..<10).forEach { _ in throttle.push("a") }
        throttle.flush()
        XCTAssertEqual(emissions.count, 2)
        XCTAssertEqual(emissions.joined(), String(repeating: "a", count: 10))
    }

    func test_flushPreservesTail() {
        var emissions: [String] = []
        let throttle = StreamThrottle { emissions.append($0) }
        throttle.push("你好")
        throttle.push("呀")
        throttle.flush()
        XCTAssertEqual(emissions.joined(), "你好呀")
    }

    func test_resetClearsState() {
        var emissions: [String] = []
        let throttle = StreamThrottle { emissions.append($0) }
        throttle.push("x")
        throttle.reset()
        throttle.flush()               // reset 后 buffer 已空,flush 是 no-op
        XCTAssertEqual(emissions, ["x"])
    }

    func test_longText_switchesToSlowInterval() {
        let throttle = StreamThrottle { _ in }
        XCTAssertEqual(throttle.currentInterval, StreamThrottle.baseInterval)
        throttle.push(String(repeating: "字", count: 4001))
        XCTAssertEqual(throttle.currentInterval, StreamThrottle.longTextInterval)
    }
}
