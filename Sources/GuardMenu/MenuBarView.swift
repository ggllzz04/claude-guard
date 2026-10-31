import SwiftUI
import AppKit
import GuardKit

/// 菜单栏弹出面板：只放状态、会关闭 Claude 的原因、节点和两个操作。
struct MenuBarView: View {
    @ObservedObject var state: AppState
    let openDashboard: () -> Void

    private var snapshot: Snapshot? { state.snapshot }

    private var keyChecks: [GuardCheck] {
        guard let checks = snapshot?.checks else { return [] }
        return ["tun", "routes", "node", "rules"].compactMap { id in checks.first { $0.id == id } }
    }

    private var criticalChecks: [GuardCheck] {
        snapshot?.checks.filter { $0.severity == .critical } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ShieldBadge(state: snapshot?.state ?? .unknown)
                    .scaleEffect(0.62)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot?.state.title ?? "检查中")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(snapshot?.state == .blocked ? Theme.red : Theme.text)
                    Text(snapshot?.stateSubtitle ?? "正在检查…")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !criticalChecks.isEmpty {
                CriticalBanner(checks: criticalChecks,
                               enforcing: snapshot?.daemonMode == .root && snapshot?.settings.enforce == true,
                               compact: true)
            } else if let warning = snapshot?.checks.first(where: { $0.severity == .warning }) {
                Label("\(warning.title)：\(warning.detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stableGlass(RoundedRectangle(cornerRadius: 12), tint: Theme.yellow.opacity(0.18))
            }

            VStack(spacing: 0) {
                ForEach(Array(keyChecks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { RowDivider() }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(check.severity.indicatorColor)
                            .frame(width: 6, height: 6)
                        Text(check.title)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Text(check.detail)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .stableGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                ActionButton(title: "打开面板", icon: "macwindow", tint: Theme.teal, prominent: true, fullWidth: true) {
                    openDashboard()
                }
                ActionButton(title: "封锁", icon: "hand.raised.fill", tint: Theme.red) {
                    state.blockClaude()
                }
                .disabled(!state.daemonConnected || state.pendingCommand != nil)
            }

            HStack {
                Text(snapshot?.clashVersion.map { "mihomo \($0)" } ?? "等待 Clash")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("退出 Route Guard") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .environment(\.controlActiveState, .key)
    }
}
