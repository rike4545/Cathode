import Foundation

/// gRPC length-prefixed message framing.
///
/// Frame layout: one compression byte, a 4-byte big-endian length, then the
/// payload. gRPC-web adds a trailer frame with the high bit (0x80) set that
/// carries HTTP-header-style `grpc-status` / `grpc-message` text.
enum GrpcFrame {
    struct Parsed {
        let isTrailer: Bool
        let payload: Data
    }

    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(0) // not compressed
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func parse(_ buffer: Data) -> [Parsed] {
        var frames: [Parsed] = []
        var offset = buffer.startIndex
        while offset + 5 <= buffer.endIndex {
            let flags = buffer[offset]
            let length = buffer.withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(
                    fromByteOffset: offset - buffer.startIndex + 1, as: UInt32.self))
            }
            let start = offset + 5
            let end = start + Int(length)
            guard end <= buffer.endIndex else { break } // partial frame
            frames.append(Parsed(isTrailer: flags & 0x80 != 0, payload: buffer[start..<end]))
            offset = end
        }
        return frames
    }

    /// Parses a gRPC-web trailer frame — `key: value` lines, CRLF separated.
    static func parseTrailers(_ payload: Data) -> [String: String] {
        guard let text = String(data: payload, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

/// Canonical gRPC status codes, with the handful Cathode reacts to named.
enum GrpcStatus: Int, Sendable {
    case ok = 0, cancelled = 1, unknown = 2, invalidArgument = 3, deadlineExceeded = 4
    case notFound = 5, alreadyExists = 6, permissionDenied = 7, resourceExhausted = 8
    case failedPrecondition = 9, aborted = 10, outOfRange = 11, unimplemented = 12
    case internalError = 13, unavailable = 14, dataLoss = 15, unauthenticated = 16

    var label: String {
        switch self {
        case .ok: "OK"
        case .cancelled: "CANCELLED"
        case .unknown: "UNKNOWN"
        case .invalidArgument: "INVALID_ARGUMENT"
        case .deadlineExceeded: "DEADLINE_EXCEEDED"
        case .notFound: "NOT_FOUND"
        case .alreadyExists: "ALREADY_EXISTS"
        case .permissionDenied: "PERMISSION_DENIED"
        case .resourceExhausted: "RESOURCE_EXHAUSTED"
        case .failedPrecondition: "FAILED_PRECONDITION"
        case .aborted: "ABORTED"
        case .outOfRange: "OUT_OF_RANGE"
        case .unimplemented: "UNIMPLEMENTED"
        case .internalError: "INTERNAL"
        case .unavailable: "UNAVAILABLE"
        case .dataLoss: "DATA_LOSS"
        case .unauthenticated: "UNAUTHENTICATED"
        }
    }
}

struct GrpcError: Error, LocalizedError, Sendable {
    let status: GrpcStatus
    let message: String
    /// Extra guidance shown in the connection banner — usually the "what to try"
    /// half of an otherwise opaque networking failure.
    let hint: String?

    init(_ status: GrpcStatus, _ message: String, hint: String? = nil) {
        self.status = status
        self.message = message
        self.hint = hint
    }

    var errorDescription: String? { message }

    /// Transient failures worth another attempt, versus permanent protocol errors.
    var isRetryable: Bool {
        switch status {
        case .unavailable, .deadlineExceeded, .aborted, .resourceExhausted: true
        default: false
        }
    }
}
