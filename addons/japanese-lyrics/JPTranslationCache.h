#import <Foundation/Foundation.h>
@interface JPTranslationCache : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)readIdentity:(NSString *)identity count:(NSUInteger)count completion:(void (^)(NSArray *translations))completion;
- (void)writeIdentity:(NSString *)identity translations:(NSArray *)translations completion:(void (^)(BOOL success))completion;
@end
