import Foundation

/// A behavioural model of a Starlink terminal.
///
/// Demo mode has to be convincing enough that the charts, the sky dome, the
/// alert engine and the outage timeline all show the same *kinds* of structure
/// they show on real hardware — otherwise it teaches the wrong thing about the
/// UI. So this is a model, not a random walk:
///
///  * satellite handoffs land on 15-second boundaries, each with a latency step
///  * obstructions are fixed objects in the sky, so they bite only when the
///    currently-tracked satellite passes behind one
///  * household demand follows a diurnal curve with bursty streaming on top
///  * rain fade degrades SNR and throughput together, then recovers
///  * power tracks load, plus a heater draw when it is cold out
actor DishSimulator {
    /// 12 hours at 1 Hz, matching the dish's own history buffer.
    static let ringSeconds = 43_200

    /// A fixed obstruction: a tree or roofline occupying a patch of sky.
    struct SkyObject: Sendable {
        var azimuthDeg: Double
        var widthDeg: Double
        /// Everything below this elevation, inside the wedge, is blocked.
        var elevationDeg: Double
        var label: String
    }

    struct Sample: Sendable {
        var downlinkBps = 0.0
        var uplinkBps = 0.0
        var latencyMs = 0.0
        var dropRate = 0.0
        var powerW = 0.0
        var snr = 0.0
        var obstructed = false
        var scheduled = true
    }

    struct Event: Sendable, Identifiable {
        var id = UUID()
        var at: Date
        var detail: String
    }

    // MARK: - Configuration

    private var rngState: UInt64
    let latitude: Double
    let longitude: Double
    private let demandScale: Double
    let hardwareVersion: String
    let softwareVersion: String
    let dishID: String
    let bootedAt: Date
    private let objects: [SkyObject]

    // MARK: - Ring buffers, mirroring the dish's own history layout

    private var ringDown = [Float](repeating: 0, count: ringSeconds)
    private var ringUp = [Float](repeating: 0, count: ringSeconds)
    private var ringLatency = [Float](repeating: 0, count: ringSeconds)
    private var ringDrop = [Float](repeating: 0, count: ringSeconds)
    private var ringPower = [Float](repeating: 0, count: ringSeconds)
    private var ringSnr = [Float](repeating: 0, count: ringSeconds)
    private var ringObstructed = [Int](repeating: 0, count: ringSeconds)
    private var ringScheduled = [Int](repeating: 1, count: ringSeconds)

    /// Seconds since boot; also the ring's write cursor.
    private(set) var current = 0
    private var lastAdvance: Date
    /// History is generated on the first `advance` rather than in `init`: a
    /// synchronous actor initialiser cannot call isolated methods under Swift 6
    /// strict concurrency, and every read path goes through `advance` first.
    private let initialUptime: TimeInterval
    private var hasPrefilled = false

    // MARK: - Accumulated sky observation, backing the SNR map

    private let mapRows = 123
    private let mapCols = 123
    private var skyObserved: [Float]
    private var skyBlocked: [Float]

    // MARK: - Slowly-varying environment

    private var rainIntensity = 0.0
    private var rainUntil = Date.distantPast
    private var outageUntil = Date.distantPast
    private var outageCause: String?
    private var ambientC = 14.0
    private var satAzimuth = 180.0
    private var satElevation = 55.0
    private var satSlot = -1
    /// Angular rates, degrees per second. A terminal does not stare at a fixed
    /// point for its whole 15-second slot — it follows the satellite across the
    /// sky, and that arc is the thing the sky view exists to show.
    private var satAzimuthRate = 0.0
    private var satElevationRate = 0.0
    private var events: [Event] = []

    init(
        seed: UInt64 = 0xCA_70_DE,
        latitude: Double = 44.9778,
        longitude: Double = -93.2650,
        demand: Double = 1.0,
        initialUptime: TimeInterval = 61 * 3600,
        obstructions: [SkyObject]? = nil
    ) {
        self.rngState = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        self.latitude = latitude
        self.longitude = longitude
        self.demandScale = demand
        self.hardwareVersion = "rev3_proto2"
        self.softwareVersion = "2026.32.0.mr58982"
        self.dishID = "ut01000000-00000000-0092c4f1"
        self.bootedAt = Date().addingTimeInterval(-initialUptime)
        self.objects = obstructions ?? [
            SkyObject(azimuthDeg: 22, widthDeg: 11, elevationDeg: 31, label: "Oak"),
            SkyObject(azimuthDeg: 41, widthDeg: 6, elevationDeg: 24, label: "Chimney"),
            SkyObject(azimuthDeg: 300, widthDeg: 15, elevationDeg: 20, label: "Treeline"),
        ]
        self.skyObserved = [Float](repeating: 0, count: 123 * 123)
        self.skyBlocked = [Float](repeating: 0, count: 123 * 123)
        self.lastAdvance = .now
        self.initialUptime = initialUptime
    }

    /// Generates history backwards from now so charts have depth on first paint.
    private func prefill(seconds: Int) {
        guard seconds > 0 else { return }
        let start = Date().addingTimeInterval(-Double(seconds))
        for i in 0..<seconds {
            step(at: start.addingTimeInterval(Double(i)))
        }
        lastAdvance = .now
    }

    /// Catches the ring up to wall-clock time. Cheap when called often.
    func advance(to now: Date = .now) {
        if !hasPrefilled {
            hasPrefilled = true
            prefill(seconds: min(Self.ringSeconds, Int(initialUptime)))
        }
        let elapsed = Int(now.timeIntervalSince(lastAdvance))
        guard elapsed > 0 else { return }
        // Returning from a long background suspend must not replay hours.
        let steps = min(elapsed, Self.ringSeconds)
        let base = now.addingTimeInterval(-Double(steps))
        for i in 0..<steps {
            step(at: base.addingTimeInterval(Double(i)))
        }
        lastAdvance = now
    }

    private func step(at date: Date) {
        let idx = current % Self.ringSeconds
        let s = tick(at: date)
        ringDown[idx] = Float(s.downlinkBps)
        ringUp[idx] = Float(s.uplinkBps)
        ringLatency[idx] = Float(s.dropRate >= 1 ? 0 : s.latencyMs)
        ringDrop[idx] = Float(s.dropRate)
        ringPower[idx] = Float(s.powerW)
        ringSnr[idx] = Float(s.snr)
        ringObstructed[idx] = s.obstructed ? 1 : 0
        ringScheduled[idx] = s.scheduled ? 1 : 0
        current += 1
    }

    private func tick(at date: Date) -> Sample {
        let t = date.timeIntervalSince1970
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute, .dayOfYear], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        let localHour = (hour + longitude / 15).truncatingRemainder(dividingBy: 24)
        let localHourWrapped = localHour < 0 ? localHour + 24 : localHour

        // Satellite handoff: real terminals switch on 15-second boundaries.
        let slot = Int(t / 15)
        if slot != satSlot {
            satSlot = slot
            satAzimuth = (satAzimuth + 40 + random() * 280).truncatingRemainder(dividingBy: 360)
            // The full usable cone, not a band: a terminal does track satellites
            // through zenith, and clipping the range left an unobserved hole in
            // the middle of the rendered sky map.
            satElevation = 20 + random() * 68
            // A LEO pass crosses several degrees of sky per second, faster in
            // azimuth the closer it is to zenith.
            let rising = random() < 0.5
            satElevationRate = (0.25 + random() * 0.95) * (rising ? 1 : -1)
            let zenithFactor = 1 + 2.5 * (satElevation / 90)
            satAzimuthRate = (0.4 + random() * 1.6) * zenithFactor * (random() < 0.5 ? 1 : -1)
        } else {
            // Advance along the pass. One tick is one simulated second.
            satElevation += satElevationRate
            satAzimuth = (satAzimuth + satAzimuthRate + 360)
                .truncatingRemainder(dividingBy: 360)
            // Reflect off the usable elevation limits rather than clipping, so a
            // pass never sticks against the edge of the cone.
            if satElevation > 88 {
                satElevation = 176 - satElevation
                satElevationRate = -satElevationRate
            } else if satElevation < 18 {
                satElevation = 36 - satElevation
                satElevationRate = -satElevationRate
            }
        }
        observeSky(azimuth: satAzimuth, elevation: satElevation)

        // Is the tracked satellite behind a known object?
        let obstructed = objects.contains { o in
            angularDistance(o.azimuthDeg, satAzimuth) < o.widthDeg && satElevation < o.elevationDeg
        }

        // Rain fade arrives in bursts and decays.
        if date > rainUntil, random() < 0.00018 {
            rainIntensity = 0.25 + random() * 0.75
            rainUntil = date.addingTimeInterval(240 + random() * 2400)
        }
        if date > rainUntil { rainIntensity *= 0.999 }
        let rain = rainIntensity

        // Unplanned outages.
        if date > outageUntil, random() < 0.000035 {
            outageUntil = date.addingTimeInterval(4 + random() * 50)
            let cause = ["No satellites", "Network issue", "Software update"][Int(random() * 3) % 3]
            outageCause = cause
            events.append(Event(at: date, detail: cause))
            if events.count > 400 { events.removeFirst() }
        }
        let inOutage = date < outageUntil

        // Household demand: diurnal curve plus bursty streams.
        let diurnal = 0.18
            + 0.42 * exp(-pow((localHourWrapped - 20.5) / 3.1, 2))
            + 0.16 * exp(-pow((localHourWrapped - 9.5) / 2.4, 2))
        let burst = max(0, valueNoise(t / 90) - 0.45) * 2.4
        let demand = max(0.02, (diurnal + burst) * demandScale)

        // Link capacity.
        let snrBase = 9.4 - rain * 5.2 - (obstructed ? 6 : 0)
        let snr = max(0, snrBase + valueNoise(t / 17) * 0.6)
        let capacity = (185e6 + valueNoise(t / 240) * 55e6) * min(1.05, max(0, snr / 9.4))

        let scheduled = !inOutage && !obstructed
        let dropRate: Double = inOutage || obstructed
            ? 1
            : min(1, max(0, rain * 0.09 + max(0, valueNoise(t / 7) - 0.86) * 0.5))

        let downlink = scheduled ? max(0, min(capacity, capacity * demand)) * (1 - dropRate) : 0
        let uplink = scheduled ? downlink * (0.07 + random() * 0.05) + 120e3 * demand : 0

        // Latency: base + jitter + handoff step + mild bufferbloat under load.
        let handoffAge = t - Double(slot) * 15
        let handoffSpike = handoffAge < 1 ? 14 + random() * 26 : 0
        let loadPenalty = 34 * pow(downlink / max(1, capacity), 2.4)
        let latency = inOutage || obstructed
            ? 0
            : 24 + valueNoise(t / 11) * 9 + handoffSpike + loadPenalty + rain * 18

        // Power tracks load, plus the heater when it is cold.
        ambientC += (seasonalTemp(dayOfYear: parts.dayOfYear ?? 180, hour: hour, latitude: latitude) - ambientC) * 0.0006
        let heating = ambientC < 2 ? 55 + random() * 20 : 0
        let power = 42 + (downlink / 1e6) * 0.17 + (uplink / 1e6) * 0.4 + heating + random() * 2.5

        return Sample(downlinkBps: downlink, uplinkBps: uplink, latencyMs: latency,
                      dropRate: dropRate, powerW: power, snr: snr,
                      obstructed: obstructed, scheduled: scheduled)
    }

    /// Records that the dish looked at this patch of sky, and whether it was clear.
    private func observeSky(azimuth: Double, elevation: Double) {
        let (row, col) = Self.skyToGrid(azimuth: azimuth, elevation: elevation,
                                        rows: mapRows, cols: mapCols)
        guard row >= 0 else { return }
        let blocked = objects.contains { o in
            angularDistance(o.azimuthDeg, azimuth) < o.widthDeg && elevation < o.elevationDeg
        }
        // Spread over a small kernel — the beam is not a point.
        for dr in -2...2 {
            for dc in -2...2 {
                let r = row + dr, c = col + dc
                guard r >= 0, r < mapRows, c >= 0, c < mapCols else { continue }
                let i = r * mapCols + c
                let weight = Float(1.0 / Double(1 + dr * dr + dc * dc))
                guard weight > 0.04 else { continue }
                skyObserved[i] += weight
                if blocked { skyBlocked[i] += weight }
            }
        }
    }

    // MARK: - Accessors used by the transport

    var uptimeSeconds: Int { Int(Date().timeIntervalSince(bootedAt)) }

    var latest: Sample {
        let idx = (current - 1 + Self.ringSeconds) % Self.ringSeconds
        return Sample(
            downlinkBps: Double(ringDown[idx]), uplinkBps: Double(ringUp[idx]),
            latencyMs: Double(ringLatency[idx]), dropRate: Double(ringDrop[idx]),
            powerW: Double(ringPower[idx]), snr: Double(ringSnr[idx]),
            obstructed: ringObstructed[idx] == 1, scheduled: ringScheduled[idx] == 1)
    }

    var boresight: (azimuth: Double, elevation: Double) { (satAzimuth, satElevation) }
    var weather: (rain: Double, ambientC: Double) { (rainIntensity, ambientC) }
    var isInOutage: Bool { Date() < outageUntil }
    var recentEvents: [Event] { events }
    var mapShape: (rows: Int, cols: Int) { (mapRows, mapCols) }

    func series() -> (down: [Float], up: [Float], latency: [Float], drop: [Float],
                      power: [Float], snr: [Float], obstructed: [Int], scheduled: [Int]) {
        (ringDown, ringUp, ringLatency, ringDrop, ringPower, ringSnr, ringObstructed, ringScheduled)
    }

    /// Fraction of observed sky that is blocked — what the dish reports.
    var obstructionFraction: Double {
        var observed: Double = 0, blocked: Double = 0
        for i in 0..<skyObserved.count where skyObserved[i] > 0 {
            observed += Double(skyObserved[i])
            blocked += Double(skyBlocked[i])
        }
        return observed > 0 ? blocked / observed : 0
    }

    /// The 123×123 SNR grid: -1 unobserved, 0 clear, 1 fully blocked.
    func obstructionGrid() -> [Float] {
        (0..<skyObserved.count).map { i in
            let observed = skyObserved[i]
            return observed <= 0 ? -1 : min(1, max(0, skyBlocked[i] / observed))
        }
    }

    /// A simulated on-demand speed test: briefly saturates, so it beats live rates.
    func runSpeedTest() -> (down: Double, up: Double, latency: Double,
                            loadDown: Double, loadUp: Double) {
        let s = latest
        let headroom = s.scheduled ? 1.0 : 0.0
        let quality = min(1, max(0.2, s.snr / 9.4))
        let latency = s.latencyMs > 0 ? s.latencyMs : 28
        return (
            down: (205e6 + random() * 90e6) * headroom * quality,
            up: (18e6 + random() * 14e6) * headroom * quality,
            latency: latency,
            loadDown: latency + 22 + random() * 60,
            loadUp: latency + 35 + random() * 90)
    }

    /// Forces a condition, so the UI's unhealthy states can be demonstrated.
    enum Injection: String, CaseIterable, Sendable {
        case outage, rain, clear
        var label: String {
            switch self {
            case .outage: "Force outage"
            case .rain: "Force rain fade"
            case .clear: "Clear conditions"
            }
        }
    }

    func inject(_ kind: Injection, duration: TimeInterval = 45) {
        let now = Date()
        switch kind {
        case .outage:
            outageUntil = now.addingTimeInterval(duration)
            outageCause = "Injected outage"
            events.append(Event(at: now, detail: "Injected outage"))
        case .rain:
            rainIntensity = 0.85
            rainUntil = now.addingTimeInterval(duration)
        case .clear:
            outageUntil = .distantPast
            rainIntensity = 0
            rainUntil = .distantPast
        }
    }

    // MARK: - Helpers

    /// xorshift64*, so a given seed always produces the same demo timeline.
    private func random() -> Double {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let value = rngState &* 0x2545_F491_4F6C_DD1D
        return Double(value >> 11) / Double(1 << 53)
    }

    /// Maps an azimuth/elevation to a cell in the dish's square SNR grid. The
    /// grid is a top-down fisheye: centre is zenith, edge is horizon, north up.
    static func skyToGrid(azimuth: Double, elevation: Double,
                          rows: Int, cols: Int) -> (row: Int, col: Int) {
        guard elevation >= 0, elevation <= 90 else { return (-1, -1) }
        let r = (90 - elevation) / 90
        let rad = azimuth * .pi / 180
        let x = r * sin(rad)
        let y = -r * cos(rad)
        return (Int(((y + 1) / 2 * Double(rows - 1)).rounded()),
                Int(((x + 1) / 2 * Double(cols - 1)).rounded()))
    }
}

