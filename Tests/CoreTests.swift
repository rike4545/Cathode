import Foundation

/// A dependency-free test harness for Cathode's wire and analysis layers.
///
/// These are the parts where a silent mistake is invisible in the UI — a
/// mis-decoded array still draws a chart, it just draws the wrong one. The
/// packed-float width bug that motivated this file did exactly that: power
/// decoded as float64 instead of float32 and rendered as a plausible-looking
/// line at 1e12 watts.
///
/// Run with `Tests/run.sh`.

// Swift 6 forbids mutable globals without an explicit opt-out; this harness is
// strictly single-threaded, so the unchecked annotation is accurate.
@MainActor var failures = 0
@MainActor var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL  \(message)")
    }
}

@MainActor
func checkClose(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    check(abs(actual - expected) <= tolerance,
          "\(message) — got \(actual), expected \(expected) ±\(tolerance)")
}

@MainActor
func suite(_ name: String, _ body: () async throws -> Void) async {
    print("\n\(name)")
    do { try await body() } catch {
        failures += 1
        print("  FAIL  threw \(error)")
    }
}

@main
enum CoreTests {
  @MainActor
  static func main() async {

// MARK: - Protobuf round-trips

await suite("Protobuf wire format") {
    var w = ProtoWriter()
    w.varint(1, 300)
    w.string(2, "rev3_proto2")
    w.float(3, 42.5)
    w.double(4, 1234.5678)
    w.bool(5, true)
    w.message(6) { inner in inner.varint(1, 7) }

    let m = try ProtoMessage(decoding: w.data)
    check(m.uint(1) == 300, "varint round-trip")
    check(m.string(2) == "rev3_proto2", "string round-trip")
    checkClose(m.double(3) ?? 0, 42.5, tolerance: 0.001, "float32 round-trip")
    checkClose(m.double(4) ?? 0, 1234.5678, tolerance: 0.0001, "float64 round-trip")
    check(m.bool(5) == true, "bool round-trip")
    check(m.message(6)?.uint(1) == 7, "nested message round-trip")
    check(m.uint(99) == nil, "absent field reads as nil, not zero")
}

await suite("Packed arrays declare their width") {
    // The regression: an even-length float32 array is also a valid length for a
    // float64 array. Width has to come from the schema, never from the bytes.
    let watts: [Float] = (0..<1000).map { 42 + Float($0 % 60) * 0.5 }
    var w = ProtoWriter()
    w.packedFloat(1, watts[...])
    let m = try ProtoMessage(decoding: w.data)

    let decoded = m.floatArray(1)
    check(decoded.count == watts.count, "packed float32 count preserved")
    checkClose(decoded.max() ?? 0, Double(watts.max() ?? 0), tolerance: 0.01,
               "packed float32 values preserved")
    check(decoded.allSatisfy { $0 > 0 && $0 < 1000 },
          "no value escapes a plausible watt range")

    // And an explicit float64 array still works when the schema says so.
    var w64 = ProtoWriter()
    for v in [1.5, 2.5, 3.5] { w64.double(2, v) }
    let m64 = try ProtoMessage(decoding: w64.data)
    checkClose(m64.floatArray(2, width: .float64).reduce(0, +), 7.5, tolerance: 0.001,
               "unpacked float64 round-trip")
}

await suite("gRPC framing") {
    let payload = Data([1, 2, 3, 4, 5])
    let framed = GrpcFrame.frame(payload)
    check(framed.count == payload.count + 5, "frame adds a 5-byte prefix")
    let parsed = GrpcFrame.parse(framed)
    check(parsed.count == 1 && parsed[0].payload == payload, "frame round-trip")
    check(parsed[0].isTrailer == false, "message frame is not a trailer")

    let trailers = GrpcFrame.parseTrailers(Data("grpc-status: 0\r\ngrpc-message: ok".utf8))
    check(trailers["grpc-status"] == "0", "trailer status parsed")
    check(trailers["grpc-message"] == "ok", "trailer message parsed")
}

// MARK: - End-to-end through the simulator

await suite("Simulator telemetry decodes to sane values") {
    let transport = SimulatorTransport(latency: .zero)
    let client = DishClient(transport: transport)

    let status = try await client.status()
    check(status.deviceInfo.hardwareVersion == "rev3_proto2", "hardware version decoded")
    check(status.uptimeS ?? 0 > 0, "uptime decoded")
    checkClose(status.powerW ?? 0, 70, tolerance: 90, "power is in watts, not gigawatts")
    check((status.downlinkBps ?? 0) < 1e10, "downlink is a believable bitrate")
    check(status.alignment.boresightAzimuthDeg != nil, "boresight azimuth decoded")

    let history = try await client.history()
    check(history.samples.count > 100, "history returns a populated ring")
    let powers = history.samples.compactMap(\.powerW)
    check(!powers.isEmpty, "history carries a power series")
    check(powers.allSatisfy { $0 > 0 && $0 < 500 },
          "every history power sample is a plausible wattage")
    let rates = history.samples.map(\.downlinkBps)
    check(rates.allSatisfy { $0 >= 0 && $0 < 1e10 },
          "every history throughput sample is a plausible bitrate")
    check(history.samples.map(\.t).sorted() == history.samples.map(\.t),
          "history is returned in chronological order")

    let map = try await client.obstructionMap()
    check(map?.rows == 123 && map?.cols == 123, "obstruction map is the expected shape")
    check(map?.data.allSatisfy { $0 >= -1 && $0 <= 1 } == true,
          "obstruction cells stay in [-1, 1]")

    let speed = try await client.speedTest()
    check(speed.downlinkBps > 1e6, "speed test returns a real downlink figure")
    check((speed.latencyUnderLoadDownMs ?? 0) >= speed.latencyMs,
          "loaded latency is at least idle latency")

    let wifi = try await client.wifiClients()
    check(wifi.clients.count > 3, "router reports clients")
    check(wifi.clients.allSatisfy { $0.displayName.isEmpty == false }, "clients are named")
}

// MARK: - Ring-buffer rotation

await suite("History ring rotation") {
    // A ring that has wrapped must come back in chronological order, with the
    // newest sample last, regardless of where the write cursor sits.
    let size = 10
    var w = ProtoWriter()
    w.varint(F.History.current, 23) // wrapped twice, cursor at index 3
    w.packedFloat(F.History.downlinkThroughputBps, (0..<size).map { Float($0) }[...])
    w.packedFloat(F.History.popPingDropRate, [Float](repeating: 0, count: size)[...])
    let window = DishDecode.history(try ProtoMessage(decoding: w.data), limit: size)

    check(window.samples.count == size, "all ring entries returned")
    // Cursor 23 means index 22 % 10 = 2 is newest; oldest retained is index 3.
    checkClose(window.samples.first?.downlinkBps ?? -1, 3, tolerance: 0.001,
               "oldest sample is the one after the cursor")
    checkClose(window.samples.last?.downlinkBps ?? -1, 2, tolerance: 0.001,
               "newest sample is at the cursor")
}

// MARK: - Analysis

await suite("Obstruction advisor") {
    // Build a map blocked only to the east, below 30 degrees.
    var data = [Float](repeating: 0, count: 123 * 123)
    for row in 0..<123 {
        for col in 0..<123 {
            let sky = gridToSky(row: row, col: col, rows: 123, cols: 123)
            if sky.radius > 1 { data[row * 123 + col] = -1 }
            else if angularDistance(sky.azimuth, 90) < 12 && sky.elevation < 30 {
                data[row * 123 + col] = 1
            }
        }
    }
    let map = ObstructionMap(timestamp: .now, rows: 123, cols: 123, data: data,
                             minElevationDeg: 20)
    let advice = Insights.analyseObstruction(map)
    check(!advice.isClear, "blocked map is not reported as clear")
    check(advice.worst != nil, "a worst direction is identified")
    check(advice.worst.map { angularDistance($0.azimuthDeg, 90) < 20 } == true,
          "worst direction points east — got \(advice.worst?.compass ?? "none")")
    check(advice.recommendation?.contains("E") == true, "recommendation names the direction")
}

await suite("Connection grading") {
    let clean: [HistorySample] = (0..<600).map { i in
        HistorySample(t: Date().addingTimeInterval(-Double(i)), downlinkBps: 1e8,
                      uplinkBps: 1e7, latencyMs: 30, dropRate: 0, powerW: 60,
                      obstructed: false, noSchedule: false)
    }
    check(Insights.linkGrade(clean).letter.hasPrefix("A"), "a clean link grades A")

    let bad: [HistorySample] = (0..<600).map { i in
        let drop: Double = i % 3 == 0 ? 1.0 : 0.2
        let blocked: Bool = i % 4 == 0
        return HistorySample(t: Date().addingTimeInterval(-Double(i)), downlinkBps: 1e6,
                             uplinkBps: 1e5, latencyMs: 400, dropRate: drop,
                             powerW: 60, obstructed: blocked, noSchedule: false)
    }
    check(["D", "F"].contains(Insights.linkGrade(bad).letter),
          "a badly degraded link grades D or F — got \(Insights.linkGrade(bad).letter)")

    let bloated = SpeedTestResult(timestamp: .now, downlinkBps: 2e8, uplinkBps: 2e7,
                                  latencyMs: 30, latencyUnderLoadDownMs: 600,
                                  latencyUnderLoadUpMs: 700)
    check(Insights.bufferbloatGrade(bloated).letter == "F", "600 ms of bloat grades F")
}

await suite("Alert engine") {
    var status = DishStatus()
    status.state = .connected
    status.popPingDropRate = 0.3
    status.popPingLatencyMs = 250
    status.obstruction.fractionObstructed = 0.05

    let alerts = AlertEngine().evaluate(status: status, recent: [], previous: [])
    check(alerts.contains { $0.id == "drop.high" }, "heavy loss raises an alert")
    check(alerts.contains { $0.id == "latency.critical" }, "high latency raises an alert")
    check(alerts.contains { $0.id == "obstruction.high" }, "obstruction raises an alert")
    check(alerts.first?.severity == .critical, "most severe alert sorts first")
    check(alerts.allSatisfy { !$0.detail.isEmpty }, "every alert explains itself")

    var healthy = DishStatus()
    healthy.state = .connected
    healthy.popPingDropRate = 0
    healthy.popPingLatencyMs = 30
    check(AlertEngine().evaluate(status: healthy, recent: [], previous: []).isEmpty,
          "a healthy dish raises nothing")

    // firstSeen must survive re-evaluation so "active for 5 min" stays true.
    let first = AlertEngine().evaluate(status: status, recent: [], previous: [])
    let second = AlertEngine().evaluate(status: status, recent: [], previous: first)
    check(first.first?.firstSeen == second.first?.firstSeen,
          "an ongoing alert keeps its original firstSeen")
}

await suite("Formatting") {
    check(Format.bitrate(96_400_000).combined == "96 Mbps", "bitrate picks Mbps")
    check(Format.bitrate(1_500_000_000).combined == "1.50 Gbps", "bitrate picks Gbps")
    check(Format.percent(0.09, places: 1).combined == "9.0%", "percent has no leading space")
    check(Format.duration(226_800) == "2d 15h", "duration is compact")
    check(Format.compass(22) == "NNE", "azimuth maps to a compass point")
    check(Format.compass(359) == "N", "azimuth wraps at north")
    check(Format.bitrate(nil).value == "—", "missing values render as an em dash")
}

await suite("History store") {
    let store = try await HistoryStore.open(inMemory: true)
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let samples: [HistorySample] = (0..<300).map { i in
        let drop: Double = i < 10 ? 1.0 : 0.0
        return HistorySample(t: now.addingTimeInterval(-Double(300 - i)),
                             downlinkBps: 1e8, uplinkBps: 1e7, latencyMs: 30,
                             dropRate: drop, powerW: 60,
                             obstructed: false, noSchedule: false)
    }
    try await store.ingest(samples)
    try await store.ingest(samples) // duplicates must be ignored
    let stats = try await store.statistics()
    check(stats.sampleRows == 300, "duplicate seconds are ignored — got \(stats.sampleRows)")

    try await store.compact(now: now)
    let uptime = try await store.uptime(from: now.addingTimeInterval(-400), to: now)
    check(uptime.recordedSeconds > 0, "rollups record sample counts")
    check((uptime.availability ?? 1) < 1, "outage seconds reduce availability")

    let usage = try await store.usage(from: now.addingTimeInterval(-400), to: now)
    // 1e8 bps for ~290 non-current-minute seconds, in bytes.
    check(usage.down > 3e9 && usage.down < 4e9, "byte totals are plausible — got \(usage.down)")
}

// MARK: - Result

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("All good.")
  }
}
