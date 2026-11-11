import SwiftUI
import TermCore

@main
struct TermAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// SwiftUI colours and fonts for the active theme.
struct Palette: Equatable {
    let theme: Theme
    /// The size of code and command text; prose and labels are sized relative to it.
    let fontSize: Double

    var background: Color { Color(hex: theme.background) }
    var surface: Color { Color(hex: theme.surface) }
    var card: Color { Color(hex: theme.card) }
    var sidebar: Color { Color(hex: theme.sidebar) }
    var border: Color { Color(hex: theme.border) }
    var text: Color { Color(hex: theme.text) }
    var dim: Color { Color(hex: theme.dim) }
    var accent: Color { Color(hex: theme.accent) }
    var error: Color { Color(hex: theme.error) }
    var success: Color { Color(hex: theme.success) }
    /// Ink on top of the accent colour.
    var onAccent: Color { theme.glow ? Color(hex: theme.background) : Color.white }
    /// Fill of a control that cannot be used right now.
    var inactive: Color { Color(hex: theme.text).opacity(0.1) }
    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }

    /// The conversation.
    var prose: Font { .system(size: fontSize + 3) }
    var proseBold: Font { .system(size: fontSize + 3, weight: .semibold) }
    var heading: Font { .system(size: fontSize + 5, weight: .semibold) }
    /// Buttons, menus and list rows.
    var label: Font { .system(size: fontSize + 2) }
    var labelBold: Font { .system(size: fontSize + 2, weight: .semibold) }
    var caption: Font { .system(size: fontSize) }
    /// Code, commands and their output.
    var mono: Font { .system(size: fontSize, design: .monospaced) }
    var monoBold: Font { .system(size: fontSize, weight: .semibold, design: .monospaced) }
    /// Code inside a sentence, sized to sit with the prose around it.
    var monoInline: Font { .system(size: fontSize + 2, design: .monospaced) }
}
