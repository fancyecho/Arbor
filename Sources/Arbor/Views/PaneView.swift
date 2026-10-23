import UniformTypeIdentifiers
import SwiftUI

/// A floating glass card. The pane that receives commands lifts: workspace-colored rim, deeper shadow.
struct PaneView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    /// Width the content is laid out at; wider than the card while the card grows over it (see DeckView).
    var contentWidth: CGFloat?

    @Environment(\.arborTint) private var tint

    private var isActive: Bool { workspace.activePaneID == pane.id }
    private var lifted: Bool { isActive && workspace.paneCount > 1 }
    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        let tab = pane.activeTab
        VStack(spacing: 0) {
            TabBarView(workspace: workspace, pane: pane, isActive: isActive)
            PathBarView(workspace: workspace, tab: tab)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 12)
            TabContentView(workspace: workspace, pane: pane, tab: tab, isActive: isActive)
            StatusBarView(tab: tab)
        }
        .frame(width: contentWidth, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background { Self.shape.fill(Surface.card(active: isActive || workspace.paneCount == 1)) }
        .clipShape(Self.shape)
        .overlay {
            // Lit from above, like the glass around it: the rim is brightest along the top edge.
            if lifted {
                Self.shape.strokeBorder(
                    LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5)
            } else {
                Self.shape.strokeBorder(Surface.hairline, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.22 : 0.08), radius: lifted ? 22 : 8, y: lifted ? 10 : 3)
        .animation(.easeOut(duration: 0.22), value: lifted)
        .simultaneousGesture(TapGesture().onEnded { workspace.activate(pane) })
    }
}

/// Switches between list and grid, and shows loading / empty / error states.
struct TabContentView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isActive: Bool

    /// Entering a folder fades its contents in and lets them settle a few points, instead of a hard swap.
    @State private var entrance: CGFloat = 1
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
                    plannedWidth: plannedWidth, spaceRevision: SpaceIndex.shared.revision)
            case .grid:
                // While the pane shrinks, icons keep the final arrangement instead of re-wrapping every frame.
                FileGridView(workspace: workspace, pane: pane, tab: tab, items: items, isActive: isActive)
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
                        focusToken: workspace.focusToken, plannedWidth: plannedWidth, spaceRevision: SpaceIndex.shared.revision)
                } else {
                    ColumnBrowserView(workspace: workspace, pane: pane, tab: tab, items: items, isActive: isActive)
                }
            case .space:
                SpaceView(workspace: workspace, pane: pane, tab: tab, isActive: isActive)
            }
        }
        .overlay {
            if let message = tab.errorMessage {
                ContentUnavailableView {
                    Label("无法打开文件夹", systemImage: "lock.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("返回") { tab.goBack() }.disabled(!tab.canGoBack).buttonStyle(.glass)
                }
            } else if tab.isLoading || (tab.isSearching && items.isEmpty) {
                ProgressView().controlSize(.small)
            } else if items.isEmpty, tab.viewMode != .columns || tab.isSearchMode {
                // (The column view shows this inside its own column, not across all of them.)
                VStack(spacing: 6) {
                    Text(tab.filter.isEmpty ? "文件夹为空" : "没有匹配“\(tab.filter)”的项目")
                    let hidden = tab.items.filter(\.isHidden).count
                    if tab.filter.isEmpty, hidden > 0, !AppSettings.shared.showHidden {
                        Button("显示 \(hidden) 个隐藏项目") { AppSettings.shared.showHidden = true }
                            .buttonStyle(.tintLink)
                            .font(.caption)
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
            }
        }
        .opacity(0.4 + 0.6 * entrance)
        .offset(y: (1 - entrance) * 6)
        .onChange(of: tab.url) { _, _ in
            entrance = 0
            withAnimation(.easeOut(duration: 0.24)) { entrance = 1 }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let tab: TabState
    @Environment(\.arborTint) private var tint
    @State private var freeSpace: Int64?

    var body: some View {
        let visible = tab.visibleItems
        let selected = visible.filter { tab.selection.contains($0.url) }
        HStack(spacing: 6) {
            if selected.isEmpty {
                Text("\(visible.count) 项")
            } else {
                Text("已选 \(selected.count) / \(visible.count) 项").foregroundStyle(tint)
                let bytes = selected.compactMap(\.size).reduce(0, +)
                if bytes > 0 { Text("·  \(Format.bytes(bytes))") }
            }
            if tab.isSearchMode {
                Text("·  \(tab.searchScope == .spotlight ? "Spotlight" : "子文件夹")搜索\(tab.isSearching ? "中…" : tab.searchTruncated ? "（仅显示前 \(RecursiveSearch.resultLimit) 项）" : "")")
                    .foregroundStyle(tint)
                if tab.isSearching { ProgressView().controlSize(.mini) }
            } else if !tab.filter.isEmpty {
                Text("·  已过滤").foregroundStyle(tint)
            }
            Spacer(minLength: 8)
            if let freeSpace {
                // Narrow panes drop the label, then the figure, instead of truncating it to "可用 73.…".
                ViewThatFits {
                    Text("可用 \(Format.bytes(freeSpace))")
                    Text(Format.bytes(freeSpace)).help("可用空间")
                    Color.clear.frame(width: 0)
                }
                .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .frame(height: 26)
        .task(id: tab.url) {
            let values = try? tab.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeSpace = values?.volumeAvailableCapacityForImportantUsage
        }
    }
}
