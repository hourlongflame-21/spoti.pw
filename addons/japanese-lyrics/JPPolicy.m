#import "JPPolicy.h"
#import <NaturalLanguage/NaturalLanguage.h>

static BOOL HasKana(NSString *text) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = [NSRegularExpression regularExpressionWithPattern:@"[\\p{Hiragana}\\p{Katakana}]" options:0 error:NULL]; });
    return [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}
BOOL JPKeepOriginal(NSString *text) {
    if (!text.length) return NO;
    static NSCache *decisions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ decisions = [NSCache new]; decisions.countLimit = 1024; decisions.totalCostLimit = 1024*1024; });
    NSNumber *known = [decisions objectForKey:text];
    if (known) return known.boolValue;
    if (HasKana(text)) { [decisions setObject:@YES forKey:text cost:text.length*2]; return YES; }
    NLLanguageRecognizer *r = [NLLanguageRecognizer new];
    [r processString:text];
    BOOL japanese = [r.dominantLanguage isEqual:NLLanguageJapanese] &&
        [r languageHypothesesWithMaximum:1][NLLanguageJapanese].doubleValue >= 0.70;
    [decisions setObject:@(japanese) forKey:text cost:text.length*2];
    return japanese;
}
BOOL JPShouldAutoTranslate(NSArray<NSString *> *texts) {
    if (texts.count > 400) return NO;
    NSUInteger length = 0;
    for (NSString *text in texts) { length += text.length; if (length > 60000) return NO; }
    NSMutableArray *unique = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *text in texts) {
        if (JPKeepOriginal(text)) return NO; // Conservative: mixed Japanese/English also stays untouched.
        if (![seen containsObject:text] && text.length) { [unique addObject:text]; [seen addObject:text]; }
    }
    NSString *sample = [unique componentsJoinedByString:@"\n"];
    NSUInteger letters = 0;
    NSCharacterSet *alphabet = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < sample.length; i++) if ([alphabet characterIsMember:[sample characterAtIndex:i]]) letters++;
    if (letters < 8 || sample.length > 60000) return NO;
    NLLanguageRecognizer *r = [NLLanguageRecognizer new];
    [r processString:sample];
    NSString *language = r.dominantLanguage;
    if (!language.length || [language isEqual:NLLanguageJapanese] || [language isEqual:NLLanguageUndetermined]) return NO;
    return [r languageHypothesesWithMaximum:1][language].doubleValue >= 0.70;
}
BOOL JPValidExplanation(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"meaning", @"slang", @"rhyme", @"uncertainty"]) {
        id text = value[key];
        if (![text isKindOfClass:NSString.class] || ![text length] || [text length] > 12000) return NO;
    }
    return YES;
}
