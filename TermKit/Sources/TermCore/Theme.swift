import Foundation

/// Colour palette as 0xRRGGBB values so the core stays UI-framework free.
public struct Theme: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    /// The page behind the chat and the sheets.
    public var background: UInt32
    /// Raised elements: the message box, the user's own messages, chips and list rows.
    public var surface: UInt32
    /// Blocks inside the chat: code and tool activity.
    public var card: UInt32
    public var sidebar: UInt32
    /// Hairlines around cards and fields.
    public var border: UInt32
    public var text: UInt32
    public var dim: UInt32
    public var accent: UInt32
    public var error: UInt32
    public var success: UInt32
    /// Phosphor-style glow behind text.
    public var glow: Bool

    public static let dark = Theme(
        id: "dark", name: "Dark", isDark: true,
        background: 0x1C1C1B, surface: 0x2C2C2A, card: 0x242423, sidebar: 0x212120, border: 0x3C3B38,
        text: 0xEEECE5, dim: 0x9C9A92, accent: 0xD97757, error: 0xE5675F, success: 0x78B98A, glow: false)

    public static let light = Theme(
        id: "light", name: "Light", isDark: false,
        background: 0xFAF9F5, surface: 0xFFFFFF, card: 0xF0EEE6, sidebar: 0xF4F2EC, border: 0xDEDCD1,
        text: 0x1F1E1D, dim: 0x76746C, accent: 0xC96442, error: 0xB93A32, success: 0x2F7D4F, glow: false)

    public static let crtGreen = Theme(
        id: "crt-green", name: "CRT Green", isDark: true,
        background: 0x020A04, surface: 0x06180B, card: 0x041208, sidebar: 0x041208, border: 0x124A22,
        text: 0x4AF07A, dim: 0x24914A, accent: 0xB6FFC8, error: 0xFF6B5E, success: 0x4AF07A, glow: true)

    public static let crtAmber = Theme(
        id: "crt-amber", name: "CRT Amber", isDark: true,
        background: 0x0B0700, surface: 0x1A1103, card: 0x140D02, sidebar: 0x140D02, border: 0x4D340A,
        text: 0xFFB43C, dim: 0xA06A14, accent: 0xFFE2A8, error: 0xFF6B5E, success: 0xFFB43C, glow: true)

    public static let all: [Theme] = [.dark, .light, .crtGreen, .crtAmber]

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .dark
    }
}
