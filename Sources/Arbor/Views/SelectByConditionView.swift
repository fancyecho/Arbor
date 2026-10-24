import SwiftUI

/// "按条件选择": select items in the active folder by name pattern, kind, age and size.
struct SelectByConditionView: View {
    let workspace: WorkspaceState

    @Environment(\.dismiss) private var dismiss
    @State private var condition = SelectionCondition()

    var body: some View {
        let tab = workspace.activeTab
        let matches = tab.visibleItems.filter { condition.matches($0) }

        VStack(alignment: .leading, spacing: 14) {
            Text(L("按条件选择")).font(.headline)
            Form {
                TextField(L("名称"), text: $condition.pattern, prompt: Text(L("包含的文字，或通配符如 *.jpg、IMG_????")))
                Toggle(L("使用正则表达式"), isOn: $condition.useRegex)
                Picker(L("类型"), selection: $condition.kind) {
                    ForEach(SelectionCondition.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("修改时间"), selection: $condition.age) {
                    ForEach(SelectionCondition.Age.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Picker(L("大小"), selection: $condition.sizeRule) {
                        ForEach(SelectionCondition.SizeRule.allCases) { Text($0.title).tag($0) }
                    }
                    if condition.sizeRule != .any {
                        TextField("", value: $condition.sizeMB, format: .number)
                            .frame(width: 70)
                            .labelsHidden()
                        Text("MB")
                    }
                }
                Toggle(L("添加到当前选择"), isOn: $condition.addToSelection)
            }
            HStack {
                Text(L("匹配 \(matches.count) / \(tab.visibleItems.count) 项")).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("选择")) {
                    let urls = Set(matches.map(\.url))
                    tab.selection = condition.addToSelection ? tab.selection.union(urls) : urls
                    workspace.focusToken += 1
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matches.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
