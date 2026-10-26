import XCTest
@testable import AniCompanion

final class PanelLayoutTests: XCTestCase {

    func test_normalValue_passthrough() {
        XCTAssertEqual(PanelLayout.computeRatio(0.58), 0.58)
        XCTAssertEqual(PanelLayout.computeRatio(0.3), 0.3)
        XCTAssertEqual(PanelLayout.computeRatio(0.7), 0.7)
    }

    func test_outOfRange_clampedToBand() {
        XCTAssertEqual(PanelLayout.computeRatio(0.05), 0.3, accuracy: 0.0001)   // 手改 plist 的脏值
        XCTAssertEqual(PanelLayout.computeRatio(0.95), 0.7, accuracy: 0.0001)
        XCTAssertEqual(PanelLayout.computeRatio(-1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(PanelLayout.computeRatio(2), 0.7, accuracy: 0.0001)
    }

    func test_nan_fallsBackToDefault() {
        XCTAssertEqual(PanelLayout.computeRatio(.nan), PanelLayout.defaultRatio, accuracy: 0.0001)
    }

    func test_draggedRatio_staysInBand() {
        // 拖动映射：raw ratio + translation/windowWidth 再 clamp
        XCTAssertEqual(PanelLayout.computeRatio(0.58 + 0.5), 0.7, accuracy: 0.0001)  // 拖到底
        XCTAssertEqual(PanelLayout.computeRatio(0.58 - 0.5), 0.3, accuracy: 0.0001)  // 拖到顶
    }

    func test_chatWidth_tracksWindowWidth() {
        XCTAssertEqual(PanelLayout.chatWidth(ratio: 0.58, windowWidth: 900), 900 * 0.58, accuracy: 0.01)
        XCTAssertEqual(PanelLayout.chatWidth(ratio: 0.3, windowWidth: 1400), 1400 * 0.3, accuracy: 0.01)
    }
}
