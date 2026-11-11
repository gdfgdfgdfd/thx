import SwiftUI
import UIKit

extension View {
    /// Liquid Glass where the system has it (iOS 26), a blurred translucent card before that.
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
    }

    /// Rounded card used for code, tool lists and other blocks inside the transcript.
    func card(_ palette: Palette, radius: CGFloat = Metrics.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(palette.code)
            .clipShape(shape)
            .overlay { shape.stroke(palette.edge, lineWidth: 0.5) }
    }
}

enum Metrics {
    static let cardRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 18
    static let composerRadius: CGFloat = 24
    static let barHeight: CGFloat = 38
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        // The glass API ships with the iOS 26 SDK; older Xcode versions build the fallback only.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(liquidGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            content.background { FrostedShape(shape: shape, tint: tint) }
        }
        #else
        content.background { FrostedShape(shape: shape, tint: tint) }
        #endif
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

private struct FrostedShape<S: Shape>: View {
    let shape: S
    let tint: Color?

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            if let tint { shape.fill(tint.opacity(0.22)) }
            shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// Copies text and confirms it, so nothing has to be selected by hand.
struct CopyButton: View {
    let text: String
    let palette: Palette
    var label: String?
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.snappy(duration: 0.2)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                if let label { Text(copied ? "Copied" : label) }
            }
            .font(palette.small)
            .foregroundStyle(copied ? palette.success : palette.dim)
            .padding(.horizontal, 8)
            .frame(minWidth: 32, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copied) { _, isCopied in isCopied }
        .accessibilityLabel(label ?? "Copy")
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(palette.small)
                .foregroundStyle(palette.dim)
                .frame(minWidth: 32, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
