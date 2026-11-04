import AppKit
import Combine
import Network
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var reachable: Bool?
    @Published var error: String?
    @Published var diagnostics = "Run a local readiness check. This does not test a censored network."
    @Published private(set) var busy = false
    @Published private(set) var systemProxyLinked = false
    private var browserWindow: NSWindow?
    private let engine: EngineControlling
    private let store: ConfigurationStoring
    private var refresh: Task<Void, Never>?
    private var path: NWPathMonitor?
    private var operation = UUID()
    var isEnabled: Bool { snapshot.state == .enabled }

    init(engine: EngineControlling = ProxyEngine(), store: ConfigurationStoring? = nil) {
        self.engine = engine; self.store = store ?? PreferencesStore()
        if let saved = self.store.load(),
           let validated = try? saved.validated(), !validated.allowLoopbackForTesting, validated.allowedPorts == [443] {
            configuration = validated
        } else { configuration = Configuration() }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--test-port"),
           arguments.indices.contains(index + 1), let port = UInt16(arguments[index + 1]), port >= 1024 {
            configuration.port = port
        }
    }
    func toggle() { isEnabled || snapshot.state == .starting ? disable() : enable() }
    func enable() {
        guard !busy else { return }
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
    private func startRefresh() {
        refresh?.cancel()
        let monitor = NWPathMonitor()
        path = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            DispatchQueue.main.async {
                guard let self, let monitor, self.path === monitor else { return }
                self.reachable = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.macdpi.reachability"))
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
    func checkReadiness() {
        refreshRoutingStatus()
        do {
            _ = try configuration.validated()
            diagnostics = "Configuration valid. Loopback mode needs no administrator permission.\nListener: \(snapshot.state.rawValue). Network path: \(reachable.map { $0 ? "available" : "unavailable" } ?? "not monitored while disabled").\nSystem HTTPS proxy: \(systemProxyLinked ? "points to this listener; apps may ignore it" : "not linked; Enable alone does not route other apps").\nDNS: \(configuration.dnsMode.title), for proxy connections only.\nTLS record splitting: implemented. See docs/REAL_NETWORK_VALIDATION.md for the dated, limited network test; your application is not automatically verified.\nTransparent extension: not installed or activated by this build.\nGame UDP, voice UDP and QUIC/HTTP/3: outside this TCP proxy."
        } catch { diagnostics = error.localizedDescription }
    }
    func refreshRoutingStatus() { systemProxyLinked = ProxyRoutingStatus.systemHTTPSProxyMatches(port: configuration.port) }
    func copyProxyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("127.0.0.1:\(configuration.port)", forType: .string)
    }
    func openProxySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func openProxiedBrowser() {
        guard isEnabled else { error = "Enable the local proxy first."; return }
        guard #available(macOS 14, *) else { error = "The isolated web window requires macOS 14. Configure your browser’s HTTPS proxy on this macOS version."; return }
        if let browserWindow { browserWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "MacDPI · Proxied HTTPS web window"
        window.contentViewController = NSHostingController(rootView: ProxiedBrowser(port: configuration.port))
        window.center(); window.makeKeyAndOrderFront(nil); browserWindow = window
    }
    func copyDiagnostics() {
        let text = "MacDPI \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")\n\(diagnostics)\nActive: \(snapshot.activeConnections), transformed: \(snapshot.transformed), failures: \(snapshot.failures)\n\(snapshot.lastError ?? "No recorded error")"
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
    func terminate(completion: @escaping () -> Void) { browserWindow?.close(); browserWindow = nil; operation = UUID(); refresh?.cancel(); path?.cancel(); engine.stop(completion: completion) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var item: NSStatusItem?
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let model = AppModel(store: arguments.contains("--ui-testing") ? MemoryConfigurationStore() : nil)
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
    private func installMenus() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "About MacDPI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let toggle = NSMenuItem(title: "Enable / Disable Local Proxy", action: #selector(toggleEngine), keyEquivalent: "e")
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
        item.button?.toolTip = "MacDPI — local proxy"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Open MacDPI", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let statusToggle = NSMenuItem(title: "Enable / Disable local proxy", action: #selector(toggleEngine), keyEquivalent: "")
        statusToggle.target = self; menu.addItem(statusToggle)
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
    @objc private func toggleEngine() { model?.toggle() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.terminate { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
