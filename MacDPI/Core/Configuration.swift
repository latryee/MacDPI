import Foundation

public enum DNSMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, cloudflare
    public var id: String { rawValue }
    public var title: String { self == .system ? "System DNS" : "Cloudflare DNS over HTTPS" }
}

public enum Profile: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard, compatibility, advanced
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var detail: String {
        switch self {
        case .standard: return "Split the first complete ClientHello record inside its visible server name, or at byte 32. Effectiveness depends on the network and traffic routing."
        case .compatibility: return "Forward bytes unchanged. Use to diagnose server compatibility; provides no DPI transformation."
        case .advanced: return "Split the first complete ClientHello record at your chosen payload offset. Effectiveness depends on the network and traffic routing."
        }
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var port: UInt16 = 8080
    public var profile: Profile = .standard
    /// Explicitly opt in: sends proxy destination names to Cloudflare, never changes macOS DNS.
    public var dnsMode: DNSMode = .system
    public var splitOffset: Int = 32
    public var maxConnections: Int = 64
    public var handshakeTimeout: TimeInterval = 10
    public var idleTimeout: TimeInterval = 120
    /// For isolated tests/CLI only. The GUI never exposes this exception.
    public var allowLoopbackForTesting = false
    public var allowedPorts: [UInt16] = [443]
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case port, profile, dnsMode, splitOffset, maxConnections, handshakeTimeout, idleTimeout, allowLoopbackForTesting, allowedPorts
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? port
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? profile
        dnsMode = try c.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? dnsMode
        splitOffset = try c.decodeIfPresent(Int.self, forKey: .splitOffset) ?? splitOffset
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? maxConnections
        handshakeTimeout = try c.decodeIfPresent(Double.self, forKey: .handshakeTimeout) ?? handshakeTimeout
        idleTimeout = try c.decodeIfPresent(Double.self, forKey: .idleTimeout) ?? idleTimeout
        allowLoopbackForTesting = try c.decodeIfPresent(Bool.self, forKey: .allowLoopbackForTesting) ?? allowLoopbackForTesting
        allowedPorts = try c.decodeIfPresent([UInt16].self, forKey: .allowedPorts) ?? allowedPorts
    }

    public func validated() throws -> Configuration {
        guard port >= 1024, (1...256).contains(maxConnections), (1...16_000).contains(splitOffset),
              handshakeTimeout.isFinite, (1...60).contains(handshakeTimeout),
              idleTimeout.isFinite, (5...3600).contains(idleTimeout),
              !allowedPorts.isEmpty, allowedPorts.count <= 32, !allowedPorts.contains(0) else {
            throw CoreError.invalidConfiguration
        }
        return self
    }
}

public enum CoreError: String, Error, LocalizedError, Sendable {
    case invalidConfiguration = "Invalid configuration. Check the port, bounds and timeouts."
    case invalidRequest = "Only a valid HTTP CONNECT request is supported."
    case forbiddenDestination = "Destination is outside the allowed public HTTPS scope."
    case resolutionFailed = "DNS resolution failed. Check the selected resolver."
    case connectionFailed = "The destination connection failed."
    case timedOut = "The connection timed out."
    case capacity = "The connection limit was reached."
    case stopped = "The engine is disabled."
    public var errorDescription: String? { rawValue }
}

public enum EngineState: String, Codable, Sendable { case disabled, starting, enabled, failed }

public struct Snapshot: Codable, Sendable, Equatable {
    public var state: EngineState = .disabled
    public var activeConnections = 0
    public var accepted: UInt64 = 0
    public var rejected: UInt64 = 0
    public var failures: UInt64 = 0
    public var transformed: UInt64 = 0
    public var passedThrough: UInt64 = 0
    public var uploaded: UInt64 = 0
    public var downloaded: UInt64 = 0
    public var lastError: String?
    public init() {}
}

public struct StrategyDescriptor: Sendable {
    public let id: String
    public let description: String
    public let status: String
    public static let available: [StrategyDescriptor] = [
        .init(id: "tls-record-split", description: "Reframe a complete plaintext ClientHello without altering handshake bytes. TCP port 443, TLS 1.2/1.3. Single initial record only; bounded fallback for other traffic.", status: "Implemented; local integrity/TLS tests and a dated limited Discord/Roblox network check pass. No universal or native-game coverage claim."),
        .init(id: "passthrough", description: "Unmodified CONNECT byte stream, with backpressure and half-close.", status: "Implemented; no circumvention claim.")
    ]
}
