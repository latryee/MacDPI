package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

// These tests establish real reconstructed flows through the simulated utun
// and native loopback sockets. They do not create an OS tunnel or change routes.
func TestSyntheticTCPAdmissionLimitAndCancellation(t *testing.T) {
	s := makeSyntheticNetwork(t, false)
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var servers sync.WaitGroup
	t.Cleanup(func() { listener.Close(); servers.Wait() })
	servers.Go(func() {
		for {
			peer, err := listener.Accept()
			if err != nil {
				return
			}
			servers.Go(func() {
				defer peer.Close()
				_ = peer.SetDeadline(time.Now().Add(30 * time.Second))
				_, _ = io.Copy(peer, peer)
			})
		}
	})
	const port = 12347
	upstreams := &capacityUpstreams{}
	ctx, worker := s.attachFor(t, stackOptions{
		dial: upstreams.record(makeFixtureDial(t, s, port, "tcp4", listener.Addr().String())),
		wire: fixturePolicy{},
	}, 30*time.Second)
	t.Cleanup(upstreams.close)
	clients := make([]*gonet.TCPConn, 0, maxTCP+1)
	defer func() {
		for _, client := range clients {
			client.Close()
		}
	}()
	for flow := range maxTCP {
		client, err := gonet.DialContextTCP(ctx, s.client, s.remote(port), s.protocol)
		if err != nil {
			t.Fatalf("admitted TCP flow %d: %v", flow, err)
		}
		clients = append(clients, client)
		capacityTCPEcho(t, client, []byte{byte(flow), 17, 29, 41})
	}
	if got := upstreams.attempts.Load(); got != maxTCP {
		t.Fatalf("%d usable TCP flows made %d upstream attempts", maxTCP, got)
	}

	reject, cancelReject := context.WithTimeout(ctx, 3*time.Second)
	extra, err := gonet.DialContextTCP(reject, s.client, s.remote(port), s.protocol)
	cancelReject()
	if extra != nil {
		extra.Close()
	}
	if err == nil {
		t.Fatal("TCP flow beyond the admission limit unexpectedly connected")
	}
	if got := upstreams.attempts.Load(); got != maxTCP {
		t.Fatalf("rejected TCP flow reached the physical dialer: %d attempts", got)
	}
	capacityTCPEcho(t, clients[maxTCP-1], []byte("usable at capacity"))

	// A graceful half-close must return a slot, not just make it disappear
	// during global shutdown. The same native echo peer observes the FIN.
	if err := clients[0].CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if err := clients[0].SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var tail [1]byte
	if n, err := clients[0].Read(tail[:]); n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("closed TCP flow did not finish its echo: %d %v", n, err)
	}
	clients[0].Close()
	capacityWaitFlows(t, worker, maxTCP-1, 0)
	replacement, err := gonet.DialContextTCP(ctx, s.client, s.remote(port), s.protocol)
	if err != nil {
		t.Fatalf("released TCP slot could not be reused: %v", err)
	}
	clients = append(clients, replacement)
	capacityTCPEcho(t, replacement, []byte("replacement flow"))
	if got := upstreams.attempts.Load(); got != maxTCP+1 {
		t.Fatalf("replacement flow made %d total attempts, want %d", got, maxTCP+1)
	}

	worker.cancel()
	capacityWaitFlows(t, worker, 0, 0)
	upstreams.assertClosed(t)
}

