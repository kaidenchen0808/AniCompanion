import Foundation
import os

/// Kokoro 中文声线（sherpa-onnx generate 的 sid，顺序与官方 kokoro speaker 表一致：
/// 0-3 女声 xiaobei/xiaoni/xiaoxiao/xiaoyi，4-7 男声 yunjian/yunxi/yunxia/yunyang）。
/// 显示名走 xcstrings（en 源），rawValue 即持久化值。
enum KokoroVoice: String, CaseIterable, Identifiable, Sendable {
    case xiaobei = "zf_xiaobei"
    case xiaoni = "zf_xiaoni"
    case xiaoxiao = "zf_xiaoxiao"
    case xiaoyi = "zf_xiaoyi"
    case yunjian = "zm_yunjian"
    case yunxi = "zm_yunxi"
    case yunxia = "zm_yunxia"
    case yunyang = "zm_yunyang"

    static let `default`: KokoroVoice = .xiaoni

    var id: String { rawValue }

    /// Speaker id for `SherpaOnnxEngine.generate(text:sid:)` — the index in
    /// `allCases`, matching the official kokoro speaker ordering.
    var sid: Int32 { Int32(KokoroVoice.allCases.firstIndex(of: self)!) }

    /// Localized at the call site (`String(localized:)`, not a raw literal) because the
    /// Picker renders `Text(option.displayName)` — a plain String wouldn't hit xcstrings.
    /// En falls back to the key itself; zh-Hant translations live in Localizable.xcstrings.
    var displayName: String {
        switch self {
        case .xiaobei: return String(localized: "Xiaobei", comment: "Kokoro voice: female")
        case .xiaoni: return String(localized: "Xiaoni (gentle)", comment: "Kokoro voice: female, gentle (the default)")
        case .xiaoxiao: return String(localized: "Xiaoxiao", comment: "Kokoro voice: female")
        case .xiaoyi: return String(localized: "Xiaoyi", comment: "Kokoro voice: female")
        case .yunjian: return String(localized: "Yunjian", comment: "Kokoro voice: male")
        case .yunxi: return String(localized: "Yunxi", comment: "Kokoro voice: male")
        case .yunxia: return String(localized: "Yunxia", comment: "Kokoro voice: male")
        case .yunyang: return String(localized: "Yunyang", comment: "Kokoro voice: male")
        }
    }
}

/// float32 PCM → 16-bit mono WAV（44 字节头手写，零依赖）。
/// 样本截断到 [-1, 1] 防 int16 回绕（±2.0 若直接乘 32767 会绕回错值）。
enum KokoroWAV {

    /// - Parameters:
    ///   - samples: float32 mono samples, nominally in [-1, 1] (clamped if not).
    ///   - sampleRate: output sample rate in Hz (e.g. 24000 from the kokoro model).
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2   // 16-bit = 2 bytes per sample
        var data = Data(capacity: 44 + dataBytes)

        func appendASCII(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendLE16(_ v: UInt16) {
            data.append(UInt8(v & 0xff))
            data.append(UInt8((v >> 8) & 0xff))
        }
        func appendLE32(_ v: UInt32) {
            data.append(UInt8(v & 0xff))
            data.append(UInt8((v >> 8) & 0xff))
            data.append(UInt8((v >> 16) & 0xff))
            data.append(UInt8((v >> 24) & 0xff))
        }

        // RIFF chunk: "RIFF" + chunk size (everything after this field) + "WAVE"
        appendASCII("RIFF")
        appendLE32(UInt32(36 + dataBytes))
        appendASCII("WAVE")

        // fmt subchunk: PCM(1), mono, sampleRate, byteRate = sr * 1ch * 2B,
        // blockAlign = 1ch * 2B, bitsPerSample = 16
        appendASCII("fmt ")
        appendLE32(16)
        appendLE16(1)
        appendLE16(1)
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 2))
        appendLE16(2)
        appendLE16(16)

        // data subchunk: clamp(-1, 1) * 32767 → Int16 little-endian
        appendASCII("data")
        appendLE32(UInt32(dataBytes))
        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            appendLE16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}

/// TTS provider `.kokoro` — on-device neural TTS via sherpa-onnx. Same contract shape as
/// `AppleTTSService`: one WAV yield per sentence. The engine is created lazily on first
/// synthesis (1-3s model load) and kept alive for the service lifetime; synthesis itself
/// runs off the main actor (the C call is synchronous and CPU-bound).
final class KokoroTTSService: TTSServiceProtocol, Sendable {

    private let config: SherpaOnnxEngine.Config
    private let voice: KokoroVoice

    /// Lazily-created engine box. `OSAllocatedUnfairLock` is Sendable when its state is;
    /// `SherpaOnnxEngine` is `@unchecked Sendable` (internal NSLock), so the service itself
    /// needs no unchecked conformance. The lock also guarantees create-exactly-once across
    /// concurrent syntheses — a failed creation caches the inert shell (its `isLoaded`
    /// stays false), so a broken pack fails fast on every sentence instead of re-loading.
    private let engine = OSAllocatedUnfairLock<SherpaOnnxEngine?>(initialState: nil)

    /// - Parameter voicepackDirectory: the `…/Voicepack/kokoro` directory (from
    ///   `VoicepackStore.kokoroDirectory`), containing model.int8.onnx, tokens.txt,
    ///   voices.bin, lexicon-zh.txt, lexicon-us-en.txt and espeak-ng-data/.
    init(voicepackDirectory: URL, voice: KokoroVoice) {
        let dir = voicepackDirectory
        self.config = SherpaOnnxEngine.Config(
            modelPath: dir.appendingPathComponent("model.int8.onnx").path,
            voicesPath: dir.appendingPathComponent("voices.bin").path,
            tokensPath: dir.appendingPathComponent("tokens.txt").path,
            dataDir: dir.appendingPathComponent("espeak-ng-data").path,
            lexiconPaths: [
                dir.appendingPathComponent("lexicon-zh.txt").path,
                dir.appendingPathComponent("lexicon-us-en.txt").path,
            ].joined(separator: ","),
            numThreads: 2
        )
        self.voice = voice
    }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        // Kokoro is a single-voice neural model with no emotion input (unlike Apple's
        // pitchMultiplier or MiniMax's timber_weights) — `emotion` is accepted for
        // protocol symmetry and deliberately ignored.
        let voice = self.voice
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }
                    try Task.checkCancellation()

                    guard let engine = self.ensureEngine() else {
                        continuation.finish(throwing: TTSError.decodingError("Kokoro engine not available."))
                        return
                    }
                    try Task.checkCancellation()

                    guard let (samples, sampleRate) = engine.generate(text: trimmed, sid: voice.sid),
                          !samples.isEmpty else {
                        continuation.finish(throwing: TTSError.decodingError("Kokoro produced no audio."))
                        return
                    }
                    try Task.checkCancellation()

                    continuation.yield(KokoroWAV.encode(samples: samples, sampleRate: sampleRate))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Returns the shared engine if it loaded successfully, creating it on first call.
    /// Nil = the pack is broken/missing: every synthesis then fails with the same
    /// "engine not available" error (AppState's not-installed fallback usually prevents
    /// this path, but a hand-deleted model file after service creation still lands here).
    private func ensureEngine() -> SherpaOnnxEngine? {
        engine.withLock { box in
            if let box { return box.isLoaded ? box : nil }
            let created = SherpaOnnxEngine(config: config)
            box = created
            return created.isLoaded ? created : nil
        }
    }
}
