import Darwin
import Foundation
import XCTest
@testable import MacDPICore

final class TUNRouteTests: XCTestCase {
    func testCIDRCanonicalizationAndContainment() throws {
        let ipv4 = try XCTUnwrap(TUNCIDR("8.8.8.42/24"))
        XCTAssertEqual(ipv4.description, "8.8.8.0/24")
        XCTAssertTrue(ipv4.contains(address: "8.8.8.255"))
        XCTAssertFalse(ipv4.contains(address: "8.8.9.0"))
        XCTAssertFalse(ipv4.contains(address: "::ffff:8.8.8.8"))
        let ipv6 = try XCTUnwrap(TUNCIDR("2606:4700:abcd::1/37"))
        XCTAssertTrue(ipv6.contains(address: "2606:4700:afff::1"))
        XCTAssertFalse(ipv6.contains(address: "2606:4700:b000::1"))
        XCTAssertEqual(try JSONDecoder().decode(TUNCIDR.self, from: JSONEncoder().encode(ipv6)), ipv6)
        for invalid in ["bad/16", "8.8.8.8/-1", "8.8.8.8/33", "::1/129", "::1%en0/128", "1.1.1.1\0suffix/32"] {
            XCTAssertNil(TUNCIDR(invalid))
        }
    }

    func testPublicCoverKeepsPrivateAndExplicitNetworksOutsideTunnel() throws {
        let backend = MockRouteBackend()
        let protected = try XCTUnwrap(TUNCIDR("8.8.4.0/24"))
        backend.baseline = fixtureBaseline(protected: [protected])
        let plan = try backend.plan()
        XCTAssertLessThanOrEqual(plan.routes.count, TUNRoutePlan.maximumRoutes)
        XCTAssertTrue(plan.routes.allSatisfy { $0.destination.prefixLength > 1 && $0.scopeIndex == 0 })
        for (offset, route) in plan.routes.enumerated() {
            XCTAssertFalse(plan.routes.dropFirst(offset + 1).contains {
                $0.destination.contains(route.destination) || route.destination.contains($0.destination)
            })
        }
        for address in ["1.1.1.1", "8.8.8.8", "93.184.215.14", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertEqual(plan.routes.filter { $0.destination.contains(address: address) }.count, 1, address)
        }
        for address in ["10.1.2.3", "192.168.0.42", "169.254.1.2", "100.100.1.2", "127.0.0.1", "224.1.2.3",
                        "192.0.2.5", "8.8.4.4", "2001:db8::5", "::1", "fc00::5", "ff02::1", "fe80::2"] {
            XCTAssertFalse(plan.routes.contains { $0.destination.contains(address: address) }, address)
        }
        backend.baseline = fixtureBaseline(v6: false)
        XCTAssertTrue(try backend.plan().routes.allSatisfy { $0.destination.family == .ipv4 })
    }

    func testRoutePlannerRejectsVPNAndUnusableDefaults() throws {
        let backend = MockRouteBackend()
        backend.baseline = fixtureBaseline(vpn: true)
        XCTAssertThrowsError(try backend.plan()) { XCTAssertEqual($0 as? TUNRouteError, .conflictingVPN) }
        backend.baseline = fixtureBaseline(forwarding: true)
        XCTAssertThrowsError(try backend.plan()) { XCTAssertEqual($0 as? TUNRouteError, .systemForwardingEnabled) }
        backend.baseline = fixtureBaseline(v4: false, v6: false)
        XCTAssertThrowsError(try backend.plan()) { XCTAssertEqual($0 as? TUNRouteError, .unsuitableNetwork) }
        backend.baseline = fixtureBaseline()
        backend.interfaces.remove(backend.lease.interfaceIndex)
        XCTAssertThrowsError(try backend.plan()) { XCTAssertEqual($0 as? TUNRouteError, .invalidLease) }
    }

    func testGlobalRouteConflictRequiresExplicitExclusion() throws {
        let backend = MockRouteBackend()
        let prefix = try XCTUnwrap(TUNCIDR("8.0.0.0/7"))
        let foreign = TUNObservedRoute(destination: prefix, interfaceIndex: 1, linkGatewayIndex: nil, scopeIndex: 0)
        backend.routes.insert(foreign)
        XCTAssertThrowsError(try backend.plan()) { XCTAssertEqual($0 as? TUNRouteError, .routeConflict) }
        backend.baseline = fixtureBaseline(protected: [prefix])
        XCTAssertFalse(try backend.plan().routes.contains { prefix.contains($0.destination) })
    }

