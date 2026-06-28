#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>

/*
 JoyConFix.m - handler mapping probe

 The previous fixes proved that:
 - physical buttons exist separately
 - names/aliases can be normalized
 - MeloNX still does not react

 This build does not change input behavior. It logs where MeloNX attaches input
 event handlers and whether it later reads button values.

 Search the MeloNX log for:
   [JoyConHandler]
*/

static char kJCFButtonLabelKey;
static char kJCFLastValueKey;
static char kJCFLastPressedKey;

static IMP gOrigPhysicalButtons;
static IMP gOrigButtonValue;
static IMP gOrigButtonPressed;
static IMP gOrigSetButtonValueChangedHandler;
static IMP gOrigSetButtonPressedChangedHandler;
static IMP gOrigSetProfileValueChangedHandler;
static IMP gOrigLocalizedName;
static IMP gOrigUnmappedLocalizedName;
static IMP gOrigName;
static IMP gOrigAliases;

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

static NSString *JCFLabelForButton(id button) {
    NSString *label = objc_getAssociatedObject(button, &kJCFButtonLabelKey);
    if (label.length > 0) {
        return label;
    }

    NSString *unmapped = JCFString(JCFCallId(button, NSSelectorFromString(@"unmappedLocalizedName")));
    NSString *localized = JCFString(JCFCallId(button, NSSelectorFromString(@"localizedName")));
    NSString *name = JCFString(JCFCallId(button, NSSelectorFromString(@"name")));

    if (unmapped.length > 0) {
        return unmapped;
    }
    if (localized.length > 0) {
        return localized;
    }
    if (name.length > 0) {
        return name;
    }
    return [NSString stringWithFormat:@"unlabeled.%@", NSStringFromClass([button class])];
}

static void JCFSetButtonLabel(id button, NSString *label) {
    if (!button || label.length == 0) {
        return;
    }

    NSString *oldLabel = objc_getAssociatedObject(button, &kJCFButtonLabelKey);
    if (![oldLabel isEqualToString:label]) {
        objc_setAssociatedObject(button, &kJCFButtonLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSLog(@"[JoyConHandler] label %@ -> %p", label, button);
    }
}

static BOOL JCFHasJoyConFaceButtons(NSDictionary *dict) {
    return [dict objectForKey:@"Button A"] &&
           [dict objectForKey:@"Button B"] &&
           [dict objectForKey:@"Button X"] &&
           [dict objectForKey:@"Button Y"];
}

static NSSet *JCFAliasesForLabel(NSString *label) {
    if ([label isEqualToString:@"Button A"]) return [NSSet setWithObjects:@"Button A", @"A Button", @"A", @"GCInputButtonA", @"buttonA", nil];
    if ([label isEqualToString:@"Button B"]) return [NSSet setWithObjects:@"Button B", @"B Button", @"B", @"GCInputButtonB", @"buttonB", nil];
    if ([label isEqualToString:@"Button X"]) return [NSSet setWithObjects:@"Button X", @"X Button", @"X", @"GCInputButtonX", @"buttonX", nil];
    if ([label isEqualToString:@"Button Y"]) return [NSSet setWithObjects:@"Button Y", @"Y Button", @"Y", @"GCInputButtonY", @"buttonY", nil];
    if ([label isEqualToString:@"Left Shoulder"]) return [NSSet setWithObjects:@"Left Shoulder", @"L1 Button", @"L1", @"L", @"SL", @"GCInputLeftShoulder", @"leftShoulder", nil];
    if ([label isEqualToString:@"Right Shoulder"]) return [NSSet setWithObjects:@"Right Shoulder", @"R1 Button", @"R1", @"R", @"SR", @"GCInputRightShoulder", @"rightShoulder", nil];
    return nil;
}

static void JCFAddAliases(NSMutableDictionary *dict, NSString *sourceKey, NSArray *aliases) {
    id button = [dict objectForKey:sourceKey];
    if (!button) {
        return;
    }

    JCFSetButtonLabel(button, sourceKey);

    for (NSString *alias in aliases) {
        if ([alias isKindOfClass:NSString.class] && ![dict objectForKey:alias]) {
            [dict setObject:button forKey:alias];
        }
    }
}

static id JCFOriginalGetter(id self, SEL _cmd, IMP original) {
    return original ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
}

static id JCFButtonLocalizedName(id self, SEL _cmd) {
    NSString *label = objc_getAssociatedObject(self, &kJCFButtonLabelKey);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigLocalizedName);
}

static id JCFButtonUnmappedLocalizedName(id self, SEL _cmd) {
    NSString *label = objc_getAssociatedObject(self, &kJCFButtonLabelKey);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigUnmappedLocalizedName);
}

static id JCFButtonName(id self, SEL _cmd) {
    NSString *label = objc_getAssociatedObject(self, &kJCFButtonLabelKey);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigName);
}

