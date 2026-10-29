#import <Foundation/Foundation.h>
BOOL JPCoreLayerInvisible(BOOL hidden, double modelAlpha, BOOL hasPresentation, double presentationAlpha);
@interface JPCoreWork : NSObject
- (void)request:(NSString *)key start:(void (^)(void (^finish)(id result)))start completion:(void (^)(id result))completion;
- (void)clear;
@end
