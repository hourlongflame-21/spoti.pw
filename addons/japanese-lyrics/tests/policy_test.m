#import <Foundation/Foundation.h>
#import "../JPPolicy.h"
static void Check(BOOL ok, NSString *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
    printf("PASS: %s\n", label.UTF8String);
}
int main(void) {
    @autoreleasepool {
        Check(JPKeepOriginal(@"君と歩いたこの道を忘れない"), @"Japanese unchanged");
        Check(!JPShouldAutoTranslate(@[@"君と歩いたこの道を忘れない"]), @"Japanese song skipped");
        Check(!JPShouldAutoTranslate(@[@"I will never let you go", @"君と歩いたこの道を忘れない"]), @"mixed Japanese song skipped");
        Check(!JPShouldAutoTranslate(@[@"ｷﾐﾄｲｯｼｮﾆ"]), @"halfwidth kana skipped");
        Check(!JPShouldAutoTranslate(@[@""]), @"empty skipped");
        Check(!JPShouldAutoTranslate(@[@"123 456"]), @"numbers skipped");
        Check(!JPShouldAutoTranslate(@[@"oh"]), @"short ambiguous lyric skipped");
        Check(JPShouldAutoTranslate(@[@"We keep on walking down the road together", @"And I will never let you go"]), @"English eligible");
        Check(JPShouldAutoTranslate(@[@"너와 함께 걸었던 그 길을 잊지 않을 거야"]), @"Korean eligible");
        Check(JPShouldAutoTranslate(@[@"Je ne veux jamais oublier les jours que nous avons passes ensemble"]), @"French eligible");
        NSDictionary *good = @{@"meaning":@"意味", @"slang":@"なし", @"rhyme":@"不明", @"uncertainty":@"作者の意図は未確認"};
        Check(JPValidExplanation(good), @"complete explanation accepted");
        Check(!JPValidExplanation(@[]), @"array rejected");
        Check(!JPValidExplanation(@{@"meaning":@"x"}), @"missing fields rejected");
        NSMutableDictionary *bad = [good mutableCopy]; bad[@"rhyme"] = @3;
        Check(!JPValidExplanation(bad), @"non-text rejected");
        bad[@"rhyme"] = @"";
        Check(!JPValidExplanation(bad), @"empty explanation rejected");
        bad[@"rhyme"] = [@"" stringByPaddingToLength:12001 withString:@"x" startingAtIndex:0];
        Check(!JPValidExplanation(bad), @"oversized explanation rejected");
    }
    return 0;
}
