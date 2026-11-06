#include "TUNSessionIPC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/message.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sys_domain.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static const char broker_dir[] = "/private/var/run/io.github.latryee.macdpi";
enum { max_timeout_ms = 90000, send_timeout_ms = 2000 };

static int fail(int error) {
    errno = error;
    return -1;
}

static void close_preserving_errno(int fd) {
    int error = errno;
    close(fd);
    errno = error;
}

int macdpi_tun_session_valid(const char *session) {
    if (session == NULL || strnlen(session, 37) != 36) return 0;
    for (size_t index = 0; index < 36; ++index) {
        char byte = session[index];
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (byte != '-') return 0;
        } else if (!(byte >= '0' && byte <= '9') && !(byte >= 'a' && byte <= 'f')) {
            return 0;
        }
    }
    return 1;
}

static int socket_address(const char *session, struct sockaddr_un *address) {
    if (!macdpi_tun_session_valid(session)) return fail(EINVAL);
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    int length = snprintf(address->sun_path, sizeof(address->sun_path), "%s/%s.sock", broker_dir, session);
    if (length < 0 || (size_t)length >= sizeof(address->sun_path)) return fail(ENAMETOOLONG);
    address->sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + (size_t)length + 1);
    return 0;
}

static int check_directory(void) {
    struct stat info;
    if (lstat(broker_dir, &info) < 0) return -1;
    if (!S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0777) != 0755) return fail(EACCES);
    return 0;
}

static int check_socket_owner(const struct sockaddr_un *address, uid_t owner) {
    struct stat info;
    if (lstat(address->sun_path, &info) < 0) return -1;
    if (!S_ISSOCK(info.st_mode) || info.st_uid != owner || (info.st_mode & 0777) != 0600) return fail(EACCES);
    return 0;
}

static int setup_socket(int fd) {
    int enabled = 1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) return -1;
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int stream_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0 && setup_socket(fd) < 0) {
        close_preserving_errno(fd);
        return -1;
    }
    return fd;
}

int macdpi_tun_broker_listen(const char *session, uint32_t uid) {
    if (geteuid() != 0 || uid == 0 || uid == UINT32_MAX) return fail(EACCES);
    struct sockaddr_un address;
    if (socket_address(session, &address) < 0) return -1;
    // The root-owned directory prevents a client from replacing a socket
    // between bind, authentication, and cleanup. Never remove a stale path.
    if (mkdir(broker_dir, 0755) == 0) {
        if (chmod(broker_dir, 0755) < 0) return -1;
    } else if (errno != EEXIST) {
        return -1;
    }
    if (check_directory() < 0) return -1;
    int fd = stream_socket();
    if (fd < 0) return -1;
    if (bind(fd, (const struct sockaddr *)&address, address.sun_len) < 0) {
        close_preserving_errno(fd);
        return -1;
    }
    if (chmod(address.sun_path, 0600) < 0 || chown(address.sun_path, (uid_t)uid, 0) < 0 || listen(fd, 4) < 0) {
        int error = errno;
        unlink(address.sun_path);
        close(fd);
        return fail(error);
    }
    return fd;
}

int macdpi_tun_broker_unlink(const char *session, uint32_t uid) {
    if (geteuid() != 0 || uid == 0 || uid == UINT32_MAX) return fail(EACCES);
    struct sockaddr_un address;
    if (socket_address(session, &address) < 0 || check_directory() < 0) return -1;
    if (check_socket_owner(&address, (uid_t)uid) < 0) return errno == ENOENT ? 0 : -1;
    return unlink(address.sun_path);
}

static uint64_t monotonic_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}

static int remaining_ms(uint64_t deadline) {
    uint64_t now = monotonic_ms();
    return now >= deadline ? 0 : (int)(deadline - now);
}

static int wait_event(int fd, short events, int cancel_fd, uint64_t deadline) {
    struct pollfd fds[2] = {{.fd = fd, .events = events}, {.fd = cancel_fd, .events = POLLIN}};
    for (;;) {
        int count = poll(fds, 2, remaining_ms(deadline));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return -1;
        if (count == 0) return fail(ETIMEDOUT);
        if (fds[1].revents != 0) return fail(ECANCELED);
        if ((fds[0].revents & POLLNVAL) != 0) return fail(EBADF);
        return 0;
    }
}

