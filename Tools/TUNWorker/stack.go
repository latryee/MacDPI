package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	tunnelNIC     tcpip.NICID = 1
	tunnelQueue               = 128
	maxTCP                    = 96
	maxUDP                    = 64
	maxDatagram               = 65_507
	udpQueueBytes             = 512 * udp.MacDPIQueuedDatagramOverhead
)

type dialFlow func(context.Context, string, netip.AddrPort) (net.Conn, error)

type wirePolicy interface {
	transformTLS([]byte) []byte
	routeDNS([]byte) dnsAction
	replyDNS(query, upstream []byte, datagram, encrypted bool) []byte
}

type stackOptions struct {
	profile           int
	encryptedDNS      bool
	dial              dialFlow
	wire              wirePolicy
	encryptedExchange func(context.Context, []byte) ([]byte, error)
	closeEncrypted    func()
}

type tunnelStack struct {
	ctx     context.Context
	cancel  context.CancelFunc
	stack   *stack.Stack
	link    *channel.Endpoint
	options stackOptions

	mu       sync.Mutex
	closed   bool
	tcpFlows int
	udpFlows int
	flows    sync.WaitGroup
}

func newTunnel(parent context.Context, options stackOptions) (*tunnelStack, error) {
	if options.dial == nil || options.wire == nil ||
		(options.encryptedDNS && options.encryptedExchange == nil) {
		return nil, errors.New("tunnel configuration incomplete")
	}
	ctx, cancel := context.WithCancel(parent)
	t := &tunnelStack{
		ctx: ctx, cancel: cancel, options: options,
		stack: stack.New(stack.Options{
			NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
			TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
		}),
		link: channel.New(tunnelQueue, tunMTU, ""),
	}
	if err := t.stack.CreateNIC(tunnelNIC, t.link); err != nil {
		t.close()
		return nil, fmt.Errorf("TCP/IP interface: %s", err)
	}
	if err := t.stack.SetPromiscuousMode(tunnelNIC, true); err != nil {
		t.close()
		return nil, fmt.Errorf("TCP/IP promiscuous mode: %s", err)
	}
	if err := t.stack.SetSpoofing(tunnelNIC, true); err != nil {
		t.close()
		return nil, fmt.Errorf("TCP/IP reply address policy: %s", err)
	}
	// Reconstructed packets terminate at this stack. No IP forwarding is
	// enabled between interfaces or clients on the LAN.
	t.stack.SetRouteTable([]tcpip.Route{
		{Destination: ipv4AnySubnet(), NIC: tunnelNIC},
		{Destination: ipv6AnySubnet(), NIC: tunnelNIC},
	})
	receive := tcpip.TCPReceiveBufferSizeRangeOption{Min: 4 << 10, Default: 32 << 10, Max: 128 << 10}
	send := tcpip.TCPSendBufferSizeRangeOption{Min: 4 << 10, Default: 32 << 10, Max: 128 << 10}
	if err := t.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &receive); err != nil {
		t.close()
		return nil, fmt.Errorf("TCP receive limit: %s", err)
	}
	if err := t.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &send); err != nil {
		t.close()
		return nil, fmt.Errorf("TCP send limit: %s", err)
	}
	udpReceive := tcpip.ReceiveBufferSizeOption{Min: 4 << 10, Default: udpQueueBytes, Max: udpQueueBytes}
	if err := t.stack.SetOption(udpReceive); err != nil {
		t.close()
		return nil, fmt.Errorf("UDP receive limit: %s", err)
	}
	t.stack.SetTransportProtocolHandler(tcp.ProtocolNumber,
		tcp.NewForwarder(t.stack, 32<<10, maxTCP, t.handleTCP).HandlePacket)
	t.stack.SetTransportProtocolHandler(udp.ProtocolNumber, func(id stack.TransportEndpointID, packet *stack.PacketBuffer) bool {
		// The request is consumed synchronously. Its input packet stays
		// owned by the stack's dispatcher, so no extra clone is required.
		return t.handleUDP(udp.NewForwarderRequest(t.stack, id, packet))
	})
	return t, nil
}

func ipv4AnySubnet() tcpip.Subnet {
	result, _ := tcpip.NewSubnet(tcpip.AddrFrom4([4]byte{}), tcpip.MaskFromBytes([]byte{0, 0, 0, 0}))
	return result
}

func ipv6AnySubnet() tcpip.Subnet {
	result, _ := tcpip.NewSubnet(tcpip.AddrFrom16([16]byte{}), tcpip.MaskFromBytes(make([]byte, 16)))
	return result
}

