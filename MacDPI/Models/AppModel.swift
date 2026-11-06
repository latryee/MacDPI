import AppKit
import Combine
import Network
import Security
import ServiceManagement
import SwiftUI

/// An injected local engine/UI test cannot accidentally reach an OS adapter through a mode change.
@MainActor
private final class IsolatedIntegrationDriver: IntegrationDriving {
    var observationChanged: ((IntegrationObservation) -> Void)?
    func inspect(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        var value = IntegrationObservation(); value.preflightIssue = "System integration is unavailable in this isolated diagnostic session."
        completion(.success(value))
    }
    func install(explicitConsent: Bool, completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) { completion(.failure(.unavailable)) }
    func start(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) { completion(.failure(.unavailable)) }
    func stop(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) { completion(.success(IntegrationObservation())) }
    func remove(explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) { completion(.failure(.unavailable)) }
}

enum IntegrationConsent: String, Identifiable {
    case enable, remove
    var id: String { rawValue }
}

@MainActor
protocol PersonalTUNControlling: AnyObject {
    var phase: PersonalTUNPhase { get }
    var detail: String { get }
    var authorizationCommand: String? { get }
    var recoveryCommand: String? { get }
    var changed: (() -> Void)? { get set }
    func start(_ configuration: Configuration)
    func stop(completion: ((Bool) -> Void)?)
}

