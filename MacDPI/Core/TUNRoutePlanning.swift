import Darwin
import Foundation

public enum TUNAddressFamily: String, CaseIterable, Codable, Sendable {
    case ipv4, ipv6

    fileprivate var byteCount: Int { self == .ipv4 ? 4 : 16 }
    fileprivate var socketFamily: Int32 { self == .ipv4 ? AF_INET : AF_INET6 }
}

/// A normalized numeric network. Address spellings and host bits are never used as route keys.
public struct TUNCIDR: Hashable, Codable, Sendable, CustomStringConvertible {
    public let family: TUNAddressFamily
    public let bytes: [UInt8]
    public let prefixLength: Int

    public init?(_ value: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard value.utf8.count <= 64, parts.count == 2, let length = Int(parts[1]),
              !parts[0].contains("\0"), !parts[0].contains("%") else { return nil }
        let address = String(parts[0])
        for family in TUNAddressFamily.allCases {
            var bytes = [UInt8](repeating: 0, count: family.byteCount)
            let parsed = bytes.withUnsafeMutableBytes { buffer in
                address.withCString { inet_pton(family.socketFamily, $0, buffer.baseAddress) }
            }
            if parsed == 1 {
                self.init(family: family, bytes: bytes, prefixLength: length)
                return
            }
        }
        return nil
    }

    public init?(family: TUNAddressFamily, bytes: [UInt8], prefixLength: Int) {
        guard bytes.count == family.byteCount, (0...bytes.count * 8).contains(prefixLength) else { return nil }
        self.family = family
        self.prefixLength = prefixLength
        self.bytes = bytes.enumerated().map { index, byte in
            let bits = min(8, max(0, prefixLength - index * 8))
            return byte & (UInt8.max << (8 - bits))
        }
    }

    public var address: String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { buffer in
            _ = inet_ntop(family.socketFamily, buffer.baseAddress, &output, socklen_t(INET6_ADDRSTRLEN))
        }
        return String(cString: output)
    }

    public var description: String { "\(address)/\(prefixLength)" }

    public func contains(_ other: Self) -> Bool {
        guard family == other.family, prefixLength <= other.prefixLength else { return false }
        let fullBytes = prefixLength / 8
        guard bytes.prefix(fullBytes).elementsEqual(other.bytes.prefix(fullBytes)) else { return false }
        let rest = prefixLength % 8
        return rest == 0 || (bytes[fullBytes] ^ other.bytes[fullBytes]) >> (8 - rest) == 0
    }

    public func contains(address: String) -> Bool {
        guard let host = Self("\(address)/\(family.byteCount * 8)") else { return false }
        return contains(host)
    }

    fileprivate func excluding(_ other: Self) -> [Self] {
        if other.contains(self) { return [] }
        guard contains(other) else { return [self] }
        var result: [Self] = []
        var prefix = self
        while prefix.prefixLength < other.prefixLength {
            let bit = prefix.prefixLength
            var high = prefix.bytes
            high[bit / 8] |= 1 << (7 - bit % 8)
            let children = [prefix.bytes, high].compactMap { Self(family: family, bytes: $0, prefixLength: bit + 1) }
            guard children.count == 2 else { return [] }
            if children[0].contains(other) {
                result.append(children[1]); prefix = children[0]
            } else {
                result.append(children[0]); prefix = children[1]
            }
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let prefix = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP prefix")
        }
        self = prefix
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct TUNPhysicalRoute: Codable, Hashable, Sendable {
    public let family: TUNAddressFamily
    public let interfaceIndex: UInt32
    public let interfaceName: String
    public let gateway: String

    public init(family: TUNAddressFamily, interfaceIndex: UInt32, interfaceName: String, gateway: String) {
        self.family = family
        self.interfaceIndex = interfaceIndex
        self.interfaceName = interfaceName
        self.gateway = gateway
    }

    fileprivate var isValid: Bool {
        guard interfaceIndex > 0, interfaceIndex <= UInt16.max, interfaceName.utf8.count < IFNAMSIZ,
              !interfaceName.isEmpty, interfaceName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              !["utun", "tun", "tap", "ppp", "ipsec", "gif", "lo"].contains(where: interfaceName.hasPrefix) else { return false }
        // Darwin presents a link-local IPv6 gateway with an optional interface scope suffix.
        let parts = gateway.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && family == .ipv6 && parts[1] == interfaceName),
              let address = TUNCIDR("\(parts[0])/\(family.byteCount * 8)"), address.family == family else { return false }
        return address.bytes.contains { $0 != 0 }
    }
}

