# Kokoro 语音包（内置离线高音质 TTS）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 内置 sherpa-onnx + Kokoro 中文 int8 语音包：Settings 一键下载（GitHub Release，sha256 校验原子安装）→ 永久离线的 8 声线高音质 TTS，自动回落 Apple 保证永不哑。

**Architecture:** `TTSProvider` 加 `.kokoro` case（插件点现成）；`VoicepackStore`（下载/校验/ditto 解压/manifest，对标 VRMModelStore 注入先例）；`SherpaOnnxEngine`（唯一碰 C API 的层，官方预编译 dylib 入库）；`KokoroTTSService` 输出单-yield WAV 流（与 AppleTTSService 同形，唇形/AudioQueue 管线零改动）。

**Tech Stack:** Swift 6 / sherpa-onnx C API（预编译 dylib）/ CryptoKit / delegate-backed URLSession / Zero SPM（ditto 解压、手写 WAV 头）。

**设计文档:** 根仓库 `docs/plans/2026-10-25-kokoro-voicepack-design.md`。

**Worktree:** `/Users/chenxuewei/hb/anicompanion/.worktrees/kokoro-voicepack`，分支 `feature/kokoro-voicepack`，基线 `e0a1d05`。基线测试 21/21。

⚠️ **Task 1 实证的结构修正（v1.13.8，后续 task 必读）：**
- 选用 sherpa-onnx **v1.13.8**（v2.0 移除了内置音素化，中文文本合成不可用）；1.13 的 C 函数已是 **CamelCase**（`SherpaOnnxCreateOfflineTts` 等），Engine 已按实际头文件实现（用 `SherpaOnnxOfflineTtsGenerateWithConfig`）
- kokoro 配置用 **`voices`（voices.bin 单文件）**而非 voices_dir；另需 `lexicon`（zh + us-en 两份）与可选 `lang` 提示；`data_dir`（espeak-ng-data）仍必需
- **双 dylib 依赖**：libsherpa-onnx-c-api.dylib + libonnxruntime.dylib 都已 vendor 进 `Libraries/sherpa-onnx/` 并 embed（project.yml 写法：target `dependencies: - framework: <path> + embed: true`，每 dylib 一条；主 sources excludes 加 `"Libraries/**"`；`LIBRARY_SEARCH_PATHS` + 双 target 的 `SWIFT_INCLUDE_PATHS`）
- **voicepack 关键文件因此定为**：`model.int8.onnx + tokens.txt + voices.bin + lexicon-zh.txt + lexicon-us-en.txt(可选) + espeak-ng-data/`（Task 2 的 isInstalled 按此校验；Task 3 声线 = generate 的 sid 0-7，顺序 xiaobei/xiaoni/xiaoxiao/xiaoyi/yunjian/yunxi/yunxia/yunyang）

⚠️ **已知陷阱（前次执行实证）：**
- 新增 `.swift` 文件后必须 `xcodegen generate`（sources 是 generate 时快照，否则测试静默缺席假绿灯）；改 `project.yml` 后同样要 generate
- 终端访问 GitHub 需显式代理：`export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897`
- xcstrings 编辑用**文本级插入**（python json.dump 会全文件重排）；测试输出 grep 用 `Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)`（系统日志有 "error:" 噪声）
- TTSServiceProtocol 是 `synthesize(text:emotion:) -> AsyncThrowingStream<Data, Error>`（流式）——Kokoro 单次 yield 完整 WAV + finish（照抄 AppleTTSService.swift:42-75 的 continuation 模式）
- UI/AppKit 层无单测，靠 manual checklist；纯逻辑（Store/WAV/映射表）全单测

---

### Task 1: sherpa-onnx dylib 接入 + C API 桥接最小验证

**Files:**
- Create: `AniCompanion/Libraries/sherpa-onnx/`（dylib + header + modulemap，二进制入库）
- Modify: `project.yml`
- Create: `AniCompanion/Services/SherpaOnnxEngine.swift`（最小骨架）
- Create: `AniCompanionTests/SherpaOnnxEngineTests.swift`

**Step 1: 获取官方预编译产物**（终端挂代理）

