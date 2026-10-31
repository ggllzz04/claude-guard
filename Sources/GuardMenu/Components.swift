import SwiftUI
import GuardKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case connections
    case events
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .connections: return "连接"
        case .events: return "事件"
        case .settings: return "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Claude 与你选择的 AI 节点"
        case .connections: return "被管理的 Claude 正在连接哪里"
        case .events: return "状态变化与提示"
        case .settings: return "保护范围、审计与节点"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .events: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum FindingFilter: String, CaseIterable, Identifiable {
    case all
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .attention: return "需要注意"
        }
    }
}

struct StatusPill: View {
    let state: GuardState
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.indicatorColor)
                .frame(width: state == .blocked ? 9 : 7, height: state == .blocked ? 9 : 7)
            Text(state.title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(state.color)
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 5 : 6)
        .stableGlass(Capsule(), tint: state.color.opacity(0.14))
    }
}

/// 卡片标题行：图标 + 标题，右侧可放一个附加视图（计数、徽标）。
struct CardHeader<Accessory: View>: View {
    let icon: String
    let title: String
    var tint: Color = Theme.teal
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(icon: String, title: String, tint: Color = Theme.teal) {
        self.init(icon: icon, title: title, tint: tint) { EmptyView() }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct ShieldBadge: View {
    let state: GuardState

    var body: some View {
        Image(systemName: state.icon)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(state.color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 64, height: 64)
            .stableGlass(Circle(), tint: state.color.opacity(0.16))
            .animation(.easeInOut(duration: 0.3), value: state)
    }
}

struct ConditionRow: View {
    let check: GuardCheck

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: check.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(check.severity.color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(check.severity == .warning ? Theme.yellow.opacity(0.24) : check.severity.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(check.detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if check.severity != .ok {
                Text(check.severity == .critical ? "直连风险" : "提示")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(check.severity.color)
            }
        }
        .padding(.vertical, 7)
    }
}

struct EventRow: View {
    let event: GuardEvent
    var showDate: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(event.severity.indicatorColor)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(event.detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(showDate ? GuardFormat.dateTime(event.time) : GuardFormat.time(event.time))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.vertical, 8)
    }
}

struct FindingRow: View {
    let finding: TrafficFinding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.verdict.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isAttention ? Theme.warningInk : finding.verdict.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isAttention ? Theme.yellow : finding.verdict.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(finding.host):\(finding.port)")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Badge(text: finding.verdict.title, color: finding.verdict.color)
                    Spacer(minLength: 4)
                    Text(finding.process)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Text(finding.chain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if finding.verdict != .ok {
                    Text(finding.note)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(finding.verdict.color)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var isAttention: Bool { finding.verdict == .warning || finding.verdict == .violation }
}

/// 统一的按钮。样式见 GuardButtonStyle；需要强调的操作用 prominent（实心底色）。
struct ActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let icon: String
    var tint: Color? = nil
    var prominent: Bool = false
    var fullWidth: Bool = false
    let action: () -> Void

    var body: some View {
        let foreground = prominent && tint != nil ? Color.white : (tint ?? Theme.text)
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(GuardButtonStyle(tint: tint, prominent: prominent))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct SidebarButton: View {
    let item: SidebarItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
            }
            // .plain 按钮只在不透明像素上响应点击；Spacer 和内边距是透明的，
            // 点在那里会落到窗口背景上（isMovableByWindowBackground）变成拖动窗口。
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct CriticalBanner: View {
    let checks: [GuardCheck]
    let enforcing: Bool
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: compact ? 20 : 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: compact ? 32 : 42, height: compact ? 32 : 42)
                .background(Theme.red, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("严重风险 · 请立即检查")
                    .font(.system(size: compact ? 12 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.red)
                Text(enforcing ? "流量可能绕过 Clash，将自动关闭被管理的 Claude" : "流量可能绕过 Clash")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                if !enforcing {
                    Text("保护未开启，不会自动关闭 Claude")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.red)
                }
                ForEach(Array(checks.prefix(3))) { check in
                    Text("\(check.title)：\(check.detail)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                }
                if checks.count > 3 {
                    Text("另有 \(checks.count - 3) 项风险，请查看运行状态")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stableGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Theme.red.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.red.opacity(0.65), lineWidth: 1.5))
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let detail: String
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: compact ? 22 : 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondary)
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 16 : 40)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: mono ? .monospaced : .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}
