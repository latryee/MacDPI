# Building and release preparation

## Requirements

A Mac, full Xcode selected as the active developer tools, Swift 5.9+, Python 3 and the system `openssl`. There are no third-party package dependencies. Compilation was verified using Xcode 27.2/Swift 6.4.2 on Apple Silicon/macOS 26.6. Other toolchains are not yet executed in this repository's recorded results.

## Build paths

- `scripts/build-app.sh`: native Universal 2 Release app using `xcrun swiftc`, Icon Utility and ad hoc signing. Deployment target 12.0. Outputs `build/release/MacDPI.app`. Compiles all UI, core and inactive integration-controller sources for both architectures.
- `MacDPI.xcodeproj`: preserved original Xcode 27.2 project format. App, hosted model tests and UI tests. Debug builds target the current architecture; Release archive explicitly targets both.
- `swift build --scratch-path build/swift -c release`: headless CLI/core. Run `build/swift/release/macdpi --help`.
- `scripts/build-extension.sh`: compile-only Universal 2 provider. Does not register, sign, embed or activate it.
- `scripts/archive.sh`: Xcode Release `.xcarchive` under `build/archive/`, signing disabled. No installation occurs; linker archive paths are metadata, not writes into Applications.

To run hosted native tests:

```sh
xcodebuild -project MacDPI.xcodeproj -scheme MacDPI -configuration Debug \
  -derivedDataPath build/xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  -destination 'platform=macOS,arch=arm64' test
```

Choose the runtime architecture appropriate to your Mac. Xcode 27's XCTest frameworks require macOS 14 for the hosted test targets; this does not raise the app's 12.0 deployment target. UI automation temporarily enables a loopback listener and uses in-memory settings. No launch-at-login or transparent integration mutation is tested.

## Packages, signing and notarization

```sh
scripts/package-release.sh             # builds app, local ad hoc ZIP + SHA-256
scripts/package-release.sh --dmg       # also creates a read-only compressed DMG
scripts/package-release.sh --existing  # package the existing app without rebuilding/re-signing
scripts/verify-release.sh build/release/MacDPI.app
```

Developer ID signing is opt-in through `SIGN_IDENTITY='Developer ID Application: …' scripts/package-release.sh`. The script never invents credentials and never uploads. Keep private keys and provisioning profiles outside source control. Network Extension signing requires additional separately reviewed steps in INSTALLATION.md; normal packages contain no provider.

After explicit authorization and access to a preconfigured keychain notary profile:

```sh
scripts/notarize.sh PATH_TO_DEVELOPER_ID_ZIP KEYCHAIN_PROFILE
```

This command uploads to Apple, waits, staples, verifies with Gatekeeper, and repackages the stapled app with updated checksums. It was not run during development. To validate a signed/stapled release use `REQUIRE_NOTARIZATION=1 scripts/verify-release.sh`. A local ad hoc app intentionally cannot satisfy that requirement. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Update versions with `scripts/set-version.py MAJOR.MINOR.PATCH`, review CHANGELOG.md and release notes, then rebuild. VERSION, Xcode marketing version and provider version are kept together. App display version comes from bundle metadata. Build number is currently 1 and should be incremented for successive distribution builds.

CI is prepared for Intel and Apple Silicon macOS 15 runners plus a separate Xcode 27 native UI job. These runner jobs have not been executed remotely. CI runs nonprivileged core and loopback tests, compiles Universal 2 app/provider, verifies the local signature/entitlements and uploads review artifacts to the workflow run. The release workflow prepares artifacts only. GitHub publication remains an explicit maintainer action after approval; for example `gh release create TAG --draft --notes-file docs/RELEASE_NOTES.md build/dist/…` with the exact reviewed signed artifacts. No workflow creates a GitHub Release automatically.

Runner labels were checked against the [GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) on 2026-11-04. Action revisions are pinned, with Dependabot updates prepared.
