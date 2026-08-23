import Foundation

/// Finds Starlink hardware on the local network.
///
/// The dish answers on a fixed management address, `192.168.100.1`, regardless
/// of what subnet the router hands out — it is reachable even in bypass mode
/// with a third-party router in front. So discovery is not really a search: it
/// is a short list of candidates probed in parallel, and the first thing that
/// speaks the Device API wins.
///
/// A full subnet sweep exists as a fallback for the unusual cases (a dish
/// behind a double-NAT, or a router that was moved off its default address),
/// but it is never run automatically — 254 probes is slow, and on iOS it makes
/// the local-network prompt look far more invasive than it is.
enum DishDiscovery {

    struct Found: Sendable, Identifiable, Equatable {
        enum Kind: String, Sendable {
            case dish, router

            var label: String {
                switch self {
                case .dish: "Dish"
                case .router: "Router"
                }
            }
        }

        var host: String
        var port: Int
        var kind: Kind
        var deviceInfo: DeviceInfo
        /// How long the probe took, useful for picking the closest responder.
        var responseMilliseconds: Int

        var id: String { "\(host):\(port)" }

        var describedName: String {
            deviceInfo.hardwareName ?? deviceInfo.hardwareVersion ?? kind.label
        }
    }

    struct Candidate: Sendable, Equatable {
        var host: String
        var port: Int
        var kind: Found.Kind
        /// Why this address is being tried, shown during a scan.
        var reason: String
    }

    /// Probes worth making before falling back to a sweep.
    static func candidates() -> [Candidate] {
        var out: [Candidate] = [
            Candidate(host: DishEndpoint.dishHost, port: DishEndpoint.dishPort,
                      kind: .dish, reason: "Starlink's fixed dish address"),
            Candidate(host: DishEndpoint.routerHost, port: DishEndpoint.routerPort,
                      kind: .router, reason: "Default Starlink router address"),
        ]
        // If this device sits on some other subnet, the router is almost
        // certainly at .1 of it.
        if let subnet = localSubnet() {
            let gateway = "\(subnet.prefix).1"
            if gateway != DishEndpoint.routerHost {
                out.append(Candidate(host: gateway, port: DishEndpoint.routerPort,
                                     kind: .router, reason: "Gateway for this network"))
            }
        }
        return out
    }

    /// Runs the candidate probes concurrently and returns everything that answered.
    static func discover(timeout: TimeInterval = 2) async -> [Found] {
        await probeAll(candidates(), timeout: timeout)
    }

    /// Sweeps the whole local /24 looking for the Device API. Explicit action
    /// only. Reports progress so a long scan does not look frozen.
    static func sweep(
        timeout: TimeInterval = 1.2,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async -> [Found] {
        guard let subnet = localSubnet() else { return await discover() }
        var targets: [Candidate] = []
        for host in 1...254 {
            let address = "\(subnet.prefix).\(host)"
            targets.append(Candidate(host: address, port: DishEndpoint.dishPort,
                                     kind: .dish, reason: "Network scan"))
            targets.append(Candidate(host: address, port: DishEndpoint.routerPort,
                                     kind: .router, reason: "Network scan"))
        }
        // Always include the fixed dish address; it is frequently outside the
        // subnet the router hands out.
        targets.append(contentsOf: candidates())

        return await probeAll(targets, timeout: timeout, concurrency: 24, progress: progress)
    }

    private static func probeAll(
        _ targets: [Candidate],
        timeout: TimeInterval,
        concurrency: Int = 8,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [Found] {
        guard !targets.isEmpty else { return [] }
        let total = Double(targets.count)

        return await withTaskGroup(of: Found?.self) { group in
            var found: [Found] = []
            var index = 0
            var completed = 0.0

            // A bounded window: hundreds of simultaneous sockets on a phone
            // produces timeouts that look like absent hardware.
            func addNext() {
                guard index < targets.count else { return }
                let target = targets[index]
                index += 1
                group.addTask { await probe(target, timeout: timeout) }
            }
            for _ in 0..<min(concurrency, targets.count) { addNext() }

            while let result = await group.next() {
                completed += 1
                progress?(completed / total)
                if let result { found.append(result) }
                addNext()
                if Task.isCancelled { break }
            }

            // Dish before router, then fastest first: the dish is what the app
            // is actually for.
            return found.sorted {
                $0.kind != $1.kind
                    ? $0.kind == .dish
                    : $0.responseMilliseconds < $1.responseMilliseconds
            }
        }
    }

    /// One probe. `getDeviceInfo` is the cheapest call that proves both that
    /// something is listening and that it is Starlink hardware rather than any
    /// other device that happens to have the port open.
    static func probe(_ candidate: Candidate, timeout: TimeInterval = 2) async -> Found? {
        let transport = GrpcWebTransport(host: candidate.host, port: candidate.port)
        let client = DishClient(transport: transport)
        let started = ContinuousClock.now
        do {
            let info = try await withTimeout(seconds: timeout) {
                try await client.deviceInfo()
            }
            // An empty response means something answered but is not a dish.
            guard info.hardwareVersion != nil || info.id != nil else { return nil }
            let elapsed = ContinuousClock.now - started
            return Found(
                host: candidate.host, port: candidate.port, kind: candidate.kind,
                deviceInfo: info,
                responseMilliseconds: Int(elapsed.components.seconds * 1000
                    + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)))
        } catch {
            return nil
        }
    }

    /// This device's IPv4 address and its /24 prefix on the Wi-Fi interface.
    ///
    /// Read straight from `getifaddrs`. iOS offers no API for the default
    /// gateway without entitlements, but on a home network the gateway is
    /// `.1` of the local subnet essentially always, and that guess costs one
    /// extra probe when it is wrong.
    static func localSubnet() -> (address: String, prefix: String)? {
        var storage: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&storage) == 0, let first = storage else { return nil }
        defer { freeifaddrs(storage) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            // en0 is Wi-Fi on iOS; the dish is never reachable over cellular.
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                 as: UTF8.self)
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            return (address, parts.prefix(3).joined(separator: "."))
        }
        return nil
    }
}

/// Races an operation against a deadline. `URLSession`'s own timeout covers the
/// request, but a probe against a dead address can sit in connection setup for
/// far longer than a scan can afford.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw GrpcError(.deadlineExceeded, "Probe timed out.")
        }
        guard let result = try await group.next() else {
            throw GrpcError(.deadlineExceeded, "Probe produced no result.")
        }
        group.cancelAll()
        return result
    }
}
