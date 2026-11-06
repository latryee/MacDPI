import Foundation

public enum TLSInspection: Equatable, Sendable {
    case incomplete
    case passthrough
    case clientHello(recordLength: Int, serverNameRange: Range<Int>?)
}

public enum TLSProcessor {
    public static let maximumRecordPayload = 16_384
    public static let maximumBuffered = maximumRecordPayload + 5

    /// Inspects only the first plaintext handshake record. Returns offsets, never retained hostnames.
    public static func inspect(_ data: Data) -> TLSInspection {
        guard let first = data.first else { return .incomplete }
        guard first == 22 else { return .passthrough }
        guard data.count >= 5 else { return .incomplete }
        let header = [UInt8](data.prefix(5))
        let length = Int(header[3]) * 256 + Int(header[4])
        guard header[1] == 3, header[2] <= 3, length >= 4, length <= maximumRecordPayload else { return .passthrough }
        guard data.count >= length + 5 else { return .incomplete }
        // Do not copy/reparse the growing payload on each incomplete receive.
        let b = [UInt8](data.prefix(length + 5))
        guard b[5] == 1 else { return .passthrough }
        let handshakeLength = Int(b[6]) << 16 | Int(b[7]) << 8 | Int(b[8])
        // Fragmented/multiple handshakes are forwarded unchanged, never partially rewritten.
        guard handshakeLength + 4 == length else { return .passthrough }
        var p = 9
        let end = 5 + length
        func take(_ n: Int) -> Bool {
            guard n >= 0, p <= end, n <= end - p else { return false }
            p += n; return true
        }
        func u8() -> Int? { guard p < end else { return nil }; defer { p += 1 }; return Int(b[p]) }
        func u16() -> Int? {
            guard p + 2 <= end else { return nil }; defer { p += 2 }
            return Int(b[p]) * 256 + Int(b[p+1])
        }
        guard take(34), let session = u8(), session <= 32, take(session),
              let ciphers = u16(), ciphers >= 2, ciphers % 2 == 0, take(ciphers),
              let compression = u8(), compression >= 1, take(compression) else { return .passthrough }
        if p == end { return .clientHello(recordLength: end, serverNameRange: nil) }
        guard let extensions = u16(), extensions == end - p else { return .passthrough }
        var nameRange: Range<Int>?
        var seen = Set<Int>()
        while p < end {
            guard let type = u16(), let size = u16(), size <= end - p, seen.insert(type).inserted else { return .passthrough }
            let next = p + size
            if type == 0 {
                guard let listSize = u16(), listSize == next - p else { return .passthrough }
                while p < next {
                    guard let nameType = u8(), let n = u16(), n > 0, n <= next - p else { return .passthrough }
                    if nameType == 0 {
                        guard nameRange == nil, n <= 253 else { return .passthrough }
                        nameRange = p..<(p+n)
                    }
                    guard take(n) else { return .passthrough }
                }
            }
            p = next
        }
        return .clientHello(recordLength: end, serverNameRange: nameRange)
    }

    /// Two valid TLS records; concatenated handshake bytes are identical to the input.
    public static func transform(_ data: Data, profile: Profile, offset: Int = 32) -> (data: Data, transformed: Bool) {
        guard profile != .compatibility, case let .clientHello(recordLength, sni) = inspect(data) else { return (data, false) }
        let payloadLength = recordLength - 5
        let desired = profile == .standard ? sni.map { $0.lowerBound - 5 + max(1, $0.count / 2) } ?? 32 : offset
        let split = min(max(1, desired), payloadLength - 1)
        let bytes = [UInt8](data.prefix(5))
        func header(_ n: Int) -> Data { Data([22, bytes[1], bytes[2], UInt8(n >> 8), UInt8(n & 255)]) }
        var out = Data(capacity: data.count + 5)
        out.append(header(split)); out.append(data.dropFirst(5).prefix(split))
        out.append(header(payloadLength - split)); out.append(data.dropFirst(5 + split).prefix(payloadLength - split))
        out.append(data.dropFirst(recordLength))
        return (out, true)
    }
}

/// One bounded accumulator per flow. Once decided, subsequent traffic never visits the TLS parser.
public struct InitialFlightProcessor {
    private var buffered = Data()
    public private(set) var decided = false
    private let configuration: Configuration
    public init(configuration: Configuration) {
        self.configuration = configuration
        decided = configuration.profile == .compatibility
    }
    public mutating func consume(_ data: Data, eof: Bool = false) -> (data: Data, transformed: Bool)? {
        if decided { return (data, false) }
        if configuration.profile == .compatibility { decided = true; return (data, false) }
        // Each TCP receive is <=64 KiB; the retained prefix never exceeds maximumBuffered.
        let room = max(0, TLSProcessor.maximumBuffered - buffered.count)
        buffered.append(data.prefix(room))
        if TLSProcessor.inspect(buffered) == .incomplete && !eof && data.count <= room && buffered.count < TLSProcessor.maximumBuffered { return nil }
        decided = true
        var result = TLSProcessor.transform(buffered, profile: configuration.profile, offset: configuration.splitOffset)
        result.data.append(data.dropFirst(room))
        buffered.removeAll(keepingCapacity: false)
        return result
    }
}
