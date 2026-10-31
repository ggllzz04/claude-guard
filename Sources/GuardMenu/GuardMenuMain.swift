import AppKit
import SwiftUI
import GuardKit


private var strongDelegate: AppDelegate?

@main
struct GuardMenuMain {
    @MainActor
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let state = AppState()
                await state.refresh()
                try? await Task.sleep(nanoseconds: 400_000_000)
                let content = DashboardView(state: state)
                    .frame(width: 1080, height: 720)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("snapshot: \(path)")
                } else {
                    fputs("snapshot failed\n", stderr)
                }
                exit(0)
            }
            RunLoop.main.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var menuBarIcon: MenuBarIconController?
    private var popover: NSPopover!
    private var window: NSWindow?
    private var activityToken: NSObjectProtocol?
    private let state = AppState()
    private let setup = SetupController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Route Guard 持续监控"
        )
        installMainMenu()
        menuBarIcon = MenuBarIconController()
        menuBarIcon?.setState(.unknown)
        menuBarIcon?.onToggle = { [weak self] in
            self?.togglePopover()
        }

        let hosting = NSHostingController(
            rootView: MenuBarView(state: state, openDashboard: { [weak self] in
                self?.openDashboard()
            })
        )
        // 面板高度跟着内容走（有红色原因时会变高）；不再写死 392pt。
        hosting.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting

        NotificationManager.shared.setup()
        state.onStateChange = { [weak self] snapshot in
            guard let self else { return }
            self.menuBarIcon?.setState(snapshot.state)
            NotificationManager.shared.notifyCritical(snapshot)
        }
        state.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if SetupController.needsSetup { self.setup.show() }
            else { self.openDashboard() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    // 原来写成 windowDidClose，NSWindowDelegate 没有这个方法，从未被调用；
    // 于是改成 orderOut 绕过，但 orderOut 只隐藏不关闭，每次重新打开都会新建一个窗口，
    // 隐藏的旧窗口连同 SwiftUI 视图树一直留在后台跟着刷新。现在走正常的 close。
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window?.contentView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func showSetup() { setup.show() }

    @objc private func closeDashboard() {
        window?.close()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Route Guard",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let setupItem = NSMenuItem(title: "初始化 / 修复环境…", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        appMenu.addItem(setupItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Route Guard",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(closeDashboard), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
    }

    @objc private func togglePopover() {
        guard let button = menuBarIcon?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func openDashboard() {
        if popover.isShown { popover.performClose(nil) }
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Route Guard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // 只有标题栏区域能拖动窗口；整窗可拖时，点在卡片空白处会变成拖窗口。
        window.isMovableByWindowBackground = false
        // 不透明的窗口底色：透明窗口下面是桌面，窗口失焦时系统会换掉玻璃的着色，看起来像变了颜色。
        window.isOpaque = true
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: 0x14161B) : NSColor(hex: 0xF4F6FA)
        }
        window.minSize = NSSize(width: 900, height: 620)
        let hostingView = NSHostingView(rootView: DashboardView(state: state))
        // 内容按窗口大小布局，不让 SwiftUI 的理想尺寸反过来撑大或居中窗口内容。
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(closeDashboard)
            closeButton.isEnabled = true
        }
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum StatusIcon {
    static func image(for state: GuardState) -> NSImage {
        let size = NSSize(width: state == .blocked ? 28 : 22, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 10, y: 18.2))
        shield.curve(to: NSPoint(x: 17, y: 15.3),
                     controlPoint1: NSPoint(x: 13.0, y: 17.6),
                     controlPoint2: NSPoint(x: 15.7, y: 16.5))
        shield.line(to: NSPoint(x: 17, y: 9.2))
        shield.curve(to: NSPoint(x: 10, y: 2.2),
                     controlPoint1: NSPoint(x: 17, y: 6.4),
                     controlPoint2: NSPoint(x: 13.6, y: 2.8))
        shield.curve(to: NSPoint(x: 3, y: 9.2),
                     controlPoint1: NSPoint(x: 6.4, y: 2.8),
                     controlPoint2: NSPoint(x: 3, y: 6.4))
        shield.line(to: NSPoint(x: 3, y: 15.3))
        shield.curve(to: NSPoint(x: 10, y: 18.2),
                     controlPoint1: NSPoint(x: 4.3, y: 16.5),
                     controlPoint2: NSPoint(x: 6.8, y: 17.6))
        shield.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 1.4
        shadow.shadowOffset = NSSize(width: 0, height: -0.4)
        shadow.set()
        NSColor.white.setFill()
        shield.fill()

        shield.lineWidth = 0.6
        NSColor.black.withAlphaComponent(0.28).setStroke()
        shield.stroke()

        // Negative-space G matches the application mark while retaining a white menu silhouette.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        let g = NSBezierPath()
        g.move(to: NSPoint(x: 12.8, y: 13.7))
        g.curve(to: NSPoint(x: 6.7, y: 11.6), controlPoint1: NSPoint(x: 9.5, y: 16.5), controlPoint2: NSPoint(x: 6.7, y: 14.5))
        g.curve(to: NSPoint(x: 10, y: 5.8), controlPoint1: NSPoint(x: 6.7, y: 9), controlPoint2: NSPoint(x: 7.8, y: 7.2))
        g.curve(to: NSPoint(x: 13.2, y: 10.1), controlPoint1: NSPoint(x: 12.4, y: 7.3), controlPoint2: NSPoint(x: 13.2, y: 8.5))
        g.line(to: NSPoint(x: 10.3, y: 10.1))
        g.lineWidth = 1.65
        g.lineCapStyle = .round
        g.lineJoinStyle = .round
        g.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 亮黄色比文字色更醒目；严重风险改成更大的红色感叹号徽标。
        let diameter: CGFloat = state == .blocked ? 12 : (state == .attention ? 8 : 6)
        let dotRect = NSRect(x: state == .blocked ? 15 : 13, y: 1.5, width: diameter, height: diameter)
        let dotBackground = NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.8, dy: -0.8))
        NSColor.black.withAlphaComponent(0.35).setFill()
        dotBackground.fill()

        let dot = NSBezierPath(ovalIn: dotRect)
        // 菜单栏可能是深色壁纸配浅色 App，使用固定信号色，不取窗口外观。
        let signal: NSColor
        switch state {
        case .attention: signal = NSColor(hex: 0xFACC15)
        case .blocked: signal = NSColor(hex: 0xEF4444)
        case .protected: signal = NSColor(hex: 0x22C55E)
        case .disabled: signal = NSColor(hex: 0x94A3B8)
        case .unknown: signal = NSColor(hex: 0x60A5FA)
        }
        signal.setFill()
        dot.fill()

        if state == .blocked {
            // 直接绘制，避免小字号字体基线导致感叹号在菜单栏中偏移。
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: dotRect.midX - 0.8, y: 6.4, width: 1.6, height: 4.5),
                         xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(ovalIn: NSRect(x: dotRect.midX - 0.9, y: 3.8, width: 1.8, height: 1.8)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
