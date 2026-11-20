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

/// The tabs of a pane, shown once it has a second one. Tabs share the width equally (like Finder and Safari)
/// inside a recessed track; the selected one is a raised tab that slides over when you switch.
struct TabBarView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let isActive: Bool

    @Namespace private var selection

    private static let minTabWidth: CGFloat = 112
    private static let maxTabWidth: CGFloat = 240
    private static let pinnedWidth: CGFloat = 34
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                let width = tabWidth(available: proxy.size.width)
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: Self.spacing) {
                            ForEach(pane.tabs) { tab in
                                TabChip(workspace: workspace, pane: pane, tab: tab,
                                        isSelected: tab.id == pane.activeTabID, selection: selection)
                                    .frame(width: tab.isPinned ? Self.pinnedWidth : width)
                                    .id(tab.id)
                                    .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                                                            removal: .opacity))
                            }
                        }
                        .padding(3)
                        .animation(.snappy(duration: 0.22), value: pane.tabs.map(\.id))
                        .animation(.snappy(duration: 0.26), value: pane.activeTabID)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: pane.activeTabID) { _, id in
                        withAnimation(.snappy) { scroller.scrollTo(id) }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius + 3, style: .continuous).fill(Self.track)
                }
                // Tabs that run past a narrow pane dissolve at the edge instead of being cut.
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                    }
                }
                .background {
                    // Double-click empty space for a new tab, like Safari.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { newTab() }
                }
            }
            .frame(height: 30)

            Button(action: newTab) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("新建标签页 (⌘T)"))
            if workspace.paneCount > 1 {
                PaneCloseButton { workspace.closePane(pane) }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
        // Dropping a tab on empty bar space appends it to this pane.
        .onDrop(of: [.arborTab], delegate: TabBarDropDelegate(workspace: workspace, pane: pane))
    }

    /// Equal shares of the bar, within limits; past the minimum the strip scrolls.
    private func tabWidth(available: CGFloat) -> CGFloat {
        let pinned = pane.tabs.filter(\.isPinned).count
        let others = max(pane.tabs.count - pinned, 1)
        let room = available - 6 - CGFloat(pinned) * Self.pinnedWidth - CGFloat(pane.tabs.count - 1) * Self.spacing
        return min(max(room / CGFloat(others), Self.minTabWidth), Self.maxTabWidth)
    }

    /// The well the tabs sit in: a step darker than the card.
    static let track = Color(nsColor: .adaptive(light: NSColor(hex: 0x1C1C34, alpha: 0.05), dark: NSColor(white: 0, alpha: 0.22)))

    private func newTab() {
        workspace.activate(pane)
        workspace.newTab()
    }
}

private struct TabChip: View {
    @Environment(\.arborTint) private var tint
    @Environment(\.colorScheme) private var colorScheme
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isSelected: Bool
    let selection: Namespace.ID

    @State private var hovering = false
    @State private var hoveringClose = false
    @State private var isFileTarget = false
    @State private var springLoader = SpringLoader()

