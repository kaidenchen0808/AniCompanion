import SwiftUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - ChatView

/// A chat interface displaying the conversation history with a text input bar at the bottom.
///
/// User messages appear right-aligned in blue bubbles; assistant messages appear
/// left-aligned in gray bubbles. Includes a text input field, send button, and
/// microphone button for voice input. Auto-scrolls to the latest message.
struct ChatView: View {

    @ObservedObject var conversationController: ConversationController
    @ObservedObject var conversationHistory: ConversationHistory

    /// The current text input value.
    @State private var inputText: String = ""

    /// Focus state for the text input field.
    @FocusState private var isInputFocused: Bool

    // MARK: / 技能选择器状态

    /// All discovered skills (~/.claude/skills), scanned on appear.
    @State private var allSkills: [Skill] = []
    /// Skills attached to the next message (chips above the input).
    @State private var selectedSkills: [Skill] = []
    /// Panel visibility — typing `/` at the start of the input opens it.
    @State private var skillPanelVisible = false
    /// Keyboard-highlighted row while the panel is open.
    @State private var skillHighlightIndex = 0

    // MARK: 贴图（多模态输入）

    /// Images attached to the next message (paste ⌘V / drag & drop / file picker).
    @State private var pendingImages: [NSImage] = []

    /// 非图片附件（文本/PDF/二进制）：预览条显示文件卡片，发送时把 payload 拼进文本。
    /// payload 两种形态：内联全文（[文件 …]…，文本/PDF）或裸路径（二进制，网关失信兜底会代读）。
    struct PendingFile: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let payload: String
        var isPath: Bool { payload.hasPrefix("/") || payload.hasPrefix("~") }
    }
    @State private var pendingFiles: [PendingFile] = []

    /// 滚动内容底部 Y（离底检测，驱动回到底部浮标）。
    @State private var bottomOffset: CGFloat = 0

    /// 深度思考开关（默认开；关 = 快问快答，网关对 GLM 端点 thinking:disabled）
    @AppStorage("thinking_enabled") private var thinkingEnabled = true

    /// Auto-follow only after the user interacts in THIS window session — reopening
    /// the window must not yank the viewport to the bottom (bug 2026-10-27).
    @State private var shouldAutoScroll = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Message List

            ScrollViewReader { scrollProxy in
                ScrollView {
                    // 离底检测:滚动内容底部相对视口位置
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollBottomOffsetKey.self,
                            value: geo.frame(in: .named("chatScroll")).maxY
                        )
                    }
                    .frame(height: 0)
                    LazyVStack(spacing: 16) {
                        // Top-of-list sentinel: appearing (i.e. scrolled to the very top) pages
                        // older history in. No-op when there is nothing older.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { loadOlderIfNeeded(proxy: scrollProxy) }

                        let visibleMessages = conversationHistory.messages.filter { $0.role != .system && !$0.isHidden }
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(
                                visibleMessages[index - 1].timestamp, inSameDayAs: message.timestamp
                            ) {
                                DaySeparator(date: message.timestamp)
                            }
                            MessageBubbleView(
                                message: message,
                                isLastAssistant: message.role == .assistant && message.id == visibleMessages.last?.id,
                                onRegenerate: { Task { await conversationController.regenerate() } },
                                onDelete: { conversationHistory.removeById(message.id) }
                            )
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        // Streaming text or typing indicator (single view type for LazyVStack stability).
                        // Gated on `isStreaming` (not `isProcessing`) so the indicator disappears
                        // as soon as the response text is committed, rather than lingering through
                        // TTS playback while 小光 is still speaking.
                        if conversationController.isStreaming {
                            AssistantProcessingView(
                                streamingText: conversationController.streamingText,
                                thinkingText: conversationController.thinkingText
                            )
                            .id("typing-indicator")
                        }
                    }
                    // Entrance animation on NEW messages only (last-id keyed — top-paging
                    // prepends and mid-list deletions deliberately don't animate).
                    .animation(.easeOut(duration: 0.18), value: conversationHistory.messages.last?.id)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                // Bottom-scroll on NEW messages only (append changes the last id); prepending
                // older history or mid-list deletion must not yank the viewport.
                .onChange(of: conversationHistory.messages.last?.id) { _, _ in
                    if shouldAutoScroll { scrollToBottom(proxy: scrollProxy) }
                }
                .onChange(of: conversationController.isStreaming) { _, streaming in
                    // 真流式跟底（哪怕刚开窗她在打字）；静态翻转不再拉底
                    if streaming { shouldAutoScroll = true; scrollToBottom(proxy: scrollProxy) }
                }
                .onChange(of: conversationController.streamingText) { _, _ in
                    if conversationController.isStreaming { scrollToBottom(proxy: scrollProxy) }
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(ScrollBottomOffsetKey.self) { newValue in
                    // 离底 > 400pt 显示浮标;有未读新消息(流式中且离底)带红点
                    bottomOffset = newValue
                }
                .overlay(alignment: .bottomTrailing) {
                    if showBackToBottom {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scrollToBottom(proxy: scrollProxy, animated: false)
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Circle()
                                    .fill(Color.black.opacity(0.55))
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                if conversationController.isStreaming {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
            }

            // MARK: - Error Banner

            if let error = conversationController.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        conversationController.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // MARK: - Lookup 任务指示条（[lookup] 二段进行中：消灭等待黑洞）

            if let status = conversationController.lookupStatusText {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.purple.opacity(0.9))
                        .symbolEffect(.pulse)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        conversationController.cancelLookup()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                            .buttonStyle(.plain)
                            .help("取消查询")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // MARK: - Skill chips（选中技能挂在输入框上）

            if !selectedSkills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedSkills) { skill in
                            SkillChip(skill: skill) {
                                selectedSkills.removeAll { $0 == skill }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            // MARK: - Skill Picker Panel（行首 / 触发）

            if skillPanelVisible {
                SkillPickerPanel(
                    skills: filteredSkills,
                    highlightIndex: $skillHighlightIndex,
                    onSelect: { attachSkill($0) }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            // MARK: - Input Card（豆包式输入卡片：附件/输入/工具行一体）

            VStack(spacing: 8) {
                // 卡片内部顶部:附件缩略图 + 文件卡片
                if !pendingImages.isEmpty || !pendingFiles.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.black.opacity(0.75))
                                        .background(Circle().fill(.white).padding(1))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                        }
                        // 文件卡片：图标 + 文件名 + 形态标注（内联/路径），与图片缩略图同一条
                        ForEach(pendingFiles) { file in
                            ZStack(alignment: .topTrailing) {
                                HStack(spacing: 6) {
                                    Image(systemName: file.icon)
                                        .font(.system(size: 18))
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        Text(file.isPath ? "路径 · 她会代读" : "已内联")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: 170)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                                Button {
                                    pendingFiles.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.black.opacity(0.75))
                                        .background(Circle().fill(.white).padding(1))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 输入区（自适应高度）
                multiLineInput

                // 卡片内部底部:工具行
                HStack(spacing: 14) {
                    Toggle(isOn: $thinkingEnabled) {
                        Text("深度思考")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Button {
                        pickAttachment()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("发送图片或文件")

                    Button {
                        toggleVoiceInput()
                    } label: {
                        Image(systemName: conversationController.isListening ? "mic.fill" : "mic")
                            .font(.system(size: 14))
                            .foregroundStyle(conversationController.isListening ? Color.red : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(conversationController.fullDuplexEnabled)
                    .help(conversationController.fullDuplexEnabled
                        ? "Voice interruption is on — just talk to interrupt her"
                        : (conversationController.isListening ? "Stop listening" : "Start voice input"))

                    Spacer(minLength: 0)

                    // 发送/停止（卡片内右下角圆形按钮）
                    if conversationController.isStreaming {
                        Button {
                            conversationController.cancel()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Stop generating")
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(canSend ? Color(red: 0.35, green: 0.55, blue: 1.0) : Color.secondary.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send message")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
        .background(Color.clear)
        .onAppear {
            isInputFocused = true
            shouldAutoScroll = false  // 打开窗口不自动跳底（bug 修复）
            allSkills = SkillStore.scan(root: SkillStore.defaultRoot)
        }
    }

    // MARK: - Helpers

    /// Back-to-bottom FAB shows once the viewport is a screen away from the bottom.
    private var showBackToBottom: Bool { bottomOffset > 700 }

    /// Whether the send button should be enabled.
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingImages.isEmpty
            || !pendingFiles.isEmpty
    }

    /// Panel list: skills filtered by the text after the leading `/`.
    private var filteredSkills: [Skill] {
        let query = inputText.hasPrefix("/") ? String(inputText.dropFirst()) : ""
        return Array(SkillStore.filter(allSkills, query: query).prefix(30))
    }

    /// Multi-line input (auto-grow 1-6 lines, Enter/Shift+Enter) + paste/drop image support.
    private var multiLineInput: some View {
                // Multi-line input field: auto-grows 1–6 lines (scrolls beyond),
            // Enter sends / Shift+Enter inserts a newline.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: inputEditorHeight)
                    .frame(maxHeight: 132, alignment: .topLeading)

                if inputText.isEmpty {
                    Text("给她说点什么…（/ 选技能 · ⌘V 贴图 · Shift+Enter 换行）")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 0)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .focused($isInputFocused)
            .onKeyPress(keys: Set([KeyEquivalent("v")])) { press in
                if press.modifiers.contains(.command) { pasteImageIfAny() }
                return .ignored  // 文本粘贴照常
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDroppedAttachments(providers)
                return true
            }
            .onChange(of: inputText) { _, newValue in
                // 行首 `/` 打开技能面板，其余输入关闭；query = / 后的文本
                if newValue.hasPrefix("/") {
                    skillPanelVisible = true
                    skillHighlightIndex = 0
                } else if skillPanelVisible {
                    skillPanelVisible = false
                }
            }
            .onKeyPress(.return, phases: .down) { handleReturnKey($0) }
            .onKeyPress(.downArrow, phases: .down) { _ in handleArrowKey(+1) }
            .onKeyPress(.upArrow, phases: .down) { _ in handleArrowKey(-1) }
            .onKeyPress(.escape, phases: .down) { _ in handleEscapeKey() }
    }

    /// Enter: skill panel open → select the highlighted skill; otherwise send.
    /// Shift+Return (and any other modifier combo) falls through to a newline.
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        if skillPanelVisible, !press.modifiers.contains(.shift) {
            if filteredSkills.indices.contains(skillHighlightIndex) {
                attachSkill(filteredSkills[skillHighlightIndex])
            }
            return .handled
        }
        guard !press.modifiers.contains(.shift) else { return .ignored }
        sendMessage()
        return .handled
    }

    private func handleArrowKey(_ delta: Int) -> KeyPress.Result {
        guard skillPanelVisible else { return .ignored }
        let next = skillHighlightIndex + delta
        guard filteredSkills.indices.contains(next) else { return .ignored }
        skillHighlightIndex = next
        return .handled
    }

    private func handleEscapeKey() -> KeyPress.Result {
        guard skillPanelVisible else { return .ignored }
        skillPanelVisible = false
        inputText = ""
        return .handled
    }

    /// Attach a skill chip, clear the `/` query, close the panel.
    private func attachSkill(_ skill: Skill) {
        if !selectedSkills.contains(skill) {
            selectedSkills.append(skill)
        }
        inputText = ""
        skillPanelVisible = false
        shouldAutoScroll = true
    }

    /// Auto-grow height for the input editor: text height measured at a conservative
    /// width (real lines never get clipped — an underestimate just leaves slack),
    /// clamped to the single-line … 6-line band; beyond that the editor scrolls inside.
    private var inputEditorHeight: CGFloat {
        let attributed = NSAttributedString(
            string: inputText.isEmpty ? " " : inputText + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let bounds = attributed.boundingRect(
            with: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return min(max(bounds.height + 16, 36), 132)
    }

    /// Send the current input text as a message.
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingFiles.isEmpty else { return }

        inputText = ""
        skillPanelVisible = false
        shouldAutoScroll = true

        // / 技能面板选中项 → [{name, content}]（SKILL.md 正文，网关截断兜底）
        let skills = selectedSkills.map { ["name": $0.name, "content": SkillStore.loadBody(for: $0)] }
        selectedSkills.removeAll()

        // 非图片附件载荷拼在文字前（内联文件/路径），纯图无文字时保留占位
        var outgoing = text
        if !pendingFiles.isEmpty {
            outgoing = pendingFiles.map(\.payload).joined(separator: "\n") + (outgoing.isEmpty ? "" : "\n" + outgoing)
        }
        if outgoing.isEmpty && !pendingImages.isEmpty { outgoing = "（看看这张图）" }
        pendingFiles.removeAll()

        // 贴图 → JPEG（最长边 1024，控制体积）随消息发送；网关路由视觉模型
        let imageData = pendingImages.compactMap { Self.jpegData(from: $0) }
        pendingImages.removeAll()

        Task {
            await conversationController.sendMessage(
                outgoing,
                skills: skills,
                images: imageData,
                thinking: thinkingEnabled
            )
        }
    }

    // MARK: - 贴图输入

    private func pasteImageIfAny() {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else { return }
        appendImage(img)
    }

    /// 📎 — file picker; route by type: image / readable text (incl. PDF) / path reference.
    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要发给她的图片或文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        routeAttachment(url: url)
    }


    /// 附件路由核心（📎 与拖拽共用）：PDF→文字层内联/扫描页渲染；图片→pendingImages；
    /// 文本/Office→内联卡片；其他→路径卡片（网关失信兜底代读）。
    private func routeAttachment(url: URL) {
        guard pendingFiles.count < 6 else { return }  // 上限防载荷/预览条双溢出（与图片 4 张同理）
        let name = url.lastPathComponent
        // PDF 必须在 NSImage 判定之前：macOS 的 NSImage(contentsOf:) 对 PDF 恒成功
        // （产出单页低清栅格图，吞掉文字层与多页）——2026-10-28 用户实测：产品 PDF 被
        // 当成一张模糊图发给视觉模型，叠加历史话题后答成了"简历"。
        if url.pathExtension.lowercased() == "pdf" {
            if let text = Self.extractText(from: url), !text.isEmpty {
                let clipped = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…（已截断）" : text
                pendingFiles.append(PendingFile(name: name, icon: "doc.text", payload: "[文件 \(name)]\n\(clipped)\n[文件结束 —— 关于这个文件：]"))
                return
            }
            // 扫描版（无文字层）：渲染前 N 页走视觉通道
            let pages = Self.renderPdfPages(url, limit: 4 - pendingImages.count)
            if !pages.isEmpty {
                pages.forEach(appendImage)
                return
            }
            pendingFiles.append(PendingFile(name: name, icon: "doc.badge.ellipsis", payload: url.path))
            return
        }
        if let img = NSImage(contentsOf: url) {
            appendImage(img)
            return
        }
        // 文本类/Office 内联抽取：她直接读到内容，快
        if let text = Self.extractText(from: url) ?? Self.extractOfficeText(from: url), !text.isEmpty {
            let clipped = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…（已截断）" : text
            pendingFiles.append(PendingFile(name: name, icon: "doc.text", payload: "[文件 \(name)]\n\(clipped)\n[文件结束 —— 关于这个文件：]"))
            return
        }
        // 其他（二进制/超大）：附路径，网关失信兜底会自动派 Read 代读
        pendingFiles.append(PendingFile(name: name, icon: "doc.badge.ellipsis", payload: url.path))
    }

    /// 拖拽附件：fileURL 优先走与 📎 相同的路由（PDF 若先查 NSImage 会被吃成单页栅格图，
    /// canLoadObject(NSImage) 对 PDF provider 恒 true）；无 fileURL 的纯图片数据才直读 NSImage。
    private func handleDroppedAttachments(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    let url: URL?
                    switch data {
                    case let u as URL: url = u
                    case let d as Data: url = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d)) as URL?
                    case let s as NSString: url = URL(fileURLWithPath: String(s))
                    default: url = nil
                    }
                    if let url {
                        Task { @MainActor in routeAttachment(url: url) }
                    }
                }
                continue
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let img = object as? NSImage {
                        Task { @MainActor in appendImage(img) }
                    }
                }
            }
        }
    }

    /// PDF 页数（0=打不开/损坏）。 */
    private static func pdfPageCount(_ url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// 把 PDF 前N页渲染成 NSImage（扫描版走视觉通道用；渲染失败返回空）。
    private static func renderPdfPages(_ url: URL, limit: Int) -> [NSImage] {
        guard limit > 0, let doc = PDFDocument(url: url) else { return [] }
        var images: [NSImage] = []
        for i in 0..<min(limit, doc.pageCount) {
            guard let page = doc.page(at: i) else { continue }
            // 页面原始尺寸渲染（PDF 点位），vision 侧 jpegData 再压边
            let bounds = page.bounds(for: .mediaBox)
            let img = page.thumbnail(of: CGSize(width: bounds.width, height: bounds.height), for: .mediaBox)
            images.append(img)
        }
        return images
    }

    /// Office 文档（docx/pptx/xlsx）文本抽取——系统工具链，零三方依赖（2026-10-27 实验验证）：
    /// docx → textutil；pptx → slides XML 的 <a:t>；xlsx → sharedStrings 的 <t>。
    /// Process 跑固定二进制+固定参数（不经 shell，路径来自 NSOpenPanel，无注入面）。
    private static func extractOfficeText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "docx":
            let out = runSystemTool("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path]) ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
        case "pptx":
            let xml = runSystemTool("/usr/bin/unzip", ["-p", url.path, "ppt/slides/slide*.xml"]) ?? ""
            return xmlText(xml, tag: "a:t")
        case "xlsx":
            let xml = runSystemTool("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"]) ?? ""
            return xmlText(xml, tag: "t")
        default:
            return nil
        }
    }

    /// 跑系统工具拿 stdout（失败/非零退出返回 nil）。stderr 必须排空：子进程写满管道
    /// 缓冲（损坏 zip 的 unzip 每条目一条 warning 极易超 64KB）会卡死 stdout 读取。
    private static func runSystemTool(_ path: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { _ in
            // 排空即丢（unzip warning 不进结果）；handler 会自动持续回调直到 EOF
            _ = errPipe.fileHandleForReading.availableData
        }
        defer { errPipe.fileHandleForReading.readabilityHandler = nil }
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// 从 OOXML 流里抽出指定标签的文本，实体还原，按行拼接（空=返回 nil）。
    private static func xmlText(_ xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]*)</\(tag)>"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = xml as NSString
        let lines = regex.map { regex in
            regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
                match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)) : nil
            }
        } ?? []
        let text = lines
            .map { $0
                // &amp; 必须最后：先解会把 &amp;lt; 双重解码成 <
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Text extraction: plain-text extensions read directly; PDF via PDFKit. Nil = not readable.
    private static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let textExtensions: Set<String> = ["txt", "md", "json", "csv", "log", "swift", "ts", "js", "py", "sh", "yaml", "yml", "html", "css", "xml"]
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let t = page.string { out += t + "\n" }
                if out.count > 20_000 { break }
            }
            return out.isEmpty ? nil : out
        }
        guard textExtensions.contains(ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func appendImage(_ img: NSImage) {
        guard pendingImages.count < 4 else { return }  // 与网关每轮 4 图上限对齐
        pendingImages.append(img)
    }

    /// 长边压到 1024 的 JPEG（体积与视觉模型注意力平衡）。
    private static func jpegData(from image: NSImage) -> Data? {
        let maxSide: CGFloat = 1024
        var size = image.size
        if max(size.width, size.height) > maxSide {
            let scale = maxSide / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Toggle voice input on or off.
    private func toggleVoiceInput() {
        if conversationController.isListening {
            conversationController.stopVoiceInput()
        } else {
            Task {
                await conversationController.startVoiceInput()
            }
        }
    }

    /// Scroll to the bottom of the message list.
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if conversationController.isStreaming {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let lastMessage = conversationHistory.messages.last(where: { $0.role != .system && !$0.isHidden }) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    /// Page older history in at the top, anchored to the previous oldest message so the
    /// viewport stays put (no jump to bottom — the last-id onChange deliberately skips prepends).
    private func loadOlderIfNeeded(proxy: ScrollViewProxy) {
        guard let anchorId = conversationHistory.messages.first?.id else { return }
        guard conversationHistory.loadOlder(limit: 100) else { return }
        proxy.scrollTo(anchorId, anchor: .top)
    }
}

// MARK: - Scroll Bottom Offset（离底检测）

private struct ScrollBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Day Separator

/// "Today" / "Yesterday" / date divider between chat days (Doubao-style).
private struct DaySeparator: View {

    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.06))
            )
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - MessageBubbleView

/// A single chat message displayed as a rounded bubble.
///
/// User messages are right-aligned with a blue background; assistant messages
/// are left-aligned with a dark gray background.
private struct MessageBubbleView: View {

    /// 消息渲染分段：普通文字 / 文件附件（user 气泡把内联载荷显示为胶囊而非裸铺原文）。
    struct MessagePart: Identifiable {
        let id = UUID()
        var isFile = false
        var name = ""
        var chars = 0
        var preview = ""
        var text = ""
    }

    /// 把消息内容按 [文件 …]…[文件结束…] 载荷拆段（兼容完整与压缩后的结束标记）。
    private static func splitFilePayloads(_ content: String) -> [MessagePart] {
        guard content.contains("[文件 ") else { return [MessagePart(text: content)] }
        var parts: [MessagePart] = []
        var rest = Substring(content)
        while let start = rest.range(of: "[文件 ") {
            if !rest[..<start.lowerBound].isEmpty {
                parts.append(MessagePart(text: String(rest[..<start.lowerBound])))
            }
            let after = rest[start.lowerBound...]
            guard let endMark = after.range(of: "[文件结束") else {
                parts.append(filePart(from: after))  // 残缺载荷：整体当一个文件段
                rest = ""
                break
            }
            parts.append(filePart(from: after[..<endMark.lowerBound]))
            if let eol = after.range(of: "\n", range: endMark.lowerBound..<after.endIndex) {
                rest = after[eol.upperBound...]
            } else {
                rest = ""
            }
        }
        if !rest.isEmpty { parts.append(MessagePart(text: String(rest))) }
        return parts
    }

    /// "[文件 名]\n正文" → 附件段（名 + 字数 + 前 400 字预览供 tooltip）。
    private static func filePart(from payload: Substring) -> MessagePart {
        let lines = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(lines.first ?? "")
        let name = head.hasPrefix("[文件 ") && head.hasSuffix("]") ? String(head.dropFirst(4).dropLast()) : head
        let body = lines.count > 1 ? String(lines[1]) : ""
        return MessagePart(isFile: true, name: name.isEmpty ? "文件" : name, chars: body.count, preview: String(body.prefix(400)))
    }

    let message: ChatMessage
    /// Regeneration is offered only on the very last assistant message.
    var isLastAssistant: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            // Role icon
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser, let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingPanel(text: thinking, isThinking: false)
                }

                if isUser {
                    // 内联文件载荷不裸铺原文（2423 字 PDF 直显非常乱）——渲染成附件胶囊
                    let parts = Self.splitFilePayloads(message.displayContent)
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(parts) { part in
                            if part.isFile {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.fill")
                                        .font(.system(size: 10))
                                    Text("\(part.name) · \(part.chars) 字")
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.white.opacity(0.18)))
                                .help(part.preview)
                            } else if !part.text.isEmpty {
                                Text(part.text)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.blue.opacity(0.6))
                    )
                } else {
                    // 千问范式:AI 回复不用气泡 —— 全宽文档流直渲;代码块/表格/公式等
                    // 富媒体元素自带深色圆角卡,形成"文档嵌卡片"层次。
                    VStack(alignment: .leading, spacing: 10) {
                        MarkdownView(text: message.displayContent)

                        let cards = FilePathDetector.matches(in: message.displayContent)
                            .filter { !isImagePath($0.absolute) }
                        if !cards.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(cards, id: \.raw) { FileCardView(match: $0) }
                            }
                        }

                        // hover 工具条:消息底部一排小图标(复制/重生成/删除)
                        if hovering {
                            HStack(spacing: 14) {
                                hoverTool(icon: copied ? "checkmark" : "doc.on.doc", help: "复制") { copyMessage() }
                                if isLastAssistant {
                                    hoverTool(icon: "arrow.clockwise", help: "重新生成") { onRegenerate?() }
                                }
                                hoverTool(icon: "trash", help: "删除") { onDelete?() }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 2)
                            .transition(.opacity)
                        }
                    }
                }

                Text(formattedTimestamp)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .opacity(hovering ? 1 : 0)
            }
            .contextMenu {
                Button {
                    copyMessage()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if isLastAssistant {
                    Button {
                        onRegenerate?()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            // User icon
            if isUser {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .onHover { hovering = $0 }
    }

    /// Image extensions render via the markdown image pipeline, not as file cards.
    private func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// Small ghost icon button for the hover tool bar (Doubao-style bottom row).
    private func hoverTool(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Copy the tag-stripped Markdown source to the pasteboard.
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.displayContent, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    /// Format the message timestamp for display.
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - AssistantProcessingView

/// Combined view that shows either animated typing dots (waiting for first token)
/// or live streaming text. Uses a single view type so LazyVStack identity stays stable.
private struct AssistantProcessingView: View {

    let streamingText: String
    /// Live reasoning stream — shown in an expandable panel ABOVE the bubble (thinking
    /// arrives before the reply text; the dots stay visible while only thinking exists).
    var thinkingText: String = ""

    @State private var animating = false

    private var cleanedText: String {
        ConversationController.stripEmotionTags(from: streamingText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.purple.opacity(0.8))
                .frame(width: 24, height: 24)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                if !thinkingText.isEmpty {
                    ThinkingPanel(text: thinkingText, isThinking: true)
                }

                if cleanedText.isEmpty {
                    // Typing dots — waiting for first token
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .offset(y: animating ? -4 : 0)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                        .repeatForever()
                                        .delay(Double(index) * 0.15),
                                    value: animating
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
                } else {
                    // Live streaming text + blinking tail cursor
                    VStack(alignment: .trailing, spacing: 2) {
                        MarkdownView(text: cleanedText, textSelectionEnabled: false)
                        StreamingCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
                }
            }

            Spacer(minLength: 40)
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Thinking Panel

/// Collapsible reasoning panel (Doubao-style). Live: "思考中…" expanded with a pulsing
/// brain icon; settled on a message: "思考过程" collapsed by default.
private struct ThinkingPanel: View {

    let text: String
    var isThinking: Bool

    @State private var expanded: Bool
    @State private var pulsing = false

    init(text: String, isThinking: Bool) {
        self.text = text
        self.isThinking = isThinking
        // Live panels start expanded (watch her think in real time); committed ones collapsed.
        _expanded = State(initialValue: isThinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple.opacity(pulsing ? 0.9 : 0.45))
                    Text(isThinking ? "思考中…" : "思考过程")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .onAppear {
            guard isThinking else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Streaming Cursor

/// Blinking caret shown at the tail of the streaming bubble (Doubao-style "still typing").
private struct StreamingCursor: View {

    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.85))
            .frame(width: 2, height: 14)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Preview

#Preview {
    let history = ConversationHistory()
    let ws = ChatBackend.hermes.makeTransport(
        BackendConfig(endpoint: ChatBackend.hermes.defaultEndpoint, apiKey: "", model: ChatBackend.hermes.defaultModel)
    )
    let controller = ConversationController(
        chatTransport: ws,
        ttsService: MockTTSService(),
        audioPlayer: AudioPlayerService(),
        history: history
    )

    ChatView(
        conversationController: controller,
        conversationHistory: history
    )
    .frame(width: 360, height: 600)
    .preferredColorScheme(.dark)
}

// MARK: - Mock Services for Preview

private final class MockTTSService: TTSServiceProtocol, Sendable {
    let apiKey: String = ""
    let groupID: String = ""
    let voiceID: String = ""

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