```bash
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
# 找最新 osx asset（名如 sherpa-onnx-vX.Y.Z-osx.tar.bz2）
gh release view --repo k2-fsa/sherpa-onnx --json assets -q '.assets[].name' | grep osx
gh release download <tag> --repo k2-fsa/sherpa-onnx --pattern '*osx*' --dir /tmp/sherpa
tar xf /tmp/sherpa/sherpa-onnx-*-osx.tar.bz2 -C /tmp/sherpa
# dylib 与 header 就位（路径在解包内找 lib/libsherpa-onnx-c-api.dylib 与 include/sherpa-onnx/c-api/）
mkdir -p AniCompanion/Libraries/sherpa-onnx
cp <解包>/lib/libsherpa-onnx-c-api.dylib AniCompanion/Libraries/sherpa-onnx/
cp <解包>/include/sherpa-onnx/c-api/sherpa-onnx-c-api.h AniCompanion/Libraries/sherpa-onnx/
```

**Step 2: modulemap**

`AniCompanion/Libraries/sherpa-onnx/module.modulemap`：

```
module sherpa_onnx {
    header "sherpa-onnx-c-api.h"
    link "sherpa-onnx-c-api"
    export *
}
```

**Step 3: project.yml**（target `AniCompanion` 的 sources 追加 + settings）

```yaml
      # sherpa-onnx C API dynamic library (embedded)
      - path: AniCompanion/Libraries/sherpa-onnx/libsherpa-onnx-c-api.dylib
```

settings.base 加：`SWIFT_INCLUDE_PATHS: AniCompanion/Libraries/sherpa-onnx`

改完 `xcodegen generate`，然后**验证 pbxproj**：dylib 进了 PBXBuildFile 且有 Embed Frameworks（Embed Dylib）阶段；若 XcodeGen 未自动 embed，在 dylib 条目加 `buildPhase: none` 并手补——以 `xcodebuild build` 产物里 `AniCompanion.app/Contents/Frameworks/libsherpa-onnx-c-api.dylib` 存在为准。

**Step 4: Engine 最小骨架**

`SherpaOnnxEngine.swift`：

```swift
import Foundation
import sherpa_onnx

/// The only layer that touches the sherpa-onnx C API. Owns the offline-tts handle
/// (created lazily on first synthesis, torn down on deinit). Thread-safety: a single
/// `NSLock` serializes generation — the pipeline is inherently sentence-serial.
final class SherpaOnnxEngine: @unchecked Sendable {
    struct Config {
        let modelPath: String      // …/Voicepack/kokoro/model.int8.onnx
        let tokensPath: String     // …/tokens.txt
        let voicesDir: String      // …/voices
        let dataDir: String        // …/espeak-ng-data
        let numThreads: Int = 2
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(config: Config) {
        var c = sherpa_onnx_offline_tts_config_t()
        c.model.num_threads = Int32(config.numThreads)
        c.model.debug = 0
        c.model.provider = strdup("cpu")
        c.model.kokoro.model = strdup(config.modelPath)
        c.model.kokoro.voices_dir = strdup(config.voicesDir)
        c.model.kokoro.tokens = strdup(config.tokensPath)
        c.model.kokoro.data_dir = strdup(config.dataDir)
        c.model.kokoro.length_scale = 1.0
        handle = sherpa_onnx_offline_tts_create(c)
        // NOTE: config 字段名以打包的 c-api.h 为准（kokoro 子结构自 v1.10 起存在）；
        // 编译报字段不存在时读头文件核对并调整——不要发明字段。
    }
    deinit { if let handle { sherpa_onnx_offline_tts_destroy(handle) } }

    var isLoaded: Bool { handle != nil }

    /// sid = voice id（见 KokoroVoice 映射表）。返回 (samples float32, sampleRate)。
    func generate(text: String, sid: Int32, speed: Float = 1.0) -> (samples: [Float], sampleRate: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        let audio = sherpa_onnx_offline_tts_generate(handle, text, sid, speed)
        defer { sherpa_onnx_offline_tts_free_generated_audio(audio) }
        guard audio.n > 0, let p = audio.samples else { return nil }
        let out = UnsafeBufferPointer(start: p, count: Int(audio.n))
        return (Array(out), Int(audio.sample_rate))
    }
}
```

