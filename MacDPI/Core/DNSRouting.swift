import Foundation

/// Bounded DNS envelope parsing for transparent DNS. Unlike the local A/AAAA resolver, this
/// preserves arbitrary ordinary query types (including SRV/TXT/HTTPS) and NXDOMAIN responses.
public struct DNSPacket {
    public let data: Data
    public let identifier: UInt16
    public let flags: UInt16
    public let name: String
    public let type: UInt16
    public let queryClass: UInt16
    public let questionEnd: Int
    public let udpLimit: Int
    public static let maximumSize = 32_768

    public init(_ data: Data, response: Bool) throws {
        guard (12...Self.maximumSize).contains(data.count) else { throw CoreError.invalidRequest }
        let bytes = [UInt8](data)
        func word(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset + 2 <= bytes.count else { throw CoreError.invalidRequest }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset+1])
        }
        func readName(_ cursor: inout Int) throws -> String {
            var position = cursor, resume: Int?, labels = [String](), visited = Set<Int>(), total = 0
            while true {
                guard position < bytes.count, visited.insert(position).inserted, visited.count <= 128 else { throw CoreError.invalidRequest }
                let length = Int(bytes[position])
                if length & 0xc0 == 0xc0 {
                    let target = Int(try word(position) & 0x3fff)
                    guard target >= 12, target < position else { throw CoreError.invalidRequest }
                    if resume == nil { resume = position + 2 }
                    position = target; continue
                }
                guard length <= 63, length <= bytes.count - position - 1 else { throw CoreError.invalidRequest }
                position += 1
                if length == 0 { cursor = resume ?? position; return labels.joined(separator: ".").lowercased() }
                total += length + 1
                let label = bytes[position..<(position+length)]
                guard total <= 254, label.allSatisfy({ (33...126).contains($0) && $0 != 46 }),
                      let text = String(bytes: label, encoding: .ascii) else { throw CoreError.invalidRequest }
                labels.append(text); position += length
            }
        }
        identifier = try word(0); flags = try word(2)
        let answers = Int(try word(6)), authorities = Int(try word(8)), additionals = Int(try word(10))
        guard (flags & 0x8000 != 0) == response, flags & 0x7800 == 0, try word(4) == 1,
              answers + authorities + additionals <= 256,
              response || (answers == 0 && authorities == 0 && additionals <= 16 && flags & 0x0200 == 0) else { throw CoreError.invalidRequest }
        var cursor = 12
        name = try readName(&cursor)
        type = try word(cursor); queryClass = try word(cursor+2); cursor += 4
        guard queryClass == 1 else { throw CoreError.invalidRequest }
        questionEnd = cursor
        var limit = 512, optSeen = false
        for index in 0..<(answers + authorities + additionals) {
            let owner = try readName(&cursor)
            let kind = try word(cursor), cls = try word(cursor+2), length = Int(try word(cursor+8))
            cursor += 10
            guard length <= bytes.count - cursor else { throw CoreError.invalidRequest }
            if kind == 41 {
                guard index >= answers + authorities, owner.isEmpty, !optSeen else { throw CoreError.invalidRequest }
                optSeen = true; limit = min(4096, max(512, Int(cls)))
            }
            cursor += length
        }
        guard cursor == bytes.count else { throw CoreError.invalidRequest }
        self.data = data; udpLimit = limit
    }
    public func validates(response: DNSPacket) -> Bool {
        identifier == response.identifier && name == response.name && type == response.type && queryClass == response.queryClass
    }
    public func reply(_ response: DNSPacket, udp: Bool) throws -> Data {
        guard validates(response: response) else { throw CoreError.resolutionFailed }
        guard udp && response.data.count > udpLimit else { return response.data }
        // Correctly ask the client to retry over TCP instead of sending an oversized UDP answer.
        var truncated = Array(data.prefix(questionEnd))
        let newFlags = (response.flags | 0x0200) & ~UInt16(0x0020)
        truncated[2] = UInt8(newFlags >> 8); truncated[3] = UInt8(newFlags & 255)
        for index in 6..<12 { truncated[index] = 0 }
        return Data(truncated)
    }
    public func failureReply() -> Data {
        var result = Array(data.prefix(questionEnd))
        let value = UInt16(0x8082) | (flags & 0x0100)
        result[2] = UInt8(value >> 8); result[3] = UInt8(value & 255)
        for index in 6..<12 { result[index] = 0 }
        return Data(result)
    }
}

public struct DNSRoutingPolicy: Sendable {
    public let originalResolverDomains: [String]
    public init(originalResolverDomains: [String] = []) {
        self.originalResolverDomains = Array(Set(originalResolverDomains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0.utf8.count <= 253 })).sorted().prefix(128).map { $0 }
    }
    public func usesOriginalResolver(_ name: String) -> Bool {
        let name = name.lowercased()
        if !name.contains(".") { return true }
        return (["local", "localhost", "home.arpa", "in-addr.arpa", "ip6.arpa"] + originalResolverDomains).contains {
            name == $0 || name.hasSuffix("." + $0)
        }
    }
}

/// Original-resolver routes are intentional LAN/split-DNS/interface exceptions, never a fallback
/// after encrypted-DNS failure. Neither direction guesses a domain from an IP or rewrites RR data.
public final class DNSQueryRouter {
    public typealias Exchange = (Data, @escaping (Result<Data, CoreError>) -> Void) -> ResolutionTicket
    private let policy: DNSRoutingPolicy
    private let encrypted: Exchange
    private let original: Exchange
    public init(policy: DNSRoutingPolicy, encrypted: @escaping Exchange, original: @escaping Exchange) {
        self.policy = policy; self.encrypted = encrypted; self.original = original
    }
    @discardableResult
    public func exchange(_ data: Data, preserveOriginalInterface: Bool = false, udp: Bool,
                         completion: @escaping (Result<Data, CoreError>) -> Void) -> ResolutionTicket {
        let ticket = ResolutionTicket()
        guard let query = try? DNSPacket(data, response: false) else { completion(.failure(.invalidRequest)); return ticket }
        let operation = preserveOriginalInterface || policy.usesOriginalResolver(query.name) ? original : encrypted
        let child = operation(data) { result in
            guard !ticket.isCancelled else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let bytes):
                do { completion(.success(try query.reply(DNSPacket(bytes, response: true), udp: udp))) }
                catch { completion(.failure(.resolutionFailed)) }
            }
        }
        ticket.onCancel { child.cancel() }
        return ticket
    }
}

/// Two-byte length framing for TCP DNS. The caller applies one-exchange-at-a-time backpressure.
public struct DNSStreamFramer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws {
        guard data.count <= 98_306 - buffer.count else { throw CoreError.capacity }
        buffer.append(data)
    }
    public mutating func next() throws -> Data? {
        guard buffer.count >= 2 else { return nil }
        let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex+1])
        guard (12...DNSPacket.maximumSize).contains(length) else { throw CoreError.invalidRequest }
        guard buffer.count >= length + 2 else { return nil }
        let message = Data(buffer.dropFirst(2).prefix(length)); buffer.removeFirst(length+2)
        return message
    }
    public var isEmpty: Bool { buffer.isEmpty }
    public static func frame(_ message: Data) throws -> Data {
        guard (12...DNSPacket.maximumSize).contains(message.count) else { throw CoreError.capacity }
        var result = Data([UInt8(message.count >> 8), UInt8(message.count & 255)]); result.append(message); return result
    }
}
