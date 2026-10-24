import SwiftUI

struct ConnectServerSheet: View {
    let workspace: WorkspaceState

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var recents: [String] = AppDefaults.store.stringArray(forKey: "servers.recent") ?? []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("连接服务器")).font(.headline)
            TextField(L("服务器地址"), text: $address, prompt: Text(L("smb://192.168.1.10/共享")))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(connect)
            Text(L("支持 smb://、afp://、nfs://、https://（WebDAV）和 ftp://（只读）。只写主机名时默认使用 SMB。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !recents.isEmpty {
                Text(L("最近使用")).font(.subheadline).foregroundStyle(.secondary)
                List(recents, id: \.self) { server in
                    Label(server, systemImage: "server.rack")
                        .contentShape(Rectangle())
                        .onTapGesture { address = server }
                        .onTapGesture(count: 2) {
                            address = server
                            connect()
                        }
                        .contextMenu {
                            Button(L("从列表中移除")) {
                                recents.removeAll { $0 == server }
                                AppDefaults.store.set(recents, forKey: "servers.recent")
                            }
                        }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 130)
            }

            if let error { Text(error).font(.callout).foregroundStyle(.red) }

            HStack {
                if connecting {
                    ProgressView().controlSize(.small)
                    Text(L("正在连接…")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("连接"), action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ServerConnect.normalize(address) == nil || connecting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func connect() {
        guard let url = ServerConnect.normalize(address), !connecting else { return }
        connecting = true
        error = nil
        ServerConnect.mount(url) { result in
            connecting = false
            switch result {
            case .success(let mountPoint):
                recents.removeAll { $0 == url.absoluteString }
                recents.insert(url.absoluteString, at: 0)
                AppDefaults.store.set(Array(recents.prefix(10)), forKey: "servers.recent")
                VolumeList.shared.refresh()
                workspace.go(to: mountPoint)
                dismiss()
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }
}
