import AppKit

/// Templates and small file utilities.
@MainActor
extension WorkspaceState {
    func newFile(from template: URL) {
        let tab = activeTab
        do {
            let file = try Templates.instantiate(template, in: tab.url)
            FileHistory.shared.record("新建文件", steps: [.trash(file)])
            tab.reload(selecting: [file])
            tab.renamingURL = file
        } catch {
            report(error)
        }
    }

    func openTemplatesFolder() {
        Templates.ensureFolder()
        activePane.newTab(url: Templates.folder)
    }

    /// ⌃⌘N: moves the selection into a new folder and starts renaming it.
    func newFolderWithSelection(_ urls: [URL]? = nil) {
        let items = selectionOrNil(urls)
        guard !items.isEmpty else { return newFolder() }
        let tab = activeTab
        do {
            let (folder, undo) = try FileTools.newFolder(with: items, in: tab.url)
            FileHistory.shared.record("用所选项目新建文件夹", steps: undo)
            tab.reload(selecting: [folder])
            tab.renamingURL = folder
        } catch {
            report(error)
        }
    }

    func flatten(_ folder: URL? = nil) {
        guard let folder = folder ?? selectionOrNil(nil).first.flatMap(TabState.resolvedDirectory) else { return }
        guard confirmFlatten(folder) else { return }
        let tab = activeTab
        Task.detached(priority: .userInitiated) {
            let result = Result { try FileTools.flatten(folder) }
            await MainActor.run {
                switch result {
                case .success(let (moved, undo)):
                    FileHistory.shared.record("平铺文件夹", steps: undo)
                    self.alertMessage = moved == 0 ? "“\(folder.lastPathComponent)”的子文件夹中没有文件。" : nil
                case .failure(let error):
                    self.report(error)
                }
                tab.reload()
            }
        }
    }

    /// Flattening rewrites a whole folder tree, so it always asks first and spells out what will move.
    private func confirmFlatten(_ folder: URL) -> Bool {
        let preview = FileTools.flattenPreview(folder)
        guard preview.fileCount > 0 else {
            alertMessage = "“\(folder.lastPathComponent)”的子文件夹中没有文件。"
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = preview.looksLikeProject ? .critical : .warning
        alert.messageText = "要平铺“\(folder.lastPathComponent)”吗？"
        let names = preview.subfolders.prefix(6).joined(separator: "、") + (preview.subfolders.count > 6 ? " 等" : "")
        var text = "将把 \(preview.subfolders.count) 个子文件夹（\(names)）中的 \(preview.fileCount) 个文件移到“\(folder.lastPathComponent)”里，清空的子文件夹会移到废纸篓。可以用 ⌘Z 撤销。"
        if preview.looksLikeProject {
            text = "⚠️ 这个文件夹看起来是一个代码项目，平铺会打乱它的目录结构，导致无法编译。\n\n" + text
        }
        alert.informativeText = text
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let go = alert.addButton(withTitle: "平铺")
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    func makeLinks(alias: Bool, _ urls: [URL]? = nil) {
        let tab = activeTab
        var created: [URL] = []
        do {
            for item in selectionOrNil(urls) {
                created.append(alias ? try FileTools.makeAlias(to: item) : try FileTools.makeSymlink(to: item))
            }
        } catch {
            report(error)
        }
        FileHistory.shared.record(alias ? "制作替身" : "创建符号链接", steps: created.map { .trash($0) })
        tab.reload(selecting: Set(created))
    }

    func showHashes(_ urls: [URL]? = nil) {
        let items = selectionOrNil(urls)
        guard !items.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let text = FileTools.hashes(items)
            await MainActor.run { self.commandOutput = CommandOutput(title: "文件哈希", text: text, succeeded: true) }
        }
    }

    func exportTree(_ folder: URL? = nil) {
        let root = folder ?? selectionOrNil(nil).first.flatMap(TabState.resolvedDirectory) ?? activeTab.url
        Task.detached(priority: .userInitiated) {
            let text = FileTools.tree(of: root)
            await MainActor.run { self.commandOutput = CommandOutput(title: "目录树：\(root.lastPathComponent)", text: text, succeeded: true) }
        }
    }

    func toggleTag(_ tag: String, _ urls: [URL]? = nil) {
        let items = selectionOrNil(urls)
        do {
            try FinderTags.toggle(tag, on: items)
        } catch {
            report(error)
        }
        activeTab.reload()
    }

    /// Shows every file with this tag in the active tab (Spotlight).
    func showTag(_ tag: String) {
        activeTab.showTag(tag)
        focusToken += 1
    }

    /// Explicit URLs, or the active tab's selection (in display order).
    func selectionOrNil(_ urls: [URL]?) -> [URL] {
        if let urls { return urls }
        let tab = activeTab
        return tab.visibleItems.filter { tab.selection.contains($0.url) }.map(\.url)
    }
}

// MARK: - Image tools

@MainActor
extension WorkspaceState {
    enum ImageJob: Sendable {
        case convert(ImageFormat, maxPixel: Int?)
        case rotate(clockwise: Bool)
        case pdf
        case removeBackground

        var title: String {
            switch self {
            case .convert(let format, let maxPixel): maxPixel.map { "缩小到 \($0) 像素" } ?? "转换为 \(format.title)"
            case .rotate(let clockwise): clockwise ? "向右旋转" : "向左旋转"
            case .pdf: "合成 PDF"
            case .removeBackground: "移除背景"
            }
        }
    }

    /// Runs an image job in the background; new files are selected and everything is undoable.
    func runImageJob(_ job: ImageJob, _ urls: [URL]? = nil) {
        let images = selectionOrNil(urls).filter(ImageTools.isImage)
        guard !images.isEmpty else { return }
        let tab = activeTab
        let directory = tab.url
        Task.detached(priority: .userInitiated) {
            var created: [URL] = []
            var undo: [UndoStep] = []
            var failure: Error?
            do {
                switch job {
                case .convert(let format, let maxPixel):
                    for url in images {
                        // Downscaling keeps the original format; JPEG stays JPEG etc.
                        let target = maxPixel == nil ? format
                            : ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() || ($0 == .jpeg && url.pathExtension.lowercased() == "jpeg") } ?? .jpeg
                        created.append(try ImageTools.convert(url, to: target, maxPixel: maxPixel))
                    }
                case .rotate(let clockwise):
                    for url in images { undo = try ImageTools.rotate(url, clockwise: clockwise) + undo }
                case .pdf:
                    created.append(try ImageTools.makePDF(images, in: directory))
                case .removeBackground:
                    for url in images { created.append(try ImageTools.removeBackground(url)) }
                }
            } catch {
                failure = error
            }
            let steps = created.reversed().map { UndoStep.trash($0) } + undo
            let results = created, error = failure
            await MainActor.run {
                FileHistory.shared.record(job.title, steps: steps)
                self.report(error)
                tab.reload(selecting: results.isEmpty ? nil : Set(results))
            }
        }
    }
}
