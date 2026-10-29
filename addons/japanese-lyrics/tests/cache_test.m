#import <Foundation/Foundation.h>
#import "../JPTranslationCache.h"
static void Check(BOOL ok, NSString *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
    printf("PASS: %s\n", label.UTF8String);
}
static NSString *Key(NSUInteger index) { return [NSString stringWithFormat:@"%064lx", (unsigned long)index]; }
static void Wait(BOOL *done) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!*done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    if (!*done) { fprintf(stderr,"Timeout\n"); exit(1); }
}
static NSArray *Read(JPTranslationCache *cache, NSString *key, NSUInteger count) {
    __block BOOL done = NO; __block NSArray *answer = nil;
    [cache readIdentity:key count:count completion:^(NSArray *value) {
        if (!NSThread.isMainThread) exit(1);
        answer = value; done = YES;
    }];
    Wait(&done); return answer;
}
static BOOL Write(JPTranslationCache *cache, NSString *key, NSArray *value) {
    __block BOOL done = NO, success = NO;
    [cache writeIdentity:key translations:value completion:^(BOOL result) {
        if (!NSThread.isMainThread) exit(1);
        success = result; done = YES;
    }];
    Wait(&done); return success;
}
int main(void) {
    @autoreleasepool {
        NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        JPTranslationCache *cache = [[JPTranslationCache alloc] initWithDirectory:dir];
        Check(!Read(cache, Key(1), 1), @"missing cache returns no translation");
        Check(Write(cache, Key(1), @[@"日本語😀"]), @"write creates directory and persists Unicode");
        Check([Read(cache, Key(1), 1) isEqual:@[@"日本語😀"]], @"write invalidates negative memory entry");
        JPTranslationCache *cold = [[JPTranslationCache alloc] initWithDirectory:dir];
        Check([Read(cold, Key(1), 1) isEqual:@[@"日本語😀"]], @"fresh instance restores from disk");
        [NSFileManager.defaultManager removeItemAtURL:[dir URLByAppendingPathComponent:[Key(1) stringByAppendingString:@".json"]] error:NULL];
        Check([Read(cold, Key(1), 1) isEqual:@[@"日本語😀"]], @"warm read survives missing disk file without rereading");
        Check(!Read(cold, Key(1), 2), @"wrong row count cannot be applied");
        Check(!Write(cache, @"../escape", @[@"x"]), @"path traversal rejected on write");
        Check(!Read(cache, @"../escape", 1), @"path traversal rejected on read");
        Check(!Write(cache, Key(2), @[@3]), @"non-string translations rejected");
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"not json" writeToURL:[dir URLByAppendingPathComponent:[Key(3) stringByAppendingString:@".json"]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        Check(!Read(cache, Key(3), 1), @"corrupt JSON does not reach lyrics UI");
        NSURL *huge = [dir URLByAppendingPathComponent:[Key(4) stringByAppendingString:@".json"]];
        [[NSMutableData dataWithLength:3*1024*1024] writeToURL:huge atomically:YES];
        Check(!Read(cache, Key(4), 1), @"oversized cache ignored");
        __block BOOL done = NO;
        [cache readIdentity:Key(1) count:1 completion:^(NSArray *value) { done = YES; }];
        Check(!done, @"warm cache callback is asynchronous"); Wait(&done);
        NSURL *unrelated = [dir URLByAppendingPathComponent:@"user-notes.json"];
        [@"keep" writeToURL:unrelated atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        for (NSUInteger i=10;i<65;i++) if (!Write(cache, Key(i), @[@"x"])) exit(1);
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:NULL];
        Check(files.count == 51, @"disk cache capped at 50 plus unrelated file");
        Check([NSFileManager.defaultManager fileExistsAtPath:unrelated.path], @"cache pruning preserves unrelated files");
        [NSFileManager.defaultManager removeItemAtURL:dir error:NULL];
    }
    return 0;
}
