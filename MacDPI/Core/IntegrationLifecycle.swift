import Foundation

public enum TrafficIntegrationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case personalTUN, localProxy, transparent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .personalTUN: return "Personal TUN"
        case .localProxy: return "Local proxy diagnostics"
        case .transparent: return "Signed network extensions"
        }
    }
}

public enum IntegrationPhase: String, Codable, Sendable {
    case unavailable, disabled, permissionRequired, installing, awaitingApproval, restartRequired
    case configuring, starting, active, reconnecting, stopping, removing, failed
    public var title: String {
        switch self {
        case .unavailable: return "Integration unavailable"
        case .disabled: return "Disabled"
        case .permissionRequired: return "Setup required"
        case .installing: return "Installing extension"
        case .awaitingApproval: return "macOS approval required"
        case .restartRequired: return "Restart required"
        case .configuring: return "Configuring integration"
        case .starting: return "Starting integration"
        case .active: return "Transparent routing active"
        case .reconnecting: return "Reconnecting"
        case .stopping: return "Stopping integration"
        case .removing: return "Removing integration"
        case .failed: return "Integration needs attention"
        }
    }
    public var isBusy: Bool { [.installing, .configuring, .starting, .stopping, .removing].contains(self) }
}

public enum IntegrationExtensionState: String, Codable, Sendable {
    case unknown, absent, awaitingApproval, enabled, uninstalling, restartRequired
}
public enum IntegrationConnectionState: String, Codable, Sendable {
    case unconfigured, disconnected, connecting, connected, reasserting, disconnecting
    public var isStopped: Bool { self == .unconfigured || self == .disconnected }
}
public enum IntegrationDNSState: String, Codable, Sendable { case system, encryptedActive, awaitingApproval, restartRequired, unavailable, unknown }
public struct IntegrationDNSStatus: Equatable, Codable, Sendable {
    public var state: IntegrationDNSState
    public var detail: String
    public init(state: IntegrationDNSState, detail: String) { self.state = state; self.detail = detail }
    public static let system = Self(state: .system, detail: "System DNS is unchanged; IP-only DNS filtering cannot be corrected from a guessed domain.")
}

/// Fixed, bounded control vocabulary shared with the provider. It contains no destination metadata.
public struct ProviderStatusMessage: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var isEnabled: Bool
    public var activeTCPFlows: Int
    public var activeUDPFlows: Int
    public var pendingFlows: Int
    public var snapshot: Snapshot
    public init(protocolVersion: Int = 1, isEnabled: Bool, activeTCPFlows: Int = 0, activeUDPFlows: Int = 0,
                pendingFlows: Int = 0, snapshot: Snapshot = Snapshot()) {
        self.protocolVersion = protocolVersion; self.isEnabled = isEnabled
        self.activeTCPFlows = activeTCPFlows; self.activeUDPFlows = activeUDPFlows
        self.pendingFlows = pendingFlows; self.snapshot = snapshot
    }
    public var isValid: Bool {
        protocolVersion == 1 && (0...4096).contains(activeTCPFlows) && (0...4096).contains(activeUDPFlows)
            && (0...4096).contains(pendingFlows)
    }
    public var isDrained: Bool { isValid && !isEnabled && activeTCPFlows == 0 && activeUDPFlows == 0 && pendingFlows == 0 }
}

public struct IntegrationObservation: Equatable, Sendable {
    public var extensionState: IntegrationExtensionState = .unknown
    public var connection: IntegrationConnectionState = .unconfigured
    public var configurationPresent = false
    public var configurationCurrent = true
    public var extensionCurrent = true
    public var requiresEncryptedDNS = false
    public var systemStateInspected = true
    public var ownConfigurationCount = 0
    public var provider: ProviderStatusMessage?
    public var dns: IntegrationDNSStatus = .system
    public var preflightIssue: String?
    public var inspectionIssue: String?
    public init() {}
    public var isReady: Bool {
        preflightIssue == nil && inspectionIssue == nil && extensionState == .enabled && connection == .connected && configurationPresent
            && configurationCurrent && extensionCurrent && ownConfigurationCount == 1 && provider?.isValid == true && provider?.isEnabled == true
            && (!requiresEncryptedDNS || dns.state == .encryptedActive)
    }
}

