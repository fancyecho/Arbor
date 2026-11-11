import Foundation

/// Folders that developer tools rebuild on their own (dependencies, build output, package caches):
/// safe to throw away, and often the biggest thing in a projects folder.
enum DevCacheRule: String, CaseIterable, Sendable {
    case nodeModules, swiftBuild, derivedData, pods, cargoTarget, mavenTarget, gradleBuild, gradleProject, cmakeBuild
    case webBuildCache, pythonVenv, deviceSupport, simulatorCaches, packageCache

    var title: String {
        switch self {
        case .nodeModules: L("Node 依赖")
        case .swiftBuild: L("SwiftPM 构建")
        case .derivedData: L("Xcode 构建")
        case .pods: L("CocoaPods")
        case .cargoTarget: L("Rust 构建")
        case .mavenTarget: L("Maven 构建")
        case .gradleBuild, .gradleProject: L("Gradle 构建")
        case .cmakeBuild: L("CMake 构建")
        case .webBuildCache: L("前端构建缓存")
        case .pythonVenv: L("Python 虚拟环境")
        case .deviceSupport: L("设备调试符号")
        case .simulatorCaches: L("模拟器缓存")
        case .packageCache: L("包管理器缓存")
        }
    }

    var symbol: String {
        switch self {
        case .nodeModules, .webBuildCache: "shippingbox"
        case .swiftBuild, .derivedData: "hammer"
        case .pods: "cube.box"
        case .cargoTarget, .mavenTarget, .gradleBuild, .gradleProject, .cmakeBuild: "gearshape.2"
        case .pythonVenv: "chevron.left.forwardslash.chevron.right"
        case .deviceSupport: "iphone"
        case .simulatorCaches: "ipad.and.iphone"
        case .packageCache: "archivebox"
        }
    }

    /// How to get it back, for the tooltip.
    var regenerate: String {
        switch self {
        case .nodeModules: L("用 npm / pnpm / yarn install 重新安装")
        case .swiftBuild, .derivedData, .cargoTarget, .mavenTarget, .gradleBuild, .gradleProject, .cmakeBuild:
            L("下次构建时自动重新生成")
        case .pods: L("用 pod install 重新安装")
        case .webBuildCache: L("下次构建或启动开发服务器时重新生成")
        case .pythonVenv: L("需要重新创建虚拟环境并安装依赖")
        case .deviceSupport: L("连接设备调试时 Xcode 会重新下载")
        case .simulatorCaches: L("模拟器会按需重新生成")
        case .packageCache: L("需要时会重新下载")
        }
    }

    /// Projects of these kinds are judged by when their own files last changed.
    var belongsToProject: Bool {
        switch self {
        case .deviceSupport, .simulatorCaches, .packageCache: false
        case .derivedData: false
        default: true
        }
    }
}

struct DevCacheItem: Identifiable, Sendable, Equatable {
    let url: URL
    let rule: DevCacheRule
    let size: Int64
    /// The project it belongs to ("Arbor"), or what it is ("iOS 18.2").
    let name: String
    /// When the project (or the cache itself) was last worked on.
    var lastActivity: Date?

    var id: URL { url }

    var isStale: Bool { (lastActivity.map { Date().timeIntervalSince($0) } ?? .infinity) > 30 * 86_400 }
}

