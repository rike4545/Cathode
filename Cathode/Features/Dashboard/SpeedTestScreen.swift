import SwiftUI
import Charts

struct SpeedTestScreen: View {
    @Environment(AppModel.self) private var model
    @State private var elapsed: Double = 0
    @State private var timer: Timer?

    private var latest: SpeedTestResult? { model.speedTests.first }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.gutter) {
                runPanel
                if let latest { resultPanel(latest) }
                if model.speedTests.count > 1 { historyPanel }
                explainerPanel
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 28)
        }
        .background(Color.ground)
        .navigationTitle("Speed test")
        .navigationBarTitleDisplayMode(.inline)
        // A speed test takes half a minute; people put the phone down. A result
        // landing is exactly the kind of moment worth a tap on the wrist.
        .sensoryFeedback(.success, trigger: latest?.id) { _, _ in
            model.settings.hapticsEnabled
        }
    }

    private var runPanel: some View {
        Panel {
            VStack(spacing: 14) {
                if model.speedTestInProgress {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Saturating the link…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.ink)
                        Text("This deliberately uses the full connection for about 30 seconds. "
                             + "Everything else on the network will slow down while it runs.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    Button {
                        Task { await model.runSpeedTest() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Run speed test")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.good, in: .rect(cornerRadius: Metrics.innerRadius))
                        .foregroundStyle(Color.ground)
                    }
                    .buttonStyle(.plain)
                    Text("Runs on the dish itself, so it measures the satellite link rather "
                         + "than your Wi-Fi.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func resultPanel(_ result: SpeedTestResult) -> some View {
        let grade = Insights.bufferbloatGrade(result)
        return VStack(spacing: Metrics.gutter) {
            Panel("Result", subtitle: Format.dayAndTime(result.timestamp)) {
                HStack(spacing: 0) {
                    resultColumn("Download", Format.bitrate(result.downlinkBps), .downlink)
                    Divider().frame(height: 46).overlay(Color.hairline)
                    resultColumn("Upload", Format.bitrate(result.uplinkBps), .uplink)
                    Divider().frame(height: 46).overlay(Color.hairline)
                    resultColumn("Latency", Format.latency(result.latencyMs), .latency)
                }
            }

            Panel("Latency under load", subtitle: "The bufferbloat test") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 2) {
                        Text(grade.letter)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tone(grade.tone))
                        Text("GRADE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Color.inkTertiary)
                    }
                    .frame(width: 72)
                    .padding(.vertical, 10)
                    .background(Color.tone(grade.tone).opacity(0.10),
                                in: .rect(cornerRadius: Metrics.innerRadius))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(grade.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        loadBar("Idle", result.latencyMs, result)
                        if let down = result.latencyUnderLoadDownMs {
                            loadBar("Downloading", down, result)
                        }
                        if let up = result.latencyUnderLoadUpMs {
                            loadBar("Uploading", up, result)
                        }
                    }
                }
            }
        }
    }

    private func resultColumn(_ label: String, _ value: Format.Measured, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.label)
                .tracking(0.7)
                .foregroundStyle(Color.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(value.unit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadBar(_ label: String, _ ms: Double, _ result: SpeedTestResult) -> some View {
        let peak = max(result.latencyMs,
                       max(result.latencyUnderLoadDownMs ?? 0, result.latencyUnderLoadUpMs ?? 0))
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.inkTertiary)
                .frame(width: 76, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceSunken)
                    Capsule()
                        .fill(ms > result.latencyMs * 3 ? Color.bad
                              : ms > result.latencyMs * 1.6 ? Color.warn : Color.good)
                        .frame(width: max(4, geo.size.width * min(1, ms / max(1, peak))))
                }
            }
            .frame(height: 6)
            Text("\(Int(ms)) ms")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var historyPanel: some View {
        Panel("Past tests", subtitle: "\(model.speedTests.count) recorded") {
            Chart {
                ForEach(model.speedTests.reversed()) { test in
                    BarMark(
                        x: .value("When", test.timestamp, unit: .minute),
                        y: .value("Mbps", test.downlinkBps / 1_000_000))
                        .foregroundStyle(Color.downlink)
                        .cornerRadius(2)
                }
            }
            .frame(height: 110)
            .chartYAxisLabel("Mbps", position: .leading)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.inkTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.inkTertiary)
                }
            }

            VStack(spacing: 0) {
                ForEach(model.speedTests.prefix(6)) { test in
                    HStack {
                        Text(Format.dayAndTime(test.timestamp))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkSecondary)
                        Spacer()
                        Text("↓ \(Format.bitrate(test.downlinkBps).combined)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.downlink)
                        Text("↑ \(Format.bitrate(test.uplinkBps).combined)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.uplink)
                        Text("\(Int(test.latencyMs)) ms")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.latency)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var explainerPanel: some View {
        Panel("Why latency under load matters") {
            Text("A speed number tells you how fast a big download finishes. It says nothing "
                 + "about whether a video call survives while that download is running.\n\n"
                 + "When a link is saturated, packets queue. If the queue is deep, every "
                 + "interactive packet waits behind it and latency climbs — often from 30 ms to "
                 + "several hundred. That is bufferbloat, and it is the difference between a "
                 + "connection that measures well and one that feels good.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
