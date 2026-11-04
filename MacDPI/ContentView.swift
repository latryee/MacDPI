import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Label("MacDPI", systemImage: "network.badge.shield.half.filled")
                    .font(.title2.weight(.semibold)).foregroundStyle(.tint)
                VStack(spacing: 6) {
                    navigation("Overview", symbol: "square.grid.2x2", index: 0)
                    navigation("Settings", symbol: "slider.horizontal.3", index: 1)
                    navigation("Diagnostics", symbol: "waveform.path.ecg", index: 2)
                }
                Spacer()
                Text("LOCAL. INDEPENDENT.\nOPEN SOURCE.").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(5)
                Text("No telemetry · No accounts").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(width: 172).background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(["Your connection, considered.", "Make it yours.", "See what’s happening."][tab]).font(.title.weight(.semibold))
                            Text("A lightweight, native local proxy for macOS").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if tab == 0 { overview }
                    if tab == 1 { settings }
                    if tab == 2 { diagnostics }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.padding(32)
            }.frame(minWidth: 550)
        }.frame(minWidth: 790, minHeight: 600)
    }
    private func navigation(_ title: String, symbol: String, index: Int) -> some View {
        Button { tab = index } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(tab == index ? Color.accentColor.opacity(0.13) : Color.clear).cornerRadius(8)
        }.buttonStyle(.plain).accessibilityIdentifier("nav-\(index)")
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                Image(systemName: model.isEnabled ? "network" : "power.circle").font(.system(size: 42, weight: .light)).foregroundStyle(model.isEnabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isEnabled ? "Proxy ready" : model.snapshot.state.rawValue.capitalized).font(.title2.weight(.medium)).accessibilityIdentifier("engine-status")
                    Text(model.isEnabled ? "Listening on 127.0.0.1:\(String(model.configuration.port))" : "Ready when you are. Enable the local proxy to begin.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.snapshot.state == .starting ? "Cancel" : model.isEnabled ? "Disable" : "Enable") { model.toggle() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy && model.snapshot.state != .starting)
                    .keyboardShortcut("e", modifiers: [.command]).accessibilityIdentifier("engine-toggle")
            }
            Divider()
            Text("Only apps explicitly configured to use this proxy send traffic through MacDPI. This is not system-wide protection.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Route your traffic") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.systemProxyLinked ? "macOS HTTPS proxy points to MacDPI. Applications may use their own network stack." : "Other apps are not automatically connected. Enable starts the proxy only.")
                    Text("For a web-only session without changing Mac settings, open the proxied window. DNS filtering may also require Cloudflare DNS over HTTPS in Settings.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open proxied web window") { model.openProxiedBrowser() }.disabled(!model.isEnabled).accessibilityIdentifier("open-proxied-web")
                        Button("Check setup") { model.refreshRoutingStatus() }
                    }
                    Text("Native Roblox games, Discord voice and other UDP applications require additional integration; this build does not route them.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                metric("Connections", value: String(model.snapshot.activeConnections), symbol: "arrow.triangle.branch")
                metric("Records split", value: String(model.snapshot.transformed), symbol: "arrow.left.and.right")
                metric("Transferred", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.snapshot.uploaded &+ model.snapshot.downloaded), countStyle: .binary), symbol: "arrow.up.arrow.down")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("CURRENT PROFILE").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text(model.configuration.profile.title).font(.headline) }
                    Text(model.configuration.profile.detail).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Label("Effectiveness depends on the site, network and application", systemImage: "info.circle").font(.caption)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label(model.reachable.map { $0 ? "Network path available" : "Network path unavailable" } ?? "Network monitoring off", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("No administrator access needed").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).background(Color(NSColor.controlBackgroundColor)).cornerRadius(16)
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.primary.opacity(0.035)).cornerRadius(10)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Profile", selection: $model.configuration.profile) { ForEach(Profile.allCases) { Text($0.title).tag($0) } }
                    Picker("DNS for proxy connections", selection: $model.configuration.dnsMode) { ForEach(DNSMode.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("dns-mode")
                    Text("Optional Cloudflare DNS over HTTPS sends destination names and your IP to Cloudflare using certificate-verified HTTPS. No system DNS change; no fallback to system DNS if it fails. System DNS remains the default.").font(.caption).foregroundStyle(.secondary)
                    Text(model.configuration.profile.detail).font(.caption).foregroundStyle(.secondary)
                    TextField("Local port (1024–65535)", value: $model.configuration.port, formatter: NumberFormatter()).accessibilityIdentifier("proxy-port")
                    if model.configuration.profile == .advanced {
                        Stepper("Split offset: \(model.configuration.splitOffset) bytes", value: $model.configuration.splitOffset, in: 1...16_000)
                    }
                    Stepper("Maximum connections: \(model.configuration.maxConnections)", value: $model.configuration.maxConnections, in: 1...256)
                }.padding(12).disabled(model.isEnabled || model.busy)
            }
            Text("Disable the engine before changing its configuration. Settings are saved when you enable it. The proxy allows public TCP port 443 destinations only.").font(.caption).foregroundStyle(.secondary)
            GroupBox("Connect other apps") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Apps that honor the macOS Secure Web Proxy (HTTPS) setting can use 127.0.0.1, port \(String(model.configuration.port)). Changing it affects those apps across this network service; record your current settings first.")
                    HStack {
                        Button("Copy proxy address") { model.copyProxyAddress() }
                        Button("Open Network Settings") { model.openProxySettings() }
                    }
                    Text("This app does not change system settings. Restore your previous HTTPS proxy setting before stopping MacDPI. Games and UDP voice do not use this HTTPS proxy.").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            if #available(macOS 13, *) {
                Toggle("Launch MacDPI at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text("Launch at login never automatically enables the engine. macOS may request approval in Login Items.").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Transparent integration") {
                Text("Permission required · Developer ID signing and Apple entitlements are required. The provider is prepared separately and is not installed or activated by this application. See INSTALLATION.md.").font(.callout).foregroundStyle(.secondary).padding(12)
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Check readiness") { model.checkReadiness() }.accessibilityIdentifier("readiness-check")
                Button("Copy report") { model.copyDiagnostics() }
                Spacer()
            }
            Text(model.diagnostics).accessibilityIdentifier("diagnostics-text").font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Color.primary.opacity(0.04)).cornerRadius(10)
            HStack { Text("Failed connections"); Spacer(); Text(String(model.snapshot.failures)).monospacedDigit() }
            HStack { Text("Passed through"); Spacer(); Text(String(model.snapshot.passedThrough)).monospacedDigit() }
            if let error = model.snapshot.lastError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            Text("Reports contain aggregate counters and fixed error categories. No browsing history, traffic payloads, passwords or hostnames are recorded.").font(.caption).foregroundStyle(.secondary)
            Text("Recovery: disable the proxy, restore the app’s previous proxy setting, then retry in Compatibility mode. Existing connections close when disabled.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
