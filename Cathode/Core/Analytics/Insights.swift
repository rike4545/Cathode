import Foundation

/// Analyses that turn raw telemetry into something actionable.
///
/// These are the parts of Cathode that go past reporting numbers: grading a
/// connection the way a person would judge it, and telling someone which way to
/// move a dish rather than just showing them a red blob.
enum Insights {

    // MARK: - Connection grade

    /// A letter grade for the link, in the spirit of a bufferbloat test.
    ///
    /// Idle latency says how the connection feels when nothing else is running.
    /// Latency *under load* says whether a video call survives someone else
    /// starting a download — which is what people actually complain about, and
    /// what a raw speed number never captures.
    struct Grade: Sendable, Equatable {
        var letter: String
        var tone: Tone
        var summary: String

        static let unknown = Grade(letter: "—", tone: .idle, summary: "Not enough data yet.")
    }

    static func bufferbloatGrade(_ result: SpeedTestResult) -> Grade {
        let idle = result.latencyMs
        let loaded = max(result.latencyUnderLoadDownMs ?? idle, result.latencyUnderLoadUpMs ?? idle)
        guard idle > 0, loaded >= idle else { return .unknown }
        let increase = loaded - idle

        switch increase {
        case ..<5:
            return Grade(letter: "A+", tone: .good,
                         summary: "Latency barely moves under load. Calls and games stay smooth "
                                + "even while someone else is downloading.")
        case ..<30:
            return Grade(letter: "A", tone: .good,
                         summary: "Adds \(Int(increase)) ms under load — well controlled.")
        case ..<60:
            return Grade(letter: "B", tone: .good,
                         summary: "Adds \(Int(increase)) ms under load. Fine for most things.")
        case ..<150:
            return Grade(letter: "C", tone: .warn,
                         summary: "Adds \(Int(increase)) ms under load. Video calls will stutter "
                                + "when the link is busy.")
        case ..<400:
            return Grade(letter: "D", tone: .warn,
                         summary: "Adds \(Int(increase)) ms under load. Real-time apps will "
                                + "struggle during downloads.")
        default:
            return Grade(letter: "F", tone: .bad,
                         summary: "Adds \(Int(increase)) ms under load. The connection becomes "
                                + "unusable for anything interactive while busy.")
        }
    }

    /// Overall connection quality from a window of history, not a single test.
    static func linkGrade(_ samples: [HistorySample]) -> Grade {
        let usable = samples.filter { !$0.isOutage }
        guard usable.count >= 60 else { return .unknown }

        let latencies = usable.compactMap(\.latencyMs).sorted()
        guard !latencies.isEmpty else { return .unknown }
        let p50 = latencies.percentile(0.5)
        let p95 = latencies.percentile(0.95)
        let lossRate = Double(samples.count(where: \.isOutage)) / Double(samples.count)

        // Points off for each thing a user would notice, worst-case dominant.
        var score = 100.0
        score -= max(0, p50 - 35) * 0.6
        score -= max(0, p95 - 80) * 0.25
        score -= lossRate * 400
        score -= Double(samples.count(where: \.obstructed)) / Double(samples.count) * 200

        let letter: String
        let tone: Tone
        switch score {
        case 92...: (letter, tone) = ("A+", .good)
        case 85..<92: (letter, tone) = ("A", .good)
        case 75..<85: (letter, tone) = ("B", .good)
        case 62..<75: (letter, tone) = ("C", .warn)
        case 45..<62: (letter, tone) = ("D", .warn)
        default: (letter, tone) = ("F", .bad)
        }

        let summary = "Median \(Int(p50)) ms, 95th percentile \(Int(p95)) ms, "
            + "\(Format.percent(lossRate, places: 2).combined) of seconds lost."
        return Grade(letter: letter, tone: tone, summary: summary)
    }

    // MARK: - Obstruction advisor