public struct IntegrationStatus: Equatable, Sendable {
    public var phase: IntegrationPhase = .disabled
    public var detail = "No system networking changes have been requested."
    public var observation = IntegrationObservation()
    public init() {}
    public var isEnabled: Bool { phase == .active || phase == .reconnecting }
    public var requiresStop: Bool {
        isEnabled || !observation.connection.isStopped || [.encryptedActive, .unknown].contains(observation.dns.state)
    }
}

public enum IntegrationFailure: String, Error, LocalizedError, Sendable {
    case consentRequired = "Explicit approval is required before installing or changing networking integration."
    case unavailable = "The signed and provisioned integration is unavailable in this build."
    case operationInProgress = "An integration operation is already in progress."
    case invalidConfiguration = "The integration configuration is invalid."
    case duplicateConfigurations = "Multiple MacDPI configurations were found. Remove MacDPI integration before setting it up again."
    case staleConfiguration = "The saved MacDPI configuration does not match this build. Enable after reviewing setup to update it."
    case permissionDenied = "macOS did not authorize this integration operation."
    case installationFailed = "The system extension request failed."
    case configurationFailed = "The MacDPI network configuration could not be saved."
    case startFailed = "The transparent provider did not become ready."
    case stopUnverified = "The system has not confirmed that interception stopped. Use Emergency stop and inspect Network Settings."
    case dnsUnavailable = "Selected encrypted DNS requires approved system DNS integration; there is no silent fallback."
    case dnsStopUnverified = "Restoration of the MacDPI DNS configuration could not be confirmed."
    case recoveryRequired = "Integration rollback could not be fully verified. Inspect MacDPI and macOS Network Settings."
    case timedOut = "The integration operation exceeded its deadline."
    public var errorDescription: String? { rawValue }
}
public enum IntegrationInstallResult: Sendable { case installed, awaitingApproval, restartRequired }

/// Methods that mutate the machine require explicit consent. Inspect is read-only and never repairs preferences.
@MainActor
public protocol IntegrationDriving: AnyObject {
    var observationChanged: ((IntegrationObservation) -> Void)? { get set }
    func inspect(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void)
    func install(explicitConsent: Bool, completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void)
    func start(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void)
    func stop(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void)
    func remove(explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void)
}

/// A DNS supplement changes only MacDPI's configuration and checks that it is released on disable.
@MainActor
public protocol IntegrationDNSSupport: AnyObject {
    var statusChanged: (() -> Void)? { get set }
    func inspect(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void)
    func enable(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void)
    func disable(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void)
    func remove(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void)
}

public extension IntegrationDNSSupport {
    /// Optional for deterministic test doubles. Production adapters publish configuration and IPC loss.
    var statusChanged: (() -> Void)? { get { nil } set {} }
}

