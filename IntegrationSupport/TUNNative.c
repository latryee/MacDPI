#include "TUNNative.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_utun.h>
#include <net/route.h>
#include <netinet6/in6_var.h>
#include <poll.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

enum { packetMTU = 1500, routeSnapshotLimit = 4 * 1024 * 1024 };

static size_t aligned_length(size_t length) {
    return length == 0 ? sizeof(uint32_t) : (length + sizeof(uint32_t) - 1) & ~(sizeof(uint32_t) - 1);
}

static size_t address_offset(int family) {
    return family == AF_INET ? offsetof(struct sockaddr_in, sin_addr) : offsetof(struct sockaddr_in6, sin6_addr);
}

static size_t address_length(int family) { return family == AF_INET ? 4 : 16; }

static int read_prefix(const struct sockaddr *mask, int family, bool host, uint8_t *prefix) {
    const size_t bytes = address_length(family), offset = address_offset(family);
    *prefix = 0;
    if (host) { *prefix = (uint8_t)(bytes * 8); return 0; }
    if (!mask) return 0;
    bool seenZero = false;
    const uint8_t *raw = (const uint8_t *)mask;
    for (size_t i = 0; i < bytes; i++) {
        const uint8_t value = offset + i < mask->sa_len ? raw[offset + i] : 0;
        for (int bit = 7; bit >= 0; bit--) {
            if ((value & (1u << bit)) == 0) seenZero = true;
            else if (seenZero) return EINVAL;
            else (*prefix)++;
        }
    }
    return 0;
}

static int decode_route(const struct rt_msghdr2 *header, const uint8_t *cursor, const uint8_t *end, MDPIRoute *route) {
    const struct sockaddr *fields[RTAX_MAX] = {0};
    for (int field = 0; field < RTAX_MAX; field++) {
        if (!(header->rtm_addrs & (1u << field))) continue;
        if ((size_t)(end - cursor) < 2) return EPROTO;
        const struct sockaddr *addr = (const struct sockaddr *)cursor;
        const size_t length = aligned_length(addr->sa_len);
        if (length > (size_t)(end - cursor)) return EPROTO;
        fields[field] = addr;
        cursor += length;
    }
    const struct sockaddr *dest = fields[RTAX_DST], *gateway = fields[RTAX_GATEWAY];
    if (!dest || (dest->sa_family != AF_INET && dest->sa_family != AF_INET6)) return EAFNOSUPPORT;
    const int family = dest->sa_family;
    const size_t width = address_length(family), offset = address_offset(family);
    if (dest->sa_len < offset + width || header->rtm_index == 0) return EPROTO;
    memset(route, 0, sizeof(*route));
    route->family = family == AF_INET ? 4 : 6;
    route->interfaceIndex = header->rtm_index;
    route->flags = (uint32_t)header->rtm_flags;
    int error = read_prefix(fields[RTAX_NETMASK], family, header->rtm_flags & RTF_HOST, &route->prefix);
    if (error) return error;
    memcpy(route->network, (const uint8_t *)dest + offset, width);
    if (gateway && (gateway->sa_family == AF_INET || gateway->sa_family == AF_INET6)) {
        const size_t gwWidth = address_length(gateway->sa_family), gwOffset = address_offset(gateway->sa_family);
        if (gateway->sa_len < gwOffset + gwWidth) return EPROTO;
        route->gatewayFamily = gateway->sa_family == AF_INET ? 4 : 6;
        memcpy(route->gateway, (const uint8_t *)gateway + gwOffset, gwWidth);
    } else if (gateway && gateway->sa_family == AF_LINK) {
        route->gatewayFamily = AF_LINK;
        if (gateway->sa_len < offsetof(struct sockaddr_dl, sdl_index) + sizeof(uint16_t)) return EPROTO;
        memcpy(&route->linkGatewayIndex, (const uint8_t *)gateway + offsetof(struct sockaddr_dl, sdl_index), sizeof(uint16_t));
    }
    return 0;
}

int mdpi_route_snapshot(MDPIRoute *routes, size_t capacity, size_t *count) {
    if (!routes || !count || capacity == 0 || capacity > 32768) return EINVAL;
    *count = 0;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP2, 0};
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) < 0) return errno;
    if (length == 0 || length > routeSnapshotLimit) return EOVERFLOW;
    const size_t slack = 32768;
    length += slack;
    uint8_t *buffer = malloc(length);
    if (!buffer) return ENOMEM;
    int error = 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) < 0) { error = errno; goto done; }
    for (size_t offset = 0; offset < length;) {
        if (length - offset < sizeof(struct rt_msghdr2)) { error = EPROTO; break; }
        // The kernel aligns sockaddrs on a 4-byte boundary. The message itself need
        // not satisfy alignment of every C structure on both target architectures.
        struct rt_msghdr2 header;
        memcpy(&header, buffer + offset, sizeof(header));
        if (header.rtm_msglen < sizeof(header) || header.rtm_msglen > length - offset ||
            header.rtm_version != RTM_VERSION) { error = EPROTO; break; }
        if (*count == capacity) { error = EOVERFLOW; break; }
        // `decode_route` parses only the bounded message slice.
        error = decode_route(&header, buffer + offset + sizeof(header),
                             buffer + offset + header.rtm_msglen, routes + *count);
        if (error == 0) (*count)++;
        else if (error == EAFNOSUPPORT) error = 0;
        else break;
        offset += header.rtm_msglen;
    }
