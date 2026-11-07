import Foundation

public enum TUNRoutePhase: String, Codable, Sendable {
    case disabled, configuring, active, restoring, recoveryRequired
}

/// The complete set of possible capture writes is saved before the first RTM_ADD. Recovery never
/// interprets a journal entry as permission to delete a route or take over an interface by name.
public struct TUNRouteJournal: Codable, Equatable, Sendable {
    public let version: Int
    public let lease: TUNRouteLease
    public let routes: [TUNObservedRoute]
    public var phase: TUNRoutePhase

    init(plan: TUNRoutePlan, phase: TUNRoutePhase) {
        version = 1
        lease = plan.lease
        routes = plan.routes
        self.phase = phase
    }

    var isValid: Bool {
        version == 1 && lease.isValid && !routes.isEmpty && routes.count <= TUNRoutePlan.maximumRoutes &&
            Set(routes.map(\.destination)).count == routes.count &&
            routes.allSatisfy {
                $0.destination.prefixLength > 1 && $0.interfaceIndex == lease.interfaceIndex &&
                    $0.linkGatewayIndex == lease.interfaceIndex && $0.scopeIndex == 0
            } && [.configuring, .active, .restoring].contains(phase)
    }
}

/// Open with an exclusive lock before starting a helper session. Save must make the entire
/// new journal durable or throw. A crash after a write and before its acknowledgement is valid.
public protocol TUNRouteJournalStore: AnyObject {
    func load() throws -> TUNRouteJournal?
    func save(_ journal: TUNRouteJournal) throws
    func clear() throws
}

/// A backend controls actual live descriptors. It never closes an arbitrary interface by name.
public protocol TUNRouteBackend: AnyObject {
    func owns(_ lease: TUNRouteLease) -> Bool
    /// Supply stable physical settings with the specified live lease's own changes excluded
    /// from the baseline. The interfaces and routes still include the actual observed state.
    func snapshot(excluding lease: TUNRouteLease?) throws -> TUNRouteSnapshot
    /// Perform an exclusive RTM_ADD and validate the kernel acknowledgement. Never use RTM_CHANGE.
    func insert(_ route: TUNObservedRoute, lease: TUNRouteLease) throws
    /// Read-only verification that interface-bound egress still uses the physical path.
    func verifyEgress(_ plan: TUNRoutePlan) throws
    /// Close the live lease and wait a bounded time for detach. Darwin owns route purging for the
    /// detached ifnet. Avoid RTM_DELETE: Darwin does not atomically compare its gateway or ifindex.
    func release(_ lease: TUNRouteLease) throws
}

/// Confined to the owning helper's serial execution context, alongside its engine health lease.
public final class TUNRouteTransaction {
    public private(set) var phase: TUNRoutePhase = .disabled
    private let backend: TUNRouteBackend
    private let store: TUNRouteJournalStore
    private var liveLease: TUNRouteLease?
    private var journal: TUNRouteJournal?
    private var activePlan: TUNRoutePlan?

    public init(backend: TUNRouteBackend, store: TUNRouteJournalStore) {
        self.backend = backend
        self.store = store
    }

    public func activate(_ plan: TUNRoutePlan, engineIsReady: () -> Bool) throws {
        guard phase == .disabled else { throw TUNRouteError.alreadyRunning }
        guard backend.owns(plan.lease) else { throw TUNRouteError.invalidLease }
        liveLease = plan.lease
        phase = .configuring
        do {
            do {
                guard try store.load() == nil else { throw TUNRouteError.journalRequiresRecovery }
            } catch {
                throw TUNRouteError.journalRequiresRecovery
            }
            guard engineIsReady() else { throw TUNRouteError.engineNotReady }
            let snapshot = try backend.snapshot(excluding: plan.lease)
            guard snapshot.baseline == plan.baseline else { throw TUNRouteError.baselineChanged }
            guard try TUNRoutePlan.make(snapshot: snapshot, lease: plan.lease) == plan else { throw TUNRouteError.routeConflict }
            try backend.verifyEgress(plan)
            journal = TUNRouteJournal(plan: plan, phase: .configuring)
            try persistJournal()
            for route in plan.routes {
                guard engineIsReady() else { throw TUNRouteError.engineNotReady }
                try backend.insert(route, lease: plan.lease)
            }
            try verify(plan, engineIsReady: engineIsReady)
            journal?.phase = .active
            try persistJournal()
            activePlan = plan
            phase = .active
        } catch {
            // Close the live lease even if reading the old journal or persisting our intent failed.
            // If restoring also fails, the restoration error is the higher-priority result.
            try restoreLiveLease()
            if case TUNRouteError.journalRequiresRecovery = error { phase = .recoveryRequired }
            throw error
        }
    }

