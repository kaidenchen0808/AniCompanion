# 右键菜单 + 桌宠工坊 + 显示模式（陪伴/静隐）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 桌宠右键弹 NSMenu（静隐切换 / 工坊 / 设置 / 退出）；静隐 = 缩小半透明驻留右下角不说话；工坊独立窗口管理 VRM 模型（导入/切换/删除）；SettingsView 新增「Mode」「About」两区、Character 区改为跳转工坊。

**Architecture:** 全部改动在渲染端 Swift 层。新增 `DisplayMode` 状态（`AppState.displayMode` @Published，`AppDelegate` sink 应用窗口形态，沿 `petMode` 的现成模式）；右键菜单挂 `PetDragView.rightMouseDown` → AppKit `NSMenu`（桌宠模式无 SwiftUI 树）；工坊是 AppDelegate 手工创建的 `NSWindow` + `NSHostingController(WorkshopView)`（pet 模式会拆掉 MainView，SwiftUI `openWindow` 无锚点，手工窗口与主窗口同一套路）；模型发现/导入复用 `VRMModelStore`，只新增 `deleteModel` + 可注入目录（测试用）。

**Tech Stack:** Swift 6 / AppKit NSMenu + NSWindow / SwiftUI / XcodeGen（`project.yml` 是工程唯一真源，`.xcodeproj` 不入库）/ XCTest / String Catalog（`Localizable.xcstrings`）。

⚠️ **XcodeGen 陷阱（Task 1 实测确认）**：target sources 是 generate 时的**快照展开**，不是运行时通配。**每新增一个 `.swift` 文件后必须重跑 `xcodegen generate`**，否则新文件静默不进 target——`xcodebuild test` 依旧全绿但新测试缺席（假绿灯）。`project.yml` 本身无需改动，重跑 generate 零 git 影响（pbxproj 被 ignore）。

**设计文档:** 根仓库 `docs/plans/2026-10-25-rightclick-workshop-design.md`（需求背景与决策记录）。

**Worktree:** `/Users/chenxuewei/hb/anicompanion/.worktrees/rightclick-workshop`，分支 `feature/rightclick-workshop`。所有命令在此目录执行。

**与设计文档的一处偏差（已论证）:** 设计稿原写「workshopRequested @Published → openWindow」，实现改为 AppDelegate 手工 NSWindow——`openWindow` 需要 SwiftUI view 锚点，而 pet 模式下 MainView 整棵被拆掉，Settings Scene 的 view 树也不保证存活；手工窗口是本项目主窗口的既有模式，且右键菜单的调用方本来就是 AppDelegate。**不需要** `workshopRequested`/`settingsRequested` 两个 @Published。

**已知坑（来自 anicompanion/CLAUDE.md 与代码注释，实现时别踩）:**
- 改 `project.yml` 后必须 `xcodegen generate`（本计划不需要改 project.yml）
- `enterPet` 的顺序铁律：先 `setFrame` 缩窗口 → 再装 webView → 最后 dispatch JS resize
- `.borderless` rawValue 是 0，`styleMask.contains(.borderless)` 恒 true——用自持 Bool（`isPetActive`/`isQuietActive`）判断状态
- 静隐窗口 frame 用 `visibleFrame`（已扣菜单栏+Dock）
- 所有用户可见字符串必须 `Text("…")` / `String(localized:)` 进 `Localizable.xcstrings`（en 开发语言 + zh-Hant 出厂），NSMenuItem title 用 `String(localized:)`
- `NSMenu` 的 target/action 用 `quietItem.target = self`（AppDelegate 是 NSObject，可直接当 target）
- 单测只能覆盖纯逻辑（几何/存储/枚举）；窗口形态逻辑靠 manual checklist（文末）

---

### Task 1: DisplayMode 枚举 + AppState 状态 + 通知静默抑制

**Files:**
- Modify: `AniCompanion/App/AppState.swift`
- Modify: `AniCompanion/Pipeline/ConversationController.swift`
- Create: `AniCompanionTests/DisplayModeTests.swift`

**Step 1: 写失败的测试**

`AniCompanionTests/DisplayModeTests.swift`：

```swift
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
```

**Step 2: 跑测试确认失败**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL — `cannot find 'DisplayMode' in scope`

**Step 3: 实现 DisplayMode + AppState 状态**

`AppState.swift`：在 `// MARK: - AppState` 注释块之前（文件顶部 import 之后）加枚举：

```swift
// MARK: - DisplayMode

/// Which form the desktop pet takes: the full-size companion, or the quiet mini form docked
/// at the bottom-right corner (translucent, no speech, no bubble — she's resting).
/// Only meaningful while `petMode` is active; in windowed mode the value persists but has no
/// visible effect until the next enter-pet.
enum DisplayMode: String, CaseIterable {
    case companion
    case quiet
}
```

`AppState.swift`：在 `@Published var petMode: Bool = false`（约 :172）之后加：

