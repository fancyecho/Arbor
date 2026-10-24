import AppKit
import SwiftUI

/// List view backed by NSTableView: native type-select, keyboard navigation, column sorting,
/// drag & drop and inline rename that behave like Finder, and stay fast with 10k+ items.
struct FileListView: NSViewRepresentable {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    // Values read by the parent body so SwiftUI re-runs `updateNSView` when they change.
    let items: [FileItem]
    let selection: Set<URL>
    let sort: SortOrder
    let renamingURL: URL?
    let pendingScrollAnchor: URL?
    /// Search results come from many folders, so show where each one lives.
    let showsLocation: Bool
    let compareMarks: [String: CompareStatus]
    let visibleColumns: [String]
    /// Workspace color for selections and size bars.
    let tint: NSColor
    /// Size bars and freshness dots (Settings › 通用).
    let showsInsights: Bool
    let isActive: Bool
    let focusToken: Int
    /// While the window layout animates: the width this list is heading for (columns are chosen for it).
    var plannedWidth: CGFloat?
    /// Changes when a space scan finishes or updates, so scanned folder sizes show up in the size column.
    var spaceRevision = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LayoutFirewall {
        let table = FileTableView()
        let coordinator = context.coordinator
        coordinator.table = table
        coordinator.parent = self

        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing // FileScrollView fits the name column
        table.headerView = NSTableHeaderView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableColumn.isHidden = column != .name
            table.addTableColumn(tableColumn)
        }
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        table.onFocus = { [weak coordinator] in coordinator?.tableDidFocus() }
        table.onDragLeave = { [weak coordinator] in coordinator?.hideDropHint() }
        table.onKey = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }

        let scroll = FileScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        SlimScroller.install(on: scroll, tint: tint)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return LayoutFirewall(content: scroll)
    }

    func updateNSView(_ container: LayoutFirewall, context: Context) {
        context.coordinator.update(with: self)
    }

    /// Take whatever space SwiftUI offers. Without this SwiftUI re-measures the table every time a
    /// column or row changes inside it, feeding AppKit layout back into SwiftUI layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayoutFirewall, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }

    // MARK: - Columns

    enum Column: String, CaseIterable {
        case name, location, modified, created, size, kind, ext, tags

        /// Columns the user can switch on and off from the header menu.
        static let optional: [Column] = [.modified, .created, .size, .kind, .ext, .tags]

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String { sortKey.title }
        var sortKey: SortKey {
            switch self {
            case .name: .name
            case .modified: .modified
            case .size: .size
            case .kind: .kind
            case .location: .location
            case .created: .created
            case .ext: .ext
            case .tags: .tags
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 260
            case .modified: 124
            case .size: 118
            case .kind: 110
            case .location: 180
            case .created: 124
            case .ext: 64
            case .tags: 90
            }
        }
        var minWidth: CGFloat { self == .name ? 120 : 50 }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var table: FileTableView?
        weak var headerMenu: NSMenu?
        var parent: FileListView!
        private var items: [FileItem] = []
        private var marks: [String: CompareStatus] = [:]
        private var tint: NSColor = .controlAccentColor
        private var insights = true
        /// Largest file in the folder; size bars are relative to it.
        private var maxSize: Int64 = 1
        private var spaceRevision = -1
        /// Scanned sizes of this folder's subfolders, by name (empty when unscanned or showing search results).
        private var folderSizes: [String: Int64] = [:]
        private var tabID: UUID?
        private var isSyncing = false
        /// Table callbacks fired while it is being set up (e.g. restoring autosaved columns) are ignored.
        private var isConfigured = false
        private var lastFocusToken = -1
        private var editingURL: URL?
        private var renameCancelled = false

        private var workspace: WorkspaceState { parent.workspace }
        private var tab: TabState { parent.tab }

        func update(with view: FileListView) {
            parent = view
            guard let table else { return }
            isConfigured = true
            isSyncing = true
            defer { isSyncing = false }

            // The scroll view decides what actually fits; we only say what the user wants.
            var desired: Set<String> = Set(view.visibleColumns)
            if view.showsLocation { desired.insert(Column.location.rawValue) }
            if let scroll = table.enclosingScrollView as? FileScrollView,
               scroll.desiredColumns != desired || scroll.plannedWidth != view.plannedWidth {
                scroll.desiredColumns = desired
                scroll.plannedWidth = view.plannedWidth
                scroll.fitColumns()
            }

            let tabChanged = tabID != view.tab.id
            let selectionChanged = selectedURLs() != view.selection
            if tint != view.tint {
                tint = view.tint
                table.tint = view.tint
                if let scroll = table.enclosingScrollView { SlimScroller.install(on: scroll, tint: view.tint) }
                table.enumerateAvailableRowViews { rowView, _ in
                    (rowView as? TintedRowView)?.tint = view.tint
                }
            }
            if tabChanged || items != view.items || marks != view.compareMarks || insights != view.showsInsights
                || spaceRevision != view.spaceRevision {
                items = view.items
                marks = view.compareMarks
                insights = view.showsInsights
                spaceRevision = view.spaceRevision
                folderSizes = view.showsLocation ? [:] : SpaceIndex.shared.childSizes(of: view.tab.url) ?? [:]
                maxSize = max(1, view.items.compactMap { $0.isNavigable ? folderSizes[$0.name] : $0.size }.max() ?? 1)
                tabID = view.tab.id
                table.reloadData()
                // Switching tabs returns to where that tab was scrolled.
                if tabChanged, !(view.tab.scrollAnchor.map(scrollToTop) ?? false) { table.scroll(.zero) }
                applyPendingAnchor(view)
                applySelection(view.selection, scrollToFirst: tabChanged || selectionChanged)
            } else {
                applyPendingAnchor(view)
                if selectionChanged { applySelection(view.selection, scrollToFirst: true) }
            }

            let descriptor = NSSortDescriptor(key: view.sort.key.rawValue, ascending: view.sort.ascending)
            if table.sortDescriptors.first?.key != descriptor.key || table.sortDescriptors.first?.ascending != descriptor.ascending {
                table.sortDescriptors = [descriptor]
            }

            if let renaming = view.renamingURL, !(editingURL?.isSameFile(as: renaming) ?? false) {
                DispatchQueue.main.async { [weak self] in self?.beginRename(renaming) }
            }

            if view.isActive, view.focusToken != lastFocusToken {
                lastFocusToken = view.focusToken
                DispatchQueue.main.async { [weak table] in
                    guard let table, let window = table.window, window.firstResponder !== table else { return }
                    if !(window.firstResponder is NSText) { window.makeFirstResponder(table) }
                }
            }
        }

        /// Scrolls a remembered item back to the top once it has loaded, then clears the request.
        private func applyPendingAnchor(_ view: FileListView) {
            guard let anchor = view.pendingScrollAnchor, scrollToTop(anchor) else { return }
            let tab = view.tab
            DispatchQueue.main.async { tab.pendingScrollAnchor = nil }
        }

        @discardableResult
        private func scrollToTop(_ url: URL) -> Bool {
            guard let table, let scroll = table.enclosingScrollView,
                  let row = items.firstIndex(where: { $0.url.isSameFile(as: url) }) else { return false }
            let clip = scroll.contentView
            let inset = clip.contentInsets.top
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY - inset))
            scroll.reflectScrolledClipView(clip)
            return true
        }

        /// Right-click on the column header: choose visible columns, like Finder.
        private func buildHeaderMenu(_ menu: NSMenu) {
            let settings = AppSettings.shared
            for column in Column.optional {
                let item = ClosureMenuItem(title: column.title) {
                    if settings.listColumns.contains(column.rawValue) {
                        settings.listColumns.removeAll { $0 == column.rawValue }
                    } else {
                        settings.listColumns.append(column.rawValue)
                    }
                }
                item.state = settings.listColumns.contains(column.rawValue) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: L("恢复默认列")) { settings.listColumns = ["modified", "size", "kind"] })
        }

        @objc func didScroll(_ notification: Notification) {
            guard let table, let clip = table.enclosingScrollView?.contentView, !items.isEmpty else { return }
            let row = table.row(at: NSPoint(x: 1, y: clip.bounds.minY + clip.contentInsets.top + 1))
            if row >= 0, row < items.count { tab.scrollAnchor = items[row].url }
        }

        private func selectedURLs() -> Set<URL> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
        }

        private func applySelection(_ urls: Set<URL>, scrollToFirst: Bool) {
            guard let table else { return }
            var indexes = IndexSet()
            for (index, item) in items.enumerated() where urls.contains(item.url) { indexes.insert(index) }
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            if scrollToFirst, let first = indexes.first { table.scrollRowToVisible(first) }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = (tableView.makeView(withIdentifier: TintedRowView.identifier, owner: nil) as? TintedRowView) ?? TintedRowView()
            rowView.identifier = TintedRowView.identifier
            rowView.tint = tint
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), row < items.count else { return nil }
            let item = items[row]
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileCellView)
                ?? FileCellView(column: column)
            cell.identifier = tableColumn.identifier
            let folderSize = item.isNavigable && column == .size ? folderSizes[item.name] : nil
            cell.configure(item: item, column: column, mark: marks[item.name],
                           insight: insights ? CellInsight(maxSize: maxSize, tint: tint) : nil, folderSize: folderSize)
            if column == .name { cell.textField?.delegate = self }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier == Column.name.identifier && row < items.count ? items[row].name : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard isConfigured, !isSyncing, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
            tab.sort.key = key
            tab.sort.ascending = descriptor.ascending
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard isConfigured, !isSyncing else { return }
            let urls = selectedURLs()
            if tab.selection != urls { tab.selection = urls }
            let ordered = items.filter { urls.contains($0.url) }.map(\.url)
            QuickLookController.shared.selectionChanged(ordered)
        }

        // MARK: Interaction

        func tableDidFocus() {
            workspace.activate(parent.pane)
            QuickLookController.shared.keyHandler = { [weak self] event in
                guard let table = self?.table, [125, 126].contains(event.keyCode) else { return false }
                table.keyDown(with: event)
                return true
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count else { return }
            workspace.activate(parent.pane)
            workspace.openSelection([items[row].url])
        }

        /// Returns true if the key was handled.
        func handleKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 49 where flags.isEmpty: // Space
                workspace.quickLook()
            case 36, 76: // Return / Enter
                if flags.isEmpty { workspace.rename() } else { return false }
            case 48: // Tab
                workspace.focusNextPane(flags.contains(.shift) ? -1 : 1)
            case 53: // Escape
                if !tab.filter.isEmpty { tab.filter = "" } else { tab.selection = [] }
            default:
                return false
            }
            return true
        }

        // MARK: Inline rename

        private func beginRename(_ url: URL) {
            guard let table, let row = items.firstIndex(where: { $0.url.isSameFile(as: url) }),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView,
                  let field = cell.textField else { return }
            editingURL = url
            renameCancelled = false
            table.scrollRowToVisible(row)
            field.isEditable = true
            field.isSelectable = true
            Self.styleEditing(field, tint: tint)
            table.window?.makeFirstResponder(field)
            // Select the base name only, like Finder.
            if let editor = field.currentEditor() {
                let name = field.stringValue as NSString
                let ext = (name.pathExtension as NSString).length
                let isFolder = items[row].isDirectory
                let length = (ext > 0 && !isFolder) ? name.length - ext - 1 : name.length
                editor.selectedRange = NSRange(location: 0, length: max(length, 0))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                renameCancelled = true
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        /// The name field while renaming: a rounded field with a workspace-colored rim, not the system's
        /// black box and blue focus ring. `tint` nil puts the label back.
        static func styleEditing(_ field: NSTextField, tint: NSColor?) {
            field.wantsLayer = true
            if let tint {
                field.focusRingType = .none
                field.drawsBackground = true
                field.backgroundColor = NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : .white
                }
                field.layer?.cornerRadius = 5
                field.layer?.borderWidth = 1.5
                field.layer?.borderColor = tint.cgColor
            } else {
                field.drawsBackground = false
                field.layer?.borderWidth = 0
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let url = editingURL else { return }
            editingURL = nil
            field.isEditable = false
            field.isSelectable = false
            Self.styleEditing(field, tint: nil)
            let newName = field.stringValue
            if renameCancelled || newName.isEmpty {
                field.stringValue = url.lastPathComponent
                tab.renamingURL = nil
            } else if !workspace.commitRename(url, to: newName, in: tab) {
                // The rename didn't happen (name taken…): show the real name again, not the one typed.
                field.stringValue = url.lastPathComponent
            }
            if table?.window?.firstResponder == nil || table?.window?.firstResponder === table?.window {
                table?.window?.makeFirstResponder(table)
            }
        }

        // MARK: Drag & drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row < items.count ? items[row].url as NSURL : nil
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            var destination = tab.url
            if dropOperation == .on, row < items.count, items[row].isNavigable {
                destination = items[row].url
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            let urls = Self.draggedURLs(info)
            guard !urls.isEmpty, !urls.contains(where: { $0.isSameFile(as: destination) }) else {
                hideDropHint()
                return []
            }
            let operation = Self.operation(for: info, sources: urls, destination: destination)
            // Moving items into the folder they already live in does nothing.
            if operation == .move, urls.allSatisfy({ $0.deletingLastPathComponent().isSameFile(as: destination) }) {
                hideDropHint()
                return []
            }
            showDropHint(info, count: urls.count, operation: operation, destination: destination,
                         sameVolume: FileOperations.isSameVolume(urls, destination))
            return operation
        }

        // MARK: Drop hint

        private var dropHint: DropHintView?

        /// "移动 3 项到“下载” · 同一磁盘 · 按住 ⌥ 改为拷贝 · 可撤销", right next to the pointer.
        private func showDropHint(_ info: NSDraggingInfo, count: Int, operation: NSDragOperation, destination: URL, sameVolume: Bool) {
            guard let scroll = table?.enclosingScrollView else { return }
            let hint = dropHint ?? {
                let view = DropHintView()
                scroll.addSubview(view)
                dropHint = view
                return view
            }()
            let name = Places.displayName(for: destination)
            let verb = operation == .move ? L("移动") : L("拷贝")
            let detail: String
            if operation == .move {
                detail = L("同一磁盘 · 按住 ⌥ 改为拷贝 · 可撤销")
            } else if sameVolume {
                detail = L("按住了 ⌥，将拷贝 · 可撤销")
            } else {
                detail = L("不同磁盘，将拷贝 · 可撤销")
            }
            hint.update(title: L("\(verb) \(count) 项到“\(name)”"), detail: detail, tint: tint)
            var point = scroll.convert(info.draggingLocation, from: nil)
            point.x = min(point.x + 18, scroll.bounds.width - hint.frame.width - 8)
            point.y = scroll.isFlipped ? point.y + 18 : point.y - 18 - hint.frame.height
            hint.setFrameOrigin(point)
            hint.isHidden = false
        }

        func hideDropHint() {
            dropHint?.isHidden = true
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            hideDropHint()
            let destination = (row >= 0 && row < items.count && items[row].isNavigable) ? items[row].url : tab.url
            let urls = Self.draggedURLs(info)
            let operation = Self.operation(for: info, sources: urls, destination: destination)
            let tab = self.tab
            let workspace = self.workspace
            let completion: ([URL], Error?) -> Void = { results, error in
                workspace.report(error)
                tab.reload(selecting: destination.isSameFile(as: tab.url) ? Set(results) : nil)
            }
            if operation == .move {
                FileOperationQueue.shared.move(urls, to: destination, completion: completion)
            } else {
                FileOperationQueue.shared.copy(urls, to: destination, completion: completion)
            }
            return true
        }

        static func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        /// Finder semantics: move within a volume, copy across volumes, ⌥ forces copy.
        static func operation(for info: NSDraggingInfo, sources: [URL], destination: URL) -> NSDragOperation {
            let mask = info.draggingSourceOperationMask
            if mask == .copy { return .copy }
            if FileOperations.isSameVolume(sources, destination), mask.contains(.move) { return .move }
            return mask.contains(.copy) ? .copy : (mask.contains(.move) ? .move : [])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                buildHeaderMenu(menu)
                return
            }
            guard let table else { return }
            workspace.activate(parent.pane)

            let row = table.clickedRow
            if row >= 0, row < items.count, !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            let selected = row >= 0 ? items.filter { tab.selection.contains($0.url) || $0.url == items[row].url } : []
            ContextMenuBuilder.build(into: menu, workspace: workspace, tab: tab, selected: selected)
        }
    }
}

