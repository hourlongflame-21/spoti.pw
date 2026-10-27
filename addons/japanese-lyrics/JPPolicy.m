#import "JPPolicy.h"
#import <NaturalLanguage/NaturalLanguage.h>

static BOOL HasKana(NSString *text) {
    return [text rangeOfString:@"[\\p{Hiragana}\\p{Katakana}]" options:NSRegularExpressionSearch].location != NSNotFound;
}
BOOL JPKeepOriginal(NSString *text) {
    if (HasKana(text)) return YES;
    NLLanguageRecognizer *r = [NLLanguageRecognizer new];
    [r processString:text];
    return [r.dominantLanguage isEqual:NLLanguageJapanese] &&
        [r languageHypothesesWithMaximum:1][NLLanguageJapanese].doubleValue >= 0.70;
}
BOOL JPShouldAutoTranslate(NSArray<NSString *> *texts) {
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
