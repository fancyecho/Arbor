import AppKit

/// User-facing commands. Menu items, context menus and keyboard handlers all funnel through here
/// so behaviour is identical no matter how a command is invoked.
@MainActor
extension WorkspaceState {
    /// Explicit targets, or the active tab's selection.
    private func targets(_ urls: [URL]?) -> [URL] {
        if let urls { return urls }
        let tab = activeTab
        if tab.viewMode == .space { return tab.selectedItems.map(\.url) }
        return tab.visibleItems.filter { tab.selection.contains($0.url) }.map(\.url)
    }

    var hasSelection: Bool { !activeTab.selection.isEmpty }

    // MARK: Navigation

    func goBack() { activeTab.goBack() }
    func goForward() { activeTab.goForward() }
    func goUp() { activeTab.goUp() }

    func go(to url: URL) {
        if let directory = TabState.resolvedDirectory(url) {
            activeTab.navigate(to: directory)
        } else {
            activeTab.navigate(to: url.deletingLastPathComponent(), select: url)
        }
        focusToken += 1
    }

    func openSelection(_ urls: [URL]? = nil) {
        let tab = activeTab
        let selected = targets(urls)
        let visible = tab.visibleItems
        let items = selected.map { url in visible.first { $0.url == url } ?? FileItem(url: url) }
        // A single folder navigates; multiple items open in their apps, folders in new tabs.
        if items.count == 1, let item = items.first {
            tab.open(item)
            return
        }
        for item in items {
            if item.isNavigable { activePane.newTab(url: item.url, activate: false) } else { NSWorkspace.shared.open(item.url) }
        }
    }

    func openInNewTab(_ url: URL? = nil) {
        let target = url ?? targets(nil).first.flatMap(TabState.resolvedDirectory) ?? activeTab.url
        activePane.newTab(url: target)
    }

    func openInOtherPane(_ url: URL? = nil) {
        guard let other = otherPane else {
            setPaneCount(2)
            openInOtherPane(url)
            return
        }
        let target = url ?? targets(nil).first.flatMap(TabState.resolvedDirectory) ?? activeTab.url
        other.activeTab.navigate(to: target)
    }

    // MARK: Clipboard

    func copy(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        FileClipboard.shared.write(items, cut: false)
    }

    func cut(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        FileClipboard.shared.write(items, cut: true)
    }

    var canPaste: Bool { FileClipboard.shared.hasFiles }

    func paste(into directory: URL? = nil) {
        let clipboard = FileClipboard.shared
        let sources = clipboard.urls
        guard !sources.isEmpty else { return }
        let tab = activeTab
        let destination = directory ?? tab.url
        let completion: ([URL], Error?) -> Void = { [weak self] results, error in
            self?.report(error)
            if destination.isSameFile(as: tab.url) { tab.reload(selecting: Set(results)) }
        }
        if clipboard.isCut {
            clipboard.didPasteCut()
            FileOperationQueue.shared.move(sources, to: destination, completion: completion)
        } else {
            FileOperationQueue.shared.copy(sources, to: destination, completion: completion)
        }
    }

    // MARK: File operations

    func duplicate(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        let tab = activeTab
        FileOperationQueue.shared.duplicate(items) { [weak self] results, error in
            self?.report(error)
            tab.reload(selecting: Set(results))
        }
    }

    func moveToTrash(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        let tab = activeTab
        // Keep the cursor near where it was: select the item after the deleted block.
        let visible = tab.visibleItems
        let lastIndex = visible.lastIndex { items.contains($0.url) } ?? 0
        let next = visible[(lastIndex + 1)...].first { !items.contains($0.url) }
            ?? visible[..<min(lastIndex, visible.count)].last { !items.contains($0.url) }
        FileOperationQueue.shared.trash(items) { [weak self] error in
            self?.report(error)
            tab.reload(selecting: next.map { [$0.url] } ?? [])
        }
    }

    func rename(_ url: URL? = nil) {
        guard let target = url ?? targets(nil).first else { return }
        activeTab.selection = [target]
        activeTab.renamingURL = target
    }

    /// Called by views when inline editing ends. Returns false if the rename failed (e.g. the name is
    /// taken); the item keeps its name and, like Finder, naming resumes once the alert is dismissed.
    @discardableResult
    func commitRename(_ url: URL, to newName: String, in tab: TabState) -> Bool {
        tab.renamingURL = nil
        guard newName != url.lastPathComponent else { return true }
        do {
            let renamed = try FileOperations.rename(url, to: newName)
            FileHistory.shared.record(L("重命名"), steps: [.move(from: renamed, to: url)])
            tab.reload(selecting: [renamed])
            return true
        } catch {
            renameAfterAlert = (tab, url)
            report(error)
            return false
        }
    }

