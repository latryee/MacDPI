package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

type fixturePolicy struct {
	transform func([]byte) []byte
	dns       dnsAction
}

func (p fixturePolicy) transformTLS(record []byte) []byte {
	if p.transform == nil {
		return nil
	}
	return p.transform(record)
}
func (p fixturePolicy) routeDNS([]byte) dnsAction { return p.dns }
func (p fixturePolicy) replyDNS(query, reply []byte, _, _ bool) []byte {
	if reply != nil {
		return reply
	}
	failure := bytes.Clone(query)
	failure[2] |= 0x80
	failure[3] = 2 // SERVFAIL; production builds this via Swift DNSPacket.
	return failure
}

type syntheticNetwork struct {
	client   *stack.Stack
	link     *channel.Endpoint
	protocol tcpip.NetworkProtocolNumber
	target   tcpip.Address
}

func makeSyntheticNetwork(t *testing.T, v6 bool) syntheticNetwork {
	t.Helper()
	s := syntheticNetwork{
		client: stack.New(stack.Options{
			NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
			TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
		}),
		link:     channel.New(tunnelQueue, tunMTU, ""),
		protocol: ipv4.ProtocolNumber,
		target:   tcpip.AddrFromSlice(netip.MustParseAddr("198.51.100.9").AsSlice()),
	}
	client := tcpip.AddrFromSlice(netip.MustParseAddr("192.0.2.10").AsSlice())
	subnet, prefix := ipv4AnySubnet(), 32
	if v6 {
		s.protocol = ipv6.ProtocolNumber
		s.target = tcpip.AddrFromSlice(netip.MustParseAddr("2001:db8::9").AsSlice())
		client = tcpip.AddrFromSlice(netip.MustParseAddr("2001:db8:2::10").AsSlice())
		subnet, prefix = ipv6AnySubnet(), 128
	}
	if err := s.client.CreateNIC(tunnelNIC, s.link); err != nil {
		t.Fatal(err)
	}
	if err := s.client.AddProtocolAddress(tunnelNIC, tcpip.ProtocolAddress{
		Protocol: s.protocol, AddressWithPrefix: tcpip.AddressWithPrefix{Address: client, PrefixLen: prefix},
	}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	s.client.SetRouteTable([]tcpip.Route{{Destination: subnet, NIC: tunnelNIC}})
	t.Cleanup(func() { s.client.Close(); s.client.Wait(); s.link.Close() })
	return s
}

func (s syntheticNetwork) remote(port uint16) tcpip.FullAddress {
	return tcpip.FullAddress{NIC: tunnelNIC, Addr: s.target, Port: port}
}

func (s syntheticNetwork) attach(t *testing.T, options stackOptions) context.Context {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range fds {
		// Match Darwin utun's packet queues. AF_UNIX defaults are too small for
		// a normal burst of TCP segments or IPv4/IPv6 UDP fragments.
		for _, option := range []int{unix.SO_RCVBUF, unix.SO_SNDBUF} {
			if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, option, 512<<10); err != nil {
				_ = unix.Close(fds[0])
				_ = unix.Close(fds[1])
				t.Fatal(err)
			}
		}
		if err := unix.SetNonblock(fd, true); err != nil {
			_ = unix.Close(fds[0])
			_ = unix.Close(fds[1])
			t.Fatal(err)
		}
	}
	tun := os.NewFile(uintptr(fds[0]), "synthetic utun")
	peer := os.NewFile(uintptr(fds[1]), "synthetic client")
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	var pumps sync.WaitGroup
	done := make(chan error, 1)
	t.Cleanup(func() {
		cancel()
		_ = peer.Close()
		_ = tun.Close()
		pumps.Wait()
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, os.ErrClosed) {
				t.Errorf("worker did not close cleanly: %v", err)
			}
		case <-time.After(time.Second):
			t.Error("worker did not stop after cancellation")
		}
	})
	worker, err := newTunnel(ctx, options)
	if err != nil {
		done <- err
		t.Fatal(err)
	}
	ready := make(chan struct{})
	go func() {
		done <- worker.serve(tun, func() error { close(ready); return nil })
	}()
	pumps.Go(func() {
		buffer := make([]byte, tunHeader+tunMTU+1)
		for {
			n, err := peer.Read(buffer)
			if err != nil {
				return
			}
			injectFrame(s.link, buffer[:n])
		}
	})
	pumps.Go(func() {
		buffer := make([]byte, tunHeader+tunMTU)
		for {
			p := s.link.ReadContext(ctx)
			if p == nil {
				return
			}
			err := writePacket(peer, buffer, p)
			p.DecRef()
			if err != nil {
				return
			}
		}
	})
	select {
	case <-ready:
		return ctx
	case <-ctx.Done():
		t.Fatal("worker did not become ready")
		return ctx
	}
}

