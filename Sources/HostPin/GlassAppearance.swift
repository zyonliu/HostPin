import AppKit
import SwiftUI

struct GlassControls: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
    }
}

struct GlassControlSurface: ViewModifier {
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(enabled),
                                in: RoundedRectangle(cornerRadius: 7))
        } else {
            content
                .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: 7))
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12))
                }
        }
    }
}

struct NativeBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.material = material
    }

    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Keep the native title bar covered outside SwiftUI's content bounds.
            // A clear window leaves a hole above the sidebar in Settings.
            window?.backgroundColor = .windowBackgroundColor
        }
    }
}
