# MacDPI 0.3.0 personal TUN preview — build 8

The [v0.3.0-preview.1 prerelease](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1) provides an ad hoc Universal 2 app with a local TCP/UDP engine and per-session macOS administrator authorization. It needs no paid Apple Developer membership or separately installed DPI tool. Open the app, leave Automatic setup selected, press Enable and approve macOS authorization. Ordinary DNS settings remain unchanged; eligible TLS origin repair uses validated Cloudflare answers. Disable releases the session's interface and routes.

## Downloads

- [Universal 2 DMG](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.dmg)
- [Universal 2 ZIP](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.zip)
- [SHA-256 manifest](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.sha256)

Disable and quit an existing copy before replacing it. This package is **ad hoc signed, not Developer ID signed or notarized**. If macOS declines it, build from reviewed source; do not disable Gatekeeper, SIP or certificate validation. [Installation and recovery](../INSTALLATION.md) · [Build guide](../BUILDING.md)

## Build 8 changes and checks

Build 8 recreates the selectable diagnostics view when report content changes and removes an explicit accessibility label that caused recursion on macOS 27. Exact UI assertions are preserved. TCP, UDP, TLS, DNS and route behavior are unchanged; rebuilt component hashes are not claimed to be identical to earlier builds.

The release source is [9928a913](https://github.com/latryee/MacDPI/commit/9928a9134fe25f21616661064dec974af98b2838). All three jobs in [CI run 42500004385](https://github.com/latryee/MacDPI/actions/runs/42500004385) passed: macOS 15 ARM and Intel isolated checks/builds, plus 29 native model and three UI cases on macOS 27.0.1/Xcode 27.2. The portable jobs include 130 core, 14 packaging, four operator and 13 native stop-channel cases, plus packet/IPC and loopback fixtures. Local verification checked the promoted Universal 2 app, exact ZIP/DMG contents, nested signatures and checksums. Its packaged engine passed SIGTERM, SIGINT and parent-EOF cancellation with an absent broker. Manual Overview/Diagnostics inspection confirmed Disabled and updated Personal TUN diagnostics without activation. [Package record](verification/0.3.0-release-readiness.json)

## Live evidence and limits

**No build 8 live TUN trial is claimed.** On build 6, the owner confirmed Discord messaging, two-way audio, real Roblox gameplay and rejoining both services on the development Mac/network. All 26 public HTTPS/API checks passed during about 25 min 44 s of monitored use; Disable restored all eight policy fingerprints and the resolver baseline. This was within a 30-minute setup/test/shutdown window, not an exact 30-minute Active stability run. A separate 121.27-second practical quiet interval averaged 0.066% combined CPU with 141.41 MiB peak RSS (148.28 MB); it did not include sleep.

On build 7, the same app, engine, helper and route survived 10.97 seconds of measured physical sleep. Certificate-verified public HTTPS/API passed before and after wake. Graceful signal shutdown reached Disabled with independent restoration of all eight policy fingerprints, resolver, route, interface and owned processes. That workflow completed in 149.75 seconds within its approved five-minute maximum. Earlier unauthenticated Gateway Hello evidence belongs to build 3.

The app targets macOS 12 and includes Intel/Apple Silicon slices. **Real TUN operation is verified only on Apple Silicon/macOS 26.6.** Isolated Intel CI does not establish physical Intel TUN compatibility. Physical IPv6, longer daily reliability, repeated/longer sleep, abrupt crash recovery and network/VPN transitions remain unverified. An older build 3 stop remains unexplained. These results do not establish universal access, quantified voice/game latency or UDP-specific circumvention. [Compatibility](../COMPATIBILITY.md) · [Verification](TUN_VERIFICATION.md) · [Engineering report](PERSONAL_REPORT_0.3.0.md)

## Preserved MacDPI 0.2.0 local review

The independent Network Extension path bundles Universal 2 transparent TCP/UDP and optional DNS system extensions. A properly provisioned build follows official macOS approval; the ad hoc local-review artifact cannot activate those components. The authenticated loopback CONNECT mode also remains available. Their Developer ID distribution, notarization and installed lifecycle acceptance remain pending. [Preserved report](FINAL_REPORT.md)
