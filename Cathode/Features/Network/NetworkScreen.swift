import SwiftUI

struct NetworkScreen: View {
    @Environment(AppModel.self) private var model
    @State private var sort: Sort = .throughput
    @State private var usageRange: UsageRange = .day
    @State private var usage: [ClientUsageTotal] = []

    enum UsageRange: String, CaseIterable, Hashable {
        case day, week, month
        var label: String {
            switch self {
            case .day: "24H"
            case .week: "7D"
            case .month: "30D"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .day: 86_400
            case .week: 604_800
            case .month: 2_592_000
            }
        }
    }

    enum Sort: String, CaseIterable, Hashable {
        case throughput, name, signal, total
        var label: String {
            switch self {
            case .throughput: "Now"
            case .name: "Name"
            case .signal: "Signal"
            case .total: "Total"
            }
        }
    }

    private var clients: [WifiClient] {
        let list = model.wifi?.clients ?? []
        return switch sort {
        case .throughput: list.sorted { ($0.rxBps ?? 0) + ($0.txBps ?? 0) > ($1.rxBps ?? 0) + ($1.txBps ?? 0) }
        case .name: list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .signal: list.sorted { ($0.signalStrength ?? -120) > ($1.signalStrength ?? -120) }
        case .total: list.sorted { ($0.bytesDown ?? 0) > ($1.bytesDown ?? 0) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    linkPanel
                    if model.wifi == nil {
                        routerUnavailablePanel
                    } else {
                        routerPanel
                        clientsPanel
                    }
                    usagePanel
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.large)
            .task(id: usageRange) { await loadUsage() }
            .refreshable { await loadUsage() }
        }
    }

