import Foundation

/// The shapes Cathode renders.
///
/// Almost everything is optional on purpose: firmware revisions differ in what
/// they report, and a missing value has to read as "unknown" rather than
/// silently as zero — a dish reporting no power figure is not a dish drawing 0 W.

enum DishState: String, Sendable, CaseIterable, Codable {
    case unknown, connected, searching, booting, stowed
    case thermalShutdown, noSats, obstructed, noDownlink, noPings, offline

    var label: String {
        switch self {
        case .unknown: "Unknown"
        case .connected: "Online"
        case .searching: "Searching"
        case .booting: "Booting"
        case .stowed: "Stowed"
        case .thermalShutdown: "Thermal shutdown"
        case .noSats: "No satellites"
        case .obstructed: "Obstructed"
        case .noDownlink: "No downlink"
        case .noPings: "No pings"
        case .offline: "Offline"
        }
    }

    var tone: Tone {
        switch self {
        case .connected: .good
        case .searching, .booting, .obstructed: .warn
        case .thermalShutdown, .noSats, .noDownlink, .noPings, .offline: .bad
        case .stowed, .unknown: .idle
        }
    }
}

enum Tone: String, Sendable {
    case good, warn, bad, idle
}

struct DeviceInfo: Sendable, Codable, Equatable {
    var id: String?
    var hardwareVersion: String?
    var softwareVersion: String?
    var countryCode: String?
    var utcOffsetS: Int?
    var bootcount: Int?
    var generationNumber: Int?
    var manufacturedVersion: String?

    /// Human-facing hardware name. The dish reports codenames like `rev3_proto2`.
    var hardwareName: String? {
        guard let hardwareVersion else { return nil }
        switch hardwareVersion.lowercased() {
        case let v where v.hasPrefix("rev1"): return "Round (Gen 1)"
        case let v where v.hasPrefix("rev2"): return "Rectangular (Gen 2)"
        case let v where v.hasPrefix("rev3"): return "Standard (Gen 3)"
        case let v where v.hasPrefix("rev4"): return "Standard Actuated"
        case let v where v.contains("hp"): return "High Performance"
        case let v where v.contains("mini"): return "Mini"
        default: return hardwareVersion
        }
    }
}

struct ObstructionStats: Sendable, Codable, Equatable {
    /// Fraction 0–1 of the observed sky that is blocked.
    var fractionObstructed: Double?
    var validS: Double?
    var currentlyObstructed: Bool?
    var avgProlongedObstructionIntervalS: Double?
    var timeObstructed: Double?
    var patchesValid: Int?
}

struct AlignmentStats: Sendable, Codable, Equatable {
    /// Where the dish is actually pointing.
    var boresightAzimuthDeg: Double?
    var boresightElevationDeg: Double?
    /// Where it wants to point for the cell it is serving.
    var desiredBoresightAzimuthDeg: Double?
    var desiredBoresightElevationDeg: Double?
    /// Physical mount orientation from the dish's own IMU.
    var tiltAngleDeg: Double?
    var attitudeUncertaintyDeg: Double?

    /// How far off the desired vector the dish currently is, in degrees.
    var pointingErrorDeg: Double? {
        guard let az = boresightAzimuthDeg, let el = boresightElevationDeg,
              let dAz = desiredBoresightAzimuthDeg, let dEl = desiredBoresightElevationDeg
        else { return nil }
        var deltaAz = abs(az - dAz).truncatingRemainder(dividingBy: 360)
        if deltaAz > 180 { deltaAz = 360 - deltaAz }
        // Azimuth error matters less near zenith, where the cone is narrow.
        let scaled = deltaAz * cos(el * .pi / 180)
        return (scaled * scaled + pow(el - dEl, 2)).squareRoot()
    }
}

/// Named alert bits the dish raises. Unrecognised bits are preserved in `raw`.
struct DishAlerts: Sendable, Codable, Equatable {
    var motorsStuck = false
    var thermalThrottle = false
    var thermalShutdown = false
    var mastNotNearVertical = false
    var unexpectedLocation = false
    var slowEthernetSpeeds = false
    var roaming = false
    var installPending = false
    var isHeating = false
    var powerSupplyThermalThrottle = false
    var isPowerSaveIdle = false
    var movingWhileNotMobile = false
    var movingTooFastForPolicy = false
    var dbfTelemStale = false
    var lowMotorCurrent = false
    var lowerSignalThanPredicted = false
    var raw: Int = 0

