#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - disable MeloNX controller correction

 Diagnostics proved that MeloNX reads Button A/B/X/Y and Left/Right Shoulder
 as separate GameController values. If the game still receives wrong buttons,
 the broken step is MeloNX/Ryujinx's controller correction/mapping layer.

 This build:
 - keeps the working ProController spoof
 - forces ControllerTypesForID to ProController
 - disables likely "correct controller" settings read via NSUserDefaults
 - does not touch button value/isPressed
 - does not rotate sticks
 - does not use object_setClass
*/

static IMP gOrigVendorName;
static IMP gOrigProductCategory;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigDefaultsBoolForKey;

static NSData *JCFForcedControllerTypesData(void) {
    static NSData *data;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *json = @"{\"0\":\"ProController\",\"1\":\"ProController\",\"2\":\"ProController\",\"3\":\"ProController\"}";
        data = [json dataUsingEncoding:NSUTF8StringEncoding];
    });
    return data;
}

static NSString *JCFForcedControllerTypesString(void) {
    static NSString *string;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        string = [[NSString alloc] initWithData:JCFForcedControllerTypesData() encoding:NSUTF8StringEncoding];
    });
    return string;
}

static id JCFOriginalGetter(id object, SEL selector, IMP original) {
    if (original) {
        return ((id (*)(id, SEL))original)(object, selector);
    }
    if (object && selector && [object respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    }
    return nil;
}

static NSString *JCFString(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return value ? [value description] : @"";
}

static BOOL JCFTextLooksLikeJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"joy-con"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"nintendo"] ||
           [lower containsString:@"wireless gamepad"];
}

static BOOL JCFLooksLikeJoyConController(id controller) {
    if (!controller) {
        return NO;
    }
    NSString *vendorName = JCFString(JCFOriginalGetter(controller, @selector(vendorName), gOrigVendorName));
    NSString *productCategory = JCFString(JCFOriginalGetter(controller, @selector(productCategory), gOrigProductCategory));
    return JCFTextLooksLikeJoyCon([NSString stringWithFormat:@"%@ %@", vendorName, productCategory]);
}

static id JCFVendorName(id self, SEL _cmd) {
    id original = JCFOriginalGetter(self, _cmd, gOrigVendorName);
    if (JCFTextLooksLikeJoyCon(JCFString(original))) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static id JCFProductCategory(id self, SEL _cmd) {
    id original = JCFOriginalGetter(self, _cmd, gOrigProductCategory);
    if (JCFTextLooksLikeJoyCon(JCFString(original)) || JCFLooksLikeJoyConController(self)) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static BOOL JCFIsControllerTypesKey(id key) {
    return [key isKindOfClass:NSString.class] && [(NSString *)key isEqualToString:@"ControllerTypesForID"];
}

static BOOL JCFIsCorrectControllerKey(id key) {
    if (![key isKindOfClass:NSString.class]) {
        return NO;
    }

    NSString *lower = [(NSString *)key lowercaseString];
    NSString *compact = [[lower stringByReplacingOccurrencesOfString:@"-" withString:@""]
                         stringByReplacingOccurrencesOfString:@"_" withString:@""];

    return ([compact containsString:@"correct"] && [compact containsString:@"controller"]) ||
           [lower isEqualToString:@"correct-controller"] ||
           [lower isEqualToString:@"correct_controller"] ||
           [lower isEqualToString:@"correctcontroller"];
}

static id JCFDefaultsObjectForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesData();
    }
    if (JCFIsCorrectControllerKey(key)) {
        return @NO;
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsDataForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesData();
    }
    return gOrigDefaultsDataForKey ? ((id (*)(id, SEL, id))gOrigDefaultsDataForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesString();
    }
    if (JCFIsCorrectControllerKey(key)) {
        return @"false";
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static BOOL JCFDefaultsBoolForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConFix] disabled correct-controller key %@", key);
        return NO;
    }
    return gOrigDefaultsBoolForKey ? ((BOOL (*)(id, SEL, id))gOrigDefaultsBoolForKey)(self, _cmd, key) : NO;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        JCFSwizzle(GCController.class, @selector(vendorName), (IMP)JCFVendorName, &gOrigVendorName);
        JCFSwizzle(GCController.class, @selector(productCategory), (IMP)JCFProductCategory, &gOrigProductCategory);
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(dataForKey:), (IMP)JCFDefaultsDataForKey, &gOrigDefaultsDataForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(boolForKey:), (IMP)JCFDefaultsBoolForKey, &gOrigDefaultsBoolForKey);

        NSLog(@"[JoyConFix] no-correct ProController fix loaded");
    }
}