**Step 5: 冒烟单测**（证明 dylib 真加载、符号真链接——用失败路径）

`SherpaOnnxEngineTests.swift`：

```swift
import XCTest
@testable import AniCompanion

final class SherpaOnnxEngineTests: XCTestCase {
    func testEngine_withMissingModel_returnsNotLoaded() {
        let tmp = NSTemporaryDirectory() + "nope-\(UUID().uuidString)"
        let engine = SherpaOnnxEngine(config: .init(
            modelPath: tmp + "/model.int8.onnx",
            tokensPath: tmp + "/tokens.txt",
            voicesDir: tmp + "/voices",
            dataDir: tmp + "/espeak-ng-data"))
        XCTAssertFalse(engine.isLoaded, "a nonexistent model must fail to load — and getting here at all proves the dylib linked")
    }
}
```

**Step 6: `xcodegen generate && xcodebuild test`** — 22 tests 0 failures。

**Step 7: Commit** — `feat: link sherpa-onnx c-api dylib + engine skeleton`（含二进制 dylib/header，`.gitignore` 若挡了 `*.dylib` 就加例外）。

---

### Task 2: VoicepackStore（下载/校验/解压/清单）+ 单测

**Files:**
- Create: `AniCompanion/Services/VoicepackStore.swift`
- Create: `AniCompanionTests/VoicepackStoreTests.swift`

**Step 1: 失败测试先写**（新文件后 xcodegen）：

```swift
import XCTest
@testable import AniCompanion

final class VoicepackStoreTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws { tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VP-\(UUID())"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testInstalled_requiresKeyFiles() throws {
        let store = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x", expectedSizeBytes: 1)
        XCTAssertFalse(store.isInstalled)
        let kokoro = tmp.appendingPathComponent("kokoro", isDirectory: true)
        try FileManager.default.createDirectory(at: kokoro.appendingPathComponent("voices"), withIntermediateDirectories: true)
        for f in ["model.int8.onnx", "tokens.txt", "espeak-ng-data"] { try Data([0]).write(to: kokoro.appendingPathComponent(f)) }
        try Data([0]).write(to: kokoro.appendingPathComponent("voices/zf_xiaoni.bin"))
        XCTAssertTrue(store.isInstalled)
        try FileManager.default.removeItem(at: kokoro.appendingPathComponent("tokens.txt"))
        XCTAssertFalse(store.isInstalled, "a hand-deleted key file must fall back to not-installed")
    }

    func testSHA256_ofKnownData() {
        XCTAssertEqual(VoicepackStore.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testManifest_roundTrip() throws {
        let store = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x", expectedSizeBytes: 1)
        try store.writeManifest(version: "v1")
        XCTAssertEqual(store.installedVersion, "v1")
    }

    func testHasFreeSpace_injectable() {
        // free-space check takes a closure so tests don't depend on the real disk
        let tiny = VoicepackStore(directoryOverride: tmp, expectedSHA256: "x", expectedSizeBytes: 1_000_000, freeSpaceProvider: { 500_000 })
        XCTAssertFalse(tiny.hasEnoughFreeSpace)   // needs 2×
    }
}
```

**Step 2: 实现**（要点，TDD 让测试过）：

