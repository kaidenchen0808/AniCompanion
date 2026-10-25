import Foundation
import CryptoKit
import Combine

/// Owns the Kokoro voicepack on disk: …/Voicepack/kokoro/{model.int8.onnx, tokens.txt,
/// voices.bin, lexicon-zh.txt, lexicon-us-en.txt, espeak-ng-data/, manifest.json}.
///
/// Install = preflight (free space) → download(tmp) → sha256 verify → ditto unzip(staging)
/// → atomic replace → manifest. A failure at any step cleans its temp artifacts — never a
/// half-installed pack. `state` is published so Settings can observe progress across window
/// close/reopen.
@MainActor
final class VoicepackStore: ObservableObject {

    static let shared = VoicepackStore()

    enum State: Equatable {
        case idle
        case downloading(Double)      // 0...1
        case installed
        case failed(String)
    }
    @Published private(set) var state: State

    // Release asset constants —— make-voicepack.sh 发布后回填 expectedSHA256（现在占位，
    // 校验逻辑仍完整实现并测试；单测里注入 expectedSHA256）。
    nonisolated static let releaseAssetURL = URL(string: "https://github.com/catsmice/AniCompanion/releases/download/voicepack-kokoro-v1/kokoro-zh-v1.zip")!
    nonisolated static let expectedSHA256 = "PENDING-RELEASE"
    nonisolated static let expectedSizeBytes: Int64 = 150_000_000
    nonisolated static let packVersion = "v1"

    nonisolated static let manifestName = "manifest.json"
    nonisolated static let downloadTmpName = ".download.tmp"
    nonisolated static let stagingName = ".staging"

