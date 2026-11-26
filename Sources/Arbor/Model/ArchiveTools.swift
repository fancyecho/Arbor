import AppKit
import Foundation

/// Archive detection and compression / extraction through Keka (or another chosen archiver),
/// falling back to macOS's built-in `ditto` (ZIP) and Archive Utility when no external tool is used.
enum ArchiveTools {
    static let extensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "zst", "tzst", "lz4", "lzma", "cab", "xip", "cpio",
        "aar", "jar", "war", "ear", "lha", "lzh", "sit", "sitx", "ace",
    ]

    /// Compound extensions like `.tar.gz` or `.tar.zst`.
    private static let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.lzma"]

    static func isArchive(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return false }
        let lower = url.lastPathComponent.lowercased()
        if compoundSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func isArchive(_ item: FileItem) -> Bool {
        guard !item.isNavigable else { return false }
        let lower = item.name.lowercased()
        if compoundSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        return extensions.contains(item.fileExtension.lowercased())
    }

    /// Bundle IDs of extract-only tools (they can unpack archives, but cannot create them).
    private static let extractOnlyBundleIDs: Set<String> = [
        "cx.c3.theunarchiver",
    ]

    static func supportsCompression(bundleID: String) -> Bool {
        !extractOnlyBundleIDs.contains(bundleID)
    }

    /// Compresses `urls`: hands off to Keka / chosen external archiver if available and capable,
    /// otherwise creates a `.zip` with macOS `ditto` (preserving Finder metadata, undoable).
    @MainActor
    static func compress(_ urls: [URL], in directory: URL, completion: @escaping @MainActor ([URL], Error?) -> Void) {
        guard !urls.isEmpty else { return }
        let settings = AppSettings.shared
        if settings.archiverBundleID != ExternalApp.systemArchiverBundleID,
           supportsCompression(bundleID: settings.archiverBundleID),
           let appURL = settings.archiverURL {
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([], error) } }
            }
            return
        }
        compressWithDitto(urls, in: directory, completion: completion)
    }

    /// Extracts `urls` with Keka / chosen external archiver, or macOS Archive Utility.
    @MainActor
    static func extract(_ urls: [URL], completion: @escaping @MainActor (Error?) -> Void) {
        guard !urls.isEmpty else { return }
        let appURL = AppSettings.shared.archiverURL ?? ExternalApp.archiveUtilityURL
        guard let appURL else {
            FileOperations.open(urls)
            completion(nil)
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Built-in ZIP creation using `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`.
    @MainActor
    static func compressWithDitto(_ urls: [URL], in directory: URL,
                                  completion: @escaping @MainActor ([URL], Error?) -> Void) {
        let baseName: String
        if urls.count == 1 {
            let item = urls[0]
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))?.isDirectory == true
            let stem = isDir ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
            baseName = (stem.isEmpty ? L("归档") : stem) + ".zip"
        } else {
            baseName = L("归档") + ".zip"
        }
        let target = FileOperations.uniqueURL(for: baseName, in: directory)
        let targetPath = target.path
        let sources = urls

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if sources.count == 1 {
                    try runDitto(args: ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, targetPath])
                } else {
                    // Stage symlinks/hardlinks or zip from a temporary staging directory so multiple items
                    // share a clean archive root without absolute path prefixes.
                    let fm = FileManager.default
                    let staging = fm.temporaryDirectory.appendingPathComponent("arbor-zip-\(UUID().uuidString)", isDirectory: true)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: staging) }
                    for src in sources {
                        let link = FileOperations.uniqueURL(for: src.lastPathComponent, in: staging)
                        try fm.copyItem(at: src, to: link)
                    }
                    try runDitto(args: ["-c", "-k", "--sequesterRsrc", staging.path, targetPath])
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        FileHistory.shared.record(L("压缩"), steps: [.trash(target)])
                        completion([target], nil)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: target)
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([], error) } }
            }
        }
    }

    private static func runDitto(args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "app.arbor.archive", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.isEmpty ? L("压缩失败（退出码 \(process.terminationStatus)）。") : msg,
            ])
        }
    }
}