```swift
import Foundation
import CryptoKit
import Combine

/// Owns the Kokoro voicepack on disk: …/Voicepack/kokoro/{model.int8.onnx, tokens.txt,
/// voices/*.bin, espeak-ng-data/, manifest.json}. Install = preflight → download(tmp) →
/// sha256 verify → ditto unzip(staging) → atomic replace. A failure at any step cleans
/// its temp artifacts — never a half-installed pack. `state` is published so Settings
/// can observe progress across window close/reopen.
@MainActor
final class VoicepackStore: ObservableObject {
    static let shared = VoicepackStore()
    enum State: Equatable { case idle, downloading(Double), installed, failed(String) }
    @Published private(set) var state: State = .idle   // .installed iff isInstalled

    // 常量：asset 名/URL/sha256/size —— make-voicepack.sh 发布时更新这里的硬编码
    // （releaseURL 指向 catsmice/AniCompanion 的 Release；版本随 manifest 走）
    static let releaseAssetURL = URL(string: "https://github.com/catsmice/AniCompanion/releases/download/voicepack-kokoro-v1/kokoro-zh-v1.zip")!
    static let expectedSHA256 = "<发布时填入>"     // Task 5 发布后回填
    static let expectedSizeBytes: Int64 = 150_000_000   // 预估值，发布时校准

    let rootDirectory: URL        // override ?tmp : …/Application Support/AniCompanion/Voicepack
    var kokoroDirectory: URL { rootDirectory.appendingPathComponent("kokoro", isDirectory: true) }
    private let expectedSHA256Hex: String
    private let expectedSize: Int64
    private let freeSpaceProvider: () -> Int64
    private var downloadTask: Task<Void, Never>?

    init(directoryOverride: URL? = nil, expectedSHA256: String = VoicepackStore.expectedSHA256,
         expectedSizeBytes: Int64 = VoicepackStore.expectedSizeBytes,
         freeSpaceProvider: @escaping () -> Int64 = { VoicepackStore.volumeFreeSpace() }) { … }

    var isInstalled: Bool { key files all exist（model.int8.onnx、tokens.txt、voices/ 目录非空、espeak-ng-data） }
    var installedVersion: String? { manifest.json 读 version }
    var hasEnoughFreeSpace: Bool { freeSpaceProvider() > expectedSize * 2 }

    @MainActor func install() {
        guard !isInstalled, downloadTask == nil else { return }   // 防重入
        state = .downloading(0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.runInstall(); self.state = .installed }
            catch { self.state = .failed(error.localizedDescription); self.cleanupTemps() }
            self?.downloadTask = nil   // 按 MainActor 实际写法调整
        }
    }
    // runInstall：URLSession.download(from:) + delegate 进度（del
    // egate-backed session，didWriteData → state = .downloading(fraction)）；
    // sha256Hex(of:) == expectedSHA256 否则 throw VoicepackError.checksumMismatch；
    // Process(/usr/bin/ditto -x -k zip staging) terminationStatus != 0 throw；
    // FileManager.replaceItem(staging/kokoro → kokoroDirectory)；writeManifest(version:)。
    static func sha256Hex(of data: Data) -> String { SHA256.hash(data:).map { String(format: "%02x", $0) }.joined() }
    enum VoicepackError: LocalizedError { case checksumMismatch, unzipFailed, insufficientDiskSpace /* errorDescription 走 String(localized:) */ }
}
```

**Step 3-5:** xcodegen → 测试过（25 tests）→ commit `feat: VoicepackStore — download/verify/unpack/manifest`。

---

### Task 3: WAV 封装 + KokoroTTSService + TTSProvider case

**Files:**
- Create: `AniCompanion/Services/KokoroTTSService.swift`
- Create: `AniCompanionTests/KokoroWAVTests.swift`
- Modify: `AniCompanion/Services/TTSProvider.swift`
- Modify: `AniCompanion/App/AppState.swift`

**Step 1: WAV 封装单测（纯函数先行）**

`KokoroWAVTests.swift`：

```swift
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
        // sample rate little-endian at offset 24
        let sr = UInt32(b[24]) | UInt32(b[25]) << 8
        XCTAssertEqual(Int(sr), 24000)
        XCTAssertEqual(wav.count, 44 + 8)
    }
    func testVoiceCatalog_completeness() {
        XCTAssertEqual(KokoroVoice.allCases.count, 8)
        XCTAssertEqual(KokoroVoice.default, .xiaoni)
        XCTAssertSetEqualIds  // zf_xiaobei/zf_xiaoni/zf_xiaoxiao/zf_xiaoyi/zm_yunjian/zm_yunxi/zm_yunxia/zm_yunyang
    }
}
```

**Step 2: 实现**

`KokoroTTSService.swift`：

