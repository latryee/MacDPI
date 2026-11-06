# Performance

MacDPI 0.3.0 Personal TUN has separate measurements for the synthetic packet path, authorization wait and GUI in local mode. The enabled physical TUN path still needs an authorized trial. [0.3.0 verification and measurements](docs/TUN_VERIFICATION.md).

Local measurements on November 5, 2026 used Apple Silicon, macOS 26.6 and Xcode 27.2. The GUI sample used a development build of the embedded-provider app in isolated diagnostic mode. The headless engine and native socket tests ran on loopback. The measurements exclude installed system extensions, WebKit and external servers.

| Workload | Average CPU, one core = 100% | Resident memory |
| --- | ---: | ---: |
| Native app, idle and disabled, 20 s | 0.750% | 92.30 MiB |
| Native app, idle local listener, 20 s | 0.100% | 90.84 MiB |
| Headless CLI, idle listener, 5 s | 0.000% at sampling resolution | 9.92 MiB |
| Headless CLI, paced 6.25 MiB/s each direction, 3 s | 5.331% | 11.89 MiB |
| Headless CLI, 60 s soak with traffic and connection churn | 4.483% | 14.22 MiB peak sampled |

The two short GUI samples met the idle CPU and memory targets on this Mac. Natural background activity affects both samples, so the difference between the two modes should not be read as a change caused by Enable. The app's engine runs inside the app process. The optional browser would add Apple WebKit processes.

The soak used four persistent tunnels and 300 short connections and verified 375 MiB of payload in each direction. RSS rose from 8.31 MiB to 11.95 MiB after the workload. SIGTERM to process exit took 2.26 ms, with zero active sessions and zero reported failures after orderly half-close. An initial version of the workload used abrupt client close and recorded nine connection errors. The orderly retest separates steady forwarding and graceful shutdown from the reset behavior exercised in the dedicated reset scenario. The run was bounded to one minute and included other host activity.

| Loopback workload | Direct baseline | Through local proxy |
| --- | ---: | ---: |
| Median TCP connect plus one-byte echo, 20 samples | 0.180 ms | 1.030 ms |
| Echo throughput, 4 MiB payload each direction | 1,083.3 MiB/s | 503.2 MiB/s |

The median added connect/echo time was 0.849 ms. Throughput counts both directions in a synthetic unencrypted loopback stream. The existing 150-connection test sampled RSS at 11.89 MiB before and 12.92 MiB after. These bounded runs leave long-term memory growth and physical network throughput unmeasured.

The UDP receive path now uses a temporary uninitialized buffer and copies only the bytes returned by `recvmsg`. Three controlled samples per variant sent 20,000 sequential 1,200-byte datagrams each with byte equality. Median measured Swift process CPU time fell from 0.3263 s to 0.2595 s, about 20.5%, and median elapsed time fell from 0.7870 s to 0.6851 s. These results apply to that loopback transport workload.

A three-second process sample and five-second Instruments Time Profiler trace completed on the idle diagnostic app. The process sample reported 26.2 MiB physical footprint and showed event-loop and kernel waits. Physical footprint and RSS measure different things. Combined provider resources, installed stop latency, sleep/wake and battery behavior await an authorized signed deployment.

```sh
swift build --scratch-path build/swift -c release
xcrun swiftc -swift-version 5 Tools/TLSFixture/main.swift -o build/tls-fixture
python3 scripts/integration.py --soak-seconds 60
python3 scripts/app-idle.py --profile --instruments
```

The profiler attaches to the isolated app process that the harness starts. Run timing workloads sequentially for comparison. Sanitized samples are saved in the versioned verification records. [Local engine](docs/verification/0.2.0-integration.json), [GUI idle](docs/verification/0.2.0-app-idle.json), [soak](docs/verification/0.2.0-soak-clean.json), [UDP comparison](docs/verification/0.2.0-udp-buffer-ab.json).
