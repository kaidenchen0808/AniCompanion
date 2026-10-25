# Pet 桌宠小型化 + 右下角常驻 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** AniCompanion 启动直接以小桌宠（QQ 宠物量级）形态常驻屏幕右下角，尺寸/位置/模式持久化；windowed 大窗口降级为按需打开的面板（红叉不退出 app）。

**Architecture:** 全部改动在渲染端 Swift 层（`AppDelegate.swift` 为主）+ 气泡的 HTML/CSS。新增纯几何模块 `PetFramePlanner`（CoreGraphics CGRect 进出，不碰 AppKit 窗口）承载所有位置决策，XCTest 只测它。启动即 pet 通过「透明窗口隐藏 windowed 闪现 → 等 webView scene ready → 切 pet → 恢复透明度」序列实现。

**Tech Stack:** Swift 6 / AppKit NSPanel / XcodeGen（project.yml 是工程唯一真源，`.xcodeproj` 不入库）/ XCTest / 三行 JS+CSS（气泡）。

**设计文档:** 根仓库 `docs/plans/2026-10-25-pet-bottom-right-design.md`（含需求背景与决策记录）。

**Worktree:** `/Users/chenxuewei/hb/anicompanion/.worktrees/pet-bottom-right`，分支 `feature/pet-bottom-right`。所有命令在此目录执行。

**已知坑（来自 anicompanion/CLAUDE.md，实现时别踩）:**
- 改 `project.yml` 后必须 `xcodegen generate` 重新生成工程
- `enterPet` 的顺序铁律：先 `setFrame` 缩窗口 → 再装 webView → 最后 dispatch JS resize（顺序错了相机会怼到腿上）
- `.borderless` rawValue 是 0，`styleMask.contains(.borderless)` 恒 true——用 `isPetActive` 布尔判断状态
- 主窗口是 NSPanel，不计入「最后窗口关闭」，`applicationShouldTerminateAfterLastWindowClosed` 返回 false
- 所有窗口 frame 用 `visibleFrame`（已扣菜单栏+Dock，Dock 在任意边都正确）

---

### Task 1: 测试 target 搭建

**Files:**
- Modify: `project.yml`（文件末尾追加 target 和 scheme）

**Step 1: project.yml 追加 test target 与 scheme**

在 `project.yml` 末尾（`frameworks:` 块之后、文件级）追加：

```yaml
  AniCompanionTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: AniCompanionTests
    dependencies:
      - target: AniCompanion
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.anicompanion.tests
        GENERATE_INFOPLIST_FILE: YES

schemes:
  AniCompanion:
    build:
      targets:
        AniCompanion: all
        AniCompanionTests: [test]
    test:
      targets:
        - AniCompanionTests
```

注意 `AniCompanionTests` 与 `schemes:` 同级缩进于顶层（`targets:` 之下的是两个空格缩进的 target 名）。

**Step 2: 建空的测试目录（XcodeGen 需要至少一个源文件）**

创建 `AniCompanionTests/PetFramePlannerTests.swift`：

```swift
import XCTest
@testable import AniCompanion

final class PetFramePlannerTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

**Step 3: 重新生成工程并跑测试**

```bash
xcodegen generate
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`（1 个 placeholder 测试通过）。首次 test 编译较慢，耐心。

**Step 4: Commit**

```bash
git add project.yml AniCompanionTests/
git commit -m "chore: add unit-test target (XcodeGen scheme)"
```

---

### Task 2: PetFramePlanner 纯几何模块（TDD）

**Files:**
- Create: `AniCompanion/App/PetFramePlanner.swift`
- Test: `AniCompanionTests/PetFramePlannerTests.swift`（替换 placeholder）

**Step 1: 写失败测试**

替换 `AniCompanionTests/PetFramePlannerTests.swift` 全文：

```swift
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
        XCTAssertFalse(PetFramePlanner.isValid(.init(x: .nan, y: 0, width: 100, height: 100)))
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
    }
}
```

**Step 2: 跑测试确认失败**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: FAIL（`cannot find 'PetFramePlanner' in scope`）。

**Step 3: 最小实现**

创建 `AniCompanion/App/PetFramePlanner.swift`：

```swift
import CoreGraphics

