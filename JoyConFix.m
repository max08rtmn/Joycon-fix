#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - Joy-Con R physical dpad-to-face remap

 Logs showed that the separated Joy-Con R is exposed to MeloNX as GCGamepad
 (micro), not as an extended gamepad. In micro/Joy-Con-right style mappings,
 emulators often derive the four face buttons from D-pad directions.

 This build changes only GCPhysicalInputProfile.buttons for Joy-Con R:
   Direction Pad Up    -> Button X
   Direction Pad Right -> Button A
   Direction Pad Down  -> Button B
   Direction Pad Left  -> Button Y
   L/SL aliases        -> Left Shoulder
   R/SR aliases        -> Right Shoulder

 It does not spoof controller identity, force ControllerTypesForID, rotate
 sticks, hook value/isPressed, or change button objects themselves.

 Search the log for:
   [JoyConDpadFace]
*/

static IMP gOrigPhysicalButtons;

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

static BOOL JCFTextLooksLikeRightJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return ([lower containsString:@"joy-con"] || [lower containsString:@"joycon"]) &&
           ([lower containsString:@"(r)"] || [lower containsString:@"right"] || [lower containsString:@" r"]);
}

static BOOL JCFProfileBelongsToRightJoyCon(id profile) {
    for (GCController *controller in [GCController controllers]) {
        id physical = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
        if (physical != profile) {
            continue;
        }

        NSString *combined = [NSString stringWithFormat:@"%@ %@",
                              JCFString(JCFCallId(controller, @selector(vendorName))),
                              JCFString(JCFCallId(controller, @selector(productCategory)))];
        if (JCFTextLooksLikeRightJoyCon(combined)) {
            return YES;
        }
    }

    return NO;
}

static BOOL JCFHasFaceButtons(NSDictionary *buttons) {
    return [buttons objectForKey:@"Button A"] &&
           [buttons objectForKey:@"Button B"] &&
           [buttons objectForKey:@"Button X"] &&
           [buttons objectForKey:@"Button Y"];
}

static void JCFSetAlias(NSMutableDictionary *dict, NSString *alias, NSString *source) {
    id button = [dict objectForKey:source];
    if (button) {
        [dict setObject:button forKey:alias];
    }
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    NSDictionary *original = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;
    if (![original isKindOfClass:NSDictionary.class] ||
        !JCFHasFaceButtons(original) ||
        !JCFProfileBelongsToRightJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *fixed = [original mutableCopy];

    JCFSetAlias(fixed, @"Direction Pad Up", @"Button X");
    JCFSetAlias(fixed, @"Direction Pad Right", @"Button A");
    JCFSetAlias(fixed, @"Direction Pad Down", @"Button B");
    JCFSetAlias(fixed, @"Direction Pad Left", @"Button Y");

    JCFSetAlias(fixed, @"D-Pad Up", @"Button X");
    JCFSetAlias(fixed, @"D-Pad Right", @"Button A");
    JCFSetAlias(fixed, @"D-Pad Down", @"Button B");
    JCFSetAlias(fixed, @"D-Pad Left", @"Button Y");

    JCFSetAlias(fixed, @"Up", @"Button X");
    JCFSetAlias(fixed, @"Right", @"Button A");
    JCFSetAlias(fixed, @"Down", @"Button B");
    JCFSetAlias(fixed, @"Left", @"Button Y");

    JCFSetAlias(fixed, @"A Button", @"Button A");
    JCFSetAlias(fixed, @"B Button", @"Button B");
    JCFSetAlias(fixed, @"X Button", @"Button X");
    JCFSetAlias(fixed, @"Y Button", @"Button Y");

    JCFSetAlias(fixed, @"SL", @"Left Shoulder");
    JCFSetAlias(fixed, @"L", @"Left Shoulder");
    JCFSetAlias(fixed, @"L1", @"Left Shoulder");
    JCFSetAlias(fixed, @"SR", @"Right Shoulder");
    JCFSetAlias(fixed, @"R", @"Right Shoulder");
    JCFSetAlias(fixed, @"R1", @"Right Shoulder");

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConDpadFace] remapped physical Joy-Con R buttons original=%lu fixed=%lu A=%p B=%p X=%p Y=%p up=%p right=%p down=%p left=%p",
              (unsigned long)original.count,
              (unsigned long)fixed.count,
              [fixed objectForKey:@"Button A"],
              [fixed objectForKey:@"Button B"],
              [fixed objectForKey:@"Button X"],
              [fixed objectForKey:@"Button Y"],
              [fixed objectForKey:@"Direction Pad Up"],
              [fixed objectForKey:@"Direction Pad Right"],
              [fixed objectForKey:@"Direction Pad Down"],
              [fixed objectForKey:@"Direction Pad Left"]);
    }

    return fixed;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConDpadFace] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConDpadFace] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        NSLog(@"[JoyConDpadFace] LOAD MARKER 2026-06-28-right-joycon-dpad-face");
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);

        NSLog(@"[JoyConDpadFace] ready");
    }
}
