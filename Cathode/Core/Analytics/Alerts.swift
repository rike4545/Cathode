import Foundation

/// Severity-graded alerts derived from live telemetry.
///
/// The dish raises its own alert bits, but they only cover hardware faults. Most
/// of what actually degrades a connection — creeping obstruction, latency that
/// has doubled since last week, a link that drops for ten seconds every few
/// minutes — never sets a bit. This engine watches for those too.
struct Alert: Identifiable, Sendable, Equatable {
    enum Severity: Int, Comparable, Sendable, CaseIterable {
        case info = 0, warning = 1, critical = 2

        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .info: "Info"
            case .warning: "Warning"
            case .critical: "Critical"
            }
        }
        var tone: Tone {
            switch self {
            case .info: .idle
            case .warning: .warn
            case .critical: .bad
            }
        }
        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .critical: "exclamationmark.octagon.fill"
            }
        }
    }

    /// Stable across re-evaluations so an ongoing alert is not re-notified.
    var id: String
    var severity: Severity
    var title: String
    var detail: String
    /// What the user can actually do about it. Nil when there is nothing to do.
    var remedy: String?
    var firstSeen: Date
    var lastSeen: Date
    var isFromHardware: Bool

    var age: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}

/// Evaluates the alert rules against each new status and history window.
struct AlertEngine: Sendable {

    struct Thresholds: Sendable, Equatable, Codable {
        var latencyWarnMs: Double = 90
        var latencyCriticalMs: Double = 200
        var dropWarnRate: Double = 0.02
        var dropCriticalRate: Double = 0.10
        var obstructionWarnFraction: Double = 0.005
        var obstructionCriticalFraction: Double = 0.02
        /// Outage seconds within the trailing hour before it counts as unstable.
        var outageSecondsPerHourWarn: Int = 30
        var lowSpeedWarnMbps: Double = 5

        static let `default` = Thresholds()
    }

    var thresholds: Thresholds = .default

