# Reddit announcement draft

**Not posted.** The owner deferred Reddit publication. No target community has been selected and no community's current rules or required flair have been checked. Review those before any later posting. Keep the testing-preview label and the evidence boundaries below.

## Suggested title

MacDPI: an open-source macOS DPI circumvention app, looking for preview testers

## Post body

I'm working on **MacDPI**, a native macOS app for local DPI circumvention. Open it, press **Enable** and approve the macOS administrator dialog. It handles supported desktop traffic without per-app proxy setup.

It uses a local `utun` interface, a separate unprivileged TCP/UDP engine and TLS ClientHello record splitting. Traffic goes directly to destination servers; there is no remote VPN service or separately installed SpoofDPI/GoodbyeDPI executable. The personal build does not need a paid Apple Developer membership. Disable releases the session's interface and checks that its routes are gone.

The **0.3.0/build 8 testing preview** has Universal 2 DMG/ZIP downloads and SHA-256 checksums. Build 8 fixes selectable diagnostics accessibility without changing TCP/UDP/TLS/DNS or route behavior. Its macOS 15 ARM/Intel CI and macOS 27.0.1/Xcode 27.2 native job passed; the latter ran 29 model and three UI cases. These are isolated checks, not physical Intel TUN acceptance.

What has worked on the development Mac/network:

- On build 6, the owner confirmed Discord messaging/audio in both directions, a real Roblox game and rejoining both services. No noticeable delay was reported; RTT and exact application-use minutes were not measured.
- All 26 public HTTPS/API checks across 13 rounds passed over the build 6 tunnel. Disable restored all eight policy fingerprints and the resolver baseline, with the interface/helper/engine cleaned up. Earlier unauthenticated Gateway WebSocket evidence belongs to build 3.
- Build 7 preserved the same app/engine/helper and capture route across 10.97 seconds of measured physical sleep. Certificate-verified HTTPS/API passed before and after wake; graceful stop and independent network/resource cleanup passed in 149.75 seconds within the five-minute test limit.

**No build 8 live TUN run is claimed.** The build 6 monitored interval was about 25 min 44 s within a maximum 30-minute setup/test/shutdown window, with no unexpected stop observed. It was not an exact 30-minute Active stability test. Its 307 samples averaged 0.231% of one CPU core and peaked at 152.64 MiB combined app/engine/helper RSS with uncontrolled owner traffic. A separate 121.27-second practical quiet interval averaged 0.066% and peaked at 141.41 MiB (148.28 MB); it did not include sleep.

An older build 3 stop remains unexplained. Longer daily use, repeated/longer sleep, abrupt-crash/network transitions, physical IPv6, broader reconnect coverage and Intel/older-macOS TUN runtime need more testing. UDP forwarding does not mean every UDP or QUIC block can be bypassed.

The package is ad hoc signed, **not Developer ID signed or notarized**. If macOS declines it, build from reviewed source; do not weaken system protections. The code targets macOS 12 and includes Intel/Apple Silicon slices. Real TUN runtime evidence is limited to Apple Silicon/macOS 26.6.

Automatic setup keeps ordinary System DNS and can use Cloudflare DoH for eligible Discord/Roblox TLS origin repair. There is no telemetry, browsing-history collection, TLS decryption or trusted-certificate installation. The README explains permissions, privacy behavior and current evidence.

**Source and documentation:** [github.com/latryee/MacDPI](https://github.com/latryee/MacDPI)

**Downloads:** [Preview release](https://github.com/latryee/MacDPI/releases/tag/v0.3.0-preview.1) · [DMG](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.dmg) · [ZIP](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.zip) · [SHA-256](https://github.com/latryee/MacDPI/releases/download/v0.3.0-preview.1/MacDPI-0.3.0-universal2-personal-adhoc.sha256)

I'd appreciate reproducible feedback from other Mac/network combinations, especially Intel and older macOS. Please include the build, macOS version, architecture and a sanitized diagnostic report; keep credentials and private traffic out of issues.
