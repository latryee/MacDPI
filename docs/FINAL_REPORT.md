# Final engineering report — MacDPI 0.1.0

Development and verification snapshot updated on 2026-11-04. This is an independently implemented native pre-release application, with local artifacts ready for review. Seamless all-application routing, native game/voice coverage and public release validation remain incomplete.

## 1. Executive summary

MacDPI now contains a real HTTP CONNECT forwarding engine and TLS record transformation, native SwiftUI views hosted by an explicit AppKit window/menu lifecycle, automated verification, release artifacts and open-source documentation. The existing Xcode project was retained. No privileged command, system proxy/DNS/route/firewall/VPN change, trust installation, extension activation or GitHub publication was performed.

## 2. Implemented features

Loopback listener; public HTTPS destination scope; strict request parsing; system or opt-in bounded Cloudflare HTTPS resolver with pinned numeric addresses; cancellable lookups; bounded backpressure; concurrency limits; initial/idle deadlines; half-close; disable/quit cleanup; restart; settings; menu bar and keyboard controls; light/dark appearance; readiness, routing status and sanitized aggregate diagnostics; macOS 14+ isolated HTTPS web window; optional launch-at-login API guarded to macOS 13+. Login registration was not exercised on the host.

## 3. Actual DPI strategies

Standard splits the first complete ClientHello record inside visible SNI, falling back to offset 32. Advanced uses a configured offset. Both preserve handshake payload bytes; local TLS 1.2/1.3 fixtures and certificate rejection pass. Compatibility forwards unchanged. Already fragmented, oversized, malformed and other first records fall back unchanged. No TCP packet-boundary, IP fragmentation, ECH inner-name, QUIC or universal-bypass claim is made. A limited real-network comparison passed Discord API/WebSocket and Roblox site/API with Standard plus DoH, while unchanged TLS timed out. Native web pages also rendered. See [REAL_NETWORK_VALIDATION.md](REAL_NETWORK_VALIDATION.md); native games, voice and full system-wide behavior remain incomplete.

## 4. macOS compatibility

Universal 2 app and separate provider both compile for arm64 and x86_64 with macOS 12.0 deployment metadata. Runtime validation covers only Apple Silicon/macOS 26.6. Intel and older-OS runtime tests remain unavailable. Original project format requires Xcode 27.2; portable compiler scripts avoid that project-format dependency but older toolchain execution is unverified. See [COMPATIBILITY.md](../COMPATIBILITY.md).

## 5. Build results

Swift package Debug/Release, native Debug, portable Universal 2 Release, Xcode Universal 2 Release archive, and separate Universal 2 provider compilation pass. App signature/resource/entitlement checks pass. ZIP, DMG and SHA-256 files are under `build/dist/`. The app is locally ad hoc signed, not Developer ID-signed/notarized. The provider is unsigned and omitted from the app bundle.

## 6. Test results

37 XCTest cases pass (28 core, 9 native model/UI). 23 integration scenarios pass. These include byte preservation, malformed input, concurrency, cancellation, timeouts, reset/failure recovery, queued/HTTPS DNS cancellation and response validation, active shutdown, same-port restart, memory samples, native/web window lifetime, light/dark screenshots and TLS 1.2/1.3 across all profiles. CI is prepared for Intel/Apple Silicon and an Xcode 27 UI runner, but was not executed remotely. See [TEST_RESULTS.md](../TEST_RESULTS.md).

## 7. Performance measurements

Enabled native idle: 0.250% CPU and 94.92 MiB RSS over 20.0 seconds. Disabled: 0.050% and 93.33 MiB. Headless paced transfer: 4.664% CPU at 6.25 MiB/s each direction. Median added local connect/echo time: 0.834 ms. Bulk echo: 447.3 MiB/s versus 1034.9 baseline (combined directions). The loopback benchmark ran alongside UI tests; default native idle was sampled afterward. Optional website/WebKit process memory is outside that idle sample. These are bounded synthetic measurements with limits documented in [PERFORMANCE.md](../PERFORMANCE.md).

## 8. Security review

Sandboxed app; least-privilege network-only entitlements; loopback-only listener; strict destination and DNS pinning policy; bounded parsing and admission; no private traffic logs, telemetry, relays, credentials, certificate installation or TLS termination. Queue/actor ownership and cancellation were reviewed and tested. Other local processes can access this unauthenticated proxy; it is not a local authorization boundary. An in-progress OS DNS lookup cannot be interrupted. The review is not an independent security audit. See [SECURITY.md](../SECURITY.md) and [PRIVACY.md](../PRIVACY.md).

