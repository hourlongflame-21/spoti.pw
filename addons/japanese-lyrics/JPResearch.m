#import "JPResearch.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSDictionary *Dict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSArray *Array(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *String(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static BOOL Index(id value, NSUInteger limit, NSUInteger *out) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0 || number != floor(number) || number >= limit) return NO;
    *out = [value unsignedIntegerValue]; return YES;
}
BOOL JPResearchURLAllowed(NSURL *url) {
    return [url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user.length && !url.password.length;
}
NSDictionary *JPDecodeResearch(NSData *data, NSInteger status, NSString **failure) {
    if (!data || data.length > 1024*1024) { *failure = @"応答が空、または大きすぎます。"; return nil; }
    NSDictionary *root = Dict([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]);
    if (status < 200 || status >= 300 || !root) {
        *failure = [NSString stringWithFormat:@"検索解説を取得できませんでした（HTTP %ld）。APIキー・モデルの検索対応・利用上限を確認してください。", (long)status]; return nil;
    }
    NSDictionary *candidate = Dict(Array(root[@"candidates"]).firstObject);
    if (![String(candidate[@"finishReason"]) isEqual:@"STOP"]) {
        *failure = @"応答が完了しませんでした。出力上限・利用制限などの可能性があります。"; return nil;
    }
    NSArray *parts = Array(Dict(candidate[@"content"])[@"parts"]);
    if (parts.count > 128) { *failure = @"応答の構造が大きすぎます。"; return nil; }
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *partOffsets = [NSMutableArray array], *partTexts = [NSMutableArray array];
    for (id item in parts) {
        NSDictionary *part = Dict(item);
        NSString *value = String(part[@"text"]);
        BOOL thought = [part[@"thought"] isKindOfClass:NSNumber.class] && [part[@"thought"] boolValue];
        if (value && !thought) {
            [partOffsets addObject:@(text.length)]; [partTexts addObject:value]; [text appendString:value];
        } else { [partOffsets addObject:NSNull.null]; [partTexts addObject:NSNull.null]; }
    }
    if (!text.length || text.length > 120000) { *failure = @"解説テキストを読み取れませんでした。"; return nil; }
    NSDictionary *metadata = Dict(candidate[@"groundingMetadata"]);
    NSArray *chunks = Array(metadata[@"groundingChunks"]), *supports = Array(metadata[@"groundingSupports"]);
    if (chunks.count > 64 || supports.count > 512) { *failure = @"出典データが大きすぎます。"; return nil; }
    NSMutableArray *sources = [NSMutableArray array], *citations = [NSMutableArray array];
    NSMutableDictionary *sourceMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < chunks.count; i++) {
        NSDictionary *web = Dict(Dict(chunks[i])[@"web"]);
        NSString *uri = String(web[@"uri"]);
        NSURL *url = uri.length <= 8192 ? [NSURL URLWithString:uri ?: @""] : nil;
        if (!JPResearchURLAllowed(url)) continue;
        NSString *title = String(web[@"title"]);
        if (!title.length || title.length > 1024) title = url.host;
        NSDictionary *source = @{@"number":@(i + 1), @"title":title, @"url":url.absoluteString};
        sourceMap[@(i)] = source; [sources addObject:source];
    }
    NSMutableSet *used = [NSMutableSet set];
    for (id item in supports) {
        NSDictionary *support = Dict(item), *segment = Dict(support[@"segment"]);
        NSUInteger partIndex, start, end;
        if (!Index(segment[@"partIndex"] ?: @0, parts.count, &partIndex) ||
            partOffsets[partIndex] == NSNull.null) continue;
        NSString *part = partTexts[partIndex];
        NSData *bytes = [part dataUsingEncoding:NSUTF8StringEncoding];
        if (!Index(segment[@"startIndex"] ?: @0, bytes.length + 1, &start) ||
            !Index(segment[@"endIndex"], bytes.length + 1, &end) || end <= start) continue;
        NSString *prefix = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(0, end)] encoding:NSUTF8StringEncoding];
        NSString *selected = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(start, end - start)] encoding:NSUTF8StringEncoding];
        if (!prefix || !selected) continue; // Never split UTF-8 Japanese or emoji.
        NSString *reported = String(segment[@"text"]);
        if (reported && ![reported isEqual:selected]) continue;
        NSUInteger offset = [partOffsets[partIndex] unsignedIntegerValue] + prefix.length;
        for (id value in Array(support[@"groundingChunkIndices"])) {
            NSUInteger raw;
            if (!Index(value, chunks.count, &raw)) continue;
            NSDictionary *source = sourceMap[@(raw)];
            if (!source) continue;
            NSString *fingerprint = [NSString stringWithFormat:@"%lu:%lu", (unsigned long)offset, (unsigned long)raw];
            if ([used containsObject:fingerprint]) continue;
            [used addObject:fingerprint];
            [citations addObject:@{@"offset":@(offset), @"number":source[@"number"], @"url":source[@"url"]}];
        }
    }
    [citations sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [b[@"offset"] compare:a[@"offset"]];
        return result == NSOrderedSame ? [b[@"number"] compare:a[@"number"]] : result;
    }];
    NSMutableArray *queries = [NSMutableArray array];
    for (id value in Array(metadata[@"webSearchQueries"])) {
        NSString *query = String(value);
        if (query.length && query.length <= 2048 && queries.count < 20) [queries addObject:query];
    }
    NSString *html = String(Dict(metadata[@"searchEntryPoint"])[@"renderedContent"]);
    if (html.length > 131072) { *failure = @"検索候補の表示データが大きすぎます。"; return nil; }
    BOOL researched = queries.count && citations.count && sources.count && html.length;
    return @{@"text":text, @"sources":sources, @"citations":citations, @"queries":queries,
        @"suggestionsHTML":html ?: @"", @"researched":@(researched),
        @"model":String(root[@"modelVersion"]) ?: @""};
}
