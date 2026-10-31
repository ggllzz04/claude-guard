import SwiftUI
import AppKit
import GuardKit

/// 设置自动保存：开关、选项一改就提交给守护；滑块松手后提交。
///
/// 草稿只属于本页（拨开关、拖滑块只重绘这一页；旧版草稿在 AppState 上，每次改动整个窗口都重绘，设置页因此很卡）。
/// 用 @StateObject 而不是 @State：这台机器的 Command Line Tools 没有 SwiftUI 宏插件，@State 编译不过。
///
/// 提交是串行的：同一时间只有一个保存请求在途；在途期间又改了，等它返回后再提交最新的草稿。
/// 守护返回的设置（会把检查间隔夹到合法范围）只在本页没有更新的修改时才覆盖草稿，避免把刚拨的开关弹回去。
@MainActor
final class SettingsAutoSaver: ObservableObject {
    @Published var draft: GuardSettings = .default
    @Published var proxyGroupInput = GuardSettings.defaultProxyGroup
    @Published private(set) var loaded = false
    @Published private(set) var status: Status = .idle

    enum Status: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private weak var state: AppState?
    private var inFlight: GuardSettings?
    private var observedProxyGroup: String?
    private var debounce: Task<Void, Never>?

    func attach(_ state: AppState) {
        self.state = state
        sync(from: state.snapshot?.settings)
    }

    /// 守护那边的设置变了（别处改的，或轮询带回来的）：本页没有待提交的修改时才跟着更新，
    /// 否则会把刚拨的开关弹回旧值。
    func sync(from settings: GuardSettings?) {
        guard let settings else { return }
        // 轮询只同步已保存的组名，保留用户尚未点“应用”的输入。
        if observedProxyGroup == nil || proxyGroupInput == observedProxyGroup {
            proxyGroupInput = settings.proxyGroup
        }
        observedProxyGroup = settings.proxyGroup
        if !loaded || (inFlight == nil && debounce == nil) {
            draft = settings
            loaded = true
        }
    }

