// Independent adapters around the supplied v0.23.0-beta core. No upstream implementation copied.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "JPCoreWork.h"
static char imageKey, ownerKey;
static JPCoreWork *paletteWork, *tintWork;
static void (*originalMotion)(id, SEL);
static void (*originalDraw)(id, SEL, CFTimeInterval);
static BOOL (*increaseContrast)(void);
static Ivar warpIvar;
typedef struct { BOOL dissolve; } JPImageRequest;
static void (*originalPalette)(id, SEL, UIImage *, JPImageRequest, void (^)(id));
static void (*originalTint)(id, SEL, UIImage *, UIColor *, void (^)(UIColor *));
@interface JPCoreOwner : NSObject
@property (nonatomic, weak) UIView *view;
@end
@implementation JPCoreOwner
@end
static NSString *ImageIdentity(UIImage *image) {
    NSString *identity = objc_getAssociatedObject(image, &imageKey);
    if (!identity) {
        identity = NSUUID.UUID.UUIDString;
        objc_setAssociatedObject(image, &imageKey, identity, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return identity;
}
static void Palette(id cls, SEL selector, UIImage *image, JPImageRequest request, void (^completion)(id)) {
    if (!NSThread.isMainThread || !completion || !image.CGImage) { originalPalette(cls, selector, image, request, completion); return; }
    BOOL contrast = increaseContrast ? increaseContrast() : UIAccessibilityDarkerSystemColorsEnabled();
    NSString *key = [NSString stringWithFormat:@"%@:%d:%d", ImageIdentity(image), request.dissolve, contrast];
    [paletteWork request:key start:^(void (^finish)(id)) {
        originalPalette(cls, selector, image, request, finish);
    } completion:completion];
}
static void Tint(id cls, SEL selector, UIImage *image, UIColor *surface, void (^completion)(UIColor *)) {
    CGFloat r=0, g=0, b=0, a=0;
    if (!NSThread.isMainThread || !completion || !image.CGImage || ![surface getRed:&r green:&g blue:&b alpha:&a]) {
        originalTint(cls, selector, image, surface, completion); return;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%.17g:%.17g:%.17g:%.17g", ImageIdentity(image), (double)r, (double)g, (double)b, (double)a];
    [tintWork request:key start:^(void (^finish)(id)) {
        originalTint(cls, selector, image, surface, ^(UIColor *color) { finish(color); });
    } completion:^(id result) { completion(result); }];
}
static void Motion(id obj, SEL selector) {
    id warp = object_getIvar(obj, warpIvar);
    if (warp) {
        JPCoreOwner *owner = objc_getAssociatedObject(warp, &ownerKey);
        if (!owner) {
            owner = [JPCoreOwner new];
            objc_setAssociatedObject(warp, &ownerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        owner.view = obj;
    }
    originalMotion(obj, selector);
}
static void Draw(id obj, SEL selector, CFTimeInterval now) {
    UIView *owner = [(JPCoreOwner *)objc_getAssociatedObject(obj, &ownerKey) view];
    if (owner) {
        if (!owner.window) return;
        for (UIView *view = owner; view; view = view.superview) {
            CALayer *presentation = view.layer.presentationLayer;
            if (JPCoreLayerInvisible(view.hidden, view.alpha, presentation != nil, presentation.opacity)) return;
        }
    }
    // Keep the original display link running: a hidden ancestor can reappear without a window event.
    // The next tick therefore resumes normally; frame-rate ranges and visible rendering are untouched.
    originalDraw(obj, selector, now);
}
static BOOL Returns(Method method, char kind, unsigned int arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char type[64] = {0}; method_getReturnType(method, type, sizeof type);
    return type[0] == kind;
}
__attribute__((constructor)) static void InstallCorePerformance(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class palette = NSClassFromString(@"SGRPalette");
        Method p = class_getClassMethod(palette, NSSelectorFromString(@"paletteForImage:request:completion:"));
        Method t = class_getClassMethod(palette, NSSelectorFromString(@"tintForImage:surface:completion:"));
        char argument[256] = {0};
        if (p) method_getArgumentType(p, 3, argument, sizeof argument);
        NSUInteger size = 0, alignment = 0;
        if (argument[0] == '{') NSGetSizeAndAlignment(argument, &size, &alignment);
        if (Returns(p, 'v', 5) && Returns(t, 'v', 5) && size == sizeof(JPImageRequest) && strchr(argument, 'B')) {
            paletteWork = [JPCoreWork new]; tintWork = [JPCoreWork new];
            increaseContrast = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "SGRIncreaseContrast");
            originalPalette = (void (*)(id, SEL, UIImage *, JPImageRequest, void (^)(id)))method_setImplementation(p, (IMP)Palette);
            originalTint = (void (*)(id, SEL, UIImage *, UIColor *, void (^)(UIColor *)))method_setImplementation(t, (IMP)Tint);
        }
        Class field = NSClassFromString(@"SGRArtworkField"), warp = NSClassFromString(@"SGRWarpLayer");
        Method motion = class_getInstanceMethod(field, NSSelectorFromString(@"updateMotion"));
        Method draw = class_getInstanceMethod(warp, NSSelectorFromString(@"drawAt:"));
        warpIvar = class_getInstanceVariable(field, "_warp");
        char timeArgument[32] = {0}; if (draw) method_getArgumentType(draw, 2, timeArgument, sizeof timeArgument);
        if (warpIvar && Returns(motion, 'v', 2) && Returns(draw, 'v', 3) && timeArgument[0] == 'd') {
            originalMotion = (void (*)(id, SEL))method_setImplementation(motion, (IMP)Motion);
            originalDraw = (void (*)(id, SEL, CFTimeInterval))method_setImplementation(draw, (IMP)Draw);
        }
    });
}