// MARK: - Layout firewall

/// Hosts the table for SwiftUI. Its one subview is sized with plain autoresizing and it reports no
/// intrinsic size, so the table resizing itself (rows, columns, scrollers) never reaches SwiftUI's
/// layout. That feedback (SwiftUI re-laying out because the table changed, the table changing
/// because SwiftUI laid out) is what produced the "too many Update Constraints passes" crashes.
final class LayoutFirewall: NSView {
    init(content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}

// MARK: - Scroll view

/// Gives the name column whatever width the other columns leave, like Finder, so the
/// date/size/kind columns stay visible in narrow panes.
final class FileScrollView: NSScrollView {
    /// Columns the user wants (raw values). Narrow panes drop the least important ones that don't fit.
    var desiredColumns: Set<String> = []
    /// Set while the window layout animates: the width the list is heading for. Columns that won't fit
    /// there shrink away smoothly as the pane narrows (and new ones grow in as it widens), so the date
    /// column glides with the edge instead of jumping when a column comes or goes.
    var plannedWidth: CGFloat? {
        didSet {
            guard plannedWidth != oldValue, let table = documentView as? NSTableView else { return }
            let others = table.tableColumns.filter { $0.identifier.rawValue != FileListView.Column.name.rawValue }
            if plannedWidth != nil {
                let natural = transition?.natural
                    ?? Dictionary(uniqueKeysWithValues: others.map { ($0.identifier.rawValue, $0.width) })
                transition = ColumnTransition(
                    startWidth: contentView.bounds.width.rounded(.down),
                    shown: Set(others.filter { !$0.isHidden && $0.width >= 1 }.map(\.identifier.rawValue)),
                    natural: natural)
            } else if let transition {
                for column in others {
                    let id = column.identifier.rawValue
                    column.minWidth = FileListView.Column(rawValue: id)?.minWidth ?? 50
                    if let width = transition.natural[id] { column.width = width }
                }
                self.transition = nil
            }
            lastFit = nil
        }
    }

