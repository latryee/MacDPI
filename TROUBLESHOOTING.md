# Troubleshooting

## Personal TUN

| Symptom | Checks and recovery |
| --- | --- |
| Awaiting authorization | Complete the macOS dialog. It can identify `osascript`, Apple's script runner. A canceled/expired request needs a new Enable attempt. |
| Active, but a site or app fails | Check Automatic setup and try a new connection. Test website access, native messaging, two-way voice and a real game separately. UDP forwarding does not guarantee a filtering bypass. |
| Failed, route cleanup verified | The session has stopped safely. Review the current network and retry Enable when ready. A changed route policy, lost interface or engine/control failure can stop a session; the status alone does not identify its cause. |
| Repeated unexpected stop | Note the build, macOS version and steps. In Console, look for subsystem `io.github.latryee.MacDPI`, category `TUN lifecycle`. Caught errors use fixed categories such as `network-baseline-changed`, `route-missing`, `packet-engine` or `control-lease`. Availability depends on macOS permissions/retention; abrupt termination may not record a category. Share the relevant category rather than a full system log. |
| Recovery required | Leave the session disabled and follow the ownership-specific recovery guide. Do not delete unrelated routes, reset networking or change existing VPN/DNS settings. |
| Usage shows an em dash | Enable first, then press Measure usage. Missing process permissions, exit or a changed session produce unavailable values rather than zero. The root helper is excluded from this app/engine sample. |
| Downloaded personal package declined | The package is ad hoc signed, not notarized. Build from reviewed source without weakening Gatekeeper, SIP or certificate validation. |

The recorded later stop in build 3 remains unexplained. The diagnostic additions improve future evidence; they do not retrospectively identify or fix that stop. [Current scope](docs/TUN_VERIFICATION.md), [recovery](docs/PERSONAL_TUN.md).

## Preserved Network Extension and local proxy modes

| Symptom | Checks and recovery |
| --- | --- |
| Integration unavailable on the local review build | Use Local proxy diagnostics. Mac-wide Enable requires the Developer ID build and the profiles described in BUILDING.md. |
| macOS approval or restart required | Follow the macOS prompt, then retry Enable from the app. Read the current status before making new connections. |
| Reconnecting or integration needs attention | Use Check status. If the state remains uncertain, use Emergency stop, then verify MacDPI's Network and Login Items & Extensions entries. |
| Local proxy ready, but the desktop app is unaffected | Use the optional proxied web window or an HTTP CONNECT client that accepts proxy credentials. For supported desktop flows, use an authorized Mac-wide build. |
| Local proxy cannot start | Check for a port conflict and choose another port above 1023 in Settings. |
| DNS fails with Cloudflare selected | Check HTTPS reachability to the resolver and the split-domain settings. Disable first to explicitly choose System DNS. Preserve normal TLS certificate verification. |
| Discord voice or Roblox game session still fails | Check the separate native acceptance status in COMPATIBILITY.md. Site/API reachability alone leaves voice, UDP gameplay and reconnection unverified. |
| A connection still fails with active routing | Try a fresh connection. Compare the same workflow with Compatibility to distinguish TLS record treatment from DNS or endpoint issues. |
| Other connections fail after stop | Restore any per-app diagnostic proxy setting you changed. For Mac-wide mode, verify only MacDPI's provider entries and compare DNS/VPN state against the pre-test baseline. |
| Downloaded build rejected | Build from reviewed source or obtain a notarized release. |

For a reproducible bug, include the version, macOS version, architecture, mode, profile, fixed error category and safe local reproduction. Keep private URLs, IPs, credentials and payloads out of reports. [Recovery procedure](INSTALLATION.md).