## 9. Remaining limitations

Broad DPI coverage, native Roblox gameplay/Discord voice UDP, provider entitlement/provisioning and runtime lifecycle, Intel/older-OS execution, launch-at-login registration, IPv6/NAT64 routing environments, long battery/soak behavior and public Gatekeeper acceptance remain unverified. No DoT, automatic profile selection, SOCKS, plaintext HTTP forwarding or UDP/HTTP3 processing is implemented. Local mode applies only to explicitly configured apps or the optional proxied web window. Enable alone never routes other applications. The original seamless all-app objective is not complete; [NETWORK_SETUP_PLAN.md](NETWORK_SETUP_PLAN.md) separates the owner-approved HTTPS proxy test from the still-unavailable native game/voice integration.

## 10. GitHub release readiness

Required documentation, MIT license, native screenshots, community/security policies, issue/PR templates, pinned CI actions, archives, ZIP/DMG/checksum tools, versioning, signing/notarization preparation and verification are present. Source is left as reviewable working-tree changes; no commit, push, tag, upload or public release was made. A public download still requires maintainer review, private security/conduct contact configuration, signing/notarization and additional runtime validation.

## 11. Operations requiring explicit approval or external capabilities

| Operation | Why / permission | Risk | Reversal / evidence already available |
| --- | --- | --- | --- |
| Register and activate the optional transparent system extension | Test real other-app TCP flow interception; requires explicit permission, Developer Program entitlements, matching profiles, Developer ID signing and OS approval | Interruptions, application/VPN/filter incompatibility; fail-open exclusions | Stop/disable/remove its manager preferences, then approved OS deactivation/removal. Only compile and isolated shared-core tests are verified. |
| Change any host-wide proxy, DNS, routing, VPN or firewall configuration | Not needed for local mode; would require a separate explicit request | Disrupt other apps or persist incorrect settings | Record and restore original settings. No such changes were made. |
| Sign with a private identity and submit to Apple | Establish publisher identity and notarization; requires owner-supplied credentials and authorized upload | Credential misuse or distributing an unreviewed artifact | Replace/revoke erroneous release as appropriate; rebuild and reverify. Local ad hoc signatures/checksums already pass. |
| Publish/push to GitHub or create a release | Public distribution requires explicit authorization and a chosen repository | Public disclosure of unrevised source or artifacts | Remove/replace publication; public copies may persist. Review files/artifacts are prepared locally only. |
| Register launch at login | Test opt-in per-user startup behavior; user action/approval required | Unexpected future app launch | Unregister or remove Login Item in System Settings. Feature code is compiled but registration was not performed. |

Real-network effectiveness should only be tested with a selected, consenting test environment and endpoints. No system-wide activation is needed to inspect or run the local implementation. See [INSTALLATION.md](../INSTALLATION.md) for the extension prerequisites and removal procedure.

## 12. Open and run

Open `MacDPI.xcodeproj` in Xcode 27.2 and select MacDPI, or run `scripts/build-app.sh`. Open `build/release/MacDPI.app`, enable the local listener, and explicitly configure the desired application's HTTP CONNECT proxy as `127.0.0.1:8080`. A command-scoped example is in README.md. Disable closes all local flows; restore any per-app proxy setting you selected. Closing the window leaves the menu bar utility running; normal Quit waits for engine shutdown.

On macOS 14+, the proxied web window provides a session without changing system settings. Choose Standard plus optional Cloudflare DNS over HTTPS when DNS filtering is present. This path rendered Discord and Roblox during the limited check. It does not route native games or voice UDP.

Full build/test/release commands are in [BUILDING.md](../BUILDING.md). The distributable local review artifact names explicitly include `local-adhoc` and must not be presented as notarized public releases.

## Final cleanup requested by the user

Removed approximately 901 MiB of obsolete/generated build caches, staging folders, old test bundles, profiler output and intermediate binaries. The current source, tests, documentation, real window screenshots and latest sanitized verification summaries remain. Retained build outputs are exactly:

- `build/release/MacDPI.app`
- `build/dist/MacDPI-0.1.0-universal2-local-adhoc.zip`
- `build/dist/MacDPI-0.1.0-universal2-local-adhoc.dmg`
- `build/dist/MacDPI-0.1.0-universal2-local-adhoc.sha256`

Historical compilation/test success records remain valid; removed archive/test-cache paths must be regenerated before inspecting them. No project source or Git history was removed.
