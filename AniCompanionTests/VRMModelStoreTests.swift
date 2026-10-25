import XCTest
@testable import AniCompanion

final class VRMModelStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRMStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A store whose user directory is the temp dir, so tests never touch the real
    /// Application Support folder.
    @MainActor
    private func makeStore() -> VRMModelStore {
        VRMModelStore(userDirectoryOverride: tempDir)
    }

    /// Minimal valid GLB: header + tiny JSON chunk (enough for discovery; title parsing
    /// tolerates missing VRM extensions by returning nil → filename stem is the display name).
    private func writeMinimalVRM(_ filename: String, in dir: URL? = nil) throws {
        let json = #"{"asset":{"version":"2.0"},"extensions":{}}"#
        let jsonData = Data(json.utf8)
        var glb = Data()
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])          // magic "glTF"
        glb.append(contentsOf: [2, 0, 0, 0])                      // version 2
        var total = UInt32(12 + 8 + jsonData.count).littleEndian
        withUnsafeBytes(of: &total) { glb.append(contentsOf: $0) }
        var jsonLen = UInt32(jsonData.count).littleEndian
        withUnsafeBytes(of: &jsonLen) { glb.append(contentsOf: $0) }
        glb.append(contentsOf: [0x4E, 0x4F, 0x53, 0x4A])          // chunk type "JSON"
        glb.append(jsonData)
        try glb.write(to: (dir ?? tempDir).appendingPathComponent(filename))
    }

    // MARK: delete

    @MainActor
    func testDelete_removesUserModel() throws {
        try writeMinimalVRM("Mine.vrm")
        let store = makeStore()
        XCTAssertTrue(try store.deleteModel(filename: "Mine.vrm"))
        XCTAssertFalse(store.availableModels().contains { $0.filename == "Mine.vrm" })
    }

    @MainActor
    func testDelete_missingFile_returnsFalse_noThrow() throws {
        let store = makeStore()
        XCTAssertFalse(try store.deleteModel(filename: "Ghost.vrm"))
    }

    @MainActor
    func testDelete_neverTouchesBundleModels() throws {
        // The store only ever looks in the user directory for deletes — a built-in filename
        // (not present in the injected dir) is a no-op false, never an error.
        let store = makeStore()
        XCTAssertFalse(try store.deleteModel(filename: VRMModelStore.defaultModelFilename))
    }

    // MARK: import (existing behavior, now under an injected dir)

    @MainActor
    func testImport_intoEmptyDir_thenNameCollisionGetsSuffix() throws {
        // The source must live OUTSIDE the injected user dir — a source inside it would occupy
        // "Src.vrm" itself, making even the first import collide with its own source file.
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRMStoreTests-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        try writeMinimalVRM("Src.vrm", in: srcDir)
        let src = srcDir.appendingPathComponent("Src.vrm")

        let store = makeStore()
        XCTAssertEqual(try store.importModel(from: src), "Src.vrm")
        XCTAssertEqual(try store.importModel(from: src), "Src 2.vrm")
        XCTAssertEqual(try store.importModel(from: src), "Src 3.vrm")
        XCTAssertEqual(store.availableModels().filter { $0.filename.hasPrefix("Src") }.count, 3)
    }
}