func loopback(v6 bool) (string, string) {
	if v6 {
		return "6", "[::1]:0"
	}
	return "4", "127.0.0.1:0"
}

func makeFixtureDial(t *testing.T, s syntheticNetwork, port uint16, network, target string) dialFlow {
	t.Helper()
	expected := netip.AddrPortFrom(netip.MustParseAddr(s.target.String()), port)
	return func(ctx context.Context, proto string, destination netip.AddrPort) (net.Conn, error) {
		if proto != network[:3] || destination != expected {
			t.Errorf("original endpoint changed: %s %s, want %s %s", proto, destination, network[:3], expected)
			return nil, errors.New("unexpected fixture destination")
		}
		connection, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, network, target)
		if udp, ok := connection.(*net.UDPConn); ok {
			if err := udp.SetWriteBuffer(maxDatagram + 1); err != nil {
				_ = udp.Close()
				return nil, err
			}
		}
		return connection, err
	}
}

func TestSyntheticTCPTunnel(t *testing.T) {
	for _, v6 := range []bool{false, true} {
		family, address := loopback(v6)
		t.Run("IPv"+family, func(t *testing.T) {
			s := makeSyntheticNetwork(t, v6)
			listener, err := net.Listen("tcp"+family, address)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			const greeting = "server first"
			const trailer = "after FIN"
			record := []byte{22, 3, 1, 0, 4, 1, 2, 3, 4}
			tail := bytes.Repeat([]byte{42}, 256<<10)
			transformed := []byte("fixture transformation")
			upload := make(chan []byte, 1)
			go func() {
				remote, err := listener.Accept()
				if err != nil {
					return
				}
				defer remote.Close()
				_ = remote.SetDeadline(time.Now().Add(6 * time.Second))
				_, _ = remote.Write([]byte(greeting))
				request, err := io.ReadAll(remote)
				if err == nil {
					upload <- request
					_, _ = remote.Write([]byte(trailer))
				}
			}()
			options := stackOptions{
				profile: 1,
				dial:    makeFixtureDial(t, s, 443, "tcp"+family, listener.Addr().String()),
				wire: fixturePolicy{transform: func(first []byte) []byte {
					if !bytes.Equal(record, first) {
						t.Errorf("first record changed: %x", first)
					}
					return transformed
				}},
			}
			ctx := s.attach(t, options)
			client, err := gonet.DialContextTCP(ctx, s.client, s.remote(443), s.protocol)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(6 * time.Second))
			prefix := make([]byte, len(greeting))
			if _, err := io.ReadFull(client, prefix); err != nil || string(prefix) != greeting {
				t.Fatalf("missing server-first bytes: %q %v", prefix, err)
			}
			if _, err := client.Write(append(bytes.Clone(record), tail...)); err != nil {
				t.Fatal(err)
			}
			if err := client.CloseWrite(); err != nil {
				t.Fatal(err)
			}
			reply, err := io.ReadAll(client)
			if err != nil || string(reply) != trailer {
				t.Fatalf("half-close lost reply %q: %v", reply, err)
			}
			select {
			case received := <-upload:
				if !bytes.Equal(received, append(bytes.Clone(transformed), tail...)) {
					t.Fatalf("TCP transfer integrity mismatch: %d bytes", len(received))
				}
			case <-ctx.Done():
				t.Fatal("loopback did not receive upload")
			}
		})
	}
}

