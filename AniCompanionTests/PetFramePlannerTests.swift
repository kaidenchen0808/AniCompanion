import XCTest
@testable import AniCompanion

final class PetFramePlannerTests: XCTestCase {

    // A typical 14" MBP visible frame: Dock at the bottom, menu bar on top.
    let mainVisible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let petSize = CGSize(width: 280, height: 300)

    // MARK: bottom-right anchor

    func testBottomRight_dockAtBottom() {
        let f = PetFramePlanner.bottomRight(size: petSize, in: mainVisible)
        XCTAssertEqual(f.maxX, mainVisible.maxX - 8, accuracy: 0.001)
        XCTAssertEqual(f.minY, mainVisible.minY + 8, accuracy: 0.001)
        XCTAssertEqual(f.width, 280, accuracy: 0.001)
    }

    func testBottomRight_dockAtRight() {
        // Dock on the right: visible frame is inset from the right edge.
        let visible = CGRect(x: 0, y: 0, width: 1472, height: 982)
        let f = PetFramePlanner.bottomRight(size: petSize, in: visible)
        XCTAssertEqual(f.maxX, 1472 - 8, accuracy: 0.001)
    }

    // MARK: size clamping

    func testClamp_narrowScreen() {
        let visible = CGRect(x: 0, y: 0, width: 300, height: 800)
        let s = PetFramePlanner.clamped(size: petSize, to: visible)
        XCTAssertEqual(s.width, 270, accuracy: 0.001)  // 300 * 0.9
    }

    func testClamp_normalScreenUnchanged() {
        let s = PetFramePlanner.clamped(size: petSize, to: mainVisible)
        XCTAssertEqual(s.width, 280, accuracy: 0.001)
    }

    // MARK: stored-frame validation

    func testIsValid_rejectsGarbage() {
        XCTAssertFalse(PetFramePlanner.isValid(.init(x: CGFloat.nan, y: 0, width: 100, height: 100)))
        XCTAssertFalse(PetFramePlanner.isValid(.init(x: 0, y: 0, width: -5, height: 100)))
        XCTAssertFalse(PetFramePlanner.isValid(.init(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertTrue(PetFramePlanner.isValid(.init(x: 10, y: 10, width: 280, height: 300)))
    }

    // MARK: restore priority

    func testRestore_storedFrameOnLiveScreen_isKept() {
        let stored = CGRect(x: 400, y: 500, width: 280, height: 300)
        let f = PetFramePlanner.restore(storedFrame: stored, anchorVisible: mainVisible,
                                        fallbackSize: petSize, primaryVisible: mainVisible)
        XCTAssertEqual(f, stored)
    }

    func testRestore_anchorScreenGone_fallsBackToBottomRight() {
        // Stored at x=4000 on a screen that no longer exists (anchorVisible = nil).
        let stored = CGRect(x: 4000, y: 500, width: 280, height: 300)
        let f = PetFramePlanner.restore(storedFrame: stored, anchorVisible: nil,
                                        fallbackSize: petSize, primaryVisible: mainVisible)
        XCTAssertEqual(f.maxX, mainVisible.maxX - 8, accuracy: 0.001)
        XCTAssertEqual(f.minY, 8, accuracy: 0.001)
    }

    func testRestore_noStorage_fallsBackToBottomRight() {
        let f = PetFramePlanner.restore(storedFrame: nil, anchorVisible: nil,
                                        fallbackSize: petSize, primaryVisible: mainVisible)
        XCTAssertEqual(f.maxX, mainVisible.maxX - 8, accuracy: 0.001)
    }

    func testRestore_storedFrameOutsideAllScreens_fallsBack() {
        // Stored frame is valid CGRect but sits entirely off its anchor screen.
        let stored = CGRect(x: -5000, y: -5000, width: 280, height: 300)
        let f = PetFramePlanner.restore(storedFrame: stored, anchorVisible: mainVisible,
                                        fallbackSize: petSize, primaryVisible: mainVisible)
        XCTAssertEqual(f.maxX, mainVisible.maxX - 8, accuracy: 0.001)
    }

    // MARK: frame encode/decode

    func testFrameCoding_roundTrip() {
        let f = CGRect(x: 12.5, y: 34, width: 280, height: 300)
        let encoded = PetFramePlanner.encode(f)
        XCTAssertEqual(PetFramePlanner.decode(encoded), f)
    }

    func testFrameCoding_rejectsGarbageString() {
        XCTAssertNil(PetFramePlanner.decode("not,a,frame"))
        XCTAssertNil(PetFramePlanner.decode("1,2,3"))
        XCTAssertNil(PetFramePlanner.decode("1,2,3,-4"))       // parses fine, negative size
        XCTAssertNil(PetFramePlanner.decode("0,0,nan,300"))    // Double("nan") parses; isValid must catch it
    }
}
