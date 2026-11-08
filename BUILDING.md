# Building and release preparation

For the 0.3.0 personal-use TUN build, use the separate build path and toolchain checks. The instructions below still apply to the optional Network Extension and local proxy build. [Personal TUN build](docs/PERSONAL_TUN.md#build-and-safe-checks).

Disable and quit MacDPI before replacing its existing app bundle. To keep a session running during development, build under a separate `MACDPI_BUILD_ROOT` and replace the old bundle only after that session has stopped. Do not build over a running copy.

Use a Mac with full Xcode selected, Swift 5.9 or later, Python 3 and system OpenSSL for the TLS fixtures. The app and both system extensions target macOS 12 and build for arm64 and x86_64. The native project uses the Xcode 27.2 project format. The portable build script invokes the selected Xcode compiler directly.

```sh
scripts/build-app.sh
scripts/verify-release.sh build/release/MacDPI.app
scripts/package-release.sh --existing --dmg
```

The default build embeds both system extensions under `Contents/Library/SystemExtensions`. It uses ad hoc signatures, sets the local-review build marker and omits privileged networking entitlements from the host. The runtime preflight prevents local-review activation. `scripts/build-extension.sh` also builds the two bundles separately. `scripts/archive.sh` prepares an unsigned native Xcode archive for inspection. Use `MACDPI_BUILD_ROOT=build/another-directory` to isolate portable products. The scripts prepare files locally.

```sh
scripts/test.sh
xcodebuild -project MacDPI.xcodeproj -scheme MacDPI -configuration Debug \
  -derivedDataPath build/xcode -parallel-testing-enabled NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGNING_ALLOWED=YES PROVISIONING_PROFILE_REQUIRED=NO \
  MACDPI_INTEGRATION_BUILD=local-review MACDPI_TEAM_PREFIX=UNPROVISIONED. \
  -destination 'platform=macOS,arch=arm64' test
```

Use the local CPU architecture for hosted XCTest. The native test targets require macOS 14 with the tested Xcode toolchain. Test launches isolate integration state from macOS preferences. Loopback TLS 1.3 fixtures require macOS 15 for the memory-only identity loader.

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

The host must be authorized to install system extensions and use both Network Extension capabilities. The transparent child claims only the app-proxy capability. The DNS child claims only the DNS-proxy capability. The script verifies exact identifiers, team, profile validity, the signing certificate and signed entitlements for each slice, then checks the embedded application. The app group and provider Mach service names derive from the validated team. [Apple integration evidence](docs/APPLE_INTEGRATION_RESEARCH.md).

After separate upload authorization and setup of an Apple notary keychain profile, run `scripts/notarize.sh KEYCHAIN_PROFILE`. It makes a fresh archive from the verified Developer ID app, submits it, waits for acceptance, staples, validates Gatekeeper acceptance and regenerates packages and checksums. [Notarization script](scripts/notarize.sh), [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Update the shared marketing version and advance the build number with `scripts/set-version.py MAJOR.MINOR.PATCH`. The current version is 0.3.0/build 6. Xcode and the portable build stamp the shared version into components. Review the changelog and release notes before packaging. GitHub Actions prepares and checks review artifacts on macOS runners; the manual preparation workflow now produces the personal TUN package. Remote CI, Developer ID signing and notarization await an authorized run. Publishing is a separate maintainer action. [GitHub runner labels](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

## Current personal release checks

Build 6 passed 130 Swift core, 27 hosted model and 14 packaging cases. The current Debug CLI passed 23 loopback scenarios; four native TCP/UDP IPv4/IPv6 scenarios, the full Go suite with 15-second mixed traffic per family, capacity/lifecycle checks and native IPC also passed. Exact archives, signatures and post-promotion checksums were verified. [Current release proof](docs/verification/0.3.0-release-readiness.json).

Build 6 received a manual read-only Overview/Settings check while Disabled. The three automated native UI cases remain an earlier run; no automated UI suite was rerun. No setting was changed. A later approved build 6 GUI trial passed personal acceptance and verified Disable/restoration. Its 307 passive samples covered about 25 min 44 s within a maximum 30-minute setup/test/shutdown window; exact 30-minute Active stability is not claimed. [Live record](docs/verification/0.3.0-build6-live-personal.json).

The native CI job selects Xcode 27.2 explicitly on the public-preview `xcode-27` image and checks that version before opening the project. The portable macOS 15 jobs build through compiler scripts. This configuration has not yet been run remotely. [Hosted runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [November 4 image inventory](https://github.com/actions/runner-images/blob/releases/xcode-27-arm64/20261104/images/macos/xcode-27-arm64-Readme.md).

## Bounded manual network tests

Normal app sessions have no development-trial timer. For an explicitly approved live test, `scripts/test-session-deadline.py` provides an independent, non-root fallback for one pinned user-owned engine process. Start it with the expected executable, PID and a deadline earlier than the approved end, leaving cleanup headroom. It refuses a different executable or user and never starts a helper or changes network settings. Prefer normal GUI Disable; if the same process remains at the fallback deadline, it sends SIGTERM. Verify the helper, interface, routes and settings independently afterward.

This is a best-effort signal deadline, not proof that restoration finished by that instant. Identity inspection takes time, and the guard cannot run during machine sleep. A disarm marker should be used only after normal shutdown has been verified. The isolated tests use disposable user-owned processes and do not activate TUN:

```sh
python3 -m unittest discover -s Tests/OperatorTests -v
```
