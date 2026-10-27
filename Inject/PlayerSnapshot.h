#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface BRPlayerSnapshot : NSObject
+ (NSArray<NSDictionary<NSString *, id> *> *)snapshotIgnoringRenderFlags:(BOOL)ignoreRenderFlags maxDistance:(double)maxDistance NS_SWIFT_NAME(snapshot(ignoringRenderFlags:maxDistance:));
+ (void)configureAspect:(double)scale;
+ (NSDictionary<NSString *, id> *)aspectState;
+ (void)configureAim:(NSDictionary<NSString *, id> *)settings NS_SWIFT_NAME(configureAim(_:));
+ (NSDictionary<NSString *, id> *)aimFrame:(double)width height:(double)height stretch:(double)stretch NS_SWIFT_NAME(aimFrame(width:height:stretch:));
+ (BOOL)clearChatForController:(NSObject *)controller NS_SWIFT_NAME(clearChat(forController:));
+ (NSString *)extensionStatus;
+ (void)configureChatAliases:(NSDictionary<NSString *,NSString *> *)rules NS_SWIFT_NAME(configureChatAliases(_:));
+ (NSString *)sendChatCommand:(NSString *)command NS_SWIFT_NAME(sendChatCommand(_:));
+ (uint64_t)ownShotCount;
+ (NSString *)status;
+ (NSArray<NSNumber *> *)projectionMatrix;
+ (void)tickControls:(double)elapsed;
+ (void)stopControls;
+ (void)configureControls:(NSDictionary<NSString *, NSNumber *> *)settings NS_SWIFT_NAME(configureControls(_:));
+ (NSDictionary<NSString *, id> *)localState;
+ (NSString *)performAction:(NSString *)action values:(NSDictionary<NSString *, NSNumber *> *)values NS_SWIFT_NAME(perform(action:values:));
@end
NS_ASSUME_NONNULL_END

