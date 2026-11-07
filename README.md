# MacDPI

A native, open-source macOS DPI circumvention app for supported desktop traffic.

**0.3.0 Personal TUN preview** uses a local virtual interface, direct TCP/UDP forwarding and TLS ClientHello record splitting. Open the app, press **Enable**, approve macOS authorization and use supported applications without configuring their proxies. No paid Apple Developer membership, remote VPN server or separately installed DPI tool is required.

**Current status:** this is a testing preview. Discord two-way audio and a Roblox game session were confirmed by the owner on one Mac/network. A later session stopped unexpectedly with verified cleanup; its cause is unresolved. Extended daily reliability is not yet verified. [Detailed evidence](docs/TUN_VERIFICATION.md) · [Engineering report](docs/PERSONAL_REPORT_0.3.0.md)

## What it does

- Handles eligible public TCP and UDP traffic through a local Darwin `utun` interface.
- Applies the existing Swift TLS record transformation to applicable TCP connections. The client still verifies the origin certificate.
- Defaults to **Automatic setup**: Standard TLS handling, ordinary System DNS and selective validated Cloudflare DNS-over-HTTPS for eligible Discord/Roblox TLS origin repair.
- Keeps private/protected networks outside its capture plan. It leaves original default routes, DNS, proxy and VPN settings as found.
- Runs the interface and route helper with per-session administrator authorization. The app and traffic engine stay unprivileged.
- Provides menu bar controls, diagnostics, recovery guidance and an on-demand app/engine CPU and memory sample.

Traffic goes directly to destination servers. MacDPI is not a remote VPN and does not hide your public IP. UDP payloads pass unchanged; UDP forwarding is not a general UDP or QUIC bypass technique.

## Build and open

Use a Mac with **full Xcode** selected and **Python 3**. The checked build used Xcode 27.2. From a reviewed source checkout:

```sh
scripts/fetch-tun-toolchain.sh
MACDPI_PERSONAL_TUN=1 MACDPI_BUILD_ROOT=build/personal scripts/package-release.sh --dmg
open build/personal/release/MacDPI.app
```

The fetch step explicitly downloads a pinned Go compiler and checks its published SHA-256. Go and gVisor are linked into the bundled worker; the finished app needs no separate Go installation or runtime download.

**Disable and quit a running MacDPI copy before replacing it.** Use a separate `MACDPI_BUILD_ROOT` when developing alongside a running session. [Build guide](BUILDING.md)

The build produces these local files:

