import Foundation

/// Structural decoders: raw protobuf field maps → Cathode's typed shapes.
enum DishDecode {

    /// Pulls the payload for `op` out of a `Response` envelope.
    static func unwrap(_ responseBytes: Data, _ op: Operation) throws -> ProtoMessage? {
        try ProtoMessage(decoding: responseBytes).message(op.field)
    }

    static func deviceInfo(_ m: ProtoMessage?) -> DeviceInfo {
        guard let m else { return DeviceInfo() }
        return DeviceInfo(
            id: m.string(F.DeviceInfoF.id),
            hardwareVersion: m.string(F.DeviceInfoF.hardwareVersion),
            softwareVersion: m.string(F.DeviceInfoF.softwareVersion),
            countryCode: m.string(F.DeviceInfoF.countryCode),
            utcOffsetS: m.int(F.DeviceInfoF.utcOffsetS),
            bootcount: m.int(F.DeviceInfoF.bootcount),
            generationNumber: m.int(F.DeviceInfoF.generationNumber),
            manufacturedVersion: m.string(F.DeviceInfoF.manufacturedVersion))
    }

    static func status(_ m: ProtoMessage?, at timestamp: Date = .now) -> DishStatus {
        guard let m else { return DishStatus(timestamp: timestamp) }
        let deviceState = m.message(F.Status.deviceState)
        let obstruction = obstructionStats(m.message(F.Status.obstructionStats))
        let alerts = dishAlerts(m.message(F.Status.alerts))
        let gps = m.message(F.Status.gpsStats)

        var status = DishStatus(timestamp: timestamp)
        status.deviceInfo = deviceInfo(m.message(F.Status.deviceInfo))
        status.uptimeS = deviceState?.int(F.DeviceState.uptimeS)
        status.downlinkBps = nonNegative(m.double(F.Status.downlinkThroughputBps))
        status.uplinkBps = nonNegative(m.double(F.Status.uplinkThroughputBps))
        status.popPingLatencyMs = positive(m.double(F.Status.popPingLatencyMs))
        status.popPingDropRate = clamp01(m.double(F.Status.popPingDropRate))
        status.secondsToFirstNonemptySlot = finite(m.double(F.Status.secondsToFirstNonemptySlot))
        status.isSnrAboveNoiseFloor = m.bool(F.Status.isSnrAboveNoiseFloor)
        status.isSnrPersistentlyLow = m.bool(F.Status.isSnrPersistentlyLow)
        status.powerW = nonNegative(m.double(F.Status.powerIn))
        status.obstruction = obstruction
        status.alignment = alignmentStats(m.message(F.Status.alignmentStats), fallback: m)
        status.alerts = alerts
        status.gpsValid = gps?.bool(F.Gps.gpsValid)
        status.gpsSats = gps?.int(F.Gps.gpsSats)
        status.ethSpeedMbps = m.int(F.Status.ethSpeedMbps)
        status.bypassMode = m.bool(F.Status.bypassMode)
        status.hasActuators = m.bool(F.Status.hasActuators) ?? (m.int(F.Status.hasActuators) == 2)
        status.softwareUpdateState = m.int(F.Status.softwareUpdateState).map(String.init)
        status.swupdateRebootReady = m.bool(F.Status.swupdateRebootReady)
        status.outage = outageInfo(m.message(F.Status.outage))
        status.state = deriveState(m, outage: status.outage,
                                   obstruction: obstruction, alerts: alerts)
        return status
    }

    /// The dish's state enum does not cover everything a user would call a
    /// problem — an obstructed dish still reports CONNECTED. Fold the alert bits
    /// and drop rate in so the UI shows the state people actually mean.
    private static func deriveState(
        _ m: ProtoMessage, outage: OutageInfo?, obstruction: ObstructionStats, alerts: DishAlerts
    ) -> DishState {
        // The dish's own outage report is the most precise signal available.
        let base = outage?.cause ?? .unknown
        if base != .unknown && base != .connected { return base }
        if alerts.thermalShutdown { return .thermalShutdown }
        let drop = m.double(F.Status.popPingDropRate) ?? 0
        if drop >= 1 { return obstruction.currentlyObstructed == true ? .obstructed : .noPings }
        if obstruction.currentlyObstructed == true { return .obstructed }
        if base == .unknown && (m.double(F.Status.downlinkThroughputBps) ?? 0) > 0 { return .connected }
        return base
    }