static CFDataRef copy_code_hash(SecCodeRef code) {
    CFDictionaryRef info = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != errSecSuccess || info == NULL) return NULL;
    CFDataRef digest = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    CFDataRef retained = NULL;
    if (digest != NULL && CFGetTypeID(digest) == CFDataGetTypeID() && CFDataGetLength(digest) == 20) {
        retained = CFRetain(digest);
    }
    CFRelease(info);
    return retained;
}

static CFDataRef copy_expected_hash(CFURLRef path, CFStringRef architecture) {
    const void *key = kSecCodeAttributeArchitecture;
    const void *value = architecture;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL) return NULL;
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPathAndAttributes(path, kSecCSDefaultFlags, attributes, &code);
    CFRelease(attributes);
    if (status != errSecSuccess || code == NULL) return NULL;
    CFDataRef result = NULL;
    if (SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL) == errSecSuccess) result = copy_code_hash((SecCodeRef)code);
    CFRelease(code);
    return result;
}

static int peer_uid(int fd, uid_t expected) {
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) < 0) return -1;
    return uid == expected ? 0 : fail(EACCES);
}

static int verify_worker(int fd, uid_t uid, CFDataRef arm64, CFDataRef x86_64) {
    if (peer_uid(fd, uid) < 0) return -1;
    audit_token_t token;
    socklen_t length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) < 0 || length != sizeof(token)) return fail(EACCES);
    CFDataRef audit = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    if (audit == NULL) return fail(ENOMEM);
    const void *key = kSecGuestAttributeAudit;
    const void *value = audit;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(audit);
    if (attributes == NULL) return fail(ENOMEM);
    SecCodeRef guest = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &guest);
    CFRelease(attributes);
    if (status != errSecSuccess || guest == NULL) return fail(EACCES);
    CFDataRef digest = NULL;
    if (SecCodeCheckValidity(guest, kSecCSDefaultFlags, NULL) == errSecSuccess) digest = copy_code_hash(guest);
    CFRelease(guest);
    int match = digest != NULL && ((arm64 != NULL && CFEqual(digest, arm64)) || (x86_64 != NULL && CFEqual(digest, x86_64)));
    if (digest != NULL) CFRelease(digest);
    return match ? 0 : fail(EACCES);
}

int macdpi_tun_broker_accept(int listener, uint32_t uid, const char *worker_path, int timeout_ms) {
    if (geteuid() != 0 || uid == 0 || uid == UINT32_MAX) return fail(EACCES);
    if (worker_path == NULL || worker_path[0] != '/' || timeout_ms < 0 || timeout_ms > max_timeout_ms) return fail(EINVAL);
    size_t length = strnlen(worker_path, PATH_MAX);
    if (length == PATH_MAX) return fail(ENAMETOOLONG);
    CFURLRef path = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)worker_path, (CFIndex)length, false);
    if (path == NULL) return fail(EINVAL);
    CFDataRef arm64 = copy_expected_hash(path, CFSTR("arm64"));
    CFDataRef x86_64 = copy_expected_hash(path, CFSTR("x86_64"));
    CFRelease(path);
    if (arm64 == NULL && x86_64 == NULL) return fail(EACCES);

    uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
    int accepted = -1;
    for (unsigned attempts = 0; attempts < 8;) {
        if (wait_event(listener, POLLIN, -1, deadline) < 0) break;
        int fd = accept(listener, NULL, NULL);
        if (fd < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (fd < 0) break;
        ++attempts;
        if (setup_socket(fd) == 0 && verify_worker(fd, (uid_t)uid, arm64, x86_64) == 0) {
            accepted = fd;
            break;
        }
        close_preserving_errno(fd);
    }
    int error = errno;
    if (arm64 != NULL) CFRelease(arm64);
    if (x86_64 != NULL) CFRelease(x86_64);
    return accepted < 0 ? fail(error) : accepted;
}

