import XCTest
@testable import AniCompanion

final class KokoroWAVTests: XCTestCase {

    func testWAVHeader_fields() {
        let wav = KokoroWAV.encode(samples: [0, 0.5, -0.5, 0], sampleRate: 24000)
        let b = [UInt8](wav)
        XCTAssertEqual(String(bytes: b[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: b[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: b[36..<40], encoding: .ascii), "data")
        // RIFF chunk size = 36 + data bytes; data = 4 samples × 2 bytes
        let riffSize = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        XCTAssertEqual(Int(riffSize), 36 + 8)
        let sr = UInt32(b[24]) | UInt32(b[25]) << 8
        XCTAssertEqual(Int(sr), 24000)
        XCTAssertEqual(wav.count, 44 + 8)
    }

    func testWAV_clampsOutOfRangeSamples() {
        // ±超出 [-1, 1] 的 float 必须截断到 int16 范围而不是回绕
        let wav = KokoroWAV.encode(samples: [2.0, -2.0], sampleRate: 24000)
        let b = [UInt8](wav)
        let first = Int16(b[44]) | Int16(b[45]) << 8
        XCTAssertEqual(first, Int16.max)
    }

    func testVoiceCatalog_completeness() {
        XCTAssertEqual(KokoroVoice.allCases.count, 8)
        XCTAssertEqual(KokoroVoice.default, .xiaoni)
        // sid = allCases 索引：与官方 kokoro speaker 顺序一致
        XCTAssertEqual(KokoroVoice.xiaoni.sid, 1)
        XCTAssertEqual(KokoroVoice.yunyang.sid, 7)
        XCTAssertEqual(Set(KokoroVoice.allCases.map(\.rawValue)),
                       ["zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
                        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"])
    }
}