func TestSyntheticTLSOriginRepair(t *testing.T) {
	s := makeSyntheticNetwork(t, false)
	original := netip.MustParseAddr(s.target.String())
	correct := netip.MustParseAddr("1.1.1.1")
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	const tail = "trailing data"
	first := []byte{22, 3, 1, 0, 4, 1, 2, 3, 4}
	got := make(chan []byte, 3)
	go func() {
		for {
			remote, err := listener.Accept()
			if err != nil {
				return
			}
			_ = remote.SetDeadline(time.Now().Add(5 * time.Second))
			if payload, err := io.ReadAll(remote); err == nil {
				got <- payload
				_, _ = remote.Write([]byte("ok"))
			}
			remote.Close()
		}
	}()
	var exchanges atomic.Int32
	options := stackOptions{
		profile: 1,
		wire:    fixturePolicy{transform: func([]byte) []byte { return []byte("split") }},
		dial: func(ctx context.Context, protocol string, endpoint netip.AddrPort) (net.Conn, error) {
			if protocol != "tcp" || endpoint != netip.AddrPortFrom(correct, 443) {
				t.Errorf("unexpected upstream destination: %s %s", protocol, endpoint)
				return nil, errors.New("unexpected upstream")
			}
			return (&net.Dialer{}).DialContext(ctx, "tcp4", listener.Addr().String())
		},
		encryptedExchange: func(_ context.Context, query []byte) (encryptedDNSAnswer, error) {
			exchanges.Add(1)
			time.Sleep(60 * time.Millisecond)
			if string(query) != "question" {
				t.Errorf("unexpected DNS question: %q", query)
			}
			return encryptedDNSAnswer{message: []byte("answer"), age: 30}, nil
		},
		origin: originRepair{
			candidates: map[netip.Addr]bool{original: true},
			question: func(record []byte, ipv4 bool) ([]byte, error) {
				if !ipv4 || !bytes.Equal(record, first) {
					t.Errorf("unexpected origin repair input: %v %x", ipv4, record)
				}
				return []byte("question"), nil
			},
			addresses: func(query, answer []byte, ipv4 bool) ([]netip.Addr, uint32) {
				if !ipv4 || string(query) != "question" || string(answer) != "answer" {
					t.Errorf("unexpected origin answer: %q %q", query, answer)
				}
				return []netip.Addr{correct}, 60
			},
		},
	}
	ctx := s.attach(t, options)
	for range 3 {
		started := time.Now()
		client, err := gonet.DialContextTCP(ctx, s.client, s.remote(443), s.protocol)
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		_ = client.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err := client.Write(append(bytes.Clone(first), tail...)); err != nil {
			t.Fatal(err)
		}
		if err := client.CloseWrite(); err != nil {
			t.Fatal(err)
		}
		if reply, err := io.ReadAll(client); err != nil || string(reply) != "ok" {
			t.Fatalf("upstream reply failed: %q %v", reply, err)
		}
		t.Logf("repaired TCP connection completed in %v", time.Since(started))
		select {
		case payload := <-got:
			if string(payload) != "split"+tail {
				t.Fatalf("unexpected forwarded bytes: %q", payload)
			}
		case <-ctx.Done():
			t.Fatal("upstream did not record the payload")
		}
	}
	if got := exchanges.Load(); got != 1 {
		t.Fatalf("three repaired connections needed %d encrypted lookups, want one", got)
	}
}

func TestSuspectTLSOriginsRequiresSharedPublicSingleton(t *testing.T) {
	shared := netip.MustParseAddr("1.1.1.1")
	private := netip.MustParseAddr("192.168.0.1")
	other := netip.MustParseAddr("1.0.0.1")
	responses := map[string][]netip.Addr{
		"discord.com.":        {shared, private},
		"gateway.discord.gg.": {shared},
		"www.roblox.com.":     {other},
		"users.roblox.com.":   {other},
	}
	candidates := suspectTLSOrigins(context.Background(), func(_ context.Context, _, name string) ([]netip.Addr, error) {
		return responses[name], nil
	})
	if len(candidates) != 1 || !candidates[other] {
		t.Fatalf("unexpected candidate set: %v", candidates)
	}
}

