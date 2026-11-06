package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"time"
)

const (
	streamBuffer    = 32 << 10
	firstFlightWait = time.Second
	maxTLSRecord    = (16 << 10) + 5
	writeLimit      = 5 * time.Second
)

type activity struct {
	start time.Time
	last  atomic.Int64
}

func (a *activity) touched() { a.last.Store(time.Since(a.start).Nanoseconds()) }

func (a *activity) deadline(idle time.Duration) time.Time {
	return a.start.Add(time.Duration(a.last.Load()) + idle)
}

func isTimeout(err error) bool {
	var networkError net.Error
	return errors.As(err, &networkError) && networkError.Timeout()
}

// Each pump closes only the destination's write side on clean EOF. Any
// other error or context cancellation stops both directions promptly.
func relayTCP(ctx context.Context, local, remote net.Conn, transform func([]byte) []byte) {
	const idle = 5 * time.Minute
	var usage = activity{start: time.Now()}
	closeBoth := func() {
		_ = local.Close()
		_ = remote.Close()
	}
	cancel := context.AfterFunc(ctx, closeBoth)
	defer cancel()
	done := make(chan struct{})
	go func() {
		if err := copyStream(local, remote, &usage, idle); err != nil {
			closeBoth()
		}
		close(done)
	}()
	if err := firstFlight(remote, local, transform, &usage); err != nil {
		closeBoth()
	} else if err := copyStream(remote, local, &usage, idle); err != nil {
		closeBoth()
	}
	<-done
}

func copyStream(dst, src net.Conn, usage *activity, idle time.Duration) error {
	buffer := make([]byte, streamBuffer)
	for {
		if err := src.SetReadDeadline(usage.deadline(idle)); err != nil {
			return err
		}
		n, err := src.Read(buffer)
		if n > 0 {
			usage.touched()
			if err := sendStream(dst, buffer[:n]); err != nil {
				return err
			}
		}
		if errors.Is(err, io.EOF) {
			half, ok := dst.(interface{ CloseWrite() error })
			if !ok {
				return errors.New("stream does not support half-close")
			}
			return half.CloseWrite()
		}
		if isTimeout(err) && time.Now().Before(usage.deadline(idle)) {
			continue
		}
		if err != nil {
			return err
		}
	}
}

func sendStream(dst net.Conn, payload []byte) error {
	if len(payload) == 0 {
		return nil
	}
	if err := dst.SetWriteDeadline(time.Now().Add(writeLimit)); err != nil {
		return err
	}
	for len(payload) > 0 {
		n, err := dst.Write(payload)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		payload = payload[n:]
	}
	return nil
}

// Take at most the first bounded TLS record. Delayed, incomplete, malformed,
// or non-TLS input is forwarded byte for byte. The server->client pump is
// already running, so a server-first stream does not wait for inspection.
func firstFlight(dst, src net.Conn, transform func([]byte) []byte, usage *activity) error {
	if transform == nil {
		return nil
	}
	if err := src.SetReadDeadline(time.Now().Add(firstFlightWait)); err != nil {
		return err
	}
	defer src.SetReadDeadline(time.Time{})
	header := make([]byte, 5)
	n, err := io.ReadFull(src, header[:1])
	if n == 0 {
		// Resume the ordinary byte stream after the inspection deadline.
		// EOF or reset will still be visible to copyStream.
		return nil
	}
	usage.touched()
	if err != nil || header[0] != 22 {
		return sendStream(dst, header[:n])
	}
	n, err = io.ReadFull(src, header[1:])
	if err != nil || header[1] != 3 {
		return sendStream(dst, header[:n+1])
	}
	length := int(binary.BigEndian.Uint16(header[3:5]))
	if length == 0 || length+5 > maxTLSRecord {
		return sendStream(dst, header)
	}
	record := make([]byte, length+5)
	copy(record, header)
	n, err = io.ReadFull(src, record[5:])
	if err != nil {
		return sendStream(dst, record[:n+5])
	}
	if transformed := transform(record); len(transformed) > 0 {
		return sendStream(dst, transformed)
	}
	return sendStream(dst, record)
}

func relayUDP(ctx context.Context, local, remote net.Conn, idle time.Duration) {
	var usage = activity{start: time.Now()}
	closeBoth := func() {
		_ = local.Close()
		_ = remote.Close()
	}
	cancel := context.AfterFunc(ctx, closeBoth)
	defer cancel()
	done := make(chan struct{})
	go func() {
		copyDatagrams(local, remote, &usage, idle)
		closeBoth()
		close(done)
	}()
	copyDatagrams(remote, local, &usage, idle)
	closeBoth()
	<-done
}

func copyDatagrams(dst, src net.Conn, usage *activity, idle time.Duration) {
	buffer := make([]byte, maxDatagram+1)
	for {
		if err := src.SetReadDeadline(usage.deadline(idle)); err != nil {
			return
		}
		n, err := src.Read(buffer)
		if isTimeout(err) && time.Now().Before(usage.deadline(idle)) {
			continue
		}
		if err != nil {
			return
		}
		if n > maxDatagram {
			continue
		}
		usage.touched()
		if err := sendDatagram(dst, buffer[:n]); err != nil {
			return
		}
	}
}

func sendDatagram(dst net.Conn, payload []byte) error {
	if err := dst.SetWriteDeadline(time.Now().Add(writeLimit)); err != nil {
		return err
	}
	n, err := dst.Write(payload)
	if err == nil && n != len(payload) {
		return io.ErrShortWrite
	}
	return err
}
