import SwiftUI

struct BatchRenameView: View {
    let workspace: WorkspaceState
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss
    @State private var rule = BatchRenameRule()

    var body: some View {
        let names = urls.map(\.lastPathComponent)
        let newNames = rule.apply(to: names)
        let problems = BatchRenamer.problems(urls: urls, newNames: newNames)
        let changed = zip(names, newNames).filter { $0 != $1 }.count
        let blocked = problems.contains { $0 != nil } || rule.regexError != nil

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("批量重命名").font(.headline)
                Text("\(urls.count) 个项目").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $rule.mode) {
                    ForEach(BatchRenameRule.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            options
                .frame(minHeight: 64, alignment: .top)

            preview(names: names, newNames: newNames, problems: problems)

            HStack {
                if let error = rule.regexError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let problem = problems.compactMap({ $0 }).first {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("将重命名 \(changed) 个项目").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { apply(newNames) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked || changed == 0)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }

    @ViewBuilder
    private var options: some View {
        Form {
            switch rule.mode {
            case .replace:
                TextField("查找", text: $rule.find, prompt: Text(rule.useRegex ? "正则表达式，如 (\\d+)" : "要查找的文本"))
                TextField("替换为", text: $rule.replacement, prompt: Text(rule.useRegex ? "可用 $1 引用分组" : "留空即删除"))
                HStack(spacing: 16) {
                    Toggle("正则表达式", isOn: $rule.useRegex)
                    Toggle("区分大小写", isOn: $rule.caseSensitive)
                    Toggle("包含扩展名", isOn: $rule.includeExtension)
                }
            case .add:
                TextField("前缀", text: $rule.prefix, prompt: Text("加在名称前"))
                TextField("后缀", text: $rule.suffix, prompt: Text("加在扩展名前"))
            case .sequence:
                TextField("名称", text: $rule.baseName, prompt: Text("留空则只保留序号"))
                HStack(spacing: 16) {
                    Stepper("起始 \(rule.startIndex)", value: $rule.startIndex, in: 0...99999)
                    Stepper("位数 \(rule.digits)", value: $rule.digits, in: 1...6)
                    TextField("分隔符", text: $rule.separator).frame(width: 110)
                    Toggle("序号在前", isOn: $rule.numberFirst)
                }
            case .letterCase:
                Picker("转换为", selection: $rule.caseStyle) {
                    ForEach(BatchRenameRule.CaseStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                Toggle("包含扩展名", isOn: $rule.includeExtension)
            }
        }
        .formStyle(.columns)
    }

    private func preview(names: [String], newNames: [String], problems: [BatchRenamer.Problem?]) -> some View {
        List {
            ForEach(names.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(names[index])
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Text(newNames[index])
                        .fontWeight(names[index] == newNames[index] ? .regular : .medium)
                        .foregroundStyle(problems[index] != nil ? Color.orange : (names[index] == newNames[index] ? .secondary : .primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(problems[index]?.message ?? "")
                }
                .font(.system(size: 12))
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func apply(_ newNames: [String]) {
        let tab = workspace.activeTab
        do {
            let renamed = try BatchRenamer.perform(urls: urls, newNames: newNames)
            let pairs = zip(urls, newNames).map { ($0, $0.deletingLastPathComponent().appendingPathComponent($1)) }
            FileHistory.shared.record("批量重命名", steps: UndoExecutor.renameSteps(pairs.map { (from: $0.0, to: $0.1) }))
            tab.reload(selecting: Set(renamed))
            dismiss()
        } catch {
            workspace.report(error)
        }
    }
}