```swift
/// Display form of the desktop pet. Applied by AppDelegate (window-level work) via a Combine
/// sink on `$displayMode` — the same pattern as `petMode`. Toggled from the pet context menu,
/// Settings → Mode, or by clicking the quiet mini form.
@Published var displayMode: DisplayMode = {
    DisplayMode(rawValue: UserDefaults.standard.string(forKey: "display_mode") ?? "") ?? .companion
}()

/// Persistence slot for `displayMode` (written by AppDelegate's sink — the single place that
/// applies mode changes, mirroring the petMode/launchInPetMode split).
@AppStorage("display_mode") var displayModeStorage: String = DisplayMode.companion.rawValue
```

`AppState.swift` `initializeServices()` 末尾（`controller.triggerLaunchGreeting()` 之前）加：

```swift
// Quiet mode suppresses server-pushed notifications. Re-applied here because
// reinitializeServices() rebuilds the controller (a fresh one defaults to false).
conversationController?.isQuietMode = (displayMode == .quiet && petMode)
```

`ConversationController.swift`：在 `@Published private(set) var isProcessing`（:40）附近加属性：

```swift
/// While true, server-pushed notifications are acked and dropped without speaking — set by
/// AppState/AppDelegate when the pet rests in quiet mode (no TTS, no bubble).
var isQuietMode = false
```

`ConversationController.swift` `handleNotification(ref:source:)`（:695）开头、`guard !isProcessing` 之前加：

```swift
// Quiet mode: she's resting — ack (so the backend doesn't retry) and drop without speaking.
if isQuietMode {
    Log.pipeline("[Pipeline] Notification \(ref) dropped — quiet mode")
    Task { try? await chatTransport.send(.ack(ref: ref)) }
    return
}
```

**Step 4: 跑测试确认通过**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS — `Executed 15 tests, with 0 failures`（原 11 + 新 4）

**Step 5: Commit**

```bash
git add AniCompanion/App/AppState.swift AniCompanion/Pipeline/ConversationController.swift AniCompanionTests/DisplayModeTests.swift
git commit -m "feat: DisplayMode enum + quiet-mode notification suppression"
```

---

### Task 2: VRMModelStore — 可注入目录 + deleteModel

**Files:**
- Modify: `AniCompanion/Character/VRMModelStore.swift`
- Create: `AniCompanionTests/VRMModelStoreTests.swift`

**Step 1: 写失败的测试**

`AniCompanionTests/VRMModelStoreTests.swift`（新文件 → 写完先 `xcodegen generate` 再跑测试，见顶部陷阱）：

```swift
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
    private func writeMinimalVRM(_ filename: String) throws {
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
        try glb.write(to: tempDir.appendingPathComponent(filename))
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
        let src = tempDir.appendingPathComponent("Src.vrm")
        try writeMinimalVRM("Src.vrm")
        let store = makeStore()
        XCTAssertEqual(try store.importModel(from: src), "Src.vrm")
        XCTAssertEqual(try store.importModel(from: src), "Src 2.vrm")
        XCTAssertEqual(try store.importModel(from: src), "Src 3.vrm")
        XCTAssertEqual(store.availableModels().filter { $0.filename.hasPrefix("Src") }.count, 3)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL — `incorrect argument label` / `cannot find 'deleteModel'`

**Step 3: 实现**

`VRMModelStore.swift`：

类内顶部（`private let fm` 旁）加：

```swift
private let userDirectoryOverride: URL?

