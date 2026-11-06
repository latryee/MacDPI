#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "../IntegrationSupport/ControlChannel.h"
NS_ASSUME_NONNULL_BEGIN
@interface MDPITransparentProxyBase : NETransparentProxyProvider
- (BOOL)acceptUDPFlow:(NEAppProxyUDPFlow *)flow host:(NSString *)host port:(uint16_t)port NS_SWIFT_NAME(acceptUDP(_:host:port:));
@end
@interface MDPIDNSProxyBase : NEDNSProxyProvider
- (BOOL)acceptUDPFlow:(NEAppProxyUDPFlow *)flow host:(NSString *)host port:(uint16_t)port NS_SWIFT_NAME(acceptUDP(_:host:port:));
@end
/// Public Network.framework C adapter: preserves NE flow metadata on macOS 12+, without Swift overlay casts.
@interface MDPINetworkConnection : NSObject
- (nullable instancetype)initWithHost:(NSString *)host port:(uint16_t)port datagram:(BOOL)datagram flow:(nullable NEAppProxyFlow *)flow NS_SWIFT_NAME(init(host:port:datagram:flow:));
- (void)startOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(start(queue:completion:));
- (void)sendData:(NSData *)data final:(BOOL)final completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(send(_:final:completion:));
- (void)receiveWithCompletion:(void (^)(NSData * _Nullable, BOOL, NSError * _Nullable))completion NS_SWIFT_NAME(receive(completion:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
