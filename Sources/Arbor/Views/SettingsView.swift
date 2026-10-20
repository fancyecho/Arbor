import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            AppsSettings().tabItem { Label("应用", systemImage: "app.badge") }
            CommandsSettings().tabItem { Label("自定义命令", systemImage: "command") }
            ColorRulesSettings().tabItem { Label("颜色规则", systemImage: "paintpalette") }
            ShortcutsSettings().tabItem { Label("快捷键", systemImage: "keyboard") }
            MenuSettings().tabItem { Label("右键菜单", systemImage: "contextualmenu.and.cursorarrow") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var opensFolders = DefaultFolderApp.isArbor
    /// Read-only: who opens folders right now (shown so the setting can be checked at a glance).
    private var folderHandlerName: String {
        guard let id = DefaultFolderApp.currentHandler else { return "未知" }
        if id.lowercased() == DefaultFolderApp.finderID { return "访达" }
        if id.lowercased() == Bundle.main.bundleIdentifier?.lowercased() { return "Arbor" }
        return id
    }
    @State private var folderError: String?

    private var folderFooter: String {
        if let folderError { return "没能更改：\(folderError)" }
        return "现在打开文件夹的是：\(folderHandlerName)。打开后，从聚焦搜索、其他应用或终端（open 命令）打开的文件夹都会在 Arbor 里显示。桌面、程序坞和“在访达中显示”属于访达本身，仍会打开访达。关闭即恢复由访达打开。"
    }

    private func setOpensFolders(_ on: Bool) {
        folderError = nil
        DefaultFolderApp.set(on) { problem in
            folderError = problem
            // Read back what the system actually did (the user may have declined).
            opensFolders = DefaultFolderApp.isArbor
        }
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("浏览") {
                Toggle("显示隐藏文件", isOn: $settings.showHidden)
                Toggle("文件夹排在文件前面", isOn: $settings.foldersFirst)
                Toggle("列表中显示大小条和新鲜度光点", isOn: $settings.showListInsights)
            }
            Section {
                Picker("新窗口的窗格", selection: $settings.newWindowPaneCount) {
                    Text("和上次一样").tag(0)
                    Divider()
                    Text("单窗格").tag(1)
                    Text("双窗格").tag(2)
                    Text("三窗格").tag(3)
                }
            } header: {
                Text("窗口")
            } footer: {
                Text("关掉所有窗口后再打开，会回到关闭前的标签页；“和上次一样”还会沿用窗格数、窗格宽度、侧边栏和检查器。已有窗口时按 ⌘N，新窗口沿用当前窗口的布局，从主目录开始。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("自动保存工作区的布局", isOn: $settings.autoSaveWorkspaces)
            } header: {
                Text("工作区")
            } footer: {
                Text("工作区是一组存好的窗格、标签页和颜色。打开时，切换到别的工作区或退出 Arbor 都会把当前布局存回去；关闭后只有“用当前布局更新”才会保存。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("自动检查更新", isOn: $settings.autoCheckUpdates)
                Toggle("接收开发预览版", isOn: $settings.includePreviewUpdates)
                LabeledContent("当前版本") {
                    HStack {
                        Text(Updater.shared.currentTag).foregroundStyle(.secondary)
                        Button("检查更新") { Updater.shared.check(userInitiated: true) }
                    }
                }
            } header: {
                Text("更新")
            } footer: {
                Text("更新来自 GitHub 上的 \(Updater.shared.repository) 发布页，下载后会在 Arbor 退出时替换并重新打开。")
                    .foregroundStyle(.secondary)
            }
            Section("检查器") {
                Toggle("自动计算文件夹大小", isOn: $settings.autoFolderSize)
            }
            Section {
                Toggle("用 Arbor 打开文件夹（代替访达）", isOn: Binding(get: { opensFolders }, set: setOpensFolders))
            } header: {
                Text("默认文件管理器")
            } footer: {
                Text(folderFooter).foregroundStyle(.secondary)
            }
            Section {
                Toggle("在菜单栏显示 Arbor 图标", isOn: $settings.showMenuBarIcon)
                LabeledContent("随时呼出 Arbor") { HotKeyRecorder(spec: $settings.hotKey) }
            } header: {
                Text("系统")
            } footer: {
                Text("在任何应用中按下快捷键即可显示 / 隐藏 Arbor。显示菜单栏图标时，关闭所有窗口后 Arbor 会继续在后台运行。\n访达右键菜单「服务 › 在 Arbor 中打开」可在系统设置 › 键盘 › 键盘快捷键 › 服务中开启。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("终端", selection: $settings.terminalBundleID) {
                    ForEach(ExternalApp.installedTerminals) { appRow($0).tag($0.bundleID) }
                }
                Picker("编辑器", selection: $settings.editorBundleID) {
                    ForEach(ExternalApp.installedEditors) { appRow($0).tag($0.bundleID) }
                }
            } footer: {
                Text("“在终端中打开”（⌥⌘T）和“在编辑器中打开”（⌥⌘E）使用这里选择的应用。只列出已安装的应用。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func appRow(_ app: ExternalApp) -> some View {
        HStack {
            if let url = app.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
            Text(app.name)
        }
    }
}

private struct CommandsSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.customCommands) { command in
                        Label(command.name, systemImage: command.mode == .terminal ? "terminal" : "gearshape")
                            .tag(command.id)
                    }
                    .onMove { settings.customCommands.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let command = CustomCommand(name: "新命令", script: "echo $FILES")
                        settings.customCommands.append(command)
                        selection = command.id
                    } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        settings.customCommands.removeAll { $0.id == selection }
                        selection = settings.customCommands.first?.id
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 170, maxWidth: 220)

            if let index = settings.customCommands.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("名称", text: $settings.customCommands[index].name)
                    Picker("运行方式", selection: $settings.customCommands[index].mode) {
                        ForEach(CustomCommand.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("命令（zsh）")
                        TextEditor(text: $settings.customCommands[index].script)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Text(CommandRunner.placeholderHelp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text("选择或添加一条命令。命令会出现在右键菜单「自定义命令」和 ⌘K 命令面板中。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? settings.customCommands.first?.id }
    }
}

private struct ShortcutsSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var query = ""

    var body: some View {
        let entries = ShortcutCatalog.entries.filter { query.isEmpty || Fuzzy.score(query, $0.title) != nil }
        let used = Dictionary(grouping: ShortcutCatalog.entries.compactMap { entry in
            ShortcutCatalog.current(entry.title).map { ($0.display, entry.title) }
        }, by: \.0)
        VStack(spacing: 0) {
            HStack {
                TextField("搜索命令", text: $query).textFieldStyle(.roundedBorder)
                Button("全部恢复默认") {
                    settings.customShortcuts = [:]
                    settings.clearedShortcuts = []
                }
            }
            .padding(12)
            Form {
                LabeledContent("固定按键（不可更改）") {
                    Text("空格 快速查看 · ↩ 重命名 · ⇥ 切换窗格").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.title) { entry in
                    let current = ShortcutCatalog.current(entry.title)
                    let conflict = current.map { (used[$0.display]?.count ?? 0) > 1 } ?? false
                    LabeledContent {
                        HStack {
                            if conflict {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("与其他命令冲突")
                            }
                            ShortcutRecorder(id: entry.title)
                        }
                    } label: {
                        Text(entry.title)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Records a menu shortcut for one command.
private struct ShortcutRecorder: View {
    let id: String
    @State private var recording = false
    @State private var monitor: Any?
    private let settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "请按下…" : (ShortcutCatalog.current(id)?.display ?? "无")) { recording ? stop() : start() }
                .frame(minWidth: 90)
            Menu {
                Button("恢复默认") {
                    settings.customShortcuts[id] = nil
                    settings.clearedShortcuts.remove(id)
                }
                Button("移除快捷键") {
                    settings.customShortcuts[id] = nil
                    settings.clearedShortcuts.insert(id)
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let specials: [UInt16: String] = [51: "delete", 126: "up", 125: "down", 123: "left", 124: "right",
                                              36: "return", 49: "space", 48: "tab"]
            if event.keyCode == 53 { stop(); return nil } // esc cancels
            var modifiers: EventModifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            guard let key = specials[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased().first.map(String.init),
                  !modifiers.isEmpty || specials[event.keyCode] != nil else { return nil }
            settings.customShortcuts[id] = ShortcutSpec(key: key, modifiers: modifiers.rawValue)
            settings.clearedShortcuts.remove(id)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct MenuSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(ContextMenuBuilder.customizable, id: \.self) { title in
                    Toggle(title, isOn: Binding(
                        get: { !settings.hiddenMenuItems.contains(title) },
                        set: { visible in
                            if visible { settings.hiddenMenuItems.remove(title) } else { settings.hiddenMenuItems.insert(title) }
                        }))
                }
            } header: {
                Text("在右键菜单中显示")
            } footer: {
                Text("打开、剪切、拷贝、粘贴、重命名、移到废纸篓始终显示。工具栏可在窗口工具栏上右键 › 自定义工具栏。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Shows the output of a custom command.
struct CommandOutputSheet: View {
    let output: CommandOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(output.title, systemImage: output.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(output.succeeded ? Color.primary : Color.orange)
            ScrollView {
                Text(output.text.isEmpty ? "（无输出）" : output.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("拷贝输出") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

private struct ColorRulesSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach($settings.colorRules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        TextField("", text: $rule.pattern, prompt: Text("*.psd; *.ai"))
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $rule.tint) {
                            ForEach(ColorRule.Tint.allCases) { tint in
                                Label { Text(tint.title) } icon: { Image(nsImage: FinderTags.dot(tint.color)) }.tag(tint)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        Button {
                            settings.colorRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加规则", systemImage: "plus") {
                    settings.colorRules.append(ColorRule(pattern: "", tint: .blue))
                }
            } header: {
                Text("按文件名给文件着色")
            } footer: {
                Text("用分号分隔多个通配符，例如 *.psd; *.sketch 或 IMG_*。规则从上到下匹配，第一条匹配的生效。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
