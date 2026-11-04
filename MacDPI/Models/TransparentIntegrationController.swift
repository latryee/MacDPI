import Foundation
import NetworkExtension
import SystemExtensions

/// Deliberately not wired to the local-mode Enable button. Every mutating entry requires explicit consent.
/// The standard app does not bundle this provider or request its entitlements.
@MainActor
final class TransparentIntegrationController: NSObject, OSSystemExtensionRequestDelegate {
    enum IntegrationError: Error { case explicitApprovalRequired, providerNotBundled, invalidConfiguration }
    nonisolated static let identifier = "io.github.latryee.MacDPI.TransparentProxy"
    private(set) var status = "Not activated"
    private var completion: ((Error?) -> Void)?

    func activateAfterExplicitApproval(consent: Bool, completion: @escaping (Error?) -> Void) throws {
        guard consent else { throw IntegrationError.explicitApprovalRequired }
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(Self.identifier).systemextension")
        guard FileManager.default.fileExists(atPath: path.path) else { throw IntegrationError.providerNotBundled }
        self.completion = completion
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func configureAfterExplicitApproval(consent: Bool, configuration: Configuration, completion: @escaping (Error?) -> Void) throws {
        guard consent else { throw IntegrationError.explicitApprovalRequired }
        _ = try configuration.validated()
        guard !configuration.allowLoopbackForTesting, configuration.allowedPorts == [443] else { throw IntegrationError.invalidConfiguration }
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error { completion(error); return }
                let manager = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.identifier } ?? NETransparentProxyManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.identifier
                proto.serverAddress = "MacDPI local processing"
                proto.providerConfiguration = ["profile": configuration.profile.rawValue, "splitOffset": configuration.splitOffset, "dnsMode": configuration.dnsMode.rawValue]
                manager.protocolConfiguration = proto; manager.localizedDescription = "MacDPI Transparent Proxy"
                manager.isOnDemandEnabled = false; manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error { completion(error); return }
                    manager.loadFromPreferences { error in
                        if let error { completion(error); return }
                        do { try manager.connection.startVPNTunnel(); completion(nil) } catch { completion(error) }
                    }
                }
            }
        }
    }
    func disableAndRemoveAfterExplicitApproval(consent: Bool, completion: @escaping (Error?) -> Void) throws {
        guard consent else { throw IntegrationError.explicitApprovalRequired }
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error { completion(error); return }
            let own = managers?.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.identifier } ?? []
            let group = DispatchGroup()
            let lock = NSLock()
            var firstError: Error?
            for manager in own {
                group.enter()
                manager.connection.stopVPNTunnel()
                manager.isEnabled = false
                manager.saveToPreferences { error in
                    if let error { lock.lock(); firstError = firstError ?? error; lock.unlock(); group.leave(); return }
                    manager.removeFromPreferences { error in
                        lock.lock(); firstError = firstError ?? error; lock.unlock(); group.leave()
                    }
                }
            }
            group.notify(queue: .main) { completion(firstError) }
        }
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { DispatchQueue.main.async { self.status = "Approval required in System Settings" } }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            self.status = result == .completed ? "System extension registered; network activation unverified" : "Restart required"
            self.completion?(nil); self.completion = nil
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { DispatchQueue.main.async { self.status = "Activation failed"; self.completion?(error); self.completion = nil } }
}
