import SwiftUI

// Shared by the app and the widget extension: how a Pocket looks on screen.

enum LightState { case off, on, pairing, recording }

/// Mirrors the Pocket's status light: solid blue when paired and ready, blinking blue
/// when it needs pairing, pulsing amber while recording, dim when not connected.
struct LightDot: View {
    let state: LightState
    @State private var phase = false

    private var colour: Color {
        switch state {
        case .off: Color.white.opacity(0.35)
        case .on, .pairing: .blue
        case .recording: .orange
        }
    }
    private var animated: Bool { state == .pairing || state == .recording }

    var body: some View {
        Circle()
            .fill(colour)
            .opacity(state == .pairing && phase ? 0.15 : 1)
            .scaleEffect(state == .recording && phase ? 0.8 : 1)
            .shadow(color: state == .off ? .clear : colour.opacity(0.7), radius: 5)
            .animation(animated ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = animated }
            .onChange(of: state) {
                phase = false
                if animated { Task { @MainActor in phase = true } }
            }
    }
}

/// Colour from the advertised name (`PKT01_GREY_…`), so the card on screen matches
/// the one in hand. Unknown colours fall back to grey.
struct PocketLook {
    let fill: Color
    let ink: Color

    init(advertised: String) {
        let colour = advertised.split(separator: "_").dropFirst().first.map { $0.uppercased() } ?? ""
        let pair: (Color, Color) = switch colour {
        case "BLACK": (Color(white: 0.13), .white)
        case "WHITE": (Color(white: 0.93), Color(white: 0.12))
        case "SILVER": (Color(white: 0.78), Color(white: 0.1))
        case "BLUE", "NAVY": (Color(red: 0.16, green: 0.33, blue: 0.62), .white)
        case "GREEN": (Color(red: 0.2, green: 0.45, blue: 0.33), .white)
        case "RED": (Color(red: 0.66, green: 0.2, blue: 0.2), .white)
        case "PINK": (Color(red: 0.93, green: 0.7, blue: 0.76), Color(white: 0.12))
        case "ORANGE": (Color(red: 0.87, green: 0.47, blue: 0.2), .white)
        case "YELLOW", "GOLD": (Color(red: 0.9, green: 0.78, blue: 0.4), Color(white: 0.12))
        case "PURPLE": (Color(red: 0.42, green: 0.3, blue: 0.6), .white)
        default: (Color(red: 0.4, green: 0.42, blue: 0.45), .white)
        }
        fill = pair.0
        ink = pair.1
    }
}

enum PocketFacts {
    /// The Pocket records 32 kbps MP3: about 4,000 bytes a second, 14 MB an hour.
    static let bytesPerSecond = 4_000.0

    /// Storage as recording time, which is what it means on a card this size.
    static func hours(mib: Int) -> String {
        let h = Double(mib) * 1_048_576 / bytesPerSecond / 3_600
        let rounded: Double = h >= 1_000 ? (h / 100).rounded() * 100 : h >= 100 ? (h / 10).rounded() * 10 : h.rounded()
        if rounded < 1 { return "under an hour" }
        return "about \(Int(rounded).formatted()) hours"
    }

    /// "40 sec", "12 min", "1 hr 5 min".
    static func length(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) sec"
            : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