/// `userDirectoryOverride` exists for unit tests (an injected temp dir); production code
/// uses `shared` and gets the real Application Support directory.
init(userDirectoryOverride: URL? = nil) {
    self.userDirectoryOverride = userDirectoryOverride
}
```

`userModelsDirectory` 计算属性改为：

```swift
var userModelsDirectory: URL {
    if let override = userDirectoryOverride { return override }
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AniCompanion/VRMModel", isDirectory: true)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}
```

（注意：override 分支**不**执行创建——测试的 setUp 已建好目录，且不往真实 Application Support 写任何东西。）

`// MARK: - Import` 区块内、`importModel` 之后加：

```swift
/// Remove a user-imported model from the writable directory. Built-in (bundle) models are
/// never touched — only the user directory is consulted, so a built-in filename is a no-op.
/// Returns false when the file isn't in the user directory; throws on filesystem errors.
@discardableResult
func deleteModel(filename: String) throws -> Bool {
    let url = userModelsDirectory.appendingPathComponent(filename)
    guard fm.fileExists(atPath: url.path) else { return false }
    try fm.removeItem(at: url)
    return true
}
```

**Step 4: 跑测试确认通过**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS — `Executed 20 tests, with 0 failures`

**Step 5: Commit**

```bash
git add AniCompanion/Character/VRMModelStore.swift AniCompanionTests/VRMModelStoreTests.swift
git commit -m "feat: VRMModelStore deleteModel + injectable user dir"
```

---

### Task 3: AppDelegate 静隐窗口形态

纯 AppKit 窗口逻辑，无单测（UI 层），构建通过即提交，行为靠文末 manual checklist。

**Files:**
- Modify: `AniCompanion/App/AppDelegate.swift`

**Step 1: 实现状态与形态切换**

`AppDelegate.swift` 状态区（`isPetActive` 旁，:45 附近）加：

```swift
/// Quiet mode is active (small translucent form at the bottom-right). Tracked separately from
/// `appState.displayMode` for the same reason as `isPetActive` — never re-derive window state.
private var isQuietActive = false
private var quietCancellable: AnyCancellable?

/// Quiet form size (QQ-pet corner-sticker scale). Deliberately NOT configurable — the resting
/// form is a fixed tiny size; her real size (`currentPetSize`) is restored on wake.
private static let quietSize = NSSize(width: 80, height: 86)
```

`applicationDidFinishLaunching` 里 `petCancellable = ...` 之后加 displayMode sink：

```swift
// Apply display-mode changes to the window (quiet ⇄ companion). Mirrors the petMode sink:
// always persist the choice, but only reshape the window while the pet is actually active —
// a windowed save persists and takes effect on the next enter-pet.
// NOTE: `conversationController.isQuietMode` is owned by enterQuiet()/exitQuiet() below —
// NOT set here. The sink's guard would skip the flag on launch-into-quiet (the petMode sink
// calls enterQuiet() directly), and exitPet must clear it on the way to windowed mode.
quietCancellable = appState.$displayMode
    .receive(on: RunLoop.main)
    .sink { [weak self] mode in
        guard let self else { return }
        self.appState.displayModeStorage = mode.rawValue
        guard self.isPetActive, (mode == .quiet) != self.isQuietActive else { return }
        mode == .quiet ? self.enterQuiet() : self.exitQuiet()
    }
```

`petMode` sink 里 `petMode ? self.enterPet(window) : self.exitPet(window)` 与 `if petMode { window.alphaValue = 1 }` 之间插一行（启动直达静隐、以及任何 enterPet 路径都不闪现大形态）：

```swift
petMode ? self.enterPet(window) : self.exitPet(window)
if petMode, self.appState.displayMode == .quiet { self.enterQuiet() }   // before the reveal below
if petMode { window.alphaValue = 1 }
```

`enterPet` 方法之后新增两个形态方法（注意：`exitQuiet` 走 `plannedPetFrame` —— 恢复到记住的位置或右下角，与启动路径同源）：

```swift
// MARK: - Quiet mode (resting mini form)

/// Shrink her to the translucent corner-sticker form: stop any in-flight speech, clear the
/// bubble, dock bottom-right. The window's own alphaValue is untouched (the launch-time
/// reveal in the petMode sink stays in charge of that).
private func enterQuiet() {
    guard let window = mainWindow, let webView = appState.characterManager.webView else { return }
    isQuietActive = true
    appState.conversationController?.isQuietMode = true   // drop pushed notifications (owned HERE)
    appState.conversationController?.cancel()          // stop mid-sentence TTS
    appState.characterManager.setSpeechText(nil)       // hide the bubble
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
    window.setFrame(PetFramePlanner.bottomRight(size: Self.quietSize, in: visible), display: true)
    webView.alphaValue = 0.4
    refitScene(webView)
}

/// Wake back to the companion form: full opacity, remembered spot (or bottom-right).
private func exitQuiet() {
    guard let window = mainWindow, let webView = appState.characterManager.webView else { return }
    isQuietActive = false
    appState.conversationController?.isQuietMode = false  // resume pushed notifications
    webView.alphaValue = 1
    window.setFrame(plannedPetFrame(for: window), display: true)
    refitScene(webView)
}
```

**Step 2: 修各处 guard（静隐期间屏蔽干扰行为）**

- `windowDidMove`（:267）guard 改为：
  ```swift
  guard isPetActive, !isQuietActive,
        let window = mainWindow,
        let webView = appState.characterManager.webView else { return }
  ```
  （静隐小形态被拖动时不翻转气泡、**不把小 frame 写进 `petFrameStorage`**——否则下次陪伴模式会以 80×86 恢复。）
- `scalePet`（:301）guard 改为 `guard isPetActive, !isQuietActive, let window = mainWindow else { return }`（静隐尺寸固定，滚轮/捏合不生效）。
- `exitPet`（:226）开头加：
  ```swift
  if isQuietActive {
      appState.characterManager.webView?.alphaValue = 1
      isQuietActive = false
      appState.conversationController?.isQuietMode = false   // windowed mode must not stay muted
  }
  ```
  （静隐中双击退出 → windowed 角色不能停留在 40% 透明、通知不能持续被静默。`displayMode` 保持 `.quiet`——下次进桌宠回到静隐，符合"她还在休息"的语义。）

**Step 2b: 顺手小修（来自 Task 1 code review）**

- `AppState.swift`：给 `DisplayMode` 加 `static let storageKey = "display_mode"` 常量（extension 形式），把 init 闭包与 `@AppStorage` 的两处字面量换上去（项目惯例：`TTSProvider.storageKey` 等）。
- `ConversationController.swift` 静默分支的注释把 "ack (so the backend doesn't retry)" 修正为 "ack for protocol symmetry (v1 companion-layer is at-most-once; the send itself is a no-op on plain gateways)"。

**Step 3: 构建验证**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add AniCompanion/App/AppDelegate.swift
git commit -m "feat: quiet-mode window form (enter/exit/sink + guards)"
```

---

### Task 4: PetDragView 右键 + AppDelegate NSMenu + 工坊窗口壳

**Files:**
- Modify: `AniCompanion/Views/DesktopPet.swift`
- Modify: `AniCompanion/App/AppDelegate.swift`
- Create: `AniCompanion/Views/WorkshopView.swift`（本 task 占位，Task 5 填实）

**Step 1: PetDragView 加右键**

`DesktopPet.swift` 属性区加、类末尾加：

```swift
/// Right-click context menu provider. AppDelegate builds the NSMenu (it owns mode/window
/// state); the view only knows how to present it.
var menuProvider: (() -> NSMenu)?
```

```swift
/// Right-click → the pet context menu (quiet-mode toggle / workshop / settings / exit).
override func rightMouseDown(with event: NSEvent) {
    if let menu = menuProvider?() {
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
```

**Step 2: AppDelegate 建菜单 + 动作 + 工坊窗口壳**

`AppDelegate` 状态区加工坊窗口持有：

```swift
private var workshopWindow: NSWindow?
```

`enterPet` 里 `drag.onTap = ...` 闭包之后加（闭包接线，风格与 onExit/onScale 一致）：

```swift
drag.menuProvider = { [weak self] in self?.buildPetMenu() }
```

新增方法区（放 exitPet 之后）：

```swift
// MARK: - Pet context menu & auxiliary windows

private func buildPetMenu() -> NSMenu {
    let menu = NSMenu()

    let quiet = NSMenuItem(
        title: String(localized: "Quiet Mode", comment: "Context menu: rest at the corner, no speech"),
        action: #selector(toggleQuietMode), keyEquivalent: ""
    )
    quiet.target = self
    quiet.state = appState.displayMode == .quiet ? .on : .off
    menu.addItem(quiet)

    menu.addItem(.separator())

    let workshop = NSMenuItem(
        title: String(localized: "Pet Workshop…", comment: "Context menu: open the model workshop"),
        action: #selector(showWorkshop), keyEquivalent: ""
    )
    workshop.target = self
    menu.addItem(workshop)

    let settings = NSMenuItem(
        title: String(localized: "Settings…", comment: "Context menu: open the settings window"),
        action: #selector(openSettings), keyEquivalent: ","
    )
    settings.target = self
    settings.keyEquivalentModifierMask = .command
    menu.addItem(settings)

    menu.addItem(.separator())

    let exit = NSMenuItem(
        title: String(localized: "Exit Pet Mode", comment: "Context menu: back to the windowed app"),
        action: #selector(exitPetFromMenu), keyEquivalent: ""
    )
    exit.target = self
    menu.addItem(exit)

    return menu
}

@objc private func toggleQuietMode() {
    appState.displayMode = appState.displayMode == .quiet ? .companion : .quiet
}

@objc private func exitPetFromMenu() {
    appState.petMode = false
}

@objc func showWorkshop() {
    // Pet mode is a nonactivating panel — bring the app forward so the workshop window
    // can take focus.
    NSApp.activate(ignoringOtherApps: true)
    if workshopWindow == nil {
        let vc = NSHostingController(rootView: WorkshopView().environmentObject(appState))
        let w = NSWindow(contentViewController: vc)
        w.title = String(localized: "Pet Workshop", comment: "Workshop window title")
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 520, height: 420))
        w.center()
        workshopWindow = w
    }
    workshopWindow?.makeKeyAndOrderFront(nil)
}

@objc private func openSettings() {
    // Same story as the workshop window: pet mode tears down the SwiftUI tree, so the
    // Settings scene's window is unreachable from here (and Apple removed the
    // showSettingsWindow: action in macOS 14 anyway). Host SettingsView ourselves.
    NSApp.activate(ignoringOtherApps: true)
    if settingsWindow == nil {
        let vc = NSHostingController(rootView: SettingsView().environmentObject(appState))
        let w = NSWindow(contentViewController: vc)
        w.title = String(localized: "Settings", comment: "Settings window title")
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 480, height: 640))   // SettingsView's own fixed frame
        w.center()
        settingsWindow = w
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
}
```

⚠️ 计划缺陷修正（Task 4 review 发现）：原计划此处用 `NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"))`——该 action 在 macOS 14+ 已被 Apple 移除（SwiftUI 打日志拒绝），且 sendAction 响应链到不了 SwiftUI 实现者，菜单项是死的。已改为与工坊同构的手工窗口（上面代码块即修正版）。**已知差异**：SettingsView 的 Cancel/Save 走 `@Environment(\.dismiss)`，在手工窗口（非 sheet）里是 no-op——Task 6 改造 SettingsView 时统一处理（给 Cancel/Save 补"关所在窗口"的能力）。

