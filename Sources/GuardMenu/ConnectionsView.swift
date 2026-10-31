import SwiftUI
import GuardKit

@MainActor
final class ConnectionsFilterStore: ObservableObject {
    @Published var filter: FindingFilter = .all
}

struct ConnectionsView: View {
    @ObservedObject var state: AppState
    // 这台机器没有 SwiftUI 宏插件，@State 编译不过，界面状态用 @StateObject。
    @StateObject private var filterStore = ConnectionsFilterStore()
    private var filter: FindingFilter { filterStore.filter }

    private var all: [TrafficFinding] { state.snapshot?.findings ?? [] }

    private var findings: [TrafficFinding] {
        switch filter {
        case .all: return all
        case .attention: return all.filter { $0.verdict == .violation || $0.verdict == .warning }
        }
    }

    private var attentionCount: Int {
        all.filter { $0.verdict == .violation || $0.verdict == .warning }.count
    }

    private var unmanaged: [ClaudeApp] {
        guard let settings = state.snapshot?.settings else { return [] }
        return ClaudeApp.allCases.filter { !settings.manages($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SegmentedChoice(options: FindingFilter.allCases.map { item in
                    (item, item == .attention && attentionCount > 0 ? "\(item.title) \(attentionCount)" : item.title)
                }, selection: $filterStore.filter)
                Spacer()
                Text("只看目的地和出口，不读取内容。连接审计只提示，不会关闭 Claude。")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
            }

            if !unmanaged.isEmpty {
                Text("未管理：\(unmanaged.map(\.title).joined(separator: "、"))（不审计）")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            }

            if findings.isEmpty {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: state.snapshot?.processes.isEmpty != false ? "没有需要审计的 Claude" : "这里很安静",
                    detail: state.snapshot?.processes.isEmpty != false
                        ? "被管理的 Claude 运行后，这里会显示它的连接和出口"
                        : "当前没有符合筛选条件的连接"
                )
                .glassCard(padding: 16, radius: 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                        if index > 0 { RowDivider() }
                        FindingRow(finding: finding)
                    }
                }
                .glassCard(padding: 16, radius: 20)
            }
        }
    }
}

struct EventsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // 守护按时间先后返回；和总览“最近活动”一致，最新的放最上面。
        let events = Array((state.snapshot?.events ?? []).reversed())
        VStack(alignment: .leading, spacing: 14) {
            if events.isEmpty {
                EmptyStateView(icon: "sparkles", title: "还没有事件", detail: "Route Guard 会在这里记录重要的变化")
                    .glassCard(padding: 16, radius: 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { RowDivider() }
                        EventRow(event: event, showDate: true)
                    }
                }
                .glassCard(padding: 16, radius: 20)
            }
        }
    }
}
