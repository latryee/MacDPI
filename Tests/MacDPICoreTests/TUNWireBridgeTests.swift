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
                                       answer.bindMemory(to: UInt8.self).baseAddress, Int32(answer.count), 1,
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

    private func dnsQuestion(_ domain: String) -> Data {
        var data = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(contentsOf: [0, 0, 28, 0, 1])
        return data
    }
}