    private var linkPanel: some View {
        Panel("Link", subtitle: "Dish to point of presence") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                StatTile(label: "Download", value: Format.bitrate(model.status?.downlinkBps),
                         icon: "arrow.down", trend: model.sparkline { $0.downlinkBps },
                         trendTint: .downlink)
                StatTile(label: "Upload", value: Format.bitrate(model.status?.uplinkBps),
                         icon: "arrow.up", trend: model.sparkline { $0.uplinkBps },
                         trendTint: .uplink)
            }
            Divider().overlay(Color.hairline)
            if let eth = model.status?.ethSpeedMbps {
                MetricRow(label: "Ethernet link", value: "\(eth) Mbps",
                          tone: eth >= 1000 ? .good : eth > 0 ? .warn : .bad)
            }
            MetricRow(label: "Bypass mode",
                      value: (model.status?.bypassMode ?? false) ? "On — router bypassed" : "Off")
            if let gps = model.status?.gpsSats {
                MetricRow(label: "GPS satellites", value: "\(gps)",
                          tone: (model.status?.gpsValid ?? false) ? .good : .warn)
            }
            if let location = model.location, let lat = location.latitude, let lon = location.longitude {
                MetricRow(label: "Location",
                          value: "\(Format.decimal(lat, places: 4)), \(Format.decimal(lon, places: 4))",
                          mono: true)
            }
        }
    }

    private var routerUnavailablePanel: some View {
        Panel("Router") {
            EmptyPanel(
                icon: "wifi.router",
                message: "No router data",
                detail: model.isDemo
                    ? "The simulator provides a router; give it a moment to answer."
                    : "The dish answered but the router did not. This is expected in bypass "
                    + "mode, or when a third-party router replaced the Starlink one.")
        }
    }

    private var routerPanel: some View {
        Panel("Router", subtitle: model.wifi?.deviceInfo.softwareVersion) {
            MetricRow(label: "Hardware",
                      value: model.wifi?.deviceInfo.hardwareVersion ?? "—", mono: true)
            if let latency = model.wifi?.pingLatencyMs {
                MetricRow(label: "Router ping", value: Format.latency(latency).combined, tone: .good)
            }
            MetricRow(label: "Mode",
                      value: (model.wifi?.isRepeater ?? false) ? "Mesh repeater" : "Primary")
            MetricRow(label: "Connected devices", value: "\(model.wifi?.clients.count ?? 0)")
        }
    }

    private var clientsPanel: some View {
        Panel("Devices", subtitle: "Per-client throughput, straight from the router") {
            VStack(spacing: 12) {
                SegmentPicker(options: Sort.allCases.map { ($0, $0.label) }, selection: $sort)
                if clients.isEmpty {
                    EmptyPanel(icon: "laptopcomputer.slash", message: "No devices connected")
                } else {
                    VStack(spacing: 0) {
                        ForEach(clients) { client in
                            ClientRow(client: client, peak: peakThroughput)
                            if client.id != clients.last?.id {
                                Divider().overlay(Color.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Usage per device over time.
    ///
    /// The router only reports a running lifetime total per client, which
    /// answers the wrong question. Cathode samples those counters and stores
    /// the differences, so this can answer the one people actually ask: who has
    /// been using the connection this week.
    private var usagePanel: some View {
        Panel("Usage by device", subtitle: "Measured by Cathode, not the router") {
            VStack(spacing: 12) {
                SegmentPicker(options: UsageRange.allCases.map { ($0, $0.label) },
                              selection: $usageRange)
                if usage.isEmpty {
                    EmptyPanel(
                        icon: "chart.bar.xaxis",
                        message: "Nothing recorded yet",
                        detail: "Cathode builds this by watching the router's per-device "
                              + "counters while it runs. Leave it connected and it fills in.")
                } else {
                    let peak = usage.first?.total ?? 1
                    let total = usage.reduce(0) { $0 + $1.total }
                    ForEach(usage.prefix(12)) { entry in
                        UsageRow(entry: entry, peak: peak, share: total > 0 ? entry.total / total : 0)
                        if entry.id != usage.prefix(12).last?.id {
                            Divider().overlay(Color.hairline)
                        }
                    }
                    Divider().overlay(Color.hairline)
                    MetricRow(label: "Total across \(usage.count) devices",
                              value: Format.bytes(total).combined)
                }
            }
        }
    }

    private func loadUsage() async {
        guard let store = model.store else { return }
        let to = Date.now
        usage = (try? await store.clientUsage(
            from: to.addingTimeInterval(-usageRange.seconds), to: to)) ?? []
    }

    /// Scale every device's bar against the busiest one, so the list reads as a
    /// ranking rather than as absolute values nobody can compare by eye.
    private var peakThroughput: Double {
        max(1, clients.map { ($0.rxBps ?? 0) + ($0.txBps ?? 0) }.max() ?? 1)
    }
}

struct ClientRow: View {
    var client: WifiClient
    var peak: Double

    private var total: Double { (client.rxBps ?? 0) + (client.txBps ?? 0) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(client.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if let band = client.band {
                        Text(band)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.inkTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.surfaceSunken, in: .rect(cornerRadius: 3))
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.surfaceSunken)
                        Capsule()
                            .fill(Color.downlink.opacity(0.8))
                            .frame(width: max(2, geo.size.width * min(1, total / peak)))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 8) {
                    Text(client.ipAddress ?? client.macAddress ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.inkTertiary)
                    if let bytes = client.bytesDown {
                        Text("· \(Format.bytes(bytes).combined) total")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkTertiary)
                    }
                }
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bitrate(total).combined)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                SignalBars(bars: client.signalBars, isWired: client.isWired ?? false)
            }
        }
        .padding(.vertical, 10)
    }

    private var icon: String {
        if client.isWired == true { return "cable.connector" }
        let name = client.displayName.lowercased()
        if name.contains("tv") || name.contains("roku") || name.contains("apple tv") { return "tv" }
        if name.contains("phone") || name.contains("pixel") { return "iphone" }
        if name.contains("mac") || name.contains("laptop") || name.contains("pc") { return "laptopcomputer" }
        if name.contains("camera") { return "video" }
        if name.contains("speaker") || name.contains("echo") || name.contains("sonos") { return "hifispeaker" }
        if name.contains("thermostat") || name.contains("nest") { return "thermometer.medium" }
        return "wifi"
    }
}

struct UsageRow: View {
    var entry: ClientUsageTotal
    var peak: Double
    /// Fraction of all recorded usage in the window.
    var share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Format.bytes(entry.total).combined)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
            }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    Capsule().fill(Color.downlink)
                        .frame(width: max(2, geo.size.width * (entry.down / max(1, peak))))
                    Capsule().fill(Color.uplink)
                        .frame(width: max(1, geo.size.width * (entry.up / max(1, peak))))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                Text("↓ \(Format.bytes(entry.down).combined)")
                    .foregroundStyle(Color.downlink)
                Text("↑ \(Format.bytes(entry.up).combined)")
                    .foregroundStyle(Color.uplink)
                Spacer()
                Text("\(Int((share * 100).rounded()))% of total")
                    .foregroundStyle(Color.inkTertiary)
            }
            .font(.system(size: 10, design: .rounded))
            .monospacedDigit()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue("\(Format.bytes(entry.total).combined), "
            + "\(Int((share * 100).rounded())) percent of all usage")
    }
}

struct SignalBars: View {
    var bars: Int
    var isWired: Bool

    var body: some View {
        if isWired {
            Text("Wired")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.inkTertiary)
        } else {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(1...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 0.6)
                        .fill(level <= bars ? tint : Color.surfaceSunken)
                        .frame(width: 2.5, height: CGFloat(level) * 2.4 + 2)
                }
            }
        }
    }

    private var tint: Color {
        switch bars {
        case 4, 3: .good
        case 2: .warn
        default: .bad
        }
    }
}
