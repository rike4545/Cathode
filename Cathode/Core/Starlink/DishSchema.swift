import Foundation

/// Field-number map for `SpaceX.API.Device.Request` / `Response`.
///
/// **Read this before trusting the numbers.** Starlink's Device API is not
/// publicly documented. These are the community-known field numbers used across
/// the open-source tooling ecosystem — a well-supported starting point, not a
/// specification. Cathode is built so that being wrong here degrades gracefully:
///
///  * The structural decoder never mis-labels a field it cannot find; it reports
///    the value as unknown, and Diagnostics lists exactly which lookups missed.
///  * `Operation.allCases` is probed at connect time, so an operation whose
///    number has moved shows up as unsupported rather than as bad data.
///  * Demo mode encodes responses with these same numbers, so the whole decode
///    path is exercised end to end regardless of what hardware is present.
enum Operation: String, CaseIterable, Sendable {
    case getStatus, getDeviceInfo, getHistory, reboot, speedTest, getLocation
    case getDiagnostics, dishStow, dishGetContext, dishGetObstructionMap
    case dishGetConfig, dishSetConfig, dishClearObstructionMap
    case wifiGetClients, wifiGetStatus, wifiGetConfig, wifiGetDiagnostics

    /// Field number of this operation's arm on the request/response oneof.
    /// The two envelopes mirror each other.
    var field: Int {
        switch self {
        case .reboot: 1001
        case .getStatus: 1003
        case .getDeviceInfo: 1004
        case .getHistory: 1005
        case .speedTest: 1013
        case .getLocation: 1015
        case .getDiagnostics: 1017
        case .dishStow: 2002
        case .dishGetContext: 2003
        case .dishGetObstructionMap: 2004
        case .dishGetConfig: 2011
        case .dishSetConfig: 2012
        case .dishClearObstructionMap: 2013
        case .wifiGetClients: 3002
        case .wifiGetStatus: 3005
        case .wifiGetConfig: 3009
        case .wifiGetDiagnostics: 3013
        }
    }

    var label: String {
        switch self {
        case .getStatus: "Status"
        case .getDeviceInfo: "Device info"
        case .getHistory: "History"
        case .reboot: "Reboot"
        case .speedTest: "Speed test"
        case .getLocation: "Location"
        case .getDiagnostics: "Diagnostics"
        case .dishStow: "Stow"
        case .dishGetContext: "Context"
        case .dishGetObstructionMap: "Obstruction map"
        case .dishGetConfig: "Read config"
        case .dishSetConfig: "Write config"
        case .dishClearObstructionMap: "Reset obstruction map"
        case .wifiGetClients: "Router clients"
        case .wifiGetStatus: "Router status"
        case .wifiGetConfig: "Router config"
        case .wifiGetDiagnostics: "Router diagnostics"
        }
    }

    /// Operations that change hardware state and must never run automatically.
    var isMutating: Bool {
        switch self {
        case .reboot, .dishStow, .dishSetConfig, .dishClearObstructionMap: true
        default: false
        }
    }
}

/// Field numbers inside the nested response messages.
enum F {
    enum Status {
        static let deviceInfo = 1, deviceState = 2, obstructionStats = 3, alerts = 5
        static let downlinkThroughputBps = 6, uplinkThroughputBps = 7
        static let popPingLatencyMs = 8, popPingDropRate = 9, secondsToFirstNonemptySlot = 10
        static let boresightAzimuthDeg = 11, boresightElevationDeg = 12, ethSpeedMbps = 13
        static let outage = 14
        static let gpsStats = 20, softwareUpdateState = 22
        static let isSnrAboveNoiseFloor = 24, hasActuators = 25
        static let swupdateRebootReady = 28, bypassMode = 29, isSnrPersistentlyLow = 30
        static let powerIn = 32, alignmentStats = 34
    }
    enum DeviceState { static let uptimeS = 1 }
    enum Outage {
        static let cause = 1, startTimestampNs = 2, durationNs = 3, didSwitch = 4
    }
    enum DeviceInfoF {
        static let id = 1, hardwareVersion = 2, softwareVersion = 3, countryCode = 4
        static let utcOffsetS = 5, bootcount = 9, generationNumber = 13, manufacturedVersion = 15
    }
    enum Obstruction {
        static let fractionObstructed = 1, validS = 3, currentlyObstructed = 5
        static let avgProlongedObstructionIntervalS = 6, timeObstructed = 8, patchesValid = 10
    }
    enum Alignment {
        static let tiltAngleDeg = 1, boresightAzimuthDeg = 2, boresightElevationDeg = 3
        static let attitudeUncertaintyDeg = 5
        static let desiredBoresightAzimuthDeg = 6, desiredBoresightElevationDeg = 7
    }
    enum Gps { static let gpsValid = 1, gpsSats = 2 }
    enum History {
        static let current = 1
        static let popPingDropRate = 1000, snr = 1001, popPingLatencyMs = 1002
        static let downlinkThroughputBps = 1003, uplinkThroughputBps = 1004
        static let scheduled = 1006, obstructed = 1007, powerIn = 1008
    }
    enum ObstructionMapF { static let numRows = 1, numCols = 2, snr = 3, minElevationDeg = 4 }
    enum SpeedTest {
        static let downlinkBps = 1, uplinkBps = 2, latencyMs = 3
        static let latencyUnderLoadDownMs = 4, latencyUnderLoadUpMs = 5
    }
    enum Location { static let lla = 1, sigmaM = 3 }
    enum Lla { static let lat = 1, lon = 2, alt = 3 }
    enum WifiStatusF {
        static let deviceInfo = 1, clients = 3, pingLatencyMs = 5, pingDropRate = 6
        static let isBypassed = 9, isRepeater = 10
    }
    enum WifiClientF {
        static let macAddress = 1, ipAddress = 2, name = 4, signalStrength = 6
        static let txBps = 7, rxBps = 8, bytesDown = 9, bytesUp = 10
        static let connectedTimeS = 11, isWifi = 12, isWired = 13, band = 15
    }
    /// Bit positions on `DishAlerts`, in declared field order.
    static var alertFields: [(Int, WritableKeyPath<DishAlerts, Bool>)] { [
        (1, \.motorsStuck), (2, \.thermalThrottle), (3, \.thermalShutdown),
        (4, \.mastNotNearVertical), (5, \.unexpectedLocation), (6, \.slowEthernetSpeeds),
        (7, \.roaming), (8, \.installPending), (9, \.isHeating),
        (10, \.powerSupplyThermalThrottle), (11, \.isPowerSaveIdle),
        (12, \.movingWhileNotMobile), (13, \.movingTooFastForPolicy),
        (14, \.dbfTelemStale), (15, \.lowMotorCurrent), (16, \.lowerSignalThanPredicted),
    ] }
    /// The dish's outage-cause enum, which doubles as its unhealthy-state enum.
    static let outageCause: [Int: DishState] = [
        0: .unknown, 1: .booting, 2: .stowed, 3: .thermalShutdown, 4: .noDownlink,
        5: .noSats, 6: .obstructed, 7: .noDownlink, 8: .noPings, 9: .searching,
    ]
}
