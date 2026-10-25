import Foundation
import sherpa_onnx

/// The only layer that touches the sherpa-onnx C API (v1.13.8, CamelCase API).
/// Owns the offline-tts handle (created at init, torn down on deinit).
///
/// Thread-safety: a single NSLock serializes generation — the pipeline is
/// inherently sentence-serial. `@unchecked Sendable` because all mutable state
/// (`handle` after init) is guarded by that lock.
final class SherpaOnnxEngine: @unchecked Sendable {
    /// Field names mirror `SherpaOnnxOfflineTtsKokoroModelConfig` in
    /// `Libraries/sherpa-onnx/c-api.h` — do not invent fields; keep in sync
    /// with the vendored header when bumping the sherpa-onnx release.
    struct Config {
        /// Path to the Kokoro model (e.g. …/Voicepack/kokoro/model.int8.onnx).
        let modelPath: String
        /// Path to the speaker embeddings file (voices.bin, kokoro >= 1.0).
        let voicesPath: String
        /// Path to tokens.txt.
        let tokensPath: String
        /// Path to the espeak-ng-data directory (phonemization; validated by
        /// phontab/phonindex/phondata/intonations presence).
        let dataDir: String
        /// Optional comma-separated lexicon files (kokoro >= 1.0 multi-lang).
        var lexiconPaths: String?
        /// Optional language hint for kokoro >= 1.0 (e.g. "zh", "en").
        var lang: String?
        /// Backend threads.
        var numThreads: Int = 2
        /// Speech rate scale (> 1 slower, < 1 faster). (The vendored header's comment at
        /// c-api.h:2306 says the opposite — it is inverted; upstream semantics are larger → slower.)
        var lengthScale: Float = 1.0
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?

    /// Creates the engine; on any config/model error the C API returns NULL
    /// and `isLoaded` stays false (the engine is then an inert shell).
    init(config: Config) {
        var c = SherpaOnnxOfflineTtsConfig()
        // strdup'd strings: the C API copies them into std::string during
        // SherpaOnnxCreateOfflineTts, so free them right after the call.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func dup(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        c.model.num_threads = Int32(config.numThreads)
        c.model.debug = 0
        c.model.provider = dup("cpu")
        c.model.kokoro.model = dup(config.modelPath)
        c.model.kokoro.voices = dup(config.voicesPath)
        c.model.kokoro.tokens = dup(config.tokensPath)
        c.model.kokoro.data_dir = dup(config.dataDir)
        if let lexicon = config.lexiconPaths { c.model.kokoro.lexicon = dup(lexicon) }
        if let lang = config.lang { c.model.kokoro.lang = dup(lang) }
        c.model.kokoro.length_scale = config.lengthScale

        handle = SherpaOnnxCreateOfflineTts(&c)
        owned.forEach { free($0) }
    }

    deinit {
        if let handle { SherpaOnnxDestroyOfflineTts(handle) }
    }

    /// `handle` is immutable after init — safe to read unlocked.
    var isLoaded: Bool { handle != nil }

    /// Output sample rate in Hz (valid once loaded).
    var sampleRate: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        return Int(SherpaOnnxOfflineTtsSampleRate(handle))
    }

    /// Number of speaker ids the model exposes (valid once loaded).
    var numSpeakers: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        return Int(SherpaOnnxOfflineTtsNumSpeakers(handle))
    }

    /// Synthesizes `text` with speaker `sid`. Returns (float32 mono samples, sampleRate),
    /// or nil when the engine failed to load or generation errored.
    func generate(text: String, sid: Int32 = 0, speed: Float = 1.0) -> (samples: [Float], sampleRate: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        var cfg = SherpaOnnxGenerationConfig()
        cfg.sid = sid
        cfg.speed = speed
        guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(handle, text, &cfg, nil, nil) else {
            return nil
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let head = audio.pointee
        guard head.n > 0, let p = head.samples else { return nil }
        return (Array(UnsafeBufferPointer(start: p, count: Int(head.n))), Int(head.sample_rate))
    }
}
