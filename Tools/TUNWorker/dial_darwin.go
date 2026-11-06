package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func isPhysicalInterface(index int) bool {
	if index == 0 {
		return true
	}
	iface, err := net.InterfaceByIndex(index)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return false
	}
	// Refuse a TUN/VPN interface as the egress even when supplied by mistake.
	return !strings.HasPrefix(iface.Name, "utun") && !strings.HasPrefix(iface.Name, "ipsec") &&
		!strings.HasPrefix(iface.Name, "ppp")
}

func physicalDialer(ipv4Index, ipv6Index int) dialFlow {
	return func(ctx context.Context, network string, address netip.AddrPort) (net.Conn, error) {
		if network != "tcp" && network != "udp" {
			return nil, errors.New("unsupported egress protocol")
		}
		if !address.IsValid() || address.Port() == 0 || !publicEgress(address.Addr()) {
			return nil, errors.New("invalid egress endpoint")
		}
		var index, level, option int
		if address.Addr().Is4() {
			network += "4"
			index, level, option = ipv4Index, unix.IPPROTO_IP, unix.IP_BOUND_IF
		} else {
			network += "6"
			index, level, option = ipv6Index, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF
		}
		if index <= 0 {
			return nil, errors.New("egress family has no physical route")
		}
		dialer := net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
			ControlContext: func(_ context.Context, _, _ string, socket syscall.RawConn) error {
				var bindErr error
				if err := socket.Control(func(fd uintptr) {
					bindErr = unix.SetsockoptInt(int(fd), level, option, index)
				}); err != nil {
					return err
				}
				return bindErr
			},
		}
		// Binding failure is terminal. Retrying on an unbound socket could
		// capture the worker's own connection and recurse into the TUN.
		connection, err := dialer.DialContext(ctx, network, address.String())
		if err != nil {
			return nil, err
		}
		if datagram, ok := connection.(*net.UDPConn); ok {
			// Darwin's default UDP send buffer can be only 9 KiB. Raise it per
			// socket so a reassembled datagram is sent once with its boundary intact.
			if err := datagram.SetWriteBuffer(maxDatagram + 1); err != nil {
				_ = connection.Close()
				return nil, err
			}
		}
		return connection, nil
	}
}

var virtualIPv4 = netip.MustParsePrefix("198.18.0.0/15")

func publicEgress(address netip.Addr) bool {
	// The route plan already excludes these networks. In particular, the
	// virtual interface's connected route must not expose its peer via egress.
	return address.IsGlobalUnicast() && !address.IsPrivate() && address.Zone() == "" && !virtualIPv4.Contains(address)
}
