import Foundation

/// Versioned, app-owned acknowledgement; this never grants or bypasses macOS permission.
/// Privacy-affecting DNS choices change the scope. TLS tuning does not require setup again.
struct IntegrationConsentScope: Codable, Equatable, Sendable {
    let version: Int
    let providerIdentifier: String
    let dnsMode: DNSMode
    let dnsBypassDomains: [String]
    init(configuration: Configuration) {
        version = 1
        providerIdentifier = "io.github.latryee.MacDPI.TransparentProxy"
        dnsMode = configuration.dnsMode
        dnsBypassDomains = configuration.dnsMode == .cloudflare
            ? Array(Set(configuration.dnsBypassDomains.map { $0.lowercased() })).sorted() : []
    }
}

@MainActor
protocol ConfigurationStoring: AnyObject {
    func load() -> Configuration?
    func save(_ configuration: Configuration)
    func loadIntegrationConsent() -> IntegrationConsentScope?
    func saveIntegrationConsent(_ scope: IntegrationConsentScope?)
}

extension ConfigurationStoring {
    func loadIntegrationConsent() -> IntegrationConsentScope? { nil }
    func saveIntegrationConsent(_ scope: IntegrationConsentScope?) {}
}

@MainActor
final class PreferencesStore: ConfigurationStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> Configuration? {
        guard let data = defaults.data(forKey: "MacDPI.configuration") else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    func save(_ configuration: Configuration) {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "MacDPI.configuration") }
    }
    func loadIntegrationConsent() -> IntegrationConsentScope? {
        guard let data = defaults.data(forKey: "MacDPI.integrationConsent.v1") else { return nil }
        return try? JSONDecoder().decode(IntegrationConsentScope.self, from: data)
    }
    func saveIntegrationConsent(_ scope: IntegrationConsentScope?) {
        if let scope, let data = try? JSONEncoder().encode(scope) { defaults.set(data, forKey: "MacDPI.integrationConsent.v1") }
        else { defaults.removeObject(forKey: "MacDPI.integrationConsent.v1") }
    }
}

@MainActor
final class MemoryConfigurationStore: ConfigurationStoring {
    private var configuration: Configuration?
    private var integrationConsent: IntegrationConsentScope?
    init(_ configuration: Configuration? = nil, integrationConsent: IntegrationConsentScope? = nil) {
        self.configuration = configuration; self.integrationConsent = integrationConsent
    }
    func load() -> Configuration? { configuration }
    func save(_ configuration: Configuration) { self.configuration = configuration }
    func loadIntegrationConsent() -> IntegrationConsentScope? { integrationConsent }
    func saveIntegrationConsent(_ scope: IntegrationConsentScope?) { integrationConsent = scope }
}
