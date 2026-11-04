# Verification results — 2026-11-04

Environment: Apple Silicon, macOS 26.6 (25G72), Xcode 27.2 (27B52), Apple Swift 6.4.2. App/provider deployment target 12.0; hosted Xcode test target 14.0. These are actual local results. Intel and older macOS runtime results are not available.

## Builds and artifacts

| Verification | Result |
| --- | --- |
| Swift package Debug + Release core/CLI | Pass |
| Original Xcode native Debug application | Pass |
| Xcode Universal 2 Release archive | Pass during verification; archive cache removed after verification |
| Portable native Universal 2 Release application | Pass; `build/release/MacDPI.app` |
| Separate provider arm64 + x86_64 build | Pass; unsigned, compile-only, not embedded/activated |
| Local ad hoc signature, strict resource integrity and entitlement verification | Pass |
| Release ZIP, compressed DMG and SHA-256 verification | Pass; local review artifacts only |
| Source shell/Python syntax and XML property lists | Pass |
| Repository whitespace verification | Pass |
| Developer ID signing / Apple notarization / Gatekeeper release acceptance | Not performed; credentials and authorization unavailable |
| GitHub workflows and public release | Prepared, not run remotely or published |

The application and provider both contain `arm64` and `x86_64` slices. `LC_BUILD_VERSION`/deployment compilation are evidence of a 12.0 target, not a successful runtime test of Monterey or Intel hardware.

## Automated tests

**37 XCTest cases pass:** 28 Swift package tests, 6 hosted model tests, and 3 native UI tests. **23 loopback integration scenarios pass**, with an additional paced-transfer benchmark checking every received byte. No normal test changes host networking, installs certificates, or activates an extension.

The core suite exercises configuration bounds and encoding, strict CONNECT/IPv6 parsing, smuggling/credential rejection, public/private address rules, every partial prefix of a generated ClientHello, SNI split placement, transcript and tail preservation, advanced offset clamping, identity fallback, compatibility, byte-at-a-time input, incomplete EOF, bounded-prefix handling with a large tail, 4,000 deterministic untrusted-input cases, startup cancellation, duplicate enable, stop, repeated restart, resolver failure delivery, skipping queued DNS after cancellation and dropping an in-flight cancelled result.

Nine additional encrypted-DNS tests cover wire queries, compressed A/AAAA answers, exact-question/CNAME ownership, private-address rejection, pointer/truncation/size bounds, mutation/random-input stress, coalescing/cache behavior, no system fallback, cancellation of shared tasks, stale-generation suppression, legacy configuration migration, cancellation-handler ordering, and HTTP response type/status/streaming-size rejection using an injected URLProtocol. These tests use no external service.

The model suite checks disabled/starting/enabled/failed state consistency, invalid settings, unsafe saved settings, honest readiness reports, shutdown, and ignoring a late completion after cancelling startup. The UI suite launches the actual app, enables/disables its real listener, runs diagnostics, closes/reopens the dashboard through native keyboard menu commands, and captures window-only screenshots in both light and dark appearance. Those screenshots were visually inspected; they contain no desktop background or unrelated application windows.

The new UI case opens the isolated web window without loading a site and verifies that engine disable closes it. UI engine tests use separate explicit unprivileged ports so an already-running local release does not cause a false startup failure. A compile error from explicit module-import checking and an accessibility assertion on merged SwiftUI text were found, corrected, and retested.

Integration scenarios cover:

1. CONNECT with pipelined tunnel bytes.
2. System resolver lookup of localhost and pinned numeric-address forwarding.
3. Sixteen stream transfers with eight concurrent workers; 4 MiB sent with byte equality checks.
4. Half-close preserving final server response bytes.
5. Malformed CONNECT rejection.
6. Disallowed destination-port rejection.
7. Repeated reset handling and subsequent recovery.
8. 150 sequential connections with before/after memory samples.
9. Stop releasing listener and active session state.
10. Private destination rejection with the production policy.
11. Capacity limit, initial deadline and subsequent capacity recovery.
12. Idle tunnel deadline.
13. Disable cancelling an active tunnel.
14. Same-port restart after an active tunnel is shut down.
15. Failed destination connect closing promptly.
16. Incomplete TLS handshake deadline.
17–19. Certificate-verified TLS 1.2 fixture handshakes through Standard, Compatibility and Advanced.
20. Untrusted origin certificate remains rejected by the client.
21–23. TLS 1.3 fixture handshakes through all three profiles; transformation counters confirm Standard/Advanced reframing and Compatibility passthrough.

TLS 1.2 uses Python's SSL fixture. Xcode's bundled Python links an SSL library without TLS 1.3, so TLS 1.3 uses a native Network.framework loopback server and system openssl client. The native fixture loads its generated identity with `kSecImportToMemoryOnly` on macOS 15+. Trust for the generated certificate is scoped to the test client; no keychain or system trust import occurs.

## Evidence and reproduction

Run `scripts/test.sh` for core tests, Release CLI, native fixture, integration and Universal 2 compilation. Hosted/native UI tests use the Xcode command in BUILDING.md. Run `scripts/archive.sh` and `scripts/package-release.sh --dmg` for review artifacts.

Sanitized integration/resource results and the final test summary are retained under `docs/verification/`. After verification, the user requested removal of old builds and generated files. Detailed logs, `.xcresult` bundles, profiler stacks, intermediate archives and caches were removed, including recordings that could contain desktop context. Only the latest app under `build/release/` and its ZIP, DMG and checksum under `build/dist/` remain as build outputs. All source, tests, documentation and native window screenshots are preserved; the documented commands regenerate the removed verification artifacts.

During development, tests found and drove fixes for refused connections stuck in Network.framework's waiting state, startup cancellation races, half-close cleanup, initial-flight accounting, and window restoration. The final native window lifetime is explicitly owned by AppKit, with SwiftUI rendering the interface. Unchanged counter snapshots no longer trigger published UI updates. Asset dimensions and release entitlement extraction were also corrected and reverified.

## Not established by these tests

A separate, explicitly invoked real-network check passed Discord API/WebSocket and Roblox site/public API connections using Standard plus DoH, while unchanged TLS with the same resolver timed out. The native proxied web window rendered the Discord login and Roblox home/signup pages. [Exact evidence, reproducible command and limitations](docs/REAL_NETWORK_VALIDATION.md). No authenticated account operation, game session or voice call was performed.

Universal DPI effectiveness, transparent provider activation/stop/crash semantics, native game/voice UDP, Intel runtime behavior, older OS runtime behavior, launch-at-login registration, notarization, long-duration battery use, maximum-256-connection soak, NAT64/IPv6 network routing, QUIC or HTTP/3 behavior remain unverified or unsupported. No unsupported feature is counted as a passing test. Performance evidence and its limits are in PERFORMANCE.md.

The earlier cleanup reclaimed approximately 901 MiB. After the encrypted-DNS and real-network follow-up, another 487.4 MiB of temporary build/test data was removed. Only the latest app, ZIP, DMG and checksum remain under `build/`. Retained artifacts were rechecked for code-signature/resource integrity, matching SHA-256 checksums, ZIP/app content equality and DMG integrity after cleanup.