// serve owns the packet descriptor for this session. Read the extra byte to
// detect a truncated over-MTU datagram instead of feeding its prefix to TCP/IP.
func (t *tunnelStack) serve(device io.ReadWriteCloser, ready func() error) error {
	var packetWorkers sync.WaitGroup
	results := make(chan error, 2)
	packetWorkers.Go(func() {
		input := make([]byte, tunHeader+tunMTU+1)
		for {
			n, err := device.Read(input)
			if n > 0 {
				injectFrame(t.link, input[:n])
			}
			if err != nil {
				results <- err
				return
			}
		}
	})
	packetWorkers.Go(func() {
		output := make([]byte, tunHeader+tunMTU)
		for {
			packet := t.link.ReadContext(t.ctx)
			if packet == nil {
				results <- t.ctx.Err()
				return
			}
			err := writePacket(device, output, packet)
			packet.DecRef()
			if err != nil {
				results <- err
				return
			}
		}
	})
	var err error
	if t.ctx.Err() == nil {
		err = ready()
	}
	if err == nil {
		select {
		case <-t.ctx.Done():
		case err = <-results:
		}
	}
	if t.ctx.Err() != nil {
		err = nil
	}
	t.cancel()
	_ = device.Close()
	packetWorkers.Wait()
	t.close()
	return err
}

func (t *tunnelStack) acquire(datagram bool) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed || t.ctx.Err() != nil {
		return false
	}
	count, limit := &t.tcpFlows, maxTCP
	if datagram {
		count, limit = &t.udpFlows, maxUDP
	}
	if *count >= limit {
		return false
	}
	*count += 1
	t.flows.Add(1)
	return true
}

func (t *tunnelStack) release(datagram bool) {
	t.mu.Lock()
	if datagram {
		t.udpFlows--
	} else {
		t.tcpFlows--
	}
	t.mu.Unlock()
	t.flows.Done()
}

func (t *tunnelStack) close() {
	t.cancel()
	t.mu.Lock()
	t.closed = true
	t.mu.Unlock()
	t.stack.Close()
	t.flows.Wait()
	t.stack.Wait()
	t.link.Close()
	if t.options.closeEncrypted != nil {
		t.options.closeEncrypted()
	}
}

func flowDestination(id stack.TransportEndpointID) (netip.AddrPort, bool) {
	address, ok := netip.AddrFromSlice(id.LocalAddress.AsSlice())
	if !ok || id.LocalPort == 0 {
		return netip.AddrPort{}, false
	}
	address = address.Unmap()
	if address.IsUnspecified() || address.IsMulticast() || address.IsLoopback() || address.IsLinkLocalUnicast() {
		return netip.AddrPort{}, false
	}
	return netip.AddrPortFrom(address, id.LocalPort), true
}

func (t *tunnelStack) handleTCP(request *tcp.ForwarderRequest) {
	destination, allowed := flowDestination(request.ID())
	if !allowed || !t.acquire(false) {
		request.Complete(true)
		return
	}
	defer t.release(false)
	var queue waiter.Queue
	endpoint, err := request.CreateEndpoint(&queue)
	request.Complete(err != nil)
	if err != nil {
		return
	}
	local := gonet.NewTCPConn(&queue, endpoint)
	defer local.Close()
	cancelLocal := context.AfterFunc(t.ctx, func() { _ = local.Close() })
	defer cancelLocal()
	if t.options.encryptedDNS && destination.Port() == 53 {
		t.serveTCPDNS(local, destination)
		return
	}
	remote, dialErr := t.options.dial(t.ctx, "tcp", destination)
	if dialErr != nil {
		return
	}
	defer remote.Close()
	relayTCP(t.ctx, local, remote, t.tlsTransform(destination.Port()))
}

func (t *tunnelStack) handleUDP(request *udp.ForwarderRequest) bool {
	destination, allowed := flowDestination(request.ID())
	if !allowed || !t.acquire(true) {
		return false
	}
	var queue waiter.Queue
	endpoint, err := request.CreateEndpoint(&queue)
	if err != nil {
		t.release(true)
		return false
	}
	local := gonet.NewUDPConn(&queue, endpoint)
	go func() {
		defer t.release(true)
		defer local.Close()
		cancelLocal := context.AfterFunc(t.ctx, func() { _ = local.Close() })
		defer cancelLocal()
		if t.options.encryptedDNS && destination.Port() == 53 {
			t.serveUDPDNS(local, destination)
			return
		}
		remote, dialErr := t.options.dial(t.ctx, "udp", destination)
		if dialErr != nil {
			return
		}
		defer remote.Close()
		relayUDP(t.ctx, local, remote, 45*time.Second)
	}()
	return true
}

func (t *tunnelStack) tlsTransform(port uint16) func([]byte) []byte {
	if t.options.profile != 0 && (port == 443 || port == 8443 || port == 9443) {
		return t.options.wire.transformTLS
	}
	return nil
}
