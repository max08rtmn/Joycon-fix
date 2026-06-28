#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - physical button alias fix for MeloNX / LiveContainer

 The last log showed that MeloNX reads controller.physicalInputProfile.buttons.
 On the fake separated Joy-Con, the dictionary keys are "Button A", "Button B",
 etc., while the button objects are named "A Button", "B Button", "L1 Button",
 and "R1 Button".

 If MeloNX looks up physical buttons by the object-style names, it can miss
 B/X/Y/L/R and fall back to one button. This build returns the original physical
 button dictionary plus safe aliases:
   Button A -> A Button, A, GCInputButtonA, buttonA
   Button B -> B Button, B, GCInputButtonB, buttonB
   Button X -> X Button, X, GCInputButtonX, buttonX
   Button Y -> Y Button, Y, GCInputButtonY, buttonY
   Left Shoulder -> L1 Button, L1, L, SL, GCInputLeftShoulder, leftShoulder
   Right Shoulder -> R1 Button, R1, R, SR, GCInputRightShoulder, rightShoulder

 It does not spoof the controller name, force ControllerTypesForID, rotate
 sticks, or change button values.
*/

static IMP gOrigPhysicalButtons;

static void JCFAddAliases(NSMutableDictionary *dict, id sourceKey, NSArray *aliases) {
    id button = [dict objectForKey:sourceKey];
    if (!button) {
        return;
    }

    for (id alias in aliases) {
        if (![alias isKindOfClass:NSString.class]) {
            continue;
        }
        if (![dict objectForKey:alias]) {
            [dict setObject:button forKey:alias];
        }
    }
}

static BOOL JCFHasJoyConFaceButtons(NSDictionary *dict) {
    return [dict objectForKey:@"Button A"] &&
           [dict objectForKey:@"Button B"] &&
           [dict objectForKey:@"Button X"] &&
           [dict objectForKey:@"Button Y"];
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    NSDictionary *original = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;
    if (![original isKindOfClass:NSDictionary.class] || !JCFHasJoyConFaceButtons(original)) {
        return original;
    }

    NSMutableDictionary *fixed = [original mutableCopy];

    JCFAddAliases(fixed, @"Button A", @[@"A Button", @"A", @"GCInputButtonA", @"buttonA"]);
    JCFAddAliases(fixed, @"Button B", @[@"B Button", @"B", @"GCInputButtonB", @"buttonB"]);
    JCFAddAliases(fixed, @"Button X", @[@"X Button", @"X", @"GCInputButtonX", @"buttonX"]);
    JCFAddAliases(fixed, @"Button Y", @[@"Y Button", @"Y", @"GCInputButtonY", @"buttonY"]);

    JCFAddAliases(fixed, @"Left Shoulder", @[
        @"L1 Button", @"L1", @"L", @"SL", @"Left Bumper",
        @"GCInputLeftShoulder", @"leftShoulder"
    ]);
    JCFAddAliases(fixed, @"Right Shoulder", @[
        @"R1 Button", @"R1", @"R", @"SR", @"Right Bumper",
        @"GCInputRightShoulder", @"rightShoulder"
    ]);

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConFix] physical button aliases installed. original=%lu fixed=%lu",
              (unsigned long)original.count,
              (unsigned long)fixed.count);
    }

    return fixed;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConFix] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
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

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);

        NSLog(@"[JoyConFix] physical alias fix loaded");
    }
}
