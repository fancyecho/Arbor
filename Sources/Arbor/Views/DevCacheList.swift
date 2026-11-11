import AppKit
import SwiftUI

/// "开发缓存" in the space view: every node_modules, build folder and package cache under the scanned
/// folder, with how long its project has been idle. Tick them and move them to the Trash in one go.
struct DevCacheList: View {
    let workspace: WorkspaceState
    let scan: SpaceScan
    let node: SpaceNode

    @Environment(\.arborTint) private var tint
    @State private var items: [DevCacheItem]?
    @State private var picked: Set<URL> = []
    @State private var hovered: URL?
    @State private var expanded: Set<URL> = []
    @State private var trashing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let items {
                if items.isEmpty {
                    empty
                } else {
                    summary(items)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            let largest = items.first?.size ?? 1
                            ForEach(groups(items)) { group in groupView(group, largest: largest) }
                        }
                        .padding(.bottom, 8)
                        .slimScrollers(tint)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("正在查找开发缓存…")).foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(ObjectIdentifier(node).hashValue)|\(scan.revision)|\(scan.isScanning)") { await find() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(tint)
            Text(scan.isScanning ? L("扫描完成后再看看") : L("这里没有可清理的开发缓存"))
                .font(.callout)
            Text(L("会找 node_modules、构建目录、Xcode DerivedData、Pods、Python 虚拟环境和包管理器缓存。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ items: [DevCacheItem]) -> some View {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let chosen = items.filter { picked.contains($0.url) }
        let chosenBytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        let stale = items.filter(\.isStale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(total))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(L("可以重新生成，\(items.count) 处"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !chosen.isEmpty {
                    Text(L("已选 \(Format.bytes(chosenBytes))"))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            // How much of it belongs to projects nobody has touched in a month.
            GeometryReader { proxy in
                let staleBytes = stale.reduce(Int64(0)) { $0 + $1.size }
                HStack(spacing: 1.5) {
                    Capsule().fill(Color.orange.gradient)
                        .frame(width: proxy.size.width * Double(staleBytes) / Double(max(total, 1)))
                    Capsule().fill(tint.opacity(0.55))
                }
            }
            .frame(height: 6)
            HStack(spacing: 8) {
                Button(L("选中闲置 30 天的")) {
                    withAnimation(.snappy) { picked = Set(stale.map(\.url)) }
                }
                .disabled(stale.isEmpty)
                Button(picked.isEmpty ? L("全选") : L("取消选择")) {
                    withAnimation(.snappy) { picked = picked.isEmpty ? Set(items.map(\.url)) : [] }
                }
                Spacer(minLength: 4)
                Button {
                    trash(chosen)
                } label: {
                    Label(L("移到废纸篓"), systemImage: "trash").lineLimit(1)
                }
                .buttonStyle(.glassProminent)
                .fixedSize()
                .disabled(chosen.isEmpty || trashing)
            }
            .buttonStyle(.glassCompact)
            .font(.system(size: 11))
            .lineLimit(1)
        }
    }

    // MARK: Groups

    /// Caches grouped by the project they belong to (or, for shared caches, by what they are).
    private struct Group: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let items: [DevCacheItem]
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
        var lastActivity: Date? { items.compactMap(\.lastActivity).max() }
        var isStale: Bool { items.allSatisfy(\.isStale) }
    }

    private func groups(_ items: [DevCacheItem]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [DevCacheItem]] = [:]
        for item in items {
            let key = item.rule.belongsToProject ? item.url.deletingLastPathComponent().path : "rule:" + item.rule.rawValue
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { key in
            let members = byKey[key] ?? []
            let first = members[0]
            if first.rule.belongsToProject {
                let project = first.url.deletingLastPathComponent()
                return Group(id: key, title: project.lastPathComponent,
                             subtitle: (project.path as NSString).abbreviatingWithTildeInPath, symbol: "folder.fill", items: members)
            }
            let parent = first.url.deletingLastPathComponent()
            return Group(id: key, title: first.rule.title,
                         subtitle: (parent.path as NSString).abbreviatingWithTildeInPath, symbol: first.rule.symbol, items: members)
        }
        .sorted { $0.size > $1.size }
    }

    @ViewBuilder
    private func groupView(_ group: Group, largest: Int64) -> some View {
        let urls = Set(group.items.map(\.url))
        let all = urls.isSubset(of: picked)
        let some = !urls.isDisjoint(with: picked)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { if all { picked.subtract(urls) } else { picked.formUnion(urls) } }
                } label: {
                    Image(systemName: all ? "checkmark.circle.fill" : some ? "minus.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(some ? tint : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                Image(systemName: group.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(tint.opacity(0.85))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if group.items.first?.rule.belongsToProject == true {
                            Text(groupAge(group))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(group.isStale ? Color.orange : Color.secondary)
                        }
                    }
                    Text(group.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                Text(Format.bytes(group.size))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(Rectangle())
            .contextMenu {
                if group.items.first?.rule.belongsToProject == true {
                    Button(L("在新标签页中打开项目"), systemImage: "plus.square.on.square") {
                        workspace.openInNewTab(group.items[0].url.deletingLastPathComponent())
                    }
                }
                Button(L("移到废纸篓"), systemImage: "trash") { trash(group.items) }
            }
            ForEach(group.items) { item in cacheRow(item, largest: largest) }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
    }

    /// One cache folder: its exact name, what kind it is, and (expanded) what's inside it.
    private func cacheRow(_ item: DevCacheItem, largest: Int64) -> some View {
        let isPicked = picked.contains(item.url)
        let isOpen = expanded.contains(item.url)
        let color = item.rule.color
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isPicked ? tint : Color.secondary.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
                // The kind, in its own color: easy to tell node_modules from build output at a glance.
                Image(systemName: item.rule.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cacheLabel(item))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.rule.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(color.opacity(0.16)))
                            .foregroundStyle(color)
                            .fixedSize()
                    }
                    Text(item.rule.belongsToProject ? item.rule.regenerate : age(item))
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.isStale && !item.rule.belongsToProject ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Format.bytes(item.size))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Capsule().fill(Color.primary.opacity(0.07))
                        .frame(width: 54, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(color)
                                .frame(width: max(3, 54 * Double(item.size) / Double(max(largest, 1))), height: 4)
                        }
                }
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        if isOpen { expanded.remove(item.url) } else { expanded.insert(item.url) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L("看看里面是什么"))
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(isPicked ? 0.12 : hovered == item.url ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { inside in hovered = inside ? item.url : (hovered == item.url ? nil : hovered) }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    if isPicked { picked.remove(item.url) } else { picked.insert(item.url) }
                }
            }
            .help((item.url.path as NSString).abbreviatingWithTildeInPath + "\n" + item.rule.regenerate)
            .contextMenu {
                Button(L("在新标签页中打开"), systemImage: "plus.square.on.square") { workspace.openInNewTab(item.url) }
                Button(L("在访达中显示"), systemImage: "macwindow") { FileOperations.revealInFinder([item.url]) }
                Button(L("拷贝路径"), systemImage: "link") { workspace.copyPath([item.url]) }
                Divider()
                Button(L("移到废纸篓"), systemImage: "trash") { trash([item]) }
            }
            if isOpen { contents(of: item).transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    /// The biggest things inside a cache, from the scan.
    private func contents(of item: DevCacheItem) -> some View {
        let children = scan.node(for: item.url)?.children.prefix(8) ?? []
        return VStack(alignment: .leading, spacing: 1) {
            if children.isEmpty {
                Text(L("扫描结果里没有它的内容")).foregroundStyle(.tertiary)
            }
            ForEach(Array(children), id: \.id) { child in
                HStack(spacing: 6) {
                    Image(systemName: child.isContainer ? "folder" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(child.kind == .smallFiles ? L("更小的文件") : child.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Format.bytes(child.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(height: 18)
            }
            if let count = scan.node(for: item.url)?.fileCount {
                Text(L("共 \(count.formatted()) 个文件")).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
        .font(.system(size: 11))
        .padding(.leading, 74)
        .padding(.trailing, 34)
        .padding(.vertical, 6)
    }

    /// "node_modules", or "web/.next" for caches deeper inside the project.
    private func cacheLabel(_ item: DevCacheItem) -> String {
        item.rule.belongsToProject ? item.url.lastPathComponent : item.name
    }

    private func groupAge(_ group: Group) -> String {
        guard let date = group.lastActivity else { return "" }
        return Self.ageText(date)
    }

    private func age(_ item: DevCacheItem) -> String {
        guard let date = item.lastActivity else { return L("不知道上次使用时间") }
        return Self.ageText(date)
    }

    static func ageText(_ date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return L("今天动过")
        case ..<30: return L("\(days) 天前动过")
        case ..<365: return L("\(days / 30) 个月没动")
        default: return L("\(days / 365) 年没动")
        }
    }

    private func find() async {
        let candidates = DevCacheFinder.candidates(in: node, scan: scan)
        let found = await Task.detached(priority: .userInitiated) { DevCacheFinder.resolve(candidates) }.value
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            items = found
            picked.formIntersection(found.map(\.url))
        }
    }

    private func trash(_ chosen: [DevCacheItem]) {
        guard !chosen.isEmpty else { return }
        trashing = true
        let urls = chosen.map(\.url)
        FileOperationQueue.shared.trash(urls) { error in
            trashing = false
            if let error { workspace.alertMessage = error.localizedDescription }
            withAnimation(.snappy) {
                items?.removeAll { urls.contains($0.url) }
                picked.subtract(urls)
            }
        }
    }
}

extension DevCacheRule {
    /// Each kind of cache has its own color in the list.
    var color: Color {
        switch self {
        case .nodeModules: .green
        case .swiftBuild: .orange
        case .derivedData: .blue
        case .pods: .red
        case .cargoTarget: .brown
        case .mavenTarget, .gradleBuild, .gradleProject: .teal
        case .cmakeBuild: .gray
        case .webBuildCache: .purple
        case .pythonVenv: .yellow
        case .deviceSupport: .indigo
        case .simulatorCaches: .cyan
        case .packageCache: .mint
        }
    }
}
