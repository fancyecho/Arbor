import Foundation
import Observation

struct FavoriteItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { Places.displayName(for: url) }
    var symbol: String { Places.symbol(for: url) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// User-editable sidebar: favorites (drag in, reorder, remove), recent folders and
/// which sections are collapsed. Persisted in UserDefaults.
@MainActor @Observable
final class SidebarStore {
    static let shared = SidebarStore()

    private(set) var favorites: [FavoriteItem]
    private(set) var recents: [String]
    private var collapsed: Set<String>

    private let defaults = AppDefaults.store
    private let recentLimit = 12

    private init() {
        if let data = defaults.data(forKey: "sidebar.favorites"),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) {
            favorites = decoded
        } else {
            favorites = Self.defaultFavorites
        }
        recents = defaults.stringArray(forKey: "sidebar.recents") ?? []
        collapsed = Set(defaults.stringArray(forKey: "sidebar.collapsed") ?? [])
    }

    static var defaultFavorites: [FavoriteItem] {
        Places.favorites.map { FavoriteItem(path: $0.url.standardizedFileURL.path) }
    }

    // MARK: Favorites

    func isFavorite(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return favorites.contains { $0.path == path }
    }

    func addFavorite(_ url: URL, at index: Int? = nil) {
        guard TabState.resolvedDirectory(url) != nil || url.hasDirectoryPath else { return }
        let path = url.standardizedFileURL.path
        if let existing = favorites.firstIndex(where: { $0.path == path }) {
            // Dropping an existing favorite somewhere else just moves it.
            guard let index else { return }
            moveFavorites(from: IndexSet(integer: existing), to: index)
            return
        }
        let item = FavoriteItem(path: path)
        favorites.insert(item, at: min(max(index ?? favorites.count, 0), favorites.count))
        saveFavorites()
    }

    func removeFavorite(_ item: FavoriteItem) {
        favorites.removeAll { $0.id == item.id }
        saveFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    func resetFavorites() {
        favorites = Self.defaultFavorites
        saveFavorites()
    }

    private func saveFavorites() {
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "sidebar.favorites")
    }

    // MARK: Recents

    func visit(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return }
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > recentLimit { recents.removeLast(recents.count - recentLimit) }
        defaults.set(recents, forKey: "sidebar.recents")
    }

    func clearRecents() {
        recents.removeAll()
        defaults.set(recents, forKey: "sidebar.recents")
    }

    // MARK: Sections

    func isExpanded(_ section: String) -> Bool { !collapsed.contains(section) }

    func setExpanded(_ section: String, _ expanded: Bool) {
        if expanded { collapsed.remove(section) } else { collapsed.insert(section) }
        defaults.set(Array(collapsed), forKey: "sidebar.collapsed")
    }
}

/// Remembers selection and scroll position per folder, so returning to a folder
/// (back/forward, up, sidebar, path bar) looks exactly as you left it.
@MainActor
final class FolderMemory {
    static let shared = FolderMemory()

    struct Entry {
        var selection: Set<String>
        var anchor: String?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let limit = 300

    func remember(_ folder: URL, selection: Set<URL>, anchor: URL?) {
        let key = folder.standardizedFileURL.path
        entries[key] = Entry(selection: Set(selection.map(\.standardizedFileURL.path)), anchor: anchor?.standardizedFileURL.path)
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > limit { entries[order.removeFirst()] = nil }
    }

    func recall(_ folder: URL) -> (selection: Set<URL>, anchor: URL?)? {
        guard let entry = entries[folder.standardizedFileURL.path] else { return nil }
        return (Set(entry.selection.map { URL(fileURLWithPath: $0) }), entry.anchor.map { URL(fileURLWithPath: $0) })
    }
}