| Artifact | Path |
| --- | --- |
| Application | `build/personal/release/MacDPI.app` |
| DMG | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.dmg` |
| ZIP | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.zip` |
| SHA-256 checksums | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.sha256` |

Verify the archives after building:

```sh
cd build/personal/dist
shasum -a 256 -c MacDPI-0.3.0-universal2-personal-adhoc.sha256
```

These paths describe generated artifacts, not published downloads. The build 6 artifacts have not been uploaded or published.

### Signing and compatibility

The personal app is **ad hoc signed, not Developer ID signed or notarized**. If macOS declines a downloaded copy, build from reviewed source. Do not disable Gatekeeper, SIP or certificate validation.

The app, helper and worker contain **arm64 and x86_64** slices targeting **macOS 12.0**. Runtime testing is currently limited to Apple Silicon on macOS 26.6. Intel, older macOS and physical IPv6 remain unverified. [Compatibility matrix](COMPATIBILITY.md)

## Use the app

1. Open `MacDPI.app` and leave **Automatic setup** selected.
2. Press **Enable** and approve the macOS administrator dialog. It may identify Apple's script runner as `osascript`; macOS handles the credentials.
3. Wait for **Active**, then test new application connections. Normal use needs no pasted Terminal command or per-app proxy setup.
4. Use **Measure usage** for a short CPU/RSS sample. It covers the app and its unprivileged engine; the session helper is excluded and the scope is displayed. It does not start continuous resource polling.
5. Press **Disable** when finished and wait for verified interface/route release. Closing the main window leaves an enabled session available through the menu bar.

Enable temporarily adds MacDPI-owned capture routes. Disable releases the session's interface and checks that those routes are gone. If cleanup cannot be confirmed, the app shows **Recovery required**. [Operation, removal and recovery](INSTALLATION.md) · [Personal TUN guide](docs/PERSONAL_TUN.md)

## What has been verified

| Area | Evidence |
| --- | --- |
| Personal application use | The owner confirmed Discord audio in both directions and joining and remaining in a Roblox game on the development Mac/network. |
| Real network integration | GUI activation through macOS authorization, captured public routes, certificate-verified HTTPS/API/WSS and helper-confirmed Disable. An earlier short GUI trial matched all eight baseline policy fingerprints after cleanup. |
| Local correctness | Build 6 passed 130 Swift core, 27 hosted model and 14 packaging cases. The full Go suite, 15-second mixed runs per family, synthetic IPv4 96-TCP/64-UDP capacity, UDP lifecycle/race and native IPC checks passed. [Current results](docs/TUN_VERIFICATION.md) |
| Current loopback integration | 23 scenarios passed with the current Debug CLI, plus four native TCP/UDP IPv4/IPv6 scenarios. These do not activate real capture routes. |
| Build and packaging | Universal 2 signatures and exact extracted ZIP/DMG contents verified. [Current package record](docs/verification/0.3.0-release-readiness.json) |
| Short resource sample | Over 496 seconds with uncontrolled owner traffic, the app/engine/helper averaged 0.411% of one CPU core and peaked at 130.33 MiB combined RSS. This is not a strict idle or long-term benchmark. [Measurements](PERFORMANCE.md) |

The voice/game trial used build 3. Build 6 has separate local, lifecycle and packaging verification; it has not been counted as another live service trial. Three native UI cases passed in a prior run. The current interactive check was unavailable because the test Mac was locked, which is not a test failure. The late unexpected stop is recorded in [the follow-up report](docs/verification/0.3.0-late-stop.json).

## Limits and troubleshooting

Circumvention depends on the network, application and filtering method. It does not guarantee access to every site or protocol. Encrypted or absent visible server names can prevent selective repair. Existing VPNs, filters and split-DNS policies can affect coverage; detected conflicts can prevent activation or stop a session.

Thirty-minute stability, sleep/wake, network/VPN switching, deliberate crash recovery, reconnect behavior and quantified voice/game latency still need dedicated real-world validation. The unresolved later stop prevents a general reliability claim.

| Symptom | Next step |
| --- | --- |
| Awaiting authorization | Complete the macOS dialog. If canceled or expired, retry Enable when ready. |
| Failed, with verified cleanup | Review the current connection and diagnostics before retrying. Repeated stops should be reported with the build, macOS version, architecture and sanitized diagnostic report. |
| Recovery required | Keep the tunnel disabled and follow the ownership-specific recovery guide. Do not flush unrelated routes or reset all network settings. |
| A site, voice or game still fails while Active | Check Automatic setup and the compatibility limits. Test website access, desktop connectivity, two-way audio and an actual game separately. |
| macOS declines the package | Build from reviewed source or use a genuinely notarized release when one exists. |

[More troubleshooting](TROUBLESHOOTING.md) · [Route ownership and recovery](docs/TUN_ROUTE_SAFETY.md)

## Privacy and security

MacDPI has no telemetry, advertising, accounts or external traffic relay. It does not install trusted certificates, decrypt TLS traffic, store passwords or collect browsing history.

Automatic TLS origin repair can send eligible visible Discord/Roblox names to Cloudflare over HTTPS. Cloudflare receives those DNS questions and the source IP. Ordinary DNS retains its existing system path. Explicit encrypted lookup failures do not silently downgrade.

The privileged helper is session-scoped and authenticates its worker. It installs no persistent root daemon or passwordless sudo rule. The private recovery journal records owned interface/routes. Review the [privacy policy](PRIVACY.md), [security policy](SECURITY.md) and [architecture](ARCHITECTURE.md) before authorizing a build.

Caught TUN failures can write fixed categories to the Mac's local unified log for troubleshooting. Those entries contain no endpoints, DNS names, configuration values or payloads. MacDPI does not upload these entries; macOS controls their retention and access.

## Run safe tests

The normal suites use synthetic packets and loopback fixtures. They do not activate a real TUN interface or change host networking:

```sh
swift test --scratch-path build/swift
scripts/test-tun-worker.sh
scripts/test-tun-ipc.sh
python3 -m unittest discover -s Tests/PackagingTests
```

The worker tests require the pinned compiler fetched above. Hosted model/UI checks, benchmarks and deliberately authorized live tests are documented in [BUILDING.md](BUILDING.md), [PERFORMANCE.md](PERFORMANCE.md) and [the verification report](docs/TUN_VERIFICATION.md). Live account, microphone and game tests require the user's participation.

## Other modes and contributing

The source preserves the authenticated local HTTP CONNECT proxy and optional Network Extension providers. They are independent modes; the personal TUN package omits those extensions. The local proxy handles only explicitly configured clients, and the optional system extensions have their own provisioning and approval requirements. [Preserved 0.2.0 report](docs/FINAL_REPORT.md)

Bug reports and testing on additional Mac/network combinations are welcome. Include the build, macOS version, architecture, mode and sanitized diagnostics; keep credentials and private traffic out of reports. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues through the process in [SECURITY.md](SECURITY.md).

MacDPI is [MIT licensed](LICENSE). Go, gVisor and transitive dependencies retain their own licenses; their notices ship in `MacDPI.app/Contents/Resources/TUNLicenses`.
