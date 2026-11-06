#import "NetworkTransportBridge.h"
#import <Network/Network.h>
// The Swift SDK exposes two ambiguous NWEndpoint types and a macOS 15 protocol overlay.
// Public Objective-C selectors adapt both OS generations to the same small Swift entry point.
#define MDPI_UDP_ADAPTER \
- (BOOL)acceptUDPFlow:(NEAppProxyUDPFlow *)flow host:(NSString *)host port:(uint16_t)port { return NO; } \
- (BOOL)handleNewUDPFlow:(NEAppProxyUDPFlow *)flow initialRemoteEndpoint:(NWEndpoint *)endpoint { \
    if (![endpoint isKindOfClass:NWHostEndpoint.class]) return NO; \
    NWHostEndpoint *host = (NWHostEndpoint *)endpoint; NSInteger port = host.port.integerValue; \
    return port > 0 && port <= UINT16_MAX ? [self acceptUDPFlow:flow host:host.hostname port:(uint16_t)port] : NO; \
} \
- (BOOL)handleNewUDPFlow:(NEAppProxyUDPFlow *)flow initialRemoteFlowEndpoint:(nw_endpoint_t)endpoint { \
    if (nw_endpoint_get_type(endpoint) != nw_endpoint_type_host) return NO; \
    const char *host = nw_endpoint_get_hostname(endpoint); uint16_t port = nw_endpoint_get_port(endpoint); \
    return host && port ? [self acceptUDPFlow:flow host:[NSString stringWithUTF8String:host] port:port] : NO; \
}
@implementation MDPITransparentProxyBase
MDPI_UDP_ADAPTER
@end
@implementation MDPIDNSProxyBase
MDPI_UDP_ADAPTER
@end
#undef MDPI_UDP_ADAPTER
static NSError *MDPINetworkError(nw_error_t error) {
    if (!error) return nil;
    return [NSError errorWithDomain:@"io.macdpi.transport" code:nw_error_get_error_code(error) userInfo:nil];
}
@implementation MDPINetworkConnection {
    nw_connection_t _connection; BOOL _datagram; BOOL _closed; BOOL _started;
    void (^_startCompletion)(NSError *); dispatch_queue_t _queue;
}
- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port datagram:(BOOL)datagram flow:(NEAppProxyFlow *)flow {
    if (!port || !host.length) return nil;
    if ((self = [super init])) {
        _datagram = datagram;
        nw_parameters_t parameters = datagram ? nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION)
            : nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) { nw_tcp_options_set_no_delay(tcp, true); nw_tcp_options_set_enable_keepalive(tcp, true); });
        nw_parameters_set_prefer_no_proxy(parameters, true);
        if (flow) {
            [flow setMetadata:parameters];
            if (flow.isBound) {
                nw_interface_t interface = flow.networkInterface;
                if (!interface) return nil;
                nw_parameters_require_interface(parameters, interface);
            }
        }
        nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, [NSString stringWithFormat:@"%hu", port].UTF8String);
        _connection = nw_connection_create(endpoint, parameters);
    }
    return self;
}
- (void)startOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion {
    if (_closed || _started) { completion([NSError errorWithDomain:@"io.macdpi.transport" code:1 userInfo:nil]); return; }
    _started = YES; _queue = queue; _startCompletion = [completion copy];
    nw_connection_set_queue(_connection, queue);
    __weak MDPINetworkConnection *weakSelf = self;
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        MDPINetworkConnection *owner = weakSelf;
        if (!owner || owner->_closed || !owner->_startCompletion) return;
        if (state == nw_connection_state_ready || state == nw_connection_state_failed || state == nw_connection_state_waiting) {
            void (^callback)(NSError *) = owner->_startCompletion; owner->_startCompletion = nil;
            callback(state == nw_connection_state_ready ? nil : (MDPINetworkError(error) ?: [NSError errorWithDomain:@"io.macdpi.transport" code:2 userInfo:nil]));
        }
    });
    nw_connection_start(_connection);
}
- (void)sendData:(NSData *)data final:(BOOL)final completion:(void (^)(NSError *))completion {
    if (_closed) { completion([NSError errorWithDomain:@"io.macdpi.transport" code:1 userInfo:nil]); return; }
    NSData *held = [data copy];
    dispatch_data_t content = held.length ? dispatch_data_create(held.bytes, held.length, _queue, ^{ (void)held; }) : dispatch_data_empty;
    nw_connection_send(_connection, (!_datagram && final && !held.length) ? NULL : content,
                       final && !_datagram ? NW_CONNECTION_FINAL_MESSAGE_CONTEXT : NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t error) { completion(MDPINetworkError(error)); });
}
- (void)receiveWithCompletion:(void (^)(NSData *, BOOL, NSError *))completion {
    if (_closed) { completion(nil, YES, [NSError errorWithDomain:@"io.macdpi.transport" code:1 userInfo:nil]); return; }
    void (^received)(dispatch_data_t, nw_content_context_t, bool, nw_error_t) = ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        const void *bytes = NULL; size_t count = 0;
        dispatch_data_t mapped = content ? dispatch_data_create_map(content, &bytes, &count) : nil;
        NSData *data = content ? [NSData dataWithBytes:bytes length:count] : nil;
        (void)mapped;
        completion(data, complete, MDPINetworkError(error));
    };
    if (_datagram) nw_connection_receive_message(_connection, received);
    else nw_connection_receive(_connection, 1, 65536, received);
}
- (void)cancel {
    if (_closed) return; _closed = YES; _startCompletion = nil;
    nw_connection_set_state_changed_handler(_connection, nil); nw_connection_cancel(_connection);
}
- (void)dealloc { [self cancel]; }
@end
