import AppKit
import Observation

struct Place: Hashable {
    let name: String
    let url: URL
    let symbol: String
    var shortcut: Character?
    var isEjectable = false
}

enum Places {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func dir(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first ?? home
    }

    static let favorites: [Place] = [
        Place(name: "主目录", url: home, symbol: "house", shortcut: "h"),
        Place(name: "桌面", url: dir(.desktopDirectory), symbol: "menubar.dock.rectangle", shortcut: "d"),
        Place(name: "文稿", url: dir(.documentDirectory), symbol: "doc", shortcut: "o"),
        Place(name: "下载", url: dir(.downloadsDirectory), symbol: "arrow.down.circle", shortcut: "l"),
        Place(name: "应用程序", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.3x3", shortcut: "a"),
        Place(name: "图片", url: dir(.picturesDirectory), symbol: "photo", shortcut: nil),
        Place(name: "影片", url: dir(.moviesDirectory), symbol: "film", shortcut: nil),
        Place(name: "音乐", url: dir(.musicDirectory), symbol: "music.note", shortcut: nil),
    ]

    static var iCloudDrive: Place? {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Place(name: "iCloud 云盘", url: url, symbol: "icloud")
    }

    static var trash: Place {
        Place(name: "废纸篓", url: home.appendingPathComponent(".Trash"), symbol: "trash")
    }

    /// Known folders use their localized name ("下载"); anything else its display name.
    static func displayName(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let known = favorites.first(where: { $0.url.standardizedFileURL.path == path }) { return known.name }
        return FileManager.default.displayName(atPath: path)
    }

    static func symbol(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let known = favorites.first(where: { $0.url.standardizedFileURL.path == path }) { return known.symbol }
        if path == iCloudDrive?.url.standardizedFileURL.path { return "icloud" }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return isPackage ? "shippingbox" : "folder"
    }
}

/// Mounted volumes, refreshed on mount/unmount.
@MainActor @Observable
final class VolumeList {
    static let shared = VolumeList()

    private(set) var volumes: [Place] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { return nil }
            let isNetwork = values?.volumeIsLocal == false
            let ejectable = (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false) || isNetwork
            let isInternal = values?.volumeIsInternal ?? true
            let symbol = isNetwork ? "server.rack" : url.path == "/" ? "internaldrive" : (ejectable ? "externaldrive" : (isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"))
            return Place(name: values?.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol, isEjectable: ejectable)
        }
    }

    func eject(_ place: Place) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: place.url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
