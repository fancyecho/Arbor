import AppKit
import SwiftUI

/// "时间线" view mode (⌘5): what happened under this folder lately — downloads (with the site they came
/// from), screenshots, files opened or changed — by day instead of by folder.
struct ActivityTimelineView: View {
    let workspace: WorkspaceState
    let pane: PaneState
    let tab: TabState
    let isActive: Bool

    @Environment(\.arborTint) private var tint
    @State private var model = TimelineModel()
    @AppStorage("timelineRange", store: AppDefaults.store) private var range: TimelineRange = .week
    @AppStorage("timelineFilter", store: AppDefaults.store) private var filter: TimelineFilter = .all
    @AppStorage("timelineWholeHome", store: AppDefaults.store) private var wholeHome = false
    @State private var hovered: URL?

    private var scope: URL {
        wholeHome ? FileManager.default.homeDirectoryForCurrentUser : tab.url
    }

    var body: some View {
        let shown = visibleEntries
        VStack(spacing: 0) {
            header(shown)
                .animation(.smooth(duration: 0.3), value: filter)
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).padding(.horizontal, 14)
            if model.isLoading && model.entries.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                empty
            } else {
                list(TimelineModel.days(shown))
                    // Switching filter or range swaps the list with a short cross-fade instead of a jump.
                    .id("\(filter.rawValue)|\(range.rawValue)|\(wholeHome)")
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.smooth(duration: 0.3), value: "\(filter.rawValue)|\(range.rawValue)|\(wholeHome)")
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            workspace.quickLook()
            return .handled
        }
        .onKeyPress(.return) {
            if let url = tab.selection.first { NSWorkspace.shared.open(url) }
            return .handled
        }
        .onKeyPress(.downArrow) { step(1, in: shown); return .handled }
        .onKeyPress(.upArrow) { step(-1, in: shown); return .handled }
        .task(id: "\(scope.path)|\(range.rawValue)") { model.start(scope: scope, range: range) }
        .onDisappear { model.stop() }
    }

    /// Entries after the type filter and the toolbar's filter text.
    private var visibleEntries: [TimelineEntry] {
        let needle = tab.filter.trimmingCharacters(in: .whitespaces)
        let showHidden = AppSettings.shared.showHidden
        return model.entries.filter { entry in
            filter.matches(entry) && (showHidden || !entry.item.isHidden)
                && (needle.isEmpty || NameMatcher.matches(entry.item.name, needle))
        }
    }

    // MARK: Header

    private func header(_ shown: [TimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary(shown)).font(.system(size: 13, weight: .semibold))
                    Text(wholeHome ? L("整个主目录") : L("“\(tab.title)”及其子文件夹"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ActivityBars(entries: model.entries, days: range.rawValue)
                    .frame(width: range == .today ? 120 : 150, height: 30)
                GlassSegmented(selection: $range, options: TimelineRange.allCases.map {
                    .init(value: $0, title: $0.title)
                }, compact: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TimelineFilter.allCases) { option in chip(option) }
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    Button {
                        withAnimation(.snappy) { wholeHome.toggle() }
                    } label: {
                        Label(L("整个主目录"), systemImage: wholeHome ? "house.fill" : "house")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(wholeHome ? tint.opacity(0.18) : Color.primary.opacity(0.05)))
                            .foregroundStyle(wholeHome ? tint : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("显示主目录里所有最近的文件，而不只是这个文件夹"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func chip(_ option: TimelineFilter) -> some View {
        let selected = filter == option
        let count = option == .all ? model.entries.count : model.entries.filter(option.matches).count
        return Button {
            withAnimation(.snappy(duration: 0.25)) { filter = option }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: option.symbol).font(.system(size: 10))
                Text(option.title)
                if count > 0 {
                    Text("\(count)").foregroundStyle(selected ? tint.opacity(0.8) : Color.secondary.opacity(0.7))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(selected ? tint.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.35) : .clear, lineWidth: 0.5))
            .foregroundStyle(selected ? tint : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func summary(_ shown: [TimelineEntry]) -> String {
        let downloads = shown.filter { $0.event == .downloaded }.count
        var text = L("\(range == .today ? L("今天") : L("最近 \(range.rawValue) 天")) · \(shown.count) 个文件")
        if downloads > 0 { text += L(" · \(downloads) 个下载") }
        if model.truncated { text += L("（只显示最近的部分）") }
        return text
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(tint.opacity(0.8))
            Text(L("这段时间没有动静")).font(.callout)
            Text(wholeHome ? L("Spotlight 没找到最近的文件。") : L("试试“整个主目录”，或者把时间放宽一些。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private func list(_ days: [TimelineDay]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                                switch row {
                                case .entry(let entry):
                                    entryRow(entry, isLast: index == day.rows.count - 1)
                                case .strip(let entries):
                                    strip(entries, isLast: index == day.rows.count - 1)
                                }
                            }
                        } header: {
                            dayHeader(day)
                        }
                    }
                }
                .padding(.bottom, 12)
                .slimScrollers(tint)
            }
            .onChange(of: tab.selection) { _, selection in
                guard let url = selection.first, selection.count == 1 else { return }
                withAnimation(.snappy) { proxy.scrollTo(url.path) }
            }
        }
    }

    private func dayHeader(_ day: TimelineDay) -> some View {
        HStack(spacing: 8) {
            Text(day.title).font(.system(size: 12, weight: .semibold))
            Text(L("\(day.count) 个文件")).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar.opacity(0.92))
    }

    /// The rail on the left: a dot for the event, joined to the next row by a line.
    private func rail(_ event: TimelineEvent, isLast: Bool) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .padding(.bottom, isLast ? 22 : 0)
            Image(systemName: event.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white, color(for: event))
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                .padding(.top, 13)
        }
        .frame(width: 20)
    }

    private func color(for event: TimelineEvent) -> Color {
        switch event {
        case .downloaded: .green
        case .screenshot: .purple
        case .opened: .blue
        case .modified: tint
        case .added: .teal
        }
    }

    private func entryRow(_ entry: TimelineEntry, isLast: Bool) -> some View {
        let selected = tab.selection.contains(entry.item.url)
        return HStack(alignment: .top, spacing: 10) {
            Text(Self.clock.string(from: entry.date))
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 15)
            rail(entry.event, isLast: isLast)
            HStack(spacing: 10) {
                ThumbnailView(item: entry.item, size: 34)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(eventText(entry)).foregroundStyle(color(for: entry.event))
                        Text("·").foregroundStyle(.quaternary)
                        Text(folderText(entry.item.url))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10.5))
                }
                Spacer(minLength: 4)
                if let size = entry.item.size {
                    Text(Format.bytes(size))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? tint.opacity(0.16) : hovered == entry.item.url ? Color.primary.opacity(0.05) : .clear))
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .id(entry.item.url.path)
        .onHover { inside in hovered = inside ? entry.item.url : (hovered == entry.item.url ? nil : hovered) }
        .gesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(entry.item.url) })
        .simultaneousGesture(TapGesture().onEnded { select(entry.item.url) })
        .contextMenu { menu(entry) }
        .draggable(entry.item.url) {
            Label(entry.item.name, systemImage: "doc")
        }
    }

    /// Three or more pictures in a row: one line of thumbnails.
    private func strip(_ entries: [TimelineEntry], isLast: Bool) -> some View {
        let screenshots = entries.allSatisfy(\.isScreenshot)
        return HStack(alignment: .top, spacing: 10) {
            Text(Self.clock.string(from: entries[0].date))
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 15)
            rail(screenshots ? .screenshot : entries[0].event, isLast: isLast)
            VStack(alignment: .leading, spacing: 6) {
                Text(screenshots ? L("\(entries.count) 张截图") : L("\(entries.count) 张图片"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entries) { entry in
                            let selected = tab.selection.contains(entry.item.url)
                            ThumbnailView(item: entry.item, size: 72)
                                .frame(width: 72, height: 56)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? tint.opacity(0.2) : Color.primary.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? tint : .clear, lineWidth: 1.5))
                                .id(entry.item.url.path)
                                .help("\(entry.item.name)\n\(Self.clock.string(from: entry.date))")
                                .gesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(entry.item.url) })
                                .simultaneousGesture(TapGesture().onEnded { select(entry.item.url) })
                                .contextMenu { menu(entry) }
                                .draggable(entry.item.url) { Label(entry.item.name, systemImage: "photo") }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func menu(_ entry: TimelineEntry) -> some View {
        let url = entry.item.url
        Button(L("打开"), systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        Button(L("快速查看"), systemImage: "eye") { select(url); workspace.quickLook([url]) }
        Button(L("在所在文件夹中显示"), systemImage: "folder") {
            tab.viewMode = .list
            tab.navigate(to: url.deletingLastPathComponent(), select: url)
            workspace.focusToken += 1
        }
        Button(L("在新标签页中打开所在文件夹"), systemImage: "plus.square.on.square") {
            workspace.openInNewTab(url.deletingLastPathComponent())
        }
        Divider()
        Button(L("拷贝路径"), systemImage: "link") { workspace.copyPath([url]) }
        Button(L("加入暂存架"), systemImage: "tray.and.arrow.down") { StashShelf.shared.add([url]) }
        Divider()
        Button(L("移到废纸篓"), systemImage: "trash") { workspace.moveToTrash([url]) }
    }

    private func eventText(_ entry: TimelineEntry) -> String {
        if entry.event == .downloaded, let source = entry.source { return L("下载自 \(source)") }
        return entry.event.title
    }

    private func folderText(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        let base = scope.standardizedFileURL.path
        if folder == base { return L("此文件夹") }
        if folder.hasPrefix(base + "/") { return String(folder.dropFirst(base.count + 1)) }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private func select(_ url: URL) {
        workspace.activate(pane)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if tab.selection.contains(url) { tab.selection.remove(url) } else { tab.selection.insert(url) }
        } else {
            tab.selection = [url]
        }
    }

    private func step(_ delta: Int, in shown: [TimelineEntry]) {
        guard !shown.isEmpty else { return }
        let current = tab.selection.first.flatMap { url in shown.firstIndex { $0.item.url == url } }
        let next = current.map { min(max($0 + delta, 0), shown.count - 1) } ?? 0
        tab.selection = [shown[next].item.url]
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Files per day (or per hour, for today) as small bars; the latest is on the right.
private struct ActivityBars: View {
    let entries: [TimelineEntry]
    let days: Int

    @Environment(\.arborTint) private var tint

    var body: some View {
        let buckets = counts()
        let peak = max(buckets.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: days == 30 ? 1.5 : 3) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { index, count in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == buckets.count - 1 ? tint : tint.opacity(0.45))
                    .frame(height: max(2, 30 * CGFloat(count) / CGFloat(peak)))
            }
        }
        .animation(.snappy, value: buckets)
        .help(days == 1 ? L("今天每小时的文件数") : L("每天的文件数"))
    }

    private func counts() -> [Int] {
        let calendar = Calendar.current
        if days == 1 {
            var hours = [Int](repeating: 0, count: 24)
            for entry in entries where calendar.isDateInToday(entry.date) {
                hours[calendar.component(.hour, from: entry.date)] += 1
            }
            let now = calendar.component(.hour, from: Date())
            return Array(hours.prefix(now + 1).suffix(max(now + 1, 8)))
        }
        let today = calendar.startOfDay(for: Date())
        var result = [Int](repeating: 0, count: days)
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, ago >= 0, ago < days else { continue }
            result[days - 1 - ago] += 1
        }
        return result
    }
}
