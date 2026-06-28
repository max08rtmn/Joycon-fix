#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - runtime-class extended gamepad redirect

 The physicalInputProfile exposes the fake Joy-Con buttons correctly, but
 MeloNX still maps them wrong. Earlier getter hooks on GCExtendedGamepad.class
 may miss private runtime subclasses used by GameController.

 This build patches the actual runtime class of each returned extendedGamepad
 object. Its buttonA/B/X/Y and shoulder getters return the already-correct
 physicalInputProfile buttons.

 It does not spoof controller identity, force MeloNX controller type, rotate
 sticks, poll values, or change button values.

 Search the log for:
   [JoyConRuntime]
*/

static IMP gOrigControllerExtendedGamepad;
static IMP gOrigControllerMicroGamepad;

static IMP gOrigExtButtonA;
static IMP gOrigExtButtonB;
static IMP gOrigExtButtonX;
static IMP gOrigExtButtonY;
static IMP gOrigExtLeftShoulder;
static IMP gOrigExtRightShoulder;

static IMP gOrigMicroButtonA;
static IMP gOrigMicroButtonX;

static NSMutableSet *gPatchedClasses;

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

static BOOL JCFTextLooksLikeJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"joy-con"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"nintendo"] ||
           [lower containsString:@"wireless gamepad"];
}

static BOOL JCFLooksLikeJoyConController(GCController *controller) {
    if (!controller) {
        return NO;
    }

    NSString *combined = [NSString stringWithFormat:@"%@ %@",
                          JCFString(JCFCallId(controller, @selector(vendorName))),
                          JCFString(JCFCallId(controller, @selector(productCategory)))];
    return JCFTextLooksLikeJoyCon(combined);
}

static id JCFOriginalControllerExtended(GCController *controller) {
    return gOrigControllerExtendedGamepad ? ((id (*)(id, SEL))gOrigControllerExtendedGamepad)(controller, @selector(extendedGamepad)) : nil;
}

static id JCFOriginalControllerMicro(GCController *controller) {
    return gOrigControllerMicroGamepad ? ((id (*)(id, SEL))gOrigControllerMicroGamepad)(controller, @selector(microGamepad)) : nil;
}

static GCController *JCFControllerForProfile(id profile) {
    if (!profile) {
        return nil;
    }

    for (GCController *controller in [GCController controllers]) {
        if (JCFOriginalControllerExtended(controller) == profile ||
            JCFOriginalControllerMicro(controller) == profile ||
            JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile")) == profile) {
            return controller;
        }
    }

    return nil;
}

static NSDictionary *JCFPhysicalButtonsForProfile(id profile) {
    GCController *controller = JCFControllerForProfile(profile);
    if (!JCFLooksLikeJoyConController(controller)) {
        return nil;
    }

    id physical = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(physical, NSSelectorFromString(@"buttons"));
    if (![buttons isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    return (NSDictionary *)buttons;
}

static id JCFPhysicalButton(id profile, NSString *key) {
    NSDictionary *buttons = JCFPhysicalButtonsForProfile(profile);
    id button = [buttons objectForKey:key];
    if (button) {
        return button;
    }

    NSDictionary *fallbacks = @{
        @"Button A": @[@"A Button", @"A", @"buttonA", @"GCInputButtonA"],
        @"Button B": @[@"B Button", @"B", @"buttonB", @"GCInputButtonB"],
        @"Button X": @[@"X Button", @"X", @"buttonX", @"GCInputButtonX"],
        @"Button Y": @[@"Y Button", @"Y", @"buttonY", @"GCInputButtonY"],
        @"Left Shoulder": @[@"L1 Button", @"L1", @"L", @"SL", @"leftShoulder", @"GCInputLeftShoulder"],
        @"Right Shoulder": @[@"R1 Button", @"R1", @"R", @"SR", @"rightShoulder", @"GCInputRightShoulder"]
    };

    for (NSString *alias in [fallbacks objectForKey:key]) {
        button = [buttons objectForKey:alias];
        if (button) {
            return button;
        }
    }

    return nil;
}

static id JCFOriginalButton(id self, SEL _cmd, IMP original) {
    return original ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
}

static id JCFFixedButton(id self, SEL _cmd, IMP original, NSString *key) {
    id button = JCFPhysicalButton(self, key);
    if (button) {
        return button;
    }
    return JCFOriginalButton(self, _cmd, original);
}

static id JCFExtButtonA(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonA, @"Button A"); }
static id JCFExtButtonB(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonB, @"Button B"); }
static id JCFExtButtonX(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonX, @"Button X"); }
static id JCFExtButtonY(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtButtonY, @"Button Y"); }
static id JCFExtLeftShoulder(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtLeftShoulder, @"Left Shoulder"); }
static id JCFExtRightShoulder(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigExtRightShoulder, @"Right Shoulder"); }

