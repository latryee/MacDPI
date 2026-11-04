# Compatibility

App and core deployment target: **macOS 12.0**. This keeps Swift concurrency, native SwiftUI materials and the current UI practical without requiring macOS 13-only controls. Network.framework dates to macOS 10.14; SwiftUI to 10.15. A lower target would require UI/concurrency changes and has not been validated.

| Component/platform | Compilation | Runtime validation |
| --- | --- | --- |
| Native app arm64 / macOS 12 target | Verified with Xcode 27.2 / Swift 6.4.2 | macOS 26.6 on Apple Silicon only |
| Native app x86_64 / macOS 12 target | Verified; included in Universal 2 binary | Intel hardware untested |
| Core library + CLI | Native arm64 Debug/Release and tests verified | Apple Silicon/macOS 26.6 |
| Transparent provider arm64 + x86_64 | Verified Universal 2 compilation | Not installed or activated; unverified |
| macOS 12 Monterey | Deployment target/API compilation verified | OS runtime untested |
| macOS 13–15 and other later releases | API target compilation only | OS runtime untested |
| Launch at login | Runtime guarded for macOS 13+ | Registration/unregistration not performed on development host |
| Xcode project | Original `.xcproj` format; Xcode 27.2 verified | Older Xcode cannot be assumed to read it |
| Portable app build / Swift package | Swift 5 language mode, tools 5.9 minimum | Older toolchain execution unverified; CI prepared |
| TLS 1.2 and TLS 1.3 | Complete first ClientHello record reframing | Local certificate-verified handshakes pass for all profiles |
| Fragmented/oversized/non-TLS first flight | Bounded identity fallback | Parser/stream tests pass; no transformation claim |
| ECH | Outer visible ClientHello only | No inner-name access or ECH-specific bypass claim |
| QUIC / HTTP/3 / UDP | Unsupported | Outside CONNECT TCP scope; not silently blocked |
| Cloudflare DNS over HTTPS | Native URLSession / DNS wire format, macOS 12+ | Limited live A/AAAA resolution and HTTPS check pass; IPv6-only routing untested |
| Proxied HTTPS web window | Runtime guarded for macOS 14+ | Uses WKWebsiteDataStore proxyConfigurations; other apps unaffected |
| Real network check | Standard + DoH vs unchanged TLS on 2026-11-04 | Discord API/WebSocket and Roblox site/API pass in one network; [limited scope](docs/REAL_NETWORK_VALIDATION.md) |

The local listener is IPv4 loopback only. Destinations may be public IPv4 or global unicast IPv6. Private, loopback, link-local, multicast, IPv4-mapped IPv6 and NAT64 addresses are rejected in production. This intentionally excludes LAN services and some unusual networks. IPv6 routing/NAT64-only networks have not been runtime-tested. Port 443 is the only GUI destination port.

Standard and Advanced use the same TLS record transformation with different split selection. Compatibility forwards unchanged. An application must support HTTP CONNECT proxy configuration, or use the built-in web window on macOS 14+. SOCKS5 and ordinary plaintext HTTP forwarding are not implemented. Proxy-ignoring applications, existing connections and traffic outside TCP 443 are unaffected. Native Roblox game UDP and Discord voice UDP are outside this release's scope. HTTP/2 over the TLS tunnel is byte-forwarded; controlled HTTP fixtures use HTTP/1.1.

Apple's installed SDK declares NETransparentProxyProvider available from macOS 11; this project uses 12 for consistency. Apple TN3134 documents the system-extension path for direct distribution. Entitlement access, correct Developer ID provisioning and actual approval remain requirements; successful compilation does not establish their availability to a distributor. [Apple deployment matrix](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
