# Limited real-network validation — 2026-11-04

This historical local-proxy comparison predates Personal TUN. Current GUI activation, owner-reported Discord audio and Roblox gameplay are recorded separately in [0.3.0 verification](TUN_VERIFICATION.md).

The previously missing pieces were traffic routing and DNS filtering. Enable opened only the loopback listener, so an unconfigured Discord application never used the engine. In the tested network, system DNS also returned the same address for Discord and Roblox; connecting there failed normal certificate verification. This observation is consistent with DNS filtering, without attributing it to a specific network operator.

The new optional DNS-over-HTTPS resolver and the existing TLS record splitting were tested together using the production core/CLI, without changing the Mac's DNS, proxy, routing, firewall, VPN or trust settings. No certificate warning was bypassed. No account, login token, private channel or game session was used.

Recorded at **20:32 Europe/Istanbul**, Apple Silicon/macOS 26.6:

| Public target | Direct + system DNS | Unchanged TLS + Cloudflare DoH | Standard TLS split + Cloudflare DoH |
| --- | --- | --- | --- |
| Discord gateway discovery API | Certificate rejected (`curl` 60) | TLS timeout after 8.0 s | HTTP 200, expected gateway URL, certificate verified; 0.395 s total |
| Roblox website | Certificate rejected (`curl` 60) | TLS timeout after 8.0 s | HTTP 200, expected HTML, certificate verified; 0.574 s total |
| Roblox public user API | Certificate rejected (`curl` 60) | TLS timeout after 8.0 s | HTTP 200, expected public response, certificate verified; 0.457 s total |
| Discord gateway WebSocket | Not separately tested | Not separately tested | Certificate-verified TLS, HTTP 101 and valid unauthenticated opcode 10 Hello; 0.567 s |

The split proxy's counters confirm four transformed initial records. Its final aggregate includes one connection-failure event during WebSocket teardown; the Hello had already been received and validated. Aggregate failures alone do not diagnose censorship.

The native app's isolated WebKit window was also exercised through its actual UI with Standard and Cloudflare DNS selected. Discord's Turkish login screen and Roblox's Turkish signup/home screen rendered, including website assets. No form was filled, account created or login performed. An initial attempt with System DNS failed, reproducing why encrypted DNS selection matters here.

These comparisons show that **DNS alone was insufficient in this test**, and the combined method enabled the tested HTTPS connections. They do not establish success for every destination, network, future block, authenticated app operation, native Roblox gameplay, Discord voice, WebRTC/UDP or proxy-ignoring application. The original one-button, system-wide application objective is still incomplete. The optional transparent provider remains unsigned/unactivated and cannot be counted as integration-tested.

## Reproduce deliberately

Build the Release CLI, then explicitly acknowledge that this test contacts public Discord/Roblox endpoints and Cloudflare:

```sh
swift build --scratch-path build/swift -c release
python3 scripts/check-real-network.py --acknowledge-external-requests
```

The test never changes system settings and is excluded from normal local tests/CI. Its saved report is aggregate status/timing and fixed public service labels; temporary response bodies are removed. A sanitized copy is retained at [verification/real-network.json](verification/real-network.json). Results depend on the network at execution time.

For the app: disable → Settings → Standard + Cloudflare DNS over HTTPS → enable → Open proxied web window. Cloudflare receives destination DNS names and the source IP, as disclosed in [PRIVACY.md](../PRIVACY.md). System DNS remains the default for new and migrated configurations.

For **other** applications, explicit HTTP CONNECT configuration or an owner-approved macOS HTTPS proxy setting is still needed. Native game/voice UDP needs additional supported integration beyond an HTTPS proxy; see [the concrete next-step plan](NETWORK_SETUP_PLAN.md).
