import AppKit
import Carbon.HIToolbox
import SwiftUI

/// App-level entry points used by the menu bar icon, the global hotkey, the Finder service
/// and files opened from the Dock.
@MainActor
enum AppActions {
    /// Captured from SwiftUI so AppKit code can open a new browser window.
    static var openWindow: OpenWindowAction?

    /// Open browser windows, including minimized ones (closed windows can linger in `NSApp.windows`).
    private static var browserWindows: [NSWindow] {
        NSApp.windows.filter {
            ($0.isVisible || $0.isMiniaturized) && ($0.identifier?.rawValue.hasPrefix("browser") ?? false)
        }
    }

    static var hasBrowserWindow: Bool { browserWindows.contains(where: \.isVisible) }

    /// Brings Arbor forward and shows `url` (folders open in a new tab, files are revealed).
    static func show(_ url: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let windows = browserWindows
        guard let window = windows.first(where: \.isVisible) ?? windows.first,
              let workspace = WorkspaceRegistry.shared.current else {
            WorkspaceRegistry.shared.pendingURL = url
            openWindow?(id: "browser")
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        guard let url else { return }
        if let folder = TabState.resolvedDirectory(url) {
            workspace.activePane.newTab(url: folder)
        } else {
            workspace.activePane.newTab(url: url.deletingLastPathComponent()).selection = [url]
        }
        workspace.focusToken += 1
    }

    /// A new browser window (Dock menu); it takes the open window's layout, or the last one's.
    static func newWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "browser")
    }

    /// Quits even while a sheet is open: SwiftUI ignores `terminate` then (the update prompt that appears
    /// at launch used to make ⌘Q do nothing), so the sheets are closed first.
    static func quit() {
        let withSheets = NSApp.windows.filter { !$0.sheets.isEmpty }
        guard !withSheets.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        Updater.shared.dismiss()
        for window in withSheets {
            for sheet in window.sheets { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        // A sheet that refuses to go away must not make quitting impossible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            WorkspaceRegistry.shared.persist()
            exit(0)
        }
    }

    /// Global hotkey: show Arbor, or hide it if it's already in front.
    static func toggle() {
        if NSApp.isActive, hasBrowserWindow {
            NSApp.hide(nil)
        } else {
            show()
        }
    }
}

// MARK: - Global hotkey (Carbon RegisterEventHotKey: no accessibility permission needed)

struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value.
    var modifiers: UInt
    var display: String

    static let defaultValue = HotKeySpec(keyCode: UInt32(kVK_Space),
                                         modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥Space")

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func describe(_ flags: NSEvent.ModifierFlags, key: String) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }
}

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ spec: HotKeySpec?) {
        unregister()
        guard let spec else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppActions.toggle() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4152_4252), id: 1) // "ARBR"
        RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// Click, then press a key combination to record it.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "请按下快捷键…" : (spec?.display ?? "未设置")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
            if spec != nil, !recording {
                Button { spec = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("清除")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        GlobalHotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            // Require at least one of ⌘ ⌥ ⌃ so the hotkey can't swallow normal typing.
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            let key = event.keyCode == UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
            spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, display: HotKeySpec.describe(flags, key: key))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotKey.shared.register(AppSettings.shared.hotKey)
    }
}

// MARK: - Finder service ("在 Arbor 中打开")

final class ServiceProvider: NSObject {
    @objc func openInArbor(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for url in urls { AppActions.show(url) }
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Arbor") { AppActions.show() }
        Divider()
        Menu("个人收藏") {
            ForEach(SidebarStore.shared.favorites) { favorite in
                Button(favorite.name) { AppActions.show(favorite.url) }
            }
        }
        Menu("常去的文件夹") {
            ForEach(Frecency.shared.ranked().prefix(10), id: \.path) { entry in
                Button(Places.displayName(for: URL(fileURLWithPath: entry.path))) { AppActions.show(URL(fileURLWithPath: entry.path)) }
            }
        }
        if !WorkspaceLibrary.shared.saved.isEmpty {
            Menu("工作区") {
                ForEach(WorkspaceLibrary.shared.saved) { saved in
                    Button(saved.name) {
                        AppActions.show()
                        WorkspaceRegistry.shared.current?.open(saved)
                    }
                }
            }
        }
        Divider()
        Button(StashShelf.shared.isVisible ? "隐藏暂存架" : "显示暂存架") { StashShelf.shared.toggle() }
        Button("连接服务器…") {
            AppActions.show()
            WorkspaceRegistry.shared.current?.showConnectServer = true
        }
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Arbor") { AppActions.quit() }
            .onAppear { AppActions.openWindow = openWindow }
    }
}
