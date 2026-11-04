# Security policy and review

0.1.0 is pre-release software. The review described here is a source and controlled-test review, not an independent security audit. Once published, use the repository's private vulnerability reporting / Security Advisories channel when enabled. Do not put exploit details, browsing data or credentials into public issues; maintainers must configure a private reporting route before a public release.

## Boundaries

- The app is sandboxed with only incoming/outgoing network capabilities. It requests no administrator, filesystem selection, trust, packet capture, system-extension installation or Network Extension entitlement in local mode.
- Listener binds only to IPv4 loopback. It is unauthenticated and accessible to other local processes. It is not an authorization boundary against malicious local software and must never be rebound to a LAN address.
- Only CONNECT requests and permitted destination ports are accepted. Strict ASCII authority/header validation rejects request bodies, transfer encoding, proxy credentials, bare line breaks and malformed input.
- The production address policy rejects private/reserved ranges. DNS resolution results are validated and pinned as numeric addresses before connect. The test exception permits loopback only and is never loaded from GUI preferences.
- No payload logging, TLS interception, root CA, relay, downloaded executable or external runtime dependency exists.
- The TLS parser bounds every length/index and falls back unchanged on unsupported input. End-to-end TLS authentication remains intact because handshake bytes are unchanged.
- Receive sizes, initial buffers, concurrent sessions, DNS work and deadlines are bounded. Backpressure avoids unbounded write queues. Queue ownership and main actor isolation separate networking from UI state. Late callbacks cannot revive disabled sessions or a cancelled startup.
- Optional HTTPS DNS validates server TLS normally and validates bounded DNS responses against the exact query and CNAME chain; private destinations remain blocked. Its cache is RAM-only, TTL-limited, and discarded on stop. Resolver failure does not silently expose names to system DNS. This is not a claim of independent DNSSEC validation.
- The optional WebKit window uses a nonpersistent data store and an explicit proxy with failover disabled. It denies non-HTTPS/native-app navigation and microphone/camera. Web content is handled by Apple's WebKit processes; MacDPI is not a website content blocker, WebRTC leak-prevention tool, password manager, or full browser security product.

Unit tests include deterministic malformed input stress, configuration limits, TLS transcript integrity, cancellation and restart. Socket tests cover overload, malformed traffic, partial handshake deadlines, reset recovery, private-target rejection and resource cleanup. These tests do not prove absence of all parser, race or denial-of-service bugs. Queued lookups are cancelled with their session; an already running `getaddrinfo` call cannot be cancelled; stalled lookups can temporarily exhaust the bounded DNS queue. A malicious local client can occupy the connection limit until its deadline expires.

The optional provider code is compile-tested only. It uses system-approved flow APIs, excludes common local ranges and declines unsupported/over-capacity flows. Transparent-proxy declines allow direct communication, so the design is fail-open and must not be presented as a kill switch. Signing, provisioning, OS approval, filtering interactions and stop/crash semantics require a dedicated integration review before bundling.

## Distribution

Release signatures must use Developer ID Application, secure timestamps and Hardened Runtime, followed by Apple notarization and stapling. Local ad hoc signatures are explicitly labeled and do not establish publisher identity or Gatekeeper acceptance. Do not remove quarantine, disable Gatekeeper/SIP, add firewall exceptions or change trust settings to make an artifact run. The repository contains no credentials or signing identities. Apple frameworks are linked from the OS, not redistributed under the MIT license.
