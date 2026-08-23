import Foundation

/// gRPC-web over `URLSession`.
///
/// The dish exposes native gRPC on :9200 and gRPC-web on :9201. Native gRPC
/// needs HTTP/2 trailers, which `URLSession` does not surface; gRPC-web carries
/// the same payloads over ordinary HTTP/1.1 request/response, so Cathode speaks
/// that and needs no gRPC library at all.
///
/// Two iOS specifics matter here:
///  * The dish is HTTP-only, so `Info.plist` carries a scoped ATS exception.
///  * Reaching a LAN address triggers the local-network privacy prompt. The
///    first call after a cold start is the one that raises it, and it fails
///    while the user decides — hence the retry and the tailored error text.
final class GrpcWebTransport: DishTransport {
    let kind: TransportKind = .grpcWeb
    let target: String

    private let baseURL: URL
    private let session: URLSession

    init(host: String = DishEndpoint.dishHost, port: Int = DishEndpoint.dishPort) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)!
        self.target = urlString

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // The dish answers instantly on the LAN; a deep pipeline just delays
        // detection of a link that has gone away.
        config.httpMaximumConnectionsPerHost = 4
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: config)
    }

    func unary(method: String, request payload: Data, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: method))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = GrpcFrame.frame(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.translate(error, target: target)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrpcError(.internalError, "Unexpected response from \(target)")
        }
        guard http.statusCode == 200 else {
            throw GrpcError(.unavailable, "The dish returned HTTP \(http.statusCode).",
                            hint: "Port \(DishEndpoint.dishPort) answered but rejected the request. "
                                + "This usually means the address is a different device, not a dish.")
        }

        // Status can arrive in headers or in a trailer frame depending on firmware.
        var status = (http.value(forHTTPHeaderField: "grpc-status").flatMap { Int($0) }) ?? 0
        var statusMessage = http.value(forHTTPHeaderField: "grpc-message") ?? ""
        var message: Data?

        for frame in GrpcFrame.parse(data) {
            if frame.isTrailer {
                let trailers = GrpcFrame.parseTrailers(frame.payload)
                if let s = trailers["grpc-status"].flatMap({ Int($0) }) { status = s }
                if let m = trailers["grpc-message"] {
                    statusMessage = m.removingPercentEncoding ?? m
                }
            } else if message == nil {
                message = frame.payload
            }
        }

        if status != 0 {
            let code = GrpcStatus(rawValue: status) ?? .unknown
            throw GrpcError(code, statusMessage.isEmpty ? "The dish rejected the request (\(code.label))." : statusMessage)
        }
        guard let message else {
            throw GrpcError(.internalError, "The dish replied without a message body.")
        }
        return message
    }

    /// `URLError` is opaque about LAN failures. On this network the causes are
    /// few and specific, so name them instead of surfacing "could not connect".
    private static func translate(_ error: URLError, target: String) -> GrpcError {
        switch error.code {
        case .timedOut:
            return GrpcError(.deadlineExceeded, "The dish did not answer in time.",
                             hint: "It may be rebooting, or this device may have drifted onto cellular.")
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .resourceUnavailable:
            return GrpcError(.unavailable, "Can't reach \(target).",
                             hint: "Join the Starlink Wi-Fi network, then check the dish has power. "
                                 + "Cathode only works on the same network as the dish.")
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed:
            return GrpcError(.permissionDenied, "The connection was blocked by App Transport Security.",
                             hint: "The dish speaks plain HTTP; Cathode ships an ATS exception for its address.")
        case .cancelled:
            return GrpcError(.cancelled, "The request was cancelled.")
        default:
            // Local Network privacy denial surfaces here on first run.
            return GrpcError(.unavailable, "Can't reach \(target).",
                             hint: "If iOS asked for permission to find devices on your local network "
                                 + "and it was declined, enable it in Settings › Cathode › Local Network. "
                                 + "(\(error.localizedDescription))")
        }
    }
}
