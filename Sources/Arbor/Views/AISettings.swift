import SwiftUI

/// Settings › AI: which model the command bar and AI renaming use, and how the glow looks.
struct AISettings: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(\.arborTint) private var tint
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var glowPreview = true

    var body: some View {
        Form {
            Section {
                Picker(L("接口类型"), selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField(L("接口地址"), text: $settings.aiBaseURL, prompt: Text(settings.aiProvider.defaultBaseURL))
                TextField(L("模型"), text: $settings.aiModel,
                          prompt: Text(settings.aiProvider == .anthropic ? "claude-opus-5-5" : "deepseek-chat / qwen-plus / llama3.1"))
                SecureField(L("API 密钥"), text: $settings.aiAPIKey, prompt: Text(settings.aiConfig.isLocal ? L("本地模型可以不填") : "sk-…"))
                HStack {
                    Button(testing ? L("正在测试…") : L("测试连接"), action: test)
                        .disabled(testing || !settings.aiConfig.isUsable)
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? Color.green : Color.red)
                            .lineLimit(2)
                            .font(.callout)
                    }
                }
            } header: {
                Text(L("大模型"))
            } footer: {
                Text(L("OpenAI 兼容接口可以填 DeepSeek（https://api.deepseek.com）、通义千问、Kimi、OpenRouter，或本机的 Ollama（http://localhost:11434/v1）。密钥保存在钥匙串里。"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("光效"), selection: $settings.aiGlow) {
                    ForEach(AIGlowStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // A live sample of the edge light.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 64)
                    .overlay {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text(L("问 Arbor…")).foregroundStyle(.secondary)
                        }
                    }
                    .overlay { AIGlowBorder(cornerRadius: 14, lineWidth: 1.5, spread: 0.7, active: glowPreview).id(settings.aiGlow) }
                    .padding(.vertical, 8)
                    .onTapGesture { glowPreview.toggle() }
                    .help(L("点一下切换“思考中”和“待命”"))
            } header: {
                Text(L("外观"))
            }

            Section {
                Label(L("⌘J，或在 ⌘K 里直接打一句话：Arbor 会自己查看文件夹、搜索、读取文件内容，然后显示、选中、打开，或者整理文件——新建文件夹、移动、拷贝、改名、打标签、移到废纸篓，或执行任何 ⌘K 命令。"), systemImage: "command")
                Label(L("改动文件之前会先列出计划，等你点“执行”；执行后都能用 ⌘Z 撤销。"), systemImage: "checkmark.shield")
                Label(L("右键 › 用 AI 重命名：在本机读取文本、PDF 和图片里的文字，让模型按内容起名，确认后才改。"), systemImage: "character.cursor.ibeam")
                Label(L("发送给模型的有：当前文件夹的文件名、大小和日期，所选项目的路径，以及它查看、搜索或读取到的内容。"), systemImage: "lock")
            } header: {
                Text(L("能做什么"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: settings.aiConfig) { _, _ in testResult = nil }
    }

    private func test() {
        testing = true
        testResult = nil
        let config = settings.aiConfig
        Task {
            defer { testing = false }
            do {
                let schema: [String: Any] = [
                    "type": "object", "additionalProperties": false, "required": ["ok"],
                    "properties": ["ok": ["type": "boolean"]],
                ]
                let reply = try await AIClient.json(system: "Reply with {\"ok\": true}.", user: "ping", schema: schema,
                                                    config: config, maxTokens: 256)
                testResult = reply["ok"] as? Bool == true ? (true, L("连接正常")) : (false, L("能连上，但回复不对"))
            } catch {
                testResult = (false, error.localizedDescription)
            }
        }
    }
}