**Step 3: WorkshopView 占位**

`AniCompanion/Views/WorkshopView.swift`：

```swift
import SwiftUI

// MARK: - WorkshopView
//
// The Pet Workshop: import/switch/delete VRM character models. Filled out in the next task;
// this placeholder keeps the menu target compiling.

struct WorkshopView: View {
    var body: some View {
        Text("Pet Workshop")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 4: 构建 + 提交**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

```bash
git add AniCompanion/Views/DesktopPet.swift AniCompanion/App/AppDelegate.swift AniCompanion/Views/WorkshopView.swift
git commit -m "feat: pet right-click context menu + workshop window shell"
```

---

### Task 5: WorkshopView 完整功能 + AppState.selectModel

**Files:**
- Modify: `AniCompanion/App/AppState.swift`
- Modify: `AniCompanion/Character/VRMModelStore.swift`
- Rewrite: `AniCompanion/Views/WorkshopView.swift`

**Step 0: 顺手小修（来自 Task 2 review）**

`VRMModelStore.deleteModel` 的 guard 追加两个子句，封死 `"."` / `".."`（不含斜杠但 `removeItem` 会删目录/父目录）：

```swift
guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else { return false }
```

**Step 1: AppState.selectModel（live 切换，不重建服务）**

`AppState.swift` 在 `effectiveVRMModelFilename` 之后加：

```swift
/// Switch the active character model live. Only the webview scene reloads — no service
/// rebuild (chat/TTS keep running). Persisted under `vrm_model_filename`.
func selectModel(filename: String) {
    vrmModelFilename = filename
    characterManager.loadModel(named: filename)
}
```

**Step 2: WorkshopView 完整实现**

`WorkshopView.swift` 整文件替换为：

```swift
import SwiftUI
import UniformTypeIdentifiers