/// Pure geometry for placing the desktop-pet window. Takes and returns plain CGRect/CGSize
/// (screen `visibleFrame`s), never touches AppKit windows — so every placement decision is
/// unit-testable and every failure path funnels to `bottomRight`, the single fail-safe spot
/// (she ALWAYS reappears at the bottom-right corner, never off-screen).
enum PetFramePlanner {
    /// Gap between her and the screen edge (QQ-pet style: hovering just above the Dock).
    static let margin: CGFloat = 8

    /// Bottom-right of `visible` (which must already exclude the menu bar + Dock).
    static func bottomRight(size: CGSize, in visible: CGRect) -> CGRect {
        let s = clamped(size: size, to: visible)
        return CGRect(x: visible.maxX - s.width - margin,
                      y: visible.minY + margin,
                      width: s.width,
                      height: s.height)
    }

    /// Never let her exceed 90% of the screen's dimensions.
    static func clamped(size: CGSize, to visible: CGRect) -> CGSize {
        CGSize(width: min(size.width, visible.width * 0.9),
               height: min(size.height, visible.height * 0.9))
    }

    /// Reject NaN / non-positive garbage from UserDefaults.
    static func isValid(_ f: CGRect) -> Bool {
        f.isFinite && f.width > 0 && f.height > 0
    }

    /// Restore priority: a valid stored frame that's still on its (live) anchor screen wins;
    /// anything else — no storage, anchor screen unplugged, frame off-screen — falls back to
    /// the bottom-right of the primary screen.
    static func restore(storedFrame: CGRect?, anchorVisible: CGRect?,
                        fallbackSize: CGSize, primaryVisible: CGRect) -> CGRect {
        if let stored = storedFrame, let anchor = anchorVisible,
           isValid(stored), stored.intersects(anchor) {
            return stored
        }
        return bottomRight(size: fallbackSize, in: primaryVisible)
    }

    // MARK: - UserDefaults string coding ("x,y,w,h")

    static func encode(_ f: CGRect) -> String {
        "\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)"
    }

    static func decode(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        let f = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        return isValid(f) ? f : nil
    }
}
```

**Step 4: 跑测试确认通过**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`（11 个测试）。

**Step 5: Commit**

```bash
git add AniCompanion/App/PetFramePlanner.swift AniCompanionTests/PetFramePlannerTests.swift
git commit -m "feat: PetFramePlanner — pure placement geometry with bottom-right fail-safe"
```

---

### Task 3: AppState 持久化键

**Files:**
- Modify: `AniCompanion/App/AppState.swift`（`@Published var petMode` 在 :159 附近，新键加在它旁边）

**Step 1: 加四个 @AppStorage 键**

在 `@Published var petMode: Bool = false` 的**上方**插入：

```swift
    // MARK: Desktop Pet persistence (launch-as-pet + remembered size/position)

    /// Launch straight into pet form. Default true (QQ-pet mental model: she's always there);
    /// an explicit switch to windowed writes false and is remembered.
    @AppStorage("launch_in_pet_mode") var launchInPetMode: Bool = true
    /// Last pet window frame, encoded "x,y,w,h" via PetFramePlanner.encode/decode.
    @AppStorage("pet_frame") var petFrameStorage: String = ""
    /// deviceIdentifier of the screen she was last on (nil/"" = primary bottom-right).
    @AppStorage("pet_anchor_screen") var petAnchorScreen: String = ""
    /// Last pet size, encoded like petFrame (pet width+height).
    @AppStorage("pet_size") var petSizeStorage: String = ""
```

**Step 2: 构建确认**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 3: Commit**

```bash
git add AniCompanion/App/AppState.swift
git commit -m "feat: AppStorage keys for pet mode/size/frame persistence"
```

---

### Task 4: webView ready 信号（启动即 pet 的前提）

**Files:**
- Modify: `AniCompanion/Character/ThreeVRMCharacterManager.swift`（`onWebViewReady()` 在 :122-125；`isWebViewReady` 声明在 :35）

**Step 1: 把 ready 状态变成可观察**

`private var isWebViewReady = false`（:35）改为：

