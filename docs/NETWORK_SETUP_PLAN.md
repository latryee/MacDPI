# Prepared network setup; not applied

The local engine and opt-in encrypted DNS passed the limited public checks in [REAL_NETWORK_VALIDATION.md](REAL_NETWORK_VALIDATION.md). The native web window rendered Discord and Roblox. System-wide routing has not been enabled.

The next reversible test for applications that honor macOS HTTPS proxy settings is:

1. Recheck and record the active service's current Secure Web Proxy (HTTPS) configuration immediately before any change. The read-only inspection on 2026-11-04 found the active service named **Wi-Fi**, HTTPS proxy **disabled**, server empty, port 0, proxy authentication off. Do not reuse this baseline if it has changed.
2. Run MacDPI with Standard, Cloudflare DNS over HTTPS, and listener `127.0.0.1:8080`.
3. **Only after the owner's explicit approval**, set that service's Secure Web Proxy (HTTPS) to `127.0.0.1`, port `8080`, without authentication. Leave HTTP, SOCKS, PAC, DNS, VPN, routes, interfaces and firewall unchanged. macOS may require the owner to approve an administrator dialog. No password is to be collected by MacDPI or the coding agent.
4. Start fresh browser/Discord HTTPS connections and inspect the engine counters. Applications can ignore the OS proxy. Already-open sessions do not migrate automatically. This is a test of those applications, not an assertion of system-wide interception.
5. Restore the recorded HTTPS proxy configuration after the bounded test, before stopping MacDPI. Verify the restored state by reading it again. For the observed disabled baseline, HTTPS proxy must be disabled again; any changed stored host/port values should also be restored where the supported configuration interface permits it.

**Risk:** apps using the HTTPS proxy may lose connectivity while the engine is stopped/crashed or if setup is wrong. Recording/restoring the original proxy configuration is the rollback. An existing corporate/PAC/VPN configuration must be reviewed instead of overwritten. The app does not perform this change automatically or install a privileged helper.

The original goal explicitly requires approval before system proxy changes. Ordinary “continue” instructions do not authorize this operation. No such change has been applied.

## Remaining work for native games and voice

An HTTPS proxy cannot route Roblox gameplay UDP, Discord voice UDP or arbitrary proxy-ignoring apps. Approval for the HTTPS proxy test does not solve or authorize those capabilities. A signed, provisioned and owner-approved supported Network Extension architecture with DNS and necessary transport coverage must be developed and tested before claiming that behavior. The current separate transparent provider handles TCP 443 only, prefers an OS-supplied remote hostname when available, and cannot reliably undo DNS filtering when only a previously resolved IP is supplied. It is a compile-only preparation, not a finished universal integration.

Developer ID identity, correct Apple entitlements/profiles, real extension lifecycle tests, Intel/older-OS runtime checks and authenticated game/voice validation remain outstanding. None can be replaced by a green compile result or by disabling macOS security protections. [Apple's provider deployment requirements](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
