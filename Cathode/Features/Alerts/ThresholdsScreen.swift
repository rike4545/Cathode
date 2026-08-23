import SwiftUI

/// Editable alert thresholds. Defaults are tuned for a typical residential
/// dish; someone on a congested cell or a maritime plan will want them moved.
struct ThresholdsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AlertEngine.Thresholds.default

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.gutter) {
                Panel("Latency") {
                    ThresholdSlider(title: "Warn above", value: $draft.latencyWarnMs,
                                    range: 40...300, step: 5, unit: "ms")
                    ThresholdSlider(title: "Critical above", value: $draft.latencyCriticalMs,
                                    range: 80...800, step: 10, unit: "ms")
                }
                Panel("Packet loss") {
                    ThresholdSlider(title: "Warn above", value: $draft.dropWarnRate,
                                    range: 0.001...0.20, step: 0.001, unit: "%", scale: 100)
                    ThresholdSlider(title: "Critical above", value: $draft.dropCriticalRate,
                                    range: 0.01...0.50, step: 0.01, unit: "%", scale: 100)
                }
                Panel("Obstruction") {
                    ThresholdSlider(title: "Warn above", value: $draft.obstructionWarnFraction,
                                    range: 0.0005...0.05, step: 0.0005, unit: "%", scale: 100,
                                    places: 2)
                    ThresholdSlider(title: "Critical above", value: $draft.obstructionCriticalFraction,
                                    range: 0.005...0.20, step: 0.005, unit: "%", scale: 100,
                                    places: 2)
                }
                Panel("Stability") {
                    ThresholdSlider(
                        title: "Warn above",
                        value: .init(get: { Double(draft.outageSecondsPerHourWarn) },
                                     set: { draft.outageSecondsPerHourWarn = Int($0) }),
                        range: 5...300, step: 5, unit: "s lost / hour")
                    ThresholdSlider(title: "Slow downlink below", value: $draft.lowSpeedWarnMbps,
                                    range: 1...50, step: 1, unit: "Mbps")
                }
                Panel {
                    Button("Restore defaults") { draft = .default }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 28)
        }
        .background(Color.ground)
        .navigationTitle("Alert thresholds")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = model.settings.thresholds }
        .onDisappear { model.settings.thresholds = draft }
    }
}

struct ThresholdSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var unit: String
    /// Multiplier applied for display only, e.g. fractions shown as percent.
    var scale: Double = 1
    var places: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                Text("\(Format.decimal(value * scale, places: places)) \(unit)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
