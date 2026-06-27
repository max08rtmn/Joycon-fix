#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m

 Fix idea:
 Fake separated Joy-Cons can expose correct buttons in physicalInputProfile,
 while the simplified extended/micro gamepad mapping is wrong in MeloNX.

 This tweak redirects the standard GameController button getters to the
 physical buttons iOS already sees:

   Button A/B/X/Y -> extended.buttonA/B/X/Y
   Left/Right Shoulder -> extended.left/rightShoulder

 It does not rotate sticks, install event handlers, or alter raw HID reports.
*/

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

static BOOL JCFLooksLikeJoyConController(id controller) {
    if (!controller) {
        return NO;
    }

    NSString *vendorName = JCFString(JCFCallId(controller, @selector(vendorName)));
    NSString *productCategory = JCFString(JCFCallId(controller, @selector(productCategory)));
    NSString *combined = [[NSString stringWithFormat:@"%@ %@", vendorName, productCategory] lowercaseString];

    return [combined containsString:@"joy-con"] ||
           [combined containsString:@"joycon"] ||
           [combined containsString:@"wireless gamepad"] ||
           [combined containsString:@"nintendo"];
}

static id JCFControllerForProfile(id profile) {
    id controller = JCFCallId(profile, @selector(controller));
    if (controller) {
        return controller;
    }

    id device = JCFCallId(profile, NSSelectorFromString(@"device"));
    if (device) {
        return device;
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
        NSString *shortName = [key substringFromIndex:[@"Button " length]];
        button = buttons[shortName];
    }

    return button;
}

static id JCFOriginalButton(id self, SEL _cmd, IMP original) {
    if (!original) {
        return nil;
    }
    return ((id (*)(id, SEL))original)(self, _cmd);
}

static id JCFFixedButton(id self, SEL _cmd, IMP original, NSString *physicalKey) {
    id physicalButton = JCFPhysicalButton(self, physicalKey);
    if (physicalButton) {
        return physicalButton;
    }
    return JCFOriginalButton(self, _cmd, original);
}

static id JCFExtButtonA(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtButtonA, @"Button A");
}

static id JCFExtButtonB(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtButtonB, @"Button B");
}

static id JCFExtButtonX(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtButtonX, @"Button X");
}

static id JCFExtButtonY(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtButtonY, @"Button Y");
}

static id JCFExtLeftShoulder(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtLeftShoulder, @"Left Shoulder");
}

static id JCFExtRightShoulder(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigExtRightShoulder, @"Right Shoulder");
}

static id JCFExtLeftTrigger(id self, SEL _cmd) {
    id physicalButton = JCFPhysicalButton(self, @"Left Trigger");
    if (physicalButton) {
        return physicalButton;
    }
    return JCFOriginalButton(self, _cmd, gOrigExtLeftTrigger);
}

static id JCFExtRightTrigger(id self, SEL _cmd) {
    id physicalButton = JCFPhysicalButton(self, @"Right Trigger");
    if (physicalButton) {
        return physicalButton;
    }
    return JCFOriginalButton(self, _cmd, gOrigExtRightTrigger);
}

static id JCFMicroButtonA(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigMicroButtonA, @"Button A");
}

static id JCFMicroButtonX(id self, SEL _cmd) {
    return JCFFixedButton(self, _cmd, gOrigMicroButtonX, @"Button X");
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

        NSLog(@"[JoyConFix] physical button redirect loaded");
    }
}