done:
    free(buffer);
    if (error) *count = 0;
    return error;
}

static struct sockaddr_in ipv4_address(const char *address) {
    struct sockaddr_in result = { .sin_len = sizeof(result), .sin_family = AF_INET };
    inet_pton(AF_INET, address, &result.sin_addr);
    return result;
}

static struct sockaddr_in6 ipv6_address(const char *address) {
    struct sockaddr_in6 result = { .sin6_len = sizeof(result), .sin6_family = AF_INET6 };
    inet_pton(AF_INET6, address, &result.sin6_addr);
    return result;
}

static int configure_interface(const char *name, int enableIPv6) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return errno;
    struct ifreq ifr = {0};
    strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
    ifr.ifr_mtu = packetMTU;
    int error = ioctl(fd, SIOCSIFMTU, &ifr) < 0 ? errno : 0;
    if (error == 0 && ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) error = errno;
    if (error == 0) {
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(fd, SIOCSIFFLAGS, &ifr) < 0) error = errno;
    }
    if (error == 0) {
        struct ifaliasreq alias = {0};
        strlcpy(alias.ifra_name, name, sizeof(alias.ifra_name));
        const struct sockaddr_in addr = ipv4_address("198.18.0.1"), peer = ipv4_address("198.18.0.2");
        const struct sockaddr_in mask = ipv4_address("255.255.255.252");
        memcpy(&alias.ifra_addr, &addr, sizeof(addr));
        memcpy(&alias.ifra_broadaddr, &peer, sizeof(peer));
        memcpy(&alias.ifra_mask, &mask, sizeof(mask));
        if (ioctl(fd, SIOCAIFADDR, &alias) < 0) error = errno;
    }
    close(fd);
    if (error || !enableIPv6) return error;

    fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd < 0) return errno;
    struct in6_aliasreq alias = {0};
    strlcpy(alias.ifra_name, name, sizeof(alias.ifra_name));
    alias.ifra_addr = ipv6_address("fd75:554e:4d44:5049::1");
    alias.ifra_dstaddr = ipv6_address("fd75:554e:4d44:5049::2");
    alias.ifra_prefixmask = ipv6_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff");
    alias.ifra_flags = IN6_IFF_NODAD;
    alias.ifra_lifetime.ia6t_vltime = UINT32_MAX;
    alias.ifra_lifetime.ia6t_pltime = UINT32_MAX;
    error = ioctl(fd, SIOCAIFADDR_IN6, &alias) < 0 ? errno : 0;
    close(fd);
    return error;
}

int mdpi_tun_open(int enableIPv6, char *name, size_t nameCapacity, int *outFD) {
    if (!name || nameCapacity < IFNAMSIZ || !outFD || (enableIPv6 != 0 && enableIPv6 != 1)) return EINVAL;
    *outFD = -1;
    name[0] = '\0';
    if (geteuid() != 0) return EPERM;
    const int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return errno;
    int error = 0;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || ioctl(fd, CTLIOCGINFO, &info) < 0) { error = errno; goto fail; }
    const struct sockaddr_ctl address = { .sc_len = sizeof(address), .sc_family = AF_SYSTEM,
        .ss_sysaddr = AF_SYS_CONTROL, .sc_id = info.ctl_id, .sc_unit = 0 };
    if (connect(fd, (const struct sockaddr *)&address, sizeof(address)) < 0) { error = errno; goto fail; }
    socklen_t nameLength = IFNAMSIZ;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &nameLength) < 0) { error = errno; goto fail; }
    if (nameLength < 6 || nameLength > IFNAMSIZ || name[nameLength - 1] || strncmp(name, "utun", 4) != 0) { error = EPROTO; goto fail; }
    error = configure_interface(name, enableIPv6);
    if (error) goto fail;
    *outFD = fd;
    return 0;
fail:
    close(fd);
    name[0] = '\0';
    return error;
}

static size_t append_address(uint8_t *buffer, const void *address, size_t size) {
    memcpy(buffer, address, size);
    return aligned_length(size);
}

