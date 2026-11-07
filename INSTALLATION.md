# Installation, operation and removal

Personal TUN 0.3.0 has its own authorization, stop and recovery sequence. [Personal TUN guide](docs/PERSONAL_TUN.md#first-authorized-test).

For the personal build, open the locally verified `MacDPI.app`, leave **Automatic setup** selected and press **Enable**. Approve the macOS administrator dialog, which can identify Apple's script runner as `osascript`. No Terminal paste or application proxy configuration is needed. The main window can be closed and reopened while the session continues. **Disable** stops the session and asks the helper to verify interface/route release. The development trial's ten-minute limit was imposed by the test operator; the app has no equivalent normal-use session timer. After verified Disable, quit and delete the app to uninstall. Recovery instructions cover an unconfirmed stop separately.

Personal archives are ad hoc signed and are not notarized. They require no paid Apple membership to build. A downloaded package may be declined by Gatekeeper; build from reviewed source in that case. The sections below describe the preserved optional Network Extension and local proxy builds.

## Local review build

Build from source with `scripts/build-app.sh`, then open `build/release/MacDPI.app`. Local review ZIP and DMG packages use ad hoc signatures. Distribution requires Developer ID signing and notarization. If Gatekeeper rejects a downloaded review package, build from reviewed source or obtain a notarized release.

In Settings, choose **Local proxy diagnostics** under **Operation**, then **Enable** in Overview. Open the optional **proxied web window** on macOS 14 or later, or configure a proxy-capable client to use `127.0.0.1` and the displayed port. The username is `macdpi`. **Copy diagnostic credentials** exposes the current per-launch password to the clipboard on request. A client must support HTTP CONNECT proxy authentication. Keep a record of any per-client proxy setting you change and restore it before turning off the listener. Closing the main window leaves the menu bar controls available.

## Mac-wide mode on a provisioned build

1. Prepare a Universal 2 Developer ID build with matching host and two provider profiles. Notarize and verify that artifact before distribution. Copy the reviewed application to Applications as part of the approved setup. [Build requirements](BUILDING.md).
2. Before activation, record the current VPN, filter, DNS proxy and resolver setup. Use a dedicated test Mac or a maintenance window. Check any managed or corporate configuration with its owner. Enabling a DNS proxy can disable another DNS proxy. A conflicting DNS proxy should be resolved before activation.
3. Select **Mac-wide integration**, choose the TLS profile and leave **System DNS** selected for the first test. Press **Enable**, review the scope and choose **Authorize reviewed setup**. Complete the official macOS approval prompts. If the app reports pending approval or restart, complete the indicated step, reopen the app if needed and retry Enable.
4. Wait for **Transparent routing active**. The app checks macOS connection status and fresh provider readiness. Open new application connections for testing. Existing connections may retain their previous route.
5. To test encrypted DNS separately, disable, select Cloudflare DoH and enter any required split domains. Re-enable after reviewing the separate DNS scope. Validate known local and corporate names against the recorded baseline before testing public endpoints.

## Stop, rollback and uninstall

Use **Disable** or **Emergency stop** from the main window or menu bar. The app requests flow closure, disables its own configuration and checks the resulting OS/provider state. Connections that were in use may need to reconnect. If status remains uncertain, inspect MacDPI's entries in System Settings under Network and Login Items & Extensions. Disable only MacDPI's entries and compare DNS, VPN and ordinary connection behavior against the recorded baseline. Restoring another DNS proxy, if macOS disabled it, requires its owner's normal settings and approval.

To uninstall the system integration, select **Remove MacDPI integration** in Settings and review the removal prompt. The app stops and removes its own configurations and asks macOS to deactivate the extensions. Complete any OS approval or restart, then recheck Network and Login Items & Extensions before deleting the host app. Avoid manual deletion of system preference files. The rollback sequence still needs an authorized installed test.

For local-only use, disable, quit, restore any per-client proxy settings and remove the app. If you opted into launch at login, remove the Login Item through the app or System Settings. Build products live under the repository's ignored `build/` directory.
