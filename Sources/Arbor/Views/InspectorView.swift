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
                }
            }
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
                ThumbnailView(item: item, size: 256)
                    .frame(maxWidth: 220, maxHeight: 200)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        if let mood {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(RadialGradient(colors: [mood.opacity(0.45), mood.opacity(0.12), mood.opacity(0)],
                                                     center: .center, startRadius: 10, endRadius: 190))
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.4), value: mood)
                    .task(id: item.url) {
                        mood = isPhoto ? await AmbientColor.color(for: item.url, modified: item.modified) : nil
                    }
            }

            VStack(spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text(item.localizedKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("大小") {
                    if item.isNavigable {
                        if let folderSize {
                            Text(Format.bytes(folderSize))
                        } else if computing {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在计算…") }
                        } else {
                            Button("计算") { Task { await computeSize() } }
                                .buttonStyle(.link)
                        }
                    } else {
                        Text(Format.bytes(item.size))
                    }
                }
                row("创建时间") { Text(Format.date(item.created)) }
                row("修改时间") { Text(Format.date(item.modified)) }
                if !item.tagNames.isEmpty {
                    row("标签") { Text(item.tagNames.joined(separator: "、")) }
                }
                row("位置") {
                    Text((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .font(.system(size: 12))

            HStack {
                Button("拷贝路径", systemImage: "link") { FileOperations.copyPaths([item.url]) }
                Button("在访达中显示", systemImage: "macwindow") { FileOperations.revealInFinder([item.url]) }
            }
            .controlSize(.small)
        }
        .task(id: item.url) {
            folderSize = nil
            if item.isNavigable, settings.autoFolderSize { await computeSize() }
        }
    }

    private func computeSize() async {
        computing = true
        let size = await DirectoryLoader.folderSize(item.url)
        if !Task.isCancelled { folderSize = size }
        computing = false
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MultiSelectionInfo: View {
    let items: [FileItem]

    @State private var total: Int64?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(items.prefix(4).enumerated().reversed()), id: \.offset) { index, item in
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(Double(index) * 6 - 6))
                        .offset(x: CGFloat(index) * 8 - 8)
                }
            }
            .frame(height: 160)

            Text("\(items.count) 个项目").font(.headline)
            let folders = items.filter(\.isNavigable).count
            Text("\(items.count - folders) 个文件，\(folders) 个文件夹")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("总大小").foregroundStyle(.secondary)
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