    struct ColumnTransition {
        var startWidth: CGFloat
        /// Optional columns visible when the transition began.
        var shown: Set<String>
        /// Their widths before the transition squeezed any of them.
        var natural: [String: CGFloat]
    }

    private var transition: ColumnTransition?

    /// Dropped first when space runs out; the name column always stays.
    private static let dropOrder = ["tags", "ext", "created", "kind", "location", "size", "modified"]
    private static let comfortableNameWidth: CGFloat = 170
    /// Row insets of the `.inset` table style plus a little air, so rows never reach the card edge.
    private static let horizontalChrome: CGFloat = 34

    private var lastFit: (width: CGFloat, planned: CGFloat?, columns: Set<String>)?
    private var isFitting = false

    override func tile() {
        super.tile()
        fitColumns()
    }

    /// The optional columns that fit in `width` next to a comfortable name column. Columns in
    /// `autoHidden` need 30pt more to come back (hysteresis), so a width hovering at a threshold
    /// can't flip one every frame.
    static func fittingColumns(desired: Set<String>, widths: [String: CGFloat], autoHidden: Set<String>,
                               width: CGFloat, spacing: CGFloat) -> Set<String> {
        var shown = desired
        func spare() -> CGFloat {
            let used = shown.reduce(0) { $0 + (widths[$1] ?? 0) }
            return width - used - spacing * CGFloat(shown.count + 1) - horizontalChrome
        }
        for column in dropOrder where shown.contains(column) {
            let needed = comfortableNameWidth + (autoHidden.contains(column) ? 30 : 0)
            if spare() < needed { shown.remove(column) }
        }
        return shown
    }

