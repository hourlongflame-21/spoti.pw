#import <Foundation/Foundation.h>
#import "../JPCoreWork.h"
static void Check(BOOL ok, NSString *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
    printf("PASS: %s\n", label.UTF8String);
}
static void Pump(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    if (!done()) exit(1);
}
int main(void) {
    @autoreleasepool {
        Check(JPCoreLayerInvisible(YES,1,NO,0), @"hidden ancestor suppresses drawing");
        Check(JPCoreLayerInvisible(NO,0,NO,0), @"transparent static layer suppresses drawing");
        Check(JPCoreLayerInvisible(NO,0,YES,0), @"finished fade suppresses drawing");
        Check(!JPCoreLayerInvisible(NO,0,YES,0.5), @"fading-out presentation remains visible");
        Check(!JPCoreLayerInvisible(NO,1,YES,0), @"fading-in layer is not suppressed");
        Check(!JPCoreLayerInvisible(NO,0.001,NO,0), @"faint visible layers are preserved");
        Check(!JPCoreLayerInvisible(NO,1,NO,0), @"visible layer resumes without stored hidden state");
        JPCoreWork *work = [JPCoreWork new];
        __block NSUInteger starts=0, delivered=0;
        __block void (^finish)(id) = nil;
        void (^start)(void (^)(id)) = ^(void (^callback)(id)) { starts++; finish = callback; };
        [work request:@"same" start:start completion:^(id result) { if (![result isEqual:@"color"]) exit(1); delivered++; }];
        [work request:@"same" start:start completion:^(id result) { if (![result isEqual:@"color"]) exit(1); delivered++; }];
        Check(starts == 1, @"duplicate in-flight color calculations start only once");
        finish(@"color"); finish = nil;
        Check(delivered == 0, @"completion always delivered asynchronously");
        Pump(^BOOL { return delivered == 2; });
        Check(delivered == 2, @"both original callers receive their result");
        [work request:@"same" start:start completion:^(id result) { (void)result; delivered++; }];
        Pump(^BOOL { return delivered == 3; });
        Check(starts == 1, @"repeated color request reuses completed result");
        [work request:@"other-surface" start:start completion:^(id result) { (void)result; delivered++; }];
        Check(starts == 2, @"different surface or request key is calculated separately");
        finish(nil); finish = nil; Pump(^BOOL { return delivered == 4; });
        [work request:@"other-surface" start:start completion:^(id result) { (void)result; delivered++; }];
        Check(starts == 3, @"failed calculations are not cached permanently");
        finish(@"new"); finish = nil; Pump(^BOOL { return delivered == 5; });
        [work clear];
        [work request:@"same" start:start completion:^(id result) { (void)result; delivered++; }];
        Check(starts == 4, @"clearing results recomputes next request");
        finish(@"color"); finish = nil; Pump(^BOOL { return delivered == 6; });
    }
    return 0;
}
