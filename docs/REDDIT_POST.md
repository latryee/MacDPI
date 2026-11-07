# Reddit announcement draft

This is a draft, not a published post. Before posting, make the repository and any advertised downloads accessible, check the selected community's current rules and required flair, and retain the preview label while the outstanding validation is unresolved. Do not advertise this as a stable or universally verified release.

No target community has been selected or its current rules verified. Reddit's [spam policy](https://support.reddithelp.com/hc/en-us/articles/360043504051-Spam) leaves community-specific promotion rules to its moderators. The source link below is the intended repository supplied by the owner; verify public accessibility and uploaded contents before posting.

## Suggested title

MacDPI: an open-source macOS DPI circumvention app, looking for preview testers

## Post body

I'm working on **MacDPI**, a native macOS app for local DPI circumvention. The normal workflow is to open it, press **Enable** and approve the macOS administrator dialog. It handles supported desktop traffic without per-app proxy setup.

It uses a local `utun` interface, a separate unprivileged TCP/UDP engine and TLS ClientHello record splitting. Traffic goes directly to destination servers: there is no remote VPN service or separately installed SpoofDPI/GoodbyeDPI executable. The personal build does not need a paid Apple Developer membership. Disable releases the session's interface and checks that its routes are gone.

What has worked on the development Mac/network:

- The owner confirmed Discord audio in both directions and joining and staying in a Roblox game.
- Certificate-verified public HTTPS, Discord's API and an unauthenticated Gateway WebSocket passed through the real tunnel.
- Local tests cover TCP/UDP integrity, DNS validation, route failure/cleanup and bounded resource handling. The build produces Universal 2 app, ZIP and DMG artifacts with SHA-256 checksums.

**This is still a testing preview.** The live voice/game trial used an earlier build; the later UI/diagnostic changes have separate local verification. One later session stopped unexpectedly with verified cleanup, and its cause is still being investigated. Extended stability, sleep/wake, reconnect and Intel/older-macOS runtime need more testing. UDP forwarding does not mean every UDP or QUIC block can be bypassed.

The package is ad hoc signed, **not notarized**. If macOS declines a downloaded copy, build from reviewed source rather than weakening Gatekeeper or other system protections. The code targets macOS 12 and includes Intel/Apple Silicon slices; runtime evidence so far is Apple Silicon/macOS 26.6.

Automatic setup keeps ordinary System DNS and can use Cloudflare DoH for eligible Discord/Roblox TLS origin repair. There is no telemetry, browsing-history collection, TLS decryption or trusted-certificate installation. The README explains the permissions, privacy behavior and current evidence.

**Source and documentation:** [github.com/latryee/MacDPI](https://github.com/latryee/MacDPI)

I'd appreciate reproducible feedback from other Mac/network combinations, especially Intel and older macOS. Please include the build, macOS version, architecture and a sanitized diagnostic report; keep credentials and private traffic out of issues.
