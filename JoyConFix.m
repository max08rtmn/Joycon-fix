#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>

/*
 JoyConFix.m - ProController spoof build

 Previous builds proved that iOS sees the physical fake Joy-Con buttons, but
 MeloNX still routes the separated Joy-Con through JoyconRight handling.

 This build does three things:
 1. Makes separated Joy-Cons look like a generic extended controller.
 2. Forces MeloNX's ControllerTypesForID preference to ProController at runtime.
 3. Redirects standard extended buttons to physicalInputProfile buttons when
    the app still asks the GameController API directly.

 No stick rotation, no raw HID changes, no button event handlers.
*/

static IMP gOrigVendorName;
static IMP gOrigProductCategory;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigExtButtonA;
static IMP gOrigExtButtonB;
static IMP gOrigExtButtonX;
static IMP gOrigExtButtonY;
static IMP gOrigExtLeftShoulder;
static IMP gOrigExtRightShoulder;
static IMP gOrigExtLeftTrigger;
static IMP gOrigExtRightTrigger;
static IMP gOrigMicroButtonA;
static IMP gOrigMicroButtonX;

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

static id JCFCallId(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *JCFString(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return value ? [value description] : @"";
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
    id original = gOrigVendorName ? ((id (*)(id, SEL))gOrigVendorName)(self, _cmd) : nil;
    if (JCFTextLooksLikeJoyCon(JCFString(original))) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static id JCFProductCategory(id self, SEL _cmd) {
    id original = gOrigProductCategory ? ((id (*)(id, SEL))gOrigProductCategory)(self, _cmd) : nil;
    if (JCFTextLooksLikeJoyCon(JCFString(original)) || JCFLooksLikeJoyConController(self)) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static BOOL JCFIsControllerTypesKey(id key) {
    return [key isKindOfClass:NSString.class] && [(NSString *)key isEqualToString:@"ControllerTypesForID"];
}

static id JCFDefaultsObjectForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesData();
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
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static id JCFControllerForProfile(id profile) {
    id controller = JCFCallId(profile, @selector(controller));
    if (controller) {
        return controller;
    }

    for (GCController *candidate in [GCController controllers]) {
        if ((id)candidate.extendedGamepad == profile ||
            (id)candidate.microGamepad == profile ||
            JCFCallId(candidate, NSSelectorFromString(@"physicalInputProfile")) == profile) {
            return candidate;
        }
    }

    return nil;
}

static NSDictionary *JCFPhysicalButtonsForProfile(id profile) {
    id controller = JCFControllerForProfile(profile);
    if (!JCFLooksLikeJoyConController(controller)) {
        return nil;
    }

    id physicalInputProfile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(physicalInputProfile, NSSelectorFromString(@"buttons"));
    if (![buttons isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    return (NSDictionary *)buttons;
}

static id JCFPhysicalButton(id profile, NSString *key) {
    NSDictionary *buttons = JCFPhysicalButtonsForProfile(profile);
    id button = buttons[key];
    if (!button && [key hasPrefix:@"Button "]) {
        button = buttons[[key substringFromIndex:[@"Button " length]]];
    }
    return button;
}

static id JCFOriginalButton(id self, SEL _cmd, IMP original) {
    return original ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
}

static id JCFFixedButton(id self, SEL _cmd, IMP original, NSString *physicalKey) {
    id physicalButton = JCFPhysicalButton(self, physicalKey);
    return physicalButton ?: JCFOriginalButton(self, _cmd, original);
}

static id JCFExtButtonA(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonA, @"Button A"); }
static id JCFExtButtonB(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonB, @"Button B"); }
static id JCFExtButtonX(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonX, @"Button X"); }
static id JCFExtButtonY(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonY, @"Button Y"); }
static id JCFExtLeftShoulder(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtLeftShoulder, @"Left Shoulder"); }
static id JCFExtRightShoulder(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtRightShoulder, @"Right Shoulder"); }
static id JCFExtLeftTrigger(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtLeftTrigger, @"Left Trigger"); }
static id JCFExtRightTrigger(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtRightTrigger, @"Right Trigger"); }
static id JCFMicroButtonA(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigMicroButtonA, @"Button A"); }
static id JCFMicroButtonX(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigMicroButtonX, @"Button X"); }

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

        JCFSwizzle(GCExtendedGamepad.class, @selector(buttonA), (IMP)JCFExtButtonA, &gOrigExtButtonA);
        JCFSwizzle(GCExtendedGamepad.class, @selector(buttonB), (IMP)JCFExtButtonB, &gOrigExtButtonB);
        JCFSwizzle(GCExtendedGamepad.class, @selector(buttonX), (IMP)JCFExtButtonX, &gOrigExtButtonX);
        JCFSwizzle(GCExtendedGamepad.class, @selector(buttonY), (IMP)JCFExtButtonY, &gOrigExtButtonY);
        JCFSwizzle(GCExtendedGamepad.class, @selector(leftShoulder), (IMP)JCFExtLeftShoulder, &gOrigExtLeftShoulder);
        JCFSwizzle(GCExtendedGamepad.class, @selector(rightShoulder), (IMP)JCFExtRightShoulder, &gOrigExtRightShoulder);
        JCFSwizzle(GCExtendedGamepad.class, @selector(leftTrigger), (IMP)JCFExtLeftTrigger, &gOrigExtLeftTrigger);
        JCFSwizzle(GCExtendedGamepad.class, @selector(rightTrigger), (IMP)JCFExtRightTrigger, &gOrigExtRightTrigger);

        JCFSwizzle(GCMicroGamepad.class, @selector(buttonA), (IMP)JCFMicroButtonA, &gOrigMicroButtonA);
        JCFSwizzle(GCMicroGamepad.class, @selector(buttonX), (IMP)JCFMicroButtonX, &gOrigMicroButtonX);

        NSLog(@"[JoyConFix] pro controller spoof loaded");
    }
}
