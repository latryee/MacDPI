#ifndef MACDPI_TUN_NATIVE_H
#define MACDPI_TUN_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t family; // 4 or 6
    uint8_t prefix;
    uint8_t gatewayFamily; // 0, 4, 6, or 18 (link)
    uint16_t interfaceIndex;
    uint16_t linkGatewayIndex;
    uint32_t flags;
    uint8_t network[16];
    uint8_t gateway[16];
} MDPIRoute;

// Returns an errno value. No mutation is performed by the snapshot operation.
int mdpi_route_snapshot(MDPIRoute *routes, size_t capacity, size_t *count);
int mdpi_tun_open(int enableIPv6, char *name, size_t nameCapacity, int *fd);
// Adds a route to a live utun with RTM_ADD. There is no change or delete primitive.
int mdpi_tun_add_route(int tunFD, const MDPIRoute *route);
int mdpi_route_scoped_interface(const MDPIRoute *route, uint16_t *interfaceIndex);

#endif
