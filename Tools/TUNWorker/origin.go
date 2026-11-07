package main

import (
	"context"
	"errors"
	"net/netip"
	"sync"
	"time"
)

const maxOriginEntries = 64

type originRepair struct {
	candidates map[netip.Addr]bool
	question   func(record []byte, ipv4 bool) ([]byte, error)
	addresses  func(query, reply []byte, ipv4 bool) ([]netip.Addr, uint32)
}

type originLookup struct {
	done      chan struct{}
	addresses []netip.Addr
	expires   time.Time
	err       error
}

type originCache struct {
	mu      sync.Mutex
	entries map[string]*originLookup
}

// The exact question includes the address family. Only verified answers are
// retained, in memory, for at most their remaining TTL or one minute.
func (c *originCache) resolve(ctx context.Context, query []byte, lookup func() ([]netip.Addr, time.Duration, error)) ([]netip.Addr, error) {
	key := string(query)
	c.mu.Lock()
	if entry := c.entries[key]; entry != nil {
		if done := entry.done; done != nil {
			c.mu.Unlock()
			select {
			case <-done:
				return entry.addresses, entry.err
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if time.Now().Before(entry.expires) {
			c.mu.Unlock()
			return entry.addresses, nil
		}
		delete(c.entries, key)
	}
	if len(c.entries) == maxOriginEntries {
		for oldKey, old := range c.entries {
			if old.done == nil {
				delete(c.entries, oldKey)
				break
			}
		}
	}
	if c.entries == nil {
		c.entries = make(map[string]*originLookup)
	}
	entry := &originLookup{done: make(chan struct{})}
	if len(c.entries) < maxOriginEntries {
		c.entries[key] = entry
	}
	c.mu.Unlock()

	addresses, ttl, err := lookup()
	c.mu.Lock()
	entry.addresses, entry.err = addresses, err
	entry.expires = time.Now().Add(min(ttl, time.Minute))
	close(entry.done)
	entry.done = nil
	if (err != nil || ttl <= 0) && c.entries[key] == entry {
		delete(c.entries, key)
	}
	c.mu.Unlock()
	return addresses, err
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
	addresses, err := t.origins.resolve(ctx, query, func() ([]netip.Addr, time.Duration, error) {
		answer, err := t.options.encryptedExchange(ctx, query)
		if err != nil {
			return nil, 0, err
		}
		addresses, ttl := t.options.origin.addresses(query, answer.message, ipv4)
		if len(addresses) == 0 {
			return nil, 0, errors.New("no verified TLS origin address")
		}
		return addresses, answer.cacheLifetime(ttl), nil
	})
	if err != nil {
		return netip.AddrPort{}, err
	}
	for _, address := range addresses {
		if address == destination.Addr() {
			return destination, nil
		}
	}
	return netip.AddrPortFrom(addresses[0], destination.Port()), nil
}
