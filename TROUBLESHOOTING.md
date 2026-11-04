# Troubleshooting

| Symptom | Checks and recovery |
| --- | --- |
| Failed to start | Another process may use the local port. Disable, choose another port above 1023 and retry. Do not kill unrelated processes. |
| Proxy ready, but no traffic | Only the listener is ready. Use Open proxied web window (macOS 14+) or configure the target app's HTTP CONNECT proxy explicitly. Enable alone cannot route other apps. |
| Discord/Roblox resolves to a blocking page or a bad certificate | Do not accept the bad certificate. Disable, select Cloudflare DNS over HTTPS, re-enable and retry through the proxy. This changes only MacDPI's resolver. |
| Connection fails | Look at the fixed error category, then explicitly retry with Compatibility. System DNS, destination reachability and TLS server support can each fail independently. |
| LAN/local HTTPS fails through proxy | Production policy allows public destinations only. Remove that application's proxy configuration for local services. |
| DPI blocking remains | A limited Discord/Roblox HTTPS check passed on one network; effectiveness is network-specific. TLS record splitting may not affect a DPI that reassembles handshakes. No automatic or universal bypass is claimed. |
| Roblox site opens but game / Discord voice fails | Native game/voice UDP is not implemented or routed by this HTTPS proxy. An HTTPS/system proxy setting is insufficient for those flows; transparent integration remains unactivated and needs signing/approval. |
| Secure DNS fails | The certificate-verified HTTPS resolver must be reachable. There is no silent system-DNS fallback. Retry System DNS explicitly if appropriate; do not disable certificate verification. |
| QUIC/HTTP/3 app unaffected | This release forwards TCP only. Check the application's own supported proxy/TCP configuration. MacDPI does not change system QUIC behavior. |
| Slow/incomplete first flight closes | Default 10-second deadline covers CONNECT, DNS, connect and initial TLS processing. Idle tunnels close after 120 seconds without data. |
| Connections stop after Disable | Expected. Restore any per-app proxy setting or re-enable. No persistent route is left behind. |
| Network path available but internet fails | The indicator reflects NWPathMonitor status, not a successful external probe or DPI diagnosis. |
| Downloaded app blocked | Obtain a signed/notarized build or build reviewed source. Do not disable Gatekeeper or remove quarantine. |
| Launch at login needs approval | Check System Settings → General → Login Items. This optional feature requires macOS 13+. Opening at login does not enable the engine. |
| Extension permission required | Standard packages deliberately omit the experimental provider. Read INSTALLATION.md; do not activate unsigned/unreviewed code. |

Diagnostics → Check readiness validates settings and reports the actual listener/path state and limitations. Copy report is explicit and contains no hostnames or traffic content. Aggregate connection failures can include clients intentionally resetting a connection; the count does not establish DPI blocking.

For a reproducible bug, provide the version, macOS version, architecture, profile, fixed error category and safe local reproduction. Avoid URLs, IPs, packet captures, credentials or private payloads. Test data and results can be regenerated using BUILDING.md and TEST_RESULTS.md.
