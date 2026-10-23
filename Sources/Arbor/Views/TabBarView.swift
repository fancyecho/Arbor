import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let arborTab = UTType(exportedAs: "app.arbor.tab")
}

/// The tab being dragged. Tab drags never leave the app, so the payload is just a marker.
@MainActor
enum TabDrag {
    static var tab: TabState?
    static var pane: PaneState?
}

struct TabBarView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(pane.tabs) { tab in
                            TabChip(workspace: workspace, pane: pane, tab: tab, isSelected: tab.id == pane.activeTabID)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .animation(.snappy(duration: 0.18), value: pane.tabs.map(\.id))
                }
                .scrollIndicators(.hidden)
                .onChange(of: pane.activeTabID) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
                // Tabs that run past a narrow pane dissolve before the + button instead of being cut.
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    }
                }
            }
            .background {
                // Double-click empty space for a new tab, like Safari.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { newTab() }
            }

            Button(action: newTab) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("新建标签页 (⌘T)")
            .padding(.trailing, workspace.paneCount > 1 ? 0 : 8)
            if workspace.paneCount > 1 {
                PaneCloseButton { workspace.closePane(pane) }
                    .padding(.trailing, 6)
            }
        }
        .padding(.top, 6)
        .frame(height: 38)
        // Dropping a tab on empty bar space appends it to this pane.
        .onDrop(of: [.arborTab], delegate: TabBarDropDelegate(workspace: workspace, pane: pane))
    }

    private func newTab() {
        workspace.activate(pane)
        workspace.newTab()
    }
}

private struct TabChip: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isSelected: Bool

    @State private var hovering = false
    @State private var isFileTarget = false

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: tab.url.path))
                .resizable()
                .frame(width: 14, height: 14)
            if !tab.isPinned {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                if pane.tabs.count > 1 {
                    Button { workspace.close(tab, in: pane) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(hovering || isSelected ? 1 : 0)
                    .help("关闭标签页 (⌘W)")
                }
            }
        }
        .padding(.leading, tab.isPinned ? 9 : 8)
        .padding(.trailing, tab.isPinned ? 9 : (pane.tabs.count > 1 ? 4 : 8))
        .frame(height: 26)
        .frame(maxWidth: tab.isPinned ? nil : 180)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isFileTarget ? tint : .clear, lineWidth: 1.5)
                }
        }
        .overlay(alignment: .bottom) { progress }
        .overlay(alignment: .topTrailing) {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .offset(x: -2, y: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            pane.activeTabID = tab.id
            workspace.activate(pane)
            workspace.focusToken += 1
        }
        .onHover { hovering = $0 }
        .help(tab.isPinned ? "\(tab.title)（已固定）\n\(tab.url.path)" : tab.url.path)
        .contextMenu { menu }
        .onDrag {
            TabDrag.tab = tab
            TabDrag.pane = pane
            return NSItemProvider(item: tab.id.uuidString as NSString, typeIdentifier: UTType.arborTab.identifier)
        }
        .onDrop(of: [.arborTab, .fileURL],
                delegate: TabChipDropDelegate(workspace: workspace, pane: pane, target: tab, isFileTarget: $isFileTarget))
    }

    /// A copy into this tab's folder grows a bar along the chip's bottom edge, then the chip glows once.
    @ViewBuilder
    private var progress: some View {
        if let task = FileOperationQueue.shared.task(into: tab.url) {
            switch task.state {
            case .running:
                GeometryReader { geometry in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, geometry.size.width * (task.fraction ?? 0.05)), height: 2.5)
                        .animation(.linear(duration: 0.2), value: task.fraction)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 6)
                .padding(.bottom, 1)
            case .finished:
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1.5)
                    .shadow(color: tint.opacity(0.8), radius: 6)
                    .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("新建标签页", systemImage: "plus") {
            workspace.activate(pane)
            workspace.newTab()
        }
        Button("复制标签页", systemImage: "plus.square.on.square") { pane.duplicate(tab.id) }
        Button(tab.isPinned ? "取消固定" : "固定标签页", systemImage: tab.isPinned ? "pin.slash" : "pin") {
            pane.togglePin(tab.id)
        }
        Button("移到另一窗格", systemImage: "rectangle.split.2x1") { workspace.moveTabToOtherPane(tab, from: pane) }
        Divider()
        Button("拷贝路径", systemImage: "link") { FileOperations.copyPaths([tab.url]) }
        Button("在终端中打开", systemImage: "terminal") { FileOperations.openInTerminal(tab.url) }
        Button("在访达中显示", systemImage: "macwindow") { FileOperations.revealInFinder([tab.url]) }
        Divider()
        Button("关闭标签页", systemImage: "xmark") { workspace.close(tab, in: pane) }
            .disabled(pane.tabs.count < 2)
        Button("关闭其他标签页") { workspace.closeOtherTabs(tab, in: pane) }
            .disabled(pane.tabs.count < 2)
    }
}

// MARK: - Drop handling

/// Hovering a dragged tab over another reorders live; dropping files moves/copies them into that tab's folder.
private struct TabChipDropDelegate: DropDelegate {
    let workspace: WorkspaceState
    let pane: PaneState
    let target: TabState
    @Binding var isFileTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.arborTab, .fileURL])
    }

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [.arborTab]) {
            guard let dragged = TabDrag.tab, let from = TabDrag.pane, dragged.id != target.id else { return }
            let index = pane.index(of: target.id) ?? pane.tabs.count
            withAnimation(.snappy(duration: 0.18)) {
                TabDrag.tab = workspace.moveTab(dragged, from: from, to: pane, at: index)
            }
            TabDrag.pane = pane
        } else {
            isFileTarget = true
        }
    }

    func dropExited(info: DropInfo) { isFileTarget = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.arborTab]) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isFileTarget = false
        if info.hasItemsConforming(to: [.arborTab]) {
            TabDrag.tab = nil
            TabDrag.pane = nil
            return true
        }
        let destination = target.url
        loadFileURLs(info.itemProviders(for: [.fileURL])) { urls in
            FileOperationQueue.shared.transfer(urls, to: destination) { _, error in workspace.report(error) }
        }
        return true
    }
}

private struct TabBarDropDelegate: DropDelegate {
    let workspace: WorkspaceState
    let pane: PaneState

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.arborTab]) }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            TabDrag.tab = nil
            TabDrag.pane = nil
        }
        guard let dragged = TabDrag.tab, let from = TabDrag.pane else { return false }
        workspace.moveTab(dragged, from: from, to: pane, at: pane.tabs.count)
        return true
    }
}

/// Resolves dropped file URLs (delivered asynchronously) and hands them over on the main actor.
@MainActor
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let collected = URLCollector()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { collected.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(collected.urls) }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] { lock.withLock { storage } }
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
}

/// Closes a pane when there's more than one: a quiet ×, a soft circle behind it on hover.
private struct PaneCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 20, height: 20)
                .background { Circle().fill(Color.primary.opacity(hovering ? 0.09 : 0)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .secondary : .tertiary)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("关闭这个窗格")
    }
}
