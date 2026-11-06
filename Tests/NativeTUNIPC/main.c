#include <assert.h>
#include <stdlib.h>

// The fixture also exercises the same private audit-token identity check as
// broker accept, with a same-uid local peer and no privileged listener.
#include "../../IntegrationSupport/TUNSessionIPC.c"

static void test_descriptor_and_stop(void) {
    int lease[2], packet[2];
    assert(macdpi_tun_lease_pair(lease) == 0);
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, packet) == 0);
    assert(macdpi_tun_broker_send_fd(lease[0], packet[0], 1, 300) == 0);
    uint32_t v4 = 0, v6 = 0;
    int received = -1;
    assert(macdpi_tun_broker_receive_fd(lease[1], &received, &v4, &v6, 500) == 0);
    assert(v4 == 1 && v6 == 300 && received >= 3 && received != packet[0]);
    assert((fcntl(received, F_GETFD) & FD_CLOEXEC) != 0);
    assert(macdpi_tun_validate_packet_fd(received) == -1 && errno == EPROTO);
    assert(write(packet[1], "packet", 6) == 6);
    char payload[6];
    assert(read(received, payload, sizeof(payload)) == 6 && memcmp(payload, "packet", 6) == 0);

    uint8_t message = 0;
    assert(macdpi_tun_control_receive(lease[0], &message, 5) == -1 && errno == ETIMEDOUT);
    assert(macdpi_tun_control_send(lease[1], 'S') == 0);
    assert(macdpi_tun_control_receive(lease[0], &message, 500) == 1 && message == 'S');
    assert(close(lease[1]) == 0);
    assert(macdpi_tun_control_receive(lease[0], &message, 500) == 0);
    close(lease[0]); close(received); close(packet[0]); close(packet[1]);
}

static void test_reject_missing_descriptor(void) {
    int lease[2];
    assert(macdpi_tun_lease_pair(lease) == 0);
    const uint32_t indexes[2] = {htonl(1), htonl(1)};
    assert(write(lease[0], indexes, sizeof(indexes)) == sizeof(indexes));
    uint32_t v4 = 0, v6 = 0;
    int fd = -1;
    assert(macdpi_tun_broker_receive_fd(lease[1], &fd, &v4, &v6, 500) == -1 && errno == EPROTO && fd == -1);
    close(lease[0]); close(lease[1]);
}

static void test_broker_failure_acknowledgements(void) {
    const uint8_t markers[] = {'D', 'X', 'F'};
    const int expected[] = {ECANCELED, ECANCELED, ESTALE};
    for (size_t index = 0; index < sizeof(markers); ++index) {
        int lease[2];
        assert(macdpi_tun_lease_pair(lease) == 0);
        assert(macdpi_tun_control_send(lease[0], markers[index]) == 0);
        assert(close(lease[0]) == 0);
        uint32_t v4 = 0, v6 = 0;
        int fd = -1;
        assert(macdpi_tun_broker_receive_fd(lease[1], &fd, &v4, &v6, 500) == -1);
        assert(errno == expected[index] && fd == -1);
        close(lease[1]);
    }
}

static void test_audit_identity(const char *executable) {
    CFURLRef path = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)executable, (CFIndex)strlen(executable), false);
    assert(path != NULL);
#if defined(__arm64__)
    CFDataRef expected = copy_expected_hash(path, CFSTR("arm64"));
#else
    CFDataRef expected = copy_expected_hash(path, CFSTR("x86_64"));
#endif
    assert(expected != NULL);
    CFRelease(path);
    int lease[2];
    assert(macdpi_tun_lease_pair(lease) == 0);
    assert(verify_worker(lease[0], getuid(), expected, NULL) == 0);
    assert(verify_worker(lease[0], getuid() + 1, expected, NULL) == -1 && errno == EACCES);
    UInt8 wrong_hash[20] = {0};
    CFDataRef wrong = CFDataCreate(NULL, wrong_hash, sizeof(wrong_hash));
    assert(wrong != NULL);
    assert(verify_worker(lease[0], getuid(), wrong, NULL) == -1 && errno == EACCES);
    CFRelease(expected);
    CFRelease(wrong);
    close(lease[0]); close(lease[1]);
}

int main(int argc, const char **argv) {
    assert(argc == 1 && argv[0][0] == '/');
    assert(getuid() != 0 && getuid() == geteuid());
    assert(macdpi_tun_session_valid("12a45678-1234-1234-1234-123456789012") == 1);
    assert(macdpi_tun_session_valid("12A45678-1234-1234-1234-123456789012") == 0);
    assert(macdpi_tun_session_valid("../../../../private/var/run/a.sock") == 0);
    assert(macdpi_tun_broker_listen("12a45678-1234-1234-1234-123456789012", getuid()) == -1 && errno == EACCES);
    test_descriptor_and_stop();
    test_reject_missing_descriptor();
    test_broker_failure_acknowledgements();
    test_audit_identity(argv[0]);
    puts("PASS: unprivileged TUN IPC descriptor handoff, stop, timeout, EOF, audit token, and code hash");
    return 0;
}
