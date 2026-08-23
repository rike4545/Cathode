import Foundation
import SwiftUI
import Observation

/// The app's single source of truth.
///
/// One poll loop drives everything. Fast telemetry (status) is read every
/// second; expensive reads (the obstruction map, the router client list) are on
/// their own slower cadences so a 15 000-cell SNR grid never blocks the live
/// numbers.
@MainActor
@Observable
final class AppModel {

    enum DiscoveryState: Equatable {
        case idle
        case searching
        /// Nothing on this network answered the Device API.
        case notFound
        case found(host: String, name: String)
        /// Explicit full-subnet sweep, with progress 0–1.
        case sweeping(progress: Double)

        var isBusy: Bool {
            switch self {
            case .searching, .sweeping: true
            default: false
            }
        }
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(message: String, hint: String?)

        var tone: Tone {
            switch self {
            case .connected: .good
            case .connecting: .warn
            case .failed: .bad
            case .idle: .idle
            }
        }
        var label: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting"
            case .connected: "Live"
            case .failed: "Offline"
            }
        }
    }

    // MARK: - Published state

    private(set) var connection: ConnectionState = .idle
    private(set) var status: DishStatus?
    private(set) var deviceInfo = DeviceInfo()
    private(set) var wifi: WifiStatus?
    private(set) var location: DishLocation?
    private(set) var obstructionMap: ObstructionMap?
    /// Where the dish has pointed recently. Starlink hands off between
    /// satellites every 15 seconds, so a single live marker just teleports
    /// around the dome; the track is what actually shows which arc of sky the
    /// terminal is using.
    private(set) var boresightTrack: [SkyPoint] = []
    static let trackSeconds = 180
    private(set) var obstructionAdvice: Insights.ObstructionAdvice?
    private(set) var alerts: [Alert] = []
    private(set) var acknowledgedAlertIDs: Set<String> = []
    /// The alert set last handed to the notification service, so a poll that
    /// changes nothing does not re-post anything.
    private var notifiedSignature: Set<String> = []
    /// What `alerts` currently holds, as id+severity pairs.
    private var publishedAlertSignature: Set<String> = []
    private var lastAlertPublish = Date.distantPast
    /// Last cumulative byte counters seen per device, for differencing.
    private var lastClientCounters: [String: (down: Double, up: Double)] = [:]
    /// Longest the alert wording may lag the live figures it quotes.
    private static let alertRefreshInterval: TimeInterval = 5
    private(set) var speedTests: [SpeedTestResult] = []
    private(set) var speedTestInProgress = false
    private(set) var lastUpdate: Date?
    private(set) var storeStatistics: StoreStatistics?
    private(set) var discovery: DiscoveryState = .idle
    private(set) var discovered: [DishDiscovery.Found] = []
    private(set) var recentOutages: [OutageRecord] = []

    /// A rolling in-memory window of the most recent seconds, for the live
    /// charts. Longer ranges come from the store instead.
    private(set) var liveSamples: [HistorySample] = []
    static let liveWindowSeconds = 900

    let settings: Settings
    private(set) var store: HistoryStore?

    // MARK: - Internals

    private var client: DishClient?
    private var pollTask: Task<Void, Never>?
    private var alertEngine = AlertEngine()
    private var outageTracker = OutageTracker()
    private var storeFailure: String?

    /// When each expensive read is next due.
    ///
    /// These were originally a modulo on a poll counter, which desynchronised
    /// the moment a poll loop was cancelled mid-cycle — a reconnect could leave
    /// the obstruction map unfetched for a full two minutes because the counter
    /// had already stepped past its trigger. Deadlines are immune to that, and
    /// they let a failed read retry sooner than a successful one.
    private var obstructionDue = Date.distantPast
    private var wifiDue = Date.distantPast
    private var historyTailDue = Date.distantPast
    private var locationDue = Date.distantPast
    private var compactDue = Date.distantPast

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() async {
        if store == nil {
            do {
                store = try await HistoryStore.open()
            } catch {
                // History is a bonus, not a prerequisite: a store that will not
                // open must not stop the app from showing live telemetry.
                storeFailure = String(describing: error)
            }
        }
        await connect()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        connection = .idle
    }

    /// Tears down and rebuilds the connection — used when the source or host changes.
    func reconnect() async {
        stop()
        status = nil
        liveSamples.removeAll()
        obstructionMap = nil
        obstructionAdvice = nil
        boresightTrack.removeAll()
        lastClientCounters.removeAll()
        wifi = nil
        await connect()
    }

    private func connect() async {
        connection = .connecting
        alertEngine.thresholds = settings.thresholds

        // Find the hardware before trying to talk to it, unless the user has
        // pinned an address by hand.
        if settings.source == .dish, !settings.dishHostIsPinned {
            await runDiscovery()
        }

        let transport: DishTransport = switch settings.source {
        case .demo: SimulatorTransport()
        case .dish: GrpcWebTransport(host: settings.dishHost)
        }
        let client = DishClient(transport: transport)
        self.client = client

        // A new connection re-reads everything immediately.
        obstructionDue = .distantPast
        wifiDue = .distantPast
        historyTailDue = .distantPast
        locationDue = .distantPast
        compactDue = Date.now.addingTimeInterval(Self.compactInterval)

        await loadPersisted()

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop(client: client)
        }
    }

    // MARK: - Discovery

    /// Probes the short candidate list and adopts whatever dish answers.
    @discardableResult
    func runDiscovery() async -> Bool {
        discovery = .searching
        let results = await DishDiscovery.discover()
        discovered = results

        guard let best = results.first(where: { $0.kind == .dish }) ?? results.first else {
            discovery = .notFound
            return false
        }
        // Only the dish's address is worth adopting; the router speaks the same
        // API but reports none of the telemetry this app is built around.
        if best.kind == .dish {
            settings.dishHost = best.host
        }
        discovery = .found(host: best.host, name: best.describedName)
        return true
    }

    /// Full-subnet sweep. User-initiated only.
    func sweepNetwork() async {
        discovery = .sweeping(progress: 0)
        let results = await DishDiscovery.sweep { fraction in
            Task { @MainActor [weak self] in
                self?.discovery = .sweeping(progress: fraction)
            }
        }
        discovered = results
        if let dish = results.first(where: { $0.kind == .dish }) {
            settings.dishHost = dish.host
            discovery = .found(host: dish.host, name: dish.describedName)
        } else if let any = results.first {
            discovery = .found(host: any.host, name: any.describedName)
        } else {
            discovery = .notFound
        }
    }

    // MARK: - Poll loop

    private func pollLoop(client: DishClient) async {
        var backoff: Duration = .seconds(1)
        var seededHistory = false

        while !Task.isCancelled {
            let startedAt = ContinuousClock.now
            do {
                let status = try await client.status()
                apply(status)
                connection = .connected
                backoff = .seconds(1)

                // Seed from the dish's own 12-hour ring on the first successful
                // poll, so charts have depth immediately rather than filling in
                // one second at a time.
                if !seededHistory {
                    seededHistory = true
                    await seedHistory(client: client)
                }

                // Expensive reads run on their own deadlines, so one slow or
                // failed read never delays the live numbers.
                await runIfDue(\.historyTailDue, every: Self.historyTailInterval) {
                    await self.refreshHistoryTail(client: client)
                }
                await runIfDue(\.obstructionDue, every: Self.obstructionInterval) {
                    await self.refreshObstruction(client: client)
                }
                await runIfDue(\.wifiDue, every: Self.wifiInterval) {
                    await self.refreshWifi(client: client)
                }
                await runIfDue(\.locationDue, every: Self.locationInterval) {
                    await self.refreshLocation(client: client)
                }
                if Date.now >= compactDue {
                    compactDue = Date.now.addingTimeInterval(Self.compactInterval)
                    await compactStore()
                }

            } catch is CancellationError {
                return
            } catch {
                let grpc = error as? GrpcError
                connection = .failed(
                    message: grpc?.message ?? error.localizedDescription,
                    hint: grpc?.hint)
                // Back off so a disconnected dish does not spin the radio.
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(15))
                continue
            }

            let elapsed = ContinuousClock.now - startedAt
            let target = Duration.seconds(settings.pollIntervalSeconds)
            if elapsed < target {
                try? await Task.sleep(for: target - elapsed)
            }
        }
    }

    private func apply(_ status: DishStatus) {
        self.status = status
        self.lastUpdate = status.timestamp
        if status.deviceInfo.id != nil { self.deviceInfo = status.deviceInfo }

        // Fold the live status into the rolling window as one second of history.
        let sample = HistorySample(
            t: status.timestamp,
            downlinkBps: status.downlinkBps ?? 0,
            uplinkBps: status.uplinkBps ?? 0,
            latencyMs: status.popPingLatencyMs,
            dropRate: status.popPingDropRate ?? 0,
            powerW: status.powerW,
            // Per-second SNR only arrives with the history series, not with
            // status; leaving it nil keeps the two sources from disagreeing.
            snr: nil,
            obstructed: status.obstruction.currentlyObstructed ?? false,
            noSchedule: false)
        appendLive([sample])

        recordBoresight(status)

        publishAlerts(alertEngine.evaluate(
            status: status, recent: liveSamples, previous: alerts))

        if let outage = outageTracker.observe(status) {
            recentOutages.insert(outage, at: 0)
            recentOutages = Array(recentOutages.prefix(200))
            Task { [store] in try? await store?.record(outage: outage) }
        }
    }

    /// Publishes a new alert set, throttled.
    ///
    /// Reassigning `alerts` on every poll invalidates every view that reads it,
    /// once a second, for the whole app — wasteful when the set of problems has
    /// not changed. A change in *which* problems exist publishes immediately;
    /// otherwise the refresh is time-boxed, because the detail strings quote
    /// live figures and would go stale if gated on the signature alone.
    private func publishAlerts(_ evaluated: [Alert]) {
        let signature = Set(evaluated.map { "\($0.id)|\($0.severity.rawValue)" })
        let changed = signature != publishedAlertSignature
        let stale = Date.now.timeIntervalSince(lastAlertPublish) >= Self.alertRefreshInterval
        guard changed || (stale && !evaluated.isEmpty) else { return }
        publishedAlertSignature = signature
        lastAlertPublish = .now
        alerts = evaluated

        // Drop acknowledgements for alerts that have since cleared, so the same
        // problem recurring is surfaced again rather than staying silenced.
        acknowledgedAlertIDs.formIntersection(Set(evaluated.map(\.id)))
        syncNotifications()
    }

    /// Hands the current alert set to the notification service when it changes.
    ///
    /// Demo data never notifies — being woken at 2am by a simulated outage
    /// would be a bug, not a feature.
    private func syncNotifications() {
        guard !isDemo else { return }
        let signature = Set(alerts.map(\.id))
        guard signature != notifiedSignature else { return }
        notifiedSignature = signature

        let enabled = settings.notificationsEnabled
        let minimum = Alert.Severity(rawValue: settings.notifyMinimumSeverity) ?? .critical
        let current = alerts
        Task {
            await NotificationService.shared.sync(
                alerts: current, minimum: minimum, enabled: enabled)
        }
    }

    private func recordBoresight(_ status: DishStatus) {
        guard let azimuth = status.alignment.boresightAzimuthDeg,
              let elevation = status.alignment.boresightElevationDeg,
              elevation.isFinite, azimuth.isFinite else { return }
        // Only record movement; a stationary dish would otherwise pile up
        // hundreds of identical points at one spot.
        if let last = boresightTrack.last,
           angularDistance(last.azimuth, azimuth) < 0.4,
           abs(last.elevation - elevation) < 0.4 {
            return
        }
        boresightTrack.append(SkyPoint(azimuth: azimuth, elevation: elevation,
                                       t: status.timestamp))
        let cutoff = Date.now.addingTimeInterval(-Double(Self.trackSeconds))
        if let firstKept = boresightTrack.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            boresightTrack.removeFirst(firstKept)
        }
    }

    private func appendLive(_ samples: [HistorySample]) {
        guard !samples.isEmpty else { return }
        liveSamples.append(contentsOf: samples)
        let cutoff = Date.now.addingTimeInterval(-Double(Self.liveWindowSeconds))
        if let firstKept = liveSamples.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            liveSamples.removeFirst(firstKept)
        }
        Task { [store] in try? await store?.ingest(samples) }
    }

    // MARK: - Secondary reads

    /// Cadences for the reads that are too expensive to run every second.
    static let historyTailInterval: TimeInterval = 30
    static let obstructionInterval: TimeInterval = 120
    static let wifiInterval: TimeInterval = 20
    static let locationInterval: TimeInterval = 600
    static let compactInterval: TimeInterval = 300
    /// How soon to try again after a read fails, rather than waiting out the
    /// full interval.
    static let retryInterval: TimeInterval = 15

    /// Runs `work` when its deadline has passed, then schedules the next one —
    /// sooner if the read did not succeed.
    private func runIfDue(
        _ due: ReferenceWritableKeyPath<AppModel, Date>,
        every interval: TimeInterval,
        _ work: () async -> Bool
    ) async {
        guard Date.now >= self[keyPath: due] else { return }
        // Push the deadline out before awaiting, so a call that is cancelled
        // part-way cannot leave it in the past and spin on the next tick.
        self[keyPath: due] = Date.now.addingTimeInterval(interval)
        let succeeded = await work()
        if !succeeded {
            self[keyPath: due] = Date.now.addingTimeInterval(min(interval, Self.retryInterval))
        }
    }

    private func seedHistory(client: DishClient) async {
        guard let window = try? await client.history() else { return }
        guard !window.samples.isEmpty else { return }
        // Everything older than the live window goes straight to the store;
        // only the tail is kept in memory for the live charts.
        let cutoff = Date.now.addingTimeInterval(-Double(Self.liveWindowSeconds))
        liveSamples = window.samples.filter { $0.t >= cutoff }
        let all = window.samples
        Task { [store] in
            try? await store?.ingest(all)
            try? await store?.compact()
        }
        await refreshOutagesFromStore()
    }

    /// Re-reads the dish's ring and ingests anything not already recorded.
    @discardableResult
    private func refreshHistoryTail(client: DishClient) async -> Bool {
        guard let window = try? await client.history(limit: 240),
              !window.samples.isEmpty else { return false }
        Task { [store] in
            try? await store?.ingest(window.samples)
            // Seconds the live poll already wrote are missing SNR; only the
            // history series carries it.
            try? await store?.enrich(window.samples)
        }
        return true
    }

    @discardableResult
    private func refreshObstruction(client: DishClient) async -> Bool {
        // `try?` flattens with the method's own Optional return, so one unwrap
        // covers both "the call failed" and "it decoded to nothing".
        guard let map = try? await client.obstructionMap() else { return false }
        obstructionMap = map
        obstructionAdvice = Insights.analyseObstruction(map)
        return true
    }

    @discardableResult
    private func refreshWifi(client: DishClient) async -> Bool {
        guard await client.supports(.wifiGetStatus) else { return true }
        guard let status = try? await client.wifiClients() else { return false }
        wifi = status
        recordClientUsage(status.clients)
        return true
    }

    /// Turns the router's cumulative per-device counters into usage over time.
    ///
    /// The router only ever reports a running total, which answers "how much
    /// has this device ever used" and not "who has been hammering the
    /// connection this week" — the question people actually ask. Differencing
    /// successive samples gives the latter.
    private func recordClientUsage(_ clients: [WifiClient]) {
        var deltas: [ClientUsageDelta] = []
        for client in clients {
            guard let mac = client.macAddress,
                  let down = client.bytesDown, let up = client.bytesUp else { continue }
            defer { lastClientCounters[mac] = (down, up) }
            guard let previous = lastClientCounters[mac] else { continue }
            // A counter that went backwards means the router restarted and
            // reset it. Re-baseline rather than recording a negative or, worse,
            // treating the new absolute value as a delta.
            guard down >= previous.down, up >= previous.up else { continue }
            let deltaDown = down - previous.down
            let deltaUp = up - previous.up
            guard deltaDown > 0 || deltaUp > 0 else { continue }
            deltas.append(ClientUsageDelta(
                mac: mac, name: client.name, down: deltaDown, up: deltaUp))
        }
        guard !deltas.isEmpty else { return }
        Task { [store] in try? await store?.recordClientUsage(deltas) }
    }

    @discardableResult
    private func refreshLocation(client: DishClient) async -> Bool {
        guard await client.supports(.getLocation) else { return true }
        guard let result = try? await client.location() else { return false }
        location = result
        return true
    }

    private func compactStore() async {
        try? await store?.compact()
        storeStatistics = try? await store?.statistics()
    }

    private func loadPersisted() async {
        guard let store else { return }
        speedTests = (try? await store.speedTests()) ?? []
        storeStatistics = try? await store.statistics()
        await refreshOutagesFromStore()
    }

    private func refreshOutagesFromStore() async {
        guard let store else { return }
        recentOutages = (try? await store.outages(
            from: .now.addingTimeInterval(-30 * 86_400), to: .now)) ?? []
    }

    // MARK: - Actions

    func runSpeedTest() async {
        guard let client, !speedTestInProgress else { return }
        speedTestInProgress = true
        defer { speedTestInProgress = false }
        do {
            let result = try await client.speedTest()
            speedTests.insert(result, at: 0)
            speedTests = Array(speedTests.prefix(60))
            try? await store?.record(result)
        } catch {
            let grpc = error as? GrpcError
            alerts.insert(Alert(
                id: "speedtest.failed", severity: .warning, title: "Speed test failed",
                detail: grpc?.message ?? error.localizedDescription,
                remedy: nil, firstSeen: .now, lastSeen: .now, isFromHardware: false), at: 0)
        }
    }

    enum ControlAction: String, CaseIterable, Identifiable {
        case reboot, stow, unstow, clearObstructionMap
        var id: String { rawValue }

        var title: String {
            switch self {
            case .reboot: "Reboot dish"
            case .stow: "Stow dish"
            case .unstow: "Unstow dish"
            case .clearObstructionMap: "Reset obstruction map"
            }
        }
        var detail: String {
            switch self {
            case .reboot: "The dish restarts and reconnects. Expect two to three minutes offline."
            case .stow: "The dish folds flat for transport or storage. It will not connect while stowed."
            case .unstow: "The dish returns to its operating position and begins searching."
            case .clearObstructionMap: "Clears the recorded sky map so it rebuilds from scratch. "
                + "Useful after moving the dish or trimming a tree. Takes about 12 hours to refill."
            }
        }
        var isDestructive: Bool {
            switch self {
            case .reboot, .stow: true
            case .unstow, .clearObstructionMap: false
            }
        }
    }

    func perform(_ action: ControlAction) async throws {
        guard let client else { throw GrpcError(.unavailable, "Not connected.") }
        switch action {
        case .reboot: try await client.reboot()
        case .stow: try await client.stow(true)
        case .unstow: try await client.stow(false)
        case .clearObstructionMap:
            try await client.clearObstructionMap()
            obstructionMap = nil
            obstructionAdvice = nil
        }
    }

    func setDishConfig(_ config: DishConfig) async throws {
        guard let client else { throw GrpcError(.unavailable, "Not connected.") }
        try await client.setConfig(config)
    }

    /// Asks the endpoint which operations it answers. Read-only, and slow enough
    /// that it stays a manual action on the Diagnostics screen.
    func probeCapabilities() async -> [Operation: Bool] {
        guard let client else { return [:] }
        return await client.probeCapabilities()
    }

    /// Runs one read-only operation and returns its undecoded response tree.
    func rawRequestDump(_ op: Operation) async -> String {
        guard let client else { return "Not connected." }
        do {
            guard let message = try await client.raw(op) else {
                return "\(op.label) returned an empty response."
            }
            let dump = message.dump()
            return dump.isEmpty ? "\(op.label) returned a message with no fields." : dump
        } catch {
            let grpc = error as? GrpcError
            return "\(op.label) failed.\n\n\(grpc?.message ?? error.localizedDescription)"
        }
    }

    func eraseHistory() async {
        try? await store?.eraseAll()
        storeStatistics = try? await store?.statistics()
        recentOutages = []
        speedTests = []
    }

    var transportKind: String { client?.transport.kind.rawValue ?? "none" }
    var transportTarget: String { client?.transport.target ?? "—" }

    func acknowledge(_ alert: Alert) {
        acknowledgedAlertIDs.insert(alert.id)
    }

    func acknowledgeAll() {
        acknowledgedAlertIDs.formUnion(alerts.map(\.id))
    }

    var unacknowledgedAlerts: [Alert] {
        alerts.filter { !acknowledgedAlertIDs.contains($0.id) }
    }

    var highestSeverity: Alert.Severity? {
        unacknowledgedAlerts.map(\.severity).max()
    }

    // MARK: - Derived views of the data

    /// The most recent `seconds` of live samples, for sparklines.
    func recentSamples(seconds: Int) -> [HistorySample] {
        let cutoff = Date.now.addingTimeInterval(-Double(seconds))
        return liveSamples.filter { $0.t >= cutoff }
    }

    func sparkline(seconds: Int = 300, _ pick: (HistorySample) -> Double?) -> [Double] {
        let samples = recentSamples(seconds: seconds)
        guard samples.count > 4 else { return [] }
        // Downsample to a fixed width so the sparkline cost is constant.
        let target = 60
        let stride = max(1, samples.count / target)
        return Swift.stride(from: 0, to: samples.count, by: stride)
            .compactMap { pick(samples[$0]) }
    }

    var isDemo: Bool { settings.source == .demo }

    var storeErrorMessage: String? { storeFailure }

    /// Only available in demo mode: force conditions so the UI's unhealthy
    /// states can be inspected without waiting for the real thing.
    func inject(_ injection: DishSimulator.Injection) async {
        guard let transport = client?.transport as? SimulatorTransport else { return }
        await transport.simulator.inject(injection)
    }
}
