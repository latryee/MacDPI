# Compatibility

The 0.3.0 personal build compiles the host, route helper and packet engine for arm64 and x86_64 with a macOS 12.0 deployment target. Isolated TCP and UDP packet tests cover both IP families on Apple Silicon. Real IPv4 activation and Disable were tested on macOS 26.6. [Personal TUN evidence](docs/TUN_VERIFICATION.md).

| Personal TUN capability | Evidence on the development Mac | Remaining scope |
| --- | --- | --- |
| Enable and authorization | GUI activation through macOS authorization, real captured public route and verified HTTPS | Intel and macOS 12 runtime |
| TCP/UDP | IPv4 physical HTTPS; IPv4/IPv6 synthetic integrity, loss and mixed-load fixtures | Physical IPv6, UDP interference, WAN jitter and throughput |
| Automatic setup | Standard TLS split, ordinary System DNS and selective validated DoH origin repair | Other networks, destinations, ECH and resolver policies |
| Discord desktop/voice | Owner confirmed bidirectional audio; public API and unauthenticated WSS passed over TUN | Independent voice RTT/loss, extended sessions and reconnect |
| Roblox gameplay | Owner confirmed joining a real game and remaining connected | Quantified gameplay duration, reconnect and other games/networks |
| Disable | Helper-confirmed detach, old processes exited; earlier short GUI trial matched all eight baseline fingerprints | Forced termination, sleep/wake and network/VPN switching |
| Resources | 496 s with owner traffic: 0.41% combined CPU, 130.33 MiB peak RSS | Strict idle, battery and 30-minute stability measurements |

The following matrix preserves the evidence for the **previous Network Extension and local proxy paths**. Their installed system extensions remain separate from Personal TUN.

MacDPI's host and two system extensions target macOS 12.0. The optional web window uses macOS 14 APIs. Launch at login is available from macOS 13. The minimum deployment target is checked at build time. Runtime testing on older systems and Intel hardware remains outstanding.

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

The transparent provider selects supported outbound flows with public numeric endpoints. LAN/private/reserved destinations, unsupported endpoints, ordinary port 53 DNS and MacDPI's own flows stay outside its forwarding policy. Name-only or unsupported endpoint forms can be declined. Existing flows, VPNs, filters and OS routing policy can affect coverage. IPv6-only/NAT64 deployments remain untested. [Apple architecture and platform limits](docs/APPLE_INTEGRATION_RESEARCH.md).

TLS transformation covers the first complete plaintext ClientHello record on ports 443, 8443 and 9443 in transparent mode and TCP 443 in local mode. Malformed or unsupported first records fall through unchanged. ECH inner names remain encrypted. UDP forwarding keeps application payloads intact and applies no QUIC or UDP circumvention technique. TCP packet boundaries, IP fragments and raw packet injection are outside the design.
