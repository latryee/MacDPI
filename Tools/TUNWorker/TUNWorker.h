#ifndef MACDPI_TUN_WORKER_H
#define MACDPI_TUN_WORKER_H

#include <stdint.h>

// Takes ownership of distinct packet and SOCK_STREAM lease descriptors >= 3.
// The packet descriptor carries native Darwin utun datagrams. Interface
// indices are physical egress interfaces, or zero for an unavailable family.
// The worker writes 'R' after attaching the data plane, then stops on 'S' or EOF.
// The Swift caller owns domains; the worker copies it before processing packets.
// Return codes: 0 stopped, 1 stack/I/O failed, 2 invalid configuration,
// 3 egress interface unavailable, 4 invalid lease or lease I/O failure.
int32_t macdpi_tun_run(int32_t packet_fd, int32_t lease_fd,
                      int32_t ipv4_index, int32_t ipv6_index,
                      int32_t profile, int32_t split_offset,
                      int32_t doh, uint8_t *domains, int32_t domains_len);

#endif
