import Darwin
import Foundation

// This fixture uses NET_RT_DUMP2 and RTM_GET. It never opens an utun or adds a route.
guard geteuid() != 0 else {
    fputs("The read-only route fixture must run as a normal user.\n", stderr)
    exit(2)
}

do {
    let backend = DarwinRouteBackend()
    let snapshot = try backend.snapshot(excluding: nil)
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
    }
} catch {
    fputs("Read-only route fixture failed: \(error)\n", stderr)
    exit(1)
}
