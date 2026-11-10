import SwiftUI

struct FileGridView: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    /// Every item in display order (group by group).
    let items: [FileItem]
    var groups: [FileGroup] = []
    var showsGroups = false
    let isActive: Bool

    @State private var anchor: URL?
    /// Drag-selecting: where the rectangle started and where the pointer is, in the grid's coordinates.
    @State private var marquee: (start: CGPoint, end: CGPoint)?
    /// The selection the rectangle adds to (⌘/⇧ held) and whether this drag began on a file (then it isn't ours).
    @State private var marqueeBase: Set<URL> = []
    @State private var dragBeganOnItem = false
    @State private var frames = CellFrames()
    @State private var springLoader = SpringLoader()
    @State private var width: CGFloat = 600
    @FocusState private var focused: Bool

    private static let cellWidth: CGFloat = 108
    private static let spacing: CGFloat = 8
    private var columnCount: Int { max(1, Int((width - 24 + Self.spacing) / (Self.cellWidth + Self.spacing))) }

    var body: some View {
        // The outer GeometryReader measures the space we are offered (not the content), so the
        // column count used for arrow-key navigation always matches the adaptive grid below.
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth, maximum: Self.cellWidth), spacing: Self.spacing)],
                          alignment: .leading, spacing: 10) {
                    if showsGroups {
                        ForEach(groups, id: \.id) { group in
                            Section {
                                ForEach(group.items) { item in cell(for: item) }
                            } header: {
                                GridGroupHeader(title: group.title, count: group.items.count)
                            }
                        }
                    } else {
                        ForEach(items) { item in cell(for: item) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Blank space below the files takes part in drag-selecting too.
                .frame(minHeight: geometry.size.height, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(name: Self.space)
                .gesture(marqueeGesture)
                .overlay(alignment: .topLeading) { marqueeRectangle }
                .slimScrollers(tint)
            }
            .onChange(of: tab.pendingScrollAnchor, initial: true) { _, _ in applyPendingAnchor(proxy) }
            .onChange(of: items.count) { _, _ in applyPendingAnchor(proxy) }
            .onChange(of: tab.selection) { _, selection in
                guard let first = items.first(where: { selection.contains($0.url) }) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(first.url) }
                QuickLookController.shared.selectionChanged(items.filter { selection.contains($0.url) }.map(\.url))
            }
        }
        .onAppear { width = geometry.size.width }
        .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.activate(pane)
            tab.selection = []
            focused = true
        }
        .contextMenu {
            MenuEntriesView(sections: ContextMenuBuilder.sections(workspace: workspace, tab: tab, selected: [], includeOpenWith: false))
        }
        .dropDestination(for: URL.self) { urls, _ in
            FileOperationQueue.shared.transfer(urls, to: tab.url) { results, error in
                workspace.report(error)
                tab.reload(selecting: Set(results))
            }
            return true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in if isFocused { workspace.activate(pane) } }
        .onChange(of: workspace.focusToken) { _, _ in if isActive { focused = true } }
        .onAppear { if isActive { focused = true } }
        .onKeyPress(.space) { workspace.quickLook(); return .handled }
        .onKeyPress(.return) { workspace.rename(); return .handled }
        .onKeyPress(.tab) { workspace.focusNextPane(); return .handled }
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { moveVertically(-1) }
        .onKeyPress(.downArrow) { moveVertically(1) }
        .onDisappear { springLoader.cancel() }
    }

    private func cell(for item: FileItem) -> some View {
                GridCell(
                    item: item,
                    isSelected: tab.selection.contains(item.url),
                    isRenaming: tab.renamingURL == item.url,
                    mark: tab.compareMarks[item.name],
                    commitRename: { name in
                        if let name { workspace.commitRename(item.url, to: name, in: tab) } else { tab.renamingURL = nil }
                        focused = true
                    })
                .id(item.url)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.byURL[item.url] = $0 }
                .gesture(TapGesture(count: 2).onEnded {
                    workspace.activate(pane)
                    workspace.openSelection([item.url])
                })
                .simultaneousGesture(TapGesture().onEnded { click(item) })
                .contextMenu {
                    MenuEntriesView(sections: ContextMenuBuilder.sections(
                        workspace: workspace, tab: tab, selected: menuTargets(for: item), includeOpenWith: false))
                }
                .draggable(item.url) {
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard item.isNavigable else { return false }
                    springLoader.cancel()
                    FileOperationQueue.shared.transfer(urls.filter { !$0.isSameFile(as: item.url) }, to: item.url) { _, error in
                        workspace.report(error)
                    }
                    return true
                } isTargeted: { targeted in
                    // Holding a drag over a folder opens it (spring-loading), like Finder.
                    guard item.isNavigable else { return }
                    if targeted {
                springLoader.open = { [workspace, pane, tab] folder in
                    workspace.activate(pane)
                    tab.navigate(to: folder)
                }
                springLoader.hover(item.url)
            } else {
                springLoader.leave(item.url)
            }
                }
    }

    /// Scrolls a remembered item to the top once it has loaded (items arrive after navigation).
    private func applyPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = tab.pendingScrollAnchor,
              let item = items.first(where: { $0.url.isSameFile(as: anchor) }) else { return }
        proxy.scrollTo(item.url, anchor: .top)
        DispatchQueue.main.async { tab.pendingScrollAnchor = nil }
    }

    // MARK: Selection

    private static let space = "FileGrid"

    /// Like Finder: dragging from blank space draws a rectangle that selects every file it touches.
    /// ⌘ toggles the files it touches, ⇧ adds them; a drag that starts on a file moves the file instead.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil, !dragBeganOnItem {
                    if items.contains(where: { frames.byURL[$0.url]?.contains(value.startLocation) ?? false }) {
                        dragBeganOnItem = true
                        return
                    }
                    workspace.activate(pane)
                    focused = true
                    let flags = NSEvent.modifierFlags
                    marqueeBase = flags.contains(.command) || flags.contains(.shift) ? tab.selection : []
                }
                guard !dragBeganOnItem else { return }
                marquee = (value.startLocation, value.location)
                let rect = marqueeRect(value.startLocation, value.location)
                let touched = Set(items.lazy.filter { frames.byURL[$0.url]?.intersects(rect) ?? false }.map(\.url))
                let selection = NSEvent.modifierFlags.contains(.command)
                    ? marqueeBase.symmetricDifference(touched) : marqueeBase.union(touched)
                if selection != tab.selection { tab.selection = selection }
            }
            .onEnded { _ in
                marquee = nil
                dragBeganOnItem = false
            }
    }

    @ViewBuilder private var marqueeRectangle: some View {
        if let marquee {
            let rect = marqueeRect(marquee.start, marquee.end)
            Rectangle()
                .fill(tint.opacity(0.12))
                .overlay { Rectangle().strokeBorder(tint.opacity(0.55), lineWidth: 1) }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func marqueeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func click(_ item: FileItem) {
        workspace.activate(pane)
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if tab.selection.contains(item.url) { tab.selection.remove(item.url) } else { tab.selection.insert(item.url) }
            anchor = item.url
        } else if flags.contains(.shift), let anchor, let from = items.firstIndex(where: { $0.url == anchor }),
                  let to = items.firstIndex(where: { $0.url == item.url }) {
            tab.selection = Set(items[min(from, to)...max(from, to)].map(\.url))
        } else {
            tab.selection = [item.url]
            anchor = item.url
        }
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = items.lastIndex { tab.selection.contains($0.url) }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
        tab.selection = [items[next].url]
        anchor = items[next].url
        return .handled
    }

    /// ↑/↓: the nearest item in the row above or below. With groups, rows don't line up across a
    /// header, so this goes by where the cells actually are instead of counting columns.
    private func moveVertically(_ direction: Int) -> KeyPress.Result {
        guard showsGroups, let current = items.last(where: { tab.selection.contains($0.url) }),
              let from = frames.byURL[current.url] else { return move(by: direction * columnCount) }
        let candidates = items.compactMap { item -> (FileItem, CGRect)? in
            guard let frame = frames.byURL[item.url] else { return nil }
            let ahead = direction > 0 ? frame.minY > from.maxY - 1 : frame.maxY < from.minY + 1
            return ahead ? (item, frame) : nil
        }
        guard let rowY = candidates.map({ $0.1.midY }).min(by: { abs($0 - from.midY) < abs($1 - from.midY) }) else {
            return .handled
        }
        let row = candidates.filter { abs($0.1.midY - rowY) < 1 }
        guard let next = row.min(by: { abs($0.1.midX - from.midX) < abs($1.1.midX - from.midX) })?.0 else { return .handled }
        tab.selection = [next.url]
        anchor = next.url
        return .handled
    }

    private func menuTargets(for item: FileItem) -> [FileItem] {
        tab.selection.contains(item.url) ? items.filter { tab.selection.contains($0.url) } : [item]
    }
}

