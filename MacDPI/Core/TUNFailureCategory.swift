/// Fixed diagnostic categories. Never derive a log value from an error's text,
/// userInfo, network endpoint, configuration value or packet contents.
public enum TUNFailureCategory: String, Sendable {
    case networkBaselineChanged = "network-baseline-changed"
    case networkConflict = "network-conflict"
    case networkStateUnavailable = "network-state-unavailable"
    case policyLimit = "policy-limit"
    case noEligibleRoutes = "no-eligible-routes"
    case invalidLease = "invalid-lease"
    case alreadyRunning = "already-running"
    case recoveryRequired = "recovery-required"
    case routeConflict = "route-conflict"
    case routeMissing = "route-missing"
    case workerNotReady = "worker-not-ready"
    case cleanupUnverified = "cleanup-unverified"
    case operatingSystem = "operating-system"
    case packetEngine = "packet-engine"
    case invalidSession = "invalid-session"
    case physicalInterface = "physical-interface"
    case controlLease = "control-lease"
    case unknownWorkerExit = "unknown-worker-exit"

    public static func broker(_ error: Error) -> Self {
        guard let error = error as? TUNRouteError else { return .operatingSystem }
        switch error {
        case .baselineChanged: return .networkBaselineChanged
        case .conflictingVPN, .systemForwardingEnabled: return .networkConflict
        case .unsuitableNetwork: return .networkStateUnavailable
        case .policyTooLarge: return .policyLimit
        case .noEligibleRoutes: return .noEligibleRoutes
        case .invalidLease: return .invalidLease
        case .alreadyRunning: return .alreadyRunning
        case .journalRequiresRecovery: return .recoveryRequired
        case .routeConflict: return .routeConflict
        case .routeNotInstalled: return .routeMissing
        case .engineNotReady: return .workerNotReady
        case .restorationUnverified: return .cleanupUnverified
        }
    }

    /// Numeric contract exported by Tools/TUNWorker/archive_darwin.go.
    /// A successful controlled stop has no failure category.
    public static func worker(exitCode: Int32, sessionFailed: Bool) -> Self? {
        // Startup cancellation can close the ready pipe before Go observes its
        // stop command. A nonzero worker result alone is not a failed session.
        guard sessionFailed else { return nil }
        switch exitCode {
        case 0: return nil
        case 1: return .packetEngine
        case 2: return .invalidSession
        case 3: return .physicalInterface
        case 4: return .controlLease
        default: return .unknownWorkerExit
        }
    }
}
