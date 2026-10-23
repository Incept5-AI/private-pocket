import SwiftUI

/// The app's palette: one family of colour on ink, each hue at a like lightness and
/// each with its own dark tint for type. Teal is anything you can tap and the time
/// before a conversation; amber is the card's light and the time during; cobalt is
/// work and the day at six; coral is life; lilac is what the app noticed; paper is
/// what was set. The light's colours (`LightDot`, `Lamp`) are the device's and stay.
enum Brand {
    // Ground and surfaces: ink, not black.
    static let ink = Color(hex: 0x0F1220)
    static let ground = ink
    static let surface = Color(hex: 0x1A1E31)
    static let raised = Color(hex: 0x242945)
    static let hairline = Color(hex: 0x2E3450)
    // Type.
    static let text = Color(hex: 0xEEF0F6)
    static let textSecondary = Color(hex: 0xB9C0D1)
    static let muted = Color(hex: 0x8B93A8)
    static let dim = Color(hex: 0x6B7490)
    /// Anything you can tap, and dark text on it.
    static let act = Color(hex: 0x2BA39A)
    static let onAct = Color(hex: 0x06302D)
    /// Recording: the card's amber light, and dark text on it.
    static let record = Color(hex: 0xF5B335)
    static let onRecord = Color(hex: 0x2A1B00)
    /// The two halves of a day.
    static let work = Color(hex: 0x3457D5)
    static let onWork = Color(hex: 0xFFFFFF)
    static let life = Color(hex: 0xF07A5A)
    static let onLife = Color(hex: 0x3B1208)
    /// What the app noticed.
    static let notice = Color(hex: 0xB197F2)
    static let onNotice = Color(hex: 0x221244)
    /// What was set: the morning page, a sealed clip.
    static let paper = Color(hex: 0xF2EDE3)
    static let onPaper = Color(hex: 0x16151A)
    static let paperMuted = Color(hex: 0x6E6A72)
    /// States: kept and done share teal; overdue and wrong share coral.
    static let good = act
    static let bad = life
    /// Speaker names, in order of first turn.
    static let speakers: [Color] = [work, life, act, Color(hex: 0xF5B335), notice,
                                    Color(hex: 0x6FC3BC), Color(hex: 0xE8A0C8), Color(hex: 0x8FA8F0)]
}

extension Color {
    /// `Color(hex: 0x2BA39A)`, sRGB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
