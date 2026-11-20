import AppKit
import Observation

/// Emptying the Trash, like Finder's 清倒废纸篓: the home Trash plus the Trash on every mounted disk.
/// Arbor deletes the items itself; when it can't read the Trash (no Full Disk Access) it asks Finder.
@MainActor @Observable
final class TrashBin {
    static let shared = TrashBin()

    /// While items are being deleted (the menu item and buttons wait for it).
    private(set) var isEmptying = false

    /// What's in the Trash: top-level items, or nil when the Trash can't be read.
    struct Summary: Equatable {
        var count: Int
        var readable: Bool
    }

    /// This user's Trash folders: ~/.Trash, and `.Trashes/<uid>` on each other mounted volume.
    nonisolated static func folders() -> [URL] {
        var folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
        let uid = getuid()
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            let trash = volume.appendingPathComponent(".Trashes/\(uid)")
            if FileManager.default.fileExists(atPath: trash.path) { folders.append(trash) }
        }
        return folders
    }

    /// Whether `url` is one of the Trash folders (the pane is showing the Trash).
    /// Path-only (no disk access): it runs every time a pane header draws.
    nonisolated static func isTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path { return true }
        return path.hasSuffix("/.Trashes/\(getuid())")
    }

    nonisolated static func summary(of folders: [URL] = folders()) -> Summary {
        var count = 0
        var readable = true
        for folder in folders {
            do {
                count += try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }.count
            } catch {
                // Only the home Trash decides readability; another disk's Trash may simply be gone.
                if folder == folders.first { readable = false }
            }
        }
        return Summary(count: count, readable: readable)
    }

    /// Asks first (unless ⌥ is held, like Finder's ⌥⇧⌘⌫), then deletes everything in the Trash.
    func empty(workspace: WorkspaceState? = nil) {
        guard !isEmptying else { return }
        let skipConfirmation = NSEvent.modifierFlags.contains(.option)
        let summary = Self.summary()
        if summary.readable, summary.count == 0 {
            let alert = NSAlert()
            alert.messageText = L("废纸篓是空的。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
            return
        }
        if !skipConfirmation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = summary.readable
                ? L("要永久抹掉废纸篓中的 \(summary.count) 个项目吗？")
                : L("要永久抹掉废纸篓中的项目吗？")
            alert.informativeText = L("此操作无法撤销，项目也不能再放回原处。")
            alert.addButton(withTitle: L("清倒废纸篓"))
            alert.addButton(withTitle: L("取消"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isEmptying = true
        let folders = Self.folders()
        let readable = summary.readable
        Task.detached(priority: .userInitiated) {
            let failures: [String]?
            if readable {
                failures = Self.deleteContents(of: folders)
            } else {
                failures = (try? Self.askFinder()) != nil ? [] : nil
            }
            await MainActor.run {
                self.isEmptying = false
                self.finish(failures: failures, workspace: workspace)
            }
        }
    }

    private func finish(failures: [String]?, workspace: WorkspaceState?) {
        guard let failures else {
            workspace?.alertMessage = L("无法清倒废纸篓：Arbor 没有权限读取废纸篓，也没能请访达代劳。可在「系统设置 › 隐私与安全性」中为 Arbor 授予完全磁盘访问权限或允许它控制访达。")
            return
        }
        Self.playSound()
        for tab in workspace?.panes.flatMap(\.tabs) ?? [] where Self.isTrash(tab.url) { tab.reload() }
        if !failures.isEmpty {
            let names = failures.prefix(5).joined(separator: "、")
            workspace?.alertMessage = L("有 \(failures.count) 个项目没能删除（\(names)），它们可能正在使用中。")
        }
    }

    /// Deletes every item inside `folders`. Returns the names that couldn't be deleted.
    nonisolated static func deleteContents(of folders: [URL]) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) else { continue }
            for item in items where item.lastPathComponent != ".DS_Store" {
                do {
                    try fm.removeItem(at: item)
                } catch {
                    // Locked items (Finder's 已锁定) refuse to go; unlock everything inside and try once more.
                    unlock(item)
                    do { try fm.removeItem(at: item) } catch { failures.append(item.lastPathComponent) }
                }
            }
        }
        return failures
    }

    private nonisolated static func unlock(_ url: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [],
                                             errorHandler: { _, _ in true }) else { return }
        for case let child as URL in enumerator {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: child.path)
        }
    }

    /// Without access to ~/.Trash, Finder empties it (macOS asks once whether Arbor may control Finder).
    private nonisolated static func askFinder() throws {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        if let error { throw NSError(domain: "Arbor.Trash", code: 1, userInfo: error as? [String: Any]) }
    }

    /// The crumple Finder plays.
    private static func playSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}
