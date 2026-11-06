import Darwin
import Foundation
import SystemConfiguration

/// The broker holds the only privileged reference. All route writes target that exact interface.
final class DarwinRouteBackend: TUNRouteBackend {
    private var fd: Int32 = -1
    private var lease: TUNRouteLease?
    private let store = SCDynamicStoreCreate(nil, "MacDPI TUN" as CFString, nil, nil)
    /// Ask the worker to close its duplicated descriptor before dropping the broker's copy.
    var beforeRelease: (() -> Void)?

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func open(baseline: TUNRouteSnapshot) throws -> (TUNRouteLease, Int32) {
        guard fd < 0, lease == nil else { throw TUNRouteError.alreadyRunning }
        let current = try snapshot(excluding: nil)
        guard baseline.baseline == current.baseline else { throw TUNRouteError.baselineChanged }
        guard !current.baseline.hasSystemForwarding else { throw TUNRouteError.systemForwardingEnabled }
        guard !baseline.baseline.hasConflictingVPN, !baseline.baseline.defaults.isEmpty else {
            throw TUNRouteError.unsuitableNetwork
        }
        // These addresses are private to the new virtual interface. Refuse if a local
        // interface or policy already uses either virtual range.
        let localRanges = ["198.18.0.0/30", "fd75:554e:4d44:5049::/64"].compactMap(TUNCIDR.init)
        guard !current.routes.contains(where: { route in
            route.destination.prefixLength > 0 && localRanges.contains {
                $0.contains(route.destination) || route.destination.contains($0)
            }
        }), try !hasAddress(in: localRanges) else { throw TUNRouteError.routeConflict }
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let ipv6 = baseline.baseline.defaults.contains { $0.family == .ipv6 }
        try check(mdpi_tun_open(ipv6 ? 1 : 0, &name, name.count, &fd))
        let result = TUNRouteLease(interfaceName: String(cString: name), interfaceIndex: if_nametoindex(name))
        guard result.isValid else { Darwin.close(fd); fd = -1; throw TUNRouteError.invalidLease }
        lease = result
        return (result, fd)
    }

    func owns(_ candidate: TUNRouteLease) -> Bool { fd >= 0 && lease == candidate }

