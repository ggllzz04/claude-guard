import SwiftUI
import AppKit
import GuardKit

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xff) / 255.0
        let g = CGFloat((hex >> 8) & 0xff) / 255.0
        let b = CGFloat(hex & 0xff) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// 每个颜色只创建一次（static let），名字固定；旧版每次都用 UUID 生成新名字。
private func guardDynamic(_ name: String, light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name("claude-guard-\(name)")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

enum Theme {
    // 窗口底色是不透明的固定颜色。玻璃折射的是它，所以窗口失去焦点时颜色不会变
    // （之前底下是系统的半透明窗口材质，失焦时系统会换掉它的着色，玻璃跟着变色）。
    static let bgTop = guardDynamic("bgTop", light: NSColor(hex: 0xF4F6FA), dark: NSColor(hex: 0x14161B))
    static let bgBottom = guardDynamic("bgBottom", light: NSColor(hex: 0xE8ECF3), dark: NSColor(hex: 0x0E1014))
    static let sidebar = guardDynamic("sidebar", light: NSColor(hex: 0xECEFF4), dark: NSColor(hex: 0x111317))

    static let stroke = guardDynamic("stroke", light: NSColor(hex: 0x0A0F17, alpha: 0.08),
                                     dark: NSColor(hex: 0xFFFFFF, alpha: 0.08))
    static let card = guardDynamic("card", light: NSColor(hex: 0xFFFFFF, alpha: 0.72),
                                   dark: NSColor(hex: 0x1E2128, alpha: 0.78))

    static let text = guardDynamic("text", light: NSColor(hex: 0x1A1F2B), dark: NSColor(hex: 0xF2F4F8))
    static let secondary = guardDynamic("secondary", light: NSColor(hex: 0x5B6678), dark: NSColor(hex: 0x9AA3B2))
    static let tertiary = guardDynamic("tertiary", light: NSColor(hex: 0x8A94A6), dark: NSColor(hex: 0x6B7385))

    static let green = guardDynamic("green", light: NSColor(hex: 0x16A34A), dark: NSColor(hex: 0x4ADE80))
    static let amber = guardDynamic("amber", light: NSColor(hex: 0x8A6100), dark: NSColor(hex: 0xFACC15))
    // 灯与文字分开：文字需要对比度，菜单栏指示灯必须始终是亮黄色。
    static let yellow = Color(hex: 0xFACC15)
    static let warningInk = Color(hex: 0x594000)
    static let red = guardDynamic("red", light: NSColor(hex: 0xDC2626), dark: NSColor(hex: 0xF87171))
    static let blue = guardDynamic("blue", light: NSColor(hex: 0x2563EB), dark: NSColor(hex: 0x60A5FA))
    static let teal = guardDynamic("teal", light: NSColor(hex: 0x0D9488), dark: NSColor(hex: 0x5EEAD4))
}

extension GuardState {
    var indicatorColor: Color { self == .attention ? Theme.yellow : color }

    var color: Color {
        switch self {
        case .protected: return Theme.green
        case .attention: return Theme.amber
        case .blocked: return Theme.red
        case .disabled: return Theme.tertiary
        case .unknown: return Theme.blue
        }
    }

    var icon: String {
        switch self {
        case .protected: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.shield.fill"
        case .blocked: return "xmark.shield.fill"
        case .disabled: return "shield.slash.fill"
        case .unknown: return "shield.lefthalf.filled"
        }
    }
}

extension Severity {
    var indicatorColor: Color { self == .warning ? Theme.yellow : color }

    var color: Color {
        switch self {
        case .ok: return Theme.green
        case .warning: return Theme.amber
        case .critical: return Theme.red
        }
    }
}

extension Verdict {
    var color: Color {
        switch self {
        case .ok: return Theme.green
        case .allowedDomestic: return Theme.blue
        case .allowedExternal: return Theme.blue
        case .warning: return Theme.amber
        case .violation: return Theme.amber
        }
    }

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .allowedDomestic: return "house.fill"
        case .allowedExternal: return "arrow.up.right.square.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .violation: return "exclamationmark.triangle.fill"
        }
    }
}

/// 菜单栏弹出面板仍用系统 popover 材质（它本来就是浮层，失焦即关闭）。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// 窗口底色：不透明的淡渐变，给玻璃一点可以折射的层次。
struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// 卡片：系统 Liquid Glass 的形状和高光，加一层固定颜色的底。
/// 只用 .regular 玻璃时，窗口失去焦点后系统会把玻璃换成灰色的非活跃材质（controlActiveState 改不了它），
/// 看起来就是“一失焦颜色就变”。底色是固定的，玻璃只在上面加高光和边缘，失焦前后颜色一致。
/// 旧版的 24pt 大阴影和额外描边也去掉了。
struct GlassCardModifier: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.card))
            .glassEffect(.clear, in: shape)
    }
}

/// 小元素（胶囊、圆形徽标、横幅）用的玻璃：同样先垫固定底色，可选一层状态色。
struct StableGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(Theme.card)
                    if let tint { shape.fill(tint) }
                }
            }
            .glassEffect(.clear, in: shape)
    }
}

extension View {
    func glassCard(padding: CGFloat = 18, radius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(padding: padding, radius: radius))
    }

    func stableGlass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(StableGlass(shape: shape, tint: tint))
    }
}

/// 按钮：固定底色 + 玻璃高光，按下时变暗。系统的 .glass / .glassProminent 在窗口失焦时会被换成灰色，
/// 主按钮的绿色、红色会突然褪掉，所以不用。
struct GuardButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if prominent, let tint {
                        shape.fill(tint)
                    } else {
                        shape.fill(Theme.card)
                    }
                    if configuration.isPressed {
                        shape.fill(Color.black.opacity(0.10))
                    }
                }
            }
            .glassEffect(.clear.interactive(), in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
