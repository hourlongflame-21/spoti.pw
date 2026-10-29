#import "JPTranslationCache.h"
static BOOL SafeIdentity(NSString *identity) {
    return identity.length == 64 && [identity rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static BOOL Valid(id value, NSUInteger count) {
    if (![value isKindOfClass:NSArray.class] || [value count] != count) return NO;
    for (id text in value) if (![text isKindOfClass:NSString.class] || [text length] > 8192) return NO;
    return YES;
}
@implementation JPTranslationCache {
    NSURL *_directory;
    NSCache *_memory;
    dispatch_queue_t _queue;
}
- (instancetype)initWithDirectory:(NSURL *)directory {
    if (!(self = [super init])) return nil;
    _directory = directory;
    _memory = [NSCache new]; _memory.countLimit = 50; _memory.totalCostLimit = 8*1024*1024;
    _queue = dispatch_queue_create("local.hourlong.translation-cache", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (NSURL *)url:(NSString *)identity { return [_directory URLByAppendingPathComponent:[identity stringByAppendingString:@".json"]]; }
- (void)readIdentity:(NSString *)identity count:(NSUInteger)count completion:(void (^)(NSArray *))completion {
    dispatch_async(_queue, ^{
        NSArray *answer = nil;
        if (SafeIdentity(identity)) {
            id cached = [self->_memory objectForKey:identity];
            if (!cached) {
                NSURL *url = [self url:identity];
                NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
                NSData *data = size.unsignedLongLongValue <= 2*1024*1024 ? [NSData dataWithContentsOfURL:url] : nil;
                id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                cached = Valid(value, count) ? value : NSNull.null;
                [self->_memory setObject:cached forKey:identity cost:MAX((NSUInteger)1, data.length)];
            }
            if (Valid(cached, count)) answer = cached;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(answer); });
    });
}
- (void)writeIdentity:(NSString *)identity translations:(NSArray *)translations completion:(void (^)(BOOL))completion {
    NSArray *snapshot = [translations copy];
    dispatch_async(_queue, ^{
        BOOL success = NO;
        if (SafeIdentity(identity) && Valid(snapshot, snapshot.count)) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
            if (data && data.length <= 2*1024*1024) {
                [self->_memory setObject:snapshot forKey:identity cost:data.length];
                [NSFileManager.defaultManager createDirectoryAtURL:self->_directory withIntermediateDirectories:YES attributes:nil error:NULL];
                success = [data writeToURL:[self url:identity] options:NSDataWritingAtomic error:NULL];
                NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self->_directory
                    includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:NULL];
                NSMutableArray *files = [NSMutableArray array];
                for (NSURL *url in entries) if ([url.pathExtension isEqual:@"json"] && SafeIdentity(url.lastPathComponent.stringByDeletingPathExtension)) [files addObject:url];
                if (files.count > 50) {
                    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
                        NSDate *ad = nil, *bd = nil;
                        [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:NULL];
                        [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:NULL];
                        return [(ad ?: NSDate.distantPast) compare:bd ?: NSDate.distantPast];
                    }];
                    for (NSUInteger i=0; i<files.count-50; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:NULL];
                }
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    });
}
@end
