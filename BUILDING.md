# Building and release preparation

The public personal preview is **0.3.0/build 8**, distributed as the [v0.3.0-preview.1 prerelease](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1). It is ad hoc signed, not Developer ID signed or notarized.

Disable and quit MacDPI before replacing its existing app bundle. To keep a session running during development, build under a separate `MACDPI_BUILD_ROOT` and replace the old bundle only after that session has stopped. Do not build over a running copy.

Use a Mac with full Xcode selected, Python 3 and system OpenSSL for the TLS fixtures. The native project uses the Xcode 27.2 project format. The portable build script invokes the selected Xcode compiler directly. The app, helper and worker build for arm64 and x86_64 with a macOS 12.0 deployment target; compilation does not establish runtime compatibility on every target.

## Personal TUN package

```sh
scripts/fetch-tun-toolchain.sh
MACDPI_PERSONAL_TUN=1 MACDPI_BUILD_ROOT=build/personal scripts/package-release.sh --dmg
open build/personal/release/MacDPI.app
```

The fetch step explicitly downloads a pinned Go compiler and verifies its published SHA-256. Go, gVisor and the relevant license notices are bundled with the engine; the finished app needs no separate Go installation or runtime download. The personal package omits the optional Network Extensions. [Personal TUN build details](docs/PERSONAL_TUN.md#build-and-safe-checks)

| Artifact | Local path |
| --- | --- |
| Application | `build/personal/release/MacDPI.app` |
| DMG | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.dmg` |
| ZIP | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.zip` |
| SHA-256 manifest | `build/personal/dist/MacDPI-0.3.0-universal2-personal-adhoc.sha256` |

Verify generated archives from their directory:

```sh
cd build/personal/dist
shasum -a 256 -c MacDPI-0.3.0-universal2-personal-adhoc.sha256
```

The checked build 8 app, exact extracted ZIP and read-only DMG contents, nested signatures and post-promotion checksums passed local verification. The packaged engine passed SIGTERM, SIGINT and parent-EOF cancellation with an absent broker. Manual Overview/Diagnostics inspection confirmed Disabled and updated Personal TUN diagnostics without activation. The release source is [9928a913](https://github.com/latryee/MacDPI/commit/9928a9134fe25f21616661064dec974af98b2838). Build 8 recreates selectable diagnostics when report content changes and removes the explicit accessibility label that triggered recursion on macOS 27. TCP, UDP, TLS, DNS, routes and the UI assertions are unchanged.

## Safe local and CI checks

These suites use synthetic packets, loopback fixtures and disposable normal-user processes. They do not activate a real TUN or change host networking:

```sh
swift test --scratch-path build/swift
scripts/test-tun-worker.sh
scripts/test-tun-ipc.sh
python3 scripts/test-tun-stop-channel.py
python3 -m unittest discover -s Tests/PackagingTests
python3 -m unittest discover -s Tests/OperatorTests -v
```

Use the local CPU architecture for hosted XCTest:

```sh
xcodebuild -project MacDPI.xcodeproj -scheme MacDPI -configuration Debug \
  -derivedDataPath build/xcode -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGNING_ALLOWED=YES PROVISIONING_PROFILE_REQUIRED=NO \
  MACDPI_INTEGRATION_BUILD=local-review MACDPI_TEAM_PREFIX=UNPROVISIONED. \
  -destination 'platform=macOS,arch=arm64' test
```

The native test targets require macOS 14 with the tested Xcode toolchain. Test launches isolate integration state from macOS preferences. Loopback TLS 1.3 fixtures require macOS 15 for the memory-only identity loader.

All three jobs in [CI run 42500004385](https://github.com/latryee/MacDPI/actions/runs/42500004385) passed for the release source. The native job passed **29 model and three UI cases** on macOS 27.0.1/Xcode 27.2, explicitly selecting Xcode 27.2 on the `xcode-27` runner. Both macOS 15 ARM and Intel jobs passed 130 core, 14 packaging, four operator and 13 native stop-channel cases, packet/IPC and loopback fixtures, and Universal 2 builds. Those isolated Intel checks are not physical Intel TUN acceptance.

## Live evidence boundaries

Build 7 passed 29 hosted model, 14 packaging, four operator guard and 13 native stop-channel cases. Its exact packaged engine passed SIGTERM, SIGINT and parent-EOF cancellation while waiting for an absent broker. A separate approved GUI trial preserved the app, engine, helper and capture route across 10.97 seconds of physical sleep, passed certificate-verified HTTPS/API before and after wake, and gracefully stopped to Disabled. Independent checks restored all eight policy fingerprints, resolver, route, interface and owned processes. The workflow completed in 149.75 seconds within its five-minute limit. [Build 7 record](docs/verification/0.3.0-build7-sleep-shutdown.json)

Build 6 passed 130 Swift core, 27 hosted model and 14 packaging cases; 23 Debug CLI loopback scenarios; four native TCP/UDP IPv4/IPv6 scenarios; and Go mixed-load, capacity/lifecycle/race and native IPC checks. Its owner-approved GUI trial covered Discord messaging/two-way audio and voice rejoining, Roblox gameplay/rejoining and 26 public HTTPS/API checks with verified Disable/restoration. The monitored enabled interval was about 25 min 44 s within a 30-minute setup/test/shutdown window. A separate practical quiet sample lasted 121.27 seconds. [Live record](docs/verification/0.3.0-build6-live-personal.json) · [Idle scope](docs/verification/0.3.0-build6-idle.json)

These live results belong to builds 6 and 7. **No build 8 live TUN trial is claimed.** Real TUN runtime evidence is limited to Apple Silicon/macOS 26.6. An older build 3 stop remains unexplained; long-term reliability, abrupt crash recovery and network/VPN switching need further testing. [Verification report](docs/TUN_VERIFICATION.md) · [Current package record](docs/verification/0.3.0-release-readiness.json)

## Optional Network Extension and proxy builds

```sh
scripts/build-app.sh
scripts/verify-release.sh build/release/MacDPI.app
scripts/package-release.sh --existing --dmg
```

The default build embeds both system extensions under `Contents/Library/SystemExtensions`. It uses ad hoc signatures, sets the local-review build marker and omits privileged networking entitlements from the host. Runtime preflight prevents local-review extension activation. `scripts/build-extension.sh` builds the two bundles separately; `scripts/archive.sh` prepares an unsigned native Xcode archive for inspection. These scripts prepare local files.

## Developer ID distribution

Supply the actual Developer ID Application signing identity, Team ID and a profile for each component. Keep profiles and private keys outside the repository.

```sh
SIGN_IDENTITY='Developer ID Application: …' \
MACDPI_TEAM_ID='YOURTEAMID' \
MACDPI_HOST_PROFILE='/path/to/host.provisionprofile' \
MACDPI_EXTENSION_PROFILE='/path/to/transparent.provisionprofile' \
MACDPI_DNS_PROFILE='/path/to/dns.provisionprofile' \
scripts/package-release.sh --dmg
```

The host must be authorized to install system extensions and use both Network Extension capabilities. The transparent child claims only app-proxy; the DNS child claims only DNS-proxy. The script verifies exact identifiers, team, profile validity, signing certificate and signed entitlements for each slice, then checks the embedded application. App group and provider Mach service names derive from the validated team. [Apple integration evidence](docs/APPLE_INTEGRATION_RESEARCH.md)

After separate upload authorization and setup of an Apple notary keychain profile, run `scripts/notarize.sh KEYCHAIN_PROFILE`. It makes a fresh archive from the verified Developer ID app, submits it, waits for acceptance, staples, validates Gatekeeper acceptance and regenerates packages/checksums. This process has not been performed for the personal preview. [Notarization script](scripts/notarize.sh) · [Apple documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Update the shared marketing version and advance the build number with `scripts/set-version.py MAJOR.MINOR.PATCH`. Xcode and portable builds stamp the shared version into components. Review the changelog and release notes before packaging. Publishing is a separate maintainer action.

## Bounded manual network tests

Normal app sessions have no development-trial timer. For an explicitly approved live test, `scripts/test-session-deadline.py` provides an independent, non-root fallback for one pinned user-owned engine process. Start it with the expected executable, PID and a deadline earlier than the approved end, leaving cleanup headroom. It refuses a different executable or user and never starts a helper or changes network settings. Prefer GUI Disable; if the same process remains at the fallback deadline, it sends SIGTERM. Verify the helper, interface, routes and settings independently afterward.

This is a best-effort signal deadline, not proof that restoration finished by that instant. Identity inspection takes time, and the guard cannot run during machine sleep. Use a disarm marker only after normal shutdown is verified. Live account, microphone and game tests require the user's participation.