```swift
    /// Kicks true once the scene HTML finished loading — AppDelegate awaits this to enter
    /// pet mode at launch (pet mode needs the webView to exist).
    @Published private(set) var isSceneReady = false
```

`onWebViewReady()`（:122）里 `isWebViewReady = true` 改为同时置两个（内部逻辑沿用 isWebViewReady，外部订阅 isSceneReady）：

```swift
    func onWebViewReady() {
        isWebViewReady = true
        isSceneReady = true
        loadPendingModelIfPossible()
    }
```

**Step 2: 构建确认**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 3: Commit**

```bash
git add AniCompanion/Character/ThreeVRMCharacterManager.swift
git commit -m "feat: publish isSceneReady so launch can await the webview"
```

---

### Task 5: 启动即 pet（防大窗口闪现 + fail-safe）

**Files:**
- Modify: `AniCompanion/App/AppDelegate.swift`（`applicationDidFinishLaunching` :58-84、petMode sink :77-83）

**Step 1: 启动序列改造**

`applicationDidFinishLaunching` 里，`window.makeKeyAndOrderFront(nil)` 之前加透明隐藏，之后加 ready 订阅。完整改动：

```swift
        let startInPet = appState.launchInPetMode
        if startInPet {
            // Hide the windowed form until pet mode is in place — the user sees her appear
            // at the bottom-right directly, never a 1000x650 window flashing by.
            window.alphaValue = 0
        }
        window.makeKeyAndOrderFront(nil)
```

`petCancellable` sink 之后追加（新成员变量 `private var sceneReadyCancellable: AnyCancellable?` 一并声明在 `petCancellable` 旁）：

```swift
        // Launch-as-pet: the webView only exists once MainView mounts (windowed form), so
        // wait for the scene to be ready, then flip petMode — the sink above does the rest.
        if startInPet {
            sceneReadyCancellable = appState.characterManager.$isSceneReady
                .receive(on: RunLoop.main)
                .sink { [weak self] ready in
                    guard ready, let self, !self.isPetActive else { return }
                    self.appState.petMode = true
                    self.mainWindow?.alphaValue = 1
                }
            // Fail-safe: if the scene never reports ready (odd webview failure), show the
            // windowed form after 3s instead of leaving the app invisible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.isPetActive else { return }
                self.mainWindow?.alphaValue = 1
            }
        }
```

**Step 2: petMode sink 记住显式选择**

petCancellable 的 sink 体内（`self.isPetActive = petMode` 那行之后）加：

```swift
                self.appState.launchInPetMode = petMode   // remember the explicit choice
```

注意：启动自动 pet 也会写 true（本就是 true，无副作用）；用户双击退出 pet → 写 false → 下次启动直接 windowed，老用户习惯被尊重。

**Step 3: 构建确认**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 4: 手动冒烟（可延到 Task 10 一并验证）**

```bash
scripts/run-app.sh 2>/dev/null || open "$(find ~/Library/Developer/Xcode/DerivedData -name AniCompanion.app -path '*pet-bottom-right*' | head -1)"
```

Expected: 启动后她直接以 pet 形态出现（此刻还是旧尺寸 500×540、顶部对齐——尺寸/位置在后续 task 修）。

**Step 5: Commit**

```bash
git add AniCompanion/App/AppDelegate.swift
git commit -m "feat: launch straight into pet mode (hidden windowed flash, 3s fail-safe)"
```

---

### Task 6: 尺寸系统（QQ 宠物量级 + 持久化）

**Files:**
- Modify: `AniCompanion/App/AppDelegate.swift`（`basePetSize` :52、`currentPetSize` :56、`scalePet` :224-239）

**Step 1: 基准尺寸与缩放范围**

```swift
    private static let basePetSize = NSSize(width: 280, height: 300)
```

`scalePet(by:)` 里 `let minHeight: CGFloat = 280` 改为：

```swift
        let minHeight: CGFloat = 150   // true QQ-pet mini form
```

（`maxHeight: 1100` 不动。）

**Step 2: currentPetSize 持久化恢复**

`applicationDidFinishLaunching` 开头（`appState.initializeServices()` 之后）加——尺寸编码用 `"w,h"` 两个字段，直接解析：

