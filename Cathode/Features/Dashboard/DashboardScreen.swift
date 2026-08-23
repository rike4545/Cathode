import SwiftUI

struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var ribbonSelection: HistorySample?
    @State private var ribbonWindow = 900

    private var status: DishStatus? { model.status }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    DashboardHeader()
                    if case .failed(let message, let hint) = model.connection {
                        ConnectionBanner(message: message, hint: hint)
                    }
                    if let alert = model.unacknowledgedAlerts.first, alert.severity >= .warning {
                        AlertStrip(alert: alert)
                    }

                    heroPanel
                    ribbonPanel
                    statGrid
                    qualityPanel
                    if model.isDemo { demoPanel }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .refreshable { await model.reconnect() }
        }
    }

    // MARK: - Hero

    private var heroPanel: some View {
        Panel(padding: 18) {
            HStack(alignment: .center, spacing: 18) {
                HealthRing(
                    score: status?.healthScore ?? 0,
                    state: status?.state ?? .unknown,
                    uptime: status?.uptimeS,
                    isLive: model.connection == .connected)

                VStack(alignment: .leading, spacing: 16) {
                    MeterBar(
                        label: "Download",
                        value: Format.bitrate(status?.downlinkBps),
                        fill: (status?.downlinkBps ?? 0) / 250_000_000,
                        tint: .downlink)
                    MeterBar(
                        label: "Upload",
                        value: Format.bitrate(status?.uplinkBps),
                        fill: (status?.uplinkBps ?? 0) / 30_000_000,
                        tint: .uplink)
                }
            }

            Divider().overlay(Color.hairline)

            HStack(spacing: 0) {
                heroFact("Uptime", Format.duration(status?.uptimeS.map(Double.init)))
                heroFact("Hardware", status?.deviceInfo.hardwareName ?? "—")
                heroFact("Firmware", shortFirmware(status?.deviceInfo.softwareVersion))
            }
        }
    }

    private func heroFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.label)
                .tracking(0.7)
                .foregroundStyle(Color.inkTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Firmware strings are long build identifiers; the leading date is the part
    /// that means anything to a person.
    private func shortFirmware(_ version: String?) -> String {
        guard let version else { return "—" }
        return version.split(separator: ".").prefix(3).joined(separator: ".")
    }

    // MARK: - Live ribbon

    private var ribbonPanel: some View {
        Panel("Live throughput", subtitle: nil) {
            SegmentPicker(
                options: [(300, "5m"), (900, "15m"), (3600, "1h")],
                selection: $ribbonWindow)
                .frame(width: 150)
        } content: {
            RibbonReadout(
                sample: ribbonSelection,
                fallbackDown: status?.downlinkBps,
                fallbackUp: status?.uplinkBps)
            ThroughputRibbon(
                samples: model.liveSamples,
                window: ribbonWindow,
                selection: $ribbonSelection)
                .frame(height: 148)
        }
    }

    // MARK: - Stat grid

    private var statGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Metrics.gutter),
                      GridItem(.flexible(), spacing: Metrics.gutter)],
            spacing: Metrics.gutter
        ) {
            Panel {
                StatTile(
                    label: "Latency",
                    value: Format.latency(status?.popPingLatencyMs),
                    tone: latencyTone,
                    icon: "timer",
                    trend: model.sparkline { $0.latencyMs },
                    trendTint: .latency,
                    caption: latencyCaption)
            }
            Panel {
                StatTile(
                    label: "Packet loss",
                    value: Format.percent(status?.popPingDropRate, places: 2),
                    tone: dropTone,
                    icon: "arrow.triangle.branch",
                    trend: model.sparkline { $0.dropRate },
                    trendTint: .bad,
                    caption: dropCaption)
            }
            Panel {
                StatTile(
                    label: "Power draw",
                    value: Format.watts(status?.powerW),
                    tone: .idle,
                    icon: "bolt.fill",
                    trend: model.sparkline { $0.powerW },
                    trendTint: .power,
                    caption: powerCaption)
            }
            Panel {
                StatTile(
                    label: "Obstruction",
                    value: Format.percent(status?.obstruction.fractionObstructed, places: 2),
                    tone: obstructionTone,
                    icon: "tree.fill",
                    trendTint: .obstruction,
                    caption: obstructionCaption)
            }
        }
    }

    // MARK: - Quality

    private var qualityPanel: some View {
        let grade = Insights.linkGrade(model.recentSamples(seconds: 3600))
        return Panel("Connection quality", subtitle: "Last hour") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 2) {
                    Text(grade.letter)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tone(grade.tone))
                    Text("GRADE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.inkTertiary)
                }
                .frame(width: 74)
                .padding(.vertical, 10)
                .background(Color.tone(grade.tone).opacity(0.10), in: .rect(cornerRadius: Metrics.innerRadius))

                VStack(alignment: .leading, spacing: 8) {
                    Text(grade.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        SpeedTestScreen()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "speedometer")
                            Text("Run a speed test")
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
    }

    // MARK: - Demo controls

    private var demoPanel: some View {
        Panel("Demo mode", subtitle: "Simulated telemetry — no dish required") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Force a condition to see how Cathode reports it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                HStack(spacing: 8) {
                    ForEach(DishSimulator.Injection.allCases, id: \.self) { injection in
                        Button {
                            Task { await model.inject(injection) }
                        } label: {
                            Text(injection.label)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.surfaceRaised, in: .rect(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.ink)
                    }
                }
            }
        }
    }

    // MARK: - Derived presentation

    private var latencyTone: Tone {
        guard let ms = status?.popPingLatencyMs else { return .idle }
        return ms < 60 ? .good : ms < 120 ? .warn : .bad
    }
    private var latencyCaption: String? {
        let values = model.recentSamples(seconds: 900).compactMap(\.latencyMs).sorted()
        guard values.count > 10 else { return nil }
        return "p95 \(Int(values.percentile(0.95))) ms over 15 min"
    }
    private var dropTone: Tone {
        guard let rate = status?.popPingDropRate else { return .idle }
        return rate < 0.005 ? .good : rate < 0.05 ? .warn : .bad
    }
    private var dropCaption: String? {
        let recent = model.recentSamples(seconds: 3600)
        guard !recent.isEmpty else { return nil }
        let outages = recent.count(where: \.isOutage)
        return outages == 0 ? "No dropouts in the last hour"
                            : "\(outages)s of loss in the last hour"
    }
    private var powerCaption: String? {
        let values = model.recentSamples(seconds: 3600).compactMap(\.powerW)
        guard !values.isEmpty else { return nil }
        let kWhPerMonth = values.mean * 24 * 30 / 1000
        return "≈\(Format.decimal(kWhPerMonth, places: 0)) kWh per month"
    }
    private var obstructionTone: Tone {
        guard let fraction = status?.obstruction.fractionObstructed else { return .idle }
        return fraction < 0.001 ? .good : fraction < 0.01 ? .warn : .bad
    }
    private var obstructionCaption: String? {
        if status?.obstruction.currentlyObstructed == true { return "Blocked right now" }
        guard let worst = model.obstructionAdvice?.worst else { return "Sky is clear" }
        return "Worst to the \(worst.compass)"
    }
}

