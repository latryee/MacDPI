package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"time"
)

type dnsAction int

const (
	dnsInvalid    dnsAction = -1
	dnsOriginal   dnsAction = 0
	dnsEncrypted  dnsAction = 1
	maxDNSMessage           = 32768
	dnsTimeout              = 5 * time.Second
)

// TLS validates the HTTPS name while the socket goes directly to a bound
// Cloudflare IP. This avoids bootstrapping via System DNS or system proxies.
func newDoH(dial dialFlow, ipv4Available bool) (*http.Client, func()) {
	address := netip.MustParseAddrPort("[2606:4700:4700::1111]:443")
	if ipv4Available {
		address = netip.MustParseAddrPort("1.1.1.1:443")
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, host string) (net.Conn, error) {
			if host != "cloudflare-dns.com:443" || network != "tcp" {
				return nil, errors.New("unexpected encrypted DNS destination")
			}
			return dial(ctx, network, address)
		},
		TLSClientConfig:        &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout:    dnsTimeout,
		ResponseHeaderTimeout:  dnsTimeout,
		ForceAttemptHTTP2:      true,
		MaxConnsPerHost:        8,
		MaxIdleConnsPerHost:    2,
		IdleConnTimeout:        45 * time.Second,
		DisableCompression:     true,
		MaxResponseHeaderBytes: 16 << 10,
	}
	client := &http.Client{
		Transport:     transport,
		Timeout:       dnsTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return client, transport.CloseIdleConnections
}

func exchangeDoH(ctx context.Context, client *http.Client, query []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://cloudflare-dns.com/dns-query", bytes.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/dns-message")
	req.Header.Set("Content-Type", "application/dns-message")
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	contentType, _, _ := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if response.StatusCode != http.StatusOK || contentType != "application/dns-message" ||
		response.ContentLength > maxDNSMessage {
		return nil, errors.New("invalid encrypted DNS response")
	}
	result, err := io.ReadAll(io.LimitReader(response.Body, maxDNSMessage+1))
	if err != nil || len(result) < 12 || len(result) > maxDNSMessage {
		return nil, errors.New("invalid encrypted DNS response size")
	}
	return result, nil
}

func (t *tunnelStack) dnsResponse(query []byte, destination netip.AddrPort, datagram bool) []byte {
	ctx, cancel := context.WithTimeout(t.ctx, dnsTimeout)
	defer cancel()
	var response []byte
	switch t.options.wire.routeDNS(query) {
	case dnsOriginal:
		response, _ = exchangeOriginal(ctx, t.options.dial, destination, query, datagram)
	case dnsEncrypted:
		// A failed DoH request must not retry with plaintext DNS.
		response, _ = t.options.encryptedExchange(ctx, query)
	default:
		return nil
	}
	return t.options.wire.replyDNS(query, response, datagram)
}

func exchangeOriginal(ctx context.Context, dial dialFlow, destination netip.AddrPort, query []byte, datagram bool) ([]byte, error) {
	network := "tcp"
	if datagram {
		network = "udp"
	}
	conn, err := dial(ctx, network, destination)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	cancel := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer cancel()
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		return nil, err
	}
	if datagram {
		if n, err := conn.Write(query); err != nil || n != len(query) {
			return nil, errors.New("DNS datagram send failed")
		}
		response := make([]byte, maxDNSMessage+1)
		n, err := conn.Read(response)
		if err != nil || n > maxDNSMessage {
			return nil, errors.New("DNS datagram receive failed")
		}
		return response[:n], nil
	}
	if err := sendStream(conn, dnsFrame(query)); err != nil {
		return nil, err
	}
	return readDNSFrame(conn)
}

func dnsFrame(message []byte) []byte {
	frame := make([]byte, 2+len(message))
	binary.BigEndian.PutUint16(frame, uint16(len(message)))
	copy(frame[2:], message)
	return frame
}

func readDNSFrame(r io.Reader) ([]byte, error) {
	var length [2]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return nil, err
	}
	size := int(binary.BigEndian.Uint16(length[:]))
	if size < 12 || size > maxDNSMessage {
		return nil, errors.New("invalid TCP DNS frame size")
	}
	packet := make([]byte, size)
	_, err := io.ReadFull(r, packet)
	return packet, err
}

func (t *tunnelStack) serveTCPDNS(local net.Conn, destination netip.AddrPort) {
	for {
		if err := local.SetReadDeadline(time.Now().Add(45 * time.Second)); err != nil {
			return
		}
		query, err := readDNSFrame(local)
		if err != nil {
			return
		}
		response := t.dnsResponse(query, destination, false)
		if len(response) == 0 || sendStream(local, dnsFrame(response)) != nil {
			return
		}
	}
}

func (t *tunnelStack) serveUDPDNS(local net.Conn, destination netip.AddrPort) {
	buffer := make([]byte, maxDNSMessage+1)
	for {
		if err := local.SetReadDeadline(time.Now().Add(45 * time.Second)); err != nil {
			return
		}
		n, err := local.Read(buffer)
		if err != nil {
			return
		}
		if n > maxDNSMessage {
			continue
		}
		response := t.dnsResponse(buffer[:n], destination, true)
		if len(response) != 0 && sendDatagram(local, response) != nil {
			return
		}
	}
}
