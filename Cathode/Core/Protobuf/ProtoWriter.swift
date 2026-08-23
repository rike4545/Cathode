import Foundation

/// Protobuf wire-format writer.
///
/// Requests to the dish are tiny, but the built-in simulator encodes a full
/// 12-hour history ring (five packed float arrays of 43 200 samples) on every
/// `get_history` call, so appends have to be amortised rather than naive.
struct ProtoWriter {
    private(set) var data: Data

    init(capacity: Int = 256) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v > 0x7f {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wire: WireType) {
        rawVarint(UInt64(field) << 3 | UInt64(wire.rawValue))
    }

    // MARK: - Scalars

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, .varint)
        rawVarint(value)
    }

    mutating func varint(_ field: Int, _ value: Int) {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    /// Proto3 omits zero-valued scalars; use this for genuinely optional config
    /// so an unset control is not written as an explicit zero.
    mutating func varintIfSet(_ field: Int, _ value: Int?) {
        if let value { varint(field, value) }
    }

    mutating func boolIfSet(_ field: Int, _ value: Bool?) {
        if let value { bool(field, value) }
    }

    mutating func float(_ field: Int, _ value: Double) {
        tag(field, .fixed32)
        withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func double(_ field: Int, _ value: Double) {
        tag(field, .fixed64)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, .bytes)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func stringIfSet(_ field: Int, _ value: String?) {
        if let value { string(field, value) }
    }

    // MARK: - Packed repeated fields

    mutating func packedFloat(_ field: Int, _ values: [Double]) {
        guard !values.isEmpty else { return }
        tag(field, .bytes)
        rawVarint(UInt64(values.count * 4))
        var buffer = [UInt8]()
        buffer.reserveCapacity(values.count * 4)
        for v in values {
            withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        }
        data.append(contentsOf: buffer)
    }

    mutating func packedFloat(_ field: Int, _ values: ArraySlice<Float>) {
        guard !values.isEmpty else { return }
        tag(field, .bytes)
        rawVarint(UInt64(values.count * 4))
        var buffer = [UInt8]()
        buffer.reserveCapacity(values.count * 4)
        for v in values {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        }
        data.append(contentsOf: buffer)
    }

    mutating func packedVarint(_ field: Int, _ values: [Int]) {
        guard !values.isEmpty else { return }
        var inner = ProtoWriter(capacity: values.count + 8)
        for v in values { inner.rawVarint(UInt64(bitPattern: Int64(v))) }
        bytes(field, inner.data)
    }

    // MARK: - Nested messages

    /// Writes a nested message. Passing no builder writes a zero-length field,
    /// which is exactly how the dish's request oneof arms are expressed.
    mutating func message(_ field: Int, _ build: ((inout ProtoWriter) -> Void)? = nil) {
        guard let build else {
            tag(field, .bytes)
            rawVarint(0)
            return
        }
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    static func encode(_ build: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        build(&w)
        return w.data
    }
}
