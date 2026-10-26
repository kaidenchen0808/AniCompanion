import SwiftUI
import SwiftMath

/// Block-level LaTeX formula, rendered by SwiftMath (KaTeX port, bundled fonts).
/// Fed by the ```math fence that `MarkdownNormalizer` converts `$$...$$` into.
/// Render failure (bad latex) falls back to the literal source in monospace.
struct MathBlockView: View {

    let latex: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                Text(latex)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear(perform: render)
    }

    private func render() {
        var formatter = MathImage(
            latex: latex.trimmingCharacters(in: .whitespacesAndNewlines),
            fontSize: 17,
            textColor: MTColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        )
        let (err, img, _) = formatter.asImage()
        if err == nil, let ns = img {
            image = ns
        }
    }
}
