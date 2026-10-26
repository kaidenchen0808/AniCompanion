import SwiftUI
import Quartz

// MARK: - File Card

/// Card for a local file path found in an assistant reply — icon + name + size,
/// tap to Quick Look (missing files render greyed out).
struct FileCardView: View {

    let match: FilePathDetector.Match

    @State private var exists: Bool = true
    @State private var sizeLabel: String = ""
    @State private var showPreview = false

    var body: some View {
        Button {
            if exists { showPreview = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(exists ? 0.75 : 0.3))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text((match.absolute as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(exists ? 0.95 : 0.4))
                        .lineLimit(1)
                    Text(exists ? sizeLabel : "文件不存在或已移除")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if exists {
                    Image(systemName: "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(exists ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear(perform: stat)
        .sheet(isPresented: $showPreview) {
            QuickLookWindow(url: match.fileURL)
        }
    }

    private var icon: String {
        let ext = (match.absolute as NSString).pathExtension
        return FilePathDetector.symbol(for: ext)
    }

    private func stat() {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: match.absolute, isDirectory: &isDir), !isDir.boolValue else {
            exists = false
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: match.absolute)[.size] as? Int64) ?? nil
        if let bytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            sizeLabel = formatter.string(fromByteCount: bytes)
        } else {
            sizeLabel = match.absolute
        }
    }
}

// MARK: - Quick Look（QLPreviewView 包装，sheet 呈现）

/// Wraps AppKit's `QLPreviewView` in a sheet — avoids `QLPreviewPanel`'s responder-chain
/// requirements (its `beginPreviewPanelControl` dance needs a controlled window, brittle
/// inside SwiftUI).
struct QuickLookWindow: View {

    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("关闭") { NSApp.keyWindow?.sheets.first?.orderOut(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            QuickLookPreviewView(url: url)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct QuickLookPreviewView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
