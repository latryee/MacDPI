package main

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Native Unix datagram pairs exercise the production relay's net.Conn deadline,
// empty-message and cancellation contract. IP framing is covered separately by
// the IPv4/IPv6 synthetic and native loopback transport fixtures.
func lifecycleDatagramPair(t *testing.T) [2]net.Conn {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, fd := range fds {
			if fd >= 0 {
				unix.Close(fd)
			}
		}
	}()
	var pair [2]net.Conn
	for index, fd := range fds {
		file := os.NewFile(uintptr(fd), "MacDPI datagram lifecycle fixture")
		conn, err := net.FileConn(file)
		file.Close() // FileConn owns a duplicate, including its own poll state.
		fds[index] = -1
		if err != nil {
			t.Fatal(err)
		}
		pair[index] = conn
		t.Cleanup(func() { conn.Close() })
	}
	return pair
}

type lifecycleRelay struct {
	client, upstream net.Conn
	relays           [2]net.Conn
	cancel           context.CancelFunc
	done             chan struct{}
}

func newLifecycleRelay(t *testing.T, idle time.Duration) lifecycleRelay {
	t.Helper()
	local, remote := lifecycleDatagramPair(t), lifecycleDatagramPair(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	f := lifecycleRelay{client: local[1], upstream: remote[1], relays: [2]net.Conn{local[0], remote[0]}, cancel: cancel, done: make(chan struct{})}
	go func() { relayUDP(ctx, local[0], remote[0], idle); close(f.done) }()
	t.Cleanup(func() {
		cancel()
		for _, conn := range []net.Conn{local[0], local[1], remote[0], remote[1]} {
			conn.Close()
		}
		select {
		case <-f.done:
		case <-time.After(2 * time.Second):
			t.Error("datagram relay fixture did not stop after cleanup")
		}
	})
	return f
}

func lifecycleTransfer(t *testing.T, src, dst net.Conn, payload []byte) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	if err := src.SetWriteDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	if err := dst.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	if n, err := src.Write(payload); err != nil || n != len(payload) {
		t.Fatalf("fixture send: %d bytes, %v", n, err)
	}
	var reply [32]byte
	n, err := dst.Read(reply[:])
	if err != nil || !bytes.Equal(reply[:n], payload) {
		t.Fatalf("relay changed a datagram: %x, %v", reply[:n], err)
	}
}

func lifecycleStopped(t *testing.T, f lifecycleRelay) {
	t.Helper()
	select {
	case <-f.done:
	case <-time.After(2 * time.Second):
		t.Fatal("relay did not stop within the bounded lifecycle window")
	}
	for _, conn := range f.relays {
		if _, err := conn.Write([]byte{1}); !errors.Is(err, net.ErrClosed) {
			t.Errorf("relay left a native socket open: %v", err)
		}
	}
}

func TestUDPRelayIdleExpiry(t *testing.T) {
	f := newLifecycleRelay(t, 150*time.Millisecond)
	lifecycleTransfer(t, f.client, f.upstream, []byte("outbound"))
	lifecycleTransfer(t, f.upstream, f.client, []byte("inbound"))
	select {
	case <-f.done:
		t.Fatal("relay stopped before its idle interval")
	case <-time.After(50 * time.Millisecond):
	}
	lifecycleStopped(t, f)
}

func TestUDPRelayOneWayEmptyActivityExtendsIdle(t *testing.T) {
	for _, inbound := range []bool{false, true} {
		name := "outbound"
		if inbound {
			name = "inbound"
		}
		t.Run(name, func(t *testing.T) {
			f := newLifecycleRelay(t, 500*time.Millisecond)
			src, dst := f.client, f.upstream
			if inbound {
				src, dst = dst, src
			}
			lifecycleTransfer(t, src, dst, []byte("start"))
			// Keep only one direction active, with empty datagrams, for more
			// than two original idle intervals. Both read pumps share activity.
			for range 11 {
				time.Sleep(100 * time.Millisecond)
				select {
				case <-f.done:
					t.Fatal("one-way activity did not keep the relay alive")
				default:
				}
				lifecycleTransfer(t, src, dst, nil)
			}
			lifecycleTransfer(t, src, dst, []byte("still alive"))
			lifecycleStopped(t, f) // Then stop naturally after activity ends.
		})
	}
}

func TestUDPRelayCancellationClosesBothDirections(t *testing.T) {
	f := newLifecycleRelay(t, 10*time.Second)
	lifecycleTransfer(t, f.client, f.upstream, []byte("live"))
	f.cancel()
	lifecycleStopped(t, f) // Earlier than either the idle or fixture deadline.
}
