import SwiftUI

/// Finder-style column view. Columns show each ancestor of the tab's folder, the folder itself
/// (where selection lives), then the selected folder's contents or a preview of the selected file.
/// ← goes up, → enters the selected folder.
struct ColumnBrowserView: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let items: [FileItem]
    let isActive: Bool

    @FocusState private var focused: Bool

    private var selectedItems: [FileItem] { items.filter { tab.selection.contains($0.url) } }

    var body: some View {
        let parts = PathBarView.components(of: tab.url)
        let single = selectedItems.count == 1 ? selectedItems.first : nil

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(parts.dropLast().enumerated()), id: \.element.url) { index, part in
                        DirectoryColumn(url: part.url, highlighted: parts[index + 1].url) { picked in
                            if TabState.resolvedDirectory(picked) != nil {
                                tab.navigate(to: picked)
                            } else {
                                tab.navigate(to: part.url, select: picked)
                            }
                        }
                        Divider()
                    }

                    currentColumn
                        .id("current")
                    Divider()

                    if let single {
                        if let folder = single.isNavigable ? single.url : TabState.resolvedDirectory(single.url) {
                            DirectoryColumn(url: folder, highlighted: nil) { picked in
                                tab.navigate(to: folder, select: picked)
                            }
                            .id("next")
                        } else {
                            PreviewColumn(item: single).id("next")
                        }
                        Divider()
                    }
                }
            }
            .onChange(of: tab.url, initial: true) { _, _ in scrollToEnd(proxy) }
            .onChange(of: tab.selection) { _, _ in scrollToEnd(proxy) }
        }
        .onKeyPress(.leftArrow) {
            guard tab.canGoUp else { return .ignored }
            tab.goUp()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let single, let folder = single.isNavigable ? single.url : TabState.resolvedDirectory(single.url)
            else { return .ignored }
            tab.navigate(to: folder)
            return .handled
        }
        .onKeyPress(.space) { workspace.quickLook(); return .handled }
        .onKeyPress(.return) { workspace.rename(); return .handled }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        // Wait a beat so a freshly inserted column has been laid out before scrolling to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selectedItems.count == 1 ? "next" : "current", anchor: .trailing) }
        }
    }

    private var currentColumn: some View {
        List(selection: Binding(get: { tab.selection }, set: { tab.selection = $0 })) {
            ForEach(items) { item in
                ColumnRow(item: item, isRenaming: tab.renamingURL == item.url) { name in
                    if let name { workspace.commitRename(item.url, to: name, in: tab) } else { tab.renamingURL = nil }
                }
                .tag(item.url)
                .listRowSeparator(.hidden)
                .background { if item.id == items.first?.id { SlimScrollers(tint: tint).frame(width: 0, height: 0) } }
                .draggable(item.url)
                .dropDestination(for: URL.self) { urls, _ in
                    guard item.isNavigable else { return false }
                    FileOperationQueue.shared.transfer(urls.filter { !$0.isSameFile(as: item.url) }, to: item.url) { _, error in
                        workspace.report(error)
                    }
                    return true
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            MenuEntriesView(sections: ContextMenuBuilder.sections(
                workspace: workspace, tab: tab, selected: items.filter { urls.contains($0.url) }, includeOpenWith: false))
        } primaryAction: { urls in
            workspace.activate(pane)
            workspace.openSelection(items.filter { urls.contains($0.url) }.map(\.url))
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused($focused)
        .frame(width: 240)
        .onChange(of: workspace.focusToken, initial: true) { _, _ in if isActive { focused = true } }
        .onChange(of: focused) { _, isFocused in if isFocused { workspace.activate(pane) } }
        .onChange(of: tab.selection) { _, selection in
            QuickLookController.shared.selectionChanged(items.filter { selection.contains($0.url) }.map(\.url))
        }
    }
}

/// A read-only listing used for ancestor and child columns; picking an item navigates.
private struct DirectoryColumn: View {
    @Environment(\.arborTint) private var tint
    let url: URL
    let highlighted: URL?
    let pick: (URL) -> Void

    @State private var items: [FileItem] = []

    var body: some View {
        List(selection: Binding<String?>(
            get: { highlighted?.standardizedFileURL.path },
            set: { path in if let path, let item = items.first(where: { $0.url.standardizedFileURL.path == path }) { pick(item.url) } }
        )) {
            ForEach(items) { item in
                ColumnRow(item: item, isRenaming: false) { _ in }
                    .tag(item.url.standardizedFileURL.path)
                    .listRowSeparator(.hidden)
                    .background { if item.id == items.first?.id { SlimScrollers(tint: tint).frame(width: 0, height: 0) } }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(width: 220)
        .task(id: "\(url.path)|\(AppSettings.shared.showHidden)") {
            let showHidden = AppSettings.shared.showHidden
            let loaded: [FileItem] = await withCheckedContinuation { continuation in
                DirectoryLoader.load(url) { continuation.resume(returning: (try? $0.get()) ?? []) }
            }
            items = SortOrder().sorted(loaded.filter { showHidden || !$0.isHidden })
        }
    }
}

private struct ColumnRow: View {
    let item: FileItem
    let isRenaming: Bool
    let commit: (String?) -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
            if isRenaming {
                TextField("", text: $draft)
                    .focused($fieldFocused)
                    .onSubmit { commit(draft) }
                    .onExitCommand { commit(nil) }
                    .onAppear {
                        draft = item.name
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if item.isNavigable {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .opacity(item.isHidden ? 0.55 : 1)
    }
}

private struct PreviewColumn: View {
    let item: FileItem

    var body: some View {
        VStack(spacing: 10) {
            ThumbnailView(item: item, size: 180)
                .frame(width: 180, height: 180)
            Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text(item.localizedKind).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("大小").foregroundStyle(.secondary); Text(Format.bytes(item.size)) }
                GridRow { Text("修改").foregroundStyle(.secondary); Text(Format.date(item.modified)) }
                GridRow { Text("创建").foregroundStyle(.secondary); Text(Format.date(item.created)) }
            }
            .font(.system(size: 11))
            Spacer()
        }
        .padding(16)
        .frame(width: 260)
    }
}
