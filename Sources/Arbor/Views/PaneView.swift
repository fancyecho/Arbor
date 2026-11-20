import UniformTypeIdentifiers
import SwiftUI

/// An opaque content card. The pane that receives commands gets a faint ring of the workspace color.
struct PaneView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    /// Width the content is laid out at; wider than the card while the card grows over it (see DeckView).
    var contentWidth: CGFloat?

    @Environment(\.arborTint) private var tint

    private var isActive: Bool { workspace.activePaneID == pane.id }
    private var lifted: Bool { isActive && workspace.paneCount > 1 }
    private static let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)

    var body: some View {
        let tab = pane.activeTab
        VStack(spacing: 0) {
            // One tab needs no tab bar: the header names the folder. The strip appears with a second tab.
            if pane.tabs.count > 1 {
                TabBarView(workspace: workspace, pane: pane, isActive: isActive)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PaneHeader(workspace: workspace, pane: pane, tab: tab, showsTabButtons: pane.tabs.count <= 1, isActive: isActive)
            Rectangle().fill(Surface.divider).frame(height: 1)
            TabContentView(workspace: workspace, pane: pane, tab: tab, isActive: isActive)
            StatusBarView(tab: tab)
        }
        .frame(width: contentWidth, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .card(Surface.card(active: isActive || workspace.paneCount == 1), in: Self.shape)
        .overlay {
            // The pane receiving commands: a faint ring of the workspace color, nothing louder.
            Self.shape.strokeBorder(tint.opacity(lifted ? 0.4 : 0), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.22), value: lifted)
        .animation(.snappy(duration: 0.25), value: pane.tabs.count > 1)
        .simultaneousGesture(TapGesture().onEnded { workspace.activate(pane) })
    }
}

/// The top of a pane: the folders above in small type, then the folder itself as a title, with its icon
/// and, in a Git repository, the branch.
struct PaneHeader: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    /// With a single tab there's no tab bar, so the header carries "+" (and "close pane").
    let showsTabButtons: Bool
    let isActive: Bool

    @Environment(\.arborTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            PathBarView(workspace: workspace, tab: tab, parentsOnly: true)
            HStack(spacing: 9) {
                icon
                // The title wins: in a narrow pane the branch chip gives way before the name truncates.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        title.fixedSize()
                        if let status = tab.gitStatus, !tab.isSearchMode {
                            GitBranchChip(workspace: workspace, tab: tab, status: status)
                                .fixedSize()
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    title
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !tab.isSearchMode, TrashBin.isTrash(tab.url) {
                    // Like Finder's Trash window: emptying is right where its contents are.
                    Button(L("清倒")) { TrashBin.shared.empty(workspace: workspace) }
                        .controlSize(.small)
                        // Unreadable (no Full Disk Access) still empties: Finder does it then.
                        .disabled(TrashBin.shared.isEmptying
                                  || (tab.errorMessage == nil && !tab.isLoading && tab.items.allSatisfy { $0.name == ".DS_Store" }))
                        .help(L("永久抹掉废纸篓中的所有项目（按住 ⌥ 跳过确认）"))
                }
                if showsTabButtons {
                    Button {
                        workspace.activate(pane)
                        workspace.newTab()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("新建标签页 (⌘T)"))
                    if workspace.paneCount > 1 {
                        PaneCloseButton { workspace.closePane(pane) }
                    }
                }
            }
            .frame(height: 28)
            .animation(.snappy(duration: 0.25), value: tab.gitStatus?.root)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, showsTabButtons ? 10 : 2)
        .padding(.bottom, 10)
    }

    private var title: some View {
        Text(tab.title)
            .font(TypeScale.title)
            .tracking(-0.2)
            .foregroundStyle(isActive || workspace.paneCount == 1 ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var icon: some View {
        if tab.aiQuery != nil {
            Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24)
        } else if tab.tagQuery != nil || tab.isSearchMode {
            Image(systemName: tab.tagQuery != nil ? "tag" : "magnifyingglass")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24)
        } else {
            Image(nsImage: FolderIcon.icon(for: tab.url, isDirectory: true, isPackage: false, tint: workspace.tint.nsColor))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
        }
    }
}