enum DevCacheFinder {
    /// Folders a project's cache sits next to, by cache name. Checked on disk because a scan folds small
    /// files (like package.json) into one "smaller files" entry.
    private static let markers: [String: [(rule: DevCacheRule, files: [String])]] = [
        "node_modules": [(.nodeModules, ["package.json"])],
        ".build": [(.swiftBuild, ["Package.swift"])],
        "Pods": [(.pods, ["Podfile", "Podfile.lock"])],
        "target": [(.cargoTarget, ["Cargo.toml"]), (.mavenTarget, ["pom.xml"])],
        "build": [(.gradleBuild, ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
                  (.cmakeBuild, ["CMakeLists.txt"])],
        ".gradle": [(.gradleProject, ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"])],
        ".next": [(.webBuildCache, ["package.json"])],
        ".nuxt": [(.webBuildCache, ["package.json"])],
        ".svelte-kit": [(.webBuildCache, ["package.json"])],
        ".turbo": [(.webBuildCache, ["package.json"])],
        ".parcel-cache": [(.webBuildCache, ["package.json"])],
        ".angular": [(.webBuildCache, ["package.json"])],
        "DerivedData": [(.derivedData, [])],
        ".venv": [(.pythonVenv, [])],
        "venv": [(.pythonVenv, [])],
    ]

    /// Folders under ~/Library and the home folder whose children are each one cache.
    private static let containers: [String: DevCacheRule] = [
        "Library/Developer/Xcode/DerivedData": .derivedData,
        "Library/Developer/Xcode/iOS DeviceSupport": .deviceSupport,
        "Library/Developer/Xcode/watchOS DeviceSupport": .deviceSupport,
        "Library/Developer/Xcode/visionOS DeviceSupport": .deviceSupport,
        "Library/Developer/Xcode/tvOS DeviceSupport": .deviceSupport,
    ]

    /// Single folders under the home folder that are package or simulator caches.
    private static let fixed: [String: DevCacheRule] = [
        "Library/Developer/CoreSimulator/Caches": .simulatorCaches,
        "Library/Caches/Homebrew": .packageCache,
        "Library/Caches/pip": .packageCache,
        "Library/Caches/Yarn": .packageCache,
        "Library/Caches/pnpm": .packageCache,
        "Library/Caches/CocoaPods": .packageCache,
        "Library/Caches/go-build": .packageCache,
        "Library/Caches/org.swift.swiftpm": .packageCache,
        ".npm/_cacache": .packageCache,
        ".gradle/caches": .packageCache,
        ".cargo/registry": .packageCache,
        ".m2/repository": .packageCache,
        ".cache/pip": .packageCache,
        "Library/pnpm/store": .packageCache,
    ]

    static let minimumSize: Int64 = 1_000_000

    /// Candidates in a scanned tree (main thread: the tree is only touched there). Doesn't look inside
    /// a cache once found, so node_modules inside node_modules count once.
    @MainActor
    static func candidates(in node: SpaceNode, scan: SpaceScan) -> [(url: URL, size: Int64, names: [String])] {
        var found: [(URL, Int64, [String])] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        func visit(_ node: SpaceNode, depth: Int) {
            for child in node.children where child.isBrowsable && child.size >= minimumSize {
                let url = scan.url(of: child)
                let path = url.standardizedFileURL.path
                let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
                if let rel, containers[rel] != nil {
                    for item in child.children where item.isItem && item.size >= minimumSize {
                        found.append((scan.url(of: item), item.size, [rel]))
                    }
                    continue
                }
                if let rel, fixed[rel] != nil {
                    found.append((url, child.size, [rel]))
                    continue
                }
                if markers[child.name] != nil {
                    found.append((url, child.size, [child.name]))
                    continue
                }
                if child.name == ".git" || child.name == ".Trash" || depth > 40 { continue }
                visit(child, depth: depth + 1)
            }
        }
        visit(node, depth: 0)
        return found
    }

    /// Checks each candidate on disk (marker files, dates) and turns it into an item. Off the main thread.
    static func resolve(_ candidates: [(url: URL, size: Int64, names: [String])]) -> [DevCacheItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var items: [DevCacheItem] = []
        for candidate in candidates {
            let url = candidate.url
            let parent = url.deletingLastPathComponent()
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : ""
            let parentRel = (rel as NSString).deletingLastPathComponent
            if let rule = containers[parentRel] {
                let name = rule == .derivedData ? projectName(fromDerivedData: url.lastPathComponent) : url.lastPathComponent
                items.append(DevCacheItem(url: url, rule: rule, size: candidate.size, name: name,
                                          lastActivity: modified(url)))
                continue
            }
            if let rule = fixed[rel] {
                items.append(DevCacheItem(url: url, rule: rule, size: candidate.size, name: label(forFixed: rel),
                                          lastActivity: modified(url)))
                continue
            }
            guard let options = markers[url.lastPathComponent] else { continue }
            var matched: DevCacheRule?
            for option in options {
                if option.files.isEmpty || option.files.contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                    matched = option.rule
                    break
                }
            }
            if url.lastPathComponent == ".venv" || url.lastPathComponent == "venv" {
                matched = fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) ? .pythonVenv : nil
            }
            guard let rule = matched else { continue }
            items.append(DevCacheItem(url: url, rule: rule, size: candidate.size, name: parent.lastPathComponent,
                                      lastActivity: rule.belongsToProject ? projectActivity(parent, excluding: url.lastPathComponent)
                                                                          : modified(url)))
        }
        return items.sorted { $0.size > $1.size }
    }

    /// "Arbor-abcdefghijklmn" → "Arbor".
    static func projectName(fromDerivedData name: String) -> String {
        guard let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 10 else { return name }
        return String(name[..<dash])
    }

    private static func label(forFixed rel: String) -> String {
        switch rel {
        case "Library/Developer/CoreSimulator/Caches": L("iOS 模拟器")
        case ".npm/_cacache": "npm"
        case ".gradle/caches": "Gradle"
        case ".cargo/registry": "Cargo"
        case ".m2/repository": "Maven"
        case ".cache/pip", "Library/Caches/pip": "pip"
        case "Library/pnpm/store", "Library/Caches/pnpm": "pnpm"
        case "Library/Caches/org.swift.swiftpm": "SwiftPM"
        case "Library/Caches/go-build": "Go"
        default: (rel as NSString).lastPathComponent
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// When the project's own files last changed (its top level, not counting the cache or .git).
    private static func projectActivity(_ project: URL, excluding cache: String) -> Date? {
        let skip: Set<String> = [cache, ".git", ".DS_Store", "node_modules", ".build", "build", "target", "Pods", ".next"]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        return children.filter { !skip.contains($0.lastPathComponent) }
            .compactMap(modified).max() ?? modified(project)
    }
}
