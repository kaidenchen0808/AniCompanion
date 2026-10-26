import SwiftUI
import MarkdownUI

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
        Markdown(text)
            .markdownTheme(.aniCompanion)
            .markdownImageProvider(.ani)
    }
}

// MARK: - Theme

@MainActor
extension Theme {

    /// Dark-bubble theme: white body text, bright-blue links, dark rounded code blocks.
    static let aniCompanion: Theme = Theme()
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
        }
        .codeBlock { configuration in
            CodeBlockView(code: configuration.content)
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

/// Dark code block with a monospaced scroll view and a copy button (Doubao-style).
struct CodeBlockView: View {

    let code: String
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .padding(.trailing, 36)

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
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
