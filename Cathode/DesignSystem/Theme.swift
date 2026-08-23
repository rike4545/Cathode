import SwiftUI

/// Cathode's palette.
///
/// The app is an instrument panel, so the design leans on a dark "phosphor"
/// ground with a small set of saturated signal colours that always mean the same
/// thing: cyan is downlink, violet is uplink, green is healthy, amber is
/// degraded, coral is failed. Light mode inverts the ground but keeps the signal
/// hues stable — a green number must not change meaning when the sun comes up.
///
/// Colours are defined in code rather than an asset catalog so each one can
/// document what it is *for*, and so the two schemes stay visibly paired.
extension Color {
    /// Builds a colour that resolves differently in light and dark.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: Ground and surfaces

    /// The window ground behind everything. Near-black with a faint cyan cast in dark.
    static let ground = adaptive(light: 0xF2F5F4, dark: 0x06090B)
    /// Default card surface.
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x0E1417)
    /// A card sitting on top of another card.
    static let surfaceRaised = adaptive(light: 0xF7F9F9, dark: 0x151D21)
    /// Insets, wells, chart backgrounds.
    static let surfaceSunken = adaptive(light: 0xEBEFEF, dark: 0x0A0F12)
    /// Hairlines and card borders.
    static let hairline = adaptive(light: 0xE0E5E5, dark: 0x1E272B)
    /// A stronger divider, for section breaks.
    static let hairlineStrong = adaptive(light: 0xCBD3D3, dark: 0x2A363B)

    // MARK: Text

    static let ink = adaptive(light: 0x0C1214, dark: 0xEEF4F3)
    static let inkSecondary = adaptive(light: 0x59676B, dark: 0x93A5A9)
    static let inkTertiary = adaptive(light: 0x8B9A9E, dark: 0x5D6E73)

    // MARK: Signal colours
    //
    // Each is tuned twice: the dark variant is the phosphor, the light variant
    // is darkened enough to hold contrast on white.

    /// Downlink. The dominant colour in the app.
    static let downlink = adaptive(light: 0x0E86B8, dark: 0x47C7F5)
    /// Uplink. Always paired with, and subordinate to, downlink.
    static let uplink = adaptive(light: 0x6A47C4, dark: 0xA98BFF)
    /// Latency and timing.
    static let latency = adaptive(light: 0xB06A00, dark: 0xFFC46B)
    /// Power draw.
    static let power = adaptive(light: 0xA23C7B, dark: 0xF58FC8)
    /// Healthy / nominal.
    static let good = adaptive(light: 0x0B8A5B, dark: 0x4AE3A0)
    /// Degraded but working.
    static let warn = adaptive(light: 0xA86800, dark: 0xFFB84A)
    /// Failed.
    static let bad = adaptive(light: 0xC03535, dark: 0xFF6B6B)
    /// Inactive / not applicable.
    static let idle = adaptive(light: 0x8B9A9E, dark: 0x5D6E73)
    /// Obstruction overlays on the sky dome.
    static let obstruction = adaptive(light: 0xD24A2E, dark: 0xFF7A55)

    static func tone(_ tone: Tone) -> Color {
        switch tone {
        case .good: .good
        case .warn: .warn
        case .bad: .bad
        case .idle: .idle
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// Type scale.
///
/// Telemetry readouts use monospaced digits everywhere so a changing number does
/// not shift the layout under the reader's eye — the single most important
/// typographic rule in a live dashboard.
extension Font {
    /// The hero number on a stat tile.
    static let readoutLarge = Font.system(size: 38, weight: .medium, design: .rounded)
        .monospacedDigit()
    /// A secondary readout.
    static let readout = Font.system(size: 22, weight: .medium, design: .rounded)
        .monospacedDigit()
    /// Inline numerals in dense lists.
    static let readoutSmall = Font.system(size: 15, weight: .medium, design: .rounded)
        .monospacedDigit()
    /// Units, appended to a readout.
    static let unit = Font.system(size: 13, weight: .semibold, design: .rounded)
    /// Section and card titles.
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    /// The all-caps micro-label above a value.
    static let label = Font.system(size: 10, weight: .bold)
    /// Monospaced technical text: IDs, versions, raw fields.
    static let technical = Font.system(size: 12, weight: .regular, design: .monospaced)
}

/// Layout constants, so spacing stays on a grid across every screen.
enum Metrics {
    static let cardRadius: CGFloat = 18
    static let innerRadius: CGFloat = 12
    static let gutter: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
}

/// A subtle scanline texture, used sparingly behind hero readouts.
///
/// The name of the app earns exactly one CRT reference; anything more would get
/// in the way of reading numbers, which is the actual job.
struct ScanlineOverlay: View {
    var opacity: Double = 0.035
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let spacing: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.white.opacity(opacity)))
                    y += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .blendMode(.overlay)
    }
}
