import SwiftUI

/// The light's own colours, as the card shows them. Never restyled.
enum Lamp {
    static let ready = Color(hex: 0x0A84FF)
    static let recording = Color(hex: 0xFF9F0A)
    static let paused = Color(hex: 0xF2F2F7)
    static let charging = Color(hex: 0x30D158)
    static let updating = Color(hex: 0xBF5AF2)
    static let resetting = Color(hex: 0xFF453A)
}

/// The card drawn at its real proportions: portrait, the light top-left, the side
/// button and the switch on the right edge near the top. The Pocket screen shows the
/// real light on it; the walkthrough animates it.
struct PocketIllustration: View {
    /// The card's own colour (`PocketLook.fill`).
    var fill: Color = Color(red: 0.55, green: 0.56, blue: 0.59)
    /// The light's colour, nil when off.
    var light: Color? = nil
    /// Blinking (pairing, charging, updating, resetting) or pulsing (recording).
    var blink = false
    var pulse = false
    var buttonPressed = false
    /// The side switch: down is call, the contact mic.
    var switchDown = false

    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let radius = w * 0.095
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [fill.lighter(0.28), fill, fill.darker(0.38)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.5, y: 0.65)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: w * 0.16, y: w * 0.12)
                // The light.
                Circle()
                    .fill(light ?? Color.white.opacity(0.12))
                    .frame(width: w * 0.04, height: w * 0.04)
                    .shadow(color: (light ?? .clear).opacity(0.95), radius: w * 0.022)
                    .shadow(color: (light ?? .clear).opacity(0.45), radius: w * 0.07)
                    .opacity(blink && phase ? 0.1 : 1)
                    .scaleEffect(pulse && phase ? 0.78 : 1)
                    .offset(x: w * 0.096, y: w * 0.096)
                // The side button: press once to record.
                RoundedRectangle(cornerRadius: w * 0.015, style: .continuous)
                    .fill(LinearGradient(colors: [fill.darker(0.2), fill.lighter(0.25)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.032, height: h * 0.11)
                    .offset(x: w * 0.995 - (buttonPressed ? w * 0.014 : 0), y: h * 0.158)
                // The switch: up for audio, down for call.
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: w * 0.013, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                        .frame(width: w * 0.027, height: h * 0.077)
                    RoundedRectangle(cornerRadius: w * 0.009, style: .continuous)
                        .fill(Color(white: 0.84))
                        .frame(width: w * 0.018, height: h * 0.03)
                        .offset(y: switchDown ? h * 0.077 - h * 0.03 - h * 0.005 : h * 0.005)
                }
                .offset(x: w * 0.995, y: h * 0.305)
            }
            .animation(blink || pulse ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: phase)
            .animation(.spring(duration: 0.35), value: switchDown)
            .animation(.easeOut(duration: 0.12), value: buttonPressed)
            .onAppear { phase = blink || pulse }
            .onChange(of: blink || pulse) { _, on in
                phase = false
                if on { Task { @MainActor in phase = true } }
            }
        }
        .aspectRatio(230.0 / 366.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension Color {
    func lighter(_ amount: Double) -> Color { mix(with: .white, by: amount) }
    func darker(_ amount: Double) -> Color { mix(with: .black, by: amount) }
}
