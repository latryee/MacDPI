//go:build macdpi_archive

package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../IntegrationSupport
#include "TUNWireBridge.h"
*/
import "C"

import (
	"context"
	"errors"
	"io"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

type swiftWire struct {
	profile C.int32_t
	offset  C.int32_t
	domains []byte
}

func borrowed(bytes []byte) *C.uint8_t {
	return (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(bytes)))
}

func (p swiftWire) transformTLS(input []byte) []byte {
	output := make([]byte, len(input)+5)
	n := int(C.macdpi_tls_split(borrowed(input), C.int32_t(len(input)), p.profile, p.offset,
		borrowed(output), C.int32_t(len(output))))
	if n <= 0 || n > len(output) {
		return nil
	}
	return output[:n]
}

func (p swiftWire) routeDNS(query []byte) dnsAction {
	return dnsAction(C.macdpi_dns_route(borrowed(query), C.int32_t(len(query)), 1,
		borrowed(p.domains), C.int32_t(len(p.domains))))
}

func (p swiftWire) replyDNS(query, upstream []byte, datagram, encrypted bool) []byte {
	var udp, doh C.int32_t
	if datagram {
		udp = 1
	}
	if encrypted {
		doh = 1
	}
	output := make([]byte, maxDNSMessage)
	n := int(C.macdpi_dns_reply(borrowed(query), C.int32_t(len(query)), borrowed(upstream),
		C.int32_t(len(upstream)), udp, doh, borrowed(output), C.int32_t(len(output))))
	if n <= 0 || n > len(output) {
		return nil
	}
	return output[:n]
}

//export macdpi_tun_run
func macdpi_tun_run(packetFD, leaseFD, ipv4Index, ipv6Index, profile, splitOffset, doh C.int32_t,
	domains *C.uint8_t, domainsLen C.int32_t) C.int32_t {
	pfd, lfd := int(packetFD), int(leaseFD)
	if pfd < 3 || lfd < 3 || pfd == lfd {
		return 2
	}
	defer func() {
		if pfd >= 0 {
			_ = unix.Close(pfd)
		}
		if lfd >= 0 {
			_ = unix.Close(lfd)
		}
	}()
	if ipv4Index < 0 || ipv6Index < 0 || ipv4Index == 0 && ipv6Index == 0 ||
		profile < 0 || profile > 2 || splitOffset < 1 || splitOffset > 16_000 ||
		doh < 0 || doh > 1 || domainsLen < 0 || domainsLen > maxDNSMessage ||
		domainsLen != 0 && domains == nil {
		return 2
	}
	if !isPhysicalInterface(int(ipv4Index)) || !isPhysicalInterface(int(ipv6Index)) {
		return 3
	}
	leaseType, err := unix.GetsockoptInt(lfd, unix.SOL_SOCKET, unix.SO_TYPE)
	if err != nil || leaseType != unix.SOCK_STREAM {
		return 4
	}
	peer, err := unix.Getpeername(lfd)
	if _, ok := peer.(*unix.SockaddrUnix); err != nil || !ok {
		return 4
	}
	packetType, err := unix.GetsockoptInt(pfd, unix.SOL_SOCKET, unix.SO_TYPE)
	if err != nil || packetType != unix.SOCK_DGRAM {
		return 2
	}
	if err := unix.SetNonblock(pfd, true); err != nil {
		return 2
	}
	if err := unix.SetNonblock(lfd, true); err != nil {
		return 4
	}
	// os.NewFile owns each descriptor after this point. The outer deferred
	// closes check negative sentinels so they cannot close a recycled fd.
	packetFile := os.NewFile(uintptr(pfd), "MacDPI utun")
	leaseFile := os.NewFile(uintptr(lfd), "MacDPI TUN lease")
	pfd, lfd = -1, -1
	defer packetFile.Close()
	defer leaseFile.Close()

	dial := physicalDialer(int(ipv4Index), int(ipv6Index))
	options := stackOptions{
		profile: int(profile), encryptedDNS: doh == 1, dial: dial,
		wire: swiftWire{profile: profile, offset: splitOffset, domains: C.GoBytes(unsafe.Pointer(domains), C.int(domainsLen))},
	}
	if options.encryptedDNS {
		client, closeIdle := newDoH(dial, ipv4Index != 0)
		options.encryptedExchange = func(ctx context.Context, query []byte) ([]byte, error) {
			return exchangeDoH(ctx, client, query)
		}
		options.closeEncrypted = closeIdle
	}
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	tunnel, err := newTunnel(ctx, options)
	if err != nil {
		return 1
	}
	leaseResult := make(chan error, 1)
	go func() {
		defer stop()
		var command [1]byte
		_, err := io.ReadFull(leaseFile, command[:])
		if err == nil && command[0] != 'S' {
			err = errors.New("unrecognized MacDPI lease command")
		}
		if errors.Is(err, io.EOF) || errors.Is(err, os.ErrClosed) {
			err = nil
		}
		leaseResult <- err
	}()
	err = tunnel.serve(packetFile, func() error {
		_, err := leaseFile.Write([]byte{'R'})
		return err
	})
	_ = leaseFile.Close()
	if leaseErr := <-leaseResult; leaseErr != nil {
		return 4
	}
	if err != nil {
		return 1
	}
	return 0
}
