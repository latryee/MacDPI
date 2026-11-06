package main

import (
	"encoding/binary"
	"errors"
	"io"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

const (
	tunMTU     = 1500
	tunHeader  = 4
	darwinIPv4 = 2
	darwinIPv6 = 30
)

// Darwin utun exchanges one datagram at a time, with a big-endian address
// family before the IP packet. The fd has already been created by the broker.
func decodeFrame(frame []byte) (tcpip.NetworkProtocolNumber, []byte, bool) {
	if len(frame) <= tunHeader || len(frame) > tunHeader+tunMTU {
		return 0, nil, false
	}
	packet := frame[tunHeader:]
	switch binary.BigEndian.Uint32(frame[:tunHeader]) {
	case darwinIPv4:
		if len(packet) >= 20 && packet[0]>>4 == 4 {
			headerLen := int(packet[0]&15) * 4
			total := int(binary.BigEndian.Uint16(packet[2:4]))
			if headerLen >= 20 && headerLen <= total && total == len(packet) {
				return ipv4.ProtocolNumber, packet, true
			}
		}
	case darwinIPv6:
		if len(packet) >= 40 && packet[0]>>4 == 6 &&
			40+int(binary.BigEndian.Uint16(packet[4:6])) == len(packet) {
			return ipv6.ProtocolNumber, packet, true
		}
	}
	return 0, nil, false
}

func encodeFrame(dst []byte, packet []byte) ([]byte, bool) {
	if len(packet) == 0 || len(packet) > tunMTU || len(dst) < len(packet)+tunHeader {
		return nil, false
	}
	switch packet[0] >> 4 {
	case 4:
		binary.BigEndian.PutUint32(dst[:tunHeader], darwinIPv4)
	case 6:
		binary.BigEndian.PutUint32(dst[:tunHeader], darwinIPv6)
	default:
		return nil, false
	}
	copy(dst[tunHeader:], packet)
	return dst[:len(packet)+tunHeader], true
}

func injectFrame(link *channel.Endpoint, frame []byte) {
	protocol, bytes, ok := decodeFrame(frame)
	if !ok {
		return
	}
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(bytes),
	})
	link.InjectInbound(protocol, packet)
	packet.DecRef()
}

func writePacket(device io.Writer, frame []byte, packet *stack.PacketBuffer) error {
	view := packet.ToView()
	defer view.Release()
	bytes, ok := encodeFrame(frame, view.AsSlice())
	if !ok {
		return errors.New("unexpected packet from TCP/IP stack")
	}
	n, err := device.Write(bytes)
	if err == nil && n != len(bytes) {
		return io.ErrShortWrite
	}
	return err
}