    func snapshot(excluding candidate: TUNRouteLease?) throws -> TUNRouteSnapshot {
        guard let store else { throw TUNRouteError.unsuitableNetwork }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS",
                    "State:/Network/Global/Proxies", "Setup:/Network/Global/IPv4"]
        let patterns = ["^State:/Network/Service/[^/]+/DNS$", "^State:/Network/Service/[^/]+/Proxies$"]
        guard let state = SCDynamicStoreCopyMultiple(store, keys as CFArray, patterns as CFArray) as? [String: Any] else {
            throw TUNRouteError.unsuitableNetwork
        }
        let primary4 = state[keys[0]] as? [String: Any] ?? [:]
        let primary6 = state[keys[1]] as? [String: Any] ?? [:]
        let services = Set([primary4["PrimaryService"] as? String, primary6["PrimaryService"] as? String].compactMap { $0 })
        let serviceOrder = (state[keys[4]] as? [String: Any])?["ServiceOrder"] as? [String] ?? []
        let physicalRoutes = try readRoutes()
        let interfaces = try readInterfaces()
        var observed = Set<TUNObservedRoute>(), protected = Set<TUNCIDR>(), defaults = Set<TUNPhysicalRoute>()
        var conflict = services.count > 1
        for entry in physicalRoutes {
            guard let family = family(entry), let prefix = prefix(entry, family: family) else {
                throw TUNRouteError.unsuitableNetwork
            }
            let index = UInt32(entry.interfaceIndex)
            let scoped = (entry.flags & UInt32(RTF_IFSCOPE)) != 0
            let linkIndex = entry.linkGatewayIndex == 0 ? nil : UInt32(entry.linkGatewayIndex)
            observed.insert(TUNObservedRoute(destination: prefix, interfaceIndex: index,
                                             linkGatewayIndex: linkIndex, scopeIndex: scoped ? index : 0))
            if let candidate, index == candidate.interfaceIndex || linkIndex == candidate.interfaceIndex { continue }
            // Kernel neighbor and cloned host routes can appear during a connection and are
            // not user routing policy. Never use them to establish a physical default.
            if entry.flags & UInt32(RTF_LLINFO | RTF_WASCLONED) != 0 { continue }
            guard let name = interfaces[index] else { throw TUNRouteError.unsuitableNetwork }
            if ["utun", "tun", "tap", "ppp", "ipsec", "gif"].contains(where: name.hasPrefix) {
                // macOS creates idle utuns with scoped IPv6 defaults to fe80:: and link-local /
                // multicast entries. Consider other routes conflicts, including split VPNs
                // carrying only private IPv4 or unique-local IPv6 traffic.
                let idleIPv6Default = family == .ipv6 && scoped && prefix.prefixLength == 0 &&
                    gateway(entry, family: family) == "fe80::"
                let linkLocalOrMulticast = Self.backgroundPrefixes.contains { $0.contains(prefix) }
                if !idleIPv6Default && !linkLocalOrMulticast { conflict = true }
            }
            if prefix.prefixLength > 0 {
                protected.insert(prefix)
            } else if !scoped {
                let primary = family == .ipv4 ? primary4 : primary6
                guard primary["PrimaryInterface"] as? String == name, let gateway = gateway(entry, family: family) else {
                    // Still return observed routes for recovery when the host has no usable path.
                    conflict = true
                    continue
                }
                defaults.insert(TUNPhysicalRoute(family: family, interfaceIndex: index, interfaceName: name, gateway: gateway))
            }
        }
        let baseline = TUNRouteBaseline(primaryService: services.count == 1 ? services.first! : "", defaults: defaults,
                                        protectedPrefixes: protected, dnsFingerprint: try fingerprint(state, suffix: "/DNS"),
                                        proxyFingerprint: try fingerprint(state, suffix: "/Proxies"), serviceOrder: serviceOrder,
                                        hasConflictingVPN: conflict, hasSystemForwarding: try systemForwardsIP())
        return TUNRouteSnapshot(baseline: baseline, interfaces: Set(interfaces.keys), routes: observed)
    }

    func insert(_ route: TUNObservedRoute, lease candidate: TUNRouteLease) throws {
        guard owns(candidate), route.interfaceIndex == candidate.interfaceIndex,
              route.linkGatewayIndex == candidate.interfaceIndex, route.scopeIndex == 0,
              route.destination.prefixLength > 1 else { throw TUNRouteError.invalidLease }
        var request = nativeRoute(route.destination, index: route.interfaceIndex)
        try check(mdpi_tun_add_route(fd, &request))
    }

    func verifyEgress(_ plan: TUNRoutePlan) throws {
        for physical in plan.baseline.defaults {
            guard let route = plan.routes.first(where: { $0.destination.family == physical.family }) else { continue }
            var request = nativeRoute(route.destination, index: physical.interfaceIndex)
            var observedIndex: UInt16 = 0
            try check(mdpi_route_scoped_interface(&request, &observedIndex))
            guard observedIndex == physical.interfaceIndex else { throw TUNRouteError.unsuitableNetwork }
        }
    }

    func release(_ candidate: TUNRouteLease) throws {
        guard owns(candidate) else { throw TUNRouteError.invalidLease }
        let notifyWorker = beforeRelease
        beforeRelease = nil
        notifyWorker?()
        // On Darwin close must not be retried after EINTR. Detach is asynchronous.
        let oldFD = fd
        fd = -1; lease = nil
        Darwin.close(oldFD)
        for _ in 0..<30 {
            if !((try? readInterfaces().keys.contains(candidate.interfaceIndex)) ?? true) { return }
            usleep(50_000)
        }
        throw TUNRouteError.restorationUnverified
    }

    private func readRoutes() throws -> [MDPIRoute] {
        var entries = [MDPIRoute](repeating: MDPIRoute(), count: 8192)
        var count = 0
        try check(mdpi_route_snapshot(&entries, entries.count, &count))
        return Array(entries.prefix(count))
    }

    private func readInterfaces() throws -> [UInt32: String] {
        guard let list = if_nameindex() else { throw POSIXError(.EIO) }
        defer { if_freenameindex(list) }
        var result = [UInt32: String]()
        for position in 0..<8192 {
            let entry = list.advanced(by: position).pointee
            guard let name = entry.if_name, entry.if_index != 0 else { return result }
            result[entry.if_index] = String(cString: name)
        }
        throw POSIXError(.EOVERFLOW)
    }

    private static let backgroundPrefixes = ["169.254.0.0/16", "fe80::/10", "ff00::/8"].compactMap(TUNCIDR.init)

    private func systemForwardsIP() throws -> Bool {
        for name in ["net.inet.ip.forwarding", "net.inet6.ip6.forwarding"] {
            var enabled: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &enabled, &size, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard size == MemoryLayout<Int32>.size else { throw TUNRouteError.unsuitableNetwork }
            if enabled != 0 { return true }
        }
        return false
    }

    private func hasAddress(in ranges: [TUNCIDR]) throws -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { if let list { freeifaddrs(list) } }
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr else { continue }
            let host: TUNCIDR?
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                host = withUnsafeBytes(of: &ip) { TUNCIDR(family: .ipv4, bytes: Array($0), prefixLength: 32) }
            case AF_INET6:
                var ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                host = withUnsafeBytes(of: &ip) { TUNCIDR(family: .ipv6, bytes: Array($0), prefixLength: 128) }
            default:
                continue
            }
            if let host, ranges.contains(where: { $0.contains(host) }) { return true }
        }
        return false
    }

    private func family(_ route: MDPIRoute) -> TUNAddressFamily? {
        switch route.family { case 4: return .ipv4; case 6: return .ipv6; default: return nil }
    }

    private func prefix(_ entry: MDPIRoute, family: TUNAddressFamily) -> TUNCIDR? {
        withUnsafeBytes(of: entry.network) {
            TUNCIDR(family: family, bytes: Array($0.prefix(family == .ipv4 ? 4 : 16)), prefixLength: Int(entry.prefix))
        }
    }

    private func gateway(_ entry: MDPIRoute, family: TUNAddressFamily) -> String? {
        guard entry.gatewayFamily == (family == .ipv4 ? 4 : 6) else { return nil }
        var bytes = withUnsafeBytes(of: entry.gateway) { Array($0.prefix(family == .ipv4 ? 4 : 16)) }
        // XNU may embed the link-local IPv6 scope in bytes 2–3.
        if family == .ipv6, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { bytes[2] = 0; bytes[3] = 0 }
        return TUNCIDR(family: family, bytes: bytes, prefixLength: bytes.count * 8)?.address
    }

    private func nativeRoute(_ prefix: TUNCIDR, index: UInt32) -> MDPIRoute {
        var result = MDPIRoute()
        result.family = prefix.family == .ipv4 ? 4 : 6
        result.prefix = UInt8(prefix.prefixLength)
        result.interfaceIndex = UInt16(index)
        withUnsafeMutableBytes(of: &result.network) { $0.copyBytes(from: prefix.bytes) }
        return result
    }

    private func fingerprint(_ state: [String: Any], suffix: String) throws -> String {
        let items = state.filter { $0.key.hasSuffix(suffix) }
        let data = try PropertyListSerialization.data(fromPropertyList: items, format: .xml, options: 0)
        guard data.count <= 262_144 else { throw TUNRouteError.policyTooLarge }
        return data.base64EncodedString()
    }

    private func check(_ code: Int32) throws {
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
