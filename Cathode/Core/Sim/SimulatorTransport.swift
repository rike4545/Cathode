import Foundation

/// A `DishTransport` backed by the simulator.
///
/// This deliberately encodes real protobuf responses rather than returning typed
/// values directly. Demo mode therefore exercises the identical framing, field
/// numbering and decode path that hardware does — so a bug in the wire layer
/// shows up in the simulator instead of hiding until someone plugs in a dish.
final class SimulatorTransport: DishTransport {
    let kind: TransportKind = .simulator
    let target = "Simulated dish"

    let simulator: DishSimulator
    /// Adds a plausible LAN round-trip so loading states are real, not skipped.
    private let latency: Duration

    init(simulator: DishSimulator = DishSimulator(), latency: Duration = .milliseconds(28)) {
        self.simulator = simulator
        self.latency = latency
    }

    func unary(method: String, request: Data, timeout: TimeInterval) async throws -> Data {
        try await Task.sleep(for: latency)
        try Task.checkCancellation()

        let envelope = try ProtoMessage(decoding: request)
        guard let op = Operation.allCases.first(where: { envelope.first($0.field) != nil }) else {
            throw GrpcError(.unimplemented, "The simulator does not implement that request.")
        }
        await simulator.advance()

        return switch op {
        case .getStatus: try await statusResponse()
        case .getDeviceInfo: try await deviceInfoResponse()
        case .getHistory: try await historyResponse()
        case .dishGetObstructionMap: try await obstructionMapResponse()
        case .getLocation: try await locationResponse()
        case .speedTest: try await speedTestResponse()
        case .wifiGetStatus, .wifiGetClients: try await wifiResponse(op)
        case .reboot, .dishStow, .dishSetConfig, .dishClearObstructionMap:
            try await controlResponse(op)
        case .dishGetConfig: try await configResponse()
        case .dishGetContext, .getDiagnostics, .wifiGetConfig, .wifiGetDiagnostics:
            throw GrpcError(.unimplemented, "\(op.label) is not simulated.")
        }
    }

    /// Wraps a payload in a `Response` envelope for the given operation.
    private func envelope(_ op: Operation, _ build: (inout ProtoWriter) -> Void) -> Data {
        var payload = ProtoWriter()
        build(&payload)
        var out = ProtoWriter()
        out.varint(1, 1)
        out.bytes(op.field, payload.data)
        return out.data
    }

