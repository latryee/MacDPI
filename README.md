# MacDPI

A native, open-source macOS DPI circumvention app for supported desktop traffic.

**0.3.0 Personal TUN preview, build 8** uses a local virtual interface, direct TCP/UDP forwarding and TLS ClientHello record splitting. Open the app, press **Enable**, approve macOS authorization and use supported applications without configuring their proxies. No paid Apple Developer membership, remote VPN server or separately installed DPI tool is required.

This is a **testing preview**. Personal voice/game use and a short physical sleep/wake test passed on one Apple Silicon Mac/network with earlier builds. Extended daily reliability and physical Intel operation remain unverified. Build 8 fixes selectable diagnostics accessibility; its traffic handling is unchanged. [Evidence and limits](docs/TUN_VERIFICATION.md) · [Engineering report](docs/PERSONAL_REPORT_0.3.0.md)

## Download

Use the explicit [0.3.0 preview release](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1), which contains build 8. This is a prerelease, so GitHub's latest-release shortcut does not identify it.

| Download | Use |
| --- | --- |
| [Universal 2 DMG](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.dmg) | Open the disk image and copy `MacDPI.app` to Applications |
| [Universal 2 ZIP](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.zip) | Alternative application archive |
| [SHA-256 checksums](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.sha256) | Verify the downloaded archives |

Download both archives and the checksum file into one directory, then verify them there:

```sh
shasum -a 256 -c MacDPI-0.3.0-universal2-personal-adhoc.sha256
```

**Disable and quit a running MacDPI copy before replacing it.** The app is **ad hoc signed, not Developer ID signed or notarized**. If macOS declines the download, build from reviewed source. Do not disable Gatekeeper, SIP or certificate validation.

The app, helper and worker contain **arm64 and x86_64** slices targeting **macOS 12.0**. Real TUN operation has been tested only on Apple Silicon/macOS 26.6. Automated CI on other systems is isolated testing, not proof of physical Intel or older-macOS TUN operation. [Compatibility matrix](COMPATIBILITY.md) · [Build from source](BUILDING.md)

## Use the app

1. Open `MacDPI.app` and leave **Automatic setup** selected.
2. Press **Enable** and approve the macOS administrator dialog. It may identify Apple's script runner as `osascript`; macOS handles the credentials.
3. Wait for **Active**, then test new application connections. Normal use needs no pasted Terminal command or per-app proxy setup.
4. Use **Measure usage** for a short app/engine CPU and RSS sample. Its displayed scope excludes the session helper; it does not start continuous resource polling.
5. Press **Disable** when finished and wait for verified interface/route release. Closing the main window leaves an enabled session available through the menu bar.

Enable temporarily adds MacDPI-owned capture routes for eligible public TCP/UDP traffic. Private/protected networks stay outside the capture plan. Original default routes, DNS, proxy and VPN settings are preserved. If cleanup cannot be confirmed, the app shows **Recovery required**. [Operation, removal and recovery](INSTALLATION.md) · [Personal TUN guide](docs/PERSONAL_TUN.md)

## What has been verified