func TestSyntheticUDPTunnel(t *testing.T) {
	for _, v6 := range []bool{false, true} {
		family, address := loopback(v6)
		t.Run("IPv"+family, func(t *testing.T) {
			s := makeSyntheticNetwork(t, v6)
			listener, err := net.ListenPacket("udp"+family, address)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			if err := listener.(*net.UDPConn).SetWriteBuffer(maxDatagram + 1); err != nil {
				t.Fatal(err)
			}
			go func() {
				buf := make([]byte, maxDatagram+1)
				for {
					n, sender, err := listener.ReadFrom(buf)
					if err != nil {
						return
					}
					if _, err := listener.WriteTo(buf[:n], sender); err != nil {
						if !errors.Is(err, net.ErrClosed) {
							t.Errorf("UDP echo reply: %v", err)
						}
						return
					}
				}
			}()
			const port = 12345
			s.attach(t, stackOptions{
				dial: makeFixtureDial(t, s, port, "udp"+family, listener.LocalAddr().String()),
				wire: fixturePolicy{},
			})
			remote := s.remote(port)
			client, err := gonet.DialUDP(s.client, nil, &remote, s.protocol)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(6 * time.Second))
			buffer := make([]byte, maxDatagram+1)
			for _, length := range []int{0, 3, 4096, 0, maxDatagram, 7} {
				payload := bytes.Repeat([]byte{byte(length + 17)}, length)
				if n, err := client.Write(payload); err != nil || n != len(payload) {
					t.Fatalf("send UDP length %d: %d %v", length, n, err)
				}
				n, sender, err := client.ReadFrom(buffer)
				if err != nil || !bytes.Equal(buffer[:n], payload) || sender.String() != (&net.UDPAddr{
					IP: net.IP(s.target.AsSlice()), Port: port,
				}).String() {
					t.Fatalf("UDP size/source/boundary mismatch: wrote %d, got %d %v %v", length, n, sender, err)
				}
			}
		})
	}
}