    /// Where the sky is blocked, and what to do about it.
    ///
    /// The dish reports a fraction obstructed but never says *where*. Cathode
    /// reduces the SNR grid to angular wedges, finds the worst ones, and turns
    /// that into an instruction a person can follow while standing outside.
    struct ObstructionAdvice: Sendable, Equatable {
        struct Wedge: Sendable, Equatable, Identifiable {
            /// Centre of the wedge, degrees from north.
            var azimuthDeg: Double
            /// Share of this wedge's observed cells that are blocked, 0–1.
            var blockedFraction: Double
            /// Highest elevation at which something is still blocking, degrees.
            var peakElevationDeg: Double
            var id: Double { azimuthDeg }

            var compass: String { Format.compass(azimuthDeg) }
        }

        var totalBlockedFraction: Double
        var wedges: [Wedge]
        var worst: Wedge?
        /// Plain-language recommendation, or nil when the view is clear.
        var recommendation: String?
        /// Rough share of dropouts that would go away if `worst` were cleared.
        var estimatedImprovement: Double?

        var isClear: Bool { totalBlockedFraction < 0.0005 }
    }

    static func analyseObstruction(_ map: ObstructionMap, wedgeCount: Int = 24) -> ObstructionAdvice {
        var blockedByWedge = [Double](repeating: 0, count: wedgeCount)
        var observedByWedge = [Double](repeating: 0, count: wedgeCount)
        var peakElevation = [Double](repeating: 0, count: wedgeCount)
        var totalObserved = 0.0
        var totalBlocked = 0.0

        for row in 0..<map.rows {
            for col in 0..<map.cols {
                let value = map.value(row: row, col: col)
                guard value >= 0 else { continue } // never observed
                let sky = gridToSky(row: row, col: col, rows: map.rows, cols: map.cols)
                guard sky.radius <= 1 else { continue } // outside the dome
                let index = Int((sky.azimuth / 360 * Double(wedgeCount)).rounded(.down)) % wedgeCount

                observedByWedge[index] += 1
                totalObserved += 1
                if value > 0.5 {
                    blockedByWedge[index] += Double(value)
                    totalBlocked += Double(value)
                    peakElevation[index] = max(peakElevation[index], sky.elevation)
                }
            }
        }

        let wedges = (0..<wedgeCount).compactMap { i -> ObstructionAdvice.Wedge? in
            guard observedByWedge[i] > 0, blockedByWedge[i] > 0 else { return nil }
            return ObstructionAdvice.Wedge(
                azimuthDeg: (Double(i) + 0.5) / Double(wedgeCount) * 360,
                blockedFraction: blockedByWedge[i] / observedByWedge[i],
                peakElevationDeg: peakElevation[i])
        }
        .sorted { $0.blockedFraction > $1.blockedFraction }

        let total = totalObserved > 0 ? totalBlocked / totalObserved : 0
        let worst = wedges.first

        var recommendation: String?
        var improvement: Double?
        if let worst, total >= 0.0005 {
            let share = totalBlocked > 0
                ? (worst.blockedFraction * (observedByWedge[
                    Int((worst.azimuthDeg / 360 * Double(wedgeCount)).rounded(.down)) % wedgeCount
                  ])) / totalBlocked
                : 0
            improvement = min(1, share)
            let direction = Format.compass(worst.azimuthDeg)
            let opposite = Format.compass((worst.azimuthDeg + 180).truncatingRemainder(dividingBy: 360))
            recommendation = "The worst blockage is to the \(direction), reaching "
                + "\(Int(worst.peakElevationDeg))° above the horizon. Moving the dish toward "
                + "the \(opposite), or raising it above that height, would clear most of it."
        }

        return ObstructionAdvice(
            totalBlockedFraction: total,
            wedges: wedges,
            worst: worst,
            recommendation: recommendation,
            estimatedImprovement: improvement)
    }

    // MARK: - Trend and anomaly detection