    /// 草稿变化后调用。delay 用于滑块拖动中，松手时传 0。
    func changed(delay: TimeInterval = 0) {
        guard loaded else { return }
        debounce?.cancel()
        if delay <= 0 {
            debounce = nil
            submit()
        } else {
            debounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.debounce = nil
                self?.submit()
            }
        }
    }

    func applyProxyGroup() {
        guard loaded, inFlight == nil, state?.snapshot?.selectorGroups != nil,
              let settings = state?.snapshot?.settings,
              proxyGroupInput != settings.proxyGroup,
              !proxyGroupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.proxyGroup = proxyGroupInput
        draft.enforce = false
        draft.approvedNodeName = ""
        draft.approvedNodeType = ""
        draft.approvedFingerprint = nil
        changed()
    }

    private func submit() {
        guard let state, inFlight == nil else { return }
        guard draft != state.snapshot?.settings else {
            if status == .saving { status = .saved }
            return
        }
        let sending = draft
        inFlight = sending
        status = .saving
        state.saveSettings(sending) { [weak self] ok in
            guard let self else { return }
            self.inFlight = nil
            let confirmed = state.snapshot?.settings
            if !ok {
                // 保存失败：回到守护实际在用的设置，界面不能显示一个没生效的开关状态。
                if let confirmed { self.draft = confirmed }
                self.status = .failed(state.lastError ?? "保存失败")
                return
            }
            if self.draft == sending {
                // 没有更新的修改：采用守护规范化后的值（例如检查间隔被夹到 0.25…10 秒）。
                if let confirmed { self.draft = confirmed }
                self.status = .saved
            } else {
                // 等待期间又改了：继续提交最新的草稿。
                self.submit()
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @StateObject private var saver = SettingsAutoSaver()
    @StateObject private var confirm = EnableConfirmation()

    private var draft: GuardSettings { saver.draft }
    private var saved: GuardSettings { state.snapshot?.settings ?? .default }
    private var canEdit: Bool { state.daemonConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if !canEdit {
                    Text("当前是预览模式。安装守护进程后才能修改设置。")
                        .foregroundStyle(Theme.amber)
                } else {
                    switch saver.status {
                    case .idle, .saved:
                        Label("选项自动保存；策略组需点应用", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.tertiary)
                    case .saving:
                        Label("正在保存…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.secondary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.red)
                    }
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    protectionCard
                    auditCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 16) {
                    proxyGroupCard
                    nodeCard
                    aboutCard
                }
                .frame(width: 300, alignment: .top)
            }
        }
        .disabled(!canEdit)
        .onAppear { saver.attach(state) }
        .onChange(of: saved) { _, new in saver.sync(from: new) }
        .confirmationDialog("开启保护", isPresented: $confirm.presented) {
            Button("开启并关闭 Claude", role: .destructive) {
                saver.draft.enforce = true
                saver.changed()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirm.message)
        }
    }

    /// “启用保护”开关：当前就有会关闭 Claude 的问题、且被管理的 Claude 正在运行时，先确认。
    private var enforceBinding: Binding<Bool> {
        Binding(
            get: { saver.draft.enforce },
            set: { on in
                if on, let message = EnableConfirmation.warning(for: state.snapshot, settings: saver.draft) {
                    confirm.message = message
                    confirm.presented = true
                    return
                }
                saver.draft.enforce = on
                saver.changed()
            }
        )
    }

    /// 开关、选项：改了立即保存。
    private func autoSaving<T>(_ keyPath: WritableKeyPath<GuardSettings, T>) -> Binding<T> {
        Binding(
            get: { saver.draft[keyPath: keyPath] },
            set: { value in
                saver.draft[keyPath: keyPath] = value
                saver.changed()
            }
        )
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "shield.lefthalf.filled", title: "保护范围", tint: Theme.teal)

            ToggleRow(title: "启用保护",
                      detail: "发现流量可能绕过 Clash 直连时，立即关闭下面勾选的应用。关闭时只观察，不干预。",
                      isOn: enforceBinding)

            RowDivider()

            ToggleRow(title: "管理 Claude Desktop",
                      detail: "包括 Desktop 内置的 Claude Code。",
                      isOn: autoSaving(\.manageDesktop))
            ToggleRow(title: "管理 Claude Code（命令行）",
                      detail: "如果 Claude Code 配置了第三方 API，可以不管理它。不管理的应用不审计、也不会被关闭。",
                      isOn: autoSaving(\.manageCode))

            if draft.enforce && !draft.manageDesktop && !draft.manageCode {
                Text("保护已启用，但没有勾选任何应用。")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.amber)
            }

            RowDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text("什么情况会关闭 Claude")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Clash 连不上或不是 rule 模式、TUN 没开或路由没走 TUN、系统代理没指向 Clash、有全局 IPv6 但封锁没生效、AI 分组或 Claude 域名最终会直连。其余问题（节点变化、DNS、连接审计等）只提示。")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard(padding: 18, radius: 20)
    }

    private var auditCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "eye", title: "连接审计", tint: Theme.blue)

            SegmentedChoice(options: AuditMode.allCases.map { ($0, $0.title) },
                            selection: autoSaving(\.auditMode))

            Text(draft.auditMode == .standard
                 ? "国内和本地访问放行；国外连接走了别的节点只提示。"
                 : "所有没走 AI 的国外连接都标为异常。只提示，不会关闭 Claude。")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            RowDivider()

            ToggleRow(title: "出口探测",
                      detail: "每 5 分钟经 AI 节点请求一次 \(SystemProbe.egressProbeHost) 获取出口 IP，不访问 Claude 服务。",
                      isOn: autoSaving(\.canaryEnabled))
            ToggleRow(title: "通知",
                      detail: "风险、进程关闭和代理恢复时发送系统通知。",
                      isOn: autoSaving(\.notificationsEnabled))

            RowDivider()

            HStack {
                Text("检查间隔")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(String(format: "%.2f 秒", draft.pollInterval))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
            }
            // 拖动中只改草稿；松手后才保存，拖一下不会连发十几个请求。
            Slider(value: $saver.draft.pollInterval, in: 0.25...5, step: 0.25) { editing in
                if !editing { saver.changed() }
            }
            .tint(Theme.teal)
        }
        .glassCard(padding: 18, radius: 20)
    }

    private var proxyGroupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "point.3.connected.trianglepath.dotted", title: "目标策略组", tint: Theme.teal)
            LabeledValue(label: "当前", value: saved.proxyGroup)
            TextField("输入 Selector 名称", text: $saver.proxyGroupInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("目标 Selector 策略组名称")
            Menu("选择已有 Selector") {
                ForEach(state.snapshot?.selectorGroups ?? [], id: \.self) { name in
                    Button(name) { saver.proxyGroupInput = name }
                }
            }
            .disabled(state.snapshot?.selectorGroups?.isEmpty != false)
            if state.snapshot?.selectorGroups == nil {
                Text("尚未取得 Selector 列表；请等待 Clash 恢复，并确认守护已更新。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.amber)
            }
            ActionButton(title: "应用策略组", icon: "checkmark", tint: Theme.teal, fullWidth: true) {
                saver.applyProxyGroup()
            }
            .disabled(state.snapshot?.selectorGroups == nil || saver.status == .saving || state.pendingCommand != nil ||
                      saver.proxyGroupInput == saved.proxyGroup ||
                      saver.proxyGroupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("组名需与 Clash 中的 Selector 完全一致。切换会暂停保护、清除节点确认；检查新节点后再按需开启保护。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("此处只设置检查目标；分流规则需使用同一组名。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(padding: 16, radius: 20)
    }

    private var nodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "server.rack", title: "AI 节点", tint: Theme.teal) {
                if let node = state.snapshot?.node {
                    Badge(text: node.approved ? "已确认" : "待确认", color: node.approved ? Theme.green : Theme.amber)
                }
            }
            if let node = state.snapshot?.node, !node.name.isEmpty {
                VStack(spacing: 7) {
                    LabeledValue(label: "策略组", value: node.group)
                    LabeledValue(label: "节点", value: node.name)
                    LabeledValue(label: "已确认", value: saved.approvedNodeName.isEmpty ? "—" : saved.approvedNodeName)
                    LabeledValue(label: "指纹", value: node.fingerprint.map { String($0.prefix(16)) + "…" } ?? "无", mono: true)
                }
                Text("节点或配置变化只会提示，不会关闭 Claude。确认后作为新的基准。")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton(title: "确认当前节点", icon: "checkmark.seal.fill", tint: Theme.teal, fullWidth: true) {
                    state.approveCurrentNode()
                }
                .disabled(node.approved || state.pendingCommand != nil)
            } else {
                Text("等待 Clash 与 AI 节点状态")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .glassCard(padding: 16, radius: 20)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "info.circle", title: "守护", tint: Theme.secondary)
            VStack(spacing: 7) {
                LabeledValue(label: "模式", value: state.snapshot?.daemonMode.title ?? "预览模式")
                LabeledValue(label: "Clash", value: state.snapshot?.clashVersion ?? "—")
            }
            ActionButton(title: "打开 Clash 配置目录", icon: "folder", fullWidth: true) {
                let path = NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles"
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Text("Route Guard \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 本地运行，不上传数据")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.tertiary)
        }
        .glassCard(padding: 16, radius: 20)
    }
}

