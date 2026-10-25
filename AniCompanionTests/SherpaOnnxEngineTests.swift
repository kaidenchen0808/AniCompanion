import XCTest
@testable import AniCompanion

final class SherpaOnnxEngineTests: XCTestCase {
    func testEngine_withMissingModel_returnsNotLoaded() {
        let tmp = NSTemporaryDirectory() + "nope-\(UUID().uuidString)"
        let engine = SherpaOnnxEngine(config: .init(
            modelPath: tmp + "/model.int8.onnx",
            voicesPath: tmp + "/voices.bin",
            tokensPath: tmp + "/tokens.txt",
            dataDir: tmp + "/espeak-ng-data"))
        XCTAssertFalse(engine.isLoaded, "nonexistent model must fail to load — reaching here at all proves the dylib linked & loaded")
        XCTAssertNil(engine.sampleRate)
        XCTAssertNil(engine.generate(text: "hello"))
    }
}
