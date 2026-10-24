import AppKit
import Observation

enum ViewMode: String, CaseIterable {
    case list, grid, columns, space

    var title: String {
        switch self {
        case .list: L("列表")
        case .grid: L("图标")
        case .columns: L("分栏")
        case .space: L("空间")
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .space: "chart.pie"
        }
    }
}

/// One browsing location: a directory, its contents, selection and history.
@MainActor @Observable
final class TabState: Identifiable {
    let id = UUID()

    private(set) var url: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var selection: Set<URL> = []
    var sort = SortOrder()
    var filter = "" {
        didSet { if filter != oldValue { scheduleSearch() } }
    }
    /// Where the filter text searches: this folder (instant filter), the subtree, or Spotlight.
    var searchScope: SearchScope = .folder {
        didSet { if searchScope != oldValue { scheduleSearch() } }
    }
    /// Showing every file with this Finder tag (from the sidebar), via Spotlight.
    private(set) var tagQuery: String?
    private(set) var searchResults: [FileItem] = []
    private(set) var isSearching = false
    private(set) var searchTruncated = false
    var viewMode: ViewMode = .list
    /// Pinned tabs show as an icon, stay first in the tab bar and ignore ⌘W.
    var isPinned = false

    /// Set to start inline rename of this item in whichever view is showing the tab.
    var renamingURL: URL?

    /// Result of "对比窗格", by item name; cleared when the folder changes.
    var compareMarks: [String: CompareStatus] = [:]

    /// First visible item, kept up to date by the list view (not observed: changes on every scroll).
    @ObservationIgnored var scrollAnchor: URL?
    /// Item the view should scroll to the top once it is loaded; cleared by the view.
    var pendingScrollAnchor: URL?

    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var visibleCache: (key: VisibleKey, items: [FileItem])?

    private struct VisibleKey: Equatable {
        var generation: Int, filter: String, sort: SortOrder, showHidden: Bool
        /// Space scans change folder sizes, which matters only when sorting by size.
        var sizes: Int
    }

