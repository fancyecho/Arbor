import AppKit

/// Asks the user what to do when a copied/moved item already exists at the destination.
@MainActor
enum ConflictResolver {
    static func ask(_ info: ConflictInfo) async -> (ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        let folder = FileManager.default.displayName(atPath: info.existing.deletingLastPathComponent().path)
        alert.messageText = L("“\(info.existing.lastPathComponent)”已存在于“\(folder)”中")
        alert.informativeText = L("要如何处理？\n\n新的：\(describe(info.source))\n现有：\(describe(info.existing))")
        alert.icon = NSWorkspace.shared.icon(forFile: info.source.path)

        // Folder-on-folder conflicts default to merging; everything else to keeping both.
        var choices: [(String, ConflictChoice)] = info.bothDirectories
            ? [(L("合并"), .merge), (L("保留两者"), .keepBoth)]
            : [(L("保留两者"), .keepBoth)]
        choices += [(L("替换"), .replace), (L("跳过"), .skip), (L("停止"), .stop)]
        for (title, choice) in choices {
            let button = alert.addButton(withTitle: title)
            if choice == .stop { button.keyEquivalent = "\u{1b}" }
            if choice == .replace { button.hasDestructiveAction = true }
        }

        alert.showsSuppressionButton = info.hasMoreItems
        alert.suppressionButton?.title = L("对之后的冲突执行相同操作")

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
        let size = values?.isDirectory == true ? L("文件夹") : Format.bytes(values?.fileSize.map(Int64.init))
        return L("\(size)，修改于 \(Format.date(values?.contentModificationDate))")
    }
}