extension PersonalTUNController: PersonalTUNControlling {}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static var isIsolatedLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    @Published var configuration: Configuration
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var reachable: Bool?
    @Published var error: String?
    @Published var diagnostics = "Run a local readiness check. This does not test a censored network."
    @Published private(set) var busy = false
    @Published private(set) var systemProxyLinked = false
    @Published private(set) var integrationStatus = IntegrationStatus()
    @Published private(set) var personalTUNPhase: PersonalTUNPhase = .disabled
    @Published var pendingConsent: IntegrationConsent?
    @Published private var selectedIntegrationMode: TrafficIntegrationMode
    var integrationMode: TrafficIntegrationMode {
        get { selectedIntegrationMode }
        set {
            guard newValue != selectedIntegrationMode else { return }
            guard !busy, !isEnabled, !integrationStatus.requiresStop, personalTUNPhase != .recovery else {
                error = "Disable MacDPI before changing the integration mode."; return
            }
            guard availableIntegrationModes.contains(newValue) else {
                error = "This build does not include Personal TUN."; return
            }
            selectedIntegrationMode = newValue
            pendingConsent = nil; error = nil
            if newValue == .transparent { integration.refresh() }
        }
    }
    private var browserWindow: NSWindow?
    private let engine: EngineControlling
    private let localProxyToken: String?
    private let requiresLocalAuthentication: Bool
    private let store: ConfigurationStoring
    private let integration: IntegrationLifecycle
    private let personalTUN: PersonalTUNControlling
    private let personalTUNAvailable: Bool
    private var refresh: Task<Void, Never>?
    private var path: NWPathMonitor?
    private var operation = UUID()
    private var tracksIntegrationDiagnostics = false
    private var tunActiveSince: Date?
    var availableIntegrationModes: [TrafficIntegrationMode] {
        personalTUNAvailable ? [.personalTUN, .localProxy] : [.localProxy, .transparent]
    }
    var isEnabled: Bool {
        switch integrationMode {
        case .personalTUN: return personalTUNPhase == .active
        case .transparent: return integrationStatus.isEnabled
        case .localProxy: return snapshot.state == .enabled
        }
    }
    var canToggleEngine: Bool {
        integrationMode != .personalTUN || ![.stopping, .restoring].contains(personalTUNPhase)
    }
    var engineButtonTitle: String {
        if integrationMode == .personalTUN && [.stopping, .restoring].contains(personalTUNPhase) { return "Stopping" }
        return busy ? "Cancel" : isEnabled ? "Disable" : "Enable"
    }
    var authorizationCommand: String? { integrationMode == .personalTUN ? personalTUN.authorizationCommand : nil }
    var recoveryCommand: String? {
        integrationMode == .personalTUN && personalTUNPhase == .recovery ? personalTUN.recoveryCommand : nil
    }
    var statusTitle: String {
        switch integrationMode {
        case .personalTUN: return personalTUNPhase.rawValue
        case .transparent: return integrationStatus.phase.title
        case .localProxy: return isEnabled ? "Local proxy ready" : snapshot.state.rawValue.capitalized
        }
    }
    var statusDetail: String {
        switch integrationMode {
        case .personalTUN: return personalTUN.detail
        case .transparent: return integrationStatus.detail
        case .localProxy:
            return isEnabled
                ? "Listening on 127.0.0.1:\(configuration.port). Only explicitly configured proxy clients use this listener."
                : "Enable the optional local listener for proxy diagnostics."
        }
    }

    init(engine: EngineControlling? = nil, store: ConfigurationStoring? = nil,
         integrationDriver: IntegrationDriving? = nil, mode: TrafficIntegrationMode? = nil,
         personalTUNController: PersonalTUNControlling? = nil) {
        let arguments = ProcessInfo.processInfo.arguments
        let needsCredential = engine == nil && !Self.isIsolatedLaunch
        let token = needsCredential ? Self.makeLocalProxyToken() : nil
        localProxyToken = token; requiresLocalAuthentication = needsCredential
        self.engine = engine ?? ProxyEngine(authenticationToken: token); self.store = store ?? PreferencesStore()
        let isolated = engine != nil || Self.isIsolatedLaunch
        let tunBundled = !isolated && PersonalTUNController.bundled
        personalTUNAvailable = tunBundled || personalTUNController != nil
        personalTUN = personalTUNController ?? PersonalTUNController(allowed: tunBundled)
        selectedIntegrationMode = mode ?? (isolated ? .localProxy : tunBundled ? .personalTUN : .transparent)
        integration = IntegrationLifecycle(driver: integrationDriver ?? (isolated ? IsolatedIntegrationDriver() : TransparentIntegrationController(dns: SystemDNSProxyController())))
        if let saved = self.store.load(),
           let validated = try? saved.validated(), !validated.allowLoopbackForTesting, validated.allowedPorts == [443] {
            configuration = validated
        } else { configuration = Configuration() }
        if arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--test-port"),
           arguments.indices.contains(index + 1), let port = UInt16(arguments[index + 1]), port >= 1024 {
            configuration.port = port
        }
        integration.changed = { [weak self] status in
            guard let self else { return }
            self.integrationStatus = status
            if self.tracksIntegrationDiagnostics { self.updateIntegrationDiagnostics() }
            guard self.integrationMode == .transparent else { return }
            self.busy = status.phase.isBusy
            if let provider = status.observation.provider { self.snapshot = provider.snapshot }
            self.snapshot.state = status.isEnabled ? .enabled : status.phase == .starting ? .starting : status.phase == .failed ? .failed : .disabled
            if [.failed, .unavailable].contains(status.phase) { self.error = status.detail }
            if status.isEnabled { self.startPathMonitor() }
            else if !status.phase.isBusy { self.path?.cancel(); self.path = nil; self.reachable = nil }
        }
        personalTUN.changed = { [weak self] in self?.personalTUNDidChange() }
        // Test hosts, UI automation and injected local engines never reach OS integration adapters.
        if integrationMode == .transparent { integration.refresh() }
    }
    private static func makeLocalProxyToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
    }
    func toggle() {
        guard canToggleEngine else { return }
        let changing: Bool
        switch integrationMode {
        case .personalTUN: changing = personalTUNPhase.busy
        case .transparent: changing = integrationStatus.phase.isBusy
        case .localProxy: changing = snapshot.state == .starting
        }
        isEnabled || changing ? disable() : enable()
    }
    func setupIntegration() {
        guard !busy, !isEnabled, availableIntegrationModes.contains(.transparent) else { return }
        integrationMode = .transparent
        pendingConsent = .enable
    }
    func requestIntegrationRemoval() { pendingConsent = .remove }
    func cancelIntegrationConsent() { pendingConsent = nil }
    func confirmIntegrationConsent() {
        guard let consent = pendingConsent else { return }; pendingConsent = nil
        error = nil
        if consent == .remove {
            store.saveIntegrationConsent(nil)
            integration.remove(explicitConsent: true); return
        }
        guard integrationMode == .transparent else { return }
        do { _ = try configuration.validated() } catch { self.error = error.localizedDescription; return }
        store.saveIntegrationConsent(IntegrationConsentScope(configuration: configuration))
        enableAuthorizedIntegration()
    }
    private func enableAuthorizedIntegration() {
        store.save(configuration)
        integration.enable(configuration: configuration, explicitConsent: true)
    }
    func emergencyStop() {
        pendingConsent = nil
        if integrationMode != .transparent { disable() }
        if integrationMode == .transparent || integrationStatus.requiresStop { integration.disable() }
    }
    func enable() {
        guard !busy else { return }
        if integrationMode == .personalTUN {
            do { _ = try configuration.validated() } catch { self.error = error.localizedDescription; return }
            error = nil
            snapshot = Snapshot()
            store.save(configuration)
            personalTUN.start(configuration)
            return
        }
        if integrationMode == .transparent {
            do { _ = try configuration.validated() } catch { self.error = error.localizedDescription; return }
            if store.loadIntegrationConsent() == IntegrationConsentScope(configuration: configuration) { enableAuthorizedIntegration() }
            else { pendingConsent = .enable }
            return
        }
        guard !requiresLocalAuthentication || localProxyToken != nil else {
            error = "A secure diagnostic proxy credential could not be generated. Restart MacDPI before enabling local diagnostics."; return
        }
        do { _ = try configuration.validated() } catch { self.error = error.localizedDescription; return }
        operation = UUID(); let current = operation
        busy = true; error = nil; snapshot.state = .starting
        refreshRoutingStatus()
        store.save(configuration)
        engine.start(configuration: configuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.operation == current else { return }
                self.busy = false
                if case .failure(let error) = result { self.error = error.localizedDescription }
                self.startRefresh()
            }
        }
    }
    func disable() {
        pendingConsent = nil
        if integrationMode == .personalTUN { personalTUN.stop(completion: nil); return }
        if integrationMode == .transparent { integration.disable(); return }
        browserWindow?.close(); browserWindow = nil
        operation = UUID(); let current = operation
        busy = true
        refresh?.cancel(); refresh = nil
        path?.cancel(); path = nil; reachable = nil
        engine.stop { [weak self] in
            self?.engine.snapshot { value in
                DispatchQueue.main.async {
                    guard let self, self.operation == current else { return }
                    self.snapshot = value; self.busy = false
                }
            }
        }
    }
    private func personalTUNDidChange() {
        personalTUNPhase = personalTUN.phase
        guard integrationMode == .personalTUN else { return }
        busy = personalTUNPhase.busy
        if personalTUNPhase == .active {
            if tunActiveSince == nil { tunActiveSince = Date() }
            startPathMonitor()
        } else if !busy {
            tunActiveSince = nil
            path?.cancel(); path = nil; reachable = nil
        }
        updateTUNDiagnostics()
    }
    private func startRefresh() {
        refresh?.cancel()
        startPathMonitor()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.engine.snapshot { [weak self] value in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if self.snapshot != value { self.snapshot = value }
                        if value.state == .failed || value.state == .disabled {
                            self.refresh?.cancel(); self.path?.cancel(); self.path = nil
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private func startPathMonitor() {
        guard path == nil else { return }
        let monitor = NWPathMonitor()
        path = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            DispatchQueue.main.async {
                guard let self, let monitor, self.path === monitor else { return }
                self.reachable = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.macdpi.reachability"))
    }
    func checkReadiness() {
        if integrationMode == .personalTUN {
            do {
                _ = try configuration.validated()
                updateTUNDiagnostics()
            } catch { diagnostics = error.localizedDescription }
            return
        }
        if integrationMode == .transparent {
            integration.refresh()
            tracksIntegrationDiagnostics = true
            updateIntegrationDiagnostics()
            return
        }
        tracksIntegrationDiagnostics = false
        refreshRoutingStatus()
        do {
            _ = try configuration.validated()
            diagnostics = "Configuration valid. Loopback mode needs no administrator permission.\nListener: \(snapshot.state.rawValue). Network path: \(reachable.map { $0 ? "available" : "unavailable" } ?? "not monitored while disabled").\nSystem HTTPS proxy: \(systemProxyLinked ? "points to this listener; apps may ignore it" : "not linked; Enable alone does not route other apps").\nDNS: \(configuration.dnsMode.title), for proxy connections only.\nTLS record splitting: implemented. See docs/REAL_NETWORK_VALIDATION.md for the dated, limited network test; your application is not automatically verified.\nTransparent extension: not installed or activated by local diagnostic Enable; inspect Mac-wide mode for its actual status.\nGame UDP, voice UDP and QUIC/HTTP/3: outside this TCP proxy."
        } catch { diagnostics = error.localizedDescription }
    }
    private func updateIntegrationDiagnostics() {
        diagnostics = "Mode: Mac-wide integration\nStatus: \(integrationStatus.phase.title)\n\(integrationStatus.detail)\nExtension: \(integrationStatus.observation.extensionState.rawValue); OS connection: \(integrationStatus.observation.connection.rawValue).\n\(integrationStatus.observation.dns.detail)\nSupported public TCP/UDP handling is implemented in the prepared provider. NetworkExtension exclusions apply. UDP/QUIC forwarding does not imply DPI bypass. Discord desktop/voice and Roblox gameplay remain unverified.\nAfter macOS restart, Enable is manual; no on-demand rules are installed."
    }
    private func updateTUNDiagnostics() {
        let elapsed = tunActiveSince.map { "\(max(0, Int(Date().timeIntervalSince($0)))) seconds" } ?? "unavailable"
        diagnostics = "Personal TUN · \(statusTitle)\n\(statusDetail)\nDNS option · \(configuration.dnsMode.title)\nSession duration · \(elapsed)\nAggregate traffic and resource measurements are unavailable here.\nDiscord voice and Roblox gameplay require an approved live test."
    }
    func refreshRoutingStatus() {
        if integrationMode == .transparent { integration.refresh() }
        else if integrationMode == .localProxy { systemProxyLinked = ProxyRoutingStatus.systemHTTPSProxyMatches(port: configuration.port) }
    }
    func copyTUNAuthorizationCommand() { copyCommand(authorizationCommand) }
    func copyTUNRecoveryCommand() { copyCommand(recoveryCommand) }
    private func copyCommand(_ command: String?) {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    func copyProxyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("127.0.0.1:\(configuration.port)", forType: .string)
    }
    /// Explicit user action only: the UI must disclose that this copies a secret to the clipboard.
    func copyDiagnosticCredentials() {
        guard integrationMode == .localProxy, let localProxyToken else {
            error = "No diagnostic credential is available in this session."; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Username: macdpi\nPassword: \(localProxyToken)", forType: .string)
    }
    func openProxySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func openProxiedBrowser() {
        guard integrationMode == .localProxy, isEnabled else { error = "Select Local proxy diagnostics and enable its listener first."; return }
        guard #available(macOS 14, *) else { error = "The isolated web window requires macOS 14. Configure your browser’s HTTPS proxy on this macOS version."; return }
        if let browserWindow { browserWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "MacDPI · Proxied HTTPS web window"
        window.contentViewController = NSHostingController(rootView: ProxiedBrowser(port: configuration.port, proxyCredential: localProxyToken))
        window.center(); window.makeKeyAndOrderFront(nil); browserWindow = window
    }
    func copyDiagnostics() {
        var text = "MacDPI \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")\n\(diagnostics)"
        if integrationMode != .personalTUN {
            text += "\nActive: \(snapshot.activeConnections), transformed: \(snapshot.transformed), failures: \(snapshot.failures)\n\(snapshot.lastError ?? "No recorded error")"
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    var loginEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    func setLogin(_ enabled: Bool) {
        guard #available(macOS 13, *) else { error = "Launch at login requires macOS 13 or later."; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { error = "Approve MacDPI in System Settings → General → Login Items." }
            objectWillChange.send()
        } catch { self.error = error.localizedDescription }
    }
    func terminate(completion: @escaping (Bool) -> Void) {
        browserWindow?.close(); browserWindow = nil; operation = UUID(); refresh?.cancel(); path?.cancel()
        if integrationMode == .personalTUN {
            personalTUN.stop { [weak self] stopped in
                guard let self else { completion(true); return }
                if !stopped {
                    self.error = "Route restoration is unverified. Run the recovery command shown in Personal TUN."
                }
                if self.integrationStatus.requiresStop { self.finishIntegrationTermination(completion: completion) }
                else { completion(true) }
            }
            return
        }
        if integrationMode == .localProxy {
            engine.stop { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.integrationStatus.requiresStop else { completion(true); return }
                    self.finishIntegrationTermination(completion: completion)
                }
            }
            return
        }
        finishIntegrationTermination(completion: completion)
    }
    private func finishIntegrationTermination(completion: @escaping (Bool) -> Void) {
        integration.disable { [weak self] result in
            switch result {
            case .success: completion(true)
            case .failure(let error): self?.error = error.localizedDescription; completion(false)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: AppModel?
    private var item: NSStatusItem?
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let model = AppModel(store: AppModel.isIsolatedLaunch ? MemoryConfigurationStore() : nil)
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
        window.title = "MacDPI"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.contentMinSize = NSSize(width: 790, height: 600)
        window.isReleasedWhenClosed = false
        if arguments.contains("--ui-testing"), arguments.contains("--test-light-appearance") {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.center(); mainWindow = window
        installMenus()
        showWindow()
        if arguments.contains("--ui-testing"), arguments.contains("--benchmark-enabled") { model.enable() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshRoutingStatus() }
    private func installMenus() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "About MacDPI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let toggle = NSMenuItem(title: "Enable / Disable MacDPI", action: #selector(toggleEngine), keyEquivalent: "e")
        toggle.target = self; application.addItem(toggle)
        application.addItem(.separator())
        application.addItem(withTitle: "Hide MacDPI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit MacDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = application; main.addItem(appItem)
        let file = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open MacDPI", action: #selector(showWindow), keyEquivalent: "o")
        open.target = self; file.addItem(open)
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); fileItem.submenu = file; main.addItem(fileItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "MacDPI")
        item.button?.toolTip = "MacDPI — supported Mac-wide traffic integration"
        let menu = NSMenu(); menu.delegate = self
        let state = NSMenuItem(title: model?.statusTitle ?? "MacDPI", action: nil, keyEquivalent: "")
        state.tag = 100; menu.addItem(state)
        let show = NSMenuItem(title: "Open MacDPI", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let statusToggle = NSMenuItem(title: "Enable / Disable MacDPI", action: #selector(toggleEngine), keyEquivalent: "")
        statusToggle.target = self; statusToggle.tag = 101; menu.addItem(statusToggle)
        let emergency = NSMenuItem(title: "Emergency stop", action: #selector(emergencyStop), keyEquivalent: "")
        emergency.target = self; menu.addItem(emergency)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu; self.item = item
    }
    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        (mainWindow ?? NSApp.windows.first { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return false
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 100)?.title = model?.statusTitle ?? "MacDPI"
        menu.item(withTag: 101)?.title = "\(model?.engineButtonTitle ?? "Enable") MacDPI"
        menu.item(withTag: 101)?.isEnabled = model?.canToggleEngine == true
    }
    @objc private func emergencyStop() { model?.emergencyStop() }
    @objc private func toggleEngine() {
        model?.toggle()
        if model?.pendingConsent != nil || model?.authorizationCommand != nil || model?.recoveryCommand != nil { showWindow() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.terminate { stopped in DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: stopped) } }
        return .terminateLater
    }
}
