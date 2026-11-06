import Foundation
import NetworkExtension
import Security
@preconcurrency import SystemExtensions

/// Read-only verification. Review/ad-hoc builds cannot submit activation requests, even if
/// someone bypasses the UI confirmation. macOS remains the final provisioning authority.
enum IntegrationSigningPreflight {
    static func issue(bundle: Bundle = .main, providerIdentifiers: [String] = [TransparentIntegrationController.identifier]) -> String? {
        guard bundle.object(forInfoDictionaryKey: "MacDPIIntegrationBuild") as? String == "developer-id" else {
            return "This is a local-review build. Mac-wide integration requires a Developer ID application and Apple-approved provisioning profiles. Local proxy diagnostics remain available."
        }
        guard let host = signing(bundle.bundleURL), let team = host[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, let hostID = bundle.bundleIdentifier,
              valid(bundle: bundle, info: host, team: team, identifier: hostID, host: true) else {
            return "The application signature, team, capabilities or provisioning profile is invalid. Install a correctly signed release."
        }
        for identifier in providerIdentifiers {
            let url = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
            guard let child = Bundle(url: url), child.bundleIdentifier == identifier,
                  child.object(forInfoDictionaryKey: "MacDPIIntegrationBuild") as? String == "developer-id",
                  let info = signing(url), valid(bundle: child, info: info, team: team, identifier: identifier, host: false) else {
                return "The bundled \(identifier) extension is missing or its Developer ID signature, team, capabilities or profile is invalid."
            }
        }
        return nil
    }
    static func matchesInstalledExtension(_ url: URL, identifier: String) -> Bool {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
        guard let installed = signing(url), let current = signing(bundled),
              let installedHash = installed[kSecCodeInfoUnique as String] as? Data,
              let currentHash = current[kSecCodeInfoUnique as String] as? Data else { return false }
        return installedHash == currentHash
    }
    private static func signing(_ url: URL) -> [String: Any]? {
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        let flags = SecCSFlags(rawValue: 0)
        let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecStaticCodeCreateWithPath(url as CFURL, flags, &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, flags, &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
    private static func valid(bundle: Bundle, info: [String: Any], team: String, identifier: String, host: Bool) -> Bool {
        let capability = identifier.hasSuffix(".DNSProxy") ? "dns-proxy-systemextension" : "app-proxy-provider-systemextension"
        guard info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let entitlement = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlement["com.apple.developer.team-identifier"] as? String == team,
              entitlement["com.apple.application-identifier"] as? String == team + "." + identifier,
              (entitlement["com.apple.developer.networking.networkextension"] as? [String])?.contains(capability) == true,
              !host || Set(["app-proxy-provider-systemextension", "dns-proxy-systemextension"]).isSubset(of: Set(entitlement["com.apple.developer.networking.networkextension"] as? [String] ?? [])),
              !host || entitlement["com.apple.developer.system-extension.install"] as? Bool == true,
              let profile = profile(bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")),
              (profile["TeamIdentifier"] as? [String])?.contains(team) == true,
              let expires = profile["ExpirationDate"] as? Date, expires > Date(),
              let granted = profile["Entitlements"] as? [String: Any],
              granted["com.apple.application-identifier"] as? String == team + "." + identifier,
              (granted["com.apple.developer.networking.networkextension"] as? [String])?.contains(capability) == true,
              !host || Set(["app-proxy-provider-systemextension", "dns-proxy-systemextension"]).isSubset(of: Set(granted["com.apple.developer.networking.networkextension"] as? [String] ?? [])),
              !host || granted["com.apple.developer.system-extension.install"] as? Bool == true else { return false }
        let group = team + ".io.github.latryee.MacDPI.shared"
        // TN3125: macOS app groups are unrestricted entitlements and may be absent from profiles.
        // The actual signed group must still use our verified team's prefix.
        return (entitlement["com.apple.security.application-groups"] as? [String])?.contains(group) == true
    }
    private static func profile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 1_048_576 else { return nil }
        var decoder: CMSDecoder?, content: CFData?
        var signerStatus = CMSSignerStatus.unsigned
        var certificateStatus: OSStatus = errSecSuccess
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
              data.withUnsafeBytes({ CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), true, &signerStatus, nil, &certificateStatus) == errSecSuccess,
              signerStatus == .valid, certificateStatus == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return (try? PropertyListSerialization.propertyList(from: content as Data, format: nil)) as? [String: Any]
    }
}

/// A retained, bounded SystemExtensions delegate. Property requests never install components.
@MainActor
private final class ExtensionRequestOperation: NSObject, OSSystemExtensionRequestDelegate {
    private static var live = [UUID: ExtensionRequestOperation]()
    private let id = UUID()
    private let request: OSSystemExtensionRequest
    private let properties: ((Result<[OSSystemExtensionProperties], IntegrationFailure>) -> Void)?
    private let result: ((Result<IntegrationInstallResult, IntegrationFailure>) -> Void)?
    private let changed: ((IntegrationExtensionState) -> Void)?
    private let allowAbsent: Bool
    private var reported = false
    private var deadline: Task<Void, Never>?
    private init(request: OSSystemExtensionRequest, properties: ((Result<[OSSystemExtensionProperties], IntegrationFailure>) -> Void)? = nil,
                 result: ((Result<IntegrationInstallResult, IntegrationFailure>) -> Void)? = nil,
                 changed: ((IntegrationExtensionState) -> Void)? = nil, allowAbsent: Bool = false) {
        self.request = request; self.properties = properties; self.result = result; self.changed = changed; self.allowAbsent = allowAbsent
    }
    static func inspect(identifier: String, completion: @escaping (Result<[OSSystemExtensionProperties], IntegrationFailure>) -> Void) {
        Self(request: .propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main), properties: completion).submit(timeout: 8)
    }
    static func mutate(identifier: String, activate: Bool, changed: ((IntegrationExtensionState) -> Void)? = nil,
                       completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        let request = activate ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        Self(request: request, result: completion, changed: changed, allowAbsent: !activate).submit(timeout: 120)
    }
    private func submit(timeout: TimeInterval) {
        Self.live[id] = self; request.delegate = self
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if !self.reported { self.properties?(.failure(.timedOut)); self.result?(.failure(.timedOut)); self.reported = true }
            self.finish()
        }
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    private func finish() { deadline?.cancel(); Self.live.removeValue(forKey: id) }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.changed?(.awaitingApproval)
            if !self.reported { self.reported = true; self.result?(.success(.awaitingApproval)) }
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // This delegate is created only after consent and team/signature verification.
        guard existing.bundleIdentifier == request.identifier, ext.bundleIdentifier == request.identifier else { return .cancel }
        return .replace
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        DispatchQueue.main.async { if !self.reported { self.reported = true; self.properties?(.success(properties)) }; self.finish() }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            let value: IntegrationInstallResult = result == .completed ? .installed : .restartRequired
            self.changed?(result == .completed ? .enabled : .restartRequired)
            if !self.reported { self.reported = true; self.properties?(.success([])); self.result?(.success(value)) }
            self.finish()
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            let nsError = error as NSError
            if self.allowAbsent, nsError.domain == OSSystemExtensionErrorDomain,
               nsError.code == OSSystemExtensionError.Code.extensionNotFound.rawValue {
                if !self.reported { self.reported = true; self.result?(.success(.installed)) }
                self.finish(); return
            }
            let denialCodes = [OSSystemExtensionError.Code.forbiddenBySystemPolicy.rawValue,
                               OSSystemExtensionError.Code.requestCanceled.rawValue,
                               OSSystemExtensionError.Code.authorizationRequired.rawValue]
            let denied = nsError.domain == OSSystemExtensionErrorDomain && denialCodes.contains(nsError.code)
            self.changed?(.unknown)
            if !self.reported {
                self.reported = true; self.properties?(.failure(.installationFailed))
                self.result?(.failure(denied ? .permissionDenied : .installationFailed))
            }
            self.finish()
        }
    }
}

