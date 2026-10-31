import SwiftUI
import GuardKit

struct DashboardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(state: state)
                .frame(width: 210)
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                TopBarView(state: state)
                if let snapshot = state.snapshot, snapshot.criticalCount > 0 {
                    // 切到连接、事件或设置时，严重风险仍然始终可见。
                    CriticalBanner(checks: snapshot.checks.filter { $0.severity == .critical },
                                   enforcing: snapshot.daemonMode == .root && snapshot.settings.enforce)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                ScrollView {
                    Group {
                        switch state.selection {
                        case .overview:
                            OverviewView(state: state)
                        case .connections:
                            ConnectionsView(state: state)
                        case .events:
                            EventsView(state: state)
                        case .settings:
                            SettingsView(state: state)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // 背景放在 .background 里，不参与布局：旧版背景里有 920pt 的光晕，撑高了整个内容，
        // 超出窗口的内容被垂直居中，顶部被裁掉，侧边栏标题滑到红绿灯下面。
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(AppBackground())
        // 窗口失去焦点时 macOS 默认把玻璃变灰、把彩色按钮去色，看起来像刷新后变了颜色。
        // 这是监控面板，失焦时也要能一眼看清状态，所以始终用活跃外观。
        .environment(\.controlActiveState, .key)
        .alert("Route Guard", isPresented: $state.showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "未知错误")
        }
    }
}

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "BrandIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Route Guard 折光护盾")
                Text("Route Guard")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarButton(item: item, selected: state.selection == item) {
                        // 不加动画：整页玻璃卡片做过渡会让切换显得迟钝。
                        state.selection = item
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Circle()
                    .fill(state.daemonConnected ? Theme.green : Theme.amber)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.daemonConnected ? "守护进程运行中" : "预览模式")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                    Text(state.snapshot?.clashVersion.map { "mihomo \($0)" } ?? "等待 Clash")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        // 安全区已经让出了标题栏（红绿灯）的高度，这里只留一点间距。
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

struct TopBarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selection.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(state.selection.subtitle)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let snapshot = state.snapshot {
                StatusPill(state: snapshot.state)
            }
            ActionButton(title: "刷新", icon: "arrow.clockwise") {
                state.recheck()
            }
            .help("立即重新检查所有项目")
            ActionButton(title: "封锁", icon: "hand.raised.fill", tint: Theme.red) {
                state.blockClaude()
            }
            .disabled(!state.daemonConnected || state.pendingCommand != nil)
            .help("立即关闭被管理的 Claude")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

struct OverviewView: View {
    @ObservedObject var state: AppState

    private var snapshot: Snapshot? { state.snapshot }
    private static let keyIDs = ["tun", "routes", "node", "rules"]

    private var keyChecks: [GuardCheck] {
        guard let checks = snapshot?.checks else { return [] }
        return Self.keyIDs.compactMap { id in checks.first { $0.id == id } }
    }

    /// 其余检查只显示有问题的；全部正常时折叠成一行。
    private var otherChecks: [GuardCheck] {
        guard let checks = snapshot?.checks else { return [] }
        return checks.filter { !Self.keyIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusCard(state: state)

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    checksCard
                    EventsCard(events: snapshot?.events ?? [], limit: 4) {
                        state.selection = .events
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                NodeCard(state: state)
                    .frame(width: 290, alignment: .top)
            }
        }
    }

    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(icon: "waveform.path.ecg", title: "运行状态") {
                let total = snapshot?.checks.count ?? 0
                let ok = snapshot?.checks.filter { $0.severity == .ok }.count ?? 0
                Text("\(ok)/\(total) 正常")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.bottom, 4)

            ForEach(Array(keyChecks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { RowDivider() }
                ConditionRow(check: check)
            }

            if !otherChecks.isEmpty {
                RowDivider()
                AllChecksDisclosure(checks: otherChecks)
            }
        }
        .glassCard(padding: 16, radius: 20)
    }
}

@MainActor
final class ExpandedStore: ObservableObject {
    @Published var expanded = false
}

/// 展开状态单独保存，后台刷新不会把它收起来。
struct AllChecksDisclosure: View {
    let checks: [GuardCheck]
    @StateObject private var store = ExpandedStore()
    private var expanded: Bool { store.expanded }