/// The dashboard's own header, in place of a navigation bar: wordmark, live
/// state, and the identity of whatever Cathode is currently talking to.
struct DashboardHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CATHODE")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                StatusPill(
                    text: model.connection.label,
                    tone: model.connection.tone,
                    pulsing: model.connection == .connected)
                if let lastUpdate = model.lastUpdate {
                    Text(Format.relative(lastUpdate))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            NavigationLink { AlertsScreen() } label: { alertBell }
                .buttonStyle(.plain)
                .padding(.leading, 4)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Unread count sits on the bell so the dashboard alone tells you whether
    /// anything needs attention.
    private var alertBell: some View {
        let count = model.unacknowledgedAlerts.count
        let severity = model.highestSeverity
        return ZStack(alignment: .topTrailing) {
            Image(systemName: count > 0 ? "bell.fill" : "bell")
                .font(.system(size: 16))
                .foregroundStyle(severity.map { Color.tone($0.tone) } ?? Color.inkTertiary)
                .frame(width: 34, height: 34)
                .background(Color.surface, in: .circle)
                .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 1) }
            if count > 0 {
                Text("\(min(99, count))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ground)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(severity.map { Color.tone($0.tone) } ?? Color.warn, in: .capsule)
                    .offset(x: 3, y: -2)
            }
        }
    }

    private var subtitle: String {
        if model.isDemo { return "Demo mode - simulated telemetry" }
        var parts: [String] = []
        if let hardware = model.status?.deviceInfo.hardwareName { parts.append(hardware) }
        parts.append(model.settings.dishHost)
        return parts.joined(separator: " - ")
    }
}

/// Shown at the top of the dashboard when the dish cannot be reached.
struct ConnectionBanner: View {
    var message: String
    var hint: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.bad)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        Button("Retry") { Task { await model.reconnect() } }
                            .font(.system(size: 13, weight: .semibold))
                        Button("Use demo mode") {
                            model.settings.source = .demo
                            Task { await model.reconnect() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.top, 2)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(Color.bad.opacity(0.35), lineWidth: 1)
        }
    }
}

/// The single most severe unacknowledged alert, promoted to the dashboard.
struct AlertStrip: View {
    var alert: Alert

    var body: some View {
        NavigationLink {
            AlertsScreen()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: alert.severity.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.tone(alert.severity.tone))
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(alert.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .padding(13)
            .background(Color.tone(alert.severity.tone).opacity(0.10),
                        in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(Color.tone(alert.severity.tone).opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
