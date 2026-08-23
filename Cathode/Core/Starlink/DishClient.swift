import Foundation

/// The dish client.
///
/// Every operation travels over one gRPC method (`Device/Handle`) as an arm of a
/// oneof, so the whole API surface reduces to `call(op:)`.
actor DishClient {
    let transport: DishTransport
    private var nextID: UInt64 = 1
    /// Operations this endpoint answered with UNIMPLEMENTED. Probing once and
    /// remembering keeps the poll loop from retrying what the hardware lacks —
    /// a dish in bypass mode has no router operations, for instance.
    private(set) var unsupported: Set<Operation> = []

    init(transport: DishTransport) {
        self.transport = transport
    }

    var target: String { transport.target }
    var kind: TransportKind { transport.kind }

    func supports(_ op: Operation) -> Bool { !unsupported.contains(op) }

    /// Issues one Device/Handle call and returns the unwrapped response payload.
    private func call(
        _ op: Operation,
        timeout: TimeInterval = 8,
        retries: Int = 1,
        build: ((inout ProtoWriter) -> Void)? = nil
    ) async throws -> ProtoMessage? {
        if unsupported.contains(op) {
            throw GrpcError(.unimplemented, "\(op.label) is not available on this device.")
        }
        let id = nextID
        nextID &+= 1
        let request = ProtoWriter.encode { w in
            w.varint(1, id)
            w.message(op.field, build)
        }

        var lastError: Error?
        for attempt in 0...retries {
            do {
                let bytes = try await transport.unary(
                    method: deviceMethod, request: request, timeout: timeout)
                return try DishDecode.unwrap(bytes, op)
            } catch let error as GrpcError {
                if error.status == .unimplemented {
                    unsupported.insert(op)
                    throw error
                }
                lastError = error
                guard error.isRetryable, attempt < retries else { throw error }
                // Brief linear backoff — the dish recovers in well under a second.
                try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            } catch {
                lastError = error
                guard attempt < retries else { throw error }
            }
            try Task.checkCancellation()
        }
        throw lastError ?? GrpcError(.unknown, "\(op.label) failed.")
    }

    // MARK: - Reads

    func status() async throws -> DishStatus {
        DishDecode.status(try await call(.getStatus, timeout: 6))
    }

    func deviceInfo() async throws -> DeviceInfo {
        DishDecode.deviceInfo(try await call(.getDeviceInfo, timeout: 6))
    }

    /// The full ring is ~43 200 samples per series. Pull it once at startup and
    /// afterwards ask only for the tail that has not been recorded yet.
    func history(limit: Int? = nil) async throws -> HistoryWindow {
        DishDecode.history(try await call(.getHistory, timeout: 25), limit: limit)
    }

    func obstructionMap() async throws -> ObstructionMap? {
        DishDecode.obstructionMap(try await call(.dishGetObstructionMap, timeout: 20))
    }

    func location() async throws -> DishLocation {
        DishDecode.location(try await call(.getLocation, timeout: 6))
    }

    func wifiStatus() async throws -> WifiStatus {
        DishDecode.wifiStatus(try await call(.wifiGetStatus, timeout: 6))
    }

    func wifiClients() async throws -> WifiStatus {
        DishDecode.wifiStatus(try await call(.wifiGetClients, timeout: 8))
    }

    /// Runs the dish's built-in speed test. This saturates the link for ~30s, so
    /// it is deliberately never part of the poll loop.
    func speedTest() async throws -> SpeedTestResult {
        DishDecode.speedTest(try await call(.speedTest, timeout: 120, retries: 0))
    }

    // MARK: - Controls
    //
    // Each of these changes hardware state. The UI confirms before calling them.

    func reboot() async throws {
        _ = try await call(.reboot, timeout: 6, retries: 0)
    }

    func stow(_ stowed: Bool) async throws {
        _ = try await call(.dishStow, timeout: 6, retries: 0) { w in
            w.bool(1, !stowed)
        }
    }

    func clearObstructionMap() async throws {
        _ = try await call(.dishClearObstructionMap, timeout: 6, retries: 0)
    }

    func setConfig(_ config: DishConfig) async throws {
        _ = try await call(.dishSetConfig, timeout: 8, retries: 0) { w in
            w.message(1) { c in
                if let mode = config.snowMeltMode { c.varint(3, mode.wireValue) }
                c.boolIfSet(6, config.applyPowerSave)
                c.varintIfSet(7, config.sleepStartMinute)
                c.varintIfSet(8, config.sleepDurationMinutes)
                c.boolIfSet(9, config.sleepEnabled)
            }
        }
    }

    /// Raw escape hatch backing the Diagnostics request console.
    func raw(_ op: Operation) async throws -> ProtoMessage? {
        try await call(op, timeout: 20, retries: 0)
    }

    /// Asks the endpoint which operations it actually answers. Runs once per
    /// connection so unsupported features can be hidden rather than fail later.
    func probeCapabilities() async -> [Operation: Bool] {
        var results: [Operation: Bool] = [:]
        for op in Operation.allCases where !op.isMutating {
            do {
                _ = try await call(op, timeout: 4, retries: 0)
                results[op] = true
            } catch let error as GrpcError where error.status == .unimplemented {
                results[op] = false
            } catch {
                // A timeout is not evidence of absence; leave it unrecorded.
                continue
            }
        }
        return results
    }
}

struct DishConfig: Sendable, Equatable {
    enum SnowMeltMode: String, CaseIterable, Sendable {
        case auto, alwaysOn, off
        var wireValue: Int {
            switch self {
            case .auto: 0
            case .alwaysOn: 1
            case .off: 2
            }
        }
        var label: String {
            switch self {
            case .auto: "Automatic"
            case .alwaysOn: "Always on"
            case .off: "Off"
            }
        }
    }

    var snowMeltMode: SnowMeltMode?
    var sleepEnabled: Bool?
    /// Minutes past local midnight.
    var sleepStartMinute: Int?
    var sleepDurationMinutes: Int?
    var applyPowerSave: Bool?
}
