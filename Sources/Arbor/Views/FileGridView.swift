import SwiftUI

struct FileGridView: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let items: [FileItem]
    let isActive: Bool

    @State private var anchor: URL?
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
                    ForEach(items) { item in
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
                            FileOperationQueue.shared.transfer(urls.filter { !$0.isSameFile(as: item.url) }, to: item.url) { _, error in
                                workspace.report(error)
                            }
                            return true
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .onKeyPress(.upArrow) { move(by: -columnCount) }
        .onKeyPress(.downArrow) { move(by: columnCount) }
    }

    /// Scrolls a remembered item to the top once it has loaded (items arrive after navigation).
    private func applyPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = tab.pendingScrollAnchor,
              let item = items.first(where: { $0.url.isSameFile(as: anchor) }) else { return }
        proxy.scrollTo(item.url, anchor: .top)
        DispatchQueue.main.async { tab.pendingScrollAnchor = nil }
    }

    // MARK: Selection

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

    private func menuTargets(for item: FileItem) -> [FileItem] {
        tab.selection.contains(item.url) ? items.filter { tab.selection.contains($0.url) } : [item]
    }
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
                    .background(Capsule().fill(Color(nsColor: mark.color)))
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