/// Main-actor state machine. Callbacks and actual OS observations are separate evidence; a successful
/// start request alone is never considered active. Every asynchronous operation has a generation.
@MainActor
public final class IntegrationLifecycle {
    public private(set) var status = IntegrationStatus()
    public var changed: ((IntegrationStatus) -> Void)?
    private let driver: IntegrationDriving
    private var operation = UUID()
    private var inspection = UUID()
    private var targetConfiguration = Configuration()
    private var wantedEnabled: Bool?
    private var operationInFlight = false
    private var stopCompletions = [(Result<Void, IntegrationFailure>) -> Void]()
    private let operationTimeout: TimeInterval
    private var deadline: Task<Void, Never>?
    private var awaitingInstallation = false
    private var removalRequested = false
    private var observationDeadline: Task<Void, Never>?
    public init(driver: IntegrationDriving, operationTimeout: TimeInterval = 180) {
        self.driver = driver; self.operationTimeout = operationTimeout.isFinite ? min(3600, max(0.01, operationTimeout)) : 180
        driver.observationChanged = { [weak self] observation in
            guard let self else { return }
            self.inspection = UUID(); self.observed(observation)
        }
    }
    deinit { deadline?.cancel(); observationDeadline?.cancel() }
    public func refresh() {
        guard !operationInFlight else { return }
        let generation = operation
        inspection = UUID(); let request = inspection
        driver.inspect { [weak self] result in
            guard let self, self.operation == generation, self.inspection == request else { return }
            switch result {
            case .success(let observation): self.observed(observation)
            case .failure(let error): self.set(.failed, error.rawValue)
            }
        }
    }
    public func enable(configuration: Configuration, explicitConsent: Bool) {
        guard explicitConsent else {
            if status.isEnabled { status.detail = IntegrationFailure.consentRequired.rawValue; changed?(status) }
            else { set(.permissionRequired, IntegrationFailure.consentRequired.rawValue) }
            return
        }
        guard !status.phase.isBusy else { return }
        if status.isEnabled && targetConfiguration == configuration { return }
        guard (try? configuration.validated()) != nil, !configuration.allowLoopbackForTesting else { set(.failed, IntegrationFailure.invalidConfiguration.rawValue); return }
        if awaitingInstallation, wantedEnabled == true {
            // A repeated Enable after macOS approval reuses the already-consented request.
            // A newly reviewed DNS scope may replace the desired config while installation is pending.
            targetConfiguration = configuration
            refresh(); return
        }
        targetConfiguration = configuration; wantedEnabled = true
        operationInFlight = true
        operation = UUID(); let generation = operation
        awaitingInstallation = false
        armDeadline(generation: generation, stopping: false)
        set(.configuring, "Checking the bundled extension and existing MacDPI configurations.")
        driver.inspect { [weak self] result in
            guard let self, self.operation == generation, self.wantedEnabled == true else { return }
            switch result {
            case .failure(let error): self.set(.failed, error.rawValue)
            case .success(let observation):
                self.status.observation = observation
                if let issue = observation.preflightIssue { self.set(.unavailable, issue); return }
                guard observation.ownConfigurationCount <= 1 else { self.set(.failed, IntegrationFailure.duplicateConfigurations.rawValue); return }
                if observation.extensionState == .enabled && observation.extensionCurrent { self.start(configuration, generation: generation) }
                else {
                    self.set(.installing, "Requesting installation through macOS. No traffic is active until the provider is confirmed ready.")
                    self.driver.install(explicitConsent: true) { [weak self] result in
                        guard let self, self.operation == generation, self.wantedEnabled == true else { return }
                        switch result {
                        case .failure(let error): self.set(.failed, error.rawValue)
                        case .success(.awaitingApproval):
                            self.awaitingInstallation = true
                            self.set(.awaitingApproval, "Approve MacDPI in System Settings. An installation request is pending.")
                        case .success(.restartRequired): self.set(.restartRequired, "macOS requires a restart. After restarting, inspect status and explicitly enable again.")
                        case .success(.installed): self.start(configuration, generation: generation)
                        }
                    }
                }
            }
        }
    }
    private func start(_ configuration: Configuration, generation: UUID) {
        set(.starting, "Waiting for the system connection and provider readiness reply.")
        driver.start(configuration: configuration, explicitConsent: true) { [weak self] result in
            guard let self, self.operation == generation, self.wantedEnabled == true else { return }
            switch result {
            case .failure(let error): self.rejectStarted(error)
            case .success(let observation):
                self.status.observation = observation
                if observation.dns.state == .awaitingApproval {
                    guard observation.connection.isStopped, observation.provider == nil || observation.provider?.isDrained == true else {
                        self.rejectStarted(.startFailed); return
                    }
                    self.wantedEnabled = false
                    self.set(.awaitingApproval, observation.dns.detail); return
                }
                if observation.dns.state == .restartRequired {
                    guard observation.connection.isStopped, observation.provider == nil || observation.provider?.isDrained == true else {
                        self.rejectStarted(.startFailed); return
                    }
                    self.wantedEnabled = false
                    self.set(.restartRequired, observation.dns.detail); return
                }
                guard observation.isReady else { self.rejectStarted(.startFailed); return }
                guard configuration.dnsMode != .cloudflare || observation.dns.state == .encryptedActive else {
                    self.rejectStarted(.dnsUnavailable)
                    return
                }
                self.set(.active, "The OS connection and provider readiness are confirmed. Supported public TCP/UDP traffic is handled; this is not universal DPI verification.")
            }
        }
    }
    public func disable(completion: @escaping (Result<Void, IntegrationFailure>) -> Void = { _ in }) {
        stopCompletions.append(completion)
        guard status.phase != .stopping else { return }
        wantedEnabled = false; awaitingInstallation = false; operation = UUID(); let generation = operation
        operationInFlight = true
        armDeadline(generation: generation, stopping: true)
        set(.stopping, "Requesting emergency provider drain and waiting for macOS to confirm disconnection.")
        driver.stop { [weak self] result in
            guard let self, self.operation == generation else { return }
            let outcome: Result<Void, IntegrationFailure>
            switch result {
            case .failure(let error): self.set(.failed, error.rawValue); outcome = .failure(error)
            case .success(let observation):
                self.status.observation = observation
                guard observation.connection.isStopped, observation.provider == nil || observation.provider?.isDrained == true,
                      observation.dns.state == .system else {
                    self.set(.failed, IntegrationFailure.stopUnverified.rawValue)
                    self.finishStops(.failure(.stopUnverified)); return
                }
                if observation.systemStateInspected {
                    self.set(.disabled, "macOS reports the connection stopped. MacDPI DNS changes have been released; live lifecycle behavior still requires approved validation.")
                } else {
                    self.set(.unavailable, "This build has never requested system integration. Existing system networking state was not inspected or changed by this build.")
                }
                outcome = .success(())
            }
            self.finishStops(outcome)
        }
    }
    public func remove(explicitConsent: Bool) {
        guard explicitConsent else {
            if status.isEnabled { status.detail = IntegrationFailure.consentRequired.rawValue; changed?(status) }
            else { set(.permissionRequired, IntegrationFailure.consentRequired.rawValue) }
            return
        }
        guard !removalRequested, status.phase != .removing else { return }
        removalRequested = true
        wantedEnabled = false
        disable { [weak self] result in
            guard let self else { return }
            guard case .success = result else { self.removalRequested = false; return }
            self.operation = UUID(); let generation = self.operation
            self.operationInFlight = true
            self.armDeadline(generation: generation, stopping: false)
            self.set(.removing, "Removing only MacDPI configurations and requesting official system extension deactivation.")
            self.driver.remove(explicitConsent: true) { [weak self] result in
                guard let self, self.operation == generation else { return }
                self.removalRequested = false
                switch result {
                case .failure(let error): self.set(.failed, error.rawValue)
                case .success(let observation):
                    self.status.observation = observation
                    if observation.extensionState == .restartRequired { self.set(.restartRequired, "Removal requires a macOS restart; interception is stopped.") }
                    else if observation.extensionState == .awaitingApproval { self.set(.awaitingApproval, "macOS approval is required to finish removal; interception is stopped.") }
                    else if observation.configurationPresent || !observation.connection.isStopped { self.set(.failed, IntegrationFailure.stopUnverified.rawValue) }
                    else if observation.extensionState == .uninstalling { self.set(.restartRequired, "MacDPI configurations were removed. macOS is still finishing extension removal.") }
                    else if observation.extensionState != .absent { self.set(.failed, "MacDPI configurations were removed, but macOS has not confirmed extension removal.") }
                    else { self.set(.permissionRequired, "MacDPI configurations were removed. Setup is required before enabling again.") }
                }
            }
        }
    }
    private func observed(_ observation: IntegrationObservation) {
        status.observation = observation
        if awaitingInstallation, wantedEnabled == true, observation.extensionState == .enabled,
           observation.extensionCurrent, observation.ownConfigurationCount <= 1,
           observation.preflightIssue == nil, observation.inspectionIssue == nil {
            awaitingInstallation = false; operationInFlight = true
            start(targetConfiguration, generation: operation); return
        }
        if operationInFlight { changed?(status); return }
        if let issue = observation.preflightIssue { set(.unavailable, issue); return }
        if let issue = observation.inspectionIssue { set(.failed, issue); return }
        if observation.connection.isStopped && [.encryptedActive, .unknown].contains(observation.dns.state) {
            set(.failed, "Transparent routing is stopped, but MacDPI DNS has not been confirmed released. Use Emergency stop to check and release it."); return
        }
        if observation.extensionState == .awaitingApproval || observation.dns.state == .awaitingApproval {
            set(.awaitingApproval, "macOS is waiting for system extension approval. No new traffic handling has started."); return
        }
        if observation.extensionState == .restartRequired || observation.dns.state == .restartRequired { set(.restartRequired, "macOS requires a restart; explicitly enable again afterward."); return }
        if wantedEnabled == false, !observation.connection.isStopped {
            set(.failed, "The system reports a connection after Disable. Emergency stop is available; normal handling is not confirmed."); return
        }
        if observation.ownConfigurationCount > 1 { set(.failed, IntegrationFailure.duplicateConfigurations.rawValue); return }
        if observation.connection == .reasserting {
            set(.reconnecting, "The OS reports a network transition; provider readiness is not currently confirmed.")
            armObservationDeadline(); return
        }
        if observation.connection == .connected, observation.provider?.isEnabled == true,
           (observation.requiresEncryptedDNS || targetConfiguration.dnsMode == .cloudflare), observation.dns.state != .encryptedActive {
            if wantedEnabled == true { rejectStarted(.dnsUnavailable) }
            else { set(.failed, IntegrationFailure.dnsUnavailable.rawValue) }
            return
        }
        if observation.isReady {
            if targetConfiguration.dnsMode == .cloudflare && observation.dns.state != .encryptedActive { set(.failed, IntegrationFailure.dnsUnavailable.rawValue) }
            else { set(.active, "The system connection and provider readiness are confirmed for supported traffic.") }
        } else if observation.configurationPresent && (!observation.configurationCurrent || !observation.extensionCurrent) { set(.permissionRequired, IntegrationFailure.staleConfiguration.rawValue) }
        else if observation.extensionState != .enabled { set(.permissionRequired, "Install and authorize the bundled system extension to enable Mac-wide integration.") }
        else if observation.connection.isStopped { set(.disabled, "System extension available; transparent routing is stopped.") }
        else {
            set(.starting, "The OS connection is changing; provider readiness is not confirmed.")
            armObservationDeadline()
        }
    }
    private func rejectStarted(_ error: IntegrationFailure) {
        disable { [weak self] result in
            if case .success = result { self?.set(.failed, error.rawValue) }
        }
    }
    private func set(_ phase: IntegrationPhase, _ detail: String) {
        status.phase = phase; status.detail = detail
        if [.unavailable, .disabled, .permissionRequired, .restartRequired, .active, .reconnecting, .failed].contains(phase) {
            operationInFlight = false; deadline?.cancel(); deadline = nil
        }
        if phase == .awaitingApproval { operationInFlight = false }
        if ![.starting, .reconnecting].contains(phase) { observationDeadline?.cancel(); observationDeadline = nil }
        if phase == .awaitingApproval, !awaitingInstallation { deadline?.cancel(); deadline = nil }
        changed?(status)
    }
    private func armObservationDeadline() {
        guard observationDeadline == nil else { return }
        let generation = operation, timeout = min(operationTimeout, 20)
        observationDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.operation == generation, !self.operationInFlight,
                  [.starting, .reconnecting].contains(self.status.phase) else { return }
            // Observation after app restart/sleep is read-only. A stalled OS session is reported,
            // never repaired by an unconsented preference write or another start request.
            self.set(.failed, IntegrationFailure.startFailed.rawValue)
        }
    }
    private func armDeadline(generation: UUID, stopping: Bool) {
        deadline?.cancel()
        let timeout = operationTimeout
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.operation == generation else { return }
            if stopping {
                self.operation = UUID(); self.removalRequested = false
                self.set(.failed, IntegrationFailure.stopUnverified.rawValue)
                self.finishStops(.failure(.stopUnverified))
            } else {
                self.removalRequested = false
                self.disable { [weak self] result in
                    if case .success = result { self?.set(.failed, IntegrationFailure.timedOut.rawValue) }
                }
            }
        }
    }
    private func finishStops(_ result: Result<Void, IntegrationFailure>) {
        let callbacks = stopCompletions; stopCompletions.removeAll(); callbacks.forEach { $0(result) }
    }
}
