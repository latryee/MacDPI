# Compatibility

The **0.3.0/build 8 personal preview** compiles the host, route helper and packet engine for arm64 and x86_64 with a **macOS 12.0 deployment target**. Real TUN activation and cleanup have been tested only on **Apple Silicon/macOS 26.6**, using builds 6 and 7. Build 8 changes selectable diagnostics accessibility; TCP, UDP, TLS, DNS and route behavior are unchanged. No build 8 live TUN trial is claimed. [Downloads](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1) · [Personal TUN evidence](docs/TUN_VERIFICATION.md)

The release source passed all three jobs in [CI run 42500004385](https://github.com/latryee/MacDPI/actions/runs/42500004385): native model/UI tests on macOS 27.0.1/Xcode 27.2, and isolated core, packaging, operator, packet/IPC, loopback and build checks on macOS 15 ARM and Intel runners. The native job passed 29 model and three UI cases. **Isolated Intel CI is not physical Intel TUN acceptance**, and the deployment target is not proof of operation on macOS 12.

The download is ad hoc signed, **not Developer ID signed or notarized**. If macOS declines it, build from reviewed source; do not weaken system protections. [Build guide](BUILDING.md)

| Personal TUN capability | Evidence on the development Mac | Remaining scope |
| --- | --- | --- |
| Enable and authorization | GUI activation through macOS authorization, real captured public route and certificate-verified HTTPS on builds 6/7 | Physical Intel and older macOS TUN runtime |
| TCP/UDP | IPv4 physical HTTPS; IPv4/IPv6 synthetic integrity, loss and mixed-load fixtures | Physical IPv6, UDP interference, WAN jitter and throughput |
| Automatic setup | Standard TLS split, ordinary System DNS and selective validated DoH origin repair | Other networks, destinations, ECH and resolver policies |
| Discord desktop/voice | Build 6 owner confirmed messaging, bidirectional audio and voice rejoining; public API passed. Earlier build 3 unauthenticated WSS passed | Quantified voice RTT/loss, exact use duration and broader reconnect coverage |
| Roblox gameplay | Build 6 owner confirmed joining, remaining connected and rejoining a real game | Quantified duration/RTT and other games/networks |
| Disable and sleep/wake | Build 6 GUI Disable and build 7 graceful signal stop reached verified Disabled with all eight policy/resolver checks. Build 7 preserved original processes and capture route across 10.97 s of measured physical sleep, with valid HTTPS/API before/after wake and independent resource cleanup | Abrupt crash, repeated/longer sleep and network/VPN switching |
| Resources | Build 6 owner traffic: 1543.679 s, 0.231% combined CPU, 152.64 MiB peak RSS. Separate practical quiet 121.27 s: 0.066%, 141.41 MiB (148.28 MB) | Strict zero-traffic idle, battery, leak bounds and exact 30-minute Active stability |

The build 6 monitored interval was about 25 min 44 s within a 30-minute setup/test/shutdown window. The separate quiet sample did not include sleep; compliance with that test's five-minute shutdown window was unproven. The later build 7 sleep/shutdown workflow completed in 149.75 seconds within its approved five-minute maximum. An older build 3 unexpected stop remains unexplained. [Evidence and limitations](docs/TUN_VERIFICATION.md)

## Preserved Network Extension and local proxy paths

These modes are independent of Personal TUN. Their installed system extensions remain separate and require their own provisioning and approval.

MacDPI's host and two system extensions target macOS 12.0. The optional web window uses macOS 14 APIs. Launch at login is available from macOS 13. The minimum deployment target is checked at build time. Installed extension operation on older systems and Intel hardware remains outstanding.

| Capability | Implemented | Tested | Real-world verified |
| --- | --- | --- | --- |
| HTTPS proxy | Authenticated loopback CONNECT in the app | Parser, credential and TCP/TLS loopback fixtures | Selected 0.1.0 web/API/WSS requests on one network |
| Transparent TCP routing | Public numeric IPv4/IPv6 flows, original endpoint, bound interface support | Flow policy and native TCP loopback adapter | Pending signed OS activation |
| Encrypted DNS | Local A/AAAA DoH and optional system DNS provider | Wire parsing, validation, TCP/UDP framing, cancellation, split routing and failure | Selected local DoH lookups in 0.1.0. Installed DNS provider pending |
| Transparent UDP forwarding | Bounded public IPv4/IPv6 datagrams | Empty datagrams, payloads up to 65,507 bytes, IPv4/IPv6, backpressure and cancel | Pending signed OS activation |
| Discord desktop connectivity | General TCP/UDP and optional DNS path | Controlled protocol fixtures. Prior unauthenticated API/WSS sample | Native startup, login, persistent gateway and reconnect pending |
| Discord voice | General UDP forwarding path | Controlled UDP fixtures | Voice signaling, bidirectional audio and reliability pending |
| Roblox desktop connectivity | General TCP/UDP and optional DNS path | Controlled protocol fixtures. Prior website/API sample | Native startup and authentication pending |
| Roblox gameplay | General UDP forwarding path | Controlled UDP fixtures | Game join, play, timeout and reconnect pending |
| One-click activation | Approval, preference configuration and readiness state machine | Simulated lifecycle and native model tests | macOS approval, enable and restart pending |
| Reliable shutdown and recovery | Flow drain, stop, removal and emergency control | Mock OS state, bounded resource and local restart checks | Installed rollback, updates and sleep/wake pending |

The transparent provider selects supported outbound flows with public numeric endpoints. LAN/private/reserved destinations, unsupported endpoints, ordinary port 53 DNS and MacDPI's own flows stay outside its forwarding policy. Name-only or unsupported endpoint forms can be declined. Existing flows, VPNs, filters and OS routing policy can affect coverage. IPv6-only/NAT64 deployments remain untested. [Apple architecture and platform limits](docs/APPLE_INTEGRATION_RESEARCH.md)

TLS transformation covers the first complete plaintext ClientHello record on ports 443, 8443 and 9443 in transparent mode and TCP 443 in local mode. Malformed or unsupported first records fall through unchanged. ECH inner names remain encrypted. UDP forwarding keeps application payloads intact and applies no QUIC or UDP circumvention technique. TCP packet boundaries, IP fragments and raw packet injection are outside the design.
