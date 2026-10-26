import SwiftUI
import MarkdownUI
import Highlightr

/// Renders assistant chat content as Markdown, themed for the dark chat bubbles.
struct MarkdownView: View {

    let text: String
    var textSelectionEnabled: Bool = true

    var body: some View {
        if textSelectionEnabled {
            base.textSelection(.enabled)
        } else {
            base.textSelection(.disabled)
        }
    }

    private var base: some View {
        Markdown(MarkdownNormalizer.normalize(text))
            .markdownTheme(.aniCompanion)
            .markdownImageProvider(.ani)
            // 中文回复"一行一句"是高频排版——软换行渲染成空格会把整段挤成一坨
            .markdownSoftBreakMode(.lineBreak)
    }
}

// MARK: - Theme

@MainActor
extension MarkdownUI.Theme {

    /// Dark-bubble theme: white body text, bright-blue links, dark rounded code blocks.
    static let aniCompanion: MarkdownUI.Theme = MarkdownUI.Theme()
        .text {
            FontSize(14)
            ForegroundColor(.white)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12.5)
            ForegroundColor(.white.opacity(0.92))
        }
        .link {
            ForegroundColor(Color(red: 0.45, green: 0.7, blue: 1.0))
            UnderlineStyle(.single)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 2)
                    }
                    .frame(maxHeight: .infinity, alignment: .leading)
                )
                .markdownMargin(top: .em(0.3), bottom: .em(0.3))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    ForegroundColor(.white.opacity(0.88))
                    FontSize(13)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1.0))
                .frame(width: 16)
                .markdownMargin(top: .em(0.2))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.6), bottom: .em(0.3))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.3)) }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.25))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
        }
        .codeBlock { configuration in
            if configuration.language == "math" {
                // $$...$$ 块级公式（MarkdownNormalizer 归一成 ```math 围栏）→ KaTeX 渲染
                MathBlockView(latex: configuration.content)
            } else {
                CodeBlockView(code: configuration.content, language: configuration.language)
            }
        }
        .image { configuration in
            // Rounded block-level images (http + file:// both arrive via AniImageProvider)
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.25))
        }
}

// MARK: - Code block with copy button

/// Dark code block with a monospaced scroll view, syntax highlighting (Highlightr,
/// when the fence names a language) and a copy button (Doubao-style).
struct CodeBlockView: View {

    let code: String
    var language: String? = nil
    @State private var copied = false
    @State private var highlighted: NSAttributedString?

    /// Shared Highlightr instance (loads highlight.js bundle once per process).
    @MainActor private static let highlightr: Highlightr? = {
        let hl = Highlightr()
        hl?.setTheme(to: "atom-one-dark")
        return hl
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let highlighted {
                        Text(AttributedString(highlighted))
                    } else {
                        Text(code)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .textSelection(.enabled)
                .padding(12)
            }
            .padding(.trailing, 36)
            .task { highlight() }

            HStack(spacing: 2) {
                if let language, !language.isEmpty, language != "text" {
                    Text(language)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.trailing, 4)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(copied ? 0.95 : 0.55))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制代码")
            }
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func highlight() {
        guard highlighted == nil, let hl = Self.highlightr else { return }
        // 无语言标注 / 高亮失败 → 保持纯文本（不阻塞渲染）
        guard let language, !language.isEmpty, language != "text" else { return }
        if let attr = hl.highlight(code, as: language, fastRender: true) {
            highlighted = attr
        }
    }
}
