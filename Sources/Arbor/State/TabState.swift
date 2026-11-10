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
    /// Groups in the list view ("使用群组" in Finder).
    var groupBy: GroupBy = .none
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
    @ObservationIgnored private var groupsCache: (key: GroupsKey, groups: [FileGroup])?
    @ObservationIgnored private var rowsCache: (key: RowsKey, rows: [FileItem])?
    @ObservationIgnored private var childrenCache: (key: ChildrenKey, children: [String: [FileItem]])?

    private struct VisibleKey: Equatable {
        var generation: Int, filter: String, sort: SortOrder, showHidden: Bool
        /// Space scans change folder sizes, which matters only when sorting by size; Spotlight's
        /// last-opened dates arrive later, which matters only when sorting by them.
        var sizes: Int
        var lastOpened = 0
    }

    private struct GroupsKey: Equatable {
        var visible: VisibleKey, groupBy: GroupBy, revision: Int, day: Int
    }

    private struct RowsKey: Equatable {
        var visible: VisibleKey, groups: Bool, groupBy: GroupBy, tree: Int, showsTree: Bool
    }

    private struct ChildrenKey: Equatable {
        var tree: Int, sort: SortOrder, showHidden: Bool, sizes: Int, lastOpened: Int
    }

    // MARK: Tree (folders expanded in the list view)

    /// Folders (standardized paths) whose contents show indented under them in the list view.
    private(set) var expandedFolders: Set<String> = []
    /// Bumps when an expanded folder's contents load or change.
    private(set) var treeRevision = 0
    @ObservationIgnored private var childItems: [String: [FileItem]] = [:]
    @ObservationIgnored private var childWatchers: [String: DirectoryWatcher] = [:]
    /// Folders expanded with ⌥: their subfolders expand too as they load.
    @ObservationIgnored private var expandingAll: Set<String> = []
    /// Selection remembered for items inside expanded folders, applied once those folders load.
    @ObservationIgnored private var pendingTreeSelection: Set<String> = []
    @ObservationIgnored private var treeGeneration = 0
    private static let expandAllLimit = 400

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
        let key = visibleKey
        _ = items // register observation on the raw items
        _ = searchResults
        if let cache = visibleCache, cache.key == key { return cache.items }

        var result = isSearchMode ? searchResults : items
        if !key.showHidden { result.removeAll { $0.isHidden } }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, !isSearchMode || tagQuery != nil {
            result.removeAll { !NameMatcher.matches($0.name, needle) }
        }
        let folderSizes = key.sort.key == .size && !isSearchMode ? SpaceIndex.shared.childSizes(of: url) : nil
        if needsLastOpened { LastOpenedIndex.shared.prefetch(result.map(\.url), folder: isSearchMode ? nil : url) }
        result = key.sort.sorted(result, folderSize: folderSizes.map { sizes in { sizes[$0.lastPathComponent] } },
                                 lastOpened: LastOpenedIndex.shared.date(for:))
        visibleCache = (key, result)
        return result
    }

    private var visibleKey: VisibleKey {
        var sort = self.sort
        sort.foldersFirst = AppSettings.shared.foldersFirst
        return VisibleKey(generation: itemsGeneration, filter: filter, sort: sort, showHidden: AppSettings.shared.showHidden,
                          sizes: sort.key == .size ? SpaceIndex.shared.revision : 0,
                          lastOpened: sort.key == .lastOpened ? LastOpenedIndex.shared.revision : 0)
    }

    /// Sorting or grouping by Spotlight's last-opened date, so it has to be fetched.
    private var needsLastOpened: Bool {
        sort.key == .lastOpened || (showsGroups && groupBy == .lastOpened)
    }

    /// The list (not the icon or column view) is what shows groups and expanded folders.
    var showsListView: Bool { viewMode == .list || (viewMode == .columns && isSearchMode) }

    /// The list and icon views show groups; the column and space views don't.
    var showsGroups: Bool { groupBy != .none && (showsListView || viewMode == .grid) }

    /// Expanded folders show their contents inline only while browsing (not searching or filtering).
    var showsTree: Bool {
        viewMode == .list && !isSearchMode && filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The visible items in labeled groups (one untitled group when not grouping).
    var displayGroups: [FileGroup] {
        let visible = visibleItems
        guard showsGroups else { return [FileGroup(id: "all", title: "", items: visible)] }
        let revision = switch groupBy {
        case .lastOpened: LastOpenedIndex.shared.revision
        case .size: SpaceIndex.shared.revision
        default: 0
        }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let key = GroupsKey(visible: visibleKey, groupBy: groupBy, revision: revision, day: day)
        if let cache = groupsCache, cache.key == key { return cache.groups }
        if groupBy == .lastOpened { LastOpenedIndex.shared.prefetch(visible.map(\.url), folder: isSearchMode ? nil : url) }
        let sizes = groupBy == .size && !isSearchMode ? SpaceIndex.shared.childSizes(of: url) : nil
        let groups = Grouping.groups(visible, by: groupBy, lastOpened: LastOpenedIndex.shared.date(for:),
                                     folderSize: { sizes?[$0.name] })
        groupsCache = (key, groups)
        return groups
    }

    /// Every row the user sees, in order: grouped, with the contents of expanded folders under them.
    /// Selection, Quick Look order, select-all and the status bar count work on these.
    var visibleRows: [FileItem] {
        let visible = visibleItems
        _ = treeRevision
        _ = expandedFolders
        let groups = showsGroups
        let tree = showsTree && !expandedFolders.isEmpty
        guard groups || tree else { return visible }
        let key = RowsKey(visible: visibleKey, groups: groups, groupBy: groupBy, tree: treeRevision, showsTree: tree)
        if let cache = rowsCache, cache.key == key { return cache.rows }
        var rows: [FileItem] = []
        func add(_ items: [FileItem], depth: Int) {
            for item in items {
                rows.append(item)
                if tree, depth < 64, item.isNavigable, let children = children(of: item.url) {
                    add(children, depth: depth + 1)
                }
            }
        }
        for group in displayGroups { add(group.items, depth: 0) }
        rowsCache = (key, rows)
        return rows
    }

    // MARK: Expanding folders

    func isExpanded(_ folder: URL) -> Bool { expandedFolders.contains(Self.treeKey(folder)) }

    /// The visible (sorted, hidden-filtered) contents of an expanded folder, or nil until they've loaded.
    func children(of folder: URL) -> [FileItem]? {
        let path = Self.treeKey(folder)
        guard expandedFolders.contains(path), let raw = childItems[path] else { return nil }
        var sort = self.sort
        sort.foldersFirst = AppSettings.shared.foldersFirst
        let key = ChildrenKey(tree: treeRevision, sort: sort, showHidden: AppSettings.shared.showHidden,
                              sizes: sort.key == .size ? SpaceIndex.shared.revision : 0,
                              lastOpened: sort.key == .lastOpened ? LastOpenedIndex.shared.revision : 0)
        if childrenCache?.key != key { childrenCache = (key, [:]) }
        if let hit = childrenCache?.children[path] { return hit }
        var result = raw
        if !key.showHidden { result.removeAll { $0.isHidden } }
        if sort.key == .lastOpened { LastOpenedIndex.shared.prefetch(result.map(\.url)) }
        let sizes = sort.key == .size ? SpaceIndex.shared.childSizes(of: folder) : nil
        result = sort.sorted(result, folderSize: sizes.map { sizes in { sizes[$0.lastPathComponent] } },
                             lastOpened: LastOpenedIndex.shared.date(for:))
        childrenCache?.children[path] = result
        return result
    }

    /// Shows or hides a folder's contents under it. `all` (⌥-click) also expands every subfolder
    /// (up to a few hundred); collapsing always folds everything inside.
    func setExpanded(_ folder: URL, _ expand: Bool, all: Bool = false) {
        let path = Self.treeKey(folder)
        if expand {
            if all { expandingAll.insert(path) }
            guard !expandedFolders.contains(path) else {
                if all { childItems[path].map { expandChildren(of: path, $0) } }
                return
            }
            expandedFolders.insert(path)
            loadChildren(path)
        } else {
            let inside = path == "/" ? "/" : path + "/"
            let removed = expandedFolders.filter { $0 == path || $0.hasPrefix(inside) }
            guard !removed.isEmpty else { return }
            expandedFolders.subtract(removed)
            for gone in removed {
                childItems[gone] = nil
                childWatchers[gone] = nil
                expandingAll.remove(gone)
            }
            // Like Finder, selected items inside a folder that closes are deselected.
            let kept = selection.filter { !$0.standardizedFileURL.path.hasPrefix(inside) }
            if kept != selection { selection = kept }
            treeRevision += 1
        }
    }

    /// Re-reads every expanded folder (⌘R).
    private func reloadTree() {
        for path in expandedFolders { loadChildren(path) }
    }

    private func loadChildren(_ path: String) {
        let generation = treeGeneration
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        if childWatchers[path] == nil {
            childWatchers[path] = DirectoryWatcher(url: folder) { [weak self] in self?.loadChildren(path) }
        }
        DirectoryLoader.load(folder) { [weak self] result in
            guard let self, generation == self.treeGeneration, self.expandedFolders.contains(path) else { return }
            let loaded = (try? result.get()) ?? []
            if self.childItems[path] != loaded || self.childItems[path] == nil {
                self.childItems[path] = loaded
                self.treeRevision += 1
            }
            if !self.pendingTreeSelection.isEmpty {
                let matched = loaded.filter { self.pendingTreeSelection.contains($0.url.standardizedFileURL.path) }
                if !matched.isEmpty {
                    self.pendingTreeSelection.subtract(matched.map(\.url.standardizedFileURL.path))
                    self.selection.formUnion(matched.map(\.url))
                }
            }
            if self.expandingAll.contains(path) { self.expandChildren(of: path, loaded) }
        }
    }

    private func expandChildren(of path: String, _ loaded: [FileItem]) {
        let showHidden = AppSettings.shared.showHidden
        for child in loaded where child.isNavigable && (showHidden || !child.isHidden) {
            guard expandedFolders.count < Self.expandAllLimit else { return }
            setExpanded(child.url, true, all: true)
        }
    }

    private func resetTree(expanding paths: Set<String> = []) {
        treeGeneration += 1
        childItems = [:]
        childWatchers = [:]
        expandingAll = []
        pendingTreeSelection = []
        expandedFolders = []
        treeRevision += 1
        // Parents first, so a folder whose parent is gone doesn't come back expanded.
        for path in paths.sorted(by: { $0.count < $1.count }) {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == Self.treeKey(url) || expandedFolders.contains(parent) {
                expandedFolders.insert(path)
                loadChildren(path)
            }
        }
    }

    nonisolated static func treeKey(_ url: URL) -> String { url.standardizedFileURL.path }

    var selectedItems: [FileItem] {
        let visible = visibleRows.filter { selection.contains($0.url) }
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
        FolderMemory.shared.remember(url, selection: selection, anchor: scrollAnchor, expanded: expandedFolders)
        let memory = FolderMemory.shared.recall(target)
        url = target
        resetTree(expanding: memory?.expanded ?? [])
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
        let wanted = select.map { [$0] } ?? memory?.selection
        if !expandedFolders.isEmpty, let wanted {
            pendingTreeSelection = Set(wanted.map(\.standardizedFileURL.path))
        }
        load(selecting: wanted)
    }

    // MARK: Loading

    /// Reloads the current directory, keeping the selection (or replacing it with `selecting`).
    func reload(selecting: Set<URL>? = nil) {
        if let selecting, !expandedFolders.isEmpty {
            pendingTreeSelection = Set(selecting.map(\.standardizedFileURL.path))
        }
        load(selecting: selecting ?? selection)
        reloadTree()
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
                // Items inside expanded folders stay selectable too.
                let candidates = loaded + self.childItems.values.joined()
                let matched = Set(candidates.lazy.filter { wanted.contains($0.url.standardizedFileURL.path) }.map(\.url))
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
