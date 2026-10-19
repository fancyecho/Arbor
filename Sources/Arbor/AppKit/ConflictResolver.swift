import AppKit

/// Asks the user what to do when a copied/moved item already exists at the destination.
@MainActor
enum ConflictResolver {
    static func ask(_ info: ConflictInfo) async -> (ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        let folder = FileManager.default.displayName(atPath: info.existing.deletingLastPathComponent().path)
        alert.messageText = "“\(info.existing.lastPathComponent)”已存在于“\(folder)”中"
        alert.informativeText = """
        要如何处理？

        新的：\(describe(info.source))
        现有：\(describe(info.existing))
        """
        alert.icon = NSWorkspace.shared.icon(forFile: info.source.path)

        // Folder-on-folder conflicts default to merging; everything else to keeping both.
        var choices: [(String, ConflictChoice)] = info.bothDirectories
            ? [("合并", .merge), ("保留两者", .keepBoth)]
            : [("保留两者", .keepBoth)]
        choices += [("替换", .replace), ("跳过", .skip), ("停止", .stop)]
        for (title, choice) in choices {
            let button = alert.addButton(withTitle: title)
            if choice == .stop { button.keyEquivalent = "\u{1b}" }
            if choice == .replace { button.hasDestructiveAction = true }
        }

        alert.showsSuppressionButton = info.hasMoreItems
        alert.suppressionButton?.title = "对之后的冲突执行相同操作"

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = choices.indices.contains(index) ? choices[index].1 : .stop
        let applyToAll = alert.suppressionButton?.state == .on && choice != .stop
        return (choice, applyToAll)
    }

    private static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey])
        let size = values?.isDirectory == true ? "文件夹" : Format.bytes(values?.fileSize.map(Int64.init))
        return "\(size)，修改于 \(Format.date(values?.contentModificationDate))"
    }
}