/// Switches between list and grid, and shows loading / empty / error states.
struct TabContentView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isActive: Bool

    /// Entering a folder fades its contents in and slides them a few points, instead of a hard swap:
    /// from the right when going deeper, from the left when going back up.
    @State private var entrance: CGFloat = 1
    @State private var direction: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plannedPaneWidth) private var plannedWidth

    var body: some View {
        let items = tab.visibleItems
        Group {
            switch tab.viewMode {
            case .list:
                FileListView(
                    workspace: workspace, pane: pane, tab: tab,
                    items: items, selection: tab.selection, sort: tab.sort, renamingURL: tab.renamingURL,
                    pendingScrollAnchor: tab.pendingScrollAnchor, showsLocation: tab.isSearchMode, compareMarks: tab.compareMarks, visibleColumns: AppSettings.shared.listColumns, tint: workspace.tint.nsColor, showsInsights: AppSettings.shared.showListInsights, isActive: isActive, focusToken: workspace.focusToken,
                    plannedWidth: plannedWidth, spaceRevision: SpaceIndex.shared.revision,
                    groups: tab.displayGroups, showsGroups: tab.showsGroups, showsTree: tab.showsTree,
                    expandedFolders: tab.expandedFolders, treeRevision: tab.treeRevision,
                    lastOpenedRevision: LastOpenedIndex.shared.revision, gitRevision: GitIndex.shared.revision,
                    transfers: FileOperationQueue.shared.inFlight(in: tab.url))
            case .grid:
                // While the pane shrinks, icons keep the final arrangement instead of re-wrapping every frame.
                FileGridView(workspace: workspace, pane: pane, tab: tab, items: tab.visibleRows,
                             groups: tab.displayGroups, showsGroups: tab.showsGroups, isActive: isActive)
                    .frame(width: plannedWidth, alignment: .leading)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            case .columns:
                // Search results span many folders, so they always use the list.
                if tab.isSearchMode {
                    FileListView(
                        workspace: workspace, pane: pane, tab: tab,
                        items: items, selection: tab.selection, sort: tab.sort, renamingURL: tab.renamingURL,
                        pendingScrollAnchor: tab.pendingScrollAnchor, showsLocation: true, compareMarks: [:], visibleColumns: AppSettings.shared.listColumns, tint: workspace.tint.nsColor, showsInsights: AppSettings.shared.showListInsights, isActive: isActive,
                        focusToken: workspace.focusToken, plannedWidth: plannedWidth, spaceRevision: SpaceIndex.shared.revision,
                        groups: tab.displayGroups, showsGroups: tab.showsGroups, showsTree: false,
                        lastOpenedRevision: LastOpenedIndex.shared.revision, gitRevision: GitIndex.shared.revision,
                    transfers: FileOperationQueue.shared.inFlight(in: tab.url))
                } else {
                    ColumnBrowserView(workspace: workspace, pane: pane, tab: tab, items: items, isActive: isActive)
                }
            case .space:
                SpaceView(workspace: workspace, pane: pane, tab: tab, isActive: isActive)
            case .timeline:
                ActivityTimelineView(workspace: workspace, pane: pane, tab: tab, isActive: isActive)
            }
        }
        .overlay {
            if let message = tab.errorMessage {
                ContentUnavailableView {
                    Label(L("无法打开文件夹"), systemImage: "lock.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button(L("返回")) { tab.goBack() }.disabled(!tab.canGoBack).buttonStyle(.glass)
                }
            } else if tab.isLoading || (tab.isSearching && items.isEmpty) {
                ProgressView().controlSize(.small)
            } else if items.isEmpty, tab.viewMode != .timeline, tab.viewMode != .columns || tab.isSearchMode {
                // (The column view shows this inside its own column, not across all of them.)
                VStack(spacing: 6) {
                    Text(tab.filter.isEmpty ? L("文件夹为空") : L("没有匹配“\(tab.filter)”的项目"))
                    let hidden = tab.items.filter(\.isHidden).count
                    if tab.filter.isEmpty, hidden > 0, !AppSettings.shared.showHidden {
                        Button(L("显示 \(hidden) 个隐藏项目")) { AppSettings.shared.showHidden = true }
                            .buttonStyle(.tintLink)
                            .font(.caption)
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
            }
        }
        .opacity(0.35 + 0.65 * entrance)
        .offset(x: reduceMotion ? 0 : (1 - entrance) * 18 * direction)
        // Switching views (list → icons…) settles in place instead of sliding.
        .scaleEffect(direction == 0 && !reduceMotion ? 0.985 + 0.015 * entrance : 1)
        .onChange(of: tab.viewMode) { _, _ in
            direction = 0
            entrance = 0
            withAnimation(.spring(duration: 0.3, bounce: 0)) { entrance = 1 }
        }
        .onChange(of: tab.url) { old, new in
            let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
            let goingUp = oldPath.hasPrefix(newPath == "/" ? "/" : newPath + "/")
            direction = goingUp ? -1 : 1
            entrance = 0
            withAnimation(.spring(duration: 0.32, bounce: 0)) { entrance = 1 }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let tab: TabState
    @Environment(\.arborTint) private var tint
    @State private var freeSpace: Int64?

    var body: some View {
        let visible = tab.visibleRows
        let selected = visible.filter { tab.selection.contains($0.url) }
        HStack(spacing: 6) {
            if selected.isEmpty {
                Text(L("\(visible.count) 项"))
                    .contentTransition(.numericText())
            } else {
                Text(L("已选 \(selected.count) / \(visible.count) 项")).foregroundStyle(tint)
                    .contentTransition(.numericText())
                let bytes = selected.compactMap(\.size).reduce(0, +)
                if bytes > 0 { Text("·  \(Format.bytes(bytes))") }
            }
            if tab.isSearchMode {
                let search = tab.aiQuery != nil ? L("AI 结果") : tab.tagQuery != nil || tab.searchScope == .spotlight
                    ? L("Spotlight 搜索") : L("子文件夹搜索")
                Text("·  " + (tab.isSearching ? L("\(search)中…")
                              : tab.searchTruncated ? L("\(search)（仅显示前 \(RecursiveSearch.resultLimit) 项）") : search))
                    .foregroundStyle(tint)
                if tab.isSearching { ProgressView().controlSize(.mini) }
            } else if !tab.filter.isEmpty {
                Text(L("·  已过滤")).foregroundStyle(tint)
            }
            Spacer(minLength: 8)
            if let freeSpace {
                // Narrow panes drop the label, then the figure, instead of truncating it to "可用 73.…".
                ViewThatFits {
                    Text(L("可用 \(Format.bytes(freeSpace))"))
                    Text(Format.bytes(freeSpace)).help(L("可用空间"))
                    Color.clear.frame(width: 0)
                }
                .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .animation(.snappy(duration: 0.2), value: selected.count)
        .animation(.snappy(duration: 0.2), value: visible.count)
        .padding(.leading, 18)
        .padding(.trailing, Metrics.l)
        .frame(height: 28)
        .overlay(alignment: .top) { Rectangle().fill(Surface.divider).frame(height: 1) }
        .task(id: tab.url) {
            let values = try? tab.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeSpace = values?.volumeAvailableCapacityForImportantUsage
        }
    }
}
