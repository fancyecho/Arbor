import AppKit

/// Known terminals and editors; only installed ones are offered.
struct ExternalApp: Hashable, Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { url != nil }

    static let terminals: [ExternalApp] = [
        .init(name: L("终端"), bundleID: "com.apple.Terminal"),
        .init(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        .init(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        .init(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        .init(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
        .init(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
        .init(name: "Alacritty", bundleID: "org.alacritty"),
    ]

    static let editors: [ExternalApp] = [
        .init(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        .init(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        .init(name: "Zed", bundleID: "dev.zed.Zed"),
        .init(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        .init(name: "Nova", bundleID: "com.panic.Nova"),
        .init(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        .init(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        .init(name: L("文本编辑"), bundleID: "com.apple.TextEdit"),
    ]

    static var installedTerminals: [ExternalApp] { terminals.filter(\.isInstalled) }
    static var installedEditors: [ExternalApp] { editors.filter(\.isInstalled) }
}

/// A user-defined shell command run on the selection, e.g. `zip -r 归档.zip $FILES`.
struct CustomCommand: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case background, output, terminal
        var id: Self { self }
        var title: String {
            switch self {
            case .background: L("后台运行")
            case .output: L("运行并显示输出")
            case .terminal: L("在终端中运行")
            }
        }
    }

    var id = UUID()
    var name: String
    var script: String
    var mode: Mode = .output

    static let examples: [CustomCommand] = [
        CustomCommand(name: L("压缩为 zip"), script: L("zip -r -q \"归档 $(date +%H%M%S).zip\" $NAMES"), mode: .background),
        CustomCommand(name: L("统计行数"), script: "wc -l $FILES", mode: .output),
        CustomCommand(name: L("计算 SHA-256"), script: "shasum -a 256 $FILES", mode: .output),
        CustomCommand(name: L("Git 状态"), script: "git status", mode: .terminal),
    ]
}

struct CommandOutput: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let succeeded: Bool
}

enum CommandRunner {
    static let placeholderHelp = L("$FILES 所选项目的完整路径（已加引号，空格分隔）\n$FILE  第一个所选项目    $NAMES 所选项目的名称\n$DIR   当前文件夹        命令在当前文件夹中执行")

    /// Replaces placeholders with shell-quoted values. Longer names first so $FILES isn't read as $FILE + S.
    static func expand(_ script: String, files: [URL], directory: URL) -> String {
        let q = PathFormatter.shellQuoted
        let values: [(String, String)] = [
            ("$FILES", files.map { q($0.path) }.joined(separator: " ")),
            ("$NAMES", files.map { q($0.lastPathComponent) }.joined(separator: " ")),
            ("$FILE", files.first.map { q($0.path) } ?? "''"),
            ("$DIR", q(directory.path)),
        ]
        var result = script
        for (key, value) in values { result = result.replacingOccurrences(of: key, with: value) }
        return result
    }

    /// Runs off the main thread; completion on main with combined stdout+stderr and success flag.
    @MainActor
    static func run(_ command: CustomCommand, files: [URL], directory: URL,
                    completion: @escaping @MainActor (CommandOutput) -> Void) {
        let script = expand(command.script, files: files, directory: directory)
        if command.mode == .terminal {
            runInTerminal(script, directory: directory)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["ARBOR_DIR"] = directory.path
            environment["ARBOR_FILES"] = files.map(\.path).joined(separator: "\n")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var text: String
            var ok = false
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
                ok = process.terminationStatus == 0
                if !ok { text += L("\n（退出码 \(process.terminationStatus)）") }
            } catch {
                text = error.localizedDescription
            }
            let output = CommandOutput(title: command.name, text: text.trimmingCharacters(in: .whitespacesAndNewlines), succeeded: ok)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(output) } }
        }
    }

    /// Writes a throwaway .command script and opens it with the chosen terminal.
    @MainActor
    private static func runInTerminal(_ script: String, directory: URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh -l\ncd \(PathFormatter.shellQuoted(directory.path))\n\(script)\n"
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch { return }
        NSWorkspace.shared.open([file], withApplicationAt: AppSettings.shared.terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
