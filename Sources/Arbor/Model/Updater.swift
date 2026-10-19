import AppKit
import Observation

/// A release version like `v0.1.0`, `v0.2.0-dev.3`. Previews sort before the release they lead up to.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    /// `dev.N` / `beta.N` / `rc.N` number; nil for a final release.
    let preview: Int?

    init?(tag: String) {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = parts[0].split(separator: ".").map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
        let values = numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count)
        (major, minor, patch) = (values[0], values[1], values[2])
        if parts.count == 2 {
            // "dev.3" → 3; a suffix without a number counts as preview 0.
            preview = parts[1].split(separator: ".").compactMap { Int($0) }.last ?? 0
        } else {
            preview = nil
        }
    }

    static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.preview, b.preview) {
        case let (x?, y?): return x < y
        case (_?, nil): return true // a preview comes before the final release
        default: return false
        }
    }

    var description: String { "\(major).\(minor).\(patch)" + (preview.map { "-dev.\($0)" } ?? "") }
}

struct ReleaseInfo: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let size: Int
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, prerelease, draft, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    var version: ReleaseVersion? { ReleaseVersion(tag: tagName) }

    /// The zipped app in the release ("Arbor-….zip").
    var appArchive: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("arbor") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    /// Newest release this build should offer, or nil if `current` is up to date.
    static func newest(in releases: [ReleaseInfo], after current: ReleaseVersion, includePreviews: Bool) -> ReleaseInfo? {
        releases
            .filter { !$0.draft && (includePreviews || !$0.prerelease) && $0.appArchive != nil }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?.0
    }
}

/// Checks GitHub Releases for a newer build, downloads it, and swaps it in after Arbor quits.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Shows the update sheet in the frontmost window.
    var showsSheet = false

    let repository: String
    let currentTag: String
    var currentVersion: ReleaseVersion? { ReleaseVersion(tag: currentTag) }

    private let defaults = AppDefaults.store

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        repository = info["ArborUpdateRepository"] as? String ?? "fancyecho/Arbor"
        currentTag = ProcessInfo.processInfo.environment["ARBOR_FAKE_CURRENT_TAG"]
            ?? info["ArborReleaseTag"] as? String
            ?? "v" + (info["CFBundleShortVersionString"] as? String ?? "0.0.0")
    }

    var lastCheck: Date? {
        get { defaults.object(forKey: "updates.lastCheck") as? Date }
        set { defaults.set(newValue, forKey: "updates.lastCheck") }
    }

    /// On launch: quietly check at most once every 20 hours; only speak up if there's an update.
    func checkInBackgroundIfDue() {
        guard AppSettings.shared.autoCheckUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 20 * 3600 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        if case .checking = phase { return }
        if case .downloading = phase { return }
        phase = .checking
        if userInitiated { showsSheet = true }
        let current = currentVersion ?? ReleaseVersion(tag: "0.0.0")!
        let includePreviews = AppSettings.shared.includePreviewUpdates
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Arbor-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let releases = try decoder.decode([ReleaseInfo].self, from: data)
                lastCheck = Date()
                if let newest = ReleaseInfo.newest(in: releases, after: current, includePreviews: includePreviews) {
                    phase = .available(newest)
                    showsSheet = true
                } else {
                    phase = .upToDate
                }
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    func install(_ release: ReleaseInfo) {
        guard let asset = release.appArchive else { return }
        phase = .downloading(release, 0)
        let downloader = Downloader { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(release, fraction)
            }
        }
        Task {
            do {
                let archive = try await downloader.download(asset.browserDownloadURL)
                phase = .installing
                let newApp = try await Task.detached { try Self.unpack(archive) }.value
                try Self.scheduleReplacement(with: newApp)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    func dismiss() {
        showsSheet = false
        if case .downloading = phase { return }
        phase = .idle
    }

    // MARK: Installing

    enum UpdateError: LocalizedError {
        case server(Int), badArchive, wrongApp, notWritable(String)

        var errorDescription: String? {
            switch self {
            case .server(let code): "GitHub 返回了错误（\(code)）。"
            case .badArchive: "下载的文件里没有找到 Arbor.app。"
            case .wrongApp: "下载的应用不是 Arbor，已取消更新。"
            case .notWritable(let path): "没有权限替换 \(path)。请把 Arbor 放到“应用程序”文件夹，或手动下载更新。"
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Unzips with `ditto` (keeps code signatures and extended attributes) and checks the bundle id.
    nonisolated private static func unpack(_ archive: URL) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("arbor-update-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }
        return app
    }

    /// A tiny script waits for this process to exit, swaps the bundles, and relaunches.
    private static func scheduleReplacement(with newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
        let q = PathFormatter.shellQuoted
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(target.path + ".old"))
        mv \(q(target.path)) \(q(target.path + ".old")) && mv \(q(newApp.path)) \(q(target.path)) && rm -rf \(q(target.path + ".old"))
        xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        open \(q(target.path))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-update-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [file.path]
        try shell.run()
    }
}

/// URLSession download with progress callbacks.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: Updater.UpdateError.server(http.statusCode))
            continuation = nil
            return
        }
        // The temp file is deleted when this returns, so move it somewhere we own first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Arbor-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
