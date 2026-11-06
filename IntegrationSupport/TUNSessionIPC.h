#ifndef MACDPI_TUN_SESSION_IPC_H
#define MACDPI_TUN_SESSION_IPC_H

#include <stdint.h>

// Each operation is synchronous and uses errno on failure. Descriptors remain
// owned by the caller except for a newly returned listener, peer, or packet fd.
int macdpi_tun_session_valid(const char *session);
int macdpi_tun_broker_listen(const char *session, uint32_t uid);
int macdpi_tun_broker_unlink(const char *session, uint32_t uid);
int macdpi_tun_broker_accept(int listener, uint32_t uid, const char *worker_path, int timeout_ms);
int macdpi_tun_broker_connect(const char *session, int cancel_fd, int timeout_ms);

int macdpi_tun_broker_send_fd(int peer, int packet_fd, uint32_t ipv4_index, uint32_t ipv6_index);
int macdpi_tun_broker_receive_fd(int peer, int *packet_fd, uint32_t *ipv4_index, uint32_t *ipv6_index, int timeout_ms);
int macdpi_tun_validate_packet_fd(int packet_fd);
int macdpi_tun_lease_pair(int fds[2]);

// Receives one byte, returning 1. Returns 0 on EOF, -1 on failure, and
// ETIMEDOUT via errno on timeout. A timeout of zero performs an immediate check.
int macdpi_tun_control_receive(int peer, uint8_t *byte, int timeout_ms);
int macdpi_tun_control_send(int peer, uint8_t byte);

#endif