```swift
import Foundation

/// Kokoro 中文声线（sherpa-onnx generate 的 sid 顺序，与 voices 目录内 .bin 排序一致——
/// 以 dist 的 README/voices 目录实际文件名核对 sid 映射，实现时用官方对照表校准）。
enum KokoroVoice: String, CaseIterable, Identifiable {
    case xiaobei = "zf_xiaobei", xiaoni = "zf_xiaoni", xiaoxiao = "zf_xiaoxiao", xiaoyi = "zf_xiaoyi"
    case yunjian = "zm_yunjian", yunxi = "zm_yunxi", yunxia = "zm_yunxia", yunyang = "zm_yunyang"
    static let `default`: KokoroVoice = .xiaoni
    var id: String { rawValue }
    var sid: Int32 { Int32(KokoroVoice.allCases.firstIndex(of: self)!) }
    var displayName: String {   // 本地化友好名（zh-Hant 由 xcstrings 提供）
        switch self { case .xiaobei: return "Xiaobei"; case .xiaoni: return "Xiaoni (gentle)"; … }
    }
}

/// float32 PCM → 16-bit mono WAV（44 字节头手写，零依赖）。
enum KokoroWAV {
    static func encode(samples: [Float], sampleRate: Int) -> Data { … }
}

/// TTS provider `.kokoro` — on-device neural TTS via sherpa-onnx. Same contract shape as
/// AppleTTSService: one WAV yield per sentence. Engine is created lazily on first use
/// (1-3s model load) and kept for the service lifetime; synthesis runs off the main actor.
final class KokoroTTSService: TTSServiceProtocol, Sendable {
    private let voicepackDir: URL
    private let voice: KokoroVoice
    private let engineBox: OSAllocatedUnfairLock<SherpaOnnxEngine?> = .init(initialState: nil)  // 或 NSLock+class box，沿项目风格

    init(voicepackDir: URL, voice: KokoroVoice) { … }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [voicepackDir, voice] in
                do {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw TTSError.emptyText }
                    // lazy engine create（box 内一次）；isLoaded == false → TTSError.decodingError
                    guard let (samples, rate) = engine.generate(text: trimmed, sid: voice.sid) else {
                        throw TTSError.decodingError("Kokoro produced no audio.")
                    }
                    continuation.yield(KokoroWAV.encode(samples: samples, sampleRate: rate))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

`TTSProvider.swift` 加 case `kokoro` + displayName `"Kokoro (on-device, HQ)"`。
`AppState.swift`：`@AppStorage("tts_kokoro_voice") var kokoroVoice: String = KokoroVoice.default.rawValue`；`makeTTSService()` 加分支：

```swift
case .kokoro:
    let dir = VoicepackStore.shared.kokoroDirectory
    guard VoicepackStore.shared.isInstalled else { fallthrough }   // 未安装回落 Apple
    return KokoroTTSService(voicepackDir: dir,
                            voice: KokoroVoice(rawValue: kokoroVoice) ?? .default)
