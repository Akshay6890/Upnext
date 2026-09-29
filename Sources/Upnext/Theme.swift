import AppKit
import SwiftUI

/// Colours from the app icon (Design/AppIcon.svg).
enum Brand {
    /// The icon's arrow.
    static let blue = Color(red: 0x6F / 255, green: 0xA8 / 255, blue: 0xF5 / 255)
    /// The icon's tile, top and bottom.
    static let graphiteTop = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
    static let graphiteBottom = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x21 / 255)
    /// Dark text on blue buttons (white on this blue is too low-contrast).
    static let ink = Color(red: 0x0B / 255, green: 0x14 / 255, blue: 0x22 / 255)

    static let cardFill = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)
}

// MARK: - Window chrome

/// A translucent, blurred window background tinted with the icon's graphite.
struct GlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(colors: [Brand.graphiteTop.opacity(0.62), Brand.graphiteBottom.opacity(0.80)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// Makes the hosting window see-through with a transparent title bar, so the
/// glass background runs edge to edge.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        // The header shows the name; `.toolbar(removing: .title)` needs macOS 15.
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
    }
}

// MARK: - Pointer

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view.
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: (enabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - Button styles

/// Rounded pill button. Prominent = the icon's blue; otherwise frosted glass.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(prominent ? Brand.ink : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Color.white.opacity(0.09)))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(prominent ? Color.clear : Brand.hairline, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
                .pointingHandCursor(isEnabled)
        }
    }
}

/// Plain blue text, like a link.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Brand.blue)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(Rectangle())
                .pointingHandCursor(isEnabled)
        }
    }
}

/// Round frosted icon button (toolbar refresh, cancel, …).
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Circle().strokeBorder(Brand.hairline, lineWidth: 1))
            .contentShape(Circle())
            .pointingHandCursor()
    }
}

/// A frosted card that groups rows, echoing the icon's hairline border.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1)
            )
    }
}
