import AppKit
import GuardKit

/// Let macOS allocate, restore and move the item (⌘-drag), including across displays.
@MainActor
final class MenuBarIconController: NSObject {
    private let item: NSStatusItem
    private var displayedState: GuardState?
    var button: NSStatusBarButton? { item.button }
    var onToggle: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: 30)
        super.init()
        item.autosaveName = "ClaudeGuard.StatusItem.v2"
        item.behavior = [.removalAllowed]
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(clicked)
            button.setAccessibilityLabel("Route Guard")
        }
        setState(.unknown)
    }

    func setState(_ state: GuardState) {
        guard displayedState != state else { return }
        displayedState = state
        let critical = state == .blocked
        item.length = critical ? 64 : 30
        button?.imagePosition = critical ? .imageLeading : .imageOnly
        button?.image = StatusIcon.image(for: state)
        button?.attributedTitle = NSAttributedString(
            string: critical ? "风险" : "",
            attributes: [.foregroundColor: NSColor.systemRed,
                         .font: NSFont.systemFont(ofSize: 11, weight: .bold)]
        )
        button?.toolTip = "Route Guard · \(state.title) · ⌘ 拖动调整位置"
        button?.setAccessibilityValue(state.title)
    }

    @objc private func clicked() { onToggle?() }
}