int macdpi_tun_broker_connect(const char *session, int cancel_fd, int timeout_ms) {
    if (getuid() == 0 || geteuid() != getuid()) return fail(EACCES);
    if (timeout_ms < 0 || timeout_ms > max_timeout_ms) return fail(EINVAL);
    struct sockaddr_un address;
    if (socket_address(session, &address) < 0) return -1;
    uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
    for (;;) {
        int error = 0;
        if (check_directory() < 0 || check_socket_owner(&address, getuid()) < 0) {
            error = errno;
        } else {
            int fd = stream_socket();
            if (fd < 0) return -1;
            if (connect(fd, (const struct sockaddr *)&address, address.sun_len) < 0) {
                error = errno;
                if (error == EINPROGRESS || error == EINTR) {
                    if (wait_event(fd, POLLOUT, cancel_fd, deadline) < 0) {
                        error = errno;
                    } else {
                        socklen_t length = sizeof(error);
                        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) error = errno;
                    }
                }
            }
            if (error == 0 && peer_uid(fd, 0) == 0) return fd;
            if (error == 0) error = errno;
            close(fd);
        }
        if (error != ENOENT && error != ECONNREFUSED && error != EACCES) return fail(error);
        int delay = remaining_ms(deadline);
        if (delay == 0) return fail(ETIMEDOUT);
        if (delay > 200) delay = 200;
        struct pollfd cancel = {.fd = cancel_fd, .events = POLLIN};
        int events = poll(&cancel, 1, delay);
        if (events > 0) return fail(ECANCELED);
        if (events < 0 && errno != EINTR) return -1;
    }
}

static int send_all(int fd, const void *data, size_t count, uint64_t deadline) {
    const uint8_t *bytes = data;
    while (count > 0) {
        if (wait_event(fd, POLLOUT, -1, deadline) < 0) return -1;
        ssize_t n = send(fd, bytes, count, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) return n == 0 ? fail(EPIPE) : -1;
        bytes += n;
        count -= (size_t)n;
    }
    return 0;
}