| Area | Evidence and scope |
| --- | --- |
| Build 8 package and CI | Universal 2 app signatures, exact extracted ZIP/DMG contents and SHA-256 checksums verified locally. All three CI jobs passed: macOS 15 ARM/Intel isolated suites and builds, plus 29 model and three UI cases on macOS 27.0.1/Xcode 27.2. The packaged engine passed three absent-broker cancellation checks. Manual Overview/Diagnostics inspection remained Disabled. No build 8 live TUN trial is claimed. [CI run](https://github.com/latryee/MacDPI/actions/runs/42500004385) · [Package record](docs/verification/0.3.0-release-readiness.json) |
| Personal application use — build 6 | The owner confirmed Discord messaging, two-way audio and voice rejoining, plus real Roblox gameplay and rejoining. All 26 certificate-verified public HTTPS/API checks passed during about 25 min 44 s of monitored use. Disable restored all eight policy fingerprints and the resolver baseline. Exact application-use minutes and voice/game RTT were not measured. [Live record](docs/verification/0.3.0-build6-live-personal.json) |
| Sleep/wake and shutdown — build 7 | The same app, engine, helper and capture route survived 10.97 s of measured physical sleep. Public HTTPS/API passed before and after wake; graceful signal shutdown reached Disabled and independently restored policy fingerprints, resolver, route, interface and owned processes. The workflow completed in 149.75 s within its five-minute limit. [Sleep/shutdown record](docs/verification/0.3.0-build7-sleep-shutdown.json) |
| Local correctness | Synthetic packets, loopback TCP/UDP IPv4/IPv6, DNS validation, route ownership, cancellation, capacity and mixed-load checks passed. These isolated tests do not activate real capture routes. Counts and build boundaries are in the [verification report](docs/TUN_VERIFICATION.md). |
| Resources — build 6 | During uncontrolled owner traffic, 307 samples over 1543.679 s averaged 0.231% of one CPU core and peaked at 152.64 MiB combined app/engine/helper RSS. A separate 121.27 s practical quiet interval averaged 0.066% and peaked at 141.41 MiB (148.28 MB). These are sampled intervals, not battery, strict idle or physical-footprint benchmarks. [Measurements](PERFORMANCE.md) |

The build 6 trial's 30-minute authorization window included setup and shutdown; it was not an exact 30-minute Active stability run. No unexpected stop was observed in that trial. An older build 3 stop remains unexplained. Earlier unauthenticated WebSocket evidence also belongs to build 3. [Detailed scope](docs/TUN_VERIFICATION.md)

## Limits and troubleshooting

Circumvention depends on the network, application and filtering method. Traffic goes directly to destination servers; MacDPI does not hide your public IP. UDP payloads pass unchanged, so UDP forwarding is not a general UDP or QUIC bypass technique. Encrypted or absent visible server names can prevent selective repair. Existing VPNs, filters and split-DNS policies can affect coverage; detected conflicts can prevent activation or stop a session.

Longer daily use, repeated/longer sleep, deliberate crash recovery, network/VPN switching, broader reconnect coverage, physical IPv6 and quantified voice/game latency still need dedicated validation.

| Symptom | Next step |
| --- | --- |
| Awaiting authorization | Complete the macOS dialog. If canceled or expired, retry Enable when ready. |
| Failed, with verified cleanup | Review diagnostics before retrying. Report repeated stops with the build, macOS version, architecture and sanitized diagnostic report. |
| Recovery required | Keep the tunnel disabled and follow the ownership-specific recovery guide. Do not flush unrelated routes or reset all network settings. |
| A site, voice or game fails while Active | Check Automatic setup and the compatibility limits. Test website access, desktop connectivity, two-way audio and an actual game separately. |

[Troubleshooting](TROUBLESHOOTING.md) · [Route ownership and recovery](docs/TUN_ROUTE_SAFETY.md)

## Privacy and security

MacDPI has no telemetry, advertising, accounts or external traffic relay. It does not install trusted certificates, decrypt TLS traffic, store passwords or collect browsing history. The client continues to verify the origin certificate.

Automatic setup uses Standard TLS handling, ordinary System DNS and selective validated Cloudflare DNS-over-HTTPS for eligible Discord/Roblox TLS origin repair. Cloudflare receives those DNS questions and the source IP. Ordinary DNS retains its existing system path. Explicit encrypted lookup failures do not silently downgrade.

The privileged route/interface helper runs only for the session and authenticates its worker. The app and traffic engine stay unprivileged. MacDPI installs no persistent root daemon or passwordless sudo rule. Its private recovery journal records owned interface/routes. Fixed-category TUN failure messages can enter the Mac's local unified log without endpoints, DNS names, configuration values or payloads; MacDPI does not upload them. Review the [privacy policy](PRIVACY.md), [security policy](SECURITY.md) and [architecture](ARCHITECTURE.md).

## Build and test

Use a Mac with **full Xcode** selected and **Python 3**. The checked native toolchain is Xcode 27.2:

```sh
scripts/fetch-tun-toolchain.sh
MACDPI_PERSONAL_TUN=1 MACDPI_BUILD_ROOT=build/personal scripts/package-release.sh --dmg
open build/personal/release/MacDPI.app
```

The fetch step downloads a pinned Go compiler and checks its published SHA-256. Go and gVisor are linked into the bundled worker; the finished app needs no separate Go installation or runtime download. Use a separate `MACDPI_BUILD_ROOT` when developing alongside a running session. [Build and safe test instructions](BUILDING.md)

The source also preserves the authenticated local HTTP CONNECT proxy and optional Network Extension providers as independent modes. The personal TUN package omits those extensions. [Preserved 0.2.0 report](docs/FINAL_REPORT.md)

Bug reports and tests on additional Mac/network combinations are welcome. Include the build, macOS version, architecture, mode and sanitized diagnostics; keep credentials and private traffic out of reports. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues through [SECURITY.md](SECURITY.md).

MacDPI is [MIT licensed](LICENSE). Go, gVisor and transitive dependencies retain their own licenses; their notices ship in `MacDPI.app/Contents/Resources/TUNLicenses`.
