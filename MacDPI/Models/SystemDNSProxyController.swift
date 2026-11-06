import Foundation
import NetworkExtension

/// Owns only MacDPI's DNS configuration. The configuration-enabled bit is never sufficient to
/// report encrypted DNS active: a fresh code-signature-authenticated provider reply is required.
@MainActor
final class SystemDNSProxyController: IntegrationDNSSupport {
    nonisolated static let identifier = "io.github.latryee.MacDPI.DNSProxy"
    var statusChanged: (() -> Void)?
    private let manager = NEDNSProxyManager.shared()
    private var channel: MDPIControlClient?
    private var generation = UUID()
    private var writes = 0
    private var usedIntegration = false
    private var pending = false
    private var channelWasAuthenticated = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEDNSProxyConfigurationDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.statusChanged?() }
        }
    }
    func inspect(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void) {
        if IntegrationSigningPreflight.issue(providerIdentifiers: [Self.identifier]) != nil {
            completion(.success(usedIntegration ? .init(state: .unknown, detail: "DNS integration cannot be inspected by this unprovisioned build.") : .system)); return
        }
        let run = generation
        Task { @MainActor in
            do {
                try await load(); try check(run)
                guard manager.providerProtocol?.providerBundleIdentifier == Self.identifier else {
                    completion(.success(.system)); return
                }
                guard manager.isEnabled else { completion(.success(.system)); return }
                usedIntegration = true
                let reply = await message("status")
                try check(run)
                if manager.providerProtocol?.providerBundleIdentifier == Self.identifier, manager.isEnabled,
                   reply?.isValid == true, reply?.isEnabled == true {
                    completion(.success(.init(state: .encryptedActive, detail: "Authenticated DNS provider ready: public ordinary DNS uses Cloudflare DoH. Local/split-domain and interface-bound queries intentionally retain the original resolver.")))
                } else { completion(.success(.init(state: .unknown, detail: "MacDPI DNS configuration is enabled, but provider readiness is unconfirmed."))) }
            } catch { completion(.failure(.dnsUnavailable)) }
        }
    }
    func enable(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        guard !pending else { completion(.failure(.operationInProgress)); return }
        guard configuration.dnsMode == .cloudflare, (try? configuration.validated()) != nil,
              IntegrationSigningPreflight.issue(providerIdentifiers: [Self.identifier]) == nil else { completion(.failure(.dnsUnavailable)); return }
        pending = true; usedIntegration = true; generation = UUID(); let run = generation
        TransparentIntegrationController.requestOwnedActivation(identifier: Self.identifier, explicitConsent: true) { [weak self] result in
            guard let self else { return }
            guard self.generation == run else { completion(.failure(.operationInProgress)); return }
            switch result {
            case .failure(let error): self.pending = false; completion(.failure(error))
            case .success(.awaitingApproval): self.pending = false; completion(.success(.init(state: .awaitingApproval, detail: "Approve the MacDPI DNS system extension in macOS Settings, then Enable again.")))
            case .success(.restartRequired): self.pending = false; completion(.success(.init(state: .restartRequired, detail: "macOS requires a restart before DNS integration can be used.")))
            case .success(.installed):
                Task { @MainActor in
                    do {
                        try await self.waitForWrites(run); try await self.load(); try self.check(run)
                        // Do not overwrite a foreign configuration returned by the supported API.
                        if let existing = self.manager.providerProtocol?.providerBundleIdentifier, existing != Self.identifier { throw IntegrationFailure.dnsUnavailable }
                        let proto = NEDNSProxyProviderProtocol(); proto.providerBundleIdentifier = Self.identifier
                        proto.providerConfiguration = ["configuration": try JSONEncoder().encode(configuration), "schemaVersion": 2]
                        self.manager.providerProtocol = proto; self.manager.localizedDescription = "MacDPI Encrypted DNS"
                        self.manager.isEnabled = true
                        try await self.save(); try self.check(run); try await self.load(); try self.check(run)
                        let end = ProcessInfo.processInfo.systemUptime + 12
                        while ProcessInfo.processInfo.systemUptime < end {
                            try self.check(run)
                            let reply = await self.message("status")
                            try self.check(run)
                            if self.manager.isEnabled, reply?.isValid == true, reply?.isEnabled == true {
                                self.pending = false
                                completion(.success(.init(state: .encryptedActive, detail: "DNS provider readiness authenticated. Public queries use DoH; explicit LAN/split-DNS/interface exceptions retain their original resolver."))); return
                            }
                            try await Task.sleep(nanoseconds: 250_000_000)
                        }
                        throw IntegrationFailure.dnsUnavailable
                    } catch {
                        guard self.generation == run else { completion(.failure(.operationInProgress)); return }
                        self.pending = false
                        // Even an accepted save that completed after cancellation is followed by a
                        // serialized disable. Failure is reported, never silently called restored.
                        self.disable { result in
                            if case .failure = result { completion(.failure(.recoveryRequired)) }
                            else { completion(.failure(error as? IntegrationFailure ?? .dnsUnavailable)) }
                        }
                    }
                }
            }
        }
    }
    func disable(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void) {
        generation = UUID(); let run = generation; pending = false
        if IntegrationSigningPreflight.issue(providerIdentifiers: [Self.identifier]) != nil {
            completion(usedIntegration ? .failure(.dnsStopUnverified) : .success(.system)); return
        }
        Task { @MainActor in
            do {
                try await self.waitForWrites(run)
                try self.check(run); try await self.load(); try self.check(run)
                guard self.manager.providerProtocol?.providerBundleIdentifier == Self.identifier else {
                    // A foreign DNS configuration is never disabled or removed by MacDPI.
                    completion(.success(.system)); return
                }
                guard self.manager.isEnabled else { self.closeChannel(); completion(.success(.system)); return }
                let drained = await self.message("stop")
                try self.check(run)
                // A concurrent inspection can reload the shared manager while IPC is in flight.
                guard self.manager.providerProtocol?.providerBundleIdentifier == Self.identifier else {
                    self.closeChannel(); completion(.success(.system)); return
                }
                self.manager.isEnabled = false
                try await self.save(); try self.check(run); try await self.load(); try self.check(run)
                self.closeChannel()
                guard self.manager.providerProtocol?.providerBundleIdentifier != Self.identifier || !self.manager.isEnabled else {
                    throw IntegrationFailure.dnsStopUnverified
                }
                // A missing control acknowledgement cannot establish live cleanup, even if the
                // preferences flag is disabled. OS stop/crash behavior needs approved validation.
                guard drained?.isDrained == true else { throw IntegrationFailure.dnsStopUnverified }
                completion(.success(.system))
            } catch { completion(.failure(error as? IntegrationFailure ?? .dnsStopUnverified)) }
        }
    }
    func remove(completion: @escaping (Result<IntegrationDNSStatus, IntegrationFailure>) -> Void) {
        disable { [weak self] result in
            guard let self else { return }
            guard case .success = result else { completion(result); return }
            guard IntegrationSigningPreflight.issue(providerIdentifiers: [Self.identifier]) == nil else { completion(.failure(.unavailable)); return }
            let run = self.generation
            Task { @MainActor in
                do {
                    try await self.load(); try self.check(run)
                    if self.manager.providerProtocol?.providerBundleIdentifier == Self.identifier {
                        try await self.write(self.manager.removeFromPreferences(completionHandler:))
                        try self.check(run); try await self.load(); try self.check(run)
                        guard self.manager.providerProtocol?.providerBundleIdentifier != Self.identifier else { throw IntegrationFailure.dnsStopUnverified }
                    }
                    TransparentIntegrationController.requestOwnedDeactivation(identifier: Self.identifier, explicitConsent: true) { outcome in
                        guard self.generation == run else { completion(.failure(.operationInProgress)); return }
                        switch outcome {
                        case .failure(let error): completion(.failure(error))
                        case .success(.awaitingApproval): completion(.success(.init(state: .awaitingApproval, detail: "DNS configuration removed. Approve extension removal in macOS Settings.")))
                        case .success(.restartRequired): completion(.success(.init(state: .restartRequired, detail: "DNS configuration removed; macOS requires restart to finish unloading the extension.")))
                        case .success: completion(.success(.system))
                        }
                    }
                } catch { completion(.failure(error as? IntegrationFailure ?? .configurationFailed)) }
            }
        }
    }
    private func message(_ command: String) async -> ProviderStatusMessage? {
        guard let team = MDPICopySigningTeam(), team.count == 10 else { return nil }
        if channel == nil {
            let service = team + ".io.github.latryee.MacDPI.shared.DNSProxy"
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(Self.identifier)\""
            let fresh = MDPIControlClient(service: service, requiredPeer: requirement, queue: .main)
            channel = fresh
            fresh?.invalidationHandler = { [weak self, weak fresh] in
                Task { @MainActor in
                    guard let self, let fresh, self.channel === fresh else { return }
                    let wasReady = self.channelWasAuthenticated
                    self.closeChannel()
                    if wasReady { self.statusChanged?() }
                }
            }
        }
        guard let channel else { return nil }
        let identity = ObjectIdentifier(channel)
        return await withCheckedContinuation { continuation in
            channel.request(Data(command.utf8), timeout: 3) { bytes, error in
                Task { @MainActor in
                    guard let current = self.channel, ObjectIdentifier(current) == identity,
                          error == nil, let bytes, bytes.count <= 16_384,
                          let value = try? JSONDecoder().decode(ProviderStatusMessage.self, from: bytes), value.isValid else { continuation.resume(returning: nil); return }
                    self.channelWasAuthenticated = true
                    continuation.resume(returning: value)
                }
            }
        }
    }
    private func closeChannel() {
        let old = channel; channel = nil; channelWasAuthenticated = false
        old?.invalidationHandler = nil; old?.invalidate()
    }
    private func check(_ run: UUID) throws { guard generation == run else { throw IntegrationFailure.operationInProgress } }
    private func waitForWrites(_ run: UUID) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while writes > 0 && ProcessInfo.processInfo.systemUptime < end {
            try check(run); try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(run)
        guard writes == 0 else { throw IntegrationFailure.dnsStopUnverified }
    }
    private func load() async throws { try await bounded { done in manager.loadFromPreferences { error in done(error == nil ? .success(()) : .failure(.configurationFailed)) } } }
    private func save() async throws {
        try await write(manager.saveToPreferences(completionHandler:))
    }
    private func write(_ submit: (@escaping (Error?) -> Void) -> Void) async throws {
        writes += 1
        try await bounded { done in submit { [weak self] error in
            Task { @MainActor in self?.writes -= 1; done(error == nil ? .success(()) : .failure(.configurationFailed)) }
        } }
    }
    private func bounded<T>(_ body: (@escaping (Result<T, IntegrationFailure>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let deadline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled && !finished { finished = true; continuation.resume(throwing: IntegrationFailure.timedOut) }
            }
            body { result in
                Task { @MainActor in guard !finished else { return }; finished = true; deadline.cancel(); continuation.resume(with: result.mapError { $0 as Error }) }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; channel?.invalidate() }
}
