#import <Foundation/Foundation.h>
#import "../JPResearch.h"
static void Check(BOOL ok, NSString *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
    printf("PASS: %s\n", label.UTF8String);
}
static NSMutableDictionary *Fixture(void) {
    return [@{@"modelVersion":@"fixture-model", @"candidates":@[
        @{@"finishReason":@"STOP", @"content":@{@"parts":@[
            @{@"text":@"A 猫😀。"}, @{@"text":@"private", @"thought":@YES}, @{@"text":@"後半"}]},
          @"groundingMetadata":@{
              @"webSearchQueries":@[@"test query"],
              @"searchEntryPoint":@{@"renderedContent":@"<div>Search suggestions</div>"},
              @"groundingChunks":@[
                  @{@"web":@{@"title":@"Official", @"uri":@"https://example.com/a"}},
                  @{@"web":@{@"title":@"Bad", @"uri":@"javascript:alert(1)"}},
                  @{@"web":@{@"title":@"Dictionary", @"uri":@"https://example.org/b"}}],
              @"groundingSupports":@[
                  @{@"segment":@{@"startIndex":@2, @"endIndex":@9, @"text":@"猫😀"}, @"groundingChunkIndices":@[@0,@1,@2]},
                  @{@"segment":@{@"partIndex":@2, @"endIndex":@6, @"text":@"後半"}, @"groundingChunkIndices":@[@2]}]
          }}]} mutableCopy];
}
static NSMutableDictionary *Candidate(NSMutableDictionary *root) {
    NSMutableArray *items = [root[@"candidates"] mutableCopy];
    NSMutableDictionary *candidate = [items[0] mutableCopy]; items[0] = candidate; root[@"candidates"] = items; return candidate;
}
static void Metadata(NSMutableDictionary *root, NSString *key, id value) {
    NSMutableDictionary *c = Candidate(root), *m = [c[@"groundingMetadata"] mutableCopy];
    if (value) m[key] = value; else [m removeObjectForKey:key]; c[@"groundingMetadata"] = m;
}
static NSDictionary *Decode(id value, NSInteger status) {
    NSString *failure = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:NULL];
    return JPDecodeResearch(data, status, &failure);
}
int main(void) {
    @autoreleasepool {
        NSDictionary *answer = Decode(Fixture(), 200);
        Check([answer[@"researched"] boolValue], @"complete evidence is researched");
        Check([answer[@"text"] isEqual:@"A 猫😀。後半"], @"thoughts excluded and text parts preserved");
        Check([answer[@"sources"] count] == 2, @"unsafe source URLs excluded");
        Check([answer[@"sources"][1][@"number"] isEqual:@3], @"original chunk indices preserved");
        Check([answer[@"citations"] count] == 3, @"valid citations retained");
        Check([answer[@"citations"][0][@"offset"] isEqual:@8], @"multiple parts use cumulative UTF16 offset");
        Check([answer[@"citations"][1][@"offset"] isEqual:@5], @"UTF8 byte offset maps to UTF16 including emoji");
        Check([answer[@"model"] isEqual:@"fixture-model"], @"actual response model retained");
        NSMutableDictionary *root = Fixture(); [Candidate(root) removeObjectForKey:@"groundingMetadata"];
        Check(![Decode(root, 200)[@"researched"] boolValue], @"missing grounding never claims research");
        root = Fixture(); Metadata(root, @"groundingSupports", @[]);
        Check(![Decode(root, 200)[@"researched"] boolValue], @"source list alone is insufficient");
        root = Fixture(); Metadata(root, @"webSearchQueries", @[]);
        Check(![Decode(root, 200)[@"researched"] boolValue], @"no executed queries is not research");
        root = Fixture(); Metadata(root, @"searchEntryPoint", @{}); 
        Check(![Decode(root, 200)[@"researched"] boolValue], @"missing required suggestions cannot claim research");
        root = Fixture(); Metadata(root, @"groundingSupports", @[
            @{@"segment":@{@"endIndex":@4}, @"groundingChunkIndices":@[@0]}]);
        Check([Decode(root, 200)[@"citations"] count] == 0, @"split Japanese UTF8 boundary rejected");
        root = Fixture(); Metadata(root, @"groundingSupports", @[
            @{@"segment":@{@"endIndex":@9999}, @"groundingChunkIndices":@[@0]}]);
        Check([Decode(root, 200)[@"citations"] count] == 0, @"out of range offset rejected");
        root = Fixture(); Metadata(root, @"groundingSupports", @[
            @{@"segment":@{@"endIndex":@9, @"text":@"wrong"}, @"groundingChunkIndices":@[@0]}]);
        Check([Decode(root, 200)[@"citations"] count] == 0, @"mismatched citation segment rejected");
        root = Fixture(); Metadata(root, @"groundingSupports", @[
            @{@"segment":@{@"partIndex":@1, @"endIndex":@7}, @"groundingChunkIndices":@[@0]}]);
        Check([Decode(root, 200)[@"citations"] count] == 0, @"thought part cannot receive citations");
        root = Fixture(); Metadata(root, @"groundingSupports", @[
            @{@"segment":@{@"endIndex":@9}, @"groundingChunkIndices":@[@YES,@(-1),@0.5,@999,NSNull.null]}]);
        Check([Decode(root, 200)[@"citations"] count] == 0, @"invalid chunk IDs rejected");
        Check(!Decode(Fixture(), 400), @"API errors rejected");
        root = Fixture(); Candidate(root)[@"finishReason"] = @"MAX_TOKENS";
        Check(!Decode(root, 200), @"incomplete result rejected");
        Check(!Decode(@[], 200), @"malformed root rejected");
        root = Fixture(); Candidate(root)[@"content"] = NSNull.null;
        Check(!Decode(root, 200), @"malformed content rejected");
        NSString *failure = nil;
        Check(!JPDecodeResearch([@"invalid" dataUsingEncoding:NSUTF8StringEncoding], 200, &failure), @"invalid JSON rejected");
        Check(!JPResearchURLAllowed([NSURL URLWithString:@"file:///etc/passwd"]), @"local file links rejected");
        Check(!JPResearchURLAllowed([NSURL URLWithString:@"https://user:pass@example.org/"]), @"credential links rejected");
    }
    return 0;
}