static id JCFMicroButtonA(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigMicroButtonA, @"Button A"); }
static id JCFMicroButtonX(id self, SEL _cmd) { return JCFFixedButton(self, _cmd, gOrigMicroButtonX, @"Button X"); }

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConRuntime] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }

    if (originalOut && !*originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConRuntime] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFPatchProfileClass(id profile, BOOL micro) {
    if (!profile) {
        return;
    }

    Class cls = object_getClass(profile);
    NSString *className = NSStringFromClass(cls);

    @synchronized(gPatchedClasses) {
        if ([gPatchedClasses containsObject:className]) {
            return;
        }
        [gPatchedClasses addObject:className];
    }

    if (micro) {
        JCFSwizzle(cls, @selector(buttonA), (IMP)JCFMicroButtonA, &gOrigMicroButtonA);
        JCFSwizzle(cls, @selector(buttonX), (IMP)JCFMicroButtonX, &gOrigMicroButtonX);
    } else {
        JCFSwizzle(cls, @selector(buttonA), (IMP)JCFExtButtonA, &gOrigExtButtonA);
        JCFSwizzle(cls, @selector(buttonB), (IMP)JCFExtButtonB, &gOrigExtButtonB);
        JCFSwizzle(cls, @selector(buttonX), (IMP)JCFExtButtonX, &gOrigExtButtonX);
        JCFSwizzle(cls, @selector(buttonY), (IMP)JCFExtButtonY, &gOrigExtButtonY);
        JCFSwizzle(cls, @selector(leftShoulder), (IMP)JCFExtLeftShoulder, &gOrigExtLeftShoulder);
        JCFSwizzle(cls, @selector(rightShoulder), (IMP)JCFExtRightShoulder, &gOrigExtRightShoulder);
    }
}

static void JCFLogProfileMap(GCController *controller, id profile, BOOL micro) {
    if (!profile || !JCFLooksLikeJoyConController(controller)) {
        return;
    }

    NSDictionary *buttons = JCFPhysicalButtonsForProfile(profile);
    NSLog(@"[JoyConRuntime] controller=%@ category=%@ profileClass=%@ micro=%@ physicalKeys=%@",
          controller.vendorName,
          controller.productCategory,
          NSStringFromClass(object_getClass(profile)),
          micro ? @"YES" : @"NO",
          [[buttons allKeys] componentsJoinedByString:@", "]);

    if (!micro) {
        NSLog(@"[JoyConRuntime] original ext ptrs A=%p B=%p X=%p Y=%p L=%p R=%p physical A=%p B=%p X=%p Y=%p L=%p R=%p",
              JCFOriginalButton(profile, @selector(buttonA), gOrigExtButtonA),
              JCFOriginalButton(profile, @selector(buttonB), gOrigExtButtonB),
              JCFOriginalButton(profile, @selector(buttonX), gOrigExtButtonX),
              JCFOriginalButton(profile, @selector(buttonY), gOrigExtButtonY),
              JCFOriginalButton(profile, @selector(leftShoulder), gOrigExtLeftShoulder),
              JCFOriginalButton(profile, @selector(rightShoulder), gOrigExtRightShoulder),
              JCFPhysicalButton(profile, @"Button A"),
              JCFPhysicalButton(profile, @"Button B"),
              JCFPhysicalButton(profile, @"Button X"),
              JCFPhysicalButton(profile, @"Button Y"),
              JCFPhysicalButton(profile, @"Left Shoulder"),
              JCFPhysicalButton(profile, @"Right Shoulder"));
    }
}

static id JCFControllerExtendedGamepad(id self, SEL _cmd) {
    id profile = JCFOriginalControllerExtended(self);
    JCFPatchProfileClass(profile, NO);
    JCFLogProfileMap(self, profile, NO);
    return profile;
}

static id JCFControllerMicroGamepad(id self, SEL _cmd) {
    id profile = JCFOriginalControllerMicro(self);
    JCFPatchProfileClass(profile, YES);
    JCFLogProfileMap(self, profile, YES);
    return profile;
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        NSLog(@"[JoyConRuntime] LOAD MARKER 2026-06-28-runtime-class-redirect");
        gPatchedClasses = [NSMutableSet set];

        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        JCFSwizzle(GCController.class, @selector(extendedGamepad), (IMP)JCFControllerExtendedGamepad, &gOrigControllerExtendedGamepad);
        JCFSwizzle(GCController.class, @selector(microGamepad), (IMP)JCFControllerMicroGamepad, &gOrigControllerMicroGamepad);

        for (GCController *controller in [GCController controllers]) {
            (void)JCFControllerExtendedGamepad(controller, @selector(extendedGamepad));
            (void)JCFControllerMicroGamepad(controller, @selector(microGamepad));
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
            GCController *controller = notification.object;
            (void)JCFControllerExtendedGamepad(controller, @selector(extendedGamepad));
            (void)JCFControllerMicroGamepad(controller, @selector(microGamepad));
        }];

        NSLog(@"[JoyConRuntime] ready");
    }
}
