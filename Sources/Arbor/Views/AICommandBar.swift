import AppKit
import SwiftUI

/// ⌘J "问 Arbor": tell it what you want in plain words. It looks around (lists folders, searches, reads files),
/// shows and selects things right away, and puts anything that changes files into a plan you approve.
///
/// Each request is one turn: your words, a single folded line for the steps it took (live while it works), its
/// answer, and any plan. A conversation that has gone quiet starts over when the bar opens again.
struct AICommandBar: View {
    let workspace: WorkspaceState

    @Environment(\.arborTint) private var tint
    @Environment(\.openSettings) private var openSettings
    @State private var request = ""
    @State private var appeared = false
    @FocusState private var focused: Bool

    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    private var agent: AIAgent { workspace.assistant }
    private var thinking: Bool { agent.isThinking }
    private var configured: Bool { AppSettings.shared.aiConfig.isUsable }

    private let suggestions: [(symbol: String, text: String)] = [
        ("doc.richtext", L("上周下载的 PDF")),
        ("camera.viewfinder", L("把桌面上的截图整理到一个新文件夹")),
        ("arrow.up.right.and.arrow.down.left", L("这个文件夹里最大的 5 个文件")),
        ("tag", L("给选中的文件打上“重要”标签")),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { if !thinking { close() } }

            VStack(spacing: 10) {
                if agent.hasConversation {
                    transcript.transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                      removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
                }
                if !configured { setupBubble.transition(.opacity) }
                bar
                if request.isEmpty, !agent.hasConversation, configured {
                    suggestionGrid.transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .frame(width: 600)
            .padding(.bottom, 34)
            .offset(y: appeared ? 0 : 18)
            .opacity(appeared ? 1 : 0)
            .animation(.smooth(duration: 0.35), value: agent.hasConversation)
            .animation(.smooth(duration: 0.3), value: request.isEmpty)
        }
        .onAppear {
            agent.prepareForOpen()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { appeared = true }
            DispatchQueue.main.async { focused = true }
            sendPending()
        }
        .onChange(of: workspace.aiPendingRequest) { _, _ in sendPending() }
    }

    // MARK: Input

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AngularGradient(colors: AppSettings.shared.aiGlow.colors(dark: true), center: .center))
                .symbolEffect(.pulse, isActive: thinking)
                .symbolEffect(.bounce, value: agent.entries.count)
            TextField(agent.hasConversation ? L("继续说，或者问点别的…") : L("问 Arbor：找文件、整理文件、执行命令…"), text: $request)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(run)
                .onKeyPress(.escape) { close(); return .handled }
            Group {
                if thinking {
                    Button { agent.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 19)) }
                        .foregroundStyle(.secondary)
                        .help(L("停止"))
                } else if !request.isEmpty {
                    Button(action: run) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 21)) }
                        .foregroundStyle(tint)
                } else if agent.hasConversation {
                    Button { withAnimation(.smooth(duration: 0.3)) { agent.reset() } } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .help(L("新对话"))
                }
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: thinking)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: request.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .floatingGlass(in: Self.shape, fallback: .regularMaterial)
        .overlay { AIGlowBorder(cornerRadius: 22, lineWidth: 1.5, spread: 0.8, active: thinking) }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    /// Two rows of starting points, appearing one after another.
    private var suggestionGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                SuggestionChip(symbol: item.symbol, text: item.text, delay: Double(index) * 0.05) {
                    request = item.text
                    run()
                }
            }
        }
    }

    // MARK: Transcript

    private var turns: [AITurn] {
        var result: [AITurn] = []
        for entry in agent.entries {
            switch entry {
            case .user(let id, let text):
                result.append(AITurn(id: id, request: text))
            case .assistant(_, let text):
                guard !result.isEmpty else { continue }
                // Earlier remarks ("我先找一下") become steps; the latest one is the answer.
                if let previous = result[result.count - 1].answer {
                    result[result.count - 1].steps.append(.assistant(UUID(), previous))
                }
                result[result.count - 1].answer = text
            case .activity:
                if !result.isEmpty { result[result.count - 1].steps.append(entry) }
            case .plan(_, let plan):
                if !result.isEmpty { result[result.count - 1].plans.append(plan) }
            case .error(_, let text):
                if !result.isEmpty { result[result.count - 1].errors.append(text) }
            }
        }
        return result
    }

    private var transcript: some View {
        let turns = turns
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        TurnView(turn: turn, isLatest: index == turns.count - 1, agent: agent)
                            .id(turn.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                    if workspace.hasAIResults, !thinking {
                        Button {
                            withAnimation(.smooth) { workspace.closeAIResults() }
                        } label: {
                            Label(L("关闭结果标签页"), systemImage: "xmark.circle")
                        }
                        .buttonStyle(.glassCompact)
                        .font(.system(size: 11))
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.3), value: agent.entries)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            // Older text fades out under the top edge instead of being cut.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Rectangle()
                }
            }
            .floatingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
            .onAppear {
                // Open on the latest exchange.
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: agent.entries.count) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var setupBubble: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal").foregroundStyle(tint)
            Text(L("接入你自己的大模型（Claude、DeepSeek、通义、Ollama…）后就能用。"))
                .font(.system(size: 12.5))
            Spacer(minLength: 4)
            Button(L("去设置")) {
                AppSettings.shared.settingsTab = "ai"
                openSettings()
                close()
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .regularMaterial)
    }

    private func run() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        request = ""
        agent.send(text)
    }

    /// A request handed over from the ⌘K palette.
    private func sendPending() {
        guard let pending = workspace.aiPendingRequest else { return }
        workspace.aiPendingRequest = nil
        agent.send(pending)
    }

    private func close() {
        withAnimation(.smooth(duration: 0.2)) { appeared = false }
        workspace.showAIBar = false
        workspace.focusToken += 1
    }
}