    enum VoicepackError: LocalizedError, Equatable {
        case checksumMismatch
        case unzipFailed(Int32)          // ditto exit code
        case insufficientDiskSpace
        case badResponse

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return String(localized: "Voice pack download failed verification. Please try again.",
                              comment: "Voicepack: downloaded zip sha256 mismatch")
            case .unzipFailed(let code):
                return String(localized: "Voice pack unpacking failed (code \(code)).",
                              comment: "Voicepack: ditto nonzero exit code")
            case .insufficientDiskSpace:
                return String(localized: "Not enough free disk space to install the voice pack.",
                              comment: "Voicepack: needs more than 2x pack size free")
            case .badResponse:
                return String(localized: "Voice pack download failed (bad server response).",
                              comment: "Voicepack: non-2xx HTTP status")
            }
        }
    }

    /// The payload files that must all exist under kokoro/ for the pack to count as
    /// installed (v1.13.8 layout — lexicon-us-en.txt included; a hand-deleted file falls
    /// back to not-installed so Settings offers a reinstall).
    nonisolated static let keyFileNames = ["model.int8.onnx", "tokens.txt", "voices.bin",
                               "lexicon-zh.txt", "lexicon-us-en.txt"]

    let rootDirectory: URL
    nonisolated var kokoroDirectory: URL { rootDirectory.appendingPathComponent("kokoro", isDirectory: true) }
    private let expectedSHA256Hex: String
    private let expectedSize: Int64
    private let freeSpaceProvider: () -> Int64
    private var downloadTask: Task<Void, Never>?

    /// `directoryOverride` exists for unit tests (an injected temp dir, used as-is and
    /// never created); production uses …/Application Support/AniCompanion/Voicepack
    /// (created on first access).
    init(directoryOverride: URL? = nil,
         expectedSHA256: String = VoicepackStore.expectedSHA256,
         expectedSizeBytes: Int64 = VoicepackStore.expectedSizeBytes,
         freeSpaceProvider: @escaping () -> Int64 = { VoicepackStore.volumeFreeSpace() }) {
        self.expectedSHA256Hex = expectedSHA256
        self.expectedSize = expectedSizeBytes
        self.freeSpaceProvider = freeSpaceProvider
        if let override = directoryOverride {
            self.rootDirectory = override
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AniCompanion/Voicepack", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.rootDirectory = base
        }
        self.state = .idle
        // All stored properties initialized — computed properties are fair game now.
        // Judge by the same key-file set as `isInstalled` (not just the manifest): a present
        // manifest with hand-deleted files must not report installed.
        if isInstalled { state = .installed }
    }

    // MARK: - Introspection

    /// All key payload files present + espeak-ng-data is a directory. Checked on every
    /// access (no caching) so an out-of-band hand-deleted file is caught immediately.
    var isInstalled: Bool {
        let fm = FileManager.default
        for name in Self.keyFileNames {
            guard fm.fileExists(atPath: kokoroDirectory.appendingPathComponent(name).path) else { return false }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: kokoroDirectory.appendingPathComponent("espeak-ng-data").path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return true
    }

    /// The version recorded by the last successful install (manifest.json), nil when absent.
    var installedVersion: String? {
        let url = kokoroDirectory.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(VoicepackManifest.self, from: data) else { return nil }
        return manifest.version
    }

    /// Download + unzip needs roughly 2× the pack size (zip + extracted) — require strictly
    /// more than that so the atomic replace never runs out of room mid-flight.
    var hasEnoughFreeSpace: Bool { freeSpaceProvider() > expectedSize * 2 }

    // MARK: - Install

    /// Starts the install pipeline. Re-entrant-safe: an in-flight download or an already
    /// installed pack returns immediately; insufficient disk space fails fast.
    func install() {
        guard !isInstalled, downloadTask == nil else { return }
        guard hasEnoughFreeSpace else {
            state = .failed(VoicepackError.insufficientDiskSpace.localizedDescription)
            return
        }
        state = .downloading(0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runInstall()
                self.state = .installed
            } catch {
                // A user cancel returns to idle, not a red banner. The session surfaces
                // cancellation as URLError(.cancelled); Task.checkCancellation throws
                // CancellationError — accept both (cancelInstall may already have reset
                // state; whichever runs last converges on .idle).
                let isCancellation = error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                if isCancellation {
                    self.state = .idle
                } else {
                    self.state = .failed(error.localizedDescription)
                }
                self.cleanupTemps()
            }
            self.downloadTask = nil
        }
    }

    /// Cancels an in-flight install (Settings Cancel button): cancels the structured task
    /// (which propagates into the URLSession via its cancellation handler) and clears temps.
    func cancelInstall() {
        downloadTask?.cancel()
        downloadTask = nil
        cleanupTemps()
        state = .idle
    }

    /// download(tmp) → sha256 verify → ditto unzip(staging) → locate payload → atomic
    /// replace → manifest. Every throw path leaves the previous (or absent) pack untouched;
    /// temps are cleaned by the caller and again at the end.
    private func runInstall() async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        // 1. Download via a delegate-backed session (per-task progress needs a delegate;
        //    the shared session gives none). Lands in rootDirectory/.download.tmp.
        let zipURL = rootDirectory.appendingPathComponent(Self.downloadTmpName)
        try? fm.removeItem(at: zipURL)
        try await download(to: zipURL)
        try Task.checkCancellation()

        // 2. Verify (off the main actor — hashing ~150 MB takes a beat).
        let digest = try await Self.sha256Hex(ofFile: zipURL)
        guard digest == expectedSHA256Hex else { throw VoicepackError.checksumMismatch }
        try Task.checkCancellation()

        // 3. Unzip with /usr/bin/ditto (off the main actor — it's synchronous).
        let staging = rootDirectory.appendingPathComponent(Self.stagingName)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.unzip(zip: zipURL, into: staging)
        try Task.checkCancellation()

        // 4. The zip's top level may be kokoro/ or loose files — take the first directory
        //    containing model.int8.onnx (or staging itself when the files are loose).
        guard let payload = Self.locatePayload(in: staging) else {
            throw VoicepackError.unzipFailed(-1)   // unzipped, but no model inside
        }

        // 5. Atomic swap into place.
        if fm.fileExists(atPath: kokoroDirectory.path) {
            _ = try fm.replaceItemAt(kokoroDirectory, withItemAt: payload)
        } else {
            try fm.moveItem(at: payload, to: kokoroDirectory)
        }

        // 6. Record the version, then drop temps (staging residue after a move is fine).
        try writeManifest(version: Self.packVersion)
        cleanupTemps()
    }

    /// Downloads the release zip into `destination`, publishing progress as
    /// `.downloading(fraction)`. The session is invalidated on both success and failure so
    /// the delegate (and its continuation box) is never leaked.
    private func download(to destination: URL) async throws {
        let delegate = DownloadDelegate(destination: destination) { [weak self] fraction in
            self?.state = .downloading(fraction)
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        do {
            // The download already lands at `destination` via the delegate; the handler's
            // result (the temp URL) is intentionally unused.
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    session.downloadTask(with: URLRequest(url: Self.releaseAssetURL)).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()   // surfaces to the delegate as a URLError(.cancelled)
            }
            session.finishTasksAndInvalidate()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    private func cleanupTemps() {
        let fm = FileManager.default
        try? fm.removeItem(at: rootDirectory.appendingPathComponent(Self.downloadTmpName))
        try? fm.removeItem(at: rootDirectory.appendingPathComponent(Self.stagingName))
    }

    // MARK: - Manifest

    /// Writes {"version": …} (+ install timestamp) into kokoro/manifest.json, creating the
    /// directory if needed so the call is valid in isolation (tests).
    func writeManifest(version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: kokoroDirectory, withIntermediateDirectories: true)
        let manifest = VoicepackManifest(version: version, installedAt: Date())
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: kokoroDirectory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: - Helpers

    private struct VoicepackManifest: Codable {
        var version: String
        var installedAt: Date?
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through SHA256 in 4 MB chunks (a 150 MB pack must not be slurped
    /// into one allocation). Runs detached; call with await from the main actor.
    private nonisolated static func sha256Hex(ofFile url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// `/usr/bin/ditto -x -k <zip> <dir>` — Apple's zip extractor (handles resource forks
    /// and encodings better than a Swift zip lib, zero dependencies). Runs detached so the
    /// synchronous wait never blocks the main actor.
    private nonisolated static func unzip(zip: URL, into staging: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, staging.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw VoicepackError.unzipFailed(process.terminationStatus)
            }
        }.value
    }

    /// First directory under `staging` that directly contains model.int8.onnx, or staging
    /// itself when the files are loose at the top level. Nil = no payload in the zip.
    nonisolated static func locatePayload(in staging: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appendingPathComponent("model.int8.onnx").path) {
            return staging
        }
        guard let entries = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent("model.int8.onnx").path) {
                return entry
            }
        }
        return nil
    }

    /// Free space on the volume hosting Application Support (where the pack lands).
    nonisolated static func volumeFreeSpace() -> Int64 {
        let probe = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// URLSessionDownloadDelegate box for one install download. The session retains its
/// delegate; the delegate never retains the session (the store invalidates the session on
/// completion), so no retain cycle. All delegate callbacks arrive on the session's serial
/// delegate queue, making the one-shot `continuation` handoff safe. Progress hops back to
/// the main actor via an isolated closure — the callbacks themselves are nonisolated.
// @unchecked Sendable: the mutable `continuation` is only touched on the serial delegate
// queue (checked-then-cleared in `finish()`), but the protocol now inherits Sendable and a
// mutable stored property trips the strict-concurrency warning.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    let destination: URL
    let progressHandler: @MainActor @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL,
         progressHandler: @escaping @MainActor @Sendable (Double) -> Void) {
        self.destination = destination
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = progressHandler
        Task { @MainActor in handler(min(max(fraction, 0), 1)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // A non-2xx body (e.g. an HTML error page) still "downloads successfully".
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(VoicepackStore.VoicepackError.badResponse))
            return
        }
        // The system deletes `location` when this method returns — move it into place now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // The success path resumes in didFinishDownloadingTo; this only carries failures
        // (including cancellation surfaced by the task-cancel handler).
        guard let error else { return }
        finish(.failure(error))
    }

    /// Resumes the continuation exactly once (delegate queue is serial; the nil check plus
    /// clear makes double-delivery — finish then didComplete(nil) — a no-op).
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
