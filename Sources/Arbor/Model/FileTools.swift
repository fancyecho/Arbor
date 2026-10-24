import AppKit
import CryptoKit

/// New-file templates live in a normal folder so users can drop in their own (.docx, .key, …).
enum Templates {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Arbor/Templates", isDirectory: true)
    }

    private static let defaults: [(String, String)] = [
        (L("文本文件.txt"), ""),
        ("Markdown.md", L("# 标题\n\n")),
        ("Python.py", "#!/usr/bin/env python3\n\n\ndef main():\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n"),
        ("Shell.sh", "#!/bin/zsh\nset -euo pipefail\n\n"),
        ("HTML.html", "<!doctype html>\n<html lang=\"zh\">\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n\n</body>\n</html>\n"),
        ("JSON.json", "{\n}\n"),
    ]

    /// Creates the folder with starter templates the first time.
    static func ensureFolder() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in defaults {
            try? body.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static var all: [URL] {
        ensureFolder()
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies a template into `directory` under a free name; returns the new file.
    static func instantiate(_ template: URL, in directory: URL) throws -> URL {
        let ext = template.pathExtension
        let name = ext.isEmpty ? L("未命名") : L("未命名.\(ext)")
        let target = FileOperations.uniqueURL(for: name, in: directory)
        try FileManager.default.copyItem(at: template, to: target)
        return target
    }
}

enum FileTools {
    private static var fm: FileManager { .default }

    /// Moves `items` into a new folder next to them. Returns the folder and undo steps.
    static func newFolder(with items: [URL], in directory: URL) throws -> (URL, [UndoStep]) {
        let folder = FileOperations.uniqueURL(for: L("带项目的新文件夹"), in: directory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var undo: [UndoStep] = [.trash(folder)]
        for item in items {
            let target = FileOperations.uniqueURL(for: item.lastPathComponent, in: folder)
            try fm.moveItem(at: item, to: target)
            undo.insert(.move(from: target, to: item), at: 0)
        }
        return (folder, undo)
    }

    /// Pulls every file out of `folder`'s subfolders into `folder` itself, then removes the emptied subfolders.
    static func flatten(_ folder: URL, discardEmpty: (URL) throws -> UndoStep? = trashFolder) throws -> (moved: Int, undo: [UndoStep]) {
        var undo: [UndoStep] = []
        var moved = 0
        let subfolders = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { TabState.resolvedDirectory($0) != nil && !$0.lastPathComponent.hasPrefix(".") }
        for sub in subfolders {
            let enumerator = fm.enumerator(at: sub, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                           options: [.skipsPackageDescendants])
            var files: [URL] = []
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
                if values?.isRegularFile == true || values?.isSymbolicLink == true || values?.isPackage == true,
                   url.lastPathComponent != ".DS_Store" {
                    files.append(url)
                }
            }
            for file in files {
                let target = FileOperations.uniqueURL(for: file.lastPathComponent, in: folder)
                try fm.moveItem(at: file, to: target)
                undo.insert(.move(from: target, to: file), at: 0)
                moved += 1
            }
            // Only trash the subfolder if nothing but empty folders / .DS_Store remain.
            if isEffectivelyEmpty(sub), let step = try discardEmpty(sub) {
                undo.insert(step, at: 0)
            }
        }
        return (moved, undo)
    }

    struct FlattenPreview {
        let subfolders: [String]
        let fileCount: Int
        /// Looks like source code (Package.swift, .git, package.json, *.xcodeproj…): flattening would break it.
        let looksLikeProject: Bool
    }

    static func flattenPreview(_ folder: URL) -> FlattenPreview {
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let markers: Set<String> = [".git", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
                                    "Makefile", "CMakeLists.txt", "pom.xml", "build.gradle", "Podfile", ".gitignore"]
        let looksLikeProject = children.contains { markers.contains($0.lastPathComponent) || $0.pathExtension == "xcodeproj" }
        let subfolders = children.filter { TabState.resolvedDirectory($0) != nil && !$0.lastPathComponent.hasPrefix(".") }
        var count = 0
        for sub in subfolders {
            let enumerator = fm.enumerator(at: sub, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL, count < 100_000 {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, url.lastPathComponent != ".DS_Store" {
                    count += 1
                }
            }
        }
        return FlattenPreview(subfolders: subfolders.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, fileCount: count, looksLikeProject: looksLikeProject)
    }

    /// Default for emptied subfolders: Trash, so undo restores them exactly.
    static func trashFolder(_ url: URL) throws -> UndoStep? {
        var trashed: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?).map { .move(from: $0, to: url) }
    }

    private static func isEffectivelyEmpty(_ folder: URL) -> Bool {
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { return false }
        }
        return true
    }

    static func makeSymlink(to item: URL) throws -> URL {
        let link = FileOperations.uniqueURL(for: item.lastPathComponent + L(" 链接"), in: item.deletingLastPathComponent())
        try fm.createSymbolicLink(at: link, withDestinationURL: item)
        return link
    }

    /// Finder alias (bookmark file): survives the original being moved, unlike a symlink.
    static func makeAlias(to item: URL) throws -> URL {
        let alias = FileOperations.uniqueURL(for: item.lastPathComponent + L(" 替身"), in: item.deletingLastPathComponent())
        let data = try item.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        return alias
    }

    /// MD5 / SHA-1 / SHA-256 of each regular file.
    static func hashes(_ urls: [URL]) -> String {
        urls.map { url -> String in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: url) else {
                return L("\(url.lastPathComponent)\n  （不是文件，已跳过）")
            }
            defer { try? handle.close() }
            var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                md5.update(data: chunk)
                sha1.update(data: chunk)
                sha256.update(data: chunk)
            }
            func hex<D: Digest>(_ digest: D) -> String { digest.map { String(format: "%02x", $0) }.joined() }
            return """
            \(url.lastPathComponent)
              MD5      \(hex(md5.finalize()))
              SHA-1    \(hex(sha1.finalize()))
              SHA-256  \(hex(sha256.finalize()))
            """
        }.joined(separator: "\n\n")
    }

    /// A `tree`-style outline of `root`. Hidden files are skipped; depth and size are capped.
    static func tree(of root: URL, maxDepth: Int = 8, limit: Int = 5000) -> String {
        var lines = [root.lastPathComponent + "/"]
        var count = 0, folders = 0, files = 0
        func walk(_ url: URL, prefix: String, depth: Int) {
            guard depth < maxDepth, count < limit else { return }
            let children = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for (index, child) in children.enumerated() {
                guard count < limit else {
                    lines.append(prefix + "└── …")
                    return
                }
                count += 1
                let last = index == children.count - 1
                let isFolder = TabState.resolvedDirectory(child) != nil
                lines.append(prefix + (last ? "└── " : "├── ") + child.lastPathComponent + (isFolder ? "/" : ""))
                if isFolder {
                    folders += 1
                    walk(child, prefix: prefix + (last ? "    " : "│   "), depth: depth + 1)
                } else {
                    files += 1
                }
            }
        }
        walk(root, prefix: "", depth: 0)
        lines.append("")
        lines.append(L("\(folders) 个文件夹，\(files) 个文件") + (count >= limit ? L("（已截断）") : ""))
        return lines.joined(separator: "\n")
    }
}
