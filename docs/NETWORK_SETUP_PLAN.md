# Installed integration acceptance plan

The earlier proposal to change the Wi-Fi HTTPS proxy was left unapproved. The Mac-wide acceptance path uses the bundled Network Extension providers. The owner's goal requires separate approval before installation, activation or external service testing.

## Before activation

Obtain a valid Developer ID Application identity and three matching profiles. Build, notarize and verify the complete Universal 2 package. Record the macOS version, hardware, installed filters, VPN, DNS proxies and resolver state on a dedicated test Mac. Review the plan with the owner, including which extensions may be installed, which DNS or network state may change and how long the test will run. Keep a known working way to access System Settings and restore connectivity. [Signing requirements](../BUILDING.md), [Apple deployment matrix](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Activation and rollback

1. Begin with System DNS. Check approval denial and cancellation first. Confirm no app-owned configuration stays active after either.
2. Approve MacDPI in macOS and enable. Require both the OS connection state and a fresh provider reply. On a controlled remote fixture, verify new TCP and UDP flows from a normal client, IPv4 and IPv6 where available, and unchanged LAN reachability. Exercise an existing connection separately.
3. Disable while flows are active. Confirm the provider drain, disconnected state and ordinary network recovery. Repeat through Quit and Emergency stop. If drain or status fails, follow the System Settings recovery procedure immediately. Check the known baseline again.
4. With separate DNS approval, verify local, split and public queries with controlled names. Exercise a DoH failure and verify that the public query fails without an original-resolver retry. Test provider crash, host relaunch, sleep/wake, macOS restart, update and removal. Confirm removal of MacDPI's own preferences and deactivation, including any reboot requirement.
5. Record app and both provider process CPU, RSS and stop duration under controlled traffic. Keep this data separate from the local engine and WebKit benchmarks.

Stop if a provider reports an unknown or unhealthy state, connectivity changes outside the agreed scope, or DNS/VPN state deviates from baseline. Restore only the MacDPI settings through its controls or the official OS UI. Confirm previously recorded third-party settings through their owners before attempting to restore them. [Rollback procedure](../INSTALLATION.md).

## Native application acceptance

Live service checks require separate authorization. The owner handles any account login and interactions. Record coarse status, duration, profile and failure category. Keep credentials, payloads, chat messages and account details out of evidence.

| Target | Verify separately |
| --- | --- |
| Discord desktop | Cold launch, login, API access, gateway establishment, persistence, reconnect and voice signaling |
| Discord voice | Joining, bidirectional audio, stable UDP during the call and recovery after reconnect |
| Roblox desktop | Cold launch, authentication and app startup after browser handoff |
| Roblox gameplay | Joining, stable native play, UDP traffic, timeout and reconnect |

Compare the same actions with ordinary routing and the selected MacDPI profile on the agreed network. Report failures by capability. The earlier 0.1.0 historical results cover selected web/API and unauthenticated WebSocket requests. [Historical validation](REAL_NETWORK_VALIDATION.md).