    /// Compares a recent window against a longer baseline, so a slow drift is
    /// caught before it becomes an outage. Returns nil when there is not enough
    /// history to say anything honest.
    struct Trend: Sendable, Equatable {
        var metric: String
        var recentValue: Double
        var baselineValue: Double
        /// Positive means the recent window is higher than baseline.
        var changeFraction: Double
        var isDegradation: Bool
        var summary: String
    }

    static func trends(recent: [Aggregate], baseline: [Aggregate]) -> [Trend] {
        guard recent.count >= 5, baseline.count >= 20 else { return [] }
        var out: [Trend] = []

        func compare(_ name: String, _ pick: (Aggregate) -> Double?,
                     higherIsWorse: Bool, unit: (Double) -> String,
                     minimumChange: Double = 0.15) {
            let recentValues = recent.compactMap(pick)
            let baselineValues = baseline.compactMap(pick)
            guard recentValues.count >= 3, baselineValues.count >= 10 else { return }
            let r = recentValues.mean
            let b = baselineValues.mean
            guard b > 0 else { return }
            let change = (r - b) / b
            guard abs(change) >= minimumChange else { return }
            let worse = higherIsWorse ? change > 0 : change < 0
            let direction = change > 0 ? "up" : "down"
            out.append(Trend(
                metric: name, recentValue: r, baselineValue: b,
                changeFraction: change, isDegradation: worse,
                summary: "\(name) is \(direction) \(Int(abs(change) * 100))% "
                       + "versus the longer baseline (\(unit(r)) vs \(unit(b)))."))
        }

        compare("Latency", { $0.latencyAvg }, higherIsWorse: true,
                unit: { Format.latency($0).combined })
        compare("Downlink", { $0.downAvg }, higherIsWorse: false,
                unit: { Format.bitrate($0).combined }, minimumChange: 0.25)
        compare("Packet loss", { $0.dropAvg > 0 ? $0.dropAvg : nil }, higherIsWorse: true,
                unit: { Format.percent($0, places: 2).combined }, minimumChange: 0.30)
        compare("Power draw", { $0.powerAvg }, higherIsWorse: true,
                unit: { Format.watts($0).combined }, minimumChange: 0.20)

        return out.sorted { $0.isDegradation && !$1.isDegradation }
    }

    /// Peak-hour analysis: which hours of the day are consistently worst. This
    /// is what distinguishes local congestion from a problem with the dish.
    struct HourProfile: Sendable, Identifiable, Equatable {
        var hour: Int
        var downAvg: Double
        var latencyAvg: Double?
        var outageRate: Double
        var id: Int { hour }
    }

    static func hourlyProfile(_ rollups: [Aggregate], calendar: Calendar = .current) -> [HourProfile] {
        var byHour: [Int: [Aggregate]] = [:]
        for row in rollups {
            byHour[calendar.component(.hour, from: row.t), default: []].append(row)
        }
        return (0..<24).map { hour in
            let group = byHour[hour] ?? []
            let recorded = group.reduce(0) { $0 + $1.sampleCount }
            let outages = group.reduce(0) { $0 + $1.outageSeconds }
            return HourProfile(
                hour: hour,
                downAvg: group.map(\.downAvg).mean,
                latencyAvg: group.compactMap(\.latencyAvg).isEmpty
                    ? nil : group.compactMap(\.latencyAvg).mean,
                outageRate: recorded > 0 ? Double(outages) / Double(recorded) : 0)
        }
    }

    /// Estimated energy over a window, from average power. The dish runs
    /// continuously, so this is a real line on an electricity bill.
    static func energyKWh(_ rollups: [Aggregate]) -> Double {
        // Each rollup covers one minute of recorded seconds.
        rollups.reduce(0) { total, row in
            guard let watts = row.powerAvg else { return total }
            return total + watts * Double(row.sampleCount) / 3600 / 1000
        }
    }
}