/// "今天 · 12" above a group of icons.
private struct GridGroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.horizontal, 2)
    }
}

/// Where each cell sits in the grid, updated as cells lay out. A plain object: storing a frame mustn't redraw the grid.
private final class CellFrames {
    var byURL: [URL: CGRect] = [:]
}

// MARK: - Cell

private struct GridCell: View {
    @Environment(\.arborTint) private var tint
    let item: FileItem
    let isSelected: Bool
    let isRenaming: Bool
    let mark: CompareStatus?
    let commitRename: (String?) -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if item.isNavigable {
                    FolderCoverView(item: item, size: 64)
                } else {
                    ThumbnailView(item: item, size: 64)
                }
            }
                .frame(width: 72, height: 72)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.16) : .clear))

            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .onSubmit { commitRename(draft) }
                    .onExitCommand { commitRename(nil) }
                    .onAppear {
                        draft = item.name
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ColorRules.color(for: item.name).map { Color(nsColor: $0) } ?? Color.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? tint.opacity(0.18) : .clear))
            }
        }
        .overlay(alignment: .bottom) {
            if let dots = TagDotsImage.make(item.tagNames), !isRenaming {
                Image(nsImage: dots).offset(y: 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let mark, mark != .same {
                Text(mark.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background { Capsule().fill(Color(nsColor: mark.color)) }
                    .offset(x: -8, y: 2)
            }
        }
        .frame(width: 108, height: 116, alignment: .top)
        .opacity(item.isHidden ? 0.55 : 1)
        .contentShape(Rectangle())
        .help(item.name)
    }
}

/// QuickLook thumbnail with the file icon as placeholder.
struct ThumbnailView: View {
    let item: FileItem
    let size: CGFloat

    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? item.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .shadow(color: .black.opacity(image != nil && !item.isDirectory ? 0.15 : 0), radius: 1.5, y: 1)
            .task(id: "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)") {
                image = ThumbnailCache.shared.cached(item.url, size: size, modified: item.modified)
                guard image == nil, !item.isNavigable else { return }
                image = await ThumbnailCache.shared.thumbnail(for: item.url, size: size, modified: item.modified, scale: scale)
            }
    }
}
