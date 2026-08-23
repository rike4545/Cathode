import SwiftUI
import Charts

struct HistoryScreen: View {
    @Environment(AppModel.self) private var model

    @State private var range: TimeRange = .day
    @State private var series: [Aggregate] = []
    @State private var usage: (down: Double, up: Double) = (0, 0)
    @State private var uptime = UptimeSummary(recordedSeconds: 0, outageSeconds: 0, obstructedSeconds: 0)
    @State private var outages: [OutageRecord] = []
    @State private var hourly: [Insights.HourProfile] = []
    @State private var trends: [Insights.Trend] = []
    @State private var isLoading = false
    @State private var selected: Aggregate?

    enum TimeRange: String, CaseIterable, Identifiable {
        case hour, sixHours, day, week, month
        var id: String { rawValue }

        var label: String {
            switch self {
            case .hour: "1H"
            case .sixHours: "6H"
            case .day: "24H"
            case .week: "7D"
            case .month: "30D"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .hour: 3_600
            case .sixHours: 21_600
            case .day: 86_400
            case .week: 604_800
            case .month: 2_592_000
            }
        }
        var title: String {
            switch self {
            case .hour: "the last hour"
            case .sixHours: "the last six hours"
            case .day: "the last 24 hours"
            case .week: "the last 7 days"
            case .month: "the last 30 days"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    rangePicker
                    if series.isEmpty && !isLoading {
                        emptyState
                    } else {
                        summaryPanel
                        throughputChart
                        latencyChart
                        reliabilityPanel
                        powerChart
                        if !trends.isEmpty { trendPanel }
                        hourlyPanel
                        outagePanel
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .task(id: range) { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: - Controls

    private var rangePicker: some View {
        SegmentPicker(
            options: TimeRange.allCases.map { ($0, $0.label) },
            selection: $range)
    }

    private var emptyState: some View {
        Panel {
            EmptyPanel(
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                message: "No history for \(range.title) yet",
                detail: "Cathode records telemetry while it is running and keeps minute-level "
                      + "rollups indefinitely. Leave it connected and this fills in.")
        }
    }

    // MARK: - Summary

    private var summaryPanel: some View {
        Panel("Summary", subtitle: range.title.capitalizedFirst) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                StatTile(label: "Downloaded", value: Format.bytes(usage.down),
                         tone: .idle, icon: "arrow.down", trendTint: .downlink)
                StatTile(label: "Uploaded", value: Format.bytes(usage.up),
                         tone: .idle, icon: "arrow.up", trendTint: .uplink)
                StatTile(label: "Availability",
                         value: Format.Measured(value: uptime.ninesLabel, unit: ""),
                         tone: availabilityTone, icon: "checkmark.shield",
                         caption: uptime.recordedSeconds > 0
                            ? "\(Format.duration(Double(uptime.outageSeconds))) of downtime" : nil)
                StatTile(label: "Energy",
                         value: Format.energy(kWh: Insights.energyKWh(series)),
                         tone: .idle, icon: "bolt", trendTint: .power,
                         caption: energyCaption)
            }
            if let allowance = allowanceProgress {
                Divider().overlay(Color.hairline)
                allowanceView(allowance)
            }
        }
    }

    private var availabilityTone: Tone {
        guard let availability = uptime.availability else { return .idle }
        return availability > 0.999 ? .good : availability > 0.99 ? .warn : .bad
    }

    private var energyCaption: String? {
        let kWh = Insights.energyKWh(series)
        // Project from the span actually recorded, not the span requested — a
        // 24-hour view holding 12 hours of data would otherwise halve the
        // estimate.
        let recorded = Double(series.reduce(0) { $0 + $1.sampleCount })
        guard kWh > 0, recorded >= 3_600 else { return nil }
        let perMonth = kWh / recorded * 2_592_000
        return "≈\(Format.decimal(perMonth, places: 0)) kWh per month"
    }

    private var allowanceProgress: Double? {
        let allowance = model.settings.monthlyAllowanceGB
        guard allowance > 0 else { return nil }
        return usage.down / (allowance * 1_000_000_000)
    }

    private func allowanceView(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Monthly allowance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                Text("\(Int(progress * 100))% of \(Int(model.settings.monthlyAllowanceGB)) GB")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceSunken)
                    Capsule()
                        .fill(progress > 0.9 ? Color.bad : progress > 0.75 ? Color.warn : Color.good)
                        .frame(width: max(4, geo.size.width * min(1, progress)))
                }
            }
            .frame(height: 7)
        }
    }

    // MARK: - Charts

    private var throughputChart: some View {
        Panel("Throughput", subtitle: "Average, with peaks") {
            Chart {
                ForEach(series) { point in
                    AreaMark(
                        x: .value("Time", point.t),
                        yStart: .value("Min", 0),
                        yEnd: .value("Download", point.downAvg / 1_000_000))
                        .foregroundStyle(.linearGradient(
                            colors: [.downlink.opacity(0.45), .downlink.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Download", point.downAvg / 1_000_000))
                        .foregroundStyle(Color.downlink)
                        .lineStyle(.init(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Upload", point.upAvg / 1_000_000),
                        series: .value("Series", "up"))
                        .foregroundStyle(Color.uplink)
                        .lineStyle(.init(lineWidth: 1.3))
                        .interpolationMethod(.monotone)
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.t))
                        .foregroundStyle(Color.ink.opacity(0.3))
                        .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYAxisLabel("Mbps", position: .leading)
            .chartStyle(height: 180)
            .chartSelection($selected, in: series)
            selectionReadout
        }
    }

    @ViewBuilder
    private var selectionReadout: some View {
        if let selected {
            HStack(spacing: 14) {
                Text(Format.dayAndTime(selected.t))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("↓ \(Format.bitrate(selected.downAvg).combined)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.downlink)
                Text("↑ \(Format.bitrate(selected.upAvg).combined)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.uplink)
                Spacer()
            }
            .monospacedDigit()
        }
    }

    private var latencyChart: some View {
        Panel("Latency", subtitle: "Average and worst per bucket") {
            Chart {
                ForEach(series) { point in
                    if let max = point.latencyMax {
                        BarMark(
                            x: .value("Time", point.t),
                            yStart: .value("Avg", point.latencyAvg ?? max),
                            yEnd: .value("Max", max),
                            width: .fixed(1.5))
                            .foregroundStyle(Color.latency.opacity(0.28))
                    }
                    if let avg = point.latencyAvg {
                        LineMark(x: .value("Time", point.t), y: .value("Latency", avg))
                            .foregroundStyle(Color.latency)
                            .lineStyle(.init(lineWidth: 1.6))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxisLabel("ms", position: .leading)
            .chartStyle(height: 150)
            Text("Bars show the worst latency inside each bucket, so a spike that "
                 + "lasted one second still survives being averaged.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
        }
    }

    private var reliabilityPanel: some View {
        Panel("Reliability", subtitle: "Seconds lost and seconds obstructed") {
            Chart {
                ForEach(series) { point in
                    BarMark(
                        x: .value("Time", point.t),
                        y: .value("Outage", point.outageSeconds))
                        .foregroundStyle(Color.bad)
                    BarMark(
                        x: .value("Time", point.t),
                        y: .value("Obstructed", point.obstructedSeconds))
                        .foregroundStyle(Color.obstruction.opacity(0.6))
                }
            }
            .chartYAxisLabel("seconds", position: .leading)
            .chartStyle(height: 110)
        }
    }

    private var powerChart: some View {
        Panel("Power draw") {
            Chart {
                ForEach(series) { point in
                    if let power = point.powerAvg {
                        AreaMark(x: .value("Time", point.t), y: .value("Watts", power))
                            .foregroundStyle(.linearGradient(
                                colors: [.power.opacity(0.4), .power.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", point.t), y: .value("Watts", power))
                            .foregroundStyle(Color.power)
                            .lineStyle(.init(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxisLabel("W", position: .leading)
            .chartStyle(height: 130)
        }
    }

    // MARK: - Trends and profiles

    private var trendPanel: some View {
        Panel("What changed", subtitle: "Recent window versus the longer baseline") {
            VStack(spacing: 10) {
                ForEach(trends, id: \.metric) { trend in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: trend.isDegradation
                              ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(trend.isDegradation ? Color.warn : Color.good)
                        Text(trend.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var hourlyPanel: some View {
        Panel("By hour of day", subtitle: "Where congestion shows up") {
            Chart {
                ForEach(hourly) { profile in
                    BarMark(
                        x: .value("Hour", profile.hour),
                        y: .value("Download", profile.downAvg / 1_000_000))
                        .foregroundStyle(Color.downlink.opacity(0.75))
                        .cornerRadius(2)
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(hour == 0 ? "12a" : hour == 12 ? "12p"
                                 : hour < 12 ? "\(hour)a" : "\(hour - 12)p")
                        }
                    }
                    AxisGridLine().foregroundStyle(Color.hairline)
                }
            }
            .chartYAxisLabel("Mbps", position: .leading)
            .chartStyle(height: 120)
            if let worst = hourly.filter({ $0.downAvg > 0 }).min(by: { $0.downAvg < $1.downAvg }),
               let best = hourly.max(by: { $0.downAvg < $1.downAvg }), best.downAvg > 0 {
                Text("Slowest around \(hourLabel(worst.hour)) at "
                     + "\(Format.bitrate(worst.downAvg).combined); fastest around "
                     + "\(hourLabel(best.hour)) at \(Format.bitrate(best.downAvg).combined).")
                    .font(.caption2)
                    .foregroundStyle(Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        hour == 0 ? "midnight" : hour == 12 ? "noon"
            : hour < 12 ? "\(hour) am" : "\(hour - 12) pm"
    }

    private var outagePanel: some View {
        Panel("Outages", subtitle: outages.isEmpty ? nil : "\(outages.count) recorded") {
            if outages.isEmpty {
                EmptyPanel(icon: "checkmark.seal", message: "No outages recorded",
                           detail: "Nothing dropped for longer than two seconds in this window.")
            } else {
                VStack(spacing: 0) {
                    ForEach(outages.prefix(12)) { outage in
                        HStack(spacing: 11) {
                            Circle()
                                .fill(Color.bad)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(outage.cause)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.ink)
                                Text(Format.dayAndTime(outage.start))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.inkTertiary)
                            }
                            Spacer()
                            Text(Format.preciseDuration(outage.duration))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .padding(.vertical, 9)
                        if outage.id != outages.prefix(12).last?.id {
                            Divider().overlay(Color.hairline)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let store = model.store else { return }
        isLoading = true
        defer { isLoading = false }

        let to = Date.now
        let from = to.addingTimeInterval(-range.seconds)
        series = (try? await store.series(from: from, to: to)) ?? []
        usage = (try? await store.usage(
            from: range == .month ? model.settings.billingPeriodStart() : from, to: to)) ?? (0, 0)
        uptime = (try? await store.uptime(from: from, to: to))
            ?? UptimeSummary(recordedSeconds: 0, outageSeconds: 0, obstructedSeconds: 0)
        outages = (try? await store.outages(from: from, to: to)) ?? []

        // The hourly profile and trend comparison want a wider view than the
        // selected range, so they read their own windows.
        let weekAgo = to.addingTimeInterval(-604_800)
        let week = (try? await store.series(from: weekAgo, to: to, maxPoints: 2000)) ?? []
        hourly = Insights.hourlyProfile(week)
        let recentCut = to.addingTimeInterval(-range.seconds / 4)
        trends = Insights.trends(
            recent: series.filter { $0.t >= recentCut },
            baseline: series.filter { $0.t < recentCut })
    }
}

// MARK: - Chart styling
//
// Every chart in Cathode shares one look, applied here rather than repeated.

private extension View {
    func chartStyle(height: CGFloat) -> some View {
        self
            .frame(height: height)
            .chartXAxis {
                AxisMarks(preset: .aligned) { _ in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color.surfaceSunken.opacity(0.5))
                    .clipShape(.rect(cornerRadius: 8))
            }
    }

    /// Drag-to-inspect that snaps to the nearest bucket.
    func chartSelection(_ selection: Binding<Aggregate?>, in series: [Aggregate]) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = value.location.x - geo[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                selection.wrappedValue = series.min {
                                    abs($0.t.timeIntervalSince(date))
                                        < abs($1.t.timeIntervalSince(date))
                                }
                            }
                            .onEnded { _ in selection.wrappedValue = nil })
            }
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
