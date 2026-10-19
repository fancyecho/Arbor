import CryptoKit
import Foundation

/// How an item compares with the same-named item in the other pane.
enum CompareStatus: String, Sendable {
    case onlyHere, newer, older, different, same

    var label: String {
        switch self {
        case .onlyHere: "仅此侧"
        case .newer: "较新"
        case .older: "较旧"
        case .different: "不同"
        case .same: "相同"
        }
    }
}

enum CompareSelection: String, CaseIterable, Identifiable {
    case differing, onlyHere, newer

    var id: Self { self }

    var title: String {
        switch self {
        case .differing: "选择所有不同项（新增、较新、较旧、不同）"
        case .onlyHere: "选择仅此侧有的项目"
        case .newer: "选择较新的项目"
        }
    }

    func includes(_ status: CompareStatus) -> Bool {
        switch self {
        case .differing: status != .same
        case .onlyHere: status == .onlyHere
        case .newer: status == .newer || status == .onlyHere
        }
    }
}

enum FolderCompare {
    /// Modification times closer than this count as equal (FAT/exFAT and network volumes round times).
    static let tolerance: TimeInterval = 2

    /// Compares two listings by name. Returns the status of each item, keyed by name, for each side.
    static func compare(_ left: [FileItem], _ right: [FileItem]) -> (left: [String: CompareStatus], right: [String: CompareStatus]) {
        let rightByName = Dictionary(right.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let leftByName = Dictionary(left.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var l: [String: CompareStatus] = [:], r: [String: CompareStatus] = [:]
        for item in left {
            guard let other = rightByName[item.name] else { l[item.name] = .onlyHere; continue }
            let (a, b) = status(item, other)
            l[item.name] = a
            r[item.name] = b
        }
        for item in right where leftByName[item.name] == nil { r[item.name] = .onlyHere }
        return (l, r)
    }

    private static func status(_ a: FileItem, _ b: FileItem) -> (CompareStatus, CompareStatus) {
        if a.isNavigable != b.isNavigable { return (.different, .different) }
        if a.isNavigable { return (.same, .same) }
        let ta = a.modified ?? .distantPast, tb = b.modified ?? .distantPast
        if ta.timeIntervalSince(tb) > tolerance { return (.newer, .older) }
        if tb.timeIntervalSince(ta) > tolerance { return (.older, .newer) }
        return a.size == b.size ? (.same, .same) : (.different, .different)
    }
}

// MARK: - Folder sync

struct SyncOptions: Equatable, Hashable {
    enum Direction: String, CaseIterable, Identifiable {
        case toOther, fromOther, both
        var id: Self { self }
    }

    var direction: Direction = .toOther
    var recursive = true
    /// Mirror: trash items in the target that the source doesn't have (one-way only).
    var deleteExtras = false
    /// Also compare file contents (SHA-256) when size and date match.
    var compareContents = false
}

struct SyncAction: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case add, update, delete }

    let kind: Kind
    /// Item to copy (add/update) or to trash (delete).
    let item: URL
    /// Folder the copy goes into (unused for delete).
    let destination: URL
    /// Path relative to the synced folder, for display.
    let relativePath: String

    var id: String { kind.rawValue + item.path + destination.path }
}

enum SyncPlanner {
    private static let ignored: Set<String> = [".DS_Store", ".localized"]

    static func plan(_ a: URL, _ b: URL, options: SyncOptions, cancel: CancelFlag = CancelFlag()) -> [SyncAction] {
        switch options.direction {
        case .toOther: return plan(source: a, target: b, options: options, prefix: "", cancel: cancel)
        case .fromOther: return plan(source: b, target: a, options: options, prefix: "", cancel: cancel)
        case .both:
            var twoWay = options
            twoWay.deleteExtras = false
            // Two-way never overwrites with an older file: only additions and newer versions travel.
            return plan(source: a, target: b, options: twoWay, prefix: "", cancel: cancel, newerOnly: true)
                + plan(source: b, target: a, options: twoWay, prefix: "", cancel: cancel, newerOnly: true)
        }
    }

    private static func plan(source: URL, target: URL, options: SyncOptions, prefix: String,
                             cancel: CancelFlag, newerOnly: Bool = false) -> [SyncAction] {
        guard !cancel.isCancelled else { return [] }
        let sourceItems = listing(source)
        let targetItems = listing(target)
        let targetByName = Dictionary(targetItems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var actions: [SyncAction] = []

        for item in sourceItems {
            let relative = prefix + item.name
            guard let existing = targetByName[item.name] else {
                actions.append(SyncAction(kind: .add, item: item.url, destination: target, relativePath: relative))
                continue
            }
            if item.isNavigable && existing.isNavigable {
                if options.recursive {
                    actions += plan(source: item.url, target: existing.url, options: options,
                                    prefix: relative + "/", cancel: cancel, newerOnly: newerOnly)
                }
                continue
            }
            if needsUpdate(item, existing, options: options, newerOnly: newerOnly) {
                actions.append(SyncAction(kind: .update, item: item.url, destination: target, relativePath: relative))
            }
        }

        if options.deleteExtras {
            let sourceNames = Set(sourceItems.map(\.name))
            for extra in targetItems where !sourceNames.contains(extra.name) {
                actions.append(SyncAction(kind: .delete, item: extra.url, destination: target, relativePath: prefix + extra.name))
            }
        }
        return actions
    }

    private static func needsUpdate(_ source: FileItem, _ target: FileItem, options: SyncOptions, newerOnly: Bool) -> Bool {
        if source.isNavigable != target.isNavigable { return !newerOnly }
        let ts = source.modified ?? .distantPast, tt = target.modified ?? .distantPast
        if ts.timeIntervalSince(tt) > FolderCompare.tolerance { return true }
        if newerOnly { return false }
        // Never replace a newer file in the target with an older one.
        if tt.timeIntervalSince(ts) > FolderCompare.tolerance { return false }
        if source.size != target.size { return true }
        return options.compareContents && sha256(source.url) != sha256(target.url)
    }

    private static func listing(_ url: URL) -> [FileItem] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys)) ?? [])
            .map(FileItem.init(url:))
            .filter { !ignored.contains($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
