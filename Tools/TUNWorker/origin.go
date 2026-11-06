package main

import (
	"context"
	"errors"
	"net/netip"
	"time"
)

type originRepair struct {
	candidates map[netip.Addr]bool
	question   func(record []byte, ipv4 bool) ([]byte, error)
	addresses  func(query, reply []byte, ipv4 bool) []netip.Addr
}

// Probe a fixed pair of distinct names for each service using System DNS.
// A shared singleton address is only a trigger for inspection, never proof
// of poisoning or a substitute for the ClientHello name.
func suspectTLSOrigins(ctx context.Context, lookup func(context.Context, string, string) ([]netip.Addr, error)) map[netip.Addr]bool {
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	names := [...]string{"discord.com", "gateway.discord.gg", "www.roblox.com", "users.roblox.com"}
	type result struct {
		index     int
		addresses []netip.Addr
	}
	results := make(chan result, len(names))
	for index, name := range names {
		go func() {
			addresses, err := lookup(ctx, "ip", name+".")
			if err != nil {
				addresses = nil
			}
			results <- result{index, addresses}
		}()
	}
	var answers [len(names)][]netip.Addr
collect:
	for range names {
		select {
		case result := <-results:
			answers[result.index] = result.addresses
		case <-ctx.Done():
			break collect
		}
	}
	candidates := make(map[netip.Addr]bool)
	for i := 0; i < len(names); i += 2 {
		for _, ipv4 := range []bool{true, false} {
			first := singlePublicAddress(answers[i], ipv4)
			if first.IsValid() && first == singlePublicAddress(answers[i+1], ipv4) {
				candidates[first] = true
			}
		}
	}
	return candidates
}

func singlePublicAddress(answers []netip.Addr, ipv4 bool) netip.Addr {
	var single netip.Addr
	for _, address := range answers {
		address = address.Unmap()
		if address.Is4() != ipv4 {
			continue
		}
		if !publicEgress(address) || (single.IsValid() && single != address) {
			return netip.Addr{}
		}
		single = address
	}
	return single
}

func (t *tunnelStack) resolveTLSOrigin(destination netip.AddrPort, prefix []byte) (netip.AddrPort, error) {
	ipv4 := destination.Addr().Is4()
	query, err := t.options.origin.question(prefix, ipv4)
	if err != nil || len(query) == 0 {
		return destination, err
	}
	ctx, cancel := context.WithTimeout(t.ctx, dnsTimeout)
	defer cancel()
	answer, err := t.options.encryptedExchange(ctx, query)
	if err != nil {
		return netip.AddrPort{}, err
	}
	addresses := t.options.origin.addresses(query, answer, ipv4)
	if len(addresses) == 0 {
		return netip.AddrPort{}, errors.New("no verified TLS origin address")
	}
	for _, address := range addresses {
		if address == destination.Addr() {
			return destination, nil
		}
	}
	return netip.AddrPortFrom(addresses[0], destination.Port()), nil
}
