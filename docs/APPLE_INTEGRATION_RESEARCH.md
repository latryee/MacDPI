# Apple networking integration evidence

Reviewed 2026-11-05. This records the source and packaging decisions. Builds and loopback
fixtures do not establish that macOS has approved, installed, or activated either provider.

## Supported provider architecture

MacDPI uses a host application with two separately identified Network Extension system
extensions. The transparent provider declares the app-proxy extension point and the
`app-proxy-provider-systemextension` capability. The DNS provider declares the dns-proxy
extension point and `dns-proxy-systemextension`. Apple documents these Developer ID
capabilities for handling TCP/UDP flows and DNS queries respectively. The host requests
both capabilities and `com.apple.developer.system-extension.install` in a provisioned
distribution. The DNS component is optional at runtime; forwarding generic UDP does not
provide encrypted DNS or UDP-specific circumvention. [Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension),
[System Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install).

Each SYSX executable calls `NEProvider.startSystemExtensionMode()` through the existing
extension entry point. Its own `NetworkExtension/NEProviderClasses` mapping names one
compiled provider class. Both targets explicitly use the `MacDPITransparentProxy` Swift
module so their plist class names match the actual runtime classes. The same source set
can be compiled into both independently signed bundles. [startSystemExtensionMode](https://developer.apple.com/documentation/networkextension/neprovider/startsystemextensionmode()).

The three bundle identifiers are `io.github.latryee.MacDPI`,
`io.github.latryee.MacDPI.TransparentProxy`, and `io.github.latryee.MacDPI.DNSProxy`.
Both children are embedded in the host's `Contents/Library/SystemExtensions` directory.
System extensions run in user space; their source and packaging do not require kernel
extensions or changes to operating-system protections. [System Extensions](https://developer.apple.com/system-extensions/).

## Control channel and app groups

Each provider declares its own `NEMachServiceName` inside the shared app-group namespace:
`TEAMID.io.github.latryee.MacDPI.shared.TransparentProxy` and
`TEAMID.io.github.latryee.MacDPI.shared.DNSProxy`. The shared entitlement is
`TEAMID.io.github.latryee.MacDPI.shared`. Apple's developer support explains that the Mach
service must have an entitled app group as a prefix. The source templates use the explicit
`MACDPI_TEAM_PREFIX` build setting; release preparation replaces it with the validated team
prefix. The ordinary Xcode default is `UNPROVISIONED.` and cannot represent a distribution
identity. [Apple DTS explanation of the service/app-group relationship](https://developer.apple.com/forums/thread/776759).

The host/provider control channel uses only these declared provider services. Apple's
Filtering Network Traffic sample demonstrates host-to-system-extension communication;
Apple DTS clarifies that an NE system extension declares its launchd service through
`NEMachServiceName`, rather than registering arbitrary service names. No temporary
Mach-lookup or Mach-register sandbox exceptions are added. The control bridge verifies
an exact same-team Developer ID peer requirement and carries bounded control messages.
Actual IPC access after activation still requires an authorized on-device test.
[Filtering Network Traffic sample](https://developer.apple.com/documentation/networkextension/filtering-network-traffic),
[Apple DTS explanation of declared service names and update caveats](https://developer.apple.com/forums/thread/779395).

The service names are stable for this version. Apple DTS reports an extension-update
service-cache issue in the latter thread. Installation, replacement, process restart,
IPC reconnection, and uninstall recovery must therefore be checked on an approved build;
source-level state-machine tests alone cannot establish those behaviors.

## Signing and distribution gates

The safe default is an ad hoc `local-review` build. Its host claims only sandbox, network
client, and network server permissions. Its two children retain separately scoped review
metadata and provider capabilities but are unprovisioned. The host's runtime lifecycle
guard must reject activation from this build mode.

The native release builder enters `developer-id` mode only with explicit `SIGN_IDENTITY`,
`MACDPI_TEAM_ID`, `MACDPI_HOST_PROFILE`, `MACDPI_EXTENSION_PROFILE`, and
`MACDPI_DNS_PROFILE` inputs. It checks exact identifiers, each component's capabilities,
team, expiration, all-device distribution, and disabled
debugger access. After signing, `codesign` verifies each architecture against a same-team
Developer ID requirement; the actual leaf certificate must appear in that component's
explicit profile. Each bundle embeds its own profile, and nested code is signed before
the host. These build checks are additional safeguards, not substitutes for macOS
provisioning enforcement or Gatekeeper. Apple notes that some macOS entitlements,
including macOS app groups and sandbox permissions, are unrestricted; the release
preflight therefore accepts profiles that omit unrestricted app-group grants. The verifier
instead requires the actual signed app-group entitlement and Mach service prefix to match
the configured team exactly.
[TN3125: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

Normal builds do not submit to Apple. The separate operator-run notarization script
requires an already provisioned Developer ID application, creates and verifies a fresh
archive, submits it with an existing keychain profile, staples the application, and reruns the
notarization/Gatekeeper gate. Credentials and approval are still required before that
workflow can be verified. [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## UDP verification boundary

The independent core UDP transport uses public BSD sockets, nonblocking I/O, dispatch
read/write readiness sources, and optional `IP_BOUND_IF`/`IPV6_BOUND_IF` interface binding.
It creates a connected outbound socket, not a relay listener. `recvmsg` preserves a
zero-byte message as a complete datagram and exposes truncation explicitly; it is not
interpreted as stream EOF. Numeric endpoint validation and finite endpoint, byte, packet,
and inactivity bounds are enforced by `DatagramSession`.
[recvmsg manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/recvmsg.2.html),
[DispatchSource](https://developer.apple.com/documentation/dispatch/dispatchsource).

Loopback tests exercise IPv4 and IPv6, interface binding, empty datagrams before/between/
after ordinary messages, and 65,507-byte payloads. Generic transparent UDP uses this same
BSD transport. It does not attach the original app's Network Extension metadata: another
network filter sees the provider's outbound socket identity. Provider identity exclusions
are required to prevent recursive interception. A bound original flow's interface index
is preserved with the public socket binding options.

The isolated native-adapter investigation also exercised the C Network.framework UDP
bridge against an independent BSD echo server. With an empty UDP message followed by a
five-byte message, the empty reply completed, but the next receive returned ENODATA (96).
Using raw `dispatch_data_empty` did not solve this observed behavior on this host/SDK.
It is recorded as an observed limitation, not a universal statement about every OS or an
Apple-documented guarantee. Generic UDP therefore uses BSD sockets; the C UDP bridge is
limited to validated nonempty original-DNS exchanges. No connection restart or intentional
packet loss is used as a substitute for correct datagram semantics.

The native TCP fixture uses the actual provider C Network.framework adapter with nil flow
metadata against an ordinary loopback server. It verifies eight MiB of binary payload,
serial 65,536-byte content-processed sends, delayed-reader backpressure, and receipt of a
server trailer after closing only the client's write side. These fixtures do not create an
`NEAppProxyFlow` or register either provider. Actual interception and metadata propagation
remain approval-dependent. No Discord voice, Roblox gameplay, QUIC
circumvention, system-wide routing, Developer ID deployment, or extension activation is
established by these isolated UDP tests.

## Flow policy and coexistence

The all-outbound rule uses nil remote and local endpoints. The provider declines ordinary DNS and ineligible endpoints at admission. Explicit CIDR exclusions use a non-wildcard address for all-port matches. Apple's rules disallow wildcard addresses paired with port zero and explicit port 53 matches. [NENetworkRule initializer](https://developer.apple.com/documentation/networkextension/nenetworkrule/init%28remotenetwork%3Aremoteprefix%3Alocalnetwork%3Alocalprefix%3Aprotocol%3Adirection%3A%29), [rule restrictions](https://developer.apple.com/documentation/networkextension/netransparentproxynetworksettings/excludednetworkrules).

The native TCP and original DNS bridge requests a direct connection and preserves original source metadata through the public Network API. A prefer-no-proxy setting can fall back to a configured proxy if the direct path fails. App-proxy ordering, PAC interactions and re-injection remain installed-test cases. [Apple DTS on proxy preferences](https://developer.apple.com/forums/thread/828775), [flow metadata](https://developer.apple.com/documentation/networkextension/neappproxyflow/setmetadata(_:)).
