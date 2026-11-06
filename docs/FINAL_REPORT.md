# MacDPI 0.2.0 engineering report

MacDPI now embeds two Universal 2 system extensions and connects the native **Enable** control to an approval-aware Mac-wide integration lifecycle. The local review release contains the host and both providers. Its ad hoc signature permits local review and diagnostics. Mac-wide activation requires the provisioned Developer ID build and explicit owner approval.

## What changed

| Area | Result |
| --- | --- |
| Transparent TCP | Preserves the original numeric endpoint and public flow policy. Applies the existing TLS record split on TCP 443, 8443 and 9443. Other eligible TCP flows use unchanged bytes and support half-close. |
| Transparent UDP | Preserves IPv4/IPv6 datagrams, including empty messages. Bounds peers, pending packets, bytes and timeouts. Preserves an explicitly bound interface. |
| Encrypted DNS | Optional separate DNS provider for OS-handled TCP and UDP port 53. Public queries can use DoH. Local, split and interface-bound queries use the original resolver. Failed DoH queries fail explicitly. |
| UI and lifecycle | Mac-wide mode by default. Review and OS approval states, fresh provider readiness, Disable, emergency stop, removal and read-only startup inspection. Local diagnostics remains selectable. |
| Local CONNECT | Preserves the existing TLS engine and diagnostic browser. The app generates a per-launch credential and authenticates before resolution. |
| Release | Preserves the native Xcode project. Stamps version 0.2.0/build 2 into the host and both providers, verifies package contents and prepares Developer ID and notarization gates. |

The original working source, tests and documentation were preserved in local checkpoint `192f7c4` on `codex/system-integration`. The revision uses Swift, SwiftUI, AppKit and public Apple system frameworks. No remote was configured or published.

## Evidence

97 core XCTest cases, 22 hosted model cases, three native UI cases, 23 legacy loopback integration scenarios, four native TCP/UDP fixture cases and 14 packaging checks passed. The tests found a recursive app mode setter crash, which was fixed and retested. The core tests also cover DNS error and cancellation handling, stale lifecycle state, credential admission, half-close and the first-flight timeout. Runtime evidence is from Apple Silicon on macOS 26.6. Intel and older systems were checked at build time through Universal 2 and the macOS 12 deployment target. [Test results](../TEST_RESULTS.md).

In the local diagnostic idle sample the app used 0.100% CPU and 90.84 MiB RSS. A 60-second loopback engine soak verified 375 MiB each way over four persistent tunnels and 300 short connections, with zero sessions left after stop. Controlled UDP tests informed a receive-buffer change that reduced median process CPU time by about 20.5% in the measured workload. Installed provider footprint, battery use and sleep/wake remain outside these measurements. [Performance and reproduction](../PERFORMANCE.md).

The release builder verifies architecture slices, extension classes, capabilities, app-group/Mach service metadata and signatures. It tests extracted ZIP contents and the read-only DMG against the app. The production path checks the actual Developer ID identity and matching component profiles before signing nested code and the host. Notarization creates a fresh verified submission archive and requires Apple's Accepted status before stapling. [Building and signing](../BUILDING.md), [Apple integration evidence](APPLE_INTEGRATION_RESEARCH.md).

After verifying 0.2.0, cleanup removed about 2.85 GiB of older builds, caches, test bundles and profiling output. The build directory retains `build/release/MacDPI.app` and `build/dist/MacDPI-0.2.0-universal2-local-adhoc.{zip,dmg,sha256}`. The app signature and both checksums were verified again at those paths. Source and sanitized historical evidence remain available.

## Scope and remaining acceptance

TLS record splitting preserves handshake bytes and ordinary certificate verification. It can affect a DPI that fails to reconstruct records. UDP forwarding applies no UDP or QUIC bypass strategy. A public IP does not identify a domain, so transparent forwarding preserves the OS endpoint and DNS is handled before resolution. The BSD UDP adapter preserves interface binding but cannot attach the original app metadata. The installed network path, VPN/filter coexistence and TCP/DNS re-injection need OS testing. [Capability matrix](../COMPATIBILITY.md), [security review](../SECURITY.md).

The 0.1.0 Discord API/WebSocket and Roblox web/API check was limited to one network. Real Discord desktop login, gateway persistence and voice, and Roblox native launch, authentication and gameplay are pending. The planned acceptance procedure separates these checks and treats rollback as a requirement. [Historical results](REAL_NETWORK_VALIDATION.md), [installed acceptance and rollback](NETWORK_SETUP_PLAN.md).

The current keychain inspection reported zero valid code-signing identities. The next stage needs a Developer ID Application identity and matching host, transparent and DNS profiles. With a verified signed build, obtain explicit approval for installation and activation on the test Mac. Live service testing and GitHub publication each require separate authorization. This development cycle made no changes to host DNS, proxy, routing, VPN, firewall, trust or login settings.
