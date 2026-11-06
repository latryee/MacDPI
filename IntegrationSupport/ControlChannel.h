#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Bounded control-state IPC only. Peers are checked by libxpc against an exact Developer ID requirement on every message.
@interface MDPIControlServer : NSObject
- (instancetype)initWithService:(NSString *)service requiredPeer:(NSString *)requirement
                         queue:(dispatch_queue_t)queue handler:(void (^)(NSData *, void (^)(NSData *)))handler;
- (BOOL)start;
- (void)invalidate;
@end
@interface MDPIControlClient : NSObject
@property (copy, nullable) void (^invalidationHandler)(void);
- (nullable instancetype)initWithService:(NSString *)service requiredPeer:(NSString *)requirement queue:(dispatch_queue_t)queue;
- (void)request:(NSData *)request timeout:(NSTimeInterval)timeout completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion;
- (void)invalidate;
@end
FOUNDATION_EXPORT NSString * _Nullable MDPICopySigningTeam(void);
NS_ASSUME_NONNULL_END