```swift
        let sizeParts = appState.petSizeStorage.split(separator: ",").compactMap { Double($0) }
        if sizeParts.count == 2, sizeParts[0] > 0, sizeParts[1] > 0 {
            currentPetSize = NSSize(width: sizeParts[0], height: sizeParts[1])
        }
```

**Step 3: scalePet 写回存储**

`scalePet(by:)` 末尾（`window.setFrame` 之后）加：

```swift
        appState.petSizeStorage = "\(currentPetSize.width),\(currentPetSize.height)"
```

**Step 4: 构建**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 5: Commit**

```bash
git add AniCompanion/App/AppDelegate.swift
git commit -m "feat: QQ-pet base size 280x300, min 150, persisted across launches"
```

---

### Task 7: 位置系统接线（右下角 + 记忆 + 防抖保存）

**Files:**
- Modify: `AniCompanion/App/AppDelegate.swift`（`enterPet` :125-128、`windowDidMove` :205-213）

**Step 1: enterPet 用 planner 算初始 frame**

`enterPet` 里替换这三行：

```swift
        var f = window.frame
        f.origin.y += f.height - currentPetSize.height
        f.size = currentPetSize
        window.setFrame(f, display: true)
```

为：

```swift
        // Place her at the remembered spot (or bottom-right on first run). Resize BEFORE
        // installing the webView — see the ordering gotcha in CLAUDE.md.
        let f = plannedPetFrame(for: window)
        window.setFrame(f, display: true)
        currentPetSize = f.size
```

新增私有方法（放在 `enterPet` 之后）：

```swift
    /// Where the pet window should sit: the stored frame if its screen is still live,
    /// otherwise the bottom-right of the key screen (PetFramePlanner owns all the rules).
    private func plannedPetFrame(for window: NSWindow) -> NSRect {
        let screens = NSScreen.screens
        let primary = (window.screen ?? NSScreen.main ?? screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let stored = PetFramePlanner.decode(appState.petFrameStorage)
        let anchor = screens.first { $0.deviceIdentifier == appState.petAnchorScreen }
        return PetFramePlanner.restore(storedFrame: stored,
                                       anchorVisible: anchor?.visibleFrame,
                                       fallbackSize: currentPetSize,
                                       primaryVisible: primary)
    }
```

**Step 2: windowDidMove 防抖持久化**

`windowDidMove` 的气泡翻转逻辑保留，方法末尾追加：

```swift
        persistPetFrameShortly()
```

新增成员与方法（防抖 500ms，拖动结束才写 UserDefaults）：

```swift
    private var framePersistWork: DispatchWorkItem?

    /// Debounced (500ms) persistence of her position + anchor screen while she's dragged.
    private func persistPetFrameShortly() {
        guard isPetActive, let window = mainWindow else { return }
        framePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appState.petFrameStorage = PetFramePlanner.encode(window.frame)
            self.appState.petAnchorScreen = window.screen?.deviceIdentifier ?? ""
        }
        framePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
```

**Step 3: 构建 + 全部单测**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **`。

**Step 4: Commit**

```bash
git add AniCompanion/App/AppDelegate.swift
git commit -m "feat: bottom-right anchoring with remembered position + debounced persistence"
```

---

### Task 8: windowed 面板化（红叉不退出）

**Files:**
- Modify: `AniCompanion/App/AppDelegate.swift`（`windowWillClose` :249-255）

**Step 1: 拦截主窗口关闭 = 回 pet 形态**

新增 delegate 方法（放在 `windowWillClose` 旁边），并把 `windowWillClose` 改为纯防御：

```swift
    /// Closing the windowed panel doesn't quit — she goes back to pet form and keeps sitting
    /// at the bottom-right. Quit is ⌘Q (standard menu) only.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, !isPetActive else { return true }
        appState.petMode = true   // enterPet reshapes this same window; no actual close
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Defensive only now: pet mode has no close button, and windowed close is vetoed in
        // windowShouldClose. Keeps auxiliary windows (Settings) from ever quitting the app.
    }
