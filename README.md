# MacDPI

MacDPI is a native macOS utility for applying TLS ClientHello record splitting to supported outbound traffic. The 0.2.0 source and local review build bundle a transparent TCP/UDP system extension and an optional encrypted DNS extension. A provisioned and approved build is designed to route new flows from apps across the Mac through the **Enable** control. The available ad hoc package supports review and local diagnostics. Installed routing and native Discord and Roblox compatibility await real Mac testing.

- **Mac-wide integration** handles eligible public IPv4 and IPv6 TCP/UDP flows. TCP ports 443, 8443 and 9443 are eligible for TLS record splitting. Other supported TCP traffic and UDP payloads are forwarded unchanged.
- **System DNS** is the default. With separate authorization, the optional DNS provider sends eligible public DNS queries to Cloudflare over HTTPS. Local, split and interface-bound DNS keep their original resolver. A failed encrypted query returns failure.
- **Local proxy diagnostics** uses a credential-protected loopback HTTP CONNECT listener for public TCP 443. On macOS 14 and later, the optional proxied web window supplies those credentials automatically.
- **Compatibility** forwards bytes unchanged. **Standard** chooses a split inside the visible server name or at payload byte 32. **Advanced** uses the selected offset. End-to-end TLS certificate checks remain in the client.

The 0.1.0 local proxy reached selected Discord web/API and WebSocket endpoints and Roblox web/API endpoints on one network on November 4, 2026. Voice, gameplay and desktop application routing require separate acceptance tests. [Historical test evidence](docs/REAL_NETWORK_VALIDATION.md).

On a Mac with full Xcode and Swift 5.9 or later:

```sh
scripts/build-app.sh
open build/release/MacDPI.app
```

To try the local review build, select **Settings → Operation → Local proxy diagnostics**, return to Overview and press **Enable**. To use Mac-wide integration, follow the signing and approval steps. Both the host and its two extensions compile for Intel and Apple Silicon with a macOS 12 deployment target. Runtime evidence is limited to the development Mac. [Installation and recovery](INSTALLATION.md), [build and signing instructions](BUILDING.md), [compatibility matrix](COMPATIBILITY.md).

Run controlled tests and prepare review packages:

```sh
scripts/test.sh
scripts/package-release.sh --existing --dmg
```

MacDPI uses Apple frameworks and direct connections. It has no telemetry, external traffic relay or third-party runtime dependencies. It preserves TLS authentication and retains only aggregate diagnostics. Circumvention effectiveness depends on the network and protocol. [Engineering report](docs/FINAL_REPORT.md), [test results](TEST_RESULTS.md), [performance](PERFORMANCE.md), [architecture](ARCHITECTURE.md), [security](SECURITY.md), [privacy](PRIVACY.md).

MIT licensed.
