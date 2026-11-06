# Troubleshooting

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
