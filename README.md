# MacDPI

**0.3.0 Personal TUN preview** provides local TCP/UDP traffic handling without a paid Apple Developer membership, a remote VPN server or a separately installed DPI tool. Press **Enable**, approve macOS administrator authorization and use supported desktop applications without configuring their proxies. **Disable** releases the session's interface and routes. [Build, authorization and recovery](docs/PERSONAL_TUN.md).

On November 7, 2026, the owner confirmed bidirectional Discord audio and a Roblox game session while Automatic setup was active on the development Mac. Certificate-verified public HTTPS, the Discord API and an unauthenticated Gateway WebSocket also passed through the real tunnel. This is evidence from one Mac and network, not a guarantee for other providers or destinations. A 496-second process sample measured 0.41% combined CPU and 130.33 MiB peak RSS. [Current engineering report](docs/PERSONAL_REPORT_0.3.0.md), [verification scope](docs/TUN_VERIFICATION.md).

The personal build uses System DNS for ordinary traffic and selective Cloudflare DoH for eligible Discord/Roblox TLS origin repair. TCP ClientHello record splitting preserves the encrypted connection and client certificate checks. UDP datagrams pass unchanged; forwarding does not imply a general UDP or QUIC circumvention technique. [Privacy](PRIVACY.md), [compatibility](COMPATIBILITY.md).

Build the personal Universal 2 app, ZIP, DMG and checksums with full Xcode and Python 3:

```sh
scripts/fetch-tun-toolchain.sh
MACDPI_PERSONAL_TUN=1 MACDPI_BUILD_ROOT=build/personal scripts/package-release.sh --dmg
open build/personal/release/MacDPI.app
```

The compiler is fetched explicitly with a pinned checksum. Go and gVisor are linked into the bundled worker; users need no separate runtime installation. The app, helper and worker have arm64/x86_64 slices targeting macOS 12. Runtime evidence is currently Apple Silicon/macOS 26.6. The package is ad hoc signed, not Developer ID signed or notarized. If macOS declines a downloaded copy, build from reviewed source; do not weaken system security settings.

## Preserved Network Extension and local proxy builds

MacDPI is a native macOS utility for applying TLS ClientHello record splitting to supported outbound traffic. The 0.2.0 source and local review build bundle a transparent TCP/UDP system extension and an optional encrypted DNS extension. A provisioned and approved build is designed to route new flows from apps across the Mac through the **Enable** control. The available ad hoc package supports review and local diagnostics. Installed routing and native Discord and Roblox compatibility await real Mac testing.

- **Mac-wide integration** handles eligible public IPv4 and IPv6 TCP/UDP flows. TCP ports 443, 8443 and 9443 are eligible for TLS record splitting. Other supported TCP traffic and UDP payloads are forwarded unchanged.
- **System DNS** is the default. With separate authorization, the optional DNS provider sends eligible public DNS queries to Cloudflare over HTTPS. Local, split and interface-bound DNS keep their original resolver. A failed encrypted query returns failure.
- **Local proxy diagnostics** uses a credential-protected loopback HTTP CONNECT listener for public TCP 443. On macOS 14 and later, the optional proxied web window supplies those credentials automatically.
- **Compatibility** forwards bytes unchanged. **Standard** chooses a split inside the visible server name or at payload byte 32. **Advanced** uses the selected offset. End-to-end TLS certificate checks remain in the client.

The 0.1.0 local proxy reached selected Discord web/API and WebSocket endpoints and Roblox web/API endpoints on one network on November 4, 2026. That historical test did not establish voice, gameplay or desktop application routing. [Historical test evidence](docs/REAL_NETWORK_VALIDATION.md).

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

MacDPI uses direct connections and has no telemetry or external traffic relay. The personal worker includes Go/gVisor and bundled dependency notices; no external DPI executable or runtime download is used at application startup. TLS authentication stays with the client. Circumvention effectiveness depends on the network and protocol. [Current report](docs/PERSONAL_REPORT_0.3.0.md), [0.2.0 report](docs/FINAL_REPORT.md), [test results](TEST_RESULTS.md), [performance](PERFORMANCE.md), [architecture](ARCHITECTURE.md), [security](SECURITY.md), [privacy](PRIVACY.md).

MIT licensed.
