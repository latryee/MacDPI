# Privacy

MacDPI forwards to the original destination. The operating system's network and proxy policy can affect that path. MacDPI has no traffic relay, advertising, telemetry, analytics, account system or update requests.

The transparent provider receives OS-supplied flow metadata and the numeric destination for eligible flows. The local proxy receives CONNECT host and port. Both handle encrypted tunnel bytes and may examine the plaintext first TLS ClientHello to select a record split. Origin TLS remains authenticated end-to-end. MacDPI does not record payloads, hostnames, destinations, passwords or browsing history. Aggregate counters and fixed error categories remain in memory. **Copy report** writes sanitized text to the clipboard only when requested.

The app stores its chosen operation mode, profile, DNS setting, split domains, loopback port and resource limits in preferences. Approved integration scope is stored so the same scope can be enabled again. macOS stores the app-owned provider configurations for approved integration. A fresh app launch inspects status without requesting activation. Launch at login is opt-in. The loopback diagnostic credential stays in memory for the app launch, except when explicitly copied to the clipboard. The OS and clipboard managers can retain clipboard copies.

With Cloudflare DoH enabled, Cloudflare receives selected names and the requester's public IP through certificate-validated HTTPS. The local proxy caches A/AAAA results in bounded RAM until TTL or stop. The separate DNS provider forwards eligible ordinary DNS queries and stores no persistent or provider-level answer cache. Local, split and interface-bound queries use their original resolver. A failed encrypted request remains a failed request. [Cloudflare resolver privacy](https://developers.cloudflare.com/1.1.1.1/privacy/public-dns-resolver/).

The optional web window on macOS 14 and later uses a nonpersistent WebKit data store. Sites can set session cookies and load their own resources. The window denies microphone and camera requests and closes on stop. MacDPI adds no site tracking.

The separate real-network check requires an explicit external-request acknowledgement. It contacts fixed public Discord and Roblox endpoints without credentials. It is excluded from normal local tests and CI. The existing results belong to the historical 0.1.0 local proxy test. [Historical scope](docs/REAL_NETWORK_VALIDATION.md).