    private var problems: [GuardCheck] { checks.filter { $0.severity != .ok } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(problems.isEmpty ? "其他 \(checks.count) 项检查都正常" : "其他检查 · \(problems.count) 项需要注意")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(problems.isEmpty ? Theme.secondary : Theme.amber)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { RowDivider() }
                    ConditionRow(check: check)
                }
            }
        }
    }
}

struct StatusCard: View {
    @ObservedObject var state: AppState

    private var snapshot: Snapshot? { state.snapshot }
    private var guardState: GuardState { snapshot?.state ?? .unknown }

    private func duration(at now: Date) -> String {
        guard let since = snapshot?.protectedSince else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return String(format: "%d 小时 %02d 分", seconds / 3600, (seconds % 3600) / 60)
    }

    private var managed: String {
        guard let settings = snapshot?.settings else { return "—" }
        let apps = ClaudeApp.allCases.filter { settings.manages($0) }.map(\.title)
        return apps.isEmpty ? "未管理任何应用" : apps.joined(separator: "、")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ShieldBadge(state: guardState)

            VStack(alignment: .leading, spacing: 4) {
                Text(guardState.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(guardState == .blocked || guardState == .attention ? guardState.color : Theme.text)
                Text(snapshot?.stateSubtitle ?? guardState.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 22) {
                Metric(label: "管理", value: managed)
                Metric(label: "Claude 进程", value: "\(snapshot?.processes.count ?? 0)")
                VStack(alignment: .leading, spacing: 3) {
                    Text("保护时长")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    // 快照没变化时界面不重绘，时长需要自己按秒走。
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(duration(at: context.date))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                    }
                }
            }

            if state.daemonConnected && snapshot?.settings.enforce == false {
                ActionButton(title: "启用保护", icon: "shield.fill", tint: Theme.green, prominent: true) {
                    state.selection = .settings
                }
                .help("在设置里打开保护")
            }
        }
        .glassCard(padding: 20, radius: 24)
        .overlay {
            if guardState == .blocked || guardState == .attention {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(guardState.indicatorColor.opacity(0.65), lineWidth: 1.5)
            }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }
}

struct NodeCard: View {
    @ObservedObject var state: AppState

    private var node: NodeInfo? { state.snapshot?.node }
    private var egress: GuardCheck? { state.snapshot?.checks.first { $0.id == "egress" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "globe.asia.australia.fill", title: "AI 出口") {
                if let node {
                    Badge(text: node.approved ? "已确认" : "待确认", color: node.approved ? Theme.green : Theme.amber)
                }
            }

            if let node, !node.name.isEmpty {
                Text(node.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                VStack(spacing: 7) {
                    LabeledValue(label: "类型", value: node.type)
                    LabeledValue(label: "延迟", value: node.delay > 0 ? "\(node.delay) ms" : "—")
                    LabeledValue(label: "链路", value: node.chain.joined(separator: " → "))
                    if let egress {
                        LabeledValue(label: "出口 IP", value: egress.detail)
                    }
                    LabeledValue(label: "指纹", value: node.fingerprint.map { String($0.prefix(12)) + "…" } ?? "无", mono: true)
                }

                if !node.approved {
                    ActionButton(title: "确认当前节点", icon: "checkmark.seal.fill", tint: Theme.teal,
                                 prominent: true, fullWidth: true) {
                        state.approveCurrentNode()
                    }
                    .disabled(!state.daemonConnected || state.pendingCommand != nil)
                }
            } else {
                EmptyStateView(icon: "server.rack", title: "等待 Clash",
                               detail: "Clash 准备好后会显示当前 AI 节点", compact: true)
            }
        }
        .glassCard(padding: 16, radius: 20)
    }
}

struct EventsCard: View {
    let events: [GuardEvent]
    var limit: Int = 4
    var showAll: () -> Void

    var body: some View {
        let visible = Array(events.suffix(limit).reversed())
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(icon: "clock.arrow.circlepath", title: "最近活动", tint: Theme.blue) {
                if !events.isEmpty {
                    Button("全部", action: showAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.blue)
                }
            }
            if events.isEmpty {
                EmptyStateView(icon: "sparkles", title: "一切安静", detail: "有变化时会出现在这里", compact: true)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { RowDivider() }
                    EventRow(event: event)
                }
            }
        }
        .glassCard(padding: 16, radius: 20)
    }
}
