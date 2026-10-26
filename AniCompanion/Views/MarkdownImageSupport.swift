import SwiftUI
import MarkdownUI

// MARK: - Image Provider（http/file 双源加载）

/// Loads markdown images from BOTH the network and local `file://` URLs — the brain
/// replies with web images (lookup results) and local paths (files she Read on disk).
struct AniImageProvider: ImageProvider {

    func makeImage(url: URL?) -> some View {
        RemoteOrLocalImage(url: url)
    }
}

extension ImageProvider where Self == AniImageProvider {
    /// `.markdownImageProvider(.ani)` — http + file:// dual-source loading.
    static var ani: AniImageProvider { .init() }
}

/// Async image with loading/failed placeholders, aspect-fit under a bubble-friendly cap.
struct RemoteOrLocalImage: View {

    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if url == nil {
                failureView("无图片地址")
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 120)
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
                    .task { await load() }
            }
        }
        .frame(maxWidth: 460)
    }

    private func load() async {
        guard let url else { return }
        // Local file: synchronous read is fine off-main via Task.detached semantics of await
        if url.isFileURL {
            if let data = try? Data(contentsOf: url), let ns = NSImage(data: data) {
                image = ns
            }
            return
        }
        // Remote: 8 MB cap — she curates images, but a stray huge file shouldn't stall the bubble
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           data.count <= 8 * 1024 * 1024,
           let ns = NSImage(data: data) {
            image = ns
        }
    }

    private func failureView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .padding(10)
    }
}
