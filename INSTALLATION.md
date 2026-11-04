# Installation, operation and removal

## Local review build

Run `scripts/build-app.sh` and open `build/release/MacDPI.app`, or build/run the original project in Xcode 27.2. Nothing is installed into `/Applications` by a script. The generated package is a local ad hoc review build, not a signed/notarized public release. For a downloaded artifact rejected by Gatekeeper, obtain a correctly Developer ID-signed and notarized release or build from reviewed source; do not bypass system security.

A future signed public build can be copied to Applications and opened normally. Start with Standard, enable the local listener, and set the desired application's HTTP proxy to `127.0.0.1`, port `8080` (or the configured port). Only applications with explicit HTTP CONNECT support participate. Keep a note of that application's prior proxy configuration. A command-scoped check can use:

```sh
curl --proxy http://127.0.0.1:8080 --http1.1 https://example.com/
```

The app does not configure macOS system proxies, DNS, routes or VPNs. HTTP/3/QUIC may bypass TCP proxying in clients that do not honor proxy settings; use application-supported TCP settings for an intentional test. Existing sessions do not move into the proxy automatically.

On macOS 14+, **Open proxied web window** provides an HTTPS session without any system proxy changes. If the network tampers with DNS, disable the engine, select **Cloudflare DNS over HTTPS** in Settings, review the third-party DNS disclosure, and re-enable. Select Discord, Roblox, or enter another public HTTPS URL in that window. No page is contacted until selected. The window is not a native game launcher and does not support UDP voice; microphone/camera permission is denied. Session website data is not persisted.

For other apps that honor the macOS HTTPS proxy, Settings → Connect other apps provides the loopback address and opens Network Settings. **Changing Secure Web Proxy (HTTPS) is a system networking change and needs the owner's explicit approval.** Record the network service's exact current proxy settings, enable MacDPI first, set HTTPS proxy to `127.0.0.1` and the displayed port, then start a fresh application connection. Restore the previous HTTPS proxy before disabling/quitting MacDPI. If it remains configured while MacDPI is stopped/crashed, participating apps may lose HTTPS access. Do not replace an existing corporate/VPN/PAC proxy without review. This still does not route UDP or proxy-ignoring apps.

Closing the window leaves the menu bar utility running. Use the menu bar to reopen it, disable it or quit. Disable closes all proxy sessions. Restore the tested application's previous proxy setting before expecting it to work while MacDPI is stopped. If a site fails, disable, choose Compatibility, enable and retry explicitly. No automatic request replay is performed.

## Optional transparent integration: approval required, unverified

`scripts/build-extension.sh` only compiles a separate unsigned Universal 2 bundle. It does not install or activate anything. The standard app does not embed it and exposes no activation control. `TransparentIntegrationController.swift` prepares installation, configuration, start, disable and preference-removal APIs, each requiring an explicit consent argument.

Before any real test, a maintainer must obtain Apple Developer Program access, identifiers, the `app-proxy-provider-systemextension` entitlement and matching Developer ID provisioning profiles for host/provider. Prepare the host's system-extension installation entitlement and usage description; embed the provider under `Contents/Library/SystemExtensions`; replace the literal team prefix placeholder in the provider plist; embed correct profiles and sign nested code before the host. Review the extension and its fail-open behavior, then notarize the complete artifact. This path is not a ready-to-activate release.

Activation registers executable code with macOS and can route other applications' TCP 443 flows through it. It may require approval in System Settings and may disrupt connections or conflict with VPN/filter software. Obtain explicit permission first. Test on a dedicated Mac/account with recorded baseline settings. Reversal uses the controller's stop/disable/remove operation and, if removing the installed code, an OSSystemExtensionManager deactivation request or the OS's approved removal flow. Check the OS's actual provider state; do not infer it from the local toggle. Do not manually delete macOS networking preference files.

## Remove local mode

Disable, quit, restore any per-app proxy settings you chose, and remove the app you built/copied. If you opted into launch at login, turn that switch off first (or remove the Login Item through System Settings). No privileged daemon, system extension, DNS entry, route, firewall rule, trust anchor or VPN configuration is installed by local mode. Build outputs reside in this repository's ignored `build/` directory; remove only those outputs if desired. No cleanup script recursively deletes directories.