    /// Call on an engine disconnect, route/interface notification, or wake before reporting active.
    public func checkHealth(engineIsReady: () -> Bool) throws {
        guard phase == .active, let plan = activePlan else { throw TUNRouteError.engineNotReady }
        do {
            try verify(plan, engineIsReady: engineIsReady)
        } catch {
            try restoreLiveLease()
            throw error
        }
    }

    public func disable() throws {
        if liveLease != nil { try restoreLiveLease() }
        else { try auditRecovery() }
    }

    /// Independently verify an early interface release before a journal exists.
    /// Relinquished descriptor ownership alone does not prove kernel detach.
    public func verifyReleased(_ lease: TUNRouteLease) throws {
        guard lease.isValid else { throw TUNRouteError.invalidLease }
        try verifyDetached(lease)
    }

    /// Safe after helper death or reboot. Check observed state and clear a fully resolved journal.
    /// A matching interface index may have been reused. If ambiguous, fail without changing routes.
    public func auditRecovery() throws {
        guard liveLease == nil else { throw TUNRouteError.alreadyRunning }
        do {
            if let prior = try store.load() {
                guard prior.isValid else { throw TUNRouteError.journalRequiresRecovery }
                try verifyDetached(prior.lease)
                try store.clear()
            }
            phase = .disabled
        } catch {
            phase = .recoveryRequired
            throw error
        }
    }

    private func persistJournal() throws {
        guard let journal, journal.isValid else { throw TUNRouteError.journalRequiresRecovery }
        try store.save(journal)
    }

    private func verify(_ plan: TUNRoutePlan, engineIsReady: () -> Bool) throws {
        guard engineIsReady() else { throw TUNRouteError.engineNotReady }
        guard backend.owns(plan.lease) else { throw TUNRouteError.invalidLease }
        let snapshot = try backend.snapshot(excluding: plan.lease)
        guard snapshot.baseline == plan.baseline else { throw TUNRouteError.baselineChanged }
        guard snapshot.interfaces.contains(plan.lease.interfaceIndex), Set(plan.routes).isSubset(of: snapshot.routes) else {
            throw TUNRouteError.routeNotInstalled
        }
        try backend.verifyEgress(plan)
    }

    private func restoreLiveLease() throws {
        guard let lease = liveLease else { return }
        phase = .restoring
        activePlan = nil
        if journal != nil {
            journal?.phase = .restoring
            // The first write-ahead record suffices for crash auditing. A new journal write must
            // not prevent closing the only resource that owns these routes.
            try? persistJournal()
        }
        do {
            if backend.owns(lease) { try backend.release(lease) }
            try verifyDetached(lease)
            if journal != nil { try store.clear() }
            liveLease = nil
            journal = nil
            phase = .disabled
        } catch {
            phase = .recoveryRequired
            throw TUNRouteError.restorationUnverified
        }
    }

    private func verifyDetached(_ lease: TUNRouteLease) throws {
        let snapshot = try backend.snapshot(excluding: nil)
        guard !snapshot.interfaces.contains(lease.interfaceIndex),
              !snapshot.routes.contains(where: { $0.isAssociated(with: lease) }) else {
            throw TUNRouteError.restorationUnverified
        }
    }
}