```

（`makeTTSService` 是普通 switch，fallthrough 到 apple 分支——按实际结构写。）

**Step 3-5:** xcodegen → 28 tests（25+3，WAV 两测 + catalog 一测，数字以实际为准）→ commit `feat: KokoroTTSService + WAV encoder + provider case`。

---

### Task 4: Settings Voice 区三态 UI + 下载闭环 + 试听

**Files:**
- Modify: `AniCompanion/Views/SettingsView.swift`
- Modify: `AniCompanion/App/AppState.swift`（若 load/save 需要新字段接线）

**要点（锚点式指令）：**

1. `@State private var ttsProvider` 不变；Voice 区 `switch ttsProvider`（:234）加 `.kokoro` 分支：
   - `VoicepackCard` 新私有视图（`@ObservedObject var store: VoicepackStore`）按 `store.state` 三态：未安装 → 说明行（`Text("Gentle voicepack · ~150MB · download once, offline forever")` 风格）+ Download 按钮（调 `store.install()`）+ 免费磁盘不足时禁用并提示；downloading → `ProgressView(value:)` + 百分比 + Cancel（`downloadTask` 暴露 cancel 或跳过 Cancel，YAGNI 可不做）；installed → 声线 Picker（`ForEach(KokoroVoice.allCases)` displayName）绑定本地 `@State kokoroVoice`；failed → 错误行 + 重试按钮
   - loadSettings 读 `appState.kokoroVoice`；saveSettings 写回 + 若 provider 为 kokoro 且 store 未安装则自动回落 `.apple` 再 reinit（防哑）
2. **下载闭环**：state 变 `.installed` 时（`.onChange(of: store.state)`）自动 `ttsProvider = .kokoro` + 触发一次试听（复用现有 `testVoice()` 路径，:921 的 switch 加 `.kokoro` case 构造 service）
3. 试听文案固定一句：`String(localized:)` 例 "主人，我的新声音好听吗？"（en 源：`Hi! This is my new voice.`，zh-Hant 翻译）
4. 全部新字符串 `Text()`/`String(localized:)`；UI 无单测，构建 + 既有 28 测试不回归

**Commit:** `feat: voicepack download UI + voice picker + auto-listen on install`。

---

### Task 5: make-voicepack.sh 发布脚本 + zh-Hant 本地化

**Files:**
- Create: `scripts/make-voicepack.sh`
- Modify: `AniCompanion/Resources/Localizable.xcstrings`

**脚本要点：** 挂代理提示注释 → 下载 sherpa-onnx kokoro dist（`kokoro-multi-lang-v1_1` 或中文专用包，与 Task 1 同源 release）→ 取 `model.int8.onnx + tokens.txt + voices/ + espeak-ng-data/` → `zip -r kokoro-zh-v1.zip` → `shasum -a 256` → `gh release create voicepack-kokoro-v1 kokoro-zh-v1.zip kokoro-zh-v1.zip.sha256`（存在则 `gh release upload --clobber`）→ **打印需要回填 `VoicepackStore.expectedSHA256/expectedSizeBytes` 的值**（产品主人执行；回填后一次小 commit）。

**本地化：** 沿上次流程——收集本计划全部新 key（provider 名、voicepack 卡片文案、声线名、试听句、错误文案），文本级 python 插入 zh-Hant（幂等，保留 Xcode JSON 风格）。翻译表写在脚本 dict 里（en → zh-Hant），至少覆盖：Kokoro (on-device, HQ)、Xiaobei/Xiaoni (gentle)/…、voicepack 说明/下载按钮/下载中/失败重试/磁盘不足、试听句、checksum/unzip 错误文案。

**Commit:** `feat: voicepack release script + zh-Hant strings`。

---

### Task 6: CLAUDE.md + manual checklist

- Tech Stack 的 TTS 行加 Kokoro；Settings 清单 TTS Provider 加 Kokoro 条目（voicepack 三态、8 声线、未安装回落）；Gotchas 补：**dylib embed + SWIFT_INCLUDE_PATHS**（若 Task 1 有额外坑照实记）；Status 更新
- 计划文档文末附 manual checklist（见下）

**Commit:** `docs: kokoro voicepack in CLAUDE.md`。

---

## Manual Checklist（产品主人执行；前置：跑 `scripts/make-voicepack.sh` 发布 Release 并回填 sha256/size）

- [ ] Settings → TTS Provider 选 Kokoro → 显示语音包卡片（体积说明）
- [ ] 点 Download → 进度条推进 → 完成后自动切 Kokoro + 自动听到试听句（新声线）
- [ ] 声线下拉 8 项，切换后试听各不相同；小妮为默认
- [ ] 与她对话 → Kokoro 语音自然有抑扬（对比 Apple 明显改善）、唇形同步正常
- [ ] 下载中途断网 → 错误提示 + 重试可完成
- [ ] 删除 `…/Voicepack/kokoro/tokens.txt` → Settings 回到"未安装"态；聊天仍出声（回落 Apple）
- [ ] provider 在 Apple ↔ Kokoro ↔ 其他间来回切换 Save，无崩溃无残留
- [ ] 静隐模式下她不发声（Kokoro 抑制路径同通知抑制）
- [ ] 首句延迟可接受（模型加载后 <1s/句）
- [ ] zh-Hant 界面全部新文案为繁体；en 界面为英文
- [ ] 全量单测通过（最终以实际数量为准，基线 21 + 新增）
