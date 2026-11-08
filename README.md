# MacDPI

A native, open-source macOS DPI circumvention app for supported desktop traffic.

**0.3.0 Personal TUN preview** uses a local virtual interface, direct TCP/UDP forwarding and TLS ClientHello record splitting. Open the app, press **Enable**, approve macOS authorization and use supported applications without configuring their proxies. No paid Apple Developer membership, remote VPN server or separately installed DPI tool is required.

**Current status:** build 7 is a locally verified testing preview. Build 6 passed personal acceptance on one Mac/network. The owner confirmed Discord messaging, two-way audio, a Roblox game and rejoining both services. An approved bounded trial completed with verified cleanup and no unexpected stop observed. An older build 3 stop remains unexplained; extended daily reliability is not established. [Detailed evidence](docs/TUN_VERIFICATION.md) · [Engineering report](docs/PERSONAL_REPORT_0.3.0.md)

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

These paths describe generated artifacts, not published downloads. The current build 7 artifacts have not been uploaded or published.

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
| Personal application use | On build 6, the owner confirmed Discord messaging/two-way audio, a real Roblox game, voice rejoining with two-way audio and Roblox rejoining. The owner reported no noticeable delay; RTT and exact application-use minutes were not quantified. |
| Real network integration | Build 6 completed 13 rounds of 26 certificate-verified public HTTPS/API requests while the public route used the tunnel. GUI Disable verified cleanup; all eight policy fingerprints and the resolver matched the baseline. Unauthenticated WSS evidence belongs to the earlier build 3 trial. |
| Local correctness | Build 7 passed 29 hosted model, 14 packaging, four operator guard and 13 native stop-channel cases; its packaged engine passed three unprivileged cancellation checks. Unchanged core/data-plane checks from build 6 include 130 Swift core cases. The full Go suite, 15-second mixed runs per family, synthetic IPv4 96-TCP/64-UDP capacity, UDP lifecycle/race and native IPC checks passed. [Current results](docs/TUN_VERIFICATION.md) |
| Current loopback integration | 23 scenarios passed with the current Debug CLI, plus four native TCP/UDP IPv4/IPv6 scenarios. These do not activate real capture routes. |
| Build and packaging | Universal 2 signatures and exact extracted ZIP/DMG contents verified. [Current package record](docs/verification/0.3.0-release-readiness.json) |
| Live resource sample | 307 samples covered 1543.679 seconds, about 25 min 44 s, while build 6 was enabled with uncontrolled owner traffic. App/engine/helper averaged 0.231% of one CPU core and peaked at 152.64 MiB combined sampled RSS, about 160.1 MB. This is not a strict idle, battery or physical-footprint benchmark. [Measurements](PERFORMANCE.md) |
| Practical idle sample | A separate 61-sample, 121.27-second foreground-quiet interval averaged 0.066% combined CPU and peaked at 141.41 MiB RSS, about 148.28 MB. It met the below-1%/below-150 MB targets in this sample only; background OS traffic may remain. Sleep was not tested, and the operator could not establish compliance with this test's five-minute shutdown window. [Scope and timing](docs/verification/0.3.0-build6-idle.json) |

Build 6 now has an owner-approved GUI-driven live trial as well as local and packaging verification. That voice/game trial's 30-minute authorization window included setup and shutdown; the monitored enabled interval was about 25 min 44 s, not an exact 30-minute Active stability test. The three automated native UI cases remain a prior run, not a rerun for build 6. [Voice/game trial](docs/verification/0.3.0-build6-live-personal.json). The late unexpected stop is recorded in [the follow-up report](docs/verification/0.3.0-late-stop.json).

## Limits and troubleshooting

Circumvention depends on the network, application and filtering method. It does not guarantee access to every site or protocol. Encrypted or absent visible server names can prevent selective repair. Existing VPNs, filters and split-DNS policies can affect coverage; detected conflicts can prevent activation or stop a session.

An exact 30-minute Active stability run, sleep/wake, network/VPN switching, deliberate crash recovery, broader reconnect coverage and quantified voice/game latency still need dedicated validation. The successful bounded trial does not explain or prove a fix for the older stop, or establish general reliability.

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
python3 scripts/test-tun-stop-channel.py
python3 -m unittest discover -s Tests/PackagingTests
```

The worker tests require the pinned compiler fetched above. Hosted model/UI checks, benchmarks and deliberately authorized live tests are documented in [BUILDING.md](BUILDING.md), [PERFORMANCE.md](PERFORMANCE.md) and [the verification report](docs/TUN_VERIFICATION.md). Live account, microphone and game tests require the user's participation.

## Other modes and contributing

The source preserves the authenticated local HTTP CONNECT proxy and optional Network Extension providers. They are independent modes; the personal TUN package omits those extensions. The local proxy handles only explicitly configured clients, and the optional system extensions have their own provisioning and approval requirements. [Preserved 0.2.0 report](docs/FINAL_REPORT.md)

Bug reports and testing on additional Mac/network combinations are welcome. Include the build, macOS version, architecture, mode and sanitized diagnostics; keep credentials and private traffic out of reports. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues through the process in [SECURITY.md](SECURITY.md).

MacDPI is [MIT licensed](LICENSE). Go, gVisor and transitive dependencies retain their own licenses; their notices ship in `MacDPI.app/Contents/Resources/TUNLicenses`.
