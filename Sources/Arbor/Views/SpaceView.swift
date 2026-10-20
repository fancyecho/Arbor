import AppKit
import SwiftUI

/// "空间" view mode: where the space under this folder goes. A sunburst of the folder tree next to a
/// ranked list; it is the pane's own folder, so back/forward, the path bar, the inspector, Quick Look,
/// drag and drop and undoable trashing all work as everywhere else.
struct SpaceView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isActive: Bool

    @Environment(\.arborTint) private var tint
    @State private var hovered: SpaceNode?
    @State private var listMode: ListMode = .contents
    @State private var cache = LayoutCache()

    enum ListMode: String, CaseIterable, Identifiable {
        case contents, largest
        var id: Self { self }
        var title: String { self == .contents ? "内容" : "最大的文件" }
    }

    private var index: SpaceIndex { SpaceIndex.shared }

    var body: some View {
        let url = tab.url
        let scan = index.scan(covering: url)
        Group {
            if let scan, case .failed(let message) = scan.phase {
                unavailable(message, systemImage: "exclamationmark.triangle")
            } else if let scan, let node = scan.node(for: url) {
                content(scan: scan, node: node)
            } else if let scan, scan.isScanning {
                waiting(scan)
            } else if scan != nil {
                unavailable("这个文件夹不在上次的扫描结果里。", systemImage: "questionmark.folder", scanButton: true)
            } else if Self.isVolumeRoot(url) {
                VolumeLanding(url: url) { index.startScan(url) }
            } else {
                Color.clear.onAppear { index.startScan(url) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            workspace.quickLook()
            return .handled
        }
        .onKeyPress(.return) {
            open(selectionNode(in: scan))
            return .handled
        }
    }

    static func isVolumeRoot(_ url: URL) -> Bool {
        url.path == "/" || (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    // MARK: States

    private func waiting(_ scan: SpaceScan) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在扫描…").font(.headline)
            ScanCounterLine(scan: scan)
            Button("停止") { scan.cancel() }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ message: String, systemImage: String, scanButton: Bool = false) -> some View {
        ContentUnavailableView {
            Label("无法分析", systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if scanButton { Button("扫描这个文件夹") { index.startScan(tab.url) }.buttonStyle(.glassProminent) }
        }
    }

    // MARK: Content

    private func content(scan: SpaceScan, node: SpaceNode) -> some View {
        let isScanRoot = node === scan.root
        let hidden = isScanRoot && scan.unaccounted > 0 ? cache.hidden(size: scan.unaccounted) : nil
        let layout = cache.layout(for: node, extra: hidden, revision: scan.revision)
        let palette = SpacePalette(coloring: AppSettings.shared.spaceColoring)
        return GeometryReader { proxy in
            let wide = proxy.size.width >= 520
            VStack(spacing: 0) {
                SpaceHeader(scan: scan, node: node, onRescan: { rescan(scan, node: node) })
                if wide {
                    HStack(spacing: 0) {
                        chart(scan: scan, node: node, layout: layout, palette: palette)
                            .frame(width: min(proxy.size.width * 0.5, max(proxy.size.height - 70, 200)))
                        Divider().opacity(0.4).padding(.vertical, 12)
                        list(scan: scan, node: node, hidden: hidden, layout: layout, palette: palette)
                    }
                } else {
                    chart(scan: scan, node: node, layout: layout, palette: palette)
                        .frame(height: min(proxy.size.width, proxy.size.height * 0.52))
                    list(scan: scan, node: node, hidden: hidden, layout: layout, palette: palette)
                }
            }
        }
    }

    private func chart(scan: SpaceScan, node: SpaceNode, layout: SunburstLayout, palette: SpacePalette) -> some View {
        ZStack {
            SunburstView(root: node, layout: layout, palette: palette, hovered: $hovered,
                         onActivate: { activate($0, in: scan) },
                         onCenter: { goUp(from: node, in: scan) })
            CenterLabel(node: hovered ?? node, root: node, total: layout.total, revision: scan.revision, isRoot: hovered == nil,
                        canGoUp: node !== scan.root, scanning: scan.isScanning && node === scan.root)
                .allowsHitTesting(false)
        }
        .padding(14)
        .contextMenu { if let hovered, hovered.isItem { menu(for: hovered, in: scan) } }
        .onChange(of: scan.revision) { _, _ in
            // The hovered item was trashed or moved away: don't keep showing it in the middle.
            if let hovered, hovered.parent == nil, hovered.kind != .hidden { self.hovered = nil }
        }
        .task(id: scan.revision) {
            // Screenshot aid: ARBOR_SPACE_HOVER=Library/Caches highlights that slice as if under the pointer.
            guard let path = ProcessInfo.processInfo.environment["ARBOR_SPACE_HOVER"], !scan.isScanning else { return }
            hovered = scan.node(for: tab.url.appendingPathComponent(path))
        }
    }

    private func list(scan: SpaceScan, node: SpaceNode, hidden: SpaceNode?, layout: SunburstLayout,
                      palette: SpacePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CategoryBar(node: node, revision: scan.revision)
            GlassSegmented(selection: $listMode, options: [
                .init(value: .contents, title: "内容", symbol: "list.bullet"),
                .init(value: .largest, title: "最大的文件", symbol: "arrow.down.right.and.arrow.up.left"),
            ], compact: true)
            let rows = rows(for: node, hidden: hidden, revision: scan.revision)
            let largest = rows.first?.size ?? 1
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { child in
                        let slice = layout.segment(for: child)
                        SpaceRow(node: child, scan: scan, base: node, largest: largest, revision: scan.revision,
                                 color: slice.map { palette.color(for: $0) }
                                    ?? palette.color(node: child, branch: 0, depth: 1),
                                 showsPath: listMode == .largest,
                                 isHovered: hovered === child,
                                 isSelected: tab.selection.contains(scan.url(of: child)),
                                 onHover: { inside in hovered = inside ? child : (hovered === child ? nil : hovered) },
                                 onSelect: { select(child, in: scan) },
                                 onOpen: { open(child, in: scan) })
                            .contextMenu { if child.isItem { menu(for: child, in: scan) } }
                            .draggable(scan.url(of: child)) {
                                Label(child.name, systemImage: child.isContainer ? "folder" : "doc")
                            }
                    }
                    if listMode == .contents, node.children.count > rows.count {
                        Text("还有 \(node.children.count - rows.count) 项更小的项目")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
                    }
                }
                .padding(.bottom, 8)
                .slimScrollers(tint)
            }
            SpaceFootnotes(scan: scan, node: node, workspace: workspace)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func rows(for node: SpaceNode, hidden: SpaceNode?, revision: Int) -> [SpaceNode] {
        switch listMode {
        case .contents:
            var children = Array(node.children.prefix(400))
            if let hidden { children.append(hidden); children.sort { $0.size > $1.size } }
            return children
        case .largest:
            return cache.largest(for: node, revision: revision)
        }
    }

    // MARK: Actions

    private func activate(_ node: SpaceNode, in scan: SpaceScan) {
        workspace.activate(pane)
        if node.isBrowsable {
            tab.navigate(to: scan.url(of: node))
        } else if node.isItem {
            select(node, in: scan)
        }
    }

    private func goUp(from node: SpaceNode, in scan: SpaceScan) {
        workspace.activate(pane)
        guard let parent = node.parent else { return }
        tab.navigate(to: scan.url(of: parent), select: scan.url(of: node))
    }

    private func select(_ node: SpaceNode, in scan: SpaceScan) {
        workspace.activate(pane)
        guard node.isItem else { return }
        tab.selection = [scan.url(of: node)]
    }

    private func open(_ node: SpaceNode, in scan: SpaceScan) {
        guard node.isItem else { return }
        workspace.activate(pane)
        let url = scan.url(of: node)
        if node.isBrowsable {
            tab.navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func open(_ target: (SpaceNode, SpaceScan)?) {
        if let (node, scan) = target { open(node, in: scan) }
    }

    private func selectionNode(in scan: SpaceScan?) -> (SpaceNode, SpaceScan)? {
        guard let scan, let url = tab.selection.first, let node = scan.node(for: url) else { return nil }
        return (node, scan)
    }

    private func rescan(_ scan: SpaceScan, node: SpaceNode) {
        if node === scan.root {
            index.startScan(scan.rootURL)
        } else {
            scan.graft(scan.url(of: node))
        }
    }

    @ViewBuilder
    private func menu(for node: SpaceNode, in scan: SpaceScan) -> some View {
        let url = scan.url(of: node)
        MenuEntriesView(sections: ContextMenuBuilder.sections(
            workspace: workspace, tab: tab, selected: [FileItem(url: url)], includeOpenWith: false))
    }
}

/// Keeps the ring layout and the largest-files list until the tree or the folder changes.
@MainActor
final class LayoutCache {
    private var key: (node: ObjectIdentifier, revision: Int, extra: Int64)?
    private var cached: SunburstLayout?
    private var largestKey: (node: ObjectIdentifier, revision: Int)?
    private var largestFiles: [SpaceNode] = []
    private var hiddenNode: SpaceNode?

    /// One stable object for the volume's unaccounted space, so the list and the rings agree on it.
    func hidden(size: Int64) -> SpaceNode {
        if let hiddenNode, hiddenNode.size == size { return hiddenNode }
        let node = SpaceNode(name: "系统与其他", kind: .hidden, size: size, fileCount: 0)
        hiddenNode = node
        return node
    }

    func layout(for node: SpaceNode, extra: SpaceNode?, revision: Int) -> SunburstLayout {
        let newKey = (ObjectIdentifier(node), revision, extra?.size ?? 0)
        if let key, key == newKey, let cached { return cached }
        let layout = SunburstLayout.make(root: node, extra: extra)
        key = newKey
        cached = layout
        return layout
    }

    func largest(for node: SpaceNode, revision: Int) -> [SpaceNode] {
        let newKey = (ObjectIdentifier(node), revision)
        if let largestKey, largestKey == newKey { return largestFiles }
        largestFiles = node.largestFiles(limit: 60)
        largestKey = newKey
        return largestFiles
    }
}

// MARK: - Pieces

/// Status and actions above the chart; for a whole disk, how its capacity is used.
private struct SpaceHeader: View {
    let scan: SpaceScan
    let node: SpaceNode
    let onRescan: () -> Void

    @Environment(\.arborTint) private var tint
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if scan.isScanning {
                    ProgressView().controlSize(.mini)
                    ScanCounterLine(scan: scan)
                } else if scan.refreshing > 0 {
                    ProgressView().controlSize(.mini)
                    Text("正在重新扫描…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chart.pie.fill").foregroundStyle(tint)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                GlassSegmented(selection: $settings.spaceColoring, options: [
                    .init(value: .folders, title: "文件夹", symbol: "folder"),
                    .init(value: .types, title: "类型", symbol: "square.stack.3d.up"),
                ], compact: true)
                .help("按文件夹或按文件类型上色")
                if scan.isScanning {
                    Button { scan.cancel() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.glassCompact).help("停止扫描")
                } else {
                    Button(action: onRescan) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.glassCompact).help(node === scan.root ? "重新扫描" : "重新扫描这个文件夹")
                }
            }
            .font(.system(size: 11))
            if node === scan.root, let volume = scan.volume {
                CapacityBar(volume: volume, scanned: scan.isScanning ? scan.scannedBytes : scan.root.size,
                            fraction: scan.fraction, scanning: scan.isScanning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var summary: String {
        var parts = ["\(Format.bytes(node.size))", "\(node.fileCount.formatted()) 个文件"]
        if case .finished(let seconds) = scan.phase, node === scan.root {
            parts.append(String(format: "扫描用时 %.1f 秒", seconds))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ScanCounterLine: View {
    let scan: SpaceScan

    var body: some View {
        Text("已扫描 \(Format.bytes(scan.scannedBytes)) · \(scan.scannedItems.formatted()) 个文件")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Used / unaccounted / purgeable / free, as one bar.
private struct CapacityBar: View {
    let volume: SpaceScan.Volume
    let scanned: Int64
    let fraction: Double?
    let scanning: Bool

    @Environment(\.arborTint) private var tint

    var body: some View {
        let total = max(Double(volume.total), 1)
        let scannedPart = min(Double(scanned), Double(volume.used))
        let other = scanning ? 0 : max(Double(volume.used) - scannedPart, 0)
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 1.5) {
                    Capsule().fill(tint.gradient).frame(width: width * scannedPart / total)
                    if other > 0 {
                        Capsule().fill(Color.secondary.opacity(0.45)).frame(width: width * other / total)
                    }
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .animation(.easeOut(duration: 0.3), value: scanned)
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                legend(tint, scanning ? "已扫描" : "可见文件", Int64(scannedPart))
                if other > 0 { legend(Color.secondary.opacity(0.6), "系统与其他", Int64(other)) }
                if volume.purgeable > 0 { legend(.clear, "可由系统清除", volume.purgeable, dashed: true) }
                Spacer(minLength: 0)
                Text("可用 \(Format.bytes(volume.available + volume.purgeable)) / \(Format.bytes(volume.total))")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
        }
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .overlay { if dashed { Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2])) } }
                .frame(width: 7, height: 7)
            Text("\(title) \(Format.bytes(bytes))").foregroundStyle(.secondary)
        }
    }
}

/// Middle of the rings: the folder (or what the pointer is over), its size and share.
private struct CenterLabel: View {
    let node: SpaceNode
    let root: SpaceNode
    let total: Int64
    /// Nodes are plain objects: the tree's revision tells SwiftUI their numbers changed.
    let revision: Int
    let isRoot: Bool
    let canGoUp: Bool
    let scanning: Bool

    var body: some View {
        GeometryReader { proxy in
            let diameter = max(SunRings(size: proxy.size, maxDepth: SunburstLayout.maxDepth).hole * 2 - 10, 20)
            let roomy = diameter > 120
            // The text lives in the square inside the circle; it shrinks rather than truncating.
            VStack(spacing: roomy ? 3 : 1) {
                if isRoot, canGoUp, roomy {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if diameter > 80 {
                Text(node.kind == .smallFiles ? "更小的文件" : node.name)
                    .font(.system(size: roomy ? 12 : 10.5, weight: .semibold))
                    .lineLimit(roomy ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                }
                Text(Format.bytes(node.size))
                    .font(.system(size: diameter > 160 ? 22 : (roomy ? 17 : 14), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if roomy || !isRoot {
                    if isRoot {
                        Text(scanning ? "扫描中…" : "\(node.fileCount.formatted()) 个文件")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    } else if total > 0 {
                        Text(share)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(width: diameter * 0.8)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(Glass.hairline))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private var share: String {
        let percent = Double(node.size) / Double(max(total, 1)) * 100
        let text = percent < 0.1 ? "<0.1%" : String(format: percent < 10 ? "%.1f%%" : "%.0f%%", percent)
        if node.kind == .smallFiles { return "\(node.fileCount.formatted()) 个 · \(text)" }
        return "占 \(text)"
    }
}

/// What kinds of files fill this folder, as one stacked bar with the leading categories named.
private struct CategoryBar: View {
    let node: SpaceNode
    let revision: Int

    var body: some View {
        let total = max(node.categories.reduce(0, +), 1)
        let parts = FileCategory.allCases
            .map { ($0, node.categories.indices.contains($0.rawValue) ? node.categories[$0.rawValue] : 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { category, bytes in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(category.color)
                            .frame(width: max(proxy.size.width * CGFloat(bytes) / CGFloat(total) - 1.5, 0))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(parts.prefix(4), id: \.0) { category, bytes in
                    HStack(spacing: 4) {
                        Circle().fill(category.color).frame(width: 6, height: 6)
                        Text("\(category.title) \(Int((Double(bytes) / Double(total) * 100).rounded()))%")
                    }
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help(parts.map { "\($0.0.title)：\(Format.bytes($0.1))" }.joined(separator: "\n"))
    }
}

private struct SpaceRow: View {
    let node: SpaceNode
    let scan: SpaceScan
    let base: SpaceNode
    let largest: Int64
    let revision: Int
    let color: Color
    let showsPath: Bool
    let isHovered: Bool
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    @Environment(\.arborTint) private var tint

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 9, height: 9)
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if showsPath {
                    Text(location).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if isHovered, node.isItem {
                Button { StashShelf.shared.add([scan.url(of: node)]) } label: {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("加入暂存架：收集要清理的项目，再一起移到废纸篓")
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(proxy.size.width * CGFloat(node.size) / CGFloat(max(largest, 1)), 3))
                    }
            }
            .frame(width: 54, height: 4)
            Text(Format.bytes(node.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            if node.isBrowsable {
                Button(action: onOpen) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("进入“\(node.name)”")
            } else {
                Color.clear.frame(width: 12)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: showsPath ? 36 : 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(isSelected ? 0.18 : (isHovered ? 0.08 : 0)))
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .gesture(TapGesture(count: 2).onEnded(onOpen))
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }

    @ViewBuilder
    private var icon: some View {
        switch node.kind {
        case .smallFiles: Image(systemName: "square.stack.3d.down.right").foregroundStyle(.secondary)
        case .hidden: Image(systemName: "lock.shield").foregroundStyle(.secondary)
        case .unreadable: Image(systemName: "lock").foregroundStyle(.secondary)
        default: Image(nsImage: NSWorkspace.shared.icon(forFile: scan.url(of: node).path)).resizable()
        }
    }

    private var location: String {
        let names = node.components.dropLast()
        let baseCount = base.components.count
        return names.dropFirst(baseCount).joined(separator: " › ")
    }
}

/// Notes under the list: folders that couldn't be read, and space still held by the Trash.
private struct SpaceFootnotes: View {
    let scan: SpaceScan
    let node: SpaceNode
    let workspace: WorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scan.unreadableFolders > 0, node === scan.root, !scan.isScanning {
                HStack(spacing: 6) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text("\(scan.unreadableFolders) 个文件夹没有权限读取，实际占用可能更多。")
                    Button("授予完全磁盘访问权限…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.tintLink)
                }
            }
            if let trash = trashNode, trash.size > 50_000_000 {
                HStack(spacing: 6) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("废纸篓里还有 \(Format.bytes(trash.size))，清倒后才会真正释放。")
                    Button("打开废纸篓") { workspace.activeTab.navigate(to: Places.trash.url) }
                        .buttonStyle(.tintLink)
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var trashNode: SpaceNode? {
        guard node === scan.root else { return nil }
        return scan.node(for: Places.trash.url)
    }
}

/// A disk that hasn't been scanned yet: its capacity, and a button to look inside.
private struct VolumeLanding: View {
    let url: URL
    let onScan: () -> Void

    @Environment(\.arborTint) private var tint

    var body: some View {
        let volume = SpaceScan.volumeInfo(url)
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                if let volume {
                    Circle()
                        .trim(from: 0, to: CGFloat(Double(volume.used) / Double(max(volume.total, 1))))
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 2) {
                    Image(systemName: "internaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
                    if let volume {
                        Text(Format.bytes(volume.used)).font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("已用，共 \(Format.bytes(volume.total))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, height: 150)
            Text(volume?.name ?? url.lastPathComponent).font(.title3.weight(.semibold))
            Text("扫描整个磁盘，看看空间都去哪儿了。扫描只读取文件信息，不会改动任何东西。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("扫描磁盘", systemImage: "sparkle.magnifyingglass", action: onScan)
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
