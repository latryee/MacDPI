import CryptoKit
import Darwin
import Foundation

// This fixture uses NET_RT_DUMP2 and RTM_GET. It never opens an utun or adds a route.
guard geteuid() != 0 else {
    fputs("The read-only route fixture must run as a normal user.\n", stderr)
    exit(2)
}

private func printFingerprints(_ snapshot: TUNRouteSnapshot) throws {
    let baseline = snapshot.baseline
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func emit<T: Encodable>(_ name: String, _ value: T) throws {
        let digest = SHA256.hash(data: try encoder.encode(value))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        print("\(name) \(hex)")
    }
    try emit("primary-service", baseline.primaryService)
    try emit("physical-defaults", baseline.defaults.sorted {
        ($0.family.rawValue, $0.interfaceIndex, $0.interfaceName, $0.gateway) <
        ($1.family.rawValue, $1.interfaceIndex, $1.interfaceName, $1.gateway)
    })
    try emit("interfaces", snapshot.interfaces.sorted())
    try emit("protected-prefixes", baseline.protectedPrefixes.map(\.description).sorted())
    try emit("dns", baseline.dnsFingerprint)
    try emit("proxies", baseline.proxyFingerprint)
    try emit("service-order", baseline.serviceOrder)
    try emit("network-policy", [baseline.hasConflictingVPN, baseline.hasSystemForwarding])
}

private func reportPrimaryDNS(_ plan: TUNRoutePlan) throws {
    guard let bytes = Data(base64Encoded: plan.baseline.dnsFingerprint),
          let state = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
          let primary = state["State:/Network/Global/DNS"] as? [String: Any],
          let addresses = primary["ServerAddresses"] as? [String], !addresses.isEmpty else {
        print("Primary DNS resolver addresses are unavailable for this read-only check.")
        return
    }
    let unique = Set(addresses)
    let captured = unique.filter { address in plan.routes.contains { $0.destination.contains(address: address) } }
    print("Primary DNS servers covered by the simulated capture plan: \(captured.count) of \(unique.count).")
}

do {
    let backend = DarwinRouteBackend()
    let snapshot = try backend.snapshot(excluding: nil)
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--fingerprint"] {
        try printFingerprints(snapshot)
        exit(0)
    }
    guard arguments.isEmpty else {
        fputs("Use test-tun-route-snapshot.sh [--fingerprint].\n", stderr)
        exit(2)
    }
    print("Kernel snapshot decoded \(snapshot.routes.count) routes across \(snapshot.interfaces.count) interfaces.")
    let families = snapshot.baseline.defaults.map { $0.family.rawValue }.sorted()
    print("Physical defaults: \(families.joined(separator: ", ")). Conflicting VPN: \(snapshot.baseline.hasConflictingVPN). IP forwarding: \(snapshot.baseline.hasSystemForwarding).")
    if !snapshot.baseline.hasConflictingVPN && !snapshot.baseline.hasSystemForwarding && !families.isEmpty {
        guard let unused = (UInt32(32_768)...UInt32(UInt16.max)).first(where: { !snapshot.interfaces.contains($0) }) else {
            throw TUNRouteError.unsuitableNetwork
        }
        let lease = TUNRouteLease(interfaceName: "utun9999", interfaceIndex: unused)
        let model = TUNRouteSnapshot(baseline: snapshot.baseline, interfaces: snapshot.interfaces.union([unused]), routes: snapshot.routes)
        let plan = try TUNRoutePlan.make(snapshot: model, lease: lease)
        try backend.verifyEgress(plan)
        print("Scoped RTM_GET checks passed. The simulated plan contains \(plan.routes.count) capture prefixes.")
        try reportPrimaryDNS(plan)
    }
} catch {
    fputs("Read-only route fixture failed: \(error)\n", stderr)
    exit(1)
}