    func testActivationJournalsBeforeMutatingAndDisableDetaches() throws {
        let backend = MockRouteBackend(), store = MockJournalStore()
        let plan = try backend.plan()
        backend.beforeAdd = { route in
            XCTAssertEqual(store.record?.phase, .configuring)
            XCTAssertTrue(store.record?.routes.contains(route) == true)
        }
        let transaction = TUNRouteTransaction(backend: backend, store: store)
        try transaction.activate(plan) { true }
        XCTAssertEqual(transaction.phase, .active)
        XCTAssertEqual(store.record?.phase, .active)
        XCTAssertEqual(backend.routes, Set(plan.routes))
        XCTAssertThrowsError(try transaction.activate(plan) { true }) { XCTAssertEqual($0 as? TUNRouteError, .alreadyRunning) }
        try transaction.checkHealth { true }
        try transaction.disable()
        try transaction.disable()
        XCTAssertEqual(transaction.phase, .disabled)
        XCTAssertNil(store.record)
        XCTAssertTrue(backend.routes.isEmpty)
        XCTAssertEqual(backend.releaseCount, 1)
    }

    func testPartialRouteAddFailureRollsBackEvenWhenMutationOccurred() throws {
        for failure in [1, 11, 27] {
            let backend = MockRouteBackend(), store = MockJournalStore()
            backend.failAfterAddAt = failure
            let transaction = TUNRouteTransaction(backend: backend, store: store)
            XCTAssertThrowsError(try transaction.activate(backend.plan()) { true }) { XCTAssertEqual($0 as? FixtureError, .write) }
            XCTAssertEqual(backend.addCount, failure)
            XCTAssertEqual(transaction.phase, .disabled)
            XCTAssertNil(store.record)
            XCTAssertTrue(backend.routes.isEmpty)
            XCTAssertEqual(backend.releaseCount, 1)
        }
    }

    func testMissingKernelRouteOrWrongEgressNeverBecomesActive() throws {
        for loseRoute in [true, false] {
            let backend = MockRouteBackend(), store = MockJournalStore()
            if loseRoute { backend.ignoreAddAt = 1 }
            else { backend.failEgressAt = 2 }
            let transaction = TUNRouteTransaction(backend: backend, store: store)
            XCTAssertThrowsError(try transaction.activate(backend.plan()) { true }) {
                if loseRoute { XCTAssertEqual($0 as? TUNRouteError, .routeNotInstalled) }
                else { XCTAssertEqual($0 as? FixtureError, .egress) }
            }
            XCTAssertEqual(transaction.phase, .disabled)
            XCTAssertNil(store.record)
            XCTAssertEqual(backend.releaseCount, 1)
        }
    }

    func testEngineDeathAndNetworkSwitchRestoreBeforeReportingFailure() throws {
        for failEngine in [true, false] {
            let backend = MockRouteBackend(), store = MockJournalStore()
            let transaction = TUNRouteTransaction(backend: backend, store: store)
            try transaction.activate(backend.plan()) { true }
            if !failEngine { backend.baseline = fixtureBaseline(service: "ethernet", vpn: true) }
            XCTAssertThrowsError(try transaction.checkHealth { !failEngine }) {
                XCTAssertEqual($0 as? TUNRouteError, failEngine ? .engineNotReady : .baselineChanged)
            }
            XCTAssertEqual(transaction.phase, .disabled)
            XCTAssertNil(store.record)
            XCTAssertTrue(backend.routes.isEmpty)
            if !failEngine {
                XCTAssertEqual(backend.baseline.primaryService, "ethernet")
                XCTAssertTrue(backend.baseline.hasConflictingVPN)
            }
        }
    }

    func testUnreadyEngineAndChangedBaselineLeaveNoRoutes() throws {
        for changeBaseline in [true, false] {
            let backend = MockRouteBackend(), store = MockJournalStore()
            let plan = try backend.plan()
            if changeBaseline { backend.baseline = fixtureBaseline(service: "new-service") }
            let transaction = TUNRouteTransaction(backend: backend, store: store)
            XCTAssertThrowsError(try transaction.activate(plan) { changeBaseline }) {
                XCTAssertEqual($0 as? TUNRouteError, changeBaseline ? .baselineChanged : .engineNotReady)
            }
            XCTAssertEqual(backend.addCount, 0)
            XCTAssertNil(store.record)
            XCTAssertEqual(backend.releaseCount, 1)
        }
    }

    func testJournalFaultBeforeAndAfterMutationStillReleasesLease() throws {
        for stage in [1, 2] {
            let backend = MockRouteBackend(), store = MockJournalStore()
            store.failAfterSaveAt = stage
            let transaction = TUNRouteTransaction(backend: backend, store: store)
            XCTAssertThrowsError(try transaction.activate(backend.plan()) { true }) { XCTAssertEqual($0 as? FixtureError, .write) }
            XCTAssertEqual(transaction.phase, .disabled)
            XCTAssertNil(store.record)
            XCTAssertTrue(backend.routes.isEmpty)
            XCTAssertEqual(backend.releaseCount, 1)
            if stage == 1 { XCTAssertEqual(backend.addCount, 0) }
        }
    }