    /// Width of each optional column `progress` of the way through a transition (nil = hidden).
    static func blendedWidth(full: CGFloat, inStart: Bool, inTarget: Bool, progress: CGFloat) -> CGFloat? {
        let width: CGFloat
        switch (inStart, inTarget) {
        case (true, true): width = full
        case (true, false): width = full * (1 - progress)
        case (false, true): width = full * progress
        case (false, false): return nil
        }
        return width >= 1 ? width : nil
    }

    /// Decides which columns show and how wide the name column is. It's a pure function of the visible
    /// width and the wanted columns, runs once per change and never re-enters, so changing a column
    /// can't start another layout pass that changes it back (that loop used to hang and crash the app).
    func fitColumns() {
        guard !isFitting, let table = documentView as? NSTableView,
              let name = table.tableColumns.first(where: { $0.identifier.rawValue == FileListView.Column.name.rawValue })
        else { return }
        let width = contentView.bounds.width.rounded(.down)
        // The clip view is narrower than the list by the scroller (if any); keep that offset for the plan.
        let planned = plannedWidth.map { ($0 - (bounds.width - width)).rounded(.down) }
        if let lastFit, lastFit.width == width, lastFit.planned == planned, lastFit.columns == desiredColumns { return }
        isFitting = true
        defer { isFitting = false }
        lastFit = (width, planned, desiredColumns)

        let others = table.tableColumns.filter { $0 !== name }
        let spacing = table.intercellSpacing.width
        if let planned, let transition {
            let target = Self.fittingColumns(
                desired: desiredColumns, widths: transition.natural,
                autoHidden: desiredColumns.subtracting(transition.shown), width: planned, spacing: spacing)
            let span = planned - transition.startWidth
            let progress = abs(span) < 1 ? 1 : min(max((width - transition.startWidth) / span, 0), 1)
            for column in others {
                let id = column.identifier.rawValue
                let blended = Self.blendedWidth(full: transition.natural[id] ?? column.width,
                                                inStart: transition.shown.contains(id) && desiredColumns.contains(id),
                                                inTarget: target.contains(id), progress: progress)
                if let blended {
                    column.minWidth = 0
                    if abs(column.width - blended) >= 0.5 { column.width = blended }
                    if column.isHidden { column.isHidden = false }
                } else if !column.isHidden {
                    column.isHidden = true
                }
            }
        } else {
            let widths = Dictionary(uniqueKeysWithValues: others.map { ($0.identifier.rawValue, $0.width) })
            let autoHidden = Set(others.filter(\.isHidden).map(\.identifier.rawValue)).intersection(desiredColumns)
            let shown = Self.fittingColumns(desired: desiredColumns, widths: widths, autoHidden: autoHidden,
                                            width: width, spacing: spacing)
            for column in others {
                let hidden = !shown.contains(column.identifier.rawValue)
                if column.isHidden != hidden { column.isHidden = hidden }
            }
        }
        let visible = others.filter { !$0.isHidden }
        let remaining = width - visible.reduce(0) { $0 + $1.width } - spacing * CGFloat(visible.count + 1) - Self.horizontalChrome
        let nameWidth = max(name.minWidth, remaining.rounded(.down))
        if abs(name.width - nameWidth) >= 1 { name.width = nameWidth }
    }
}

// MARK: - Table view

final class FileTableView: NSTableView {
    var onFocus: (() -> Void)?
    var onDragLeave: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragLeave?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // An optional NSDraggingDestination method NSTableView doesn't implement: calling super here
        // crashed (unrecognized selector) whenever a drag that had crossed the list ended elsewhere —
        // e.g. dragging an app out to AppCleaner.
        if NSTableView.instancesRespond(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
            super.draggingEnded(sender)
        }
        onDragLeave?()
    }
    var onKey: ((NSEvent) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        let point = convert(event.locationInWindow, from: nil)
        // Like Finder: a press on a file's icon or name grabs the file (click, drag out, double-click);
        // a press anywhere else (blank space, the other columns) can draw a selection rectangle.
        guard event.clickCount == 1, !grabsFile(at: point) else { return super.mouseDown(with: event) }
        trackMarquee(from: event)
    }