/// Owns only MacDPI managers. Launch inspection never repairs preferences. No on-demand start,
/// system proxy edits, route changes or fallback to a local listener occur here.
@MainActor
final class TransparentIntegrationController: IntegrationDriving {
    nonisolated static let identifier = "io.github.latryee.MacDPI.TransparentProxy"
    nonisolated static let dnsIdentifier = "io.github.latryee.MacDPI.DNSProxy"
    private static let schema = 1
    var observationChanged: ((IntegrationObservation) -> Void)?
    private let dns: IntegrationDNSSupport?
    private var last = IntegrationObservation()
    private var generation = UUID()
    private var statusObserver: NSObjectProtocol?
    private var preferenceWrites = 0
    private var requestedSystemChanges = false
    private var publishingStatus = false
    private var statusRefreshPending = false
    init(dns: IntegrationDNSSupport? = nil) {
        self.dns = dns
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.publishCurrent()
            }
        }
        dns?.statusChanged = { [weak self] in self?.publishCurrent() }
    }
    private func publishCurrent() {
        guard !publishingStatus else { statusRefreshPending = true; return }
        publishingStatus = true
        let run = generation
        inspect { [weak self] result in
            guard let self else { return }
            self.publishingStatus = false
            if self.generation == run, !self.statusRefreshPending {
                switch result {
                case .success(let value): self.observationChanged?(value)
                case .failure(let error):
                    var unknown = self.last
                    unknown.provider = nil; unknown.inspectionIssue = error.rawValue
                    unknown.dns = .init(state: .unknown, detail: "Integration observation failed; DNS readiness is unconfirmed.")
                    self.observationChanged?(unknown)
                }
            }
            if self.statusRefreshPending { self.statusRefreshPending = false; self.publishCurrent() }
        }
    }
    deinit { if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) } }
    func inspect(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        let run = generation
        Task { @MainActor in
            do {
                let value = try await observe(); try check(run)
                last = value; completion(.success(value))
            }
            catch { completion(.failure(error as? IntegrationFailure ?? .configurationFailed)) }
        }
    }
    func install(explicitConsent: Bool, completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard IntegrationSigningPreflight.issue() == nil else { completion(.failure(.unavailable)); return }
        requestedSystemChanges = true
        let run = generation
        ExtensionRequestOperation.mutate(identifier: Self.identifier, activate: true, changed: { [weak self] state in
            guard let self, self.generation == run else { return }
            if state == .restartRequired {
                self.last.extensionState = state; self.observationChanged?(self.last)
            } else {
                self.publishCurrent()
            }
        }, completion: completion)
    }
    static func requestOwnedActivation(identifier: String, explicitConsent: Bool,
                                       completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard [Self.identifier, dnsIdentifier].contains(identifier), IntegrationSigningPreflight.issue(providerIdentifiers: [identifier]) == nil else {
            completion(.failure(.unavailable)); return
        }
        ExtensionRequestOperation.mutate(identifier: identifier, activate: true, completion: completion)
    }
    static func requestOwnedDeactivation(identifier: String, explicitConsent: Bool,
                                         completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard [Self.identifier, dnsIdentifier].contains(identifier), IntegrationSigningPreflight.issue(providerIdentifiers: [identifier]) == nil else {
            completion(.failure(.unavailable)); return
        }
        ExtensionRequestOperation.mutate(identifier: identifier, activate: false, completion: completion)
    }
    func start(configuration: Configuration, explicitConsent: Bool,
               completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard IntegrationSigningPreflight.issue() == nil else { completion(.failure(.unavailable)); return }
        guard (try? configuration.validated()) != nil, !configuration.allowLoopbackForTesting else { completion(.failure(.invalidConfiguration)); return }
        requestedSystemChanges = true
        generation = UUID(); let run = generation
        Task { @MainActor in
            var needsRollback = false
            do {
                try await waitForPreferenceWrites(run)
                var managers = try await loadManagers(); try check(run)
                guard managers.count <= 1 else { throw IntegrationFailure.duplicateConfigurations }
                if let existing = managers.first, !Self.connection(existing.connection.status).isStopped {
                    needsRollback = true
                    _ = try await shutdown(run: run)
                    managers = try await loadManagers(); try check(run)
                }
                guard managers.count <= 1 else { throw IntegrationFailure.duplicateConfigurations }
                let manager = managers.first ?? NETransparentProxyManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.identifier; proto.serverAddress = "MacDPI local transparent processing"
                proto.providerConfiguration = Self.values(configuration)
                manager.protocolConfiguration = proto; manager.localizedDescription = "MacDPI Transparent Proxy"
                manager.isOnDemandEnabled = false; manager.onDemandRules = []; manager.isEnabled = true
                needsRollback = true
                try await save(manager); try check(run)
                try await reload(manager); try check(run)
                if configuration.dnsMode == .cloudflare {
                    guard let dns else { throw IntegrationFailure.dnsUnavailable }
                    let value = try await dnsEnable(dns, configuration: configuration); try check(run)
                    if [.awaitingApproval, .restartRequired].contains(value.state) {
                        // The supplement is not running yet. Keep TCP disabled and require a fresh
                        // Enable after OS approval/restart rather than pretending the timeout is readiness.
                        manager.isEnabled = false; try await save(manager); try check(run)
                        var observation = try await observe(managers: [manager]); try check(run); observation.dns = value
                        completion(.success(observation)); return
                    }
                    guard value.state == .encryptedActive else { throw IntegrationFailure.dnsUnavailable }
                } else if let dns {
                    let value = try await dnsDisable(dns); try check(run)
                    guard value.state == .system else { throw IntegrationFailure.dnsStopUnverified }
                }
                try manager.connection.startVPNTunnel()
                // startVPNTunnel is an acknowledgement, never readiness evidence.
                let end = ProcessInfo.processInfo.systemUptime + 20
                while ProcessInfo.processInfo.systemUptime < end {
                    try check(run)
                    let value = try await observe(managers: [manager]); try check(run)
                    if value.isReady, configuration.dnsMode != .cloudflare || value.dns.state == .encryptedActive {
                        last = value; completion(.success(value)); return
                    }
                    if manager.connection.status == .invalid { throw IntegrationFailure.startFailed }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                throw IntegrationFailure.startFailed
            } catch {
                guard generation == run else { completion(.failure(.startFailed)); return }
                let reason = error as? IntegrationFailure ?? .startFailed
                guard needsRollback else { completion(.failure(reason)); return }
                // DNS enable plus TCP start is a transaction; rollback both on failure.
                do { _ = try await shutdown(run: run); completion(.failure(reason)) }
                catch { completion(.failure(.recoveryRequired)) }
            }
        }
    }
    func stop(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        if let issue = IntegrationSigningPreflight.issue(), !requestedSystemChanges,
           !last.configurationPresent, last.connection.isStopped, last.provider?.isEnabled != true {
            // An unsupported build that never touched integration may quit without requesting
            // inaccessible preferences. This proves only this build's inactivity, not global OS state.
            generation = UUID()
            var value = IntegrationObservation(); value.preflightIssue = issue; value.systemStateInspected = false
            completion(.success(value)); return
        }
        requestedSystemChanges = true
        generation = UUID(); let run = generation
        Task { @MainActor in
            do {
                let value = try await shutdown(run: run); try check(run); last = value; completion(.success(value))
            } catch { completion(.failure(error as? IntegrationFailure ?? .stopUnverified)) }
        }
    }
    func remove(explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard IntegrationSigningPreflight.issue() == nil else { completion(.failure(.unavailable)); return }
        requestedSystemChanges = true
        generation = UUID(); let run = generation
        Task { @MainActor in
            do {
                _ = try await shutdown(run: run); try check(run)
                for manager in try await loadManagers() { try check(run); try await removeManager(manager) }
                var dnsRemoval: IntegrationDNSStatus?
                if let dns { dnsRemoval = try await dnsRemove(dns); try check(run) }
                let result = try await deactivate(); try check(run)
                var value = try await observe(); try check(run)
                if case .restartRequired = result { value.extensionState = .restartRequired }
                else if case .awaitingApproval = result { value.extensionState = .awaitingApproval }
                else if dnsRemoval?.state == .restartRequired { value.extensionState = .restartRequired }
                else if dnsRemoval?.state == .awaitingApproval { value.extensionState = .awaitingApproval }
                guard !value.configurationPresent, value.connection.isStopped else { throw IntegrationFailure.stopUnverified }
                last = value; completion(.success(value))
            } catch { completion(.failure(error as? IntegrationFailure ?? .configurationFailed)) }
        }
    }
    private func shutdown(run: UUID) async throws -> IntegrationObservation {
        try await waitForPreferenceWrites(run)
        var failure: IntegrationFailure?
        let managers: [NETransparentProxyManager]
        do { managers = try await loadManagers() }
        catch {
            // DNS restoration is still attempted if loading TCP preferences fails.
            try check(run)
            if let dns { _ = try? await dnsDisable(dns) }
            throw error
        }
        try check(run)
        for manager in managers {
            try check(run)
            if !Self.connection(manager.connection.status).isStopped {
                let reply = await providerMessage(manager, command: "stop")
                if reply?.isDrained != true { failure = .stopUnverified }
            }
            try check(run); manager.connection.stopVPNTunnel()
            if manager.isEnabled || manager.isOnDemandEnabled {
                manager.isEnabled = false; manager.isOnDemandEnabled = false; manager.onDemandRules = []
                do { try await save(manager) } catch { failure = .stopUnverified }
                try check(run)
            }
        }
        let end = ProcessInfo.processInfo.systemUptime + 12
        while managers.contains(where: { !Self.connection($0.connection.status).isStopped }) && ProcessInfo.processInfo.systemUptime < end {
            try check(run); try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !managers.allSatisfy({ Self.connection($0.connection.status).isStopped }) { failure = .stopUnverified }
        try check(run)
        var dnsStatus = IntegrationDNSStatus.system
        if let dns {
            do { dnsStatus = try await dnsDisable(dns) }
            catch { failure = .dnsStopUnverified }
            try check(run)
        }
        if dnsStatus.state != .system { failure = .dnsStopUnverified }
        if let failure { throw failure }
        let persisted = try await loadManagers(); try check(run)
        guard persisted.allSatisfy({ !$0.isEnabled && !$0.isOnDemandEnabled && Self.connection($0.connection.status).isStopped }) else {
            throw IntegrationFailure.stopUnverified
        }
        var value = try await observe(managers: persisted); try check(run)
        value.provider = nil; value.dns = dnsStatus
        guard value.connection.isStopped else { throw IntegrationFailure.stopUnverified }
        return value
    }
    private func observe(managers supplied: [NETransparentProxyManager]? = nil) async throws -> IntegrationObservation {
        if let issue = IntegrationSigningPreflight.issue() {
            var value = IntegrationObservation(); value.preflightIssue = issue; value.systemStateInspected = false
            return value
        }
        let managers: [NETransparentProxyManager]
        if let supplied { managers = supplied } else { managers = try await loadManagers() }
        var value = IntegrationObservation()
        value.preflightIssue = IntegrationSigningPreflight.issue()
        value.ownConfigurationCount = managers.count; value.configurationPresent = !managers.isEmpty
        let ext = try await extensionState()
        value.extensionState = ext.state; value.extensionCurrent = ext.current
        if let manager = managers.first {
            value.connection = Self.connection(manager.connection.status); value.configurationCurrent = Self.isCurrent(manager)
            value.requiresEncryptedDNS = ((manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["dnsMode"] as? String) == DNSMode.cloudflare.rawValue
            if manager.connection.status == .connected { value.provider = await providerMessage(manager, command: "status") }
        }
        if let dns { value.dns = (try? await dnsInspect(dns)) ?? .init(state: .unknown, detail: "System DNS supplement status could not be read.") }
        if let manager = managers.first {
            let current = Self.connection(manager.connection.status)
            if current != value.connection || current != .connected { value.provider = nil }
            value.connection = current
        }
        return value
    }
    private func extensionState() async throws -> (state: IntegrationExtensionState, current: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            ExtensionRequestOperation.inspect(identifier: Self.identifier) { result in
                guard case .success(let properties) = result else {
                    if case .failure(let error) = result { continuation.resume(throwing: error) }
                    return
                }
                let current = properties.contains { $0.isEnabled && IntegrationSigningPreflight.matchesInstalledExtension($0.url, identifier: Self.identifier) }
                if properties.contains(where: \.isUninstalling) { continuation.resume(returning: (.uninstalling, current)) }
                else if properties.contains(where: \.isAwaitingUserApproval) { continuation.resume(returning: (.awaitingApproval, current)) }
                else if properties.contains(where: \.isEnabled) { continuation.resume(returning: (.enabled, current)) }
                else { continuation.resume(returning: (.absent, true)) }
            }
        }
    }
    private static func connection(_ status: NEVPNStatus) -> IntegrationConnectionState {
        switch status {
        case .invalid: return .unconfigured
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .disconnecting
        }
    }
    private static func values(_ config: Configuration) -> [String: Any] {
        var values: [String: Any] = ["schema": schema, "profile": config.profile.rawValue, "splitOffset": config.splitOffset,
         "dnsMode": config.dnsMode.rawValue, "dnsBypassDomains": config.dnsBypassDomains, "maxConnections": config.maxConnections,
         "handshakeTimeout": config.handshakeTimeout, "idleTimeout": config.idleTimeout,
         "buildVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        values["configuration"] = try? JSONEncoder().encode(config)
        return values
    }
    private static func isCurrent(_ manager: NETransparentProxyManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == identifier, let values = proto.providerConfiguration else { return false }
        return values["schema"] as? Int == schema
            && values["buildVersion"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            && values["version"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            && !manager.isOnDemandEnabled && (manager.onDemandRules?.isEmpty ?? true)
    }
    private func check(_ run: UUID) throws { guard generation == run else { throw IntegrationFailure.operationInProgress } }
    private func waitForPreferenceWrites(_ run: UUID) async throws {
        // Submitted writes cannot be cancelled. Wait for the acknowledgement before overriding
        // an older operation, so a late save cannot undo Emergency stop.
        let end = ProcessInfo.processInfo.systemUptime + 12
        while preferenceWrites > 0 && ProcessInfo.processInfo.systemUptime < end {
            try check(run); try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(run)
        guard preferenceWrites == 0 else { throw IntegrationFailure.stopUnverified }
    }
    private func loadManagers() async throws -> [NETransparentProxyManager] {
        try await bounded { completion in
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                Task { @MainActor in
                    if error != nil { completion(.failure(.configurationFailed)) }
                    else { completion(.success((managers ?? []).filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.identifier })) }
                }
            }
        }
    }
    private func save(_ manager: NETransparentProxyManager) async throws {
        try await write(manager.saveToPreferences(completionHandler:))
    }
    private func write(_ submit: (@escaping (Error?) -> Void) -> Void) async throws {
        preferenceWrites += 1
        try await bounded { completion in
            submit { error in
                Task { @MainActor in self.preferenceWrites -= 1; completion(error == nil ? .success(()) : .failure(.configurationFailed)) }
            }
        }
    }
    private func reload(_ manager: NETransparentProxyManager) async throws {
        try await bounded { completion in manager.loadFromPreferences { error in Task { @MainActor in completion(error == nil ? .success(()) : .failure(.configurationFailed)) } } }
    }
    private func removeManager(_ manager: NETransparentProxyManager) async throws {
        try await write(manager.removeFromPreferences(completionHandler:))
    }
    private func providerMessage(_ manager: NETransparentProxyManager, command: String) async -> ProviderStatusMessage? {
        guard let session = manager.connection as? NETunnelProviderSession else { return nil }
        return try? await bounded(timeout: 2) { completion in
            do {
                try session.sendProviderMessage(Data(command.utf8)) { data in
                    Task { @MainActor in
                        guard let data, data.count <= 16_384,
                              let value = try? JSONDecoder().decode(ProviderStatusMessage.self, from: data), value.isValid else {
                            completion(.failure(.startFailed)); return
                        }
                        completion(.success(value))
                    }
                }
            } catch { completion(.failure(.startFailed)) }
        }
    }
    private func deactivate() async throws -> IntegrationInstallResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.requestOwnedDeactivation(identifier: Self.identifier, explicitConsent: true) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }
    private func dnsInspect(_ dns: IntegrationDNSSupport) async throws -> IntegrationDNSStatus { try await bounded { dns.inspect(completion: $0) } }
    private func dnsEnable(_ dns: IntegrationDNSSupport, configuration: Configuration) async throws -> IntegrationDNSStatus { try await bounded(timeout: 30) { dns.enable(configuration: configuration, explicitConsent: true, completion: $0) } }
    private func dnsDisable(_ dns: IntegrationDNSSupport) async throws -> IntegrationDNSStatus { try await bounded { dns.disable(completion: $0) } }
    private func dnsRemove(_ dns: IntegrationDNSSupport) async throws -> IntegrationDNSStatus { try await bounded { dns.remove(completion: $0) } }
    private func bounded<Value>(timeout: TimeInterval = 12, _ body: (@escaping (Result<Value, IntegrationFailure>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let deadline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, !finished else { return }; finished = true
                continuation.resume(throwing: IntegrationFailure.timedOut)
            }
            body { result in
                guard !finished else { return }; finished = true; deadline.cancel()
                continuation.resume(with: result.mapError { $0 as Error })
            }
        }
    }
}
