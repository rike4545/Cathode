import Foundation

/// Formatting for telemetry.
///
/// Every readout is split into a value and a unit so the UI can typeset them
/// separately — big monospaced digits, small unit label — and so a value never
/// changes width as it crosses a magnitude boundary mid-stream.
enum Format {

    struct Measured {
        let value: String
        let unit: String
        /// Percent and degree signs sit tight against the number; every other
        /// unit takes a space, per SI convention.
        var combined: String {
            (unit == "%" || unit == "°") ? "\(value)\(unit)" : "\(value) \(unit)"
        }
    }

    /// Bits per second, scaled to the unit a person would actually say.
    static func bitrate(_ bps: Double?, precision: Int? = nil) -> Measured {
        guard let bps, bps.isFinite, bps >= 0 else { return Measured(value: "—", unit: "Mbps") }
        switch bps {
        case ..<1_000:
            return Measured(value: decimal(bps, places: 0), unit: "bps")
        case ..<1_000_000:
            return Measured(value: decimal(bps / 1_000, places: precision ?? 0), unit: "kbps")
        case ..<1_000_000_000:
            let mbps = bps / 1_000_000
            return Measured(value: decimal(mbps, places: precision ?? (mbps < 10 ? 1 : 0)),
                            unit: "Mbps")
        default:
            return Measured(value: decimal(bps / 1_000_000_000, places: precision ?? 2),
                            unit: "Gbps")
        }
    }

    /// Byte volumes, for data-usage screens. Uses decimal units, matching how
    /// ISPs and Starlink itself report allowances.
    static func bytes(_ value: Double?) -> Measured {
        guard let value, value.isFinite, value >= 0 else { return Measured(value: "—", unit: "GB") }
        switch value {
        case ..<1_000: return Measured(value: decimal(value, places: 0), unit: "B")
        case ..<1_000_000: return Measured(value: decimal(value / 1_000, places: 0), unit: "kB")
        case ..<1_000_000_000: return Measured(value: decimal(value / 1_000_000, places: 1), unit: "MB")
        case ..<1_000_000_000_000:
            let gb = value / 1_000_000_000
            return Measured(value: decimal(gb, places: gb < 10 ? 2 : gb < 100 ? 1 : 0), unit: "GB")
        default:
            let tb = value / 1_000_000_000_000
            return Measured(value: decimal(tb, places: tb < 10 ? 2 : 1), unit: "TB")
        }
    }

    static func latency(_ ms: Double?) -> Measured {
        guard let ms, ms.isFinite, ms > 0 else { return Measured(value: "—", unit: "ms") }
        return Measured(value: decimal(ms, places: ms < 100 ? 1 : 0), unit: "ms")
    }

    static func watts(_ w: Double?) -> Measured {
        guard let w, w.isFinite, w >= 0 else { return Measured(value: "—", unit: "W") }
        return Measured(value: decimal(w, places: w < 100 ? 1 : 0), unit: "W")
    }

    /// Energy over a window, from an average wattage.
    static func energy(kWh: Double?) -> Measured {
        guard let kWh, kWh.isFinite, kWh >= 0 else { return Measured(value: "—", unit: "kWh") }
        if kWh < 1 { return Measured(value: decimal(kWh * 1000, places: 0), unit: "Wh") }
        return Measured(value: decimal(kWh, places: 2), unit: "kWh")
    }

    static func percent(_ fraction: Double?, places: Int = 1) -> Measured {
        guard let fraction, fraction.isFinite else { return Measured(value: "—", unit: "%") }
        return Measured(value: decimal(fraction * 100, places: places), unit: "%")
    }

    static func degrees(_ value: Double?, places: Int = 1) -> Measured {
        guard let value, value.isFinite else { return Measured(value: "—", unit: "°") }
        return Measured(value: decimal(value, places: places), unit: "°")
    }

    static func dbm(_ value: Double?) -> Measured {
        guard let value, value.isFinite else { return Measured(value: "—", unit: "dBm") }
        return Measured(value: decimal(value, places: 0), unit: "dBm")
    }

    /// Compact duration: `4d 6h`, `2h 14m`, `47s`. Always at most two units, so
    /// it stays the same visual width as it counts.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m" }
        return "\(secs)s"
    }

    /// Longer-form duration for outage rows, where precision matters.
    static func preciseDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 { return String(format: "%.0f sec", seconds) }
        if seconds < 3_600 {
            return String(format: "%d min %02d sec", Int(seconds) / 60, Int(seconds) % 60)
        }
        return String(format: "%d hr %02d min", Int(seconds) / 3_600, (Int(seconds) % 3_600) / 60)
    }

    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(max(0, places))f", value)
    }

    /// Clock time in the user's locale, seconds included for live readouts.
    static func clock(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(seconds ? "jmmss" : "jmm")
        return f.string(from: date)
    }

    static func dayAndTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f.string(from: date)
    }

    /// "12 sec ago", "4 min ago". Kept terse for the status bar.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 2 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed)) sec ago" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) hr ago" }
        return "\(Int(elapsed / 86_400)) days ago"
    }

    /// Azimuth as a compass point, which is far easier to act on than a number
    /// when someone is standing outside deciding where to move a dish.
    static func compass(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return "—" }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 22.5).rounded()) % 16
        return points[index]
    }
}