func TestSyntheticUDPAdmissionLimitAndCancellation(t *testing.T) {
	s := makeSyntheticNetwork(t, false)
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var servers sync.WaitGroup
	t.Cleanup(func() { listener.Close(); servers.Wait() })
	servers.Go(func() {
		var buffer [128]byte
		for {
			n, sender, err := listener.ReadFrom(buffer[:])
			if err != nil {
				return
			}
			if _, err := listener.WriteTo(buffer[:n], sender); err != nil {
				return
			}
		}
	})
	const port = 12348
	upstreams := &capacityUpstreams{}
	_, worker := s.attachFor(t, stackOptions{
		dial: upstreams.record(makeFixtureDial(t, s, port, "udp4", listener.LocalAddr().String())),
		wire: fixturePolicy{},
	}, 15*time.Second)
	t.Cleanup(upstreams.close)
	clients := make([]*gonet.UDPConn, 0, maxUDP+1)
	defer func() {
		for _, client := range clients {
			client.Close()
		}
	}()
	for flow := range maxUDP {
		remote := s.remote(port)
		client, err := gonet.DialUDP(s.client, nil, &remote, s.protocol)
		if err != nil {
			t.Fatal(err)
		}
		clients = append(clients, client)
		capacityUDPEcho(t, client, []byte{byte(flow), 3, 7, 11})
	}
	if got := upstreams.attempts.Load(); got != maxUDP {
		t.Fatalf("%d usable UDP flows made %d upstream attempts", maxUDP, got)
	}
	remote := s.remote(port)
	extra, err := gonet.DialUDP(s.client, nil, &remote, s.protocol)
	if err != nil {
		t.Fatal(err)
	}
	clients = append(clients, extra)
	if err := extra.SetDeadline(time.Now().Add(300 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, err := extra.Write([]byte("beyond capacity")); err != nil {
		t.Fatal(err)
	}
	// Existing flows must remain usable after the extra datagram has entered
	// the synthetic packet path. No admitted flow may be evicted for it.
	capacityUDPEcho(t, clients[0], []byte("first still usable"))
	capacityUDPEcho(t, clients[maxUDP-1], []byte("last still usable"))
	var reply [128]byte
	if _, err := extra.Read(reply[:]); err == nil {
		t.Fatal("UDP flow beyond the admission limit unexpectedly received a reply")
	}
	if got := upstreams.attempts.Load(); got != maxUDP {
		t.Fatalf("rejected UDP flow reached the physical dialer: %d attempts", got)
	}
	capacityWaitFlows(t, worker, 0, maxUDP)
	worker.cancel()
	capacityWaitFlows(t, worker, 0, 0)
	upstreams.assertClosed(t)
}

func capacityTCPEcho(t *testing.T, client net.Conn, payload []byte) {
	t.Helper()
	if err := client.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := sendStream(client, payload); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(client, reply); err != nil || !bytes.Equal(reply, payload) {
		t.Fatalf("TCP capacity echo changed: %x %v", reply, err)
	}
}

func capacityUDPEcho(t *testing.T, client net.Conn, payload []byte) {
	t.Helper()
	if err := client.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := sendDatagram(client, payload); err != nil {
		t.Fatal(err)
	}
	var reply [128]byte
	n, err := client.Read(reply[:])
	if err != nil || !bytes.Equal(reply[:n], payload) {
		t.Fatalf("UDP capacity echo changed: %x %v", reply[:n], err)
	}
}

func capacityWaitFlows(t *testing.T, worker *tunnelStack, tcp, udp int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		worker.mu.Lock()
		gotTCP, gotUDP := worker.tcpFlows, worker.udpFlows
		worker.mu.Unlock()
		if gotTCP == tcp && gotUDP == udp {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("flow cleanup: TCP=%d UDP=%d, want TCP=%d UDP=%d", gotTCP, gotUDP, tcp, udp)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

type capacityUpstreams struct {
	attempts atomic.Int32
	mu       sync.Mutex
	conns    []net.Conn
}

func (u *capacityUpstreams) record(dial dialFlow) dialFlow {
	return func(ctx context.Context, protocol string, destination netip.AddrPort) (net.Conn, error) {
		u.attempts.Add(1)
		conn, err := dial(ctx, protocol, destination)
		if err == nil {
			u.mu.Lock()
			u.conns = append(u.conns, conn)
			u.mu.Unlock()
		}
		return conn, err
	}
}

func (u *capacityUpstreams) close() {
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, conn := range u.conns {
		conn.Close()
	}
}

func (u *capacityUpstreams) assertClosed(t *testing.T) {
	t.Helper()
	u.mu.Lock()
	defer u.mu.Unlock()
	for index, conn := range u.conns {
		if _, err := conn.Write([]byte{1}); !errors.Is(err, net.ErrClosed) {
			t.Errorf("native upstream socket %d remained open after cancellation: %v", index, err)
		}
	}
}
