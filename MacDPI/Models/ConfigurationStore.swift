import Foundation

@MainActor
protocol ConfigurationStoring: AnyObject {
    func load() -> Configuration?
    func save(_ configuration: Configuration)
}

@MainActor
final class PreferencesStore: ConfigurationStoring {
    func load() -> Configuration? {
        guard let data = UserDefaults.standard.data(forKey: "MacDPI.configuration") else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    func save(_ configuration: Configuration) {
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "MacDPI.configuration") }
    }
}

@MainActor
final class MemoryConfigurationStore: ConfigurationStoring {
    private var configuration: Configuration?
    init(_ configuration: Configuration? = nil) { self.configuration = configuration }
    func load() -> Configuration? { configuration }
    func save(_ configuration: Configuration) { self.configuration = configuration }
}
