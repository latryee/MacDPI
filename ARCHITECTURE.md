# Architecture

## Personal TUN 0.3.0

The primary personal-use build separates SwiftUI/AppKit, an unprivileged Swift/Go data engine and a session-only route helper. macOS authorization runs only the verified helper as root. It creates a Darwin `utun`, journals its public-prefix capture plan and transfers a duplicated descriptor to the authenticated worker. The worker's gVisor stack reconstructs TCP/UDP and binds every physical outbound socket to the recorded egress interface. TCP uses the existing Swift TLS record processor; UDP payloads remain unchanged. Automatic setup leaves ordinary System DNS as found and can repair eligible TLS origins through validated Cloudflare answers. There is no remote relay, persistent root daemon or hidden runtime download. [Detailed design and bounds](docs/PERSONAL_TUN.md), [route transaction](docs/TUN_ROUTE_SAFETY.md), [current evidence](docs/TUN_VERIFICATION.md).

The Network Extension and local proxy designs below are preserved independent modes. They are not required by the personal TUN package.

## Mac-wide integration

```text
App's new supported connection
  -> macOS Network Extension flow policy
  -> original public numeric destination and port
  -> TCP stream with optional first-record TLS split
     or bounded UDP datagram pump
  -> direct connection to the original destination

Optional system DNS traffic on port 53
  -> separate DNS proxy provider
  -> bounded TCP/UDP DNS parsing and response validation
  -> original resolver for local, split or interface-bound queries
     or Cloudflare DoH for eligible public queries
```

The two providers are embedded system extensions with separate identifiers and entitlements. The host controls them through SystemExtensions and NetworkExtension. MacDPI preserves an OS-provided numeric endpoint and never infers a hostname from a shared IP. The optional DNS provider acts before the app connects. It uses the original resolver for explicitly identified exceptions and returns failure after a failed encrypted lookup. It preserves DNS records, CNAMEs and TTLs in the wire response and keeps no provider DNS cache. A UDP response larger than the client's advertised limit is truncated so the client can retry over TCP.

The transparent TCP adapter creates a Network.framework stream using public flow metadata and interface-binding APIs. The UDP adapter uses connected, nonblocking BSD sockets to preserve datagram boundaries, including zero-byte messages. It can bind to the original interface but does not transfer the originating app's metadata to the socket. The native adapters are tested on loopback without an installed provider. [Apple API decisions and transport fixtures](docs/APPLE_INTEGRATION_RESEARCH.md).

## Local diagnostic mode

```text
Explicit HTTP CONNECT client
  -> authenticated IPv4 loopback listener
  -> strict CONNECT parser, port check and selected DNS resolver
  -> pinned public numeric destination
  -> first TLS record processor and backpressured byte pumps
  -> direct TCP connection to destination
```

The app generates a per-launch random password. Authentication precedes DNS or upstream connect. Only a complete first plaintext ClientHello record is eligible for splitting. The origin and the client perform their own TLS handshake and certificate verification. Later bytes pass unchanged. The optional nonpersistent WebKit window on macOS 14 and later supplies the credential through its proxy configuration.

The local DoH resolver validates A/AAAA answers against the question and CNAME chain. It coalesces requests, caps cache entries at 256 and caps TTL at 300 seconds. Stop clears the cache. Literal IPs skip DNS. The system resolver uses one worker and at most 64 pending lookups. In-flight `getaddrinfo` calls can finish after cancellation, but late results are discarded.

## Ownership and bounds

| Component | Responsibility |
| --- | --- |
| `ProxyEngine`, `ConnectRequest`, `TLSProcessor`, `ProxySession` | Loopback admission, authentication, TLS record processing and TCP sessions |
| `TransparentPolicy`, `DatagramSession`, `UDPTransport` | Transparent endpoint policy and bounded datagram forwarding |
| `DNSRouting`, `DNSSession`, `HTTPSResolver` | Wire validation, explicit resolver selection, DNS framing and DoH transport |
| `IntegrationLifecycle` and app model controllers | Approval, observed state, recovery and safe UI actions |
| `Extension` and `IntegrationSupport` | Native flow adapters, separately scoped providers and authenticated control channel |

Each engine/provider has a serial owner queue. A TCP read is limited to 64 KiB, CONNECT headers to 8 KiB and the retained first TLS record to 16,389 bytes. A new read waits for the prior send to complete. The default transparent admission limit is 64 combined opening, TCP and UDP flows, configurable up to 256. Each UDP flow has at most 16 numeric destinations, a batch limit of 32 packets or 256 KiB, and finite timeouts. UDP payloads are capped at 65,507 bytes. DNS accepts wire messages up to 32 KiB with bounded framing, exchange and timeout state. Kernel and framework buffers are separate.

The host waits for both an OS-connected state and a fresh provider reply before reporting active routing. DNS readiness uses the app-owned enabled configuration and authenticated bounded XPC messages. The DNS peer requirement is restricted to the signed team and expected bundle identifiers. Stop closes pending and active flows, asks the OS to stop MacDPI's configuration, checks DNS release and reports uncertainty if state is missing. Reopening the host inspects owned state. Launching the app by itself does not request a new activation. Installed lifecycle behavior awaits an authorized test.

TLS record boundaries are independent of TCP packet boundaries. The app uses flow APIs and leaves routing policy, packet handling and transport reliability to the OS. [RFC 8446 record layer](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.1), [Apple transparent proxy provider](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider), [Apple rule restrictions](https://developer.apple.com/documentation/networkextension/netransparentproxynetworksettings/excludednetworkrules).