static ssize_t receive_some(int fd, void *data, size_t count, uint64_t deadline) {
    for (;;) {
        if (wait_event(fd, POLLIN, -1, deadline) < 0) return -1;
        ssize_t n = recv(fd, data, count, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        return n;
    }
}

int macdpi_tun_broker_send_fd(int peer, int packet_fd, uint32_t ipv4_index, uint32_t ipv6_index) {
    if (packet_fd < 3 || (ipv4_index == 0 && ipv6_index == 0) || ipv4_index > INT32_MAX || ipv6_index > INT32_MAX) return fail(EINVAL);
    uint32_t fields[2] = {htonl(ipv4_index), htonl(ipv6_index)};
    struct iovec data = {.iov_base = fields, .iov_len = sizeof(fields)};
    union { struct cmsghdr align; uint8_t bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr message = {.msg_iov = &data, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes)};
    struct cmsghdr *rights = CMSG_FIRSTHDR(&message);
    rights->cmsg_level = SOL_SOCKET;
    rights->cmsg_type = SCM_RIGHTS;
    rights->cmsg_len = CMSG_LEN(sizeof(packet_fd));
    memcpy(CMSG_DATA(rights), &packet_fd, sizeof(packet_fd));
    uint64_t deadline = monotonic_ms() + send_timeout_ms;
    for (;;) {
        if (wait_event(peer, POLLOUT, -1, deadline) < 0) return -1;
        ssize_t n = sendmsg(peer, &message, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) return n == 0 ? fail(EPIPE) : -1;
        return send_all(peer, (const uint8_t *)fields + n, sizeof(fields) - (size_t)n, deadline);
    }
}

int macdpi_tun_broker_receive_fd(int peer, int *packet_fd, uint32_t *ipv4_index, uint32_t *ipv6_index, int timeout_ms) {
    if (packet_fd == NULL || ipv4_index == NULL || ipv6_index == NULL || timeout_ms < 0 || timeout_ms > max_timeout_ms) return fail(EINVAL);
    *packet_fd = -1;
    uint32_t fields[2];
    struct iovec data = {.iov_base = fields, .iov_len = sizeof(fields)};
    union { struct cmsghdr align; uint8_t bytes[CMSG_SPACE(sizeof(int) * 8)]; } control = {0};
    struct msghdr message = {.msg_iov = &data, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes)};
    uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
    ssize_t n;
    for (;;) {
        if (wait_event(peer, POLLIN, -1, deadline) < 0) return -1;
        n = recvmsg(peer, &message, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) return n == 0 ? fail(EPIPE) : -1;
        break;
    }
    int received = -1;
    unsigned descriptor_count = 0;
    for (struct cmsghdr *item = CMSG_FIRSTHDR(&message); item != NULL; item = CMSG_NXTHDR(&message, item)) {
        if (item->cmsg_level != SOL_SOCKET || item->cmsg_type != SCM_RIGHTS || item->cmsg_len < CMSG_LEN(0)) continue;
        size_t count = (item->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t index = 0; index < count; ++index) {
            int fd;
            memcpy(&fd, CMSG_DATA(item) + index * sizeof(fd), sizeof(fd));
            if (descriptor_count++ == 0) received = fd;
            else close(fd);
        }
    }
    if (descriptor_count == 0 && n == 1 && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) {
        const uint8_t marker = ((const uint8_t *)fields)[0];
        if (marker == 'D' || marker == 'X') return fail(ECANCELED); // Verified cleanup before descriptor transfer.
        if (marker == 'F') return fail(ESTALE);   // The broker could not verify recovery.
    }
    if (descriptor_count != 1 || received < 3 || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0) {
        if (received >= 0) close(received);
        return fail(EPROTO);
    }
    if (fcntl(received, F_SETFD, FD_CLOEXEC) < 0) {
        close_preserving_errno(received);
        return -1;
    }
    for (size_t offset = (size_t)n; offset < sizeof(fields);) {
        n = receive_some(peer, (uint8_t *)fields + offset, sizeof(fields) - offset, deadline);
        if (n <= 0) {
            if (n == 0) errno = EPIPE;
            close_preserving_errno(received);
            return -1;
        }
        offset += (size_t)n;
    }
    uint32_t v4 = ntohl(fields[0]), v6 = ntohl(fields[1]);
    if ((v4 == 0 && v6 == 0) || v4 > INT32_MAX || v6 > INT32_MAX) {
        close(received);
        return fail(EPROTO);
    }
    *packet_fd = received;
    *ipv4_index = v4;
    *ipv6_index = v6;
    return 0;
}

int macdpi_tun_validate_packet_fd(int packet_fd) {
    struct sockaddr_ctl address;
    socklen_t length = sizeof(address);
    if (getpeername(packet_fd, (struct sockaddr *)&address, &length) < 0) return -1;
    if (length != sizeof(address) || address.sc_family != AF_SYSTEM || address.ss_sysaddr != AF_SYS_CONTROL) return fail(EPROTO);
    char name[IFNAMSIZ] = {0};
    length = sizeof(name);
    if (getsockopt(packet_fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &length) < 0) return -1;
    if (length <= 4 || length > sizeof(name) || name[length - 1] != '\0' || strncmp(name, "utun", 4) != 0) return fail(EPROTO);
    for (const char *digit = name + 4; *digit != '\0'; ++digit) if (*digit < '0' || *digit > '9') return fail(EPROTO);
    return name[4] == '\0' ? fail(EPROTO) : 0;
}

int macdpi_tun_lease_pair(int fds[2]) {
    if (fds == NULL) return fail(EINVAL);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) return -1;
    if (setup_socket(fds[0]) < 0 || setup_socket(fds[1]) < 0) {
        int error = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = -1;
        fds[1] = -1;
        return fail(error);
    }
    return 0;
}

int macdpi_tun_control_receive(int peer, uint8_t *byte, int timeout_ms) {
    if (byte == NULL || timeout_ms < 0 || timeout_ms > max_timeout_ms) return fail(EINVAL);
    return (int)receive_some(peer, byte, 1, monotonic_ms() + (uint64_t)timeout_ms);
}

int macdpi_tun_control_send(int peer, uint8_t byte) {
    return send_all(peer, &byte, 1, monotonic_ms() + send_timeout_ms);
}
