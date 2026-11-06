import XCTest
@testable import MacDPICore

final class TUNWireBridgeTests: XCTestCase {
    func testTLSPrefixRoundTripAndOutputBounds() {
        let hello = fixture()
        let sentinel = Data(repeating: 0xA5, count: hello.count + 9)
        var output = sentinel
        func split(profile: Int32, capacity: Int32) -> Int32 {
            hello.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { result in
                    macdpiTLSSplit(input.bindMemory(to: UInt8.self).baseAddress, Int32(input.count), profile, 32,
                                   result.bindMemory(to: UInt8.self).baseAddress, capacity)
                }
            }
        }
        XCTAssertEqual(split(profile: 0, capacity: Int32(output.count)), 0)
        XCTAssertEqual(output, sentinel)
        XCTAssertEqual(split(profile: 1, capacity: Int32(hello.count + 4)), -1)
        XCTAssertEqual(output, sentinel)
        let count = split(profile: 1, capacity: Int32(hello.count + 5))
        XCTAssertEqual(count, Int32(hello.count + 5))
        XCTAssertEqual(deframe(output.prefix(Int(count))), deframe(hello))
        XCTAssertEqual(output.suffix(4), sentinel.suffix(4))
    }

    func testDNSRouteUsesExactSplitDomainAndFailsClosedOnBadPolicy() {
        func route(_ name: String, doh: Int32 = 1, domains: String = "corp.example.\ninternal.example") -> Int32 {
            let query = dnsQuestion(name)
            return query.withUnsafeBytes { input in
                Array(domains.utf8).withUnsafeBufferPointer { names in
                    macdpiDNSRoute(input.bindMemory(to: UInt8.self).baseAddress, Int32(input.count), doh,
                                   names.baseAddress, Int32(names.count))
                }
            }
        }
        XCTAssertEqual(route("printer.corp.example"), 0)
        XCTAssertEqual(route("printer.local"), 0)
        XCTAssertEqual(route("evilcorp.example"), 1)
        XCTAssertEqual(route("public.example", doh: 0), 0)
        XCTAssertEqual(route("public.example", domains: "corp.example\n\ninternal.example"), -1)
        XCTAssertEqual(route("public.example", domains: "corp.example\u{0000}"), -1)
        XCTAssertEqual(macdpiDNSRoute(nil, 12, 1, nil, 0), -1)
    }

    func testDNSFailureDoesNotEmitUnverifiedResponse() throws {
        let query = dnsQuestion("public.example")
        var validResponse = query
        validResponse[2] = 0x81
        validResponse[3] = 0x80
        var mismatch = validResponse
        mismatch[1] ^= 1
        for response in [Data(), mismatch, Data(validResponse.prefix(20)), validResponse] {
            var output = Data(repeating: 0xA5, count: query.count + 4)
            let count = query.withUnsafeBytes { input in
                response.withUnsafeBytes { answer in
                    output.withUnsafeMutableBytes { result in
                        macdpiDNSReply(input.bindMemory(to: UInt8.self).baseAddress, Int32(input.count),
                                       answer.bindMemory(to: UInt8.self).baseAddress, Int32(answer.count), 1, 1,
                                       result.bindMemory(to: UInt8.self).baseAddress, Int32(result.count))
                    }
                }
            }
            XCTAssertEqual(count, Int32(query.count))
            let packet = try DNSPacket(output.prefix(Int(count)), response: true)
            XCTAssertEqual(packet.flags & 0x000F, response == validResponse ? 0 : 2)
            XCTAssertEqual(packet.identifier, 0x1234)
            XCTAssertEqual(output.suffix(4), Data(repeating: 0xA5, count: 4))
        }
    }

    func testEncryptedDNSRejectsPrivateAddressesAndServiceHints() throws {
        let publicIPv4: [UInt8] = [1, 1, 1, 1]
        let privateIPv4: [UInt8] = [192, 168, 0, 1]
        let publicIPv6: [UInt8] = [0x26, 0x06, 0x47, 0] + Array(repeating: 0, count: 11) + [1]
        let privateIPv6: [UInt8] = [0xfd] + Array(repeating: 0, count: 14) + [1]
        func hint(_ key: UInt8, _ addresses: [UInt8]) -> [UInt8] {
            [0, 1, 0, 0, key, 0, UInt8(addresses.count)] + addresses
        }
        let records: [(UInt8, [UInt8], [UInt8])] = [
            (1, publicIPv4, privateIPv4),
            (28, publicIPv6, privateIPv6),
            (64, hint(6, publicIPv6), hint(6, privateIPv6)),
            (65, hint(4, publicIPv4), hint(4, publicIPv4 + privateIPv4)),
            (65, hint(4, publicIPv4), [0, 1, 0, 0, 4, 0, 4, 1]), // incomplete hint
        ]
        for (kind, allowed, blocked) in records {
            let query = dnsQuestion("public.example", type: kind)
            func response(_ address: [UInt8]) -> Data {
                var message = query
                message[2] = 0x81; message[3] = 0x80; message[7] = 1
                message.append(contentsOf: [0xc0, 12, 0, kind, 0, 1, 0, 0, 0, 60, 0, UInt8(address.count)])
                message.append(contentsOf: address)
                return message
            }
            func reply(_ answer: Data, encrypted: Int32) -> Data {
                var output = Data(repeating: 0, count: 512)
                let length = query.withUnsafeBytes { input in
                    answer.withUnsafeBytes { upstream in
                        output.withUnsafeMutableBytes { result in
                            macdpiDNSReply(input.bindMemory(to: UInt8.self).baseAddress, Int32(input.count),
                                           upstream.bindMemory(to: UInt8.self).baseAddress, Int32(upstream.count),
                                           1, encrypted, result.bindMemory(to: UInt8.self).baseAddress, Int32(result.count))
                        }
                    }
                }
                return output.prefix(max(0, Int(length)))
            }
            XCTAssertEqual(reply(response(allowed), encrypted: 1), response(allowed))
            XCTAssertEqual(reply(response(blocked), encrypted: 0), response(blocked))
            let rejection = try DNSPacket(reply(response(blocked), encrypted: 1), response: true)
            XCTAssertEqual(rejection.flags & 0x000f, 2)
            XCTAssertEqual(rejection.data.count, query.count)
        }
    }

    private func dnsQuestion(_ domain: String, type: UInt8 = 28) -> Data {
        var data = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(contentsOf: [0, 0, type, 0, 1])
        return data
    }
}
