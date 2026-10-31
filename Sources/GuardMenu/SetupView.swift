import AppKit
import SwiftUI

@MainActor
final class SetupController: ObservableObject {
    @Published var installing = false
    @Published var error: String?
    @Published var complete = false
    private var window: NSWindow?

    static var needsSetup: Bool {
        let installed = try? String(contentsOfFile: "/Library/Application Support/Claude Guard/installed-version", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return installed != version || !FileManager.default.fileExists(atPath: "/var/run/com.local.claudeguard.sock")
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置 Claude Guard"
        window.contentView = NSHostingView(rootView: SetupView(controller: self))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func install() {
        guard !installing else { return }
        guard let resources = Bundle.main.resourceURL else { return }
        installing = true
        error = nil
        let scriptPath = resources.appendingPathComponent("Installer/setup-install.sh").path
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/bin/bash " + shellQuote(scriptPath)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Claude Guard 需要安装本地守护进程和 IPv6 防护。\""
        Task {
            let failure = await Task.detached { () -> String? in
                var detail: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&detail)
                if let detail {
                    if (detail[NSAppleScript.errorNumber] as? Int) == -128 { return "已取消授权，可以稍后重试。" }
                    return detail[NSAppleScript.errorMessage] as? String ?? "初始化失败，请重试。"
                }
                return script == nil ? "无法打开系统授权窗口。" : nil
            }.value
            self.installing = false
            if let failure { self.error = failure; return }
            self.complete = true
            // An older menu agent may still own a running copy of the previous binary.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.claudeguard.app")
                where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.terminate()
            }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Claude Guard.app"), configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error { self.error = error.localizedDescription }
                    else { NSApp.terminate(nil) }
                }
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var controller: SetupController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSImage(named: "BrandIcon") ?? NSApp.applicationIconImage)
                .resizable().frame(width: 82, height: 82)
            Text("为保护准备好环境").font(.system(size: 27, weight: .bold))
            Text("一次初始化，此后在菜单栏持续守护。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("安装到“应用程序”，设置登录时启动", systemImage: "app.badge.checkmark")
                Label("安装本地守护进程与 IPv6 防护", systemImage: "network.badge.shield.half.filled")
                Label("保留已有的保护设置和节点批准", systemImage: "checkmark.circle")
            }.font(.system(size: 14))
            Text("下一步由 macOS 请求管理员密码；应用不读取或保存密码。Clash 需已安装，首次使用后请按面板提示检查 TUN、分流规则并确认 AI 节点。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                if controller.installing { ProgressView().controlSize(.small); Text("正在初始化…").font(.caption) }
                Spacer()
                Button(controller.installing ? "请完成系统授权" : "初始化并安装") { controller.install() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(controller.installing)
            }
        }.padding(32).frame(width: 560, height: 510)
    }
}
