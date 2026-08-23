import SwiftUI

/// The dashboard's hero: a health score, the link state, and the two numbers
/// people check first.
///
/// The ring is a single 0–100 figure rather than a wall of gauges, because the
/// question someone opens this app to answer is "is it fine?" — the detail is
/// one scroll away for when the answer is no.
struct HealthRing: View {
    var score: Int
    var state: DishState
    var uptime: Int?
    var isLive: Bool

    private var tone: Tone {
        switch score {
        case 85...: .good
        case 60..<85: .warn
        default: .bad
        }
    }

    var body: some View {
        ZStack {
            GaugeArc(progress: Double(score) / 100, tint: .tone(tone), lineWidth: 11, sweep: 0.76)
            VStack(spacing: 1) {
                Text("\(score)")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText(value: Double(score)))
                Text("HEALTH")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.inkTertiary)
            }
            .offset(y: -4)

            VStack {
                Spacer()
                StatusPill(text: state.label, tone: state.tone, pulsing: isLive && state == .connected)
            }
            .offset(y: 8)
        }
        .frame(width: 148, height: 148)
        .animation(.smooth(duration: 0.6), value: score)
    }
}

/// A compact vertical bar meter, used for the secondary hero readouts.
struct MeterBar: View {
    var label: String
    var value: Format.Measured
    /// 0–1 fill.
    var fill: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.label)
                .tracking(0.7)
                .foregroundStyle(Color.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.value)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                Text(value.unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceSunken)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * max(0, min(1, fill))))
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.4), value: fill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
