import XCTest
@testable import AniCompanion

final class VoicepackStoreTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @MainActor
    func testInstalled_requiresKeyFiles() throws {
        let store = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x", expectedSizeBytes: 1)
        XCTAssertFalse(store.isInstalled)
        let kokoro = tmp.appendingPathComponent("kokoro", isDirectory: true)
        try FileManager.default.createDirectory(at: kokoro.appendingPathComponent("espeak-ng-data"), withIntermediateDirectories: true)
        for f in ["model.int8.onnx", "tokens.txt", "voices.bin", "lexicon-zh.txt", "lexicon-us-en.txt"] {
            try Data([0]).write(to: kokoro.appendingPathComponent(f))
        }
        XCTAssertTrue(store.isInstalled)
        try FileManager.default.removeItem(at: kokoro.appendingPathComponent("tokens.txt"))
        XCTAssertFalse(store.isInstalled, "a hand-deleted key file must fall back to not-installed")
    }

    func testSHA256_ofKnownData() {
        XCTAssertEqual(VoicepackStore.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @MainActor
    func testManifest_roundTrip() throws {
        let store = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x", expectedSizeBytes: 1)
        try store.writeManifest(version: "v1")
        XCTAssertEqual(store.installedVersion, "v1")
    }

    @MainActor
    func testFreeSpace_needsTwoTimesPack() {
        let store = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x",
                                   expectedSizeBytes: 1_000_000, freeSpaceProvider: { 1_500_000 })
        XCTAssertFalse(store.hasEnoughFreeSpace, "needs strictly more than 2× the pack size")
        let plenty = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x",
                                    expectedSizeBytes: 1_000_000, freeSpaceProvider: { 10_000_000 })
        XCTAssertTrue(plenty.hasEnoughFreeSpace)
    }
}
