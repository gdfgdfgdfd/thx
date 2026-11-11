import SwiftUI
import TermCore
import UIKit

enum Metrics {
    /// Left and right edge of the conversation.
    static let margin: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 20
    static let composerRadius: CGFloat = 26
    static let controlRadius: CGFloat = 10
    /// Height of the round buttons in the top bar.
    static let barButton: CGFloat = 40
}

extension View {
    /// Liquid Glass where the system has it (iOS 26), a blurred translucent card before that.
    /// Put it around controls, not inside a button's label.
    func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint))
    }

    /// Rounded card used for code, tool lists and other blocks inside the conversation.
    func card(_ palette: Palette, radius: CGFloat = Metrics.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(palette.card)
            .clipShape(shape)
            .overlay { shape.stroke(palette.border, lineWidth: 1) }
    }

    /// A filled rounded rectangle with a hairline around it: fields, chips and quiet buttons.
    func outlined(_ palette: Palette, fill: Color, radius: CGFloat = Metrics.controlRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape)
            .overlay { shape.stroke(palette.border, lineWidth: 1) }
    }

    /// Theme colours for the content of a sheet.
    func sheetPage(_ palette: Palette) -> some View {
        scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
    }
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        // The glass API ships with the iOS 26 SDK; older Xcode versions build the fallback only.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(liquidGlass(tint: tint), in: shape)
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
private func liquidGlass(tint: Color?) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
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

/// The app's mark: a burst of rounded rays.
struct Spark: Shape {
    var rays = 12

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<rays {
            let angle = Double(index) / Double(rays) * 2 * Double.pi
            let x = CGFloat(cos(angle))
            let y = CGFloat(sin(angle))
            path.move(to: CGPoint(x: center.x + x * radius * 0.22, y: center.y + y * radius * 0.22))
            path.addLine(to: CGPoint(x: center.x + x * radius * 0.9, y: center.y + y * radius * 0.9))
        }
        return path
    }
}

struct SparkMark: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Spark()
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Copies text and confirms it, so nothing has to be selected by hand.
struct CopyButton: View {
    let text: String
    let palette: Palette
    var label: String?
    var iconSize: CGFloat = 13
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
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: iconSize))
                    .contentTransition(.symbolEffect(.replace))
                if let label {
                    Text(copied ? "Copied" : label).font(palette.caption)
                }
            }
            .foregroundStyle(copied ? palette.success : palette.dim)
            .padding(.horizontal, 8)
            .frame(minWidth: 34, minHeight: 32)
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
    var iconSize: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundStyle(palette.dim)
                .frame(minWidth: 34, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