/// The backend excludes the currently held tunnel from this view. Changes to service identity,
/// defaults, protected routes, DNS/proxies, or service order are reasons to end the tunnel lease.
/// The fingerprints need only encode settings used by the owner, and stay out of the journal.
public struct TUNRouteBaseline: Equatable, Sendable {
    public let primaryService: String
    public let defaults: Set<TUNPhysicalRoute>
    public let protectedPrefixes: Set<TUNCIDR>
    public let dnsFingerprint: String
    public let proxyFingerprint: String
    public let serviceOrder: [String]
    public let hasConflictingVPN: Bool
    public let hasSystemForwarding: Bool

    public init(primaryService: String, defaults: Set<TUNPhysicalRoute>, protectedPrefixes: Set<TUNCIDR>,
                dnsFingerprint: String, proxyFingerprint: String, serviceOrder: [String], hasConflictingVPN: Bool,
                hasSystemForwarding: Bool = false) {
        self.primaryService = primaryService
        self.defaults = defaults
        self.protectedPrefixes = protectedPrefixes
        self.dnsFingerprint = dnsFingerprint
        self.proxyFingerprint = proxyFingerprint
        self.serviceOrder = serviceOrder
        self.hasConflictingVPN = hasConflictingVPN
        self.hasSystemForwarding = hasSystemForwarding
    }
}

