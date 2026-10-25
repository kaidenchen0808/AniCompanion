import XCTest
@testable import AniCompanion

final class DisplayModeTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(DisplayMode.companion.rawValue, "companion")
        XCTAssertEqual(DisplayMode.quiet.rawValue, "quiet")
    }

    func testRoundTrip() {
        for mode in DisplayMode.allCases {
            XCTAssertEqual(DisplayMode(rawValue: mode.rawValue), mode)
        }
    }

    func testUnknownFallsBackToNil_thenCompanionAtCallSite() {
        // The AppState init maps nil → .companion; the enum itself stays a plain RawRepresentable.
        XCTAssertNil(DisplayMode(rawValue: "focus"))
        XCTAssertNil(DisplayMode(rawValue: ""))
    }

    func testAllCases() {
        XCTAssertEqual(DisplayMode.allCases, [.companion, .quiet])
    }
}