```

（原 `windowWillClose` 里的 terminate 逻辑删除——app 常驻，⌘Q 退出。）

**Step 2: 构建**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 3: Commit**

```bash
git add AniCompanion/App/AppDelegate.swift
git commit -m "feat: windowed is a panel — close returns her to pet form, app stays alive"
```

---

### Task 9: 气泡小窗适配（JS + CSS）

**Files:**
- Modify: `AniCompanion/Resources/ThreeVRM/vrm_scene.html`（`#bubble` CSS :17-57）
- Modify: `AniCompanion/Resources/ThreeVRM/vrm_scene.js`（resize handler，:42-44 附近）

背景：气泡是 HTML `#bubble`（`max-width: 34%` + 15px 字号）。窗口 280 宽时 34% = 95px，完全不可读。小窗时气泡改为**横跨她头顶**（QQ 宠物样式），并限 3 行。

**Step 1: CSS 追加小窗规则**

`vrm_scene.html` 里 `body.bubble-left #bubble::after { ... }` 规则块之后追加：

```css
  /* Small pet window (QQ-pet size): the side bubble would be unreadably narrow, so the
     bubble spans above her head instead. Toggled by the resize handler (innerWidth < 360). */
  body.small-pet #bubble {
    left: 6px;
    right: 6px;
    max-width: none;
    max-height: 30%;
    font-size: 13px;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
  }
  body.small-pet #bubble::after { display: none; }
```

**Step 2: JS resize handler 切换 body class**

`vrm_scene.js` 找到 resize handler（`function` 含 `camera.aspect = ` 的那个，约 :42-44），在更新 aspect 的同一处追加：

```js
  // QQ-pet small form: swap the side bubble for an above-head banner bubble.
  document.body.classList.toggle('small-pet', window.innerWidth < 360);
```

**Step 3: 构建打包资源（资源文件随 bundle 打包，无编译验证——靠 Task 10 手动看）**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

**Step 4: Commit**

```bash
git add AniCompanion/Resources/ThreeVRM/vrm_scene.html AniCompanion/Resources/ThreeVRM/vrm_scene.js
git commit -m "feat: above-head banner bubble for the small pet window"
```

---

### Task 10: 全量验证与收尾

**Step 1: 全部单测 + 构建**

```bash
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' test 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **`（11 个测试，0 失败）。

**Step 2: 真机手动验证清单（需要用户配合，逐项打勾）**

先杀掉可能存在的旧实例再跑新构建：

```bash
pkill -9 AniCompanion 2>/dev/null; sleep 1
APP=$(find ~/Library/Developer/Xcode/DerivedData -name AniCompanion.app -path '*pet-bottom-right*' -newer project.yml | head -1)
lsregister -f "$APP" 2>/dev/null; open "$APP"
```

- [ ] 冷启动：直接小桌宠出现在**右下角**（无大窗口闪现、非居中）
- [ ] 首次尺寸 = 280×300 量级（屏幕高度约 1/6）
- [ ] 滚轮缩小到最小 ≈150 高；放大正常；重启后保持最后尺寸
- [ ] 拖到屏幕中央 → 退出重开 → 原位出现
- [ ] 双击她 → windowed 大面板出现（居中）；点红叉 → 她**回右下角**、app 不退出
- [ ] ⌘Q → app 退出
- [ ] 小尺寸下她说话：气泡横在头顶、13px、可读、最多 3 行
- [ ] 拖到屏幕左半边：气泡 side 翻转（现有逻辑未回归）
- [ ] （如有外接屏）拖到副屏 → 重启在副屏原位；拔副屏重启 → 主屏右下角

**Step 3: companion-layer 无回归确认（根仓库）**

```bash
cd /Users/chenxuewei/hb && pnpm test 2>&1 | tail -5
```

Expected: 全部通过（本次对 TS 层零改动，跑一遍是仓库规矩）。

**Step 4: 收尾 commit（如手动验证中发现小问题修复后）**

```bash
git add -A && git commit -m "fix: manual-verification touch-ups"
```

（无修改则跳过。）

---

## 完成定义

- 11 个单测全绿；构建通过
- 手动清单全勾
- feature/pet-bottom-right 分支上每个 task 一个 commit
- 之后走 superpowers:finishing-a-development-branch 合并收尾
