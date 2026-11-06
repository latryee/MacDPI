#ifndef MACDPI_TUN_WIRE_BRIDGE_H
#define MACDPI_TUN_WIRE_BRIDGE_H

#include <stdint.h>

// Synchronous calls into the existing Swift core. Pointers are borrowed only
// for the call. No function writes a partial result on error.

// profile: 0 compatibility, 1 standard, 2 advanced. Input <= 16,389 bytes.
// Returns a positive transformed length (at most input_length + 5), 0 to use
// the original bytes, or -1 for an invalid argument or insufficient output.
int32_t macdpi_tls_split(const uint8_t *input, int32_t input_length,
                         int32_t profile, int32_t offset,
                         uint8_t *output, int32_t output_capacity);

// doh: 0 original resolver, 1 encrypted resolver with split-DNS exceptions.
// domains: up to 128 ASCII names separated by newlines, or an empty byte span.
// Returns 0 to use the original resolver, 1 to use DoH, or -1 for invalid input.
int32_t macdpi_dns_route(const uint8_t *query, int32_t query_length,
                         int32_t doh, const uint8_t *domains, int32_t domains_length);

// Accepts unframed DNS messages of up to 32,768 bytes. A response length of 0
// indicates upstream failure. Valid queries receive SERVFAIL if the upstream
// response is absent, malformed, or mismatched. udp: 0 TCP, 1 UDP.
// encrypted: 1 rejects non-public addresses in DNS answers and address hints.
// Returns the reply length, or -1 for an invalid query, argument, or capacity.
int32_t macdpi_dns_reply(const uint8_t *query, int32_t query_length,
                         const uint8_t *response, int32_t response_length,
                         int32_t udp, int32_t encrypted, uint8_t *output, int32_t output_capacity);

// A supported visible name yields a bounded A/AAAA question. Zero preserves
// the original destination. A negative result indicates invalid policy.
int32_t macdpi_tls_origin_query(const uint8_t *record, int32_t length, uint16_t type,
                               const uint8_t *domains, int32_t domains_length,
                               uint8_t *output, int32_t capacity);

// Validates the encrypted response and returns concatenated public addresses
// of the requested family, or a negative result on failure.
int32_t macdpi_tls_origin_addresses(const uint8_t *query, int32_t query_length,
                                   const uint8_t *response, int32_t response_length,
                                   uint8_t *output, int32_t capacity);

#endif
