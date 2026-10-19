import SwiftUI
import UniformTypeIdentifiers

/// Up to four photo thumbnails from inside a folder, cached per folder version.
@MainActor
enum FolderCovers {
    private static var cache: [String: [NSImage]] = [:]

    static func images(for folder: URL, modified: Date?) async -> [NSImage] {
        let key = "\(folder.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = cache[key] { return hit }
        let photos = await Task.detached(priority: .utility) { () -> [URL] in
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentTypeKey]
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                         options: [.skipsHiddenFiles])) ?? []
            // Read each date once (prefetched above), only for images, and cap huge folders.
            let dated = children.prefix(2000).compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.contentType?.conforms(to: .image) == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            return dated.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        }.value
        var images: [NSImage] = []
        for url in photos {
            if let image = await ThumbnailCache.shared.thumbnail(for: url, size: 80, modified: nil, scale: 2) { images.append(image) }
        }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = images
        return images
    }
}

/// A folder drawn as a frosted-glass folder holding a mosaic of the photos inside it; the only color
/// comes from the photos themselves. Folders without photos keep the normal icon.
struct FolderCoverView: View {
    let item: FileItem
    let size: CGFloat

    @State private var images: [NSImage] = []

    private static let frame = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.92)
    })

    var body: some View {
        Group {
            if images.isEmpty {
                ThumbnailView(item: item, size: size)
            } else {
                mosaic
            }
        }
        .task(id: "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)") {
            let found = await FolderCovers.images(for: item.url, modified: item.modified)
            withAnimation(.easeOut(duration: 0.25)) { images = found }
        }
    }

    private var mosaic: some View {
        let width = size * 1.12, height = size * 0.88
        return ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                .fill(Self.frame)
                .frame(width: width * 0.42, height: 10)
                .offset(y: -6)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.frame)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .frame(width: width, height: height)
                .overlay {
                    tiles
                        .padding(.horizontal, 5)
                        .padding(.top, 9)
                        .padding(.bottom, 5)
                }
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        }
        .frame(width: width, height: height + 6, alignment: .bottom)
    }

    @ViewBuilder
    private var tiles: some View {
        let columns = images.count == 1 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Color.clear
                    .aspectRatio(images.count <= 2 ? 0.7 : 1.3, contentMode: .fit)
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