// MARK: - Turn

/// One request and everything that came of it.
private struct AITurn: Identifiable {
    let id: UUID
    var request: String
    var steps: [AIAgent.Entry] = []
    var answer: String?
    var plans: [AIPlan] = []
    var errors: [String] = []
}

private struct TurnView: View {
    let turn: AITurn
    let isLatest: Bool
    let agent: AIAgent

    @Environment(\.arborTint) private var tint
    @State private var showsSteps = false

    private var working: Bool { isLatest && agent.isThinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Your request, on the right.
            HStack {
                Spacer(minLength: 80)
                Text(turn.request)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 5,
                                                       topTrailingRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.2)))
                    .textSelection(.enabled)
            }
            if !turn.steps.isEmpty || working { steps }
            if let answer = turn.answer, !(working && turn.steps.isEmpty && answer == agent.liveStatus) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(answer)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            ForEach(turn.plans) { plan in
                PlanCard(plan: plan, state: agent.planStates[plan.id] ?? .waiting,
                         approve: { agent.approve(plan) }, reject: { agent.reject(plan) })
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            ForEach(turn.errors, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Older turns step back a little.
        .opacity(isLatest ? 1 : 0.72)
    }

    /// One line for everything it did on the way; the current step while working, a list when opened.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { showsSteps.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if working {
                        ThinkingDots()
                        Text(agent.liveStatus ?? L("思考中…"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .animation(.smooth(duration: 0.25), value: agent.liveStatus)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(tint.opacity(0.8))
                        Text(L("\(stepCount) 个步骤"))
                    }
                    if !turn.steps.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showsSteps ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsSteps {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in stepRow(step) }
                }
                .padding(.leading, 6)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1.5)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var stepCount: Int {
        turn.steps.filter { if case .activity = $0 { true } else { false } }.count
    }

    @ViewBuilder
    private func stepRow(_ step: AIAgent.Entry) -> some View {
        switch step {
        case .activity(_, let symbol, let text):
            Label(text, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 8)
        case .assistant(_, let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.leading, 8)
        default:
            EmptyView()
        }
    }
}

/// Three dots in the glow's colors, rising one after another.
private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = AppSettings.shared.aiGlow.colors(dark: true)
        SwiftUI.TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(colors[(index * 2) % colors.count])
                        .frame(width: 5, height: 5)
                        .offset(y: -2.5 * max(0, sin(t * 6 - Double(index) * 0.7)))
                }
            }
        }
        .frame(width: 22, height: 10)
    }
}

/// A starting point under the empty bar.
private struct SuggestionChip: View {
    let symbol: String
    let text: String
    let delay: Double
    let action: () -> Void

    @Environment(\.arborTint) private var tint
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? tint : .secondary)
                    .frame(width: 16)
                Text(text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .floatingGlass(in: Capsule(), fallback: .thinMaterial)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.smooth(duration: 0.18)) { hovering = inside } }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear { withAnimation(.smooth(duration: 0.35).delay(0.08 + delay)) { shown = true } }
    }
}

// MARK: - Plan

/// The changes the assistant wants to make, waiting for a yes.
private struct PlanCard: View {
    let plan: AIPlan
    let state: AIAgent.PlanState
    let approve: () -> Void
    let reject: () -> Void

    @Environment(\.arborTint) private var tint
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(tint)
                Text(L("要做这些改动：")).font(.system(size: 12, weight: .semibold))
                Spacer()
                statusLabel.transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(index: index, step: step)
            }
            if state == .waiting {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Text(L("都可以用 ⌘Z 撤销")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(L("取消"), action: reject).buttonStyle(.glassCompact)
                    Button(action: approve) {
                        HStack(spacing: 4) {
                            Text(L("执行"))
                            Text("⌘↩").font(.system(size: 10)).opacity(0.7)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .font(.system(size: 11.5))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(state == .waiting ? tint.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1))
        .opacity(state == .cancelled ? 0.5 : 1)
        .animation(.smooth(duration: 0.3), value: state)
    }

    private func stepRow(index: Int, step: AIPlan.Step) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(step.isDestructive ? Color.red : tint)
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).transition(.scale)
                    } else {
                        Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                Image(systemName: step.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(step.isDestructive ? Color.red : .secondary)
                    .frame(width: 16)
                Text(step.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .strikethrough(state == .cancelled, color: .secondary)
                Spacer(minLength: 0)
                if step.detail.count > 1 {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(step.detail.count)").font(.system(size: 10.5)).monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(expanded.contains(step.id) ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(L("看看是哪些文件"))
                }
            }
            if expanded.contains(step.id) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(step.detail.prefix(40), id: \.self) { name in
                        Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if step.detail.count > 40 {
                        Text(L("还有 \(step.detail.count - 40) 项")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 49)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .waiting: Text(L("等你确认")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint)
        case .running: ProgressView().controlSize(.mini)
        case .done: Label(L("已执行"), systemImage: "checkmark").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green)
        case .cancelled: Text(L("已取消")).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