    /// The selected tab: a raised solid surface, like a card lifted off the track.
    static let raised = Color(nsColor: .adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.12)))
    private static let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)

    /// An assistant result tab that the next results will replace.
    private var isPreview: Bool { tab.isTemporary && tab.aiQuery != nil }

    var body: some View {
        HStack(spacing: 6) {
            icon
            if !tab.isPinned {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                closeButton
            }
        }
        .padding(.leading, tab.isPinned ? 0 : 9)
        .padding(.trailing, tab.isPinned ? 0 : 4)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background {
            if isSelected {
                Self.shape
                    .fill(Self.raised)
                    .overlay { Self.shape.strokeBorder(Surface.hairline, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                    .matchedGeometryEffect(id: "selection", in: selection)
            } else if hovering {
                Self.shape.fill(Color.primary.opacity(0.05))
            }
        }
        .overlay {
            if isFileTarget {
                Self.shape.strokeBorder(tint, lineWidth: 1.5)
            } else if isPreview {
                // Temporary: a dashed edge (italics don't exist in Chinese), solid once kept.
                Self.shape.strokeBorder(tint.opacity(isSelected ? 0.55 : 0.35),
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { progress }
        .overlay(alignment: .topTrailing) {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.tertiary)
                    .offset(x: -3, y: 3)
            }
        }
        .contentShape(Rectangle())
        // Double-clicking a preview tab keeps it (the next results get a tab of their own).
        .onTapGesture(count: 2) { if isPreview { keep() } }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(help)
        .contextMenu { menu }
        .onDrag {
            TabDrag.tab = tab
            TabDrag.pane = pane
            return NSItemProvider(item: tab.id.uuidString as NSString, typeIdentifier: UTType.arborTab.identifier)
        }
        .onDrop(of: [.arborTab, .fileURL],
                delegate: TabChipDropDelegate(workspace: workspace, pane: pane, target: tab, isFileTarget: $isFileTarget,
                                              springLoader: springLoader))
    }

    @ViewBuilder
    private var icon: some View {
        if tab.aiQuery != nil {
            // The assistant's results: the sparkle in the glow's colors.
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: Array(AppSettings.shared.aiGlow.colors(dark: colorScheme == .dark).prefix(4)),
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 14, height: 14)
        } else {
            Image(nsImage: FolderIcon.icon(for: tab.url, isDirectory: true, isPackage: false, tint: workspace.tint.nsColor))
                .resizable()
                .frame(width: 14, height: 14)
                .opacity(isSelected ? 1 : 0.8)
        }
    }

    /// Shown on the selected tab and on hover, so a tab can always be closed where it is.
    private var closeButton: some View {
        Button { workspace.close(tab, in: pane) } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background { Circle().fill(Color.primary.opacity(hoveringClose ? 0.1 : 0)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hovering || isSelected ? 1 : 0)
        .onHover { hoveringClose = $0 }
        .help(L("关闭标签页 (⌘W)"))
    }

    private var help: String {
        if isPreview { return L("AI 结果：\(tab.title)\n临时标签页（虚线边框），下次的结果会替换它；双击保留") }
        if tab.aiQuery != nil { return L("AI 结果：\(tab.title)") }
        return tab.isPinned ? L("\(tab.title)（已固定）\n\(tab.url.path)") : tab.url.path
    }

    private func select() {
        pane.activeTabID = tab.id
        workspace.activate(pane)
        workspace.focusToken += 1
    }

    private func keep() {
        withAnimation(.snappy(duration: 0.2)) { tab.isTemporary = false }
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
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
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
        if isPreview {
            Button(L("保留这个标签页"), systemImage: "checkmark.rectangle") { keep() }
            Divider()
        }
        Button(L("新建标签页"), systemImage: "plus") {
            workspace.activate(pane)
            workspace.newTab()
        }
        Button(L("复制标签页"), systemImage: "plus.square.on.square") { pane.duplicate(tab.id) }
        Button(tab.isPinned ? L("取消固定") : L("固定标签页"), systemImage: tab.isPinned ? "pin.slash" : "pin") {
            pane.togglePin(tab.id)
        }
        Button(L("移到另一窗格"), systemImage: "rectangle.split.2x1") { workspace.moveTabToOtherPane(tab, from: pane) }
        Divider()
        Button(L("拷贝路径"), systemImage: "link") { FileOperations.copyPaths([tab.url]) }
        Button(L("在终端中打开"), systemImage: "terminal") { FileOperations.openInTerminal(tab.url) }
        Button(L("在访达中显示"), systemImage: "macwindow") { FileOperations.revealInFinder([tab.url]) }
        Divider()
        Button(L("关闭标签页"), systemImage: "xmark") { workspace.close(tab, in: pane) }
            .disabled(pane.tabs.count < 2)
        Button(L("关闭其他标签页")) { workspace.closeOtherTabs(tab, in: pane) }
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
    let springLoader: SpringLoader

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
            // Holding files over a tab brings it to the front, like Finder, so they can go deeper in.
            let (workspace, pane, target) = (workspace, pane, target)
            springLoader.open = { _ in
                workspace.activate(pane)
                pane.activeTabID = target.id
            }
            springLoader.hover(target.url)
        }
    }

    func dropExited(info: DropInfo) {
        isFileTarget = false
        springLoader.cancel()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.arborTab]) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isFileTarget = false
        springLoader.cancel()
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
struct PaneCloseButton: View {
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
        .help(L("关闭这个窗格"))
    }
}