    var active: [(name: String, tone: Tone)] {
        var out: [(String, Tone)] = []
        if thermalShutdown { out.append(("Thermal shutdown", .bad)) }
        if thermalThrottle { out.append(("Thermal throttling", .warn)) }
        if powerSupplyThermalThrottle { out.append(("Power supply throttling", .warn)) }
        if motorsStuck { out.append(("Motors stuck", .bad)) }
        if lowMotorCurrent { out.append(("Low motor current", .warn)) }
        if mastNotNearVertical { out.append(("Mast not vertical", .warn)) }
        if unexpectedLocation { out.append(("Unexpected location", .warn)) }
        if slowEthernetSpeeds { out.append(("Slow Ethernet link", .warn)) }
        if lowerSignalThanPredicted { out.append(("Signal below prediction", .warn)) }
        if movingWhileNotMobile { out.append(("Moving on a fixed plan", .warn)) }
        if movingTooFastForPolicy { out.append(("Moving too fast for plan", .warn)) }
        if roaming { out.append(("Roaming", .idle)) }
        if installPending { out.append(("Install pending", .idle)) }
        if isHeating { out.append(("Heater active", .idle)) }
        if isPowerSaveIdle { out.append(("Power save idle", .idle)) }
        if dbfTelemStale { out.append(("Beamforming telemetry stale", .warn)) }
        return out
    }

    var isEmpty: Bool { active.isEmpty }
}

/// An in-progress outage as the dish itself reports it, which is more precise
/// about *why* the link is down than anything Cathode could infer.
struct OutageInfo: Sendable, Codable, Equatable {
    var cause: DishState
    var startedAt: Date?
    var duration: TimeInterval?
    var didSwitch: Bool?
}

struct DishStatus: Sendable, Codable, Equatable {
    var timestamp: Date = .now
    var deviceInfo = DeviceInfo()
    var state: DishState = .unknown
    var uptimeS: Int?

    var downlinkBps: Double?
    var uplinkBps: Double?
    /// Round-trip time to the point of presence, in milliseconds.
    var popPingLatencyMs: Double?
    var popPingDropRate: Double?
    var secondsToFirstNonemptySlot: Double?

    var isSnrAboveNoiseFloor: Bool?
    var isSnrPersistentlyLow: Bool?

    /// Watts drawn at the dish's power supply.
    var powerW: Double?

    var obstruction = ObstructionStats()
    var alignment = AlignmentStats()
    var alerts = DishAlerts()
    var outage: OutageInfo?

    var gpsValid: Bool?
    var gpsSats: Int?
    var ethSpeedMbps: Int?
    var bypassMode: Bool?
    var hasActuators: Bool?
    var softwareUpdateState: String?
    var swupdateRebootReady: Bool?

    var isOnline: Bool { state == .connected }

    /// A single 0–100 health figure the dashboard leads with. Weighted so the
    /// things a user actually notices — drops and obstructions — dominate.
    var healthScore: Int {
        var score = 100.0
        if let drop = popPingDropRate { score -= min(45, drop * 45) }
        if let frac = obstruction.fractionObstructed { score -= min(25, frac * 250) }
        if let latency = popPingLatencyMs { score -= min(15, max(0, latency - 45) / 6) }
        if isSnrPersistentlyLow == true { score -= 12 }
        if alerts.thermalShutdown { score -= 40 }
        else if alerts.thermalThrottle { score -= 10 }
        if alerts.motorsStuck { score -= 15 }
        if state != .connected { score -= 30 }
        return Int(max(0, min(100, score.rounded())))
    }
}

