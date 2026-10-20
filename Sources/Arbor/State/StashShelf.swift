import AppKit
import Observation
import SwiftUI

/// A floating shelf for collecting files from different folders, then moving, copying or trashing them in
/// one go — with their sizes and the total, so it doubles as a clean-up basket for the space view.
@MainActor @Observable
final class StashShelf {
    static let shared = StashShelf()

    private(set) var items: [URL] = []
    private(set) var isVisible = false
    /// Measured sizes by path (folders take a moment; scanned ones are known at once).
    private(set) var sizes: [String: Int64] = [:]

    @ObservationIgnored private var panel: NSPanel?
    private let defaults = AppDefaults.store

    private init() {
        items = (defaults.stringArray(forKey: "shelf.items") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.standardizedFileURL.path))
        items += urls.filter { !known.contains($0.standardizedFileURL.path) }
        save()
        show()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.isSameFile(as: url) }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Drops entries whose files were moved or deleted elsewhere.
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    func transferAll(to directory: URL, move: Bool, workspace: WorkspaceState?) {
        prune()
        let sources = items
        guard !sources.isEmpty else { return }
        let completion: ([URL], Error?) -> Void = { [weak self] results, error in
            workspace?.report(error)
            if move { self?.prune() }
            if let tab = workspace?.activeTab, directory.isSameFile(as: tab.url) { tab.reload(selecting: Set(results)) }
        }
        if move {
            FileOperationQueue.shared.move(sources, to: directory, completion: completion)
        } else {
            FileOperationQueue.shared.copy(sources, to: directory, completion: completion)
        }
    }

    /// Sum of the items' sizes, or nil while some are still being measured.
    var totalSize: Int64? {
        let known = items.compactMap { sizes[$0.path] }
        return known.count == items.count ? known.reduce(0, +) : nil
    }

    func measure(_ url: URL) async {
        guard sizes[url.path] == nil else { return }
        if let scanned = SpaceIndex.shared.folderSize(url) {
            sizes[url.path] = scanned
            return
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true {
            if let size = await DirectoryLoader.folderSize(url) { sizes[url.path] = size }
        } else {
            sizes[url.path] = Int64(values?.totalFileAllocatedSize ?? 0)
        }
    }

    /// Moves everything on the shelf to the Trash (one undo step), after asking.
    func trashAll(workspace: WorkspaceState?) {
        prune()
        let sources = items
        guard !sources.isEmpty else { return }
        let alert = NSAlert()
        let size = totalSize.map { "（\(Format.bytes($0))）" } ?? ""
        alert.messageText = "把暂存架上的 \(sources.count) 个项目\(size)移到废纸篓？"
        alert.informativeText = "可以用 ⌘Z 撤销。清倒废纸篓后空间才会真正释放。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FileOperationQueue.shared.trash(sources) { [weak self] error in
            workspace?.report(error)
            self?.prune()
            workspace?.activeTab.reload()
        }
    }

    private func save() {
        defaults.set(items.map(\.path), forKey: "shelf.items")
    }

    // MARK: Panel

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            // Glass all the way to the top, like the main window: no title bar strip, just the close button.
            panel.title = "暂存架"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.minSize = NSSize(width: 280, height: 300)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = NSHostingView(rootView: StashShelfView())
            if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                panel.setFrameOrigin(NSPoint(x: main.frame.maxX - 320, y: main.frame.minY + 40))
            } else {
                panel.center()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
                MainActor.assumeIsolated { StashShelf.shared.isVisible = false }
            }
            self.panel = panel
        }
        prune()
        panel?.orderFront(nil)
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
}

struct StashShelfView: View {
    private let shelf = StashShelf.shared
    @State private var dropTargeted = false

    private var tint: Color { WorkspaceRegistry.shared.current?.tint.color ?? WorkspaceTint.indigo.color }

    var body: some View {
        VStack(spacing: 0) {
            header
            if shelf.items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(shelf.items, id: \.self) { url in ShelfRow(url: url) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            footer
        }
        .background { WorkspaceBackdrop(tint: tint).opacity(0.9) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.08)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .environment(\.arborTint, tint)
        .tint(tint)
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// Sits in the transparent title bar, to the right of the close button.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").foregroundStyle(tint)
            Text("暂存架").font(.system(size: 13, weight: .semibold))
            if !shelf.items.isEmpty {
                Text("\(shelf.items.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(tint.opacity(0.18)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .padding(.top, 2)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 76, height: 76)
                Circle().strokeBorder(tint.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).frame(width: 76, height: 76)
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .medium)).foregroundStyle(tint)
            }
            Text("把文件拖到这里").font(.system(size: 13, weight: .semibold))
            Text("从不同文件夹收集文件，\n再一次性移动、拷贝或移到废纸篓。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !shelf.items.isEmpty {
                HStack {
                    Text("\(shelf.items.count) 个项目")
                    Spacer()
                    Text(shelf.totalSize.map { "共 \(Format.bytes($0))" } ?? "正在计算大小…").monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                let target = WorkspaceRegistry.shared.current
                let here = target?.activeTab.url ?? URL(fileURLWithPath: NSHomeDirectory())
                Button("移动到此处") { shelf.transferAll(to: here, move: true, workspace: target) }
                    .buttonStyle(.glassProminentCompact)
                Button("拷贝到此处") { shelf.transferAll(to: here, move: false, workspace: target) }
                    .buttonStyle(.glassCompact)
                Spacer(minLength: 4)
                Button { shelf.trashAll(workspace: target) } label: { Image(systemName: "trash") }
                    .buttonStyle(.glassCompact)
                    .help("全部移到废纸篓（可撤销）")
                Button { shelf.clear() } label: { Image(systemName: "xmark.bin") }
                    .buttonStyle(.glassCompact)
                    .help("清空暂存架（不会删除文件）")
            }
            .disabled(shelf.items.isEmpty)
            .help("“此处”指最近使用的 Arbor 窗口中当前的文件夹")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
        }
    }
}

/// One collected item: a small glass card with its icon, name, where it came from and its size.
private struct ShelfRow: View {
    let url: URL
    @State private var hovering = false
    @Environment(\.arborTint) private var tint

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { StashShelf.shared.remove(url) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("移出暂存架")
            } else if let size = StashShelf.shared.sizes[url.path] {
                Text(Format.bytes(size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Glass.card(active: hovering))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? tint.opacity(0.35) : Glass.hairline))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .task(id: url) { await StashShelf.shared.measure(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("在 Arbor 中显示") { WorkspaceRegistry.shared.current?.go(to: url) }
            Button("打开") { NSWorkspace.shared.open(url) }
            Divider()
            Button("移出暂存架") { StashShelf.shared.remove(url) }
        }
    }
}
