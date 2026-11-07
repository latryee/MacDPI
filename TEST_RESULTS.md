# MacDPI 0.2.0 verification

This is the preserved 0.2.0 baseline. Current personal TUN build, unit, synthetic, GUI and owner-participated service evidence is recorded in [0.3.0 verification](docs/TUN_VERIFICATION.md) and the [0.3.0 report](docs/PERSONAL_REPORT_0.3.0.md).

November 5, 2026 on Apple Silicon, macOS 26.6 (25G72), Xcode 27.2 (27B52) and Swift 6.4.2. Universal 2 packaging verifies both slices. Actual execution in this report uses the development Mac.

| Verification | Result |
| --- | --- |
| Swift package core | 97 tests passed |
| Hosted native model | 22 tests passed |
| Native UI | 3 tests passed |
| Isolated Release CLI integration | 23 scenarios passed |
| Native TCP and UDP transport loopback | 4 IPv4/IPv6 scenarios passed |
| Packaging and signing gates | 14 tests passed |
| Hosted native Xcode Debug and Release archive | Built locally |
| Portable release and packaged ZIP/DMG | Universal 2 host and two embedded providers. Local review signing |
| Installed provider operation and production distribution | Pending signatures, authorization and on-device tests |

The core count includes the preserved 28 tests, 38 lifecycle tests, 14 UDP tests, 13 DNS and flow-policy tests, and four CONNECT/TCP session regressions. Lifecycle tests exercise consent, delayed status, timeout, cancellation, recovery, pending removal and orphaned DNS. The new CONNECT tests prove that wrong or absent credentials block lookup, that authentication is not sent upstream, and that a server-first non-TLS flow survives the initial TLS deadline.

The hosted suite exposed a crash in the mode setter while integration was active. The guarded setter passed the same regression after correction. The UI exercises the real local listener, menu/window lifecycle, diagnostics and close-on-disable behavior of the optional web window. Test launches use isolated settings and never operate the OS provider configuration. The first unsigned UI runner could not launch. The isolated ad hoc signed test run passed.

The local integration suite exercises malformed requests, destination policy, resets, deadlines, 16 connections, half-close, active shutdown, restart and memory sampling. It verifies trusted TLS 1.2 and 1.3 across all three profiles and rejection of an untrusted origin certificate. The test trust is client-scoped. TLS 1.3 fixture identity material is loaded in memory on macOS 15 and later.

Native transport fixtures use the provider TCP C bridge and the production UDP socket adapter against independent loopback servers. Both address families complete 8 MiB per TCP direction with delayed-reader backpressure and a post-FIN trailer. Both UDP fixtures preserve seven datagrams, including empty datagrams and a 65,507-byte payload. Fixture tests do not create an OS-supplied Network Extension flow. [Native adapter research](docs/APPLE_INTEGRATION_RESEARCH.md).

The local verification checks bundle identifiers, versions, architectures, scoped entitlements, provider classes, signatures and matched packaged contents. Developer ID profile validation is exercised with isolated fixtures. The supported build uses Swift 5 language mode and emits Swift 6 migration warnings in a few Network Extension callbacks. Apple's actual signing, notarization, extension approval, OS rollback, Intel runtime, older OS runtime and GitHub workflows remain unverified.

The earlier 0.1.0 live check and its raw data remain separate. No new live Discord, Roblox, gameplay, voice, authenticated or public-endpoint test was run for 0.2.0. [Historical live scope](docs/REAL_NETWORK_VALIDATION.md).

Reproduce with the commands in BUILDING.md. Versioned sanitized results remain in the repository. Temporary log and profiler products are disposable. [Machine-readable summary](docs/verification/0.2.0-test-summary.json), [performance](PERFORMANCE.md).
