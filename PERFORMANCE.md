# Performance — measured 2026-11-04

These are local engineering measurements, not guarantees. Final Release builds ran on Apple Silicon/macOS 26.6 with Xcode 27.2 / Swift 6.4.2. Native GUI idle sampling ran after build/tests finished. The latest loopback regression benchmark ran concurrently with native UI testing; its timing figures describe that workload. Ordinary OS and other-application activity was not controlled. The GUI was visible. No system networking settings were changed.

## Actual results

| Scenario | Average CPU (one core = 100%) | Resident memory |
| --- | ---: | ---: |
| Native app, disabled, 20.0 s sample | 0.050% | 93.33 MiB |
| Native app, enabled and idle, 20.0 s sample | 0.250% | 94.92 MiB |
| Headless engine, enabled and idle, 5.0 s sample | 0.000% at sampler resolution | 7.64 MiB |
| Headless engine, paced transfer, 3.0 s | 4.664% | 11.30 MiB |

The app includes its engine in the same process; there is no helper to add to its idle RSS. No provider is installed. The paced workload sends 18.75 MiB each direction over one tunnel, using 64 KiB messages at 100 messages/second (6.25 MiB/s each way). CPU includes MacDPI alone, not the Python fixture server/client. RSS is measured by `/bin/ps`, not a claim about physical footprint.

| Local loopback benchmark | Direct baseline | Through proxy |
| --- | ---: | ---: |
| Median TCP connect + one-byte echo, 20 samples each | 0.240 ms | 1.074 ms |
| Bulk echo, 4 MiB each direction | 1034.9 MiB/s | 447.3 MiB/s |

Measured median added connect/echo time: 0.834 ms. Throughput counts both directions (8 MiB total), using repeated 64 KiB round trips. It is a small synthetic echo measurement, **not** WAN bandwidth, encrypted bulk throughput, or a prediction for a physical interface. Bulk payloads intentionally use an unmodified non-TLS tunnel stream; TLS 1.2/1.3 handshakes are separately function-tested.

The 150-connection stability sample changed headless RSS from 11.30 to 12.33 MiB. Allocator/framework caches can retain resident pages; this short run does not prove long-term absence of leaks. Shutdown reports zero sessions, and the listener is no longer reachable. Same-port restart after an active tunnel shutdown also passes.

The default idle measurements do not open the optional web window or load a site. Opening it creates Apple WebKit content/network processes and executes website code; that combined workload can exceed the default 150 MB idle target and has not been profiled here. Encrypted-DNS request overhead was function-tested on the live network but was not isolated as a separate CPU/battery benchmark.

## Investigation and limits

The idle goals are below 1% average CPU and below 150 MB combined app/helper memory. Compare the measured values above directly with those goals; short samples and normal OS activity vary. Initial 8-second GUI samples included an enabled result of 1.123% CPU. Unchanged snapshots now avoid UI publication/redraw. Longer final samples use a 9-second settling period and 20-second measurement window; differences cannot be attributed solely to the redraw change because window lifetime and sampling conditions also changed.

A controlled paced-transfer run initially measured 11.325% headless CPU with 16 KiB reads. Increasing bounded streaming reads to 64 KiB reduced an earlier sequential sample to 3.997% under the same fixture workload. The latest 4.664% sample also had native UI tests running, so it is not a controlled comparison. The retained TLS prefix remains capped at 16,389 bytes. This trades a larger bounded per-flow read for fewer callbacks. Only the latest sanitized reports are retained after cleanup. The earlier 16 KiB figure is recorded here as a historical measurement; the comparison has no statistical confidence interval.

`/usr/bin/sample` was run against only the generated app process for three seconds at 10 ms intervals, after CPU measurement. It completed without administrator execution. The report primarily shows event-loop/kernel waits. The completed profiler output was removed during the requested cleanup; physical footprint and RSS are different measures. No long Instruments, battery, sleep/wake, maximum-capacity soak or real-network performance campaign was performed.

## Reproduce

```sh
swift build --scratch-path build/swift -c release
xcrun swiftc -swift-version 5 Tools/TLSFixture/main.swift -o build/tls-fixture
python3 scripts/integration.py
scripts/build-app.sh
python3 scripts/app-idle.py --profile
```

Run these workloads sequentially. The profiler samples only the process launched by the benchmark. Test mode uses in-memory preferences and a temporary unprivileged loopback port. Per-case waits and traffic are bounded; there is no persistent monitoring service. The production app starts disabled, and disable cancels its refresh task, path monitor, listener, sessions, queued resolver work and session timers. An OS DNS lookup already in progress cannot be force-cancelled; its result is discarded.

Sanitized raw results: [integration](docs/verification/integration.json), [app idle](docs/verification/app-idle.json). Detailed profiler stacks and intermediate test artifacts were removed after verification at the user’s request; final sanitized summaries remain in `docs/verification/`.
