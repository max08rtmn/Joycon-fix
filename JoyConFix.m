#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>

/*
 JoyConFix.m - load marker + read probe, identity-neutral

 This is intentionally simple:
 - no Xbox/ProController spoof
 - no ControllerTypesForID override
 - no stick changes
 - no handler replacement
 - no button value changes

 It only proves that the exact dylib is loaded and logs physical button reads
 when MeloNX asks GameController for value/isPressed.

 Search the log for:
   [JoyConSure]
*/

static char kJCFButtonLabelKey;
static char kJCFLastValueKey;
static char kJCFLastPressedKey;

static IMP gOrigPhysicalButtons;
static IMP gOrigButtonValue;
static IMP gOrigButtonPressed;

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
    if (unmapped.length > 0) {
        return unmapped;
    }

    NSString *localized = JCFString(JCFCallId(button, NSSelectorFromString(@"localizedName")));
    if (localized.length > 0) {
        return localized;
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
        NSLog(@"[JoyConSure] label %@ -> %p", label, button);
    }
}

static BOOL JCFIsWatchedButton(id button) {
    NSString *label = [JCFLabelForButton(button) lowercaseString];
    return [label containsString:@"button a"] ||
           [label containsString:@"button b"] ||
           [label containsString:@"button x"] ||
           [label containsString:@"button y"] ||
           [label containsString:@"a button"] ||
           [label containsString:@"b button"] ||
           [label containsString:@"x button"] ||
           [label containsString:@"y button"] ||
           [label containsString:@"left shoulder"] ||
           [label containsString:@"right shoulder"] ||
           [label containsString:@"l1"] ||
           [label containsString:@"r1"];
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    NSDictionary *buttons = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;
    if (![buttons isKindOfClass:NSDictionary.class]) {
        return buttons;
    }

    static NSMutableSet *seenProfiles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seenProfiles = [NSMutableSet set];
    });

    NSString *profileKey = [NSString stringWithFormat:@"%p", self];
    BOOL shouldLog = NO;
    @synchronized(seenProfiles) {
        if (![seenProfiles containsObject:profileKey]) {
            [seenProfiles addObject:profileKey];
            shouldLog = YES;
        }
    }

    for (NSString *key in buttons) {
        if ([key isKindOfClass:NSString.class]) {
            JCFSetButtonLabel([buttons objectForKey:key], key);
        }
    }

    if (shouldLog) {
        NSLog(@"[JoyConSure] physical profile=%p buttonCount=%lu keys=%@",
              self,
              (unsigned long)buttons.count,
              [[buttons allKeys] componentsJoinedByString:@", "]);
    }

    return buttons;
}

static void JCFLogReadIfChanged(id button, NSString *kind, float value, BOOL pressed, BOOL pressedKnown) {
    if (!JCFIsWatchedButton(button)) {
        return;
    }

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

    BOOL active = value > 0.10f || lastValue > 0.10f || (pressedKnown && (pressed || lastPressed));
    if (changed && active) {
        NSLog(@"[JoyConSure] read %@ %@ value=%.3f pressed=%@ ptr=%p",
              kind,
              JCFLabelForButton(button),
              value,
              pressedKnown ? (pressed ? @"YES" : @"NO") : @"?",
              button);
    }
}

static float JCFButtonValue(id self, SEL _cmd) {
    float value = gOrigButtonValue ? ((float (*)(id, SEL))gOrigButtonValue)(self, _cmd) : 0.0f;
    JCFLogReadIfChanged(self, @"value", value, NO, NO);
    return value;
}

static BOOL JCFButtonPressed(id self, SEL _cmd) {
    BOOL pressed = gOrigButtonPressed ? ((BOOL (*)(id, SEL))gOrigButtonPressed)(self, _cmd) : NO;
    JCFLogReadIfChanged(self, @"isPressed", pressed ? 1.0f : 0.0f, pressed, YES);
    return pressed;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConSure] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConSure] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        NSLog(@"[JoyConSure] LOAD MARKER 2026-06-28-identity-neutral-read-probe");
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        Class buttonClass = NSClassFromString(@"GCControllerButtonInput");

        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(buttonClass, @selector(value), (IMP)JCFButtonValue, &gOrigButtonValue);
        JCFSwizzle(buttonClass, @selector(isPressed), (IMP)JCFButtonPressed, &gOrigButtonPressed);

        NSLog(@"[JoyConSure] ready");
    }
}
