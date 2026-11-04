# Architecture

## Local data path

```text
Explicitly configured app
  -> IPv4 loopback HTTP CONNECT listener
  -> strict authority/header parser
  -> allowed port + selected system/HTTPS DNS + numeric address policy
  -> direct TCP connection to a pinned, permitted numeric address
  -> bounded initial-flight TLS record processor
  -> two backpressured byte-stream pumps
  -> destination server
```

No upstream relay, root helper, trusted certificate, private TLS key or local TLS termination participates in this path. The client and origin perform the authenticated TLS handshake themselves. The first plaintext ClientHello payload remains byte-for-byte identical; only record headers and boundaries change. Later bytes pass unchanged.

## Source ownership

| Component | Responsibility |
| --- | --- |
| `MacDPI/Core/Configuration.swift` | Versionable configuration, limits, profile and strategy descriptions, engine states, aggregate counters |
| `ConnectRequest.swift` | Bounded HTTP CONNECT parsing; rejects credentials, bodies, transfer encoding and malformed authorities |
| `TLSProcessor.swift` | Bounded ClientHello parsing and deterministic record reframing; no hostname retained |
| `DestinationPolicy.swift` | Public address policy, system DNS worker, pinned numeric connection targets |
| `HTTPSResolver.swift` | Opt-in, bounded DNS-over-HTTPS wire parser/transport, cancellation/coalescing/TTL RAM cache |
| `Transport.swift` | ByteStream protocol and Network.framework TCP adapter |
| `ProxySession.swift` | Handshake/idle deadlines, streaming, backpressure, half-close, cancellation and cleanup |
| `ProxyEngine.swift` | Serial ownership of listener, sessions, enable/disable, capacity and statistics |
| `MacDPI/Models` | Main actor UI state, injected engine/settings store, recovery, service integration |
| `Extension` | Compile-only Network Extension provider and metadata; distinct from local mode |
| `Tools` / `Tests` | Headless CLI, memory-only native TLS fixture, unit and integration tests |

The same core source compiles into the native app, the Swift package library, and the optional provider. The UI is not a dependency of the engine. `EngineControlling`, `HostResolving`, `ByteStream` and `ConfigurationStoring` permit isolated tests without mutating the host.

## Concurrency and bounds

The engine's private serial dispatch queue owns all listener, session and counter mutation. A session's callbacks run on its owning queue. Each direction has one receive outstanding; a subsequent read waits for the previous send's `contentProcessed` completion. There is no per-connection history or unbounded write queue.

Default capacity is 64 connections (configurable 1–256). A TCP read is at most 64 KiB; the retained TLS prefix is at most 16,389 bytes. CONNECT headers are capped at 8 KiB; one receive can additionally contain pipelined tunnel bytes. A session retains only bounded active-flight data. Native frameworks also allocate socket buffers; these are outside the Swift buffer bound. The experimental NE flow adapter rejects reads larger than 64 KiB rather than accumulating an unbounded flow chunk.

The system resolver has one worker and at most 64 pending lookups, protected by a lock. `getaddrinfo` is not cancellable. Per-request cancellation skips queued lookups and discards late results after a session stops, and admission remains bounded even if lookups stall. Literal addresses skip DNS. Resolved numeric addresses are filtered and pinned, preventing DNS rebinding between policy checking and connect. Alternative permitted addresses are tried on connection failure/waiting; this is sequential fallback, not Happy Eyeballs.

The optional HTTPS resolver sends A/AAAA DNS wire-format POST requests to the numeric certificate-validated Cloudflare endpoint. An ephemeral direct URLSession avoids bootstrap DNS poisoning and recursive use of this listener. Responses are limited to 32 KiB while streaming; redirects, credentials, cookies and disk caching are disabled. The parser checks the exact question, response flags, compression-pointer bounds and CNAME ownership before accepting public addresses. Queries coalesce by host with at most 64 waiting sessions, 128 tasks and 256 RAM cache entries (TTL capped at 300 seconds). Cancellation aborts unused tasks; generation IDs discard stale results for a repeated hostname. Stop cancels the transport and erases the cache. No system-DNS fallback is implicit.

The optional web window uses WKWebsiteDataStore's macOS 14+ per-store HTTP CONNECT proxy, `allowFailover = false`, and a nonpersistent data store. It is created only on request, loads no site automatically, and closes on engine disable/quit. It accepts HTTPS navigation only and denies microphone/camera. It does not turn the app into system-wide interception or claim WebRTC/native-game routing.

One event deadline per active session covers CONNECT, DNS, outbound connect and the first TLS flight (default 10 seconds). After deciding the initial flight, activity reschedules a 120-second idle deadline. There are no scans or periodic network requests. AppKit explicitly owns window creation, menu commands, reopen and termination; SwiftUI renders the views. The GUI samples aggregate counters once per second while enabled and avoids publishing unchanged snapshots; it stops this task and NWPathMonitor on disable. Startup operation IDs discard stale callbacks. The provider has separate generation guards and bounded open-flow deadlines.

## Recovery and removal

Disable closes the listener, cancels timers, finishes sessions and prevents stale callbacks from reviving them. The application delegate waits for local engine shutdown before normal Quit. Crashes/forced exits cause the OS to close local sockets; they cannot leave a system proxy or route behind because local mode never creates one. No request or TLS handshake is automatically replayed. Choose Compatibility and explicitly retry a failed request.

The separate provider's stop command disables processing and closes pending/active flows. Its manager integration stops the tunnel, disables the configuration, and removes only its own preferences. Actual system lifecycle, crash recovery, signing and interaction with other VPNs remain unverified. Never infer extension shutdown from the local-mode toggle: this distribution does not install the provider at all.

## Architecture decisions and primary references

- Network.framework supplies supported asynchronous TCP streams. `noDelay` disables Nagle; separate sends do **not** promise TCP packet boundaries. [NWConnection](https://developer.apple.com/documentation/network/nwconnection), [TCP options](https://developer.apple.com/documentation/network/nwprotocoltcp/options)
- TLS handshake fragmentation across records is permitted within record-layer constraints. Only a complete first ClientHello record is rewritten; already fragmented, malformed, oversized and non-ClientHello records fall back unchanged. [RFC 8446 §5.1](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.1)
- `NEAppProxyProvider` supplies flows; `NETransparentProxyProvider` is the appropriate optional transparent mechanism. Direct distribution requires system-extension packaging and the matching entitlements. [Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment), [provider documentation](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider)
- Packet tunnels would require additional packet handling and a user-space transport stack for this design; they are not implemented. No raw socket or IP fragmentation claims are made. [Apple TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)
- Optional DoH supports DNS-blocked environments; Cloudflare trust and disclosure are explicit. DoT is not implemented. DNS alone did not establish TLS to the tested Discord/Roblox endpoints; the dated check also needed record splitting. [DNS wire format](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-wireformat/), [RFC 8484](https://www.rfc-editor.org/rfc/rfc8484), [per-store WebKit proxy](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-cdc1)

Research and SDK declarations were inspected on 2026-11-04. API availability compilation and real-network effectiveness are separate forms of evidence.