    func newFolder() {
        let tab = activeTab
        do {
            let folder = try FileOperations.newFolder(in: tab.url)
            FileHistory.shared.record(L("新建文件夹"), steps: [.trash(folder)])
            tab.reload(selecting: [folder])
            tab.renamingURL = folder
        } catch {
            report(error)
        }
    }

    func newFile() {
        let tab = activeTab
        do {
            let file = try FileOperations.newFile(in: tab.url)
            FileHistory.shared.record(L("新建文件"), steps: [.trash(file)])
            tab.reload(selecting: [file])
            tab.renamingURL = file
        } catch {
            report(error)
        }
    }

    func copyToOtherPane(move: Bool = false) {
        let items = targets(nil)
        guard !items.isEmpty, let other = otherPane else { return }
        let destinationTab = other.activeTab
        let sourceTab = activeTab
        let completion: ([URL], Error?) -> Void = { [weak self] results, error in
            self?.report(error)
            destinationTab.reload(selecting: Set(results))
            if move { sourceTab.reload() }
        }
        if move {
            FileOperationQueue.shared.move(items, to: destinationTab.url, completion: completion)
        } else {
            FileOperationQueue.shared.copy(items, to: destinationTab.url, completion: completion)
        }
    }

    func batchRename(_ urls: [URL]? = nil) {
        let items = targets(urls)
        batchRenameTargets = items.isEmpty ? activeTab.visibleItems.map(\.url) : items
    }

    // MARK: Undo

    func undo() {
        FileHistory.shared.undo { [weak self] restored, error in self?.didRestore(restored, error) }
    }

    func redo() {
        FileHistory.shared.redo { [weak self] restored, error in self?.didRestore(restored, error) }
    }

    /// Selects restored items if they are in the active folder (the watcher refreshes the rest).
    private func didRestore(_ urls: [URL], _ error: Error?) {
        report(error)
        let tab = activeTab
        let here = urls.filter { $0.deletingLastPathComponent().isSameFile(as: tab.url) }
        if !here.isEmpty { tab.reload(selecting: Set(here)) }
    }

    // MARK: Integrations

    func copyPath(_ urls: [URL]? = nil) {
        let items = targets(urls)
        FileOperations.copyPaths(items.isEmpty ? [activeTab.url] : items)
    }

    func copyPath(_ urls: [URL]? = nil, as style: PathStyle) {
        let items = targets(urls)
        FileOperations.copy(items.isEmpty ? [activeTab.url] : items, as: style)
    }

    /// Opens the selection (or the current folder) in the chosen editor.
    func openInEditor(_ urls: [URL]? = nil) {
        let items = targets(urls)
        FileOperations.openInEditor(items.isEmpty ? [activeTab.url] : items)
    }

    func run(_ command: CustomCommand, on urls: [URL]? = nil) {
        let directory = activeTab.url
        let tab = activeTab
        CommandRunner.run(command, files: targets(urls), directory: directory) { [weak self] output in
            tab.reload()
            if command.mode == .output || !output.succeeded { self?.commandOutput = output }
        }
    }

    func openInTerminal(_ url: URL? = nil) {
        let target = url.flatMap(TabState.resolvedDirectory) ?? activeTab.url
        FileOperations.openInTerminal(target)
    }

    func revealInFinder(_ urls: [URL]? = nil) {
        let items = targets(urls)
        FileOperations.revealInFinder(items.isEmpty ? [activeTab.url] : items)
    }

    func quickLook(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        QuickLookController.shared.toggle(items)
    }

    /// Starts a search in the given scope and focuses the search field.
    func search(in scope: SearchScope) {
        activeTab.searchScope = scope
        searchFocusToken += 1
    }

    /// Selects every visible item with the same type (extension, or folder) as the selection.
    func selectSameType() {
        let tab = activeTab
        let selected = tab.selectedItems
        guard !selected.isEmpty else { return }
        let folders = selected.contains(where: \.isNavigable)
        let extensions = Set(selected.filter { !$0.isNavigable }.map { $0.fileExtension.lowercased() })
        tab.selection = Set(tab.visibleItems.filter {
            $0.isNavigable ? folders : extensions.contains($0.fileExtension.lowercased())
        }.map(\.url))
    }

    func addToShelf(_ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        StashShelf.shared.add(items)
    }

    func selectAll() {
        let tab = activeTab
        tab.selection = Set(tab.visibleItems.map(\.url))
    }

    func toggleHidden() {
        AppSettings.shared.showHidden.toggle()
    }

    /// Shows where the space under `url` (default: the current folder) goes.
    func analyzeSpace(_ url: URL? = nil) {
        if let url, !url.isSameFile(as: activeTab.url) { activeTab.navigate(to: url) }
        setViewMode(.space)
    }

    func setViewMode(_ mode: ViewMode) {
        activeTab.viewMode = mode
        focusToken += 1
    }

    func open(with app: URL, _ urls: [URL]? = nil) {
        let items = targets(urls)
        guard !items.isEmpty else { return }
        NSWorkspace.shared.open(items, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
