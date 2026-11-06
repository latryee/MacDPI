#import "ControlChannel.h"
#import <Security/Security.h>
#import <xpc/xpc.h>
static const size_t MDPIControlBound = 16384;
static NSError *MDPIIPCError(NSInteger code) { return [NSError errorWithDomain:@"io.macdpi.control" code:code userInfo:nil]; }
NSString *MDPICopySigningTeam(void) {
    SecCodeRef code = NULL; CFDictionaryRef information = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    OSStatus result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    CFRelease(code);
    if (result != errSecSuccess || !information) return nil;
    NSDictionary *values = CFBridgingRelease(information);
    NSString *team = values[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    return [team isKindOfClass:NSString.class] && team.length == 10 ? team : nil;
}
@implementation MDPIControlServer {
    NSString *_service; NSString *_requirement; dispatch_queue_t _queue;
    void (^_handler)(NSData *, void (^)(NSData *));
    xpc_connection_t _listener; NSMutableSet *_peers; BOOL _invalidated; NSUInteger _pending;
}
- (instancetype)initWithService:(NSString *)service requiredPeer:(NSString *)requirement queue:(dispatch_queue_t)queue handler:(void (^)(NSData *, void (^)(NSData *)))handler {
    if ((self = [super init])) { _service = [service copy]; _requirement = [requirement copy]; _queue = queue; _handler = [handler copy]; _peers = [NSMutableSet new]; }
    return self;
}
- (BOOL)start {
    if (_listener) return YES;
    if (_invalidated || !_requirement.length) return NO;
    _listener = xpc_connection_create_mach_service(_service.UTF8String, _queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!_listener || xpc_connection_set_peer_code_signing_requirement(_listener, _requirement.UTF8String) != 0) { if (_listener) xpc_connection_cancel(_listener); _listener = nil; return NO; }
    __weak MDPIControlServer *weakSelf = self;
    xpc_connection_set_event_handler(_listener, ^(xpc_object_t event) {
        MDPIControlServer *owner = weakSelf;
        if (!owner || owner->_invalidated || xpc_get_type(event) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)event;
        if (owner->_peers.count >= 8 || xpc_connection_set_peer_code_signing_requirement(peer, owner->_requirement.UTF8String) != 0) { xpc_connection_cancel(peer); return; }
        [owner->_peers addObject:peer];
        __weak xpc_connection_t weakPeer = peer;
        xpc_connection_set_target_queue(peer, owner->_queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            MDPIControlServer *server = weakSelf;
            xpc_connection_t sender = weakPeer;
            if (!server || !sender || server->_invalidated) return;
            if (xpc_get_type(message) == XPC_TYPE_ERROR) { [server->_peers removeObject:sender]; return; }
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
            size_t length = 0; const void *bytes = xpc_dictionary_get_data(message, "request", &length);
            xpc_object_t reply = xpc_dictionary_create_reply(message);
            if (!reply) return;
            if (!bytes || !length || length > 512 || server->_pending >= 16) { xpc_dictionary_set_bool(reply, "rejected", true); xpc_connection_send_message(sender, reply); return; }
            NSData *request = [NSData dataWithBytes:bytes length:length];
            server->_pending += 1;
            __block BOOL replied = NO;
            server->_handler(request, ^(NSData *response) {
                dispatch_async(server->_queue, ^{
                    if (replied || server->_invalidated) return;
                    replied = YES;
                    server->_pending -= 1;
                    if (response.length > MDPIControlBound) xpc_dictionary_set_bool(reply, "rejected", true);
                    else xpc_dictionary_set_data(reply, "response", response.bytes, response.length);
                    xpc_connection_send_message(sender, reply);
                });
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), server->_queue, ^{
                if (!replied && !server->_invalidated) { replied = YES; server->_pending -= 1; xpc_dictionary_set_bool(reply, "rejected", true); xpc_connection_send_message(sender, reply); }
            });
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(_listener);
    return YES;
}
- (void)invalidate {
    if (_invalidated) return; _invalidated = YES;
    for (xpc_connection_t peer in _peers) xpc_connection_cancel(peer);
    [_peers removeAllObjects];
    if (_listener) { xpc_connection_cancel(_listener); _listener = nil; }
    _handler = nil;
}
- (void)dealloc { [self invalidate]; }
@end
@implementation MDPIControlClient {
    xpc_connection_t _connection; dispatch_queue_t _queue; BOOL _invalidated; NSUInteger _pending;
}
- (instancetype)initWithService:(NSString *)service requiredPeer:(NSString *)requirement queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _connection = xpc_connection_create_mach_service(service.UTF8String, queue, 0);
        if (!_connection || !requirement.length || xpc_connection_set_peer_code_signing_requirement(_connection, requirement.UTF8String) != 0) { if (_connection) xpc_connection_cancel(_connection); _connection = nil; _invalidated = YES; return nil; }
        __weak MDPIControlClient *weakSelf = self;
        xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) {
            MDPIControlClient *owner = weakSelf;
            if (owner && !owner->_invalidated && xpc_get_type(event) == XPC_TYPE_ERROR && owner.invalidationHandler) owner.invalidationHandler();
        });
        xpc_connection_activate(_connection);
    }
    return self;
}
- (void)request:(NSData *)request timeout:(NSTimeInterval)timeout completion:(void (^)(NSData *, NSError *))completion {
    if (_invalidated || !request.length || request.length > 512 || _pending >= 16 || timeout < 0.1 || timeout > 15) { completion(nil, MDPIIPCError(1)); return; }
    _pending += 1;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(message, "request", request.bytes, request.length);
    __block BOOL finished = NO;
    void (^deliver)(NSData *, NSError *) = ^(NSData *response, NSError *error) { if (!finished) { finished = YES; self->_pending -= 1; completion(response, error); } };
    xpc_connection_send_message_with_reply(_connection, message, _queue, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_bool(reply, "rejected")) { deliver(nil, MDPIIPCError(2)); return; }
        size_t length = 0; const void *bytes = xpc_dictionary_get_data(reply, "response", &length);
        if (!bytes || !length || length > MDPIControlBound) { deliver(nil, MDPIIPCError(3)); return; }
        deliver([NSData dataWithBytes:bytes length:length], nil);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{ deliver(nil, MDPIIPCError(4)); });
}
- (void)invalidate { if (!_invalidated) { _invalidated = YES; if (_connection) xpc_connection_cancel(_connection); } }
- (void)dealloc { [self invalidate]; }
@end