static int exchange_route(struct rt_msghdr *request, uint16_t *replyIndex) {
    const int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return errno;
    int error = 0;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) error = errno;
    else {
        const ssize_t count = write(fd, request, request->rtm_msglen);
        if (count != request->rtm_msglen) error = count < 0 ? errno : EIO;
        else {
            struct pollfd watch = { .fd = fd, .events = POLLIN };
            error = ETIMEDOUT;
            for (unsigned attempt = 0; attempt < 16 && poll(&watch, 1, 100) == 1; attempt++) {
                uint8_t buffer[2048];
                const ssize_t size = read(fd, buffer, sizeof(buffer));
                if (size < (ssize_t)sizeof(struct rt_msghdr)) continue;
                struct rt_msghdr reply;
                memcpy(&reply, buffer, sizeof(reply));
                if (reply.rtm_version == RTM_VERSION && reply.rtm_type == request->rtm_type &&
                    reply.rtm_pid == request->rtm_pid && reply.rtm_seq == request->rtm_seq) {
                    error = reply.rtm_errno;
                    if (error == 0 && replyIndex) *replyIndex = reply.rtm_index;
                    break;
                }
            }
        }
    }
    close(fd);
    return error;
}

int mdpi_route_scoped_interface(const MDPIRoute *route, uint16_t *interfaceIndex) {
    if (!route || !interfaceIndex || !route->interfaceIndex || (route->family != 4 && route->family != 6)) return EINVAL;
    *interfaceIndex = 0;
    struct {
        struct rt_msghdr header;
        uint8_t addresses[64];
    } request = {0};
    request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_GET;
    request.header.rtm_index = route->interfaceIndex;
    request.header.rtm_flags = RTF_IFSCOPE;
    request.header.rtm_addrs = RTA_DST;
    request.header.rtm_pid = getpid();
    request.header.rtm_seq = 1;
    size_t length;
    if (route->family == 4) {
        struct sockaddr_in dest = ipv4_address("0.0.0.0");
        memcpy(&dest.sin_addr, route->network, 4);
        length = append_address(request.addresses, &dest, sizeof(dest));
    } else {
        struct sockaddr_in6 dest = ipv6_address("::");
        memcpy(&dest.sin6_addr, route->network, 16);
        length = append_address(request.addresses, &dest, sizeof(dest));
    }
    request.header.rtm_msglen = (uint16_t)(sizeof(request.header) + length);
    return exchange_route(&request.header, interfaceIndex);
}

int mdpi_tun_add_route(int tunFD, const MDPIRoute *route) {
    if (geteuid() != 0) return EPERM;
    if (tunFD < 0 || !route || (route->family != 4 && route->family != 6) || !route->interfaceIndex) return EINVAL;
    const int family = route->family == 4 ? AF_INET : AF_INET6;
    const size_t width = address_length(family);
    if (!route->prefix || route->prefix > width * 8) return EINVAL;
    char name[IFNAMSIZ] = {0};
    socklen_t nameLength = sizeof(name);
    if (getsockopt(tunFD, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &nameLength) < 0) return errno;
    if (if_nametoindex(name) != route->interfaceIndex) return ENXIO;
    struct {
        struct rt_msghdr header;
        uint8_t addresses[256];
    } request = {0};
    request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_ADD;
    request.header.rtm_index = route->interfaceIndex;
    request.header.rtm_flags = RTF_UP | RTF_STATIC;
    request.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK | RTA_IFP;
    request.header.rtm_pid = getpid();
    request.header.rtm_seq = 1; // One message per freshly opened route socket.
    uint8_t mask[16] = {0};
    for (size_t bit = 0; bit < route->prefix; bit++) mask[bit / 8] |= 0x80u >> (bit % 8);
    for (size_t i = 0; i < width; i++) if (route->network[i] & ~mask[i]) return EINVAL;
    struct sockaddr_dl link = { .sdl_len = sizeof(link), .sdl_family = AF_LINK, .sdl_index = route->interfaceIndex };
    size_t offset = 0;
    if (family == AF_INET) {
        struct sockaddr_in dst = ipv4_address("0.0.0.0"), netmask = dst;
        memcpy(&dst.sin_addr, route->network, width);
        memcpy(&netmask.sin_addr, mask, width);
        offset += append_address(request.addresses + offset, &dst, sizeof(dst));
        offset += append_address(request.addresses + offset, &link, sizeof(link));
        offset += append_address(request.addresses + offset, &netmask, sizeof(netmask));
    } else {
        struct sockaddr_in6 dst = ipv6_address("::"), netmask = dst;
        memcpy(&dst.sin6_addr, route->network, width);
        memcpy(&netmask.sin6_addr, mask, width);
        offset += append_address(request.addresses + offset, &dst, sizeof(dst));
        offset += append_address(request.addresses + offset, &link, sizeof(link));
        offset += append_address(request.addresses + offset, &netmask, sizeof(netmask));
    }
    offset += append_address(request.addresses + offset, &link, sizeof(link));
    request.header.rtm_msglen = (uint16_t)(sizeof(request.header) + offset);
    return exchange_route(&request.header, NULL);
}
