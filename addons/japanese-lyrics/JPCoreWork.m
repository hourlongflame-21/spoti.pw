#import "JPCoreWork.h"
BOOL JPCoreLayerInvisible(BOOL hidden, double modelAlpha, BOOL hasPresentation, double presentationAlpha) {
    return hidden || (modelAlpha <= 0 && (!hasPresentation || presentationAlpha <= 0));
}
@implementation JPCoreWork {
    NSCache *_results;
    NSMutableDictionary<NSString *, NSMutableArray *> *_pending;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _results = [NSCache new]; _results.countLimit = 96; _results.totalCostLimit = 12*1024*1024;
    _pending = [NSMutableDictionary dictionary];
    return self;
}
- (void)request:(NSString *)key start:(void (^)(void (^)(id)))start completion:(void (^)(id))completion {
    NSAssert(NSThread.isMainThread, @"Main-thread cache coordination required");
    id known = [_results objectForKey:key];
    if (known) { dispatch_async(dispatch_get_main_queue(), ^{ completion(known); }); return; }
    NSMutableArray *waiting = _pending[key];
    if (waiting) { [waiting addObject:[completion copy]]; return; }
    _pending[key] = [NSMutableArray arrayWithObject:[completion copy]];
    start(^(id result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) [self->_results setObject:result forKey:key cost:128*1024];
            NSArray *callbacks = self->_pending[key];
            [self->_pending removeObjectForKey:key];
            for (void (^callback)(id) in callbacks) callback(result);
        });
    });
}
- (void)clear { [_results removeAllObjects]; }
@end