func TestEmptyDatagramQueueIsBounded(t *testing.T) {
	s := makeSyntheticNetwork(t, false)
	ctx, stop := context.WithCancel(context.Background())
	worker, err := newTunnel(ctx, stackOptions{
		dial: func(ctx context.Context, _ string, _ netip.AddrPort) (net.Conn, error) {
			// Keep the first flow alive without draining its receive queue.
			<-ctx.Done()
			return nil, ctx.Err()
		},
		wire: fixturePolicy{},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { stop(); worker.close() }()
	remote := s.remote(12345)
	client, err := gonet.DialUDP(s.client, nil, &remote, s.protocol)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	const burst = 700
	for i := 0; i < burst; i++ {
		if _, err := client.Write(nil); err != nil {
			t.Fatal(err)
		}
		pkt := s.link.Read()
		if pkt == nil {
			t.Fatal("fixture client produced no datagram")
		}
		view := pkt.ToView()
		frame, ok := encodeFrame(make([]byte, tunMTU+tunHeader), view.AsSlice())
		if !ok {
			t.Fatal("invalid fixture IP datagram")
		}
		injectFrame(worker.link, frame)
		view.Release()
		pkt.DecRef()
	}
	dropped := worker.stack.Stats().UDP.ReceiveBufferErrors.Value()
	if dropped != burst-512 {
		t.Fatalf("empty packets did not respect the 512-packet budget: dropped %d", dropped)
	}
}

func TestSyntheticUDPLossAndJitter(t *testing.T) {
	s := makeSyntheticNetwork(t, false)
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		buffer := make([]byte, 32)
		for {
			n, sender, err := listener.ReadFrom(buffer)
			if err != nil {
				return
			}
			if n == 2 && buffer[1]%10 != 0 {
				_, _ = listener.WriteTo(buffer[:n], sender)
			}
		}
	}()
	const port, flows, messages = 12346, 4, 20
	s.attach(t, stackOptions{
		dial: makeFixtureDial(t, s, port, "udp4", listener.LocalAddr().String()),
		wire: fixturePolicy{},
	})
	type result struct {
		received, lost int
		rtt, jitter    time.Duration
		jitterSamples  int
		err            error
	}
	results := make(chan result, flows)
	for flow := range flows {
		go func() {
			var measured result
			defer func() { results <- measured }()
			remote := s.remote(port)
			client, err := gonet.DialUDP(s.client, nil, &remote, s.protocol)
			if err != nil {
				measured.err = err
				return
			}
			defer client.Close()
			var previous time.Duration
			var reply [32]byte
			for seq := range messages {
				request := []byte{byte(flow), byte(seq)}
				started := time.Now()
				if err := client.SetDeadline(started.Add(200 * time.Millisecond)); err != nil {
					measured.err = err
					return
				}
				if _, err := client.Write(request); err != nil {
					measured.err = err
					return
				}
				n, err := client.Read(reply[:])
				if isTimeout(err) && seq%10 == 0 {
					measured.lost++
					continue
				}
				if err != nil || seq%10 == 0 || !bytes.Equal(reply[:n], request) {
					measured.err = errors.New("UDP flow lost or misdelivered a reply beyond the injected loss")
					return
				}
				rtt := time.Since(started)
				measured.received++
				measured.rtt += rtt
				if previous > 0 {
					change := rtt - previous
					if change < 0 {
						change = -change
					}
					measured.jitter += change
					measured.jitterSamples++
				}
				previous = rtt
			}
		}()
	}
	var total result
	for range flows {
		sample := <-results
		if sample.err != nil {
			t.Fatal(sample.err)
		}
		total.received += sample.received
		total.lost += sample.lost
		total.rtt += sample.rtt
		total.jitter += sample.jitter
		total.jitterSamples += sample.jitterSamples
	}
	if total.received != 72 || total.lost != 8 {
		t.Fatalf("received %d, lost %d", total.received, total.lost)
	}
	t.Logf("%d flows, %d replies, %d injected drops, mean RTT %v, mean adjacent RTT variation %v",
		flows, total.received, total.lost, total.rtt/time.Duration(total.received), total.jitter/time.Duration(total.jitterSamples))
}

func TestEncryptedDNSNoPlaintextFallback(t *testing.T) {
	query := []byte{0x12, 0x34, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1}
	for _, datagram := range []bool{false, true} {
		worker, err := newTunnel(context.Background(), stackOptions{
			encryptedDNS: true,
			dial: func(context.Context, string, netip.AddrPort) (net.Conn, error) {
				t.Error("encrypted failure fell back to the original resolver")
				return nil, errors.New("unexpected dial")
			},
			wire: fixturePolicy{dns: dnsEncrypted},
			encryptedExchange: func(_ context.Context, got []byte) (encryptedDNSAnswer, error) {
				if !bytes.Equal(got, query) {
					t.Error("encrypted request was changed")
				}
				return encryptedDNSAnswer{}, errors.New("injected DoH timeout")
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		reply := worker.dnsResponse(query, netip.MustParseAddrPort("192.0.2.53:53"), datagram)
		worker.close()
		if len(reply) != len(query) || binary.BigEndian.Uint16(reply) != 0x1234 || reply[3]&15 != 2 {
			t.Fatalf("expected matching SERVFAIL, got %x", reply)
		}
	}
}

type dohFixtureTransport http.Header

func (headers dohFixtureTransport) RoundTrip(_ *http.Request) (*http.Response, error) {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header(headers),
		Body:       io.NopCloser(bytes.NewReader(make([]byte, 12))),
	}, nil
}

func TestEncryptedDNSCacheLifetimeRespectsHTTPMetadata(t *testing.T) {
	for _, trial := range []struct {
		age          string
		cacheControl string
		want         time.Duration
	}{
		{"5", "public, max-age=15", 10 * time.Second},
		{"5", "max-age=3600", 55 * time.Second},
		{"30", "max-age=15", 0},
		{"5", "max-age=15, no-store", 0},
		{"invalid", "max-age=15", 0},
	} {
		client := &http.Client{Transport: dohFixtureTransport{
			"Content-Type":  {"application/dns-message"},
			"Age":           {trial.age},
			"Cache-Control": {trial.cacheControl},
		}}
		answer, err := exchangeDoH(context.Background(), client, make([]byte, 12))
		if err != nil {
			t.Fatal(err)
		}
		if lifetime := answer.cacheLifetime(60); lifetime != trial.want {
			t.Errorf("Age %q, Cache-Control %q: lifetime %v, want %v", trial.age, trial.cacheControl, lifetime, trial.want)
		}
	}
}

func TestDecodeDarwinPacketFamiliesAndBounds(t *testing.T) {
	v4 := make([]byte, 20)
	v4[0] = 0x45
	binary.BigEndian.PutUint16(v4[2:], uint16(len(v4)))
	v6 := make([]byte, 41)
	v6[0] = 0x60
	v6[5] = 1
	for protocol, payload := range map[tcpip.NetworkProtocolNumber][]byte{ipv4.ProtocolNumber: v4, ipv6.ProtocolNumber: v6} {
		frame, ok := encodeFrame(make([]byte, tunHeader+tunMTU), payload)
		decoded, actual, accepted := decodeFrame(frame)
		if !ok || !accepted || decoded != protocol || !bytes.Equal(actual, payload) {
			t.Fatal("valid family did not round trip")
		}
		for _, malformed := range [][]byte{frame[:len(frame)-1], append(bytes.Clone(frame), 0), {0, 0, 0, 99, 0x45}} {
			if _, _, ok := decodeFrame(malformed); ok {
				t.Fatalf("accepted malformed frame %x", malformed)
			}
		}
	}
}