    func testConcurrentRouteReplacementSurvivesDisable() throws {
        let backend = MockRouteBackend(), store = MockJournalStore()
        let plan = try backend.plan()
        let transaction = TUNRouteTransaction(backend: backend, store: store)
        try transaction.activate(plan) { true }
        let removed = try XCTUnwrap(plan.routes.first)
        let replacement = TUNObservedRoute(destination: removed.destination, interfaceIndex: 1, linkGatewayIndex: nil, scopeIndex: 0)
        backend.routes.remove(removed)
        backend.routes.insert(replacement)
        XCTAssertThrowsError(try transaction.checkHealth { true }) { XCTAssertEqual($0 as? TUNRouteError, .routeNotInstalled) }
        XCTAssertEqual(backend.routes, [replacement])
        XCTAssertEqual(transaction.phase, .disabled)
    }

    func testUnverifiedRestorationRetainsJournalForLaterAudit() throws {
        let backend = MockRouteBackend(), store = MockJournalStore()
        let transaction = TUNRouteTransaction(backend: backend, store: store)
        try transaction.activate(backend.plan()) { true }
        backend.keepRoutesOnRelease = true
        XCTAssertThrowsError(try transaction.disable()) { XCTAssertEqual($0 as? TUNRouteError, .restorationUnverified) }
        XCTAssertEqual(transaction.phase, .recoveryRequired)
        XCTAssertNotNil(store.record)
        backend.routes = []
        try transaction.disable()
        XCTAssertEqual(transaction.phase, .disabled)
        XCTAssertNil(store.record)
    }

    func testEarlyReleaseRetryNeedsDetachProofWithoutOwnershipOrJournal() throws {
        let backend = MockRouteBackend(), store = MockJournalStore()
        let route = try XCTUnwrap(backend.plan().routes.first)
        backend.holdsLease = false // Descriptor release can precede kernel detach.
        let transaction = TUNRouteTransaction(backend: backend, store: store)
        try transaction.auditRecovery() // No record was needed before capture began.
        XCTAssertNil(store.record)
        XCTAssertThrowsError(try transaction.verifyReleased(backend.lease)) {
            XCTAssertEqual($0 as? TUNRouteError, .restorationUnverified)
        }
        backend.interfaces.remove(backend.lease.interfaceIndex)
        backend.routes.insert(route) // A lingering associated route also blocks proof.
        XCTAssertThrowsError(try transaction.verifyReleased(backend.lease)) {
            XCTAssertEqual($0 as? TUNRouteError, .restorationUnverified)
        }
        backend.routes.remove(route)
        let foreign = TUNObservedRoute(destination: route.destination, interfaceIndex: 1,
                                       linkGatewayIndex: nil, scopeIndex: 0)
        backend.routes.insert(foreign)
        XCTAssertNoThrow(try transaction.verifyReleased(backend.lease))
        XCTAssertEqual(backend.routes, [foreign])
        XCTAssertEqual(backend.releaseCount, 0) // Verification never mutates other state.
    }

    func testHelperCrashAuditRejectsReusedInterfaceAndPreservesReplacement() throws {
        let backend = MockRouteBackend(), store = MockJournalStore()
        let plan = try backend.plan()
        store.record = TUNRouteJournal(plan: plan, phase: .configuring)
        backend.holdsLease = false
        let recovery = TUNRouteTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try recovery.auditRecovery()) { XCTAssertEqual($0 as? TUNRouteError, .restorationUnverified) }
        XCTAssertEqual(recovery.phase, .recoveryRequired)
        XCTAssertEqual(backend.releaseCount, 0)
        backend.interfaces.remove(backend.lease.interfaceIndex)
        let prefix = try XCTUnwrap(plan.routes.first?.destination)
        let replacement = TUNObservedRoute(destination: prefix, interfaceIndex: 1, linkGatewayIndex: nil, scopeIndex: 0)
        backend.routes.insert(replacement)
        try recovery.auditRecovery()
        XCTAssertEqual(recovery.phase, .disabled)
        XCTAssertNil(store.record)
        XCTAssertEqual(backend.routes, [replacement])
    }

    func testPrivateJournalRoundTripAndExclusiveSession() throws {
        try withJournalDirectory { directory, descriptor in
            let backend = MockRouteBackend()
            let record = TUNRouteJournal(plan: try backend.plan(), phase: .configuring)
            var journal: TUNFileRouteJournalStore? = try TUNFileRouteJournalStore(directoryDescriptor: descriptor, owner: geteuid())
            XCTAssertNil(try journal?.load())
            try journal?.save(record)
            XCTAssertEqual(try journal?.load(), record)
            XCTAssertThrowsError(try TUNFileRouteJournalStore(directoryDescriptor: descriptor, owner: geteuid())) {
                XCTAssertEqual($0 as? TUNJournalStoreError, .anotherSession)
            }
            journal = nil
            let reopened = try TUNFileRouteJournalStore(directoryDescriptor: descriptor, owner: geteuid())
            XCTAssertEqual(try reopened.load(), record)
            try reopened.clear()
            XCTAssertNil(try reopened.load())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["route-journal.lock"])
        }
    }

    func testPrivateJournalRefusesSymlinkAndInsecureDirectory() throws {
        try withJournalDirectory { directory, descriptor in
            let store = try TUNFileRouteJournalStore(directoryDescriptor: descriptor, owner: geteuid())
            let source = directory.appendingPathComponent("route-journal.json")
            let destination = directory.appendingPathComponent("unrelated")
            try Data([42]).write(to: destination)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: destination), Data([42]))
        }
        try withJournalDirectory { _, descriptor in
            XCTAssertEqual(fchmod(descriptor, 0o755), 0)
            XCTAssertThrowsError(try TUNFileRouteJournalStore(directoryDescriptor: descriptor, owner: geteuid())) {
                XCTAssertEqual($0 as? TUNJournalStoreError, .unsafeDirectory)
            }
        }
    }

    private func withJournalDirectory(_ test: (URL, Int32) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FixtureError.write }
        defer { close(descriptor) }
        try test(directory, descriptor)
    }
}

