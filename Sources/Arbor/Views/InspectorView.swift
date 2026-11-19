import UniformTypeIdentifiers
import SwiftUI

/// Right-hand panel: preview and metadata for the selection (or the current folder).
struct InspectorView: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState

    var body: some View {
        let tab = workspace.activeTab
        let selected = tab.selectedItems
        ScrollView {
            Group {
                if selected.count > 1 {
                    MultiSelectionInfo(items: selected)
                } else {
                    SingleItemInfo(item: selected.first ?? FileItem(url: tab.url))
                        .id(selected.first?.url ?? tab.url)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: selected.first?.url ?? tab.url)
            .animation(.easeOut(duration: 0.18), value: selected.count > 1)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .top)
            .slimScrollers(tint)
        }

    }
}

private struct SingleItemInfo: View {
    let item: FileItem

    @State private var folderSize: Int64?
    @State private var computing = false
    /// The previewed photo's color, glowing softly behind the preview (photos only).
    @State private var mood: Color?
    private let settings = AppSettings.shared

    private var isPhoto: Bool { item.contentType?.conforms(to: .image) == true }

    var body: some View {
        VStack(spacing: 16) {
            if TextFile.isText(item) {
                TextPreview(item: item)
            } else {
                // The preview is the inspector's main subject: a large well at the top.
                ThumbnailView(item: item, size: 256)
                    .frame(maxWidth: 220, maxHeight: 190)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.l)
                    .background {
                        RoundedRectangle(cornerRadius: Metrics.wellRadius, style: .continuous)
                            .fill(Surface.chip)
                            .overlay {
                                if let mood {
                                    RoundedRectangle(cornerRadius: Metrics.wellRadius, style: .continuous)
                                        .fill(RadialGradient(colors: [mood.opacity(0.45), mood.opacity(0.12), mood.opacity(0)],
                                                             center: .center, startRadius: 10, endRadius: 190))
                                        .transition(.opacity)
                                }
                            }
                    }
                    .animation(.easeInOut(duration: 0.4), value: mood)
                    .task(id: item.url) {
                        mood = isPhoto ? await AmbientColor.color(for: item.url, modified: item.modified) : nil
                    }
            }

            GitDiffSection(item: item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(TypeScale.emphasis)
                    .textSelection(.enabled)
                Text(item.localizedKind)
                    .font(TypeScale.secondary)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.xs)

            Grid(alignment: .leading, horizontalSpacing: Metrics.m, verticalSpacing: 7) {
                row(L("大小")) {
                    if item.isNavigable {
                        if let folderSize {
                            Text(Format.bytes(folderSize))
                        } else if computing {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L("正在计算…")) }
                        } else {
                            Button(L("计算")) { Task { await computeSize() } }
                                .buttonStyle(.tintLink)
                        }
                    } else {
                        Text(Format.bytes(item.size))
                    }
                }
                row(L("创建时间")) { Text(Format.fullDate(item.created)) }
                row(L("修改时间")) { Text(Format.fullDate(item.modified)) }
                if !item.tagNames.isEmpty {
                    row(L("标签")) { Text(item.tagNames.joined(separator: L("、"))) }
                }
                row(L("位置")) {
                    Text((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .font(TypeScale.secondary)
            .padding(.horizontal, Metrics.xs)

            HStack(spacing: 8) {
                Button(L("拷贝路径"), systemImage: "link") { FileOperations.copyPaths([item.url]) }
                Button(L("在访达中显示"), systemImage: "macwindow") { FileOperations.revealInFinder([item.url]) }
            }
            .buttonStyle(.glassCompact)
        }
        .task(id: item.url) {
            folderSize = nil
            if item.isNavigable, settings.autoFolderSize { await computeSize() }
        }
    }

    private func computeSize() async {
        // Already known from a space scan: no need to walk the folder again.
        if let scanned = SpaceIndex.shared.folderSize(item.url) {
            folderSize = scanned
            return
        }
        computing = true
        let size = await DirectoryLoader.folderSize(item.url)
        if !Task.isCancelled { folderSize = size }
        computing = false
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MultiSelectionInfo: View {
    let items: [FileItem]
    @Environment(\.arborTintNSColor) private var tintColor

    @State private var total: Int64?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(items.prefix(4).enumerated().reversed()), id: \.offset) { index, item in
                    Image(nsImage: item.icon(tint: tintColor))
                        .resizable()
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(Double(index) * 6 - 6))
                        .offset(x: CGFloat(index) * 8 - 8)
                }
            }
            .frame(height: 160)

            Text(L("\(items.count) 个项目")).font(TypeScale.emphasis)
            let folders = items.filter(\.isNavigable).count
            Text(L("\(items.count - folders) 个文件，\(folders) 个文件夹"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text(L("总大小")).foregroundStyle(.secondary)
                Spacer()
                if let total { Text(Format.bytes(total)) } else { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 12))
        }
        .task(id: items.map(\.url)) {
            total = nil
            var sum: Int64 = 0
            for item in items {
                if item.isNavigable {
                    guard let size = await DirectoryLoader.folderSize(item.url) else { return }
                    sum += size
                } else {
                    sum += item.size ?? 0
                }
            }
            total = sum
        }
    }
}
