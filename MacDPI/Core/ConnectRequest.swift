import Foundation
import Network

public struct ConnectRequest: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let headerLength: Int
    public static let maximumHeader = 8192

    /// nil means incomplete. No URL, credentials, path, zone ID, or request body is accepted.
    public static func parse(_ data: Data) throws -> ConnectRequest? {
        guard let end = data.range(of: Data([13, 10, 13, 10]))?.upperBound else {
            if data.count >= maximumHeader { throw CoreError.invalidRequest }
            return nil
        }
        let count = data.distance(from: data.startIndex, to: end)
        guard count <= maximumHeader,
              let text = String(data: data.prefix(count), encoding: .ascii),
              !text.utf8.contains(where: { $0 < 32 && $0 != 13 && $0 != 10 }) else { throw CoreError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        guard !text.replacingOccurrences(of: "\r\n", with: "").contains(where: { $0 == "\r" || $0 == "\n" }) else { throw CoreError.invalidRequest }
        let words = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[0] == "CONNECT", ["HTTP/1.0", "HTTP/1.1"].contains(words[2]) else { throw CoreError.invalidRequest }
        let authority = String(words[1])
        let host: String
        let portText: String
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]"), authority[authority.index(after: close)...].hasPrefix(":" ) else { throw CoreError.invalidRequest }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            portText = String(authority[authority.index(close, offsetBy: 2)...])
            guard IPv6Address(host) != nil, !host.contains("%") else { throw CoreError.invalidRequest }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CoreError.invalidRequest }
            host = String(parts[0]); portText = String(parts[1])
            guard !host.isEmpty, host.utf8.count <= 253,
                  host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { throw CoreError.invalidRequest }
        }
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(portText), port > 0 else { throw CoreError.invalidRequest }
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw CoreError.invalidRequest }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !["content-length", "transfer-encoding", "proxy-authorization"].contains(name) else { throw CoreError.invalidRequest }
        }
        return .init(host: host, port: port, headerLength: count)
    }
}
