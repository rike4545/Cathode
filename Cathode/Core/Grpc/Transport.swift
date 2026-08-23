import Foundation

/// The single gRPC method every dish operation travels over.
let deviceMethod = "SpaceX.API.Device.Device/Handle"

enum TransportKind: String, Sendable {
    case grpcWeb = "gRPC-web"
    case simulator = "Simulator"
}

/// What a dish connection has to provide. Both the real gRPC-web transport and
/// the built-in simulator conform, so nothing above this layer knows or cares
/// whether there is hardware on the other end.
protocol DishTransport: Sendable {
    var kind: TransportKind { get }
    var target: String { get }
    func unary(method: String, request: Data, timeout: TimeInterval) async throws -> Data
}

extension DishTransport {
    func unary(method: String = deviceMethod, request: Data) async throws -> Data {
        try await unary(method: method, request: request, timeout: 8)
    }
}

/// Well-known local endpoints exposed by Starlink hardware.
enum DishEndpoint {
    /// The dish's gRPC-web port. HTTP/1.1, and the only one reachable from a
    /// plain URLSession without a full HTTP/2 gRPC stack.
    static let dishHost = "192.168.100.1"
    static let dishPort = 9201
    /// Gen 2/3 router. Same Device service, different address.
    static let routerHost = "192.168.1.1"
    static let routerPort = 9000
}
