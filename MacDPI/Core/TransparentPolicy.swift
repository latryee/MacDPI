import Foundation

/// Policy for OS-supplied flows, separate from the deliberately restricted local CONNECT proxy.
/// Numeric endpoints remain numeric; no reverse DNS or shared-IP domain guessing is performed.
public enum TransparentPolicy {
    public static let ownIdentifiers: Set<String> = ["io.github.latryee.MacDPI", "io.github.latryee.MacDPI.TransparentProxy", "io.github.latryee.MacDPI.DNSProxy"]
    public static let defaultTLSPorts: Set<UInt16> = [443, 8443, 9443]
    public static func shouldHandle(endpoint: DatagramEndpoint, sourceIdentifier: String?, isBound: Bool, hasInterface: Bool) -> Bool {
        guard sourceIdentifier.map({ !ownIdentifiers.contains($0) }) ?? true,
              !isBound || hasInterface, endpoint.port != 53,
              (try? endpoint.validated()) != nil else { return false }
        return true
    }
    public static func configuration(for port: UInt16, base: Configuration) -> Configuration {
        var configuration = base
        configuration.allowedPorts = [port]
        configuration.allowLoopbackForTesting = false
        if !defaultTLSPorts.contains(port) { configuration.profile = .compatibility }
        return configuration
    }
}
