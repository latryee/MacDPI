# MacDPI 0.2.0 local review

MacDPI now bundles two Universal 2 system extensions. The transparent component handles eligible public TCP and UDP flows through macOS Network Extension. The optional DNS component handles eligible public lookups through Cloudflare DoH and preserves original DNS for local, split and interface-bound queries.

The native interface uses Mac-wide integration by default. A properly provisioned build follows official macOS approval and uses provider acknowledgements to report active routing and stop status. The ad hoc review artifact allows local diagnostics and cannot activate the system components. In that mode the loopback listener uses a per-launch credential. Existing ClientHello splitting remains available and TLS certificate validation stays with the client.

The review ZIP, DMG and checksum are local artifacts. Developer ID signing, notarization, installed lifecycle tests, native Discord voice and Roblox gameplay remain pending. [Capability matrix](../COMPATIBILITY.md), [installation and recovery](../INSTALLATION.md), [engineering report](FINAL_REPORT.md).
