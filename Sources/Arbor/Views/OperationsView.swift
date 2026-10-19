import SwiftUI

/// Toolbar button that appears while file jobs exist; shows a ring of overall progress
/// and opens a popover listing each job with a cancel button.
struct OperationsButton: View {
    @Environment(\.arborTint) private var tint
    private let queue = FileOperationQueue.shared
    @State private var showing = false

    var body: some View {
        if !queue.tasks.isEmpty {
            Button { showing.toggle() } label: {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: queue.overallFraction ?? (queue.activeCount > 0 ? 0.15 : 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: queue.overallFraction)
                    Image(systemName: queue.activeCount > 0 ? "arrow.down" : "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(queue.activeCount > 0 ? tint : .secondary)
                }
                .frame(width: 16, height: 16)
            }
            .help(queue.activeCount > 0 ? "\(queue.activeCount) 个操作进行中" : "文件操作")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                OperationsList(queue: queue)
            }
        }
    }
}

private struct OperationsList: View {
    let queue: FileOperationQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件操作").font(.headline)
                Spacer()
                if queue.tasks.contains(where: { $0.state != .running }) {
                    Button("清除已完成") { queue.clearFinished() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)

            if queue.tasks.isEmpty {
                Text("没有进行中的操作")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(queue.tasks) { TaskRow(task: $0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 340)
    }
}

private struct TaskRow: View {
    let task: FileTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if task.state == .running {
                    ProgressView(value: task.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    if !task.progress.currentName.isEmpty {
                        Text(task.progress.currentName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(task.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(task.state.isFailure ? Color.red : .secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if task.state == .running {
                Button { task.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("停止")
            }
        }
    }

    private var symbol: String {
        switch task.state {
        case .running: task.kind == .move ? "arrow.right.doc.on.clipboard" : "doc.on.doc"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch task.state {
        case .running: .accentColor
        case .finished: .green
        case .cancelled: .secondary
        case .failed: .orange
        }
    }
}

private extension FileTask.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
