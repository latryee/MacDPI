import Foundation

private func wireInput(_ pointer: UnsafePointer<UInt8>?, length: Int32, maximum: Int) -> Data? {
    guard let pointer, length > 0, Int(length) <= maximum else { return nil }
    return Data(bytes: pointer, count: Int(length))
}

private func writeWireOutput(_ bytes: Data, to pointer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
    guard let pointer, bytes.count <= Int(capacity) else { return -1 }
    bytes.copyBytes(to: pointer, count: bytes.count)
    return Int32(bytes.count)
}

/// C ABI used by the unprivileged packet engine. The stream layer buffers the
/// first record; Swift only inspects a bounded prefix and borrows no storage.
@_cdecl("macdpi_tls_split")
public func macdpiTLSSplit(_ input: UnsafePointer<UInt8>?, _ inputLength: Int32,
                          _ profileCode: Int32, _ offset: Int32,
                          _ output: UnsafeMutablePointer<UInt8>?, _ outputCapacity: Int32) -> Int32 {
    guard let bytes = wireInput(input, length: inputLength, maximum: TLSProcessor.maximumBuffered) else { return -1 }
    let profile: Profile
    switch profileCode {
    case 0: return 0
    case 1: profile = .standard
    case 2:
        guard (1...16_000).contains(offset) else { return -1 }
        profile = .advanced
    default: return -1
    }
    let result = TLSProcessor.transform(bytes, profile: profile, offset: Int(offset))
    guard result.transformed else { return 0 }
    return writeWireOutput(result.data, to: output, capacity: outputCapacity)
}

/// Domain policy is snapshotted by the session owner. Invalid configuration
/// fails closed rather than losing split-DNS exclusions during conversion.
@_cdecl("macdpi_dns_route")
public func macdpiDNSRoute(_ query: UnsafePointer<UInt8>?, _ queryLength: Int32, _ doh: Int32,
                          _ domains: UnsafePointer<UInt8>?, _ domainsLength: Int32) -> Int32 {
    guard doh == 0 || doh == 1,
          let bytes = wireInput(query, length: queryLength, maximum: DNSPacket.maximumSize),
          let packet = try? DNSPacket(bytes, response: false) else { return -1 }
    let names: [String]
    if domainsLength == 0 {
        names = []
    } else {
        guard let data = wireInput(domains, length: domainsLength, maximum: 128 * 255 - 1),
              let string = String(data: data, encoding: .ascii) else { return -1 }
        let entries = string.split(separator: "\n", omittingEmptySubsequences: false)
        guard entries.count <= 128, entries.allSatisfy(validTUNSplitDomain) else { return -1 }
        names = entries.map(String.init)
    }
    return doh == 0 || DNSRoutingPolicy(originalResolverDomains: names).usesOriginalResolver(packet.name) ? 0 : 1
}

func validTUNSplitDomain(_ entry: Substring) -> Bool {
    var name = entry
    if name.last == "." { name = name.dropLast() }
    guard (1...253).contains(name.utf8.count) else { return false }
    return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        (1...63).contains(label.utf8.count) && label.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }
    }
}

/// Reuses the DNS engine's exact question matching and EDNS UDP truncation.
/// A failed encrypted lookup yields SERVFAIL and never retries another server.
@_cdecl("macdpi_dns_reply")
public func macdpiDNSReply(_ query: UnsafePointer<UInt8>?, _ queryLength: Int32,
                          _ response: UnsafePointer<UInt8>?, _ responseLength: Int32, _ udp: Int32, _ encrypted: Int32,
                          _ output: UnsafeMutablePointer<UInt8>?, _ outputCapacity: Int32) -> Int32 {
    guard (0...1).contains(udp), (0...1).contains(encrypted), responseLength >= 0,
          responseLength == 0 || response != nil,
          let bytes = wireInput(query, length: queryLength, maximum: DNSPacket.maximumSize),
          let packet = try? DNSPacket(bytes, response: false) else { return -1 }
    let answer = wireInput(response, length: responseLength, maximum: DNSPacket.maximumSize)
        .flatMap { try? packet.reply(DNSPacket($0, response: true, requirePublicAddresses: encrypted == 1), udp: udp == 1) }
    return writeWireOutput(answer ?? packet.failureReply(), to: output, capacity: outputCapacity)
}
