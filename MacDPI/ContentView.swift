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
                            Text("Native traffic integration for your Mac").foregroundStyle(.secondary)
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
        .alert(item: $model.pendingConsent) { consent in
            Alert(title: Text(consent == .enable ? "Authorize MacDPI integration" : "Remove MacDPI integration?"),
                  message: Text(consent == .enable ? enableConsent : "Stop supported traffic handling, disable MacDPI’s DNS configuration, remove only MacDPI configurations and request official extension deactivation. macOS may require approval or a restart. Other applications’ profiles are not removed."),
                  primaryButton: .default(Text(consent == .enable ? "Authorize reviewed setup" : "Remove MacDPI"), action: { model.confirmIntegrationConsent() }),
                  secondaryButton: .cancel { model.cancelIntegrationConsent() })
        }
    }
    private var enableConsent: String {
        var text = "MacDPI will request official macOS approval for its bundled networking component and handle supported public TCP/UDP flows from applications across this Mac. LAN, local and unsupported flows remain outside its scope. No remote VPN or trusted certificate is installed. Disable requests verified cleanup; real OS lifecycle and application compatibility still require testing."
        if model.configuration.dnsMode == .cloudflare {
            text += "\n\nEncrypted DNS also authorizes the separate DNS component. Cloudflare receives public DNS names and your source IP. Local, split-DNS and interface-bound queries intentionally retain their original resolver; encrypted failures do not fall back. Enabling a DNS proxy can disable another DNS proxy. Before authorizing, review Network Settings and confirm no conflicting corporate, VPN or other DNS proxy configuration is being taken over."
        }
        return text
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
                    Text(model.statusTitle).font(.title2.weight(.medium)).accessibilityIdentifier("engine-status")
                    Text(model.statusDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(model.engineButtonTitle) { model.toggle() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canToggleEngine)
                    .keyboardShortcut("e", modifiers: [.command]).accessibilityIdentifier("engine-toggle")
            }
            Divider()
            GroupBox(model.integrationMode == .localProxy ? "Optional local diagnostics" : "Supported traffic integration") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.integrationMode == .personalTUN {
                        Text("Personal TUN forwards supported public TCP and UDP through a local interface. Private networks and existing network policies stay outside its route plan.")
                        if model.usesAutomaticTUNConfiguration {
                            Text("Automatic setup uses System DNS and looks up eligible Discord or Roblox names with Cloudflare only when a TLS connection needs repair.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.personalTUNPhase == .authorization {
                            Text("Approve the system dialog to start the tunnel for this session.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.recoveryCommand != nil {
                            Button("Copy recovery command") { model.copyTUNRecoveryCommand() }
                                .accessibilityIdentifier("tun-copy-recovery")
                            Text("Run the recovery check in Terminal before retrying. The helper checks its journal again before adding routes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Check status") { model.checkReadiness() }
                    } else if model.integrationMode == .transparent {
                        Text("Configured scope: public TCP and UDP across ports; DNS uses a separate approved component when selected. Private/LAN, own-provider traffic and unsupported endpoints are excluded.")
                        Text("TLS record splitting applies on TCP 443, 8443 and 9443. Other supported streams/datagrams retain their bytes. UDP forwarding is not proof of UDP or QUIC circumvention.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Review setup") { model.setupIntegration() }.disabled(model.busy || model.isEnabled).accessibilityIdentifier("integration-setup")
                            Button("Check status") { model.checkReadiness() }
                            Button("Emergency stop") { model.emergencyStop() }.accessibilityIdentifier("emergency-stop")
                        }
                    } else {
                        Text("The optional web window sends its HTTPS traffic through the local engine. It is a diagnostic/fallback tool; native game and voice traffic are separate acceptance targets.")
                        HStack {
                            Button("Open proxied web window") { model.openProxiedBrowser() }.disabled(!model.isEnabled).accessibilityIdentifier("open-proxied-web")
                            Button("Check setup") { model.refreshRoutingStatus() }
                        }
                    }
                    Text("Discord desktop/voice and Roblox gameplay are not verified by local fixtures or website access. Approved real application testing is still required.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.integrationMode != .personalTUN {
                HStack(spacing: 12) {
                    metric("Connections", value: String(model.snapshot.activeConnections), symbol: "arrow.triangle.branch")
                    metric("Records split", value: String(model.snapshot.transformed), symbol: "arrow.left.and.right")
                    metric("Transferred", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.snapshot.uploaded &+ model.snapshot.downloaded), countStyle: .binary), symbol: "arrow.up.arrow.down")
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("CURRENT PROFILE").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text(model.usesAutomaticTUNConfiguration ? "Automatic" : model.effectiveConfiguration.profile.title).font(.headline) }
                    Text(model.effectiveConfiguration.profile.detail).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Label("Effectiveness depends on the site, network and application", systemImage: "info.circle").font(.caption)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label(model.reachable.map { $0 ? "Network path available" : "Network path unavailable" } ?? "Network monitoring off", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.integrationMode.title).font(.caption).foregroundStyle(.secondary)
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
                    Picker("Operation", selection: $model.integrationMode) { ForEach(model.availableIntegrationModes) { Text($0.title).tag($0) } }.accessibilityIdentifier("integration-mode")
                    if model.integrationMode == .personalTUN {
                        Toggle("Automatic setup", isOn: $model.configuration.tunAutomaticConfiguration)
                            .accessibilityIdentifier("tun-automatic-setup")
                    }
                    if !model.usesAutomaticTUNConfiguration {
                        Picker("Profile", selection: $model.configuration.profile) { ForEach(Profile.allCases) { Text($0.title).tag($0) } }
                        Picker("DNS", selection: $model.configuration.dnsMode) { ForEach(DNSMode.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("dns-mode")
                        Text(model.integrationMode == .personalTUN
                             ? "Cloudflare receives eligible captured DNS queries over HTTPS. Private resolvers and split domains keep their original path. If eligible encrypted DNS fails, those queries fail."
                             : "Cloudflare receives selected DNS names over HTTPS. Local diagnostics changes only the proxy resolver. Signed extension mode requires separate DNS authorization.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Uses Standard with System DNS. Cloudflare receives eligible TLS names only when a suspected DNS answer needs repair.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.integrationMode != .localProxy {
                        TextField("Additional split-DNS domains (comma separated)", text: Binding(get: { model.configuration.dnsBypassDomains.joined(separator: ", ") }, set: { model.configuration.dnsBypassDomains = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }))
                    }
                    if model.integrationMode == .personalTUN && !model.usesAutomaticTUNConfiguration && model.configuration.profile != .compatibility {
                        Toggle("Repair suspected Discord and Roblox DNS answers for TLS", isOn: $model.configuration.tunTLSOriginRepair)
                        Text("When service names share a single system DNS address, MacDPI can resolve eligible visible TLS names through Cloudflare. Split DNS and UDP keep their existing paths.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.effectiveConfiguration.profile.detail).font(.caption).foregroundStyle(.secondary)
                    if model.integrationMode == .localProxy { TextField("Local port (1024–65535)", value: $model.configuration.port, formatter: NumberFormatter()).accessibilityIdentifier("proxy-port") }
                    if model.effectiveConfiguration.profile == .advanced {
                        Stepper("Split offset: \(model.configuration.splitOffset) bytes", value: $model.configuration.splitOffset, in: 1...16_000)
                    }
                    if model.integrationMode != .personalTUN {
                        Stepper("Maximum connections: \(model.configuration.maxConnections)", value: $model.configuration.maxConnections, in: 1...256)
                    }
                }.padding(12).disabled(model.isEnabled || model.busy)
            }
            Text("Disable before changing configuration. The local diagnostic listener is restricted to public TCP 443.").font(.caption).foregroundStyle(.secondary)
            if model.integrationMode == .localProxy { GroupBox("Local proxy diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The optional listener uses 127.0.0.1, port \(String(model.configuration.port)). The normal app protects it with per-launch credentials kept only in memory; the optional web window supplies them automatically.")
                    HStack {
                        Button("Copy proxy address") { model.copyProxyAddress() }
                        Button("Copy diagnostic credentials") { model.copyDiagnosticCredentials() }
                    }
                    Text("Copying credentials explicitly puts them on the clipboard. Local mode never changes system settings and cannot route native UDP game/voice traffic.").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            } }
            if #available(macOS 13, *) {
                Toggle("Launch MacDPI at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text("Launch at login never automatically enables the engine. macOS may request approval in Login Items.").font(.caption).foregroundStyle(.secondary)
            }
            if model.availableIntegrationModes.contains(.transparent) { GroupBox("Signed network extensions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.integrationStatus.detail).font(.callout).foregroundStyle(.secondary)
                    Text(model.integrationStatus.observation.dns.detail).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Review setup") { model.setupIntegration() }.disabled(model.busy || model.isEnabled)
                        Button("Open Network Settings") { model.openProxySettings() }
                        Button("Remove MacDPI integration") { model.requestIntegrationRemoval() }.disabled(model.busy)
                    }
                }.padding(12)
            } }
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
            if model.integrationMode != .personalTUN {
                HStack { Text("Failed connections"); Spacer(); Text(String(model.snapshot.failures)).monospacedDigit() }
                HStack { Text("Passed through"); Spacer(); Text(String(model.snapshot.passedThrough)).monospacedDigit() }
            }
            if let error = model.snapshot.lastError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            Text("Reports contain aggregate counters and fixed error categories. No browsing history, traffic payloads, passwords or hostnames are recorded.").font(.caption).foregroundStyle(.secondary)
            if model.integrationMode == .localProxy {
                Text("Disable the proxy, restore the app’s previous proxy setting, then retry in Compatibility mode. Existing connections close when disabled.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