@MainActor
final class EnableConfirmation: ObservableObject {
    @Published var presented = false
    @Published var message = ""

    /// 开启保护会立刻生效：当前就有红色问题、且被管理的 Claude 在运行时，下一轮检查就会把它关掉。
    static func warning(for snapshot: Snapshot?, settings: GuardSettings) -> String? {
        guard let snapshot else { return nil }
        let critical = snapshot.checks.filter { $0.severity == .critical }
        let running = snapshot.processes.filter { settings.manages($0.app) }
        guard !critical.isEmpty, !running.isEmpty else { return nil }
        let reasons = critical.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n")
        let apps = Set(running.map(\.app.title)).sorted().joined(separator: "、")
        return "现在就有会关闭 Claude 的问题：\n\(reasons)\n\n开启后 \(apps) 会被立即关闭。"
    }
}

/// 自绘开关。系统 switch 在窗口失焦时会把“开”的颜色换成灰色，开和关看起来一样。
struct GuardSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    var title: String = ""

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? Theme.teal : Color.primary.opacity(0.14))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(Text(title))
        .accessibilityValue(on ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
    }
}

/// 自绘分段选择，理由同上：系统分段控件失焦时选中项会变灰。
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : Theme.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selected ? Theme.teal : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        // macOS 的 switch 紧跟在标签后面；标签短的那行开关会跑到中间。开关单独放、统一靠右。
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(GuardSwitchStyle(title: title))
        }
    }
}