    @ObservationIgnored private var itemsGeneration = 0
    @ObservationIgnored private var searchCancel: CancelFlag?
    @ObservationIgnored private var spotlight: SpotlightSearch?
    @ObservationIgnored private var searchDebounce: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        load(selecting: nil)
    }

    // MARK: Derived

    var title: String {
        if let tagQuery { return L("标签：\(tagQuery)") }
        return url.path == "/" ? (volumeName ?? "/") : FileManager.default.displayName(atPath: url.path)
    }

    private var volumeName: String? {
        try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }

    /// Items after hidden-file filtering, quick filter and sorting. Cached until an input changes.
    var visibleItems: [FileItem] {
        var sort = self.sort
        sort.foldersFirst = AppSettings.shared.foldersFirst
        let key = VisibleKey(generation: itemsGeneration, filter: filter, sort: sort, showHidden: AppSettings.shared.showHidden,
                             sizes: sort.key == .size ? SpaceIndex.shared.revision : 0)
        _ = items // register observation on the raw items
        _ = searchResults
        if let cache = visibleCache, cache.key == key { return cache.items }

        var result = isSearchMode ? searchResults : items
        if !key.showHidden { result.removeAll { $0.isHidden } }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, !isSearchMode || tagQuery != nil {
            result.removeAll { !NameMatcher.matches($0.name, needle) }
        }
        let folderSizes = sort.key == .size && !isSearchMode ? SpaceIndex.shared.childSizes(of: url) : nil
        result = sort.sorted(result, folderSize: folderSizes.map { sizes in { sizes[$0.lastPathComponent] } })
        visibleCache = (key, result)
        return result
    }

    var selectedItems: [FileItem] {
        let visible = visibleItems.filter { selection.contains($0.url) }
        // The space view can select files deep inside the folder (its largest-files list, the rings).
        guard viewMode == .space, visible.count < selection.count else { return visible }
        let known = Set(visible.map(\.url))
        return visible + selection.subtracting(known).sorted { $0.path < $1.path }.map(FileItem.init(url:))
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    // MARK: Navigation

    func navigate(to newURL: URL, select: URL? = nil) {
        let target = newURL.standardizedFileURL
        guard !target.isSameFile(as: url) else {
            if tagQuery != nil { showTag(nil) }
            if let select { selection = [select] }
            return
        }
        backStack.append(url)
        forwardStack.removeAll()
        go(to: target, select: select)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        go(to: previous, select: url)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        go(to: next, select: nil)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    private func go(to target: URL, select: URL?) {
        FolderMemory.shared.remember(url, selection: selection, anchor: scrollAnchor)
        let memory = FolderMemory.shared.recall(target)
        url = target
        items = []
        itemsGeneration += 1
        selection = []
        filter = ""
        searchScope = .folder
        tagQuery = nil
        compareMarks = [:]
        renamingURL = nil
        scrollAnchor = nil
        pendingScrollAnchor = memory?.anchor
        SidebarStore.shared.visit(target)
        Frecency.shared.visit(target)
        // An explicit selection (e.g. the folder we came up from) wins over the remembered one.
        load(selecting: select.map { [$0] } ?? memory?.selection)
    }

    // MARK: Loading

    /// Reloads the current directory, keeping the selection (or replacing it with `selecting`).
    func reload(selecting: Set<URL>? = nil) {
        load(selecting: selecting ?? selection)
        if isSearchMode { runSearch() }
    }

    // MARK: Searching

    /// Showing results from the subtree or Spotlight instead of the folder's own items.
    var isSearchMode: Bool {
        tagQuery != nil || (searchScope != .folder && !filter.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func showTag(_ tag: String?) {
        tagQuery = tag
        if tag == nil { scheduleSearch() } else { runSearch() }
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        if tagQuery != nil {
            // Tag results are filtered locally by name; no need to query Spotlight again.
            itemsGeneration += 1
            return
        }
        guard isSearchMode else {
            stopSearch()
            searchResults = []
            itemsGeneration += 1
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runSearch() {
        stopSearch()
        let query = filter.trimmingCharacters(in: .whitespaces)
        searchResults = []
        searchTruncated = false
        itemsGeneration += 1
        isSearching = true
        if let tag = tagQuery {
            spotlight = SpotlightSearch(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag)) { [weak self] urls in
                DispatchQueue.global(qos: .userInitiated).async {
                    let found = urls.map(FileItem.init(url:))
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.searchResults = found
                        self.itemsGeneration += 1
                        self.isSearching = false
                    }
                }
            }
            return
        }
        switch searchScope {
        case .folder:
            isSearching = false
        case .subfolders:
            let cancel = CancelFlag()
            searchCancel = cancel
            RecursiveSearch.run(
                root: url, query: query, includeHidden: AppSettings.shared.showHidden, cancel: cancel,
                onBatch: { [weak self] batch in
                    DispatchQueue.main.async {
                        guard let self, !cancel.isCancelled else { return }
                        self.searchResults += batch
                        self.itemsGeneration += 1
                    }
                },
                onDone: { [weak self] truncated in
                    DispatchQueue.main.async {
                        guard let self, !cancel.isCancelled else { return }
                        self.isSearching = false
                        self.searchTruncated = truncated
                    }
                })
        case .spotlight:
            spotlight = SpotlightSearch(text: query) { [weak self] urls in
                DispatchQueue.global(qos: .userInitiated).async {
                    let found = urls.map(FileItem.init(url:))
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.searchResults = found
                        self.itemsGeneration += 1
                        self.isSearching = false
                    }
                }
            }
        }
    }

    private func stopSearch() {
        searchCancel?.cancel()
        searchCancel = nil
        spotlight?.stop()
        spotlight = nil
        isSearching = false
    }

    private func load(selecting: Set<URL>?) {
        loadGeneration += 1
        let generation = loadGeneration
        let target = url
        isLoading = items.isEmpty
        startWatching()

        DirectoryLoader.load(target) { [weak self] result in
            guard let self, generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let loaded):
                self.errorMessage = nil
                if loaded != self.items {
                    self.items = loaded
                    self.itemsGeneration += 1
                }
                // Match by path so URLs with/without a trailing slash still select.
                let wanted = Set((selecting ?? self.selection).map(\.standardizedFileURL.path))
                let matched = Set(loaded.lazy.filter { wanted.contains($0.url.standardizedFileURL.path) }.map(\.url))
                if matched != self.selection { self.selection = matched }
                // Same for an item waiting to be named (a new folder's URL has no trailing slash; the
                // listed one does), so every view recognizes it and opens the name field.
                if let renaming = self.renamingURL,
                   let item = loaded.first(where: { $0.url.isSameFile(as: renaming) }), item.url != renaming {
                    self.renamingURL = item.url
                }
            case .failure(let error):
                self.items = []
                self.itemsGeneration += 1
                self.errorMessage = Self.describe(error, url: target)
            }
        }
    }

    private func startWatching() {
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    private static func describe(_ error: Error, url: URL) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return L("没有权限查看“\(url.lastPathComponent)”的内容。\n可在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中为 Arbor 授权。")
        }
        return error.localizedDescription
    }

    // MARK: Opening

    /// Opens an item: folders navigate in place, everything else opens in its default app.
    func open(_ item: FileItem) {
        if item.isNavigable {
            navigate(to: item.url)
        } else if item.isSymlink, let resolved = Self.resolvedDirectory(item.url) {
            navigate(to: resolved)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    nonisolated static func resolvedDirectory(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true ? resolved : nil
    }
}