    private var marquee: MarqueeView?
    /// Workspace color for the selection rectangle.
    var tint: NSColor = .controlAccentColor

    /// Whether a press here lands on a file itself: its icon or name, or any part of an already selected row
    /// (so a selection can still be dragged out from wherever it's held).
    private func grabsFile(at point: NSPoint) -> Bool {
        let row = row(at: point)
        guard row >= 0 else { return false }
        if selectedRowIndexes.contains(row) { return true }
        let column = column(at: point)
        guard column >= 0, tableColumns[column].identifier == FileListView.Column.name.identifier,
              let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? FileCellView,
              let content = cell.contentFrame else { return false }
        return content.insetBy(dx: -3, dy: -2).contains(cell.convert(point, from: self))
    }

    /// Drags out a selection rectangle; every row it touches is selected. ⌘ toggles the rows it touches,
    /// ⇧ adds them. A press that doesn't move is an ordinary click.
    private func trackMarquee(from down: NSEvent) {
        guard let window else { return super.mouseDown(with: down) }
        let start = convert(down.locationInWindow, from: nil)
        let flags = down.modifierFlags
        let base = flags.contains(.command) || flags.contains(.shift) ? selectedRowIndexes : IndexSet()
        var dragging = false
        var last = down
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer {
            NSEvent.stopPeriodicEvents()
            marquee?.removeFromSuperview()
            marquee = nil
        }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if event.type == .leftMouseUp {
                guard dragging else {
                    // A plain click: hand it to the table as if we'd never looked.
                    window.postEvent(event, atStart: true)
                    return super.mouseDown(with: down)
                }
                return
            }
            if event.type == .leftMouseDragged { last = event }
            // Holding still past the edge keeps scrolling (periodic events), like Finder.
            autoscroll(with: last)
            let point = convert(last.locationInWindow, from: nil)
            if !dragging {
                guard hypot(point.x - start.x, point.y - start.y) > 3 else { continue }
                dragging = true
            }
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
                .intersection(bounds)
            showMarquee(rect)
            let range = rows(in: rect)
            let touched = IndexSet(integersIn: range.location..<(range.location + range.length))
            let selection = flags.contains(.command) ? base.symmetricDifference(touched) : base.union(touched)
            if selection != selectedRowIndexes { selectRowIndexes(selection, byExtendingSelection: false) }
        }
    }

    private func showMarquee(_ rect: NSRect) {
        let view = marquee ?? {
            let view = MarqueeView()
            addSubview(view, positioned: .above, relativeTo: nil)
            marquee = view
            return view
        }()
        view.tint = tint
        view.frame = rect
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    // Keep clicks on empty space from leaving a stale clicked-row for the context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }

    /// The rows a right-click acts on, while its menu is open: AppKit frames them in a hard white
    /// rectangle. Here they get the workspace color instead, shaped like the selection wash: a soft
    /// outline around each run of rows, and a faint wash on a clicked row that isn't selected.
    /// (AppKit has no public hook for this; if the selector ever changes, its white frame comes back.)
    @objc(_drawContextualMenuHighlightInClipRect:)
    private func drawContextMenuTarget(in clipRect: NSRect) {
        let clicked = clickedRow
        guard clicked >= 0 else { return }
        let targets = selectedRowIndexes.contains(clicked) ? selectedRowIndexes : IndexSet(integer: clicked)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for run in targets.rangeView {
            guard let first = run.first, let last = run.last else { continue }
            let rect = rowFrame(first).union(rowFrame(last)).insetBy(dx: 2.5, dy: 1.5)
            guard rect.intersects(clipRect) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            if !selectedRowIndexes.contains(clicked) {
                tint.withAlphaComponent(dark ? 0.14 : 0.07).setFill()
                path.fill()
            }
            tint.withAlphaComponent(dark ? 0.8 : 0.6).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// Where a row's view sits (inset from the table's edges in the inset style), in table coordinates.
    private func rowFrame(_ row: Int) -> NSRect {
        rowView(atRow: row, makeIfNecessary: false)?.frame ?? rect(ofRow: row)
    }
}

/// The rubber band drawn while drag-selecting.
final class MarqueeView: NSView {
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.12).setFill()
        bounds.fill()
        tint.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Cell

final class FileCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var icon: NSImageView?
    /// Comparison badge ("较新", "仅此侧"…) shown at the end of the name column.
    private var badge: NSTextField?
    /// Finder tag dots after the name.
    private var tagDots: NSImageView?
    private var mark: CompareStatus?
    private var sizeBar: SizeBarView?
    private var freshDot: FreshDotView?

    // Keep the badge readable on a highlighted (accent-colored) row.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateBadgeColor() }
    }

    private func updateBadgeColor() {
        badge?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
            : (mark?.color ?? .secondaryLabelColor)
    }

    init(column: FileListView.Column) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        if column == .name {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(imageView)
            self.imageView = imageView
            icon = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            ])
            let badge = NSTextField(labelWithString: "")
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(badge)
            self.badge = badge
            let dots = NSImageView()
            dots.translatesAutoresizingMaskIntoConstraints = false
            dots.setContentCompressionResistancePriority(.required, for: .horizontal)
            dots.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(dots)
            tagDots = dots
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                dots.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                dots.centerYAnchor.constraint(equalTo: centerYAnchor),
                dots.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            ])
        } else if column == .size {
            let bar = SizeBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            sizeBar = bar
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                bar.centerYAnchor.constraint(equalTo: centerYAnchor),
                bar.widthAnchor.constraint(equalToConstant: 40),
                bar.heightAnchor.constraint(equalToConstant: 5),
                label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            ])
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            label.alignment = .right
        } else if column == .modified {
            let dot = FreshDotView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            freshDot = dot
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            ])
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            if column == .size { label.alignment = .right }
            if column == .kind { label.font = .systemFont(ofSize: NSFont.systemFontSize - 1) }
        }
        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([trailing, label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The icon and the name as drawn (not the blank rest of the column): where a press grabs the file.
    var contentFrame: NSRect? {
        guard let icon else { return nil }
        let textWidth = min(label.attributedStringValue.size().width + 4, label.frame.width)
        return icon.frame.union(NSRect(x: label.frame.minX, y: label.frame.minY, width: textWidth, height: label.frame.height))
    }

    /// `folderSize` comes from a space scan (folders have no size of their own on disk).
    func configure(item: FileItem, column: FileListView.Column, mark: CompareStatus? = nil, insight: CellInsight? = nil,
                   folderSize: Int64? = nil) {
        if let sizeBar {
            let size = item.isNavigable ? folderSize : item.size
            let fraction = Double(size ?? 0) / Double(insight?.maxSize ?? 1)
            sizeBar.isHidden = insight == nil || size == nil
            sizeBar.update(fraction: fraction, tint: insight?.tint ?? .controlAccentColor)
        }
        if let freshDot {
            freshDot.isHidden = insight == nil
            freshDot.update(age: item.modified.map { Date().timeIntervalSince($0) }, tint: insight?.tint ?? .controlAccentColor)
        }
        if let badge {
            badge.isHidden = mark == nil || mark == .same
            badge.stringValue = mark?.label ?? ""
            self.mark = mark
            updateBadgeColor()
        }
        switch column {
        case .name:
            label.stringValue = item.name
            label.textColor = ColorRules.color(for: item.name) ?? .labelColor
            tagDots?.image = TagDotsImage.make(item.tagNames)
            label.isEditable = false
            icon?.image = item.icon
        case .modified:
            label.stringValue = Format.date(item.modified)
        case .size:
            if item.isNavigable {
                label.stringValue = folderSize.map(Format.bytes) ?? "--"
                toolTip = folderSize == nil ? nil : L("文件夹大小（来自空间视图的扫描）")
            } else {
                label.stringValue = Format.bytes(item.size)
                toolTip = nil
            }
        case .kind:
            label.stringValue = item.localizedKind
        case .location:
            label.stringValue = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            label.lineBreakMode = .byTruncatingHead
        case .created:
            label.stringValue = Format.date(item.created)
        case .ext:
            label.stringValue = item.isNavigable ? "" : item.fileExtension
        case .tags:
            label.stringValue = item.tagNames.joined(separator: L("、"))
        }
        alphaValue = item.isHidden ? 0.55 : 1
    }
}

extension CompareStatus {
    var color: NSColor {
        switch self {
        case .onlyHere: .systemGreen
        case .newer: .systemBlue
        case .older: .systemGray
        case .different: .systemOrange
        case .same: .secondaryLabelColor
        }
    }
}

/// Overlapping colored dots for a file's Finder tags, like Finder's list view.
@MainActor
enum TagDotsImage {
    private static var cache: [String: NSImage] = [:]

    static func make(_ tags: [String]) -> NSImage? {
        let colors = tags.prefix(3).map { FinderTags.color(for: $0) ?? .systemGray }
        guard !colors.isEmpty else { return nil }
        let key = tags.prefix(3).joined(separator: "|")
        if let hit = cache[key] { return hit }
        let size: CGFloat = 10, step: CGFloat = 6
        let image = NSImage(size: NSSize(width: size + step * CGFloat(colors.count - 1), height: size), flipped: false) { _ in
            for (index, color) in colors.enumerated().reversed() {
                let rect = NSRect(x: CGFloat(index) * step, y: 0, width: size, height: size)
                NSColor.textBackgroundColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
        cache[key] = image
        return image
    }
}

struct CellInsight {
    let maxSize: Int64
    let tint: NSColor
}

/// Selection as a soft wash of the workspace color; text keeps its normal color.
/// The pane that has focus gets a slightly deeper wash than the others.
final class TintedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TintedRow")

    var tint: NSColor = .controlAccentColor {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 2.5, dy: 1.5)
        let alpha: CGFloat = isEmphasized ? (dark ? 0.34 : 0.17) : (dark ? 0.17 : 0.08)
        tint.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }

    // Never switch cell text to white: the wash is light enough for normal text colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// How big a file is compared with the largest one in the folder. Big ones (over 60%) turn warm.
final class SizeBarView: NSView {
    private var fraction: Double = 0
    private var tint: NSColor = .controlAccentColor

    func update(fraction: Double, tint: NSColor) {
        self.fraction = max(0, min(1, fraction))
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        track.fill()
        guard fraction > 0 else { return }
        let width = max(bounds.height, bounds.width * fraction)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (fraction > 0.6 ? NSColor.systemOrange : tint).setFill()
        fill.fill()
    }
}

/// Glows for files changed in the last hour, then fades with age (hidden after a month).
final class FreshDotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3.5
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(age: TimeInterval?, tint: NSColor) {
        let opacity: Float
        switch age ?? .infinity {
        case ..<3600: opacity = 1
        case ..<86_400: opacity = 0.75
        case ..<604_800: opacity = 0.45
        case ..<2_592_000: opacity = 0.2
        default: opacity = 0
        }
        layer?.backgroundColor = tint.cgColor
        layer?.opacity = opacity
        layer?.shadowColor = tint.cgColor
        layer?.shadowOpacity = (age ?? .infinity) < 3600 ? 0.9 : 0
        layer?.shadowRadius = 4
        layer?.shadowOffset = .zero
    }
}

/// The floating explanation shown while dragging files over a list.
final class DropHintView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let swatch = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(white: 1, alpha: 0.65)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        for view in [title, detail, swatch] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title text: String, detail note: String, tint: NSColor) {
        title.stringValue = text
        detail.stringValue = note
        swatch.layer?.backgroundColor = tint.cgColor
        title.sizeToFit()
        detail.sizeToFit()
        let width = max(title.frame.width, detail.frame.width) + 34
        setFrameSize(NSSize(width: width, height: 46))
        swatch.frame = NSRect(x: 10, y: 27, width: 6, height: 6)
        title.setFrameOrigin(NSPoint(x: 22, y: 22))
        detail.setFrameOrigin(NSPoint(x: 22, y: 6))
    }
}
