import AppKit
import Observation

struct Place: Hashable {
    let name: String
    let url: URL
    let symbol: String
    var shortcut: Character?
    var isEjectable = false
    /// Volumes: how full they are (0…1), for the sidebar's capacity bar.
    var fullness: Double?
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
        // Free space changes all the time; catch up whenever Arbor comes to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { return nil }
            let isNetwork = values?.volumeIsLocal == false
            let ejectable = (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false) || isNetwork
            let isInternal = values?.volumeIsInternal ?? true
            let symbol = isNetwork ? "server.rack" : url.path == "/" ? "internaldrive" : (ejectable ? "externaldrive" : (isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"))
            var fullness: Double?
            // Read-only volumes (disk images, installers) report no free space; a "full" bar would mislead.
            if values?.volumeIsReadOnly != true,
               let total = values?.volumeTotalCapacity, total > 0, let free = values?.volumeAvailableCapacityForImportantUsage {
                fullness = min(max(1 - Double(free) / Double(total), 0), 1)
            }
            return Place(name: values?.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol,
                         isEjectable: ejectable, fullness: fullness)
        }
    }

    /// Volumes being ejected right now (the sidebar shows a spinner instead of the eject button).
    private(set) var ejecting: Set<URL> = []

    /// Ejects a disk or disk image without freezing the app. Arbor first lets go of the volume itself —
    /// tabs showing it move to the home folder, scans of it stop — since a volume Arbor is still looking
    /// at counts as "in use" and won't unmount.
    func eject(_ place: Place) {
        let volume = place.url.standardizedFileURL
        guard !ejecting.contains(volume) else { return }
        ejecting.insert(volume)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for workspace in WorkspaceRegistry.shared.workspaces {
            for pane in workspace.panes {
                for tab in pane.tabs where Self.isOnVolume(tab.url, volume) {
                    tab.navigate(to: home)
                }
            }
        }
        for scan in SpaceIndex.shared.scans where scan.covers(volume) { scan.cancel() }
        QuickLookController.shared.selectionChanged([])

        // Unmounting can take seconds (or fail after a wait): never on the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            var failure: Error?
            for attempt in 0..<3 {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    failure = nil
                    break
                } catch {
                    failure = error
                    if attempt < 2 { Thread.sleep(forTimeInterval: 0.6) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.ejecting.remove(volume)
                    self.refresh()
                    if let failure { Self.reportEjectFailure(failure, name: place.name) }
                }
            }
        }
    }

    static func isOnVolume(_ url: URL, _ volume: URL) -> Bool {
        let path = url.standardizedFileURL.path, root = volume.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func reportEjectFailure(_ error: Error, name: String) {
        let alert = NSAlert()
        alert.messageText = "无法推出“\(name)”"
        alert.informativeText = "有其他应用正在使用它。关闭使用其中文件的应用后再试一次。\n\n(\(error.localizedDescription))"
        alert.runModal()
    }
}