/// One second of history from the dish's own 12-hour ring buffer.
struct HistorySample: Sendable, Codable, Equatable, Identifiable {
    var t: Date
    var downlinkBps: Double
    var uplinkBps: Double
    var latencyMs: Double?
    var dropRate: Double
    var powerW: Double?
    /// Signal-to-noise ratio. Newer firmware stopped populating this series, so
    /// it is nil far more often than the others; every consumer must cope.
    var snr: Double?
    var obstructed: Bool
    /// The dish had no scheduled slot in this second. Distinct from an
    /// obstruction: nothing was blocking the sky, the network simply had no
    /// capacity to assign — which is a complaint to Starlink, not a chainsaw.
    var noSchedule: Bool

    var id: Date { t }
    /// A second with total packet loss is an outage second, whatever the cause.
    var isOutage: Bool { dropRate >= 1 }

    /// Why this second was lost, if it was. Attribution is ordered: a second
    /// that is both obstructed and unscheduled is counted as obstructed,
    /// because that is the cause the user can act on.
    enum LossCause: String, Sendable, CaseIterable {
        case obstructed, unscheduled, other

        var label: String {
            switch self {
            case .obstructed: "Obstructed"
            case .unscheduled: "No capacity"
            case .other: "Other"
            }
        }
        var detail: String {
            switch self {
            case .obstructed: "Something blocked the dish's view of the satellite."
            case .unscheduled: "The network had no slot to assign. This is Starlink "
                + "capacity in your cell, not anything at your end."
            case .other: "Lost for a reason the dish did not attribute."
            }
        }
    }

    var lossCause: LossCause? {
        guard isOutage else { return nil }
        if obstructed { return .obstructed }
        if noSchedule { return .unscheduled }
        return .other
    }
}

struct HistoryWindow: Sendable {
    /// Monotonic count of seconds since boot; also the ring's write cursor.
    var current: Int
    var samples: [HistorySample]
}

/// The dish's SNR grid, rendered by Cathode as a polar sky dome.
struct ObstructionMap: Sendable {
    var timestamp: Date
    var rows: Int
    var cols: Int
    /// Row-major. -1 = never observed, 0 = clear, 1 = fully obstructed.
    var data: [Float]
    var minElevationDeg: Double?

    func value(row: Int, col: Int) -> Float {
        guard row >= 0, row < rows, col >= 0, col < cols else { return -1 }
        return data[row * cols + col]
    }
}

struct WifiClient: Sendable, Identifiable, Equatable {
    var macAddress: String?
    var ipAddress: String?
    var name: String?
    /// Signal strength in dBm; absent for wired clients.
    var signalStrength: Double?
    var txBps: Double?
    var rxBps: Double?
    var bytesDown: Double?
    var bytesUp: Double?
    var connectedTimeS: Double?
    var isWifi: Bool?
    var isWired: Bool?
    var band: String?

    var id: String { macAddress ?? ipAddress ?? name ?? UUID().uuidString }
    var displayName: String { name ?? ipAddress ?? macAddress ?? "Unknown device" }

    /// Wi-Fi bars, 0–4, from dBm. Wired clients report full strength.
    var signalBars: Int {
        if isWired == true { return 4 }
        guard let dbm = signalStrength else { return 0 }
        switch dbm {
        case (-55)...: return 4
        case (-67)..<(-55): return 3
        case (-75)..<(-67): return 2
        case (-85)..<(-75): return 1
        default: return 0
        }
    }
}

struct WifiStatus: Sendable {
    var deviceInfo = DeviceInfo()
    var clients: [WifiClient] = []
    var isBypassed: Bool?
    var isRepeater: Bool?
    var pingLatencyMs: Double?
    var pingDropRate: Double?
}

struct SpeedTestResult: Sendable, Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp: Date
    var downlinkBps: Double
    var uplinkBps: Double
    var latencyMs: Double
    /// Latency measured while the link is saturated — the bufferbloat signal.
    var latencyUnderLoadDownMs: Double?
    var latencyUnderLoadUpMs: Double?
}

/// One observation of where the dish was pointing, for the sky track.
struct SkyPoint: Sendable, Equatable, Identifiable {
    var azimuth: Double
    var elevation: Double
    var t: Date
    var id: Date { t }
}

struct DishLocation: Sendable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var altitudeM: Double?
    var uncertaintyM: Double?
}