/// Inverse of `skyToGrid`, used by the dome renderer to label the sky.
///
/// Takes continuous coordinates so the renderer can supersample between cells;
/// the integer overload below is the common case.
func gridToSky(row: Double, col: Double, rows: Int, cols: Int)
    -> (azimuth: Double, elevation: Double, radius: Double) {
    let y = row / Double(rows - 1) * 2 - 1
    let x = col / Double(cols - 1) * 2 - 1
    let radius = (x * x + y * y).squareRoot()
    var azimuth = atan2(x, -y) * 180 / .pi
    if azimuth < 0 { azimuth += 360 }
    return (azimuth, 90 * (1 - radius), radius)
}

func gridToSky(row: Int, col: Int, rows: Int, cols: Int)
    -> (azimuth: Double, elevation: Double, radius: Double) {
    gridToSky(row: Double(row), col: Double(col), rows: rows, cols: cols)
}

func angularDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return d > 180 ? 360 - d : d
}

/// Smooth value noise in [0,1); good enough for demand and jitter curves.
func valueNoise(_ x: Double) -> Double {
    let i = x.rounded(.down)
    let f = x - i
    let a = hashNoise(i), b = hashNoise(i + 1)
    let smooth = f * f * (3 - 2 * f)
    return a + (b - a) * smooth
}

private func hashNoise(_ n: Double) -> Double {
    let s = sin(n * 127.1) * 43758.5453
    return s - s.rounded(.down)
}

/// Rough ambient temperature for the heater model: a seasonal cosine peaking at
/// midsummer, flipped for the southern hemisphere, plus a diurnal swing.
private func seasonalTemp(dayOfYear: Int, hour: Double, latitude: Double = 44.9778) -> Double {
    let seasonal = cos(Double(dayOfYear - 200) / 365 * 2 * .pi)
    let hemisphere: Double = latitude >= 0 ? 1 : -1
    let amplitude = 6 + abs(latitude) * 0.22
    let daily = cos((hour - 15) / 24 * 2 * .pi) * 5
    return 14 + seasonal * amplitude * hemisphere + daily
}
