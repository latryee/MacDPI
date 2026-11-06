# TUN route transaction and recovery

MacDPI captures eligible public destinations through an interface it owns for one session. The route broker retains the privileged descriptor. The unprivileged packet engine uses a duplicate. The broker verifies the current physical path and refuses activation when it detects a conflicting tunnel, ambiguous primary service, enabled IP forwarding, or overlap with its virtual interface addresses.

## Activation

1. Read the kernel route table and interface list. Record the primary service, IPv4 and IPv6 defaults, existing protected destinations, and fingerprints of DNS and proxy state and service order. Keep the original default routes. Use only the address families with a usable physical default.
2. Create the session's point-to-point interface and check the baseline again. Reserve its `198.18.0.0/30` IPv4 range and, when IPv6 is available, `fd75:554e:4d44:5049::/64`. Reject an overlap before creating the interface.
3. Compute a bounded, disjoint prefix cover of public destinations. Leave LAN, loopback, link-local, multicast, special-use and existing protected prefixes out. Existing more-specific routes retain precedence. A route conflict or an oversized plan aborts activation.
4. Confirm engine readiness and that interface-scoped route lookups select the physical path. Save the complete intended route set in the private, exclusively locked journal before the first route addition. The journal contains interface and route ownership records. DNS names, proxy values and service identifiers stay out of it.
5. Use `RTM_ADD` with the live interface as link-layer gateway. Verify all expected routes in a fresh kernel snapshot and recheck scoped egress. Report active only after the checks pass.

The route broker uses the macOS kernel control interface, the route socket and the System Configuration store. The UDP and TCP forwarders must bind to the recorded physical interface for each captured address family. System DNS and proxy settings are left as found. A DNS resolver on a protected private network remains outside the public route cover. [Darwin route socket](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c), [utun implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c).

## Disable and crash recovery

The broker asks the engine to release its duplicate and closes its own descriptor. Darwin detaches the interface and walks the route tables to remove entries associated with that interface. The broker uses read-only snapshots to verify that both the interface and its associated entries are gone. It clears the journal only after this check. A failed verification leaves a recovery-required result and preserves the record. [Darwin interface teardown](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/dlil.c), [protocol route removal](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/dlil_subr.c), [interface-specific route purge](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if.c).

Darwin's `RTM_DELETE` uses the destination, mask and route scope. A lookup followed by deletion is subject to races with another process changing a route at the same key. MacDPI therefore uses descriptor ownership to relinquish the interface and does not issue route deletions. Recovery after broker death inspects the journal and observed state. A still-present or reused interface index is ambiguous and requires investigation. The recovery audit cannot adopt an interface by its name or remove an unrelated route. [Darwin route delete implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.c).

The route transaction can react to engine loss or changed network state when the broker calls its health check. IPv4 or IPv6 default changes, a changed primary service, conflicting routes, DNS and proxy changes, and unexpected disappearance of an installed route are reasons to release the session. Changes from another app remain in place. When the broker confirms cleanup after a startup or health failure, the app shows a failed session with verified cleanup. A user-requested stop with the same cleanup proof shows Disabled. If the connection drops before the broker can confirm cleanup, the app shows Recovery required.

## Verification boundaries

Run the fault-injected route and journal tests and the separate native read-only fixture as a normal user.

```sh
swift test --filter TUNRouteTests
scripts/test-tun-route-snapshot.sh
```

The route tests exercise IPv4 and IPv6 cover, preserved networks, conflict rejection, duplicate activation, partial write failures, journal faults, engine death, network switching, ambiguous crash recovery and a concurrent route replacement. The native fixture decodes actual route data with `NET_RT_DUMP2` and uses `RTM_GET` for scoped egress. It prints counts and address families. It plans capture using a synthetic interface index without creating the interface or adding routes.

Real interface creation, route insertion, teardown after both descriptors close, VPN transitions and sleep/wake require the approved live test. Verify normal connectivity with a known endpoint after Disable. A mock teardown or a successful read-only snapshot cannot establish that macOS restored a live session.
