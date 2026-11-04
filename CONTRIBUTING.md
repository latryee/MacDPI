# Contributing

Review ARCHITECTURE.md, SECURITY.md, PRIVACY.md and COMPATIBILITY.md first. Use a focused branch and describe the concrete behavior changed, evidence, limitations and platform coverage in the pull request.

Run `swift test --scratch-path build/swift`. For networking changes also build the Release CLI, compile Tools/TLSFixture/main.swift and run `python3 scripts/integration.py`. Run the native model/UI suite for UI behavior and `scripts/build-app.sh` for both architecture slices. The optional provider must continue to compile with `scripts/build-extension.sh`; compilation is not activation testing.

All normal tests must use loopback fixtures. Never add sudo, firewall/DNS/route/system-proxy changes, certificate installation, privileged helpers, extension activation, packet captures or unrelated-file mutations to a build/test script. Seek explicit authorization for dedicated system integration tests after all safe verification is complete.

Keep memory and work bounded. Preserve queue ownership, backpressure, cancellation and half-close behavior. Avoid per-packet logs or hostname histories. Tests should verify observable guarantees rather than duplicate implementation. New strategies need a precise protocol description, bounds, preconditions, failure/fallback behavior, compatibility declaration and honest evidence level. No network-effectiveness claims based on compilation alone.

Use native Swift/SwiftUI and Apple frameworks. Justify any new dependency with security, licensing and resource costs. Contributions and original icon artwork are MIT licensed; retain notices and do not copy incompatible third-party code. Apple SDKs/frameworks remain subject to Apple's licenses and are not bundled by this project. Public distribution and any applicable legal requirements remain the distributor's responsibility.
