import SwiftUI

/// The app's palette: concept D, "Graphite and Cyan". A graphite ground, cyan for
/// anything you can tap, and the card's own amber for recording. Blue is work, pink is
/// life. The light's colours (`LightDot`) are the device's and stay as they are.
enum Brand {
    // Ground and surfaces.
    static let ground = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x16191E)
    static let raised = Color(hex: 0x1F252C)
    static let hairline = Color(hex: 0x262B33)
    // Type.
    static let text = Color(hex: 0xE8EDF2)
    static let textSecondary = Color(hex: 0xB6C0CA)
    static let muted = Color(hex: 0x7F8A96)
    static let dim = Color(hex: 0x768290)
    /// Anything you can tap, and dark text on it.
    static let act = Color(hex: 0x2AD4FF)
    static let onAct = Color(hex: 0x04202A)
    /// Recording: the card's amber light, and dark text on it.
    static let record = Color(hex: 0xFF9F0A)
    static let onRecord = Color(hex: 0x1A1200)
    /// The two halves of a day.
    static let work = Color(hex: 0x5B8DEF)
    static let life = Color(hex: 0xF472B6)
    static let good = Color(hex: 0x30D158)
    static let bad = Color(hex: 0xFF453A)
    /// Speaker names, in order of first turn.
    static let speakers: [Color] = [work, life, act, Color(hex: 0xFFD08A), good,
                                    Color(hex: 0xB89CFF), Color(hex: 0xFF8A65), Color(hex: 0x8FD8C8)]
}

extension Color {
    /// `Color(hex: 0x2AD4FF)`, sRGB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
