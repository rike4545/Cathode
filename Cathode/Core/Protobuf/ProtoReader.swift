import Foundation

/// Protobuf wire-format reader.
///
/// Cathode decodes the dish's responses *structurally* — by field number and
/// wire type — rather than from a compiled `.proto`. Starlink's Device API is
/// undocumented and firmware updates routinely add fields; a structural reader
/// keeps working and surfaces anything new as an unknown field instead of
/// failing to parse.
enum WireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case bytes = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

enum WireValue: Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)
}

struct ProtoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A decoded protobuf message: field number → every value seen for that field.
///
/// Repeated fields keep all their values; scalar accessors take the first, which
/// matches proto3's last-one-wins-ish tolerance for duplicated scalars closely
/// enough for read-only telemetry.
struct ProtoMessage: Sendable {
    private(set) var fields: [Int: [WireValue]]

    init(fields: [Int: [WireValue]] = [:]) { self.fields = fields }

    /// Parse a buffer. Throws only on genuinely malformed framing.
    init(decoding data: Data) throws {
        var fields: [Int: [WireValue]] = [:]
        var reader = ByteReader(data)
        while !reader.isAtEnd {
            let tag = try reader.varint()
            let field = Int(tag >> 3)
            guard field > 0 else { throw ProtoError("field number 0 is invalid") }
            guard let wire = WireType(rawValue: UInt8(tag & 7)) else {
                throw ProtoError("unknown wire type \(tag & 7)")
            }
            let value: WireValue
            switch wire {
            case .varint: value = .varint(try reader.varint())
            case .fixed64: value = .fixed64(try reader.fixed64())
            case .fixed32: value = .fixed32(try reader.fixed32())
            case .bytes: value = .bytes(try reader.lengthDelimited())
            case .startGroup, .endGroup:
                try reader.skipGroup()
                continue
            }
            fields[field, default: []].append(value)
        }
        self.fields = fields
    }

    /// Non-throwing parse, for nested messages where a wrong guess about
    /// "is this bytes or a submessage?" must not abort the whole decode.
    static func tryDecode(_ data: Data) -> ProtoMessage? {
        try? ProtoMessage(decoding: data)
    }

    var isEmpty: Bool { fields.isEmpty }
    var fieldNumbers: [Int] { fields.keys.sorted() }

    func values(_ field: Int) -> [WireValue] { fields[field] ?? [] }
    func first(_ field: Int) -> WireValue? { fields[field]?.first }

    // MARK: - Scalar accessors
    //
    // Every accessor returns nil when the field is absent, so callers can tell
    // "the dish reported zero" from "this firmware does not report it".