/// An in-process capability held by the backend identifies the opened descriptor. A decoded lease
/// only describes that capability and cannot be used to acquire a new interface with the same name.
public struct TUNRouteLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let interfaceName: String
    public let interfaceIndex: UInt32

    public init(id: UUID = UUID(), interfaceName: String, interfaceIndex: UInt32) {
        self.id = id
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
    }

    var isValid: Bool {
        let unit = interfaceName.dropFirst(4)
        return interfaceIndex > 0 && interfaceIndex <= UInt16.max && interfaceName.hasPrefix("utun") &&
            (1...5).contains(unit.count) && unit.utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// A route fingerprint from the kernel table, or the exact interface-bound route to request.
/// A link-layer gateway is represented by its interface index. IP gateways use nil here.
public struct TUNObservedRoute: Codable, Hashable, Sendable {
    public let destination: TUNCIDR
    public let interfaceIndex: UInt32
    public let linkGatewayIndex: UInt32?
    public let scopeIndex: UInt32

    public init(destination: TUNCIDR, interfaceIndex: UInt32, linkGatewayIndex: UInt32?, scopeIndex: UInt32) {
        self.destination = destination
        self.interfaceIndex = interfaceIndex
        self.linkGatewayIndex = linkGatewayIndex
        self.scopeIndex = scopeIndex
    }

    func isAssociated(with lease: TUNRouteLease) -> Bool {
        interfaceIndex == lease.interfaceIndex || linkGatewayIndex == lease.interfaceIndex || scopeIndex == lease.interfaceIndex
    }
}

public struct TUNRouteSnapshot: Equatable, Sendable {
    public let baseline: TUNRouteBaseline
    public let interfaces: Set<UInt32>
    public let routes: Set<TUNObservedRoute>

    public init(baseline: TUNRouteBaseline, interfaces: Set<UInt32>, routes: Set<TUNObservedRoute>) {
        self.baseline = baseline
        self.interfaces = interfaces
        self.routes = routes
    }
}

public enum TUNRouteError: Error, Equatable, Sendable {
    case conflictingVPN, systemForwardingEnabled, unsuitableNetwork, invalidLease, policyTooLarge, noEligibleRoutes
    case alreadyRunning, journalRequiresRecovery, baselineChanged, routeConflict, routeNotInstalled
    case engineNotReady, restorationUnverified
}

public struct TUNRoutePlan: Equatable, Sendable {
    public let baseline: TUNRouteBaseline
    public let lease: TUNRouteLease
    public let routes: [TUNObservedRoute]

    public static let maximumRoutes = 512
    public static let maximumProtectedPrefixes = 256

    // Conservative public coverage. Never install a /0 or either /1 half of a default route.
    // The safe prefix cover preserves local, special-use, multicast and documentation ranges.
    private static let roots = ["0.0.0.0/0", "2000::/3"].compactMap(TUNCIDR.init)
    private static let excluded = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/16", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
        "203.0.113.0/24", "224.0.0.0/3", "2001::/32", "2001:db8::/32", "2002::/16", "3fff::/20"].compactMap(TUNCIDR.init)

    public static func make(snapshot: TUNRouteSnapshot, lease: TUNRouteLease) throws -> Self {
        guard lease.isValid, snapshot.interfaces.contains(lease.interfaceIndex) else { throw TUNRouteError.invalidLease }
        let baseline = snapshot.baseline
        guard !baseline.hasConflictingVPN else { throw TUNRouteError.conflictingVPN }
        guard !baseline.hasSystemForwarding else { throw TUNRouteError.systemForwardingEnabled }
        let families = Set(baseline.defaults.map(\.family))
        let interfaces = Set(baseline.defaults.map(\.interfaceIndex))
        guard !baseline.primaryService.isEmpty, families.count == baseline.defaults.count,
              interfaces.count == 1, !interfaces.contains(lease.interfaceIndex),
              baseline.defaults.allSatisfy({ $0.isValid && snapshot.interfaces.contains($0.interfaceIndex) }) else {
            throw TUNRouteError.unsuitableNetwork
        }
        guard baseline.protectedPrefixes.count <= maximumProtectedPrefixes else { throw TUNRouteError.policyTooLarge }
        var candidates = roots.filter { families.contains($0.family) }
        let protected = baseline.protectedPrefixes.sorted(by: prefixOrder)
        for exclusion in excluded + protected {
            candidates = candidates.flatMap { $0.excluding(exclusion) }
            guard candidates.count <= maximumRoutes else { throw TUNRouteError.policyTooLarge }
        }
        guard !candidates.isEmpty else { throw TUNRouteError.noEligibleRoutes }
        // Existing more-specific routes retain their precedence. If the baseline failed to mark
        // an equal or broader non-default route as protected, refuse to shadow it.
        let occupied = Set(snapshot.routes.lazy.filter { $0.scopeIndex == 0 && $0.destination.prefixLength > 0 }.map(\.destination))
        guard occupied.count <= 8_192 else { throw TUNRouteError.policyTooLarge }
        guard candidates.allSatisfy({ candidate in
            !(1...candidate.prefixLength).contains { length in
                guard let ancestor = TUNCIDR(family: candidate.family, bytes: candidate.bytes, prefixLength: length) else { return true }
                return occupied.contains(ancestor)
            }
        }) else { throw TUNRouteError.routeConflict }
        let routes = candidates.sorted(by: prefixOrder).map { destination in
            TUNObservedRoute(destination: destination, interfaceIndex: lease.interfaceIndex,
                             linkGatewayIndex: lease.interfaceIndex, scopeIndex: 0)
        }
        return Self(baseline: baseline, lease: lease, routes: routes)
    }

    private static func prefixOrder(_ lhs: TUNCIDR, _ rhs: TUNCIDR) -> Bool {
        if lhs.family != rhs.family { return lhs.family == .ipv4 }
        if lhs.bytes != rhs.bytes { return lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
        return lhs.prefixLength < rhs.prefixLength
    }
}
