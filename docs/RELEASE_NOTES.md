# MacDPI 0.1.0 — pre-release review

MacDPI introduces an independently implemented native HTTP CONNECT proxy that splits the first complete TLS ClientHello into two records while preserving its handshake bytes. Standard and Advanced perform this transformation; Compatibility forwards unchanged. No TLS interception, trusted certificates, relays, telemetry or accounts are used.

The app includes native controls, menu bar access, bounded streaming, concurrency limits, timeouts, safe shutdown and sanitized diagnostics. Packages target macOS 12+ and contain both arm64 and x86_64 slices. Local runtime tests currently cover Apple Silicon/macOS 26.6. Review TEST_RESULTS.md and PERFORMANCE.md for the exact evidence.

A limited real-network check on 2026-11-04 passed Discord API/WebSocket and Roblox site/public API connections with Standard plus optional Cloudflare DNS over HTTPS; unchanged TLS timed out. [Evidence and scope](REAL_NETWORK_VALIDATION.md). The macOS 14+ isolated web window provides an HTTPS session without system network changes. Enable alone does not route other applications. Native games/voice UDP, QUIC, automatic strategy selection and DoT remain unsupported. The transparent provider is separately compiled, omitted from ordinary packages and not activated or integration-tested.

Local artifacts use ad hoc signatures and are labeled `local-adhoc`; they are not notarized public downloads. Public distribution needs Developer ID signing, Apple notarization/stapling, Intel/older-OS runtime testing and maintainer review. Do not bypass Gatekeeper. No release was uploaded or published by development scripts.