    func uint(_ field: Int) -> UInt64? {
        switch first(field) {
        case .varint(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .fixed64(let v): return v
        default: return nil
        }
    }

    func int(_ field: Int) -> Int? {
        switch first(field) {
        case .varint(let v): return Int(Int64(bitPattern: v))
        case .fixed32(let v): return Int(Int32(bitPattern: v))
        case .fixed64(let v): return Int(Int64(bitPattern: v))
        default: return nil
        }
    }

    func bool(_ field: Int) -> Bool? {
        if case .varint(let v) = first(field) { return v != 0 }
        return nil
    }

    /// Reads a float or double field regardless of the fixed width used.
    func double(_ field: Int) -> Double? {
        switch first(field) {
        case .fixed32(let v): return Double(Float(bitPattern: v))
        case .fixed64(let v): return Double(bitPattern: v)
        case .varint(let v): return Double(Int64(bitPattern: v))
        default: return nil
        }
    }

    func string(_ field: Int) -> String? {
        guard case .bytes(let d) = first(field) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func data(_ field: Int) -> Data? {
        guard case .bytes(let d) = first(field) else { return nil }
        return d
    }

    func message(_ field: Int) -> ProtoMessage? {
        guard case .bytes(let d) = first(field) else { return nil }
        return ProtoMessage.tryDecode(d)
    }

    func messages(_ field: Int) -> [ProtoMessage] {
        values(field).compactMap {
            guard case .bytes(let d) = $0 else { return nil }
            return ProtoMessage.tryDecode(d)
        }
    }

    func strings(_ field: Int) -> [String] {
        values(field).compactMap {
            guard case .bytes(let d) = $0 else { return nil }
            return String(data: d, encoding: .utf8)
        }
    }

    /// Walks a chain of nested message fields, e.g. `path(3, 1, 4)`.
    func path(_ fields: Int...) -> ProtoMessage? {
        var current: ProtoMessage? = self
        for f in fields {
            guard let c = current else { return nil }
            current = c.message(f)
        }
        return current
    }

    // MARK: - Repeated numeric fields

    /// Element width of a packed repeated numeric field.
    ///
    /// This is a property of the schema, never of the bytes: a packed array of
    /// N `float`s and one of N/2 `double`s are byte-identical on the wire. An
    /// earlier version of this decoder sniffed the payload and got it wrong for
    /// the power series — 43 200 float32s is also a valid multiple of 8, and
    /// adjacent 4-byte watt values reinterpret into perfectly plausible-looking
    /// doubles around 1e12. So callers state the width instead.
    enum PackedWidth {
        case float32
        case float64
    }

    /// Reads a repeated float field written either packed (one length-delimited
    /// blob, which is what the dish's history arrays use) or unpacked.
    func floatArray(_ field: Int, width: PackedWidth = .float32) -> [Double] {
        var out: [Double] = []
        for value in values(field) {
            switch value {
            case .fixed32(let v): out.append(Double(Float(bitPattern: v)))
            case .fixed64(let v): out.append(Double(bitPattern: v))
            case .varint(let v): out.append(Double(Int64(bitPattern: v)))
            case .bytes(let d): out.append(contentsOf: Self.unpack(d, width: width))
            }
        }
        return out
    }

    func intArray(_ field: Int) -> [Int] {
        var out: [Int] = []
        for value in values(field) {
            switch value {
            case .varint(let v): out.append(Int(Int64(bitPattern: v)))
            case .fixed32(let v): out.append(Int(Int32(bitPattern: v)))
            case .fixed64(let v): out.append(Int(Int64(bitPattern: v)))
            case .bytes(let d):
                var r = ByteReader(d)
                while !r.isAtEnd, let v = try? r.varint() {
                    out.append(Int(Int64(bitPattern: v)))
                }
            }
        }
        return out
    }

    func boolArray(_ field: Int) -> [Bool] {
        let ints = intArray(field)
        if !ints.isEmpty { return ints.map { $0 != 0 } }
        return floatArray(field).map { $0 != 0 }
    }

    private static func unpack(_ data: Data, width: PackedWidth) -> [Double] {
        guard !data.isEmpty else { return [] }
        let stride = width == .float32 ? 4 : 8
        guard data.count % stride == 0 else {
            // Not a packed fixed-width array; the only other legal encoding for
            // a packed numeric field is varints.
            var reader = ByteReader(data)
            var out: [Double] = []
            while !reader.isAtEnd, let v = try? reader.varint() {
                out.append(Double(Int64(bitPattern: v)))
            }
            return out
        }

        var out = [Double]()
        out.reserveCapacity(data.count / stride)
        data.withUnsafeBytes { raw in
            for offset in Swift.stride(from: 0, to: data.count, by: stride) {
                switch width {
                case .float32:
                    let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                    out.append(Double(Float(bitPattern: bits)))
                case .float64:
                    let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
                    out.append(Double(bitPattern: bits))
                }
            }
        }
        return out
    }
}

extension ProtoMessage {
    /// Renders an undecoded message as an inspectable tree.
    ///
    /// Length-delimited fields are ambiguous on the wire — bytes, a string, and
    /// a nested message look identical — so this shows the interpretation that
    /// parses cleanly, and falls back to a hex preview when none does.
    func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var lines: [String] = []
        for field in fieldNumbers {
            for value in values(field) {
                switch value {
                case .varint(let v):
                    lines.append("\(pad)\(field): \(Int64(bitPattern: v))")
                case .fixed32(let v):
                    let f = Float(bitPattern: v)
                    lines.append("\(pad)\(field): \(f.isFinite ? String(format: "%g", f) : "NaN") (f32)")
                case .fixed64(let v):
                    let d = Double(bitPattern: v)
                    lines.append("\(pad)\(field): \(d.isFinite ? String(format: "%g", d) : "NaN") (f64)")
                case .bytes(let data):
                    if let nested = ProtoMessage.tryDecode(data), !nested.isEmpty,
                       nested.reencodedLength == data.count {
                        lines.append("\(pad)\(field): {")
                        lines.append(nested.dump(indent: indent + 1))
                        lines.append("\(pad)}")
                    } else if let text = String(data: data, encoding: .utf8),
                              !text.isEmpty,
                              text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" }) {
                        lines.append("\(pad)\(field): \"\(text)\"")
                    } else if data.count > 64 {
                        lines.append("\(pad)\(field): <\(data.count) bytes>")
                    } else {
                        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                        lines.append("\(pad)\(field): \(hex)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Total wire length if this message were re-encoded. Used as a cheap check
    /// that a byte blob really was a nested message rather than a lucky parse.
    var reencodedLength: Int {
        var total = 0
        for field in fieldNumbers {
            for value in values(field) {
                total += varintLength(UInt64(field) << 3)
                switch value {
                case .varint(let v): total += varintLength(v)
                case .fixed32: total += 4
                case .fixed64: total += 8
                case .bytes(let d): total += varintLength(UInt64(d.count)) + d.count
                }
            }
        }
        return total
    }
}

private func varintLength(_ value: UInt64) -> Int {
    var v = value, n = 1
    while v > 0x7f { v >>= 7; n += 1 }
    return n
}

/// Cursor over a `Data` buffer with the primitive wire reads.
struct ByteReader {
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        self.data = data
        self.index = 0
    }

    var isAtEnd: Bool { index >= data.count }

    private mutating func next() throws -> UInt8 {
        guard index < data.count else { throw ProtoError("unexpected end of buffer") }
        defer { index += 1 }
        return data[data.startIndex + index]
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        // Protobuf caps varints at 10 bytes (64 bits plus continuation bits).
        for _ in 0..<10 {
            let byte = try next()
            result |= UInt64(byte & 0x7f) &<< shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError("varint longer than 10 bytes")
    }

    mutating func fixed32() throws -> UInt32 {
        guard index + 4 <= data.count else { throw ProtoError("truncated fixed32") }
        defer { index += 4 }
        return data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index, as: UInt32.self).littleEndian
        }
    }

    mutating func fixed64() throws -> UInt64 {
        guard index + 8 <= data.count else { throw ProtoError("truncated fixed64") }
        defer { index += 8 }
        return data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index, as: UInt64.self).littleEndian
        }
    }

    mutating func lengthDelimited() throws -> Data {
        let length = Int(try varint())
        guard length >= 0, index + length <= data.count else {
            throw ProtoError("truncated length-delimited field")
        }
        defer { index += length }
        let start = data.startIndex + index
        return data[start..<(start + length)]
    }

    /// Groups are deprecated but older dish firmware still emits them.
    mutating func skipGroup() throws {
        while !isAtEnd {
            let tag = try varint()
            guard let wire = WireType(rawValue: UInt8(tag & 7)) else {
                throw ProtoError("unknown wire type in group")
            }
            switch wire {
            case .endGroup: return
            case .varint: _ = try varint()
            case .fixed32: _ = try fixed32()
            case .fixed64: _ = try fixed64()
            case .bytes: _ = try lengthDelimited()
            case .startGroup: try skipGroup()
            }
        }
        throw ProtoError("unterminated group")
    }
}