private enum FixtureError: Error, Equatable { case write, egress }

private func fixtureBaseline(service: String = "wifi", v4: Bool = true, v6: Bool = true, vpn: Bool = false, forwarding: Bool = false,
                      protected: Set<TUNCIDR> = []) -> TUNRouteBaseline {
    var defaults: Set<TUNPhysicalRoute> = []
    if v4 { defaults.insert(TUNPhysicalRoute(family: .ipv4, interfaceIndex: 1, interfaceName: "en0", gateway: "192.168.1.1")) }
    if v6 { defaults.insert(TUNPhysicalRoute(family: .ipv6, interfaceIndex: 1, interfaceName: "en0", gateway: "fe80::1%en0")) }
    return TUNRouteBaseline(primaryService: service, defaults: defaults, protectedPrefixes: protected,
                            dnsFingerprint: "dns", proxyFingerprint: "proxy", serviceOrder: [service], hasConflictingVPN: vpn,
                            hasSystemForwarding: forwarding)
}

private final class MockRouteBackend: TUNRouteBackend {
    var baseline = fixtureBaseline()
    let lease = TUNRouteLease(interfaceName: "utun12", interfaceIndex: 12)
    var interfaces: Set<UInt32> = [1, 12]
    var routes: Set<TUNObservedRoute> = []
    var holdsLease = true
    var beforeAdd: ((TUNObservedRoute) -> Void)?
    var failAfterAddAt: Int?
    var ignoreAddAt: Int?
    var failEgressAt: Int?
    var keepRoutesOnRelease = false
    private(set) var addCount = 0
    private(set) var releaseCount = 0
    private var egressCount = 0

    func owns(_ lease: TUNRouteLease) -> Bool { holdsLease && lease == self.lease }
    func snapshot(excluding lease: TUNRouteLease?) throws -> TUNRouteSnapshot {
        TUNRouteSnapshot(baseline: baseline, interfaces: interfaces, routes: routes)
    }
    func plan() throws -> TUNRoutePlan { try TUNRoutePlan.make(snapshot: snapshot(excluding: lease), lease: lease) }
    func insert(_ route: TUNObservedRoute, lease: TUNRouteLease) throws {
        XCTAssertTrue(owns(lease))
        beforeAdd?(route)
        addCount += 1
        if addCount != ignoreAddAt { routes.insert(route) }
        if addCount == failAfterAddAt { throw FixtureError.write }
    }
    func verifyEgress(_ plan: TUNRoutePlan) throws {
        egressCount += 1
        if egressCount == failEgressAt { throw FixtureError.egress }
    }
    func release(_ lease: TUNRouteLease) throws {
        XCTAssertTrue(owns(lease))
        releaseCount += 1
        holdsLease = false
        interfaces.remove(lease.interfaceIndex)
        if !keepRoutesOnRelease { routes = routes.filter { !$0.isAssociated(with: lease) } }
    }
}

private final class MockJournalStore: TUNRouteJournalStore {
    var record: TUNRouteJournal?
    var failAfterSaveAt: Int?
    private var saveCount = 0
    func load() throws -> TUNRouteJournal? { record }
    func save(_ journal: TUNRouteJournal) throws {
        record = journal
        saveCount += 1
        if saveCount == failAfterSaveAt { throw FixtureError.write }
    }
    func clear() throws { record = nil }
}
