# Changelog

## 0.3.0 personal TUN preview — v0.3.0-preview.1

- Build 8 recreates selectable diagnostics when report content changes and removes an explicit accessibility label that caused recursion on macOS 27. Exact UI assertions are preserved; TCP, UDP, TLS, DNS and route behavior are unchanged. All three release-source CI jobs passed: macOS 15 ARM/Intel isolated suites/builds, plus 29 model and three UI cases on macOS 27.0.1/Xcode 27.2. Its Universal 2 app, exact ZIP/DMG contents, signatures and SHA-256 checksums passed local verification; the packaged engine passed three absent-broker cancellation checks. Live evidence below belongs to the stated earlier builds; no build 8 live TUN run is claimed. [Downloads](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1)
- Added a separate ad hoc build with an unprivileged dual-stack TCP/UDP engine and session-scoped route helper.
- Added guarded route plans, durable ownership records and recovery checks. Preserved local diagnostics and the optional signed Network Extension build.
- Added automatic macOS administrator authorization with embedded helper hashes, private root staging and authenticated descriptor handoff. Normal Enable no longer needs a pasted Terminal command.
- Added Automatic setup and bounded, coalesced TLS origin repair lookups while preserving ordinary System DNS and end-to-end certificate validation.
- Added isolated packet, DNS, IPC, route, mixed-load and app lifecycle coverage. Earlier build 3 real-network trials verified GUI activation/Disable, public HTTPS/API and unauthenticated WebSocket requests. An older build 3 stop remains unexplained.
- Build 4 added on-demand app/engine CPU and RSS display, with unavailable/stale samples handled explicitly and no resource polling while idle. Its 126 core and 27 hosted model tests passed; its owner-participated live evidence used build 3.
- Build 5 adopted neutral wording for cleanup-confirmed failures instead of attributing an unknown stop to the helper.
- Build 6 added fixed-category local failure diagnostics. Worker categories require a failed final session outcome; normal stop/cancellation does not produce a worker-failure log. Stop before readiness is normal cancellation, and known-lease detach is verified even without ownership or a journal.
- Build 6 passed 130 core, 27 hosted model and 14 packaging cases, 23 Debug CLI scenarios and four native TCP/UDP IPv4/IPv6 scenarios. Full Go, 15-second mixed traffic per family, synthetic IPv4 96-TCP/64-UDP capacity, UDP lifecycle/race and native IPC checks passed. Overview/Settings were manually checked while Disabled without changing settings.
- Build 6 passed a bounded owner-approved GUI trial: Discord messaging/two-way audio and voice rejoining, Roblox gameplay/rejoining, 26 public HTTPS/API checks and all eight baseline fingerprints plus resolver restoration after Disable. No unexpected stop was observed. The monitored interval was about 25 min 44 s within a 30-minute setup/test/shutdown window. Combined sampled CPU averaged 0.231% of one core and peak RSS was 152.64 MiB with uncontrolled owner traffic. Exact 30-minute Active stability is not claimed.
- A separate build 6 practical quiet sample covered 61 samples over 121.27 seconds, averaging 0.066% combined CPU with 141.41 MiB peak RSS (148.28 MB). It met the resource targets only for that interval; cleanup passed, but sleep was not performed and compliance with that test's five-minute window was unproven. Added a non-root, best-effort operator deadline guard with four passing isolated tests. [Evidence and limits](docs/TUN_VERIFICATION.md#build-6-practical-idle-trial)
- Build 7 handles termination signals and parent disconnection through graceful shutdown, retaining the captured-child hard fallback after 28 seconds. It passed 29 hosted model, 14 packaging, four operator guard, 13 native stop-channel and three packaged-engine absent-broker cancellation checks. A later approved GUI trial verified 10.97 seconds of physical sleep, HTTPS/API before/after wake and graceful signal shutdown to Disabled, restoring all eight policy fingerprints, resolver, route, interface and owned processes. It completed in 149.75 seconds within a five-minute maximum. Build 6 voice/game evidence remains separate.

The preview is ad hoc signed and not notarized. Real TUN runtime evidence is limited to Apple Silicon/macOS 26.6. Physical Intel/older macOS, physical IPv6, extended daily reliability, abrupt crash recovery and network/VPN transitions remain unverified. [Compatibility](COMPATIBILITY.md) · [Verification](docs/TUN_VERIFICATION.md)

## 0.2.0 — local review

- Bundled transparent TCP/UDP and optional DNS system extensions for Intel and Apple Silicon.
- Connected native Enable, status, Disable, removal and emergency stop to the approved integration lifecycle.
- Added public numeric TCP/UDP flow policy, IPv4/IPv6 datagram forwarding and explicit DNS routing with split-domain preservation.
- Protected the optional local CONNECT listener with a per-launch credential and retained the existing TLS engine.
- Added isolated flow, DNS, lifecycle and packaging verification. Installed operation, Developer ID distribution and live desktop acceptance of these optional extension paths remained pending.

## 0.1.0 — unreleased

- Independent HTTP CONNECT TCP engine with strict loopback binding and public HTTPS scope.
- Standard/Advanced ClientHello TLS record splitting and Compatibility passthrough.
- Optional bounded Cloudflare DNS over HTTPS with TTL RAM cache, exact question/CNAME validation, cancellation and no silent system-DNS fallback.
- macOS 14+ isolated HTTPS web window; honest proxy-ready/routing status and setup guidance.
- Limited real-network Discord API/WebSocket and Roblox site/API comparison against unchanged TLS, with reproducible opt-in tooling.
- Bounded buffers, backpressure, concurrency and DNS admission, handshake/idle deadlines, half-close and shutdown/restart handling.
- Native SwiftUI dashboard, settings, menu bar, diagnostics, optional launch at login and explicit engine state.
- Universal 2 app and compile-only transparent system-extension provider.
- Local parser/lifecycle/model/UI/socket/TLS tests, reproducible benchmarks, CI and review packaging.
- MIT license, privacy/security documentation and release preparation.