// MARK: - WorkshopView
//
// The Pet Workshop — a standalone window for managing VRM character models. Instant-apply
// (no Save button): tapping a model switches her immediately via the live-reload chain
// (`AppState.selectModel` → `loadModel` → the three-vrm scene swaps, no page reload).

struct WorkshopView: View {
    @EnvironmentObject private var appState: AppState

    @State private var models: [VRMModelInfo] = []
    @State private var selected: String = ""
    @State private var importErrorText: String?
    @State private var deleteErrorText: String?
    @State private var pendingDelete: VRMModelInfo?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(models) { model in
                    row(model)
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { refresh() }
        .alert(
            Text("Couldn't import the model"),
            isPresented: Binding(
                get: { importErrorText != nil },
                set: { if !$0 { importErrorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: importErrorText ?? "")
        }
        .alert(
            Text("Couldn't delete the model"),
            isPresented: Binding(
                get: { deleteErrorText != nil },
                set: { if !$0 { deleteErrorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deleteErrorText ?? "")
        }
        .confirmationDialog(
            Text("Delete “\(pendingDelete?.displayName ?? "")”?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("Pet Workshop")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ model: VRMModelInfo) -> some View {
        let isSelected = model.filename == selected
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "person.crop.square")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(verbatim: model.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.isBuiltIn
                 ? String(localized: "Built-in", comment: "Workshop: shipped model tag")
                 : String(localized: "Imported", comment: "Workshop: user-imported model tag"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
            if !model.isBuiltIn {
                Button {
                    pendingDelete = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Delete this model", comment: "Workshop: delete button tooltip"))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { select(model) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    importModel()
                } label: {
                    Label("Import VRM…", systemImage: "plus")
                }
                Spacer()
            }
            .controlSize(.small)
            Text("Imported models are stored in Application Support. Alicia Solid (© DWANGO) is for your own use only.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func refresh() {
        models = VRMModelStore.shared.availableModels()
        selected = appState.vrmModelFilename
    }

    private func select(_ model: VRMModelInfo) {
        guard model.filename != selected else { return }
        selected = model.filename
        appState.selectModel(filename: model.filename)
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vrm") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try VRMModelStore.shared.importModel(from: url)
            refresh()
            if let imported = models.first(where: { $0.filename == filename }) {
                select(imported)   // auto-select the newcomer — she tries it on immediately
            }
        } catch {
            importErrorText = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard let model = pendingDelete else { return }
        pendingDelete = nil
        do {
            // If she's wearing the model being deleted, switch her back to the default FIRST
            // (live reload), then remove the file — never a deleted-file load.
            if model.filename == selected {
                selected = VRMModelStore.defaultModelFilename
                appState.selectModel(filename: VRMModelStore.defaultModelFilename)
            }
            try VRMModelStore.shared.deleteModel(filename: model.filename)
            refresh()
        } catch {
            deleteErrorText = error.localizedDescription
            refresh()
        }
    }
}
```

**Step 3: 构建 + 手工冒烟**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

手工（如在本机）：启动 app → 右键 → Pet Workshop… → 窗口出现、列表含 小光（Built-in）。

**Step 4: Commit**

```bash
git add AniCompanion/App/AppState.swift AniCompanion/Views/WorkshopView.swift
git commit -m "feat: pet workshop — import/switch/delete VRM models (instant apply)"
```

---

### Task 6: SettingsView — Mode 区 + About 区 + Character 区跳转

**Files:**
- Modify: `AniCompanion/Views/SettingsView.swift`

**Step 0: dismiss 差异处理（来自 Task 4 review 的已知项）**

SettingsView 的 Cancel/Save 按钮调 `@Environment(\.dismiss)`——在 MainView 的 sheet 里有效，但在 AppDelegate 手工建的 settingsWindow（Task 4 修正版 openSettings）里是 no-op，用户点 Save 后窗口不关。处理：给 SettingsView 加一个可选闭包参数 `var onClose: (() -> Void)? = nil`，Cancel/Save 动作在 `dismiss()` 之外追加 `onClose?()`（sheet 场景 onClose 为 nil 行为不变；手工窗口场景由 openSettings 处传入 `{ [weak settingsWindow] in settingsWindow?.performClose(nil) }`——注意 performClose 会走 windowShouldClose，需确认对非 mainWindow 返回 true 放行；workshopWindow delegate 未设不受影响）。若实现中发现更简洁的做法（如 NSHostingController 的 dismiss 桥接），可替换，但两个场景（sheet + 手工窗口）都必须"保存后关窗"。

**另一条 Task 4 review 观察（顺手处理）**：App 菜单 ⌘, 仍开 SwiftUI Settings scene 窗口，右键菜单开手工 settingsWindow——同一会话可能同时存在两个 SettingsView 实例（状态无冲突，仅视觉重复）。处理：`AniCompanionApp.swift` 的 `Settings { SettingsView() }` scene 保留（⌘, 是系统惯例入口），但 `openSettings()` 在建手工窗口前把标题/内容与 scene 窗口统一即可接受；或最简——manual checklist 加一条"两条路径各开一次确认无混淆"，代码不动。实现时按最简处理。

**Step 1: 新增本地状态与数据流**

@State 区（`vrmModelFilename` 声明处，:52）替换为：

```swift
@State private var displayModeSelection: DisplayMode = .companion
@State private var currentModelName: String = ""
```

（`vrmModelFilename` @State 删除——模型切换移入工坊，Settings 不再持有副本。）

`loadSettings()` 末尾（:1053 附近）把 `vrmModelFilename = appState.vrmModelFilename` 替换为：

```swift
displayModeSelection = appState.displayMode
currentModelName = VRMModelStore.shared.availableModels()
    .first { $0.filename == appState.vrmModelFilename }?.displayName
    ?? appState.vrmModelFilename
```

`saveSettings()` 里删除 `appState.vrmModelFilename = vrmModelFilename`（:1093），在 `appState.appLanguage = language.rawValue` 之前加：

```swift
appState.displayMode = displayModeSelection
```

**Step 2: Character 区改为跳转工坊**

Section 1（:176-178）替换为：

```swift
// MARK: Section: Character

SettingsSection(title: "Character", icon: "person.crop.square") {
    VStack(alignment: .leading, spacing: 12) {
        SettingsField(label: "Character Model") {
            Text(currentModelName)
        }
        Button {
            // The workshop is an AppDelegate-owned NSWindow (pet mode tears down the SwiftUI
            // tree, so openWindow has no anchor) — reach it through the app delegate.
            (NSApp.delegate as? AppDelegate)?.showWorkshop()
        } label: {
            Label("Manage Models…", systemImage: "square.grid.2x2")
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }
}
```

**Step 3: Mode 区（插在 Section 0: Connection 之前）**

```swift
// MARK: Section: Mode

SettingsSection(title: "Mode", icon: "person.fill") {
    VStack(alignment: .leading, spacing: 12) {
        SettingsField(label: "Display Mode") {
            Picker("", selection: $displayModeSelection) {
                Text("Companion").tag(DisplayMode.companion)
                Text("Quiet").tag(DisplayMode.quiet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Text("In Quiet mode she rests as a small translucent form at the bottom-right corner — no speech, no bubble. Click her to bring her back.")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
    }
}
```

**Step 4: About 区（追加在 Live Transcription 区之后、按钮栏之前）**

```swift
// MARK: Section: About

SettingsSection(title: "About", icon: "info.circle") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("AniCompanion").font(.system(size: 14, weight: .semibold))
                Text(verbatim: "v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        Text("A desktop AI companion — she watches your work, chats, and keeps you company.")
            .font(.system(size: 12))
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text("Character: AvatarSample (小光) / Alicia Solid © DWANGO — fetched on demand for personal use; see ATTRIBUTION.md.")
            Text("Rendering: three-vrm + three.js. Animations derived from Mixamo.")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.4))
    }
}

private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}
```

（`appVersion` 计算属性放 `SettingsView` 内 `saveSettings()` 附近。）

**Step 5: 删除 VRMModelPicker**

整体删除 `private struct VRMModelPicker`（:1304-1427）。**保留 `VRMDownloader`**（:1429 起）——若仅被 picker 使用则一并删除；先 `grep -n "VRMDownloader" AniCompanion/Views/SettingsView.swift` 确认无其他引用再删。

**Step 6: 构建 + 全量测试**

Run:
```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: PASS — `Executed 20 tests, with 0 failures` + `** TEST SUCCEEDED **`

**Step 7: Commit**

```bash
git add AniCompanion/Views/SettingsView.swift
git commit -m "feat: settings — Mode & About sections, Character delegates to workshop"
```

---

### Task 7: 本地化 zh-Hant 注入 + 全量验证

**Files:**
- Modify: `AniCompanion/Resources/Localizable.xcstrings`

**Step 1: 收集新 key**

构建一次（Xcode 自动提取 `Text()`/`String(localized:)` key），然后确认这些 key 存在（不存在也没关系——Step 2 的脚本会创建缺失项）：

新 key 清单（en 源文案 → zh-Hant 译文）：

| Key（en） | zh-Hant |
|---|---|
| Quiet Mode | 靜隱模式 |
| Pet Workshop… | 桌寵工坊… |
| Pet Workshop | 桌寵工坊 |
| Settings… | 設定… |
| Exit Pet Mode | 離開桌寵模式 |
| Mode | 模式 |
| Display Mode | 顯示模式 |
| Companion | 陪伴模式 |
| Quiet | 靜隱 |
| In Quiet mode she rests as a small translucent form at the bottom-right corner — no speech, no bubble. Click her to bring her back. | 靜隱模式下她會縮成半透明小身影待在螢幕右下角——不說話、不冒泡。點一下她就能喚回。 |
| Manage Models… | 管理模型… |
| Character Model | 角色模型 |
| About | 關於 |
| A desktop AI companion — she watches your work, chats, and keeps you company. | 桌面 AI 伴侶——她看著你工作、聊天、陪著你。 |
| Character: AvatarSample (小光) © VRoid / Alicia Solid © DWANGO — downloaded separately; see ATTRIBUTION.md. | 角色：AvatarSample（小光）© VRoid / Alicia Solid © DWANGO——另行下載；詳見 ATTRIBUTION.md。 |
| Rendering: three-vrm + three.js. Animations derived from Mixamo. | 渲染：three-vrm + three.js。動作動畫源自 Mixamo。 |
| Import VRM… | 匯入 VRM… |
| Built-in | 內建 |
| Imported | 已匯入 |
| Delete this model | 刪除此模型 |
| Imported models are stored in Application Support. Alicia Solid (© DWANGO) is for your own use only. | 匯入的模型存於 Application Support。Alicia Solid（© DWANGO）僅供個人使用。 |
| Couldn't import the model | 無法匯入模型 |
| Couldn't delete the model | 無法刪除模型 |
| Delete | 刪除 |
| Delete “%@”? | 刪除「%@」？ |
| Cancel | 取消 |
| OK | 好 |

**Step 2: 注入翻译（python 脚本，幂等）**

```bash
python3 - <<'EOF'
import json, sys

path = "AniCompanion/Resources/Localizable.xcstrings"
with open(path) as f:
    catalog = json.load(f)

translations = {
    "Quiet Mode": "靜隱模式",
    "Pet Workshop…": "桌寵工坊…",
    "Pet Workshop": "桌寵工坊",
    "Settings…": "設定…",
    "Exit Pet Mode": "離開桌寵模式",
    "Mode": "模式",
    "Display Mode": "顯示模式",
    "Companion": "陪伴模式",
    "Quiet": "靜隱",
    "In Quiet mode she rests as a small translucent form at the bottom-right corner — no speech, no bubble. Click her to bring her back.":
        "靜隱模式下她會縮成半透明小身影待在螢幕右下角——不說話、不冒泡。點一下她就能喚回。",
    "Manage Models…": "管理模型…",
    "Character Model": "角色模型",
    "About": "關於",
    "A desktop AI companion — she watches your work, chats, and keeps you company.":
        "桌面 AI 伴侶——她看著你工作、聊天、陪著你。",
    "Character: AvatarSample (小光) © VRoid / Alicia Solid © DWANGO — downloaded separately; see ATTRIBUTION.md.":
        "角色：AvatarSample（小光）© VRoid / Alicia Solid © DWANGO——另行下載；詳見 ATTRIBUTION.md。",
    "Rendering: three-vrm + three.js. Animations derived from Mixamo.":
        "渲染：three-vrm + three.js。動作動畫源自 Mixamo。",
    "Import VRM…": "匯入 VRM…",
    "Built-in": "內建",
    "Imported": "已匯入",
    "Delete this model": "刪除此模型",
    "Imported models are stored in Application Support. Alicia Solid (© DWANGO) is for your own use only.":
        "匯入的模型存於 Application Support。Alicia Solid（© DWANGO）僅供個人使用。",
    "Couldn't import the model": "無法匯入模型",
    "Couldn't delete the model": "無法刪除模型",
    "Delete “%@”?": "刪除「%@」？",
    "Not a valid VRM (GLB) file.": "不是有效的 VRM（GLB）檔案。",
}

strings = catalog.setdefault("strings", {})
added = 0
for key, zh in translations.items():
    entry = strings.setdefault(key, {"extractionState": "manual"})
    locs = entry.setdefault("localizations", {})
    if "zh-Hant" not in locs:
        locs["zh-Hant"] = {"stringUnit": {"state": "translated", "value": zh}}
        added += 1

with open(path, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")

print(f"added zh-Hant for {added} keys")
EOF
```

注意：`Delete`/`Cancel`/`OK` 若 catalog 已有则跳过（脚本天然幂等）。⚠️ 若 Xcode 在 json.dump 时对文件有格式差异（缩进/排序），以 Xcode 重新保存一次为准；只提交 diff 中新增的 key。

**Step 3: 全量验证**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`，20 tests 0 failures。

**Step 4: Commit**

```bash
git add AniCompanion/Resources/Localizable.xcstrings
git commit -m "i18n: zh-Hant strings for menu/workshop/mode/about"
```

---

### Task 8: 文档更新

**Files:**
- Modify: `CLAUDE.md`（anicompanion 仓库根）

**Step 1: 更新 Settings 清单与桌宠入口描述**

- **Settings (via Settings UI)** 一节：Character 区改为「当前模型名 + Manage Models… → 打开 Pet Workshop 窗口（import/switch/delete，instant apply）」；新增 **Mode** 区（Display Mode: Companion | Quiet — quiet = 角落驻留小形态，静默通知）；新增 **About** 区。
- **"Desktop Pet mode is not in this panel…"** 一段更新为：桌宠形态仍从 🐾/⌘⇧D/Character 菜单切换；**显示模式**（陪伴/静隐）从右键菜单即时切换，或 Settings → Mode（保存生效）。
- 新增一小节 **Pet context menu**：`PetDragView.rightMouseDown` → NSMenu（Quiet Mode 勾选项 / Pet Workshop… / Settings… / Exit Pet Mode）；静隐 = `AppDelegate.enterQuiet/exitQuiet`，`display_mode` 持久化，通知在 `handleNotification` 头部 ack+drop（`isQuietMode`）。
- **Project Structure** 的 Views/ 行补 `WorkshopView`。
- **VRM Model 一节更新**：应用内 "Download Alicia Solid" 按钮已随 VRMModelPicker 移除——获取 Alicia 走 `scripts/download-model.sh` 或工坊手动导入；About 区的版权行已改为 "downloaded separately"。
- **Setup wizard 已知限制**：pet 模式下手工 Settings 窗口的 "Re-run setup…" 按钮会关窗，但向导 sheet 无宿主（MainView 已拆）不呈现——记录为已知限制/后续项。

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: context menu, workshop, quiet-mode in CLAUDE.md"
```

---

## Manual Checklist（实现完成后逐项过）

UI/AppKit 逻辑无单测覆盖，以下全链路手工验证（先 `xcodebuild build` 再运行）：

- [ ] 桌宠上右键 → 菜单弹出：Quiet Mode（无勾）/ Pet Workshop… / Settings…（⌘, 快捷键提示）/ Exit Pet Mode
- [ ] 勾选 Quiet Mode → 她缩为 ~80×86、40% 透明、移到屏幕右下角；说话途中切换 → 立即安静、气泡消失
- [ ] 静隐期间 companion-layer 推送消息 → 无 TTS 无气泡（服务端日志可见 ack）
- [ ] 静隐期间拖动小形态 → 可动，但恢复后回到原位置（不记忆小形态位置）；下次重启陪伴模式尺寸正常（未污染 petFrameStorage）
- [ ] 静隐期间滚轮/捏合 → 不缩放
- [ ] 单击静隐形态 → 恢复陪伴模式（原位置/尺寸/透明度）；双击 → 退出桌宠到窗口模式，角色不透明度 100%
- [ ] 静隐状态重启 app → 直接以静隐形态出现，无大形态闪现
- [ ] windowed 模式下保存 quiet → 点 🐾 进桌宠 → 直接以静隐形态出现，无大形态闪现
- [ ] 快速右键切换 quiet⇄companion 数次 → 终态正确（尺寸/位置/透明度收敛），无残影
- [ ] 右键 → Pet Workshop… → 窗口打开；列表含 小光（Built-in 标签）
- [ ] Import VRM… → 选 .vrm → 出现在列表并自动切换（她立即换装，无白屏）
- [ ] 删除非当前模型 → 确认框 → 从列表消失
- [ ] 删除当前模型 → 先切回 小光 再删除，无残影/报错
- [ ] Built-in 模型无删除按钮
- [ ] 右键 → Settings… → Settings 窗口打开（手工窗口）；App 菜单 ⌘, 也开一次（scene 窗口）——两条路径无混淆、无状态冲突
- [ ] Settings → Mode 切 Quiet + Save → 桌宠进入静隐；切回 Companion + Save → 恢复
- [ ] 右键开 Settings → 关窗 → 右键切 Quiet → 重开 Settings（段控件应显示 Quiet）→ Save → 仍保持静隐（不回滚）
- [ ] 窗口模式下 Settings 切 Quiet + Save → 无视觉变化；重新进桌宠 → 以静隐形态出现
- [ ] Settings → About：图标/版本号/致谢显示正常；Character 区显示当前模型名，Manage Models… 呼出工坊
- [ ] 系统语言切 zh-Hant → 所有新字符串为繁体中文；切 en → 英文
- [ ] 全量单测：`xcodebuild test` 20 tests 0 failures
