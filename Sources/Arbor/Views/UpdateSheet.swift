import SwiftUI

/// "软件更新": checking, release notes, download progress and errors.
struct UpdateSheet: View {
    private let updater = Updater.shared
    @Environment(\.arborTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text("当前版本 \(updater.currentTag)").font(.caption).foregroundStyle(.secondary)
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: "正在检查更新…"
        case .upToDate: "Arbor 已是最新版本"
        case .available(let release): "有新版本：\(release.tagName)"
        case .downloading: "正在下载更新…"
        case .installing: "正在安装，Arbor 即将重新打开…"
        case .failed: "检查更新失败"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("没有比 \(updater.currentTag) 更新的版本。").foregroundStyle(.secondary)
        case .available(let release):
            notes(release)
        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).tint(tint)
                Text("\(Int(fraction * 100))% · \(Format.bytes(Int64(Double(release.appArchive?.size ?? 0) * fraction))) / \(Format.bytes(Int64(release.appArchive?.size ?? 0)))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .installing:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notes(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if release.prerelease {
                    Text("开发预览版").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                if let date = release.publishedAt { Text("发布于 \(Format.date(date))").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                Text((try? AttributedString(markdown: release.body ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(release.body ?? ""))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .slimScrollers(tint)
            }
            .frame(height: 180)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .available(let release):
            Link("在 GitHub 上查看", destination: release.htmlURL)
            Button("以后再说") { updater.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("立即更新") { updater.install(release) }
                .keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            Button("在后台继续") { updater.showsSheet = false }
        case .failed:
            Button("关闭") { updater.dismiss() }
            Button("重试") { updater.check(userInitiated: true) }.keyboardShortcut(.defaultAction)
        default:
            Button("好") { updater.dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}
