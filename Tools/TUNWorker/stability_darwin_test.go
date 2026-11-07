package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

// This is opt-in so normal unit tests stay short. All packets use an AF_UNIX
// simulated utun and native loopback peers; no routes or system settings change.
// The resource sample includes both TCP/IP stacks and the echo servers, so it
// must not be reported as the installed app/helper's CPU or memory usage.
func TestSyntheticMixedTrafficStability(t *testing.T) {
	raw := os.Getenv("MACDPI_SYNTHETIC_STABILITY_SECONDS")
	if raw == "" {
		t.Skip("set MACDPI_SYNTHETIC_STABILITY_SECONDS=5..60 for the bounded local workload")
	}
	seconds, err := strconv.Atoi(raw)
	if err != nil || seconds < 5 || seconds > 60 {
		t.Fatal("MACDPI_SYNTHETIC_STABILITY_SECONDS must be an integer from 5 to 60")
	}
	duration := time.Duration(seconds) * time.Second
	for _, v6 := range []bool{false, true} {
		family, address := loopback(v6)
		t.Run("IPv"+family, func(t *testing.T) {
			tcpPeer, err := net.Listen("tcp"+family, address)
			if err != nil {
				t.Fatal(err)
			}
			udpPeer, err := net.ListenPacket("udp"+family, address)
			if err != nil {
				tcpPeer.Close()
				t.Fatal(err)
			}
			var servers sync.WaitGroup
			t.Cleanup(func() { tcpPeer.Close(); udpPeer.Close(); servers.Wait() })
			servers.Go(func() {
				for {
					conn, err := tcpPeer.Accept()
					if err != nil {
						return
					}
					servers.Go(func() {
						defer conn.Close()
						_ = conn.SetDeadline(time.Now().Add(duration + 10*time.Second))
						_, _ = io.Copy(conn, conn)
					})
				}
			})
			servers.Go(func() {
				buffer := make([]byte, 2048)
				for {
					n, sender, err := udpPeer.ReadFrom(buffer)
					if err != nil {
						return
					}
					if _, err := udpPeer.WriteTo(buffer[:n], sender); err != nil {
						return
					}
				}
			})
			s := makeSyntheticNetwork(t, v6)
			_, worker := s.attachFor(t, stackOptions{
				profile: 1, wire: fixturePolicy{},
				dial: func(ctx context.Context, proto string, endpoint netip.AddrPort) (net.Conn, error) {
					port, peer := uint16(443), tcpPeer.Addr().String()
					if proto == "udp" {
						port, peer = 12345, udpPeer.LocalAddr().String()
					}
					return makeFixtureDial(t, s, port, proto+family, peer)(ctx, proto, endpoint)
				},
			}, duration+10*time.Second)
			before := sampleSyntheticResources(t)
			started := time.Now()
			ctx, cancel := context.WithTimeout(context.Background(), duration)
			defer cancel()
			type result struct {
				bytes uint64
				rtts  []float64
				err   error
			}
			const flows = 4
			results := make(chan result, flows*2)
			for flow := range flows {
				for _, datagram := range []bool{false, true} {
					go func() {
						var measured result
						defer func() { results <- measured }()
						var conn net.Conn
						if datagram {
							remote := s.remote(12345)
							conn, measured.err = gonet.DialUDP(s.client, nil, &remote, s.protocol)
						} else {
							conn, measured.err = gonet.DialContextTCP(ctx, s.client, s.remote(443), s.protocol)
						}
						if measured.err != nil {
							return
						}
						defer conn.Close()
						size, pace := 16<<10, 16*time.Millisecond
						if datagram {
							size, pace = 1200, 20*time.Millisecond
						}
						payload := bytes.Repeat([]byte{byte(flow + 1)}, size)
						reply := make([]byte, size+1)
						ticker := time.NewTicker(pace)
						defer ticker.Stop()
						for sequence := uint64(0); ; sequence++ {
							select {
							case <-ctx.Done():
								return
							case <-ticker.C:
							}
							binary.BigEndian.PutUint64(payload[len(payload)-8:], sequence)
							sent := time.Now()
							if measured.err = conn.SetDeadline(sent.Add(3 * time.Second)); measured.err != nil {
								return
							}
							if datagram {
								measured.err = sendDatagram(conn, payload)
							} else {
								measured.err = sendStream(conn, payload)
							}
							if measured.err != nil {
								return
							}
							var n int
							if datagram {
								n, measured.err = conn.Read(reply)
							} else {
								n, measured.err = io.ReadFull(conn, reply[:size])
							}
							if measured.err != nil {
								return
							}
							if !bytes.Equal(reply[:n], payload) {
								measured.err = fmt.Errorf("flow %d datagram=%t sequence=%d payload mismatch", flow, datagram, sequence)
								return
							}
							measured.bytes += uint64(n)
							if datagram {
								measured.rtts = append(measured.rtts, float64(time.Since(sent).Microseconds())/1000)
							}
						}
					}()
				}
			}
			var tcpBytes, udpBytes uint64
			var rtts []float64
			for range flows * 2 {
				measured := <-results
				if measured.err != nil {
					t.Errorf("mixed transport: %v", measured.err)
				}
				if measured.bytes == 0 {
					t.Error("a flow made no progress")
				}
				if len(measured.rtts) == 0 {
					tcpBytes += measured.bytes
				} else {
					udpBytes += measured.bytes
					rtts = append(rtts, measured.rtts...)
				}
			}
			elapsed := time.Since(started).Seconds()
			after := sampleSyntheticResources(t)
			worker.cancel()
			deadline := time.Now().Add(2 * time.Second)
			var remainingTCP, remainingUDP int
			for {
				worker.mu.Lock()
				remainingTCP, remainingUDP = worker.tcpFlows, worker.udpFlows
				worker.mu.Unlock()
				if remainingTCP+remainingUDP == 0 || time.Now().After(deadline) {
					break
				}
				time.Sleep(time.Millisecond)
			}
			if remainingTCP+remainingUDP != 0 {
				t.Errorf("flows remained after cancellation: TCP=%d UDP=%d", remainingTCP, remainingUDP)
			}
			runtime.GC()
			cleaned := sampleSyntheticResources(t)
			sort.Float64s(rtts)
			report := map[string]any{
				"scope": "synthetic packet path, client stack and loopback peers; no active system TUN",
				"go":    runtime.Version(), "architecture": runtime.GOARCH, "seconds": elapsed,
				"tcp_flows": flows, "udp_flows": flows,
				"tcp_verified_bytes_each_direction": tcpBytes, "udp_verified_bytes_each_direction": udpBytes,
				"udp_verified_replies": len(rtts), "resource_before": before,
				"resource_after_traffic": after, "resource_after_cancel_and_gc": cleaned,
				"cpu_percent_one_core": 100 * (after.CPUSeconds - before.CPUSeconds) / elapsed,
				"remaining_tcp_flows":  remainingTCP, "remaining_udp_flows": remainingUDP,
			}
			if len(rtts) > 0 {
				report["udp_rtt_median_ms"] = rtts[len(rtts)/2]
				report["udp_rtt_p95_ms"] = rtts[(len(rtts)-1)*95/100]
				report["udp_rtt_max_ms"] = rtts[len(rtts)-1]
			}
			encoded, err := json.Marshal(report)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("MACDPI_MEASUREMENT %s", encoded)
		})
	}
}

type syntheticResources struct {
	CPUSeconds float64 `json:"cpu_seconds"`
	RSSMiB     float64 `json:"rss_mib"`
	HeapMiB    float64 `json:"go_heap_mib"`
}

func sampleSyntheticResources(t *testing.T) syntheticResources {
	t.Helper()
	var usage unix.Rusage
	if err := unix.Getrusage(unix.RUSAGE_SELF, &usage); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command("/bin/ps", "-o", "rss=", "-p", strconv.Itoa(os.Getpid())).Output()
	if err != nil {
		t.Fatal(err)
	}
	rssKiB, err := strconv.ParseFloat(strings.TrimSpace(string(output)), 64)
	if err != nil {
		t.Fatal(err)
	}
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	return syntheticResources{
		CPUSeconds: float64(usage.Utime.Sec+usage.Stime.Sec) + float64(usage.Utime.Usec+usage.Stime.Usec)/1e6,
		RSSMiB:     rssKiB / 1024, HeapMiB: float64(memory.HeapAlloc) / (1 << 20),
	}
}
