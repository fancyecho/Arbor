import SwiftUI

/// Plans and runs a folder sync between the active pane and the other pane, previewing every action first.
struct SyncSheet: View {
    let workspace: WorkspaceState

    @Environment(\.dismiss) private var dismiss
    @State private var options = SyncOptions()
    @State private var actions: [SyncAction] = []
    @State private var planning = false

    var body: some View {
        let here = workspace.activeTab.url
        let there = workspace.otherPane?.activeTab.url ?? here

        VStack(alignment: .leading, spacing: 14) {
            Text("同步文件夹").font(.headline)

            HStack(spacing: 10) {
                folderLabel(here)
                Picker("", selection: $options.direction) {
                    Image(systemName: "arrow.right").tag(SyncOptions.Direction.toOther)
                    Image(systemName: "arrow.left").tag(SyncOptions.Direction.fromOther)
                    Image(systemName: "arrow.left.arrow.right").tag(SyncOptions.Direction.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                folderLabel(there)
            }

            Text(directionHelp)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Toggle("包含子文件夹", isOn: $options.recursive)
                Toggle("删除目标中多余的项目", isOn: $options.deleteExtras)
                    .disabled(options.direction == .both)
                    .help("让目标与源完全一致（多余项目移到废纸篓，可撤销）")
                Toggle("比较文件内容", isOn: $options.compareContents)
                    .help("大小和日期都相同时再计算 SHA-256，较慢")
            }

            List(actions) { action in
                HStack(spacing: 8) {
                    Image(systemName: symbol(action.kind))
                        .foregroundStyle(color(action.kind))
                        .frame(width: 16)
                    Text(action.relativePath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(arrow(action)).font(.caption).foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if planning {
                    ProgressView("正在比较…").controlSize(.small)
                } else if actions.isEmpty {
                    Text("两边已经一致，无需同步").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(summary).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("同步") {
                    workspace.runSync(actions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actions.isEmpty || planning || here.isSameFile(as: there))
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .task(id: options) {
            planning = true
            let cancel = CancelFlag()
            let planned = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) { [options] in
                    SyncPlanner.plan(here, there, options: options, cancel: cancel)
                }.value
            } onCancel: { cancel.cancel() }
            guard !Task.isCancelled else { return }
            actions = planned
            planning = false
        }
    }

    private func folderLabel(_ url: URL) -> some View {
        Label(Places.displayName(for: url), systemImage: "folder.fill")
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .help(url.path)
    }

    private var directionHelp: String {
        switch options.direction {
        case .toOther: "把左侧新增和较新的文件拷贝到右侧；右侧较新的文件不会被覆盖。"
        case .fromOther: "把右侧新增和较新的文件拷贝到左侧；左侧较新的文件不会被覆盖。"
        case .both: "双向：各自把对方没有的、以及更新版本的文件拷贝过去，不删除任何内容。"
        }
    }

    private var summary: String {
        let add = actions.filter { $0.kind == .add }.count
        let update = actions.filter { $0.kind == .update }.count
        let delete = actions.filter { $0.kind == .delete }.count
        return "新增 \(add) · 更新 \(update) · 删除 \(delete)"
    }

    private func symbol(_ kind: SyncAction.Kind) -> String {
        switch kind {
        case .add: "plus.circle.fill"
        case .update: "arrow.triangle.2.circlepath.circle.fill"
        case .delete: "minus.circle.fill"
        }
    }

    private func color(_ kind: SyncAction.Kind) -> Color {
        switch kind {
        case .add: .green
        case .update: .blue
        case .delete: .red
        }
    }

    private func arrow(_ action: SyncAction) -> String {
        let to = Places.displayName(for: action.kind == .delete ? action.item.deletingLastPathComponent() : action.destination)
        return action.kind == .delete ? "从“\(to)”删除" : "→ \(to)"
    }
}