    private func statusResponse() async throws -> Data {
        let s = await simulator.latest
        let boresight = await simulator.boresight
        let uptime = await simulator.uptimeSeconds
        let fraction = await simulator.obstructionFraction
        let weather = await simulator.weather
        let hw = simulator.hardwareVersion
        let sw = simulator.softwareVersion
        let id = simulator.dishID
        let inOutage = await simulator.isInOutage

        return envelope(.getStatus) { w in
            w.message(F.Status.deviceInfo) { d in
                d.string(F.DeviceInfoF.id, id)
                d.string(F.DeviceInfoF.hardwareVersion, hw)
                d.string(F.DeviceInfoF.softwareVersion, sw)
                d.string(F.DeviceInfoF.countryCode, "US")
                d.varint(F.DeviceInfoF.bootcount, 47)
                d.varint(F.DeviceInfoF.generationNumber, 3)
            }
            w.message(F.Status.deviceState) { d in
                d.varint(F.DeviceState.uptimeS, uptime)
            }
            w.message(F.Status.obstructionStats) { o in
                o.float(F.Obstruction.fractionObstructed, fraction)
                o.float(F.Obstruction.validS, Double(min(uptime, 43_200)))
                o.bool(F.Obstruction.currentlyObstructed, s.obstructed)
                o.float(F.Obstruction.avgProlongedObstructionIntervalS, fraction > 0.001 ? 1800 : .nan)
                o.float(F.Obstruction.timeObstructed, fraction * Double(min(uptime, 43_200)))
                o.varint(F.Obstruction.patchesValid, 1)
            }
            w.message(F.Status.alerts) { a in
                a.bool(3, false)
                a.bool(9, weather.ambientC < 2)
                a.bool(16, s.snr < 6 && !s.obstructed)
            }
            w.float(F.Status.downlinkThroughputBps, s.downlinkBps)
            w.float(F.Status.uplinkThroughputBps, s.uplinkBps)
            w.float(F.Status.popPingLatencyMs, s.dropRate >= 1 ? .nan : s.latencyMs)
            w.float(F.Status.popPingDropRate, s.dropRate)
            w.float(F.Status.secondsToFirstNonemptySlot, 0)
            w.varint(F.Status.ethSpeedMbps, 1000)
            w.message(F.Status.gpsStats) { g in
                g.bool(F.Gps.gpsValid, true)
                g.varint(F.Gps.gpsSats, 12)
            }
            w.bool(F.Status.isSnrAboveNoiseFloor, s.snr > 3)
            w.bool(F.Status.isSnrPersistentlyLow, s.snr < 4)
            w.varint(F.Status.hasActuators, 2)
            w.bool(F.Status.bypassMode, false)
            w.float(F.Status.powerIn, s.powerW)
            w.message(F.Status.alignmentStats) { a in
                a.float(F.Alignment.tiltAngleDeg, 12.4)
                a.float(F.Alignment.boresightAzimuthDeg, boresight.azimuth)
                a.float(F.Alignment.boresightElevationDeg, boresight.elevation)
                a.float(F.Alignment.attitudeUncertaintyDeg, 0.4)
                a.float(F.Alignment.desiredBoresightAzimuthDeg, boresight.azimuth + 0.7)
                a.float(F.Alignment.desiredBoresightElevationDeg, boresight.elevation - 0.4)
            }
            if inOutage || s.obstructed {
                w.message(F.Status.outage) { o in
                    o.varint(F.Outage.cause, s.obstructed ? 6 : 5)
                    o.varint(F.Outage.startTimestampNs,
                             UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
                    o.varint(F.Outage.durationNs, UInt64(4_000_000_000))
                }
            }
        }
    }

    private func deviceInfoResponse() async throws -> Data {
        let hw = simulator.hardwareVersion
        let sw = simulator.softwareVersion
        let id = simulator.dishID
        return envelope(.getDeviceInfo) { w in
            w.string(F.DeviceInfoF.id, id)
            w.string(F.DeviceInfoF.hardwareVersion, hw)
            w.string(F.DeviceInfoF.softwareVersion, sw)
            w.string(F.DeviceInfoF.countryCode, "US")
            w.varint(F.DeviceInfoF.bootcount, 47)
            w.varint(F.DeviceInfoF.generationNumber, 3)
        }
    }

    private func historyResponse() async throws -> Data {
        let current = await simulator.current
        let series = await simulator.series()
        return envelope(.getHistory) { w in
            w.varint(F.History.current, current)
            w.packedFloat(F.History.downlinkThroughputBps, series.down[...])
            w.packedFloat(F.History.uplinkThroughputBps, series.up[...])
            w.packedFloat(F.History.popPingLatencyMs, series.latency[...])
            w.packedFloat(F.History.popPingDropRate, series.drop[...])
            w.packedFloat(F.History.powerIn, series.power[...])
            w.packedFloat(F.History.snr, series.snr[...])
            w.packedVarint(F.History.scheduled, series.scheduled)
            w.packedVarint(F.History.obstructed, series.obstructed)
        }
    }

    private func obstructionMapResponse() async throws -> Data {
        let shape = await simulator.mapShape
        let grid = await simulator.obstructionGrid()
        return envelope(.dishGetObstructionMap) { w in
            w.varint(F.ObstructionMapF.numRows, shape.rows)
            w.varint(F.ObstructionMapF.numCols, shape.cols)
            w.packedFloat(F.ObstructionMapF.snr, grid[...])
            w.float(F.ObstructionMapF.minElevationDeg, 20)
        }
    }

    private func locationResponse() async throws -> Data {
        let lat = simulator.latitude
        let lon = simulator.longitude
        return envelope(.getLocation) { w in
            w.message(F.Location.lla) { l in
                l.double(F.Lla.lat, lat)
                l.double(F.Lla.lon, lon)
                l.double(F.Lla.alt, 264.3)
            }
            w.float(F.Location.sigmaM, 4.2)
        }
    }

    private func speedTestResponse() async throws -> Data {
        // A real test saturates the link for roughly half a minute. Compress
        // that, but keep it slow enough that the progress UI is exercised.
        try await Task.sleep(for: .seconds(4))
        let result = await simulator.runSpeedTest()
        return envelope(.speedTest) { w in
            w.float(F.SpeedTest.downlinkBps, result.down)
            w.float(F.SpeedTest.uplinkBps, result.up)
            w.float(F.SpeedTest.latencyMs, result.latency)
            w.float(F.SpeedTest.latencyUnderLoadDownMs, result.loadDown)
            w.float(F.SpeedTest.latencyUnderLoadUpMs, result.loadUp)
        }
    }

    private func wifiResponse(_ op: Operation) async throws -> Data {
        let clients = await Self.simulatedClients(simulator)
        return envelope(op) { w in
            w.message(F.WifiStatusF.deviceInfo) { d in
                d.string(F.DeviceInfoF.id, "ut01000000-router-0092c4f1")
                d.string(F.DeviceInfoF.hardwareVersion, "mn02")
                d.string(F.DeviceInfoF.softwareVersion, "2026.32.0.mr58982")
            }
            for c in clients {
                w.message(F.WifiStatusF.clients) { cw in
                    cw.stringIfSet(F.WifiClientF.macAddress, c.macAddress)
                    cw.stringIfSet(F.WifiClientF.ipAddress, c.ipAddress)
                    cw.stringIfSet(F.WifiClientF.name, c.name)
                    if let signal = c.signalStrength { cw.float(F.WifiClientF.signalStrength, signal) }
                    cw.float(F.WifiClientF.txBps, c.txBps ?? 0)
                    cw.float(F.WifiClientF.rxBps, c.rxBps ?? 0)
                    cw.float(F.WifiClientF.bytesDown, c.bytesDown ?? 0)
                    cw.float(F.WifiClientF.bytesUp, c.bytesUp ?? 0)
                    cw.float(F.WifiClientF.connectedTimeS, c.connectedTimeS ?? 0)
                    cw.boolIfSet(F.WifiClientF.isWifi, c.isWifi)
                    cw.boolIfSet(F.WifiClientF.isWired, c.isWired)
                    cw.stringIfSet(F.WifiClientF.band, c.band)
                }
            }
            w.float(F.WifiStatusF.pingLatencyMs, 3.1)
            w.float(F.WifiStatusF.pingDropRate, 0)
            w.bool(F.WifiStatusF.isBypassed, false)
            w.bool(F.WifiStatusF.isRepeater, false)
        }
    }

    private func controlResponse(_ op: Operation) async throws -> Data {
        try await Task.sleep(for: .milliseconds(400))
        return envelope(op) { _ in }
    }

    private func configResponse() async throws -> Data {
        envelope(.dishGetConfig) { w in
            w.message(1) { c in
                c.varint(3, 0)      // snow melt: automatic
                c.bool(6, false)    // power save off
                c.varint(7, 0)
                c.varint(8, 0)
                c.bool(9, false)
            }
        }
    }

    /// A believable household: a mix of bands, wired gear, and idle devices.
    private static func simulatedClients(_ sim: DishSimulator) async -> [WifiClient] {
        let total = await sim.latest
        let counters = await sim.clientBytes
        let share = DishSimulator.clientShares
        let devices: [(String, String, String, Double?, Bool)] = [
            ("Living Room TV", "4c:32:75:9a:1b:03", "192.168.1.24", -52, false),
            ("Bryan's iPhone", "a8:66:7f:11:d4:9e", "192.168.1.31", -61, false),
            ("Studio iMac", "3c:22:fb:0d:77:52", "192.168.1.11", nil, true),
            ("Office Laptop", "f0:18:98:6c:2a:14", "192.168.1.42", -68, false),
            ("Nest Thermostat", "18:b4:30:5f:c1:88", "192.168.1.58", -74, false),
            ("Garage Camera", "b8:27:eb:44:19:a0", "192.168.1.63", -81, false),
            ("Kitchen Speaker", "44:07:0b:9e:3c:21", "192.168.1.70", -70, false),
        ]
        return devices.enumerated().map { index, d in
            let weight = share[safe: index] ?? 0.01
            return WifiClient(
                macAddress: d.1, ipAddress: d.2, name: d.0,
                signalStrength: d.3,
                txBps: total.uplinkBps * weight,
                rxBps: total.downlinkBps * weight,
                bytesDown: counters[d.1]?.down ?? 0,
                bytesUp: counters[d.1]?.up ?? 0,
                connectedTimeS: Double(3600 * (index + 2)),
                isWifi: !d.4, isWired: d.4,
                band: d.4 ? nil : (index % 3 == 0 ? "5 GHz" : "2.4 GHz"))
        }
    }
}
