import AppKit

enum FileOperationError: LocalizedError {
    case invalidName(String)
    case exists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): L("“\(name)”不是有效的文件名。")
        case .exists(let name): L("已存在名为“\(name)”的项目。")
        }
    }
}

enum FileOperations {
    private static var fm: FileManager { .default }

    // MARK: Naming

    /// "报告.pdf" → "报告 2.pdf" → "报告 3.pdf" … until the name is free in `directory`.
    static func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        // Strip an existing " N" suffix so duplicating "a 2" yields "a 3", not "a 2 2".
        if let range = base.range(of: #" \d+$"#, options: .regularExpression) { base.removeSubrange(range) }
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains(":") {
            throw FileOperationError.invalidName(name)
        }
    }

    // MARK: Synchronous operations (copy/move/trash go through FileOperationQueue)

    static func isSameVolume(_ sources: [URL], _ destination: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        let target = volume(destination)
        return sources.allSatisfy { volume($0)?.isEqual(target) ?? false }
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        try validate(name: newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        if target == url { return url }
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        if !caseOnly, fm.fileExists(atPath: target.path) { throw FileOperationError.exists(newName) }
        try fm.moveItem(at: url, to: target)
        return target
    }

    static func newFolder(in directory: URL) throws -> URL {
        let target = uniqueURL(for: L("未命名文件夹"), in: directory)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    static func newFile(in directory: URL, name: String = L("未命名.txt")) throws -> URL {
        let target = uniqueURL(for: name, in: directory)
        guard fm.createFile(atPath: target.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        return target
    }

    // MARK: Integrations

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @MainActor
    static func openInTerminal(_ directory: URL) {
        NSWorkspace.shared.open([directory], withApplicationAt: AppSettings.shared.terminalURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    static func openInEditor(_ urls: [URL]) {
        guard let editor = AppSettings.shared.editorURL else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copy(_ urls: [URL], as style: PathStyle) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(PathFormatter.format(urls, style), forType: .string)
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Clipboard with cut semantics

/// Files go on the general pasteboard as file URLs so they interoperate with Finder.
/// A cut is remembered locally: pasting moves instead of copies, then clears the mark.
final class FileClipboard {
    static let shared = FileClipboard()

    private var cutChangeCount: Int?

    func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        cutChangeCount = cut ? pb.changeCount : nil
    }

    var urls: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    var isCut: Bool { cutChangeCount == NSPasteboard.general.changeCount }

    var hasFiles: Bool { !urls.isEmpty }

    func didPasteCut() { cutChangeCount = nil }
}