    /// Produces the current alert set. `previous` carries `firstSeen` forward so
    /// the UI can show how long something has been wrong.
    func evaluate(
        status: DishStatus,
        recent: [HistorySample],
        previous: [Alert],
        now: Date = .now
    ) -> [Alert] {
        var found: [Alert] = []
        let priorByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func raise(_ id: String, _ severity: Alert.Severity, _ title: String,
                   _ detail: String, remedy: String? = nil, hardware: Bool = false) {
            found.append(Alert(
                id: id, severity: severity, title: title, detail: detail, remedy: remedy,
                firstSeen: priorByID[id]?.firstSeen ?? now, lastSeen: now,
                isFromHardware: hardware))
        }

        // --- Connection state --------------------------------------------------
        switch status.state {
        case .thermalShutdown:
            raise("state.thermal", .critical, "Dish has shut down to cool off",
                  "The dish stops transmitting above its temperature limit and will resume on its own.",
                  remedy: "Shade the dish or improve airflow around the mount if this repeats.")
        case .noSats, .noDownlink, .noPings, .offline:
            raise("state.down", .critical, "Link is down",
                  "The dish reports \(status.state.label.lowercased()).",
                  remedy: "If this persists past a few minutes, check cabling and power.")
        case .searching, .booting:
            raise("state.searching", .info, "Dish is \(status.state.label.lowercased())",
                  "It has not acquired a satellite yet. This is normal after a reboot.")
        case .stowed:
            raise("state.stowed", .info, "Dish is stowed",
                  "It will not connect until it is unstowed.",
                  remedy: "Unstow from Controls when you are ready to reconnect.")
        default:
            break
        }

        // --- Packet loss -------------------------------------------------------
        if let drop = status.popPingDropRate, drop > 0 {
            if drop >= thresholds.dropCriticalRate {
                raise("drop.high", .critical, "Heavy packet loss",
                      "\(Format.percent(drop, places: 1).combined) of pings are being dropped right now.",
                      remedy: status.obstruction.currentlyObstructed == true
                          ? "The dish is obstructed — see the Sky tab for where."
                          : "Check for weather, then for anything new in the dish's view of the sky.")
            } else if drop >= thresholds.dropWarnRate {
                raise("drop.some", .warning, "Some packet loss",
                      "\(Format.percent(drop, places: 1).combined) of pings are being dropped.")
            }
        }

        // --- Latency -----------------------------------------------------------
        if let latency = status.popPingLatencyMs {
            if latency >= thresholds.latencyCriticalMs {
                raise("latency.critical", .critical, "Latency is very high",
                      "Round trip to the point of presence is \(Format.latency(latency).combined).",
                      remedy: "Video calls and games will be unusable until this clears.")
            } else if latency >= thresholds.latencyWarnMs {
                raise("latency.warn", .warning, "Latency is elevated",
                      "Round trip is \(Format.latency(latency).combined), above the usual 25–60 ms.")
            }
        }

        // --- Obstruction -------------------------------------------------------
        if let fraction = status.obstruction.fractionObstructed, fraction > 0 {
            if fraction >= thresholds.obstructionCriticalFraction {
                raise("obstruction.high", .critical, "Significant sky obstruction",
                      "\(Format.percent(fraction, places: 2).combined) of the dish's view is blocked.",
                      remedy: "Open the Sky tab — Cathode can tell you which direction to move the dish.")
            } else if fraction >= thresholds.obstructionWarnFraction {
                raise("obstruction.some", .warning, "Sky obstruction detected",
                      "\(Format.percent(fraction, places: 2).combined) of the view is blocked, "
                      + "which will cause brief dropouts.",
                      remedy: "See the Sky tab for the obstructed direction.")
            }
        }

        // --- Signal ------------------------------------------------------------
        if status.isSnrPersistentlyLow == true {
            raise("snr.low", .warning, "Signal is persistently low",
                  "The dish reports its signal-to-noise ratio has been below target.",
                  remedy: "Usually weather or a partial obstruction. Check the Sky tab.")
        }

        // --- Stability over the trailing hour ----------------------------------
        let hourAgo = now.addingTimeInterval(-3600)
        let lastHour = recent.filter { $0.t >= hourAgo }
        let outageSeconds = lastHour.count(where: \.isOutage)
        if outageSeconds >= thresholds.outageSecondsPerHourWarn, status.state == .connected {
            raise("stability.flapping", .warning, "Connection is unstable",
                  "\(outageSeconds) seconds of full loss in the last hour, even though the link is up now.",
                  remedy: "Intermittent drops like these are usually obstruction, not weather.")
        }

        // --- Throughput floor ---------------------------------------------------
        if status.state == .connected, let down = status.downlinkBps,
           down < thresholds.lowSpeedWarnMbps * 1_000_000,
           lastHour.suffix(120).map(\.downlinkBps).mean < thresholds.lowSpeedWarnMbps * 1_000_000,
           lastHour.count >= 120 {
            raise("throughput.low", .warning, "Downlink is unusually slow",
                  "Averaging \(Format.bitrate(lastHour.suffix(120).map(\.downlinkBps).mean).combined) "
                  + "over the last two minutes.",
                  remedy: "Run a speed test to confirm, then check for congestion at peak hours.")
        }

        // --- Hardware alert bits -------------------------------------------------
        for (name, tone) in status.alerts.active {
            let severity: Alert.Severity = tone == .bad ? .critical : tone == .warn ? .warning : .info
            raise("hw.\(name)", severity, name,
                  "Reported directly by the dish.", hardware: true)
        }

        // --- Software update ------------------------------------------------------
        if status.swupdateRebootReady == true {
            raise("update.ready", .info, "Update ready to install",
                  "The dish has downloaded new firmware and will reboot to apply it.",
                  remedy: "It reboots during your configured update window, or reboot now from Controls.")
        }

        return found.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.firstSeen < $1.firstSeen
        }
    }
}

/// Tracks outage spans across polls so they can be written to history once
/// complete, rather than as a smear of individual dropped seconds.
struct OutageTracker: Sendable {
    private var openStart: Date?
    private var openCause: String = "Unknown"
    private var lastSeen: Date?

    /// Feeds one status in. Returns a record when an outage has just ended.
    mutating func observe(_ status: DishStatus, now: Date = .now) -> OutageRecord? {
        let down = status.state != .connected || (status.popPingDropRate ?? 0) >= 1

        if down {
            if openStart == nil {
                openStart = now
                openCause = status.outage?.cause.label ?? status.state.label
            }
            lastSeen = now
            return nil
        }

        guard let start = openStart, let end = lastSeen else {
            openStart = nil
            return nil
        }
        openStart = nil
        lastSeen = nil
        // A single dropped poll is noise, not an outage worth recording.
        let duration = end.timeIntervalSince(start)
        guard duration >= 2 else { return nil }
        return OutageRecord(start: start, end: end, cause: openCause)
    }

    var currentOutageStart: Date? { openStart }
}