static id JCFButtonAliases(id self, SEL _cmd) {
    NSString *label = objc_getAssociatedObject(self, &kJCFButtonLabelKey);
    NSSet *aliases = label ? JCFAliasesForLabel(label) : nil;
    return aliases ?: JCFOriginalGetter(self, _cmd, gOrigAliases);
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
    JCFAddAliases(fixed, @"Left Shoulder", @[@"L1 Button", @"L1", @"L", @"SL", @"GCInputLeftShoulder", @"leftShoulder"]);
    JCFAddAliases(fixed, @"Right Shoulder", @[@"R1 Button", @"R1", @"R", @"SR", @"GCInputRightShoulder", @"rightShoulder"]);

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConHandler] physical buttons normalized original=%lu fixed=%lu",
              (unsigned long)original.count,
              (unsigned long)fixed.count);
    }

    return fixed;
}

static void JCFLogRead(id button, NSString *kind, float value, BOOL pressed, BOOL pressedKnown) {
    NSNumber *lastValueNumber = objc_getAssociatedObject(button, &kJCFLastValueKey);
    NSNumber *lastPressedNumber = objc_getAssociatedObject(button, &kJCFLastPressedKey);
    float lastValue = lastValueNumber ? lastValueNumber.floatValue : -999.0f;
    BOOL lastPressed = lastPressedNumber ? lastPressedNumber.boolValue : NO;
    BOOL changed = !lastValueNumber || fabsf(lastValue - value) > 0.01f;

    if (pressedKnown) {
        changed = changed || !lastPressedNumber || lastPressed != pressed;
        objc_setAssociatedObject(button, &kJCFLastPressedKey, @(pressed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(button, &kJCFLastValueKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!changed) {
        return;
    }

    BOOL active = value > 0.10f || lastValue > 0.10f || (pressedKnown && (pressed || lastPressed));
    if (active) {
        NSLog(@"[JoyConHandler] read %@ %@ value=%.3f pressed=%@ ptr=%p",
              kind,
              JCFLabelForButton(button),
              value,
              pressedKnown ? (pressed ? @"YES" : @"NO") : @"?",
              button);
    }
}

static float JCFButtonValue(id self, SEL _cmd) {
    float value = gOrigButtonValue ? ((float (*)(id, SEL))gOrigButtonValue)(self, _cmd) : 0.0f;
    JCFLogRead(self, @"value", value, NO, NO);
    return value;
}

static BOOL JCFButtonPressed(id self, SEL _cmd) {
    BOOL pressed = gOrigButtonPressed ? ((BOOL (*)(id, SEL))gOrigButtonPressed)(self, _cmd) : NO;
    JCFLogRead(self, @"isPressed", pressed ? 1.0f : 0.0f, pressed, YES);
    return pressed;
}

static NSString *JCFBlockSummary(id block) {
    if (!block) {
        return @"nil";
    }
    return [NSString stringWithFormat:@"%@/%p", NSStringFromClass([block class]), block];
}

static void JCFSetButtonValueChangedHandler(id self, SEL _cmd, id handler) {
    NSLog(@"[JoyConHandler] set button value handler %@ ptr=%p block=%@",
          JCFLabelForButton(self), self, JCFBlockSummary(handler));
    if (gOrigSetButtonValueChangedHandler) {
        ((void (*)(id, SEL, id))gOrigSetButtonValueChangedHandler)(self, _cmd, handler);
    }
}

static void JCFSetButtonPressedChangedHandler(id self, SEL _cmd, id handler) {
    NSLog(@"[JoyConHandler] set button pressed handler %@ ptr=%p block=%@",
          JCFLabelForButton(self), self, JCFBlockSummary(handler));
    if (gOrigSetButtonPressedChangedHandler) {
        ((void (*)(id, SEL, id))gOrigSetButtonPressedChangedHandler)(self, _cmd, handler);
    }
}

static void JCFSetProfileValueChangedHandler(id self, SEL _cmd, id handler) {
    NSLog(@"[JoyConHandler] set profile value handler profile=%p block=%@", self, JCFBlockSummary(handler));
    if (gOrigSetProfileValueChangedHandler) {
        ((void (*)(id, SEL, id))gOrigSetProfileValueChangedHandler)(self, _cmd, handler);
    }
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConHandler] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
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
        Class buttonClass = NSClassFromString(@"GCControllerButtonInput");

        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(physicalClass, NSSelectorFromString(@"setValueChangedHandler:"), (IMP)JCFSetProfileValueChangedHandler, &gOrigSetProfileValueChangedHandler);

        JCFSwizzle(buttonClass, @selector(value), (IMP)JCFButtonValue, &gOrigButtonValue);
        JCFSwizzle(buttonClass, @selector(isPressed), (IMP)JCFButtonPressed, &gOrigButtonPressed);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"setValueChangedHandler:"), (IMP)JCFSetButtonValueChangedHandler, &gOrigSetButtonValueChangedHandler);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"setPressedChangedHandler:"), (IMP)JCFSetButtonPressedChangedHandler, &gOrigSetButtonPressedChangedHandler);

        JCFSwizzle(buttonClass, NSSelectorFromString(@"localizedName"), (IMP)JCFButtonLocalizedName, &gOrigLocalizedName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"unmappedLocalizedName"), (IMP)JCFButtonUnmappedLocalizedName, &gOrigUnmappedLocalizedName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"name"), (IMP)JCFButtonName, &gOrigName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"aliases"), (IMP)JCFButtonAliases, &gOrigAliases);

        NSLog(@"[JoyConHandler] handler mapping probe loaded");
    }
}