    static func outageInfo(_ m: ProtoMessage?) -> OutageInfo? {
        guard let m, !m.isEmpty else { return nil }
        let cause = m.int(F.Outage.cause).flatMap { F.outageCause[$0] } ?? .unknown
        // An UNKNOWN cause with no timing is the dish saying "nothing is wrong".
        let startNs = m.uint(F.Outage.startTimestampNs)
        let durationNs = m.uint(F.Outage.durationNs)
        if cause == .unknown, startNs == nil, durationNs == nil { return nil }
        return OutageInfo(
            cause: cause,
            startedAt: startNs.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) },
            duration: durationNs.map { Double($0) / 1_000_000_000 },
            didSwitch: m.bool(F.Outage.didSwitch))
    }

    static func obstructionStats(_ m: ProtoMessage?) -> ObstructionStats {
        guard let m else { return ObstructionStats() }
        return ObstructionStats(
            fractionObstructed: clamp01(m.double(F.Obstruction.fractionObstructed)),
            validS: finite(m.double(F.Obstruction.validS)),
            currentlyObstructed: m.bool(F.Obstruction.currentlyObstructed),
            avgProlongedObstructionIntervalS: finite(m.double(F.Obstruction.avgProlongedObstructionIntervalS)),
            timeObstructed: finite(m.double(F.Obstruction.timeObstructed)),
            patchesValid: m.int(F.Obstruction.patchesValid))
    }

    static func alignmentStats(_ m: ProtoMessage?, fallback: ProtoMessage?) -> AlignmentStats {
        AlignmentStats(
            // Newer firmware nests boresight under alignment_stats; older builds
            // put it at the top level of the status message.
            boresightAzimuthDeg: finite(m?.double(F.Alignment.boresightAzimuthDeg))
                ?? finite(fallback?.double(F.Status.boresightAzimuthDeg)),
            boresightElevationDeg: finite(m?.double(F.Alignment.boresightElevationDeg))
                ?? finite(fallback?.double(F.Status.boresightElevationDeg)),
            desiredBoresightAzimuthDeg: finite(m?.double(F.Alignment.desiredBoresightAzimuthDeg)),
            desiredBoresightElevationDeg: finite(m?.double(F.Alignment.desiredBoresightElevationDeg)),
            tiltAngleDeg: finite(m?.double(F.Alignment.tiltAngleDeg)),
            attitudeUncertaintyDeg: finite(m?.double(F.Alignment.attitudeUncertaintyDeg)))
    }

    static func dishAlerts(_ m: ProtoMessage?) -> DishAlerts {
        var alerts = DishAlerts()
        guard let m else { return alerts }
        var raw = 0
        for (field, keyPath) in F.alertFields {
            guard let value = m.bool(field) else { continue }
            alerts[keyPath: keyPath] = value
            if value { raw |= 1 << (field - 1) }
        }
        alerts.raw = raw
        return alerts
    }

    /// The dish's history is a fixed-size ring (12 hours at 1 Hz). `current`
    /// counts seconds since boot, so `current % size` is where the newest sample
    /// sits and the buffer has to be rotated back into chronological order.
    static func history(_ m: ProtoMessage?, now: Date = .now, limit: Int? = nil) -> HistoryWindow {
        guard let m else { return HistoryWindow(current: 0, samples: []) }
        let current = m.int(F.History.current) ?? 0
        let downlink = m.floatArray(F.History.downlinkThroughputBps)
        let uplink = m.floatArray(F.History.uplinkThroughputBps)
        let latency = m.floatArray(F.History.popPingLatencyMs)
        let drop = m.floatArray(F.History.popPingDropRate)
        let power = m.floatArray(F.History.powerIn)
        let scheduled = m.boolArray(F.History.scheduled)
        let obstructed = m.boolArray(F.History.obstructed)

        let size = max(downlink.count, uplink.count, latency.count, drop.count)
        guard size > 0 else { return HistoryWindow(current: current, samples: []) }

        // Only `current` of the ring is populated until the dish has been up 12h.
        let count = min(size, current, limit ?? size)
        guard count > 0 else { return HistoryWindow(current: current, samples: []) }

        var samples = [HistorySample]()
        samples.reserveCapacity(count)
        let newest = current - 1

        for i in 0..<count {
            // Walk backwards from newest so index 0 is the oldest retained sample.
            let age = count - 1 - i
            let idx = ((newest - age) % size + size) % size
            let dropRate = clamp01(drop[safe: idx]) ?? 0
            samples.append(HistorySample(
                t: now.addingTimeInterval(-Double(age)),
                downlinkBps: max(0, downlink[safe: idx] ?? 0),
                uplinkBps: max(0, uplink[safe: idx] ?? 0),
                latencyMs: positive(latency[safe: idx]),
                dropRate: dropRate,
                powerW: power.isEmpty ? nil : nonNegative(power[safe: idx]),
                obstructed: obstructed[safe: idx] ?? false,
                noSchedule: !(scheduled[safe: idx] ?? true)))
        }
        return HistoryWindow(current: current, samples: samples)
    }

    static func obstructionMap(_ m: ProtoMessage?, now: Date = .now) -> ObstructionMap? {
        guard let m else { return nil }
        let rows = m.int(F.ObstructionMapF.numRows) ?? 0
        let cols = m.int(F.ObstructionMapF.numCols) ?? 0
        let snr = m.floatArray(F.ObstructionMapF.snr)
        guard rows > 0, cols > 0, snr.count >= rows * cols else { return nil }
        return ObstructionMap(
            timestamp: now, rows: rows, cols: cols,
            data: snr.prefix(rows * cols).map(Float.init),
            minElevationDeg: finite(m.double(F.ObstructionMapF.minElevationDeg)))
    }

    static func speedTest(_ m: ProtoMessage?, now: Date = .now) -> SpeedTestResult {
        SpeedTestResult(
            timestamp: now,
            downlinkBps: max(0, m?.double(F.SpeedTest.downlinkBps) ?? 0),
            uplinkBps: max(0, m?.double(F.SpeedTest.uplinkBps) ?? 0),
            latencyMs: max(0, m?.double(F.SpeedTest.latencyMs) ?? 0),
            latencyUnderLoadDownMs: positive(m?.double(F.SpeedTest.latencyUnderLoadDownMs)),
            latencyUnderLoadUpMs: positive(m?.double(F.SpeedTest.latencyUnderLoadUpMs)))
    }

    static func location(_ m: ProtoMessage?) -> DishLocation {
        let lla = m?.message(F.Location.lla)
        return DishLocation(
            latitude: finite(lla?.double(F.Lla.lat)),
            longitude: finite(lla?.double(F.Lla.lon)),
            altitudeM: finite(lla?.double(F.Lla.alt)),
            uncertaintyM: finite(m?.double(F.Location.sigmaM)))
    }

    static func wifiStatus(_ m: ProtoMessage?) -> WifiStatus {
        guard let m else { return WifiStatus() }
        let clients = m.messages(F.WifiStatusF.clients).map { c in
            WifiClient(
                macAddress: c.string(F.WifiClientF.macAddress),
                ipAddress: c.string(F.WifiClientF.ipAddress),
                name: c.string(F.WifiClientF.name),
                signalStrength: finite(c.double(F.WifiClientF.signalStrength)),
                txBps: nonNegative(c.double(F.WifiClientF.txBps)),
                rxBps: nonNegative(c.double(F.WifiClientF.rxBps)),
                bytesDown: nonNegative(c.double(F.WifiClientF.bytesDown)),
                bytesUp: nonNegative(c.double(F.WifiClientF.bytesUp)),
                connectedTimeS: nonNegative(c.double(F.WifiClientF.connectedTimeS)),
                isWifi: c.bool(F.WifiClientF.isWifi),
                isWired: c.bool(F.WifiClientF.isWired),
                band: c.string(F.WifiClientF.band))
        }
        return WifiStatus(
            deviceInfo: deviceInfo(m.message(F.WifiStatusF.deviceInfo)),
            clients: clients,
            isBypassed: m.bool(F.WifiStatusF.isBypassed),
            isRepeater: m.bool(F.WifiStatusF.isRepeater),
            pingLatencyMs: positive(m.double(F.WifiStatusF.pingLatencyMs)),
            pingDropRate: clamp01(m.double(F.WifiStatusF.pingDropRate)))
    }

    // MARK: - Numeric hygiene
    //
    // The dish emits NaN and sentinel values for "not measured". Normalising
    // them to nil at this boundary keeps every chart and stat tile downstream
    // free of defensive checks.

    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
    private static func nonNegative(_ v: Double?) -> Double? {
        guard let v = finite(v) else { return nil }
        return max(0, v)
    }
    private static func positive(_ v: Double?) -> Double? {
        guard let v = finite(v), v > 0 else { return nil }
        return v
    }
    private static func clamp01(_ v: Double?) -> Double? {
        guard let v = finite(v) else { return nil }
        return min(1, max(0, v))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
