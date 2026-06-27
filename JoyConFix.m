#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m

 LiveContainer itself does not map controller buttons. Its TweakLoader only
 loads tweaks into the guest app, then the app usually reads Apple's
 GameController objects. This tweak therefore patches GameController at the
 object level instead of trying to edit raw HID reports.

 From the supplied raw reports, each separated Joy-Con exposes its four front
 buttons as physical HID buttons in this order:

   bottom -> Button 1
   right  -> Button 2
   left   -> Button 3
   top    -> Button 4

 The small rail buttons are:

   SL -> Button 5
   SR -> Button 6

 The tweak remaps those physical buttons to normal gamepad properties:

   buttonA       -> Button 2
   buttonB       -> Button 1
   buttonX       -> Button 4
   buttonY       -> Button 3
   leftShoulder  -> Button 5
   rightShoulder -> Button 6

 It hooks GCExtendedGamepad/GCMicroGamepad property getters so apps that set
 normal pressedChangedHandler/valueChangedHandler blocks receive the corrected
 source buttons. It also hooks GCControllerButtonInput value/isPressed as a
 fallback for apps that cached the original objects early.
*/

#ifndef JOYCONFIX_DEBUG
#define JOYCONFIX_DEBUG 0
#endif

#if JOYCONFIX_DEBUG
#define JCFLog(fmt, ...) NSLog((@"[JoyConFix] " fmt), ##__VA_ARGS__)
#else
#define JCFLog(fmt, ...)
#endif

typedef id (*JCFIdGetterIMP)(id self, SEL _cmd);
typedef float (*JCFFloatGetterIMP)(id self, SEL _cmd);
typedef BOOL (*JCFBoolGetterIMP)(id self, SEL _cmd);

static JCFIdGetterIMP JCFOrigExtendedButtonA;
static JCFIdGetterIMP JCFOrigExtendedButtonB;
static JCFIdGetterIMP JCFOrigExtendedButtonX;
static JCFIdGetterIMP JCFOrigExtendedButtonY;
static JCFIdGetterIMP JCFOrigExtendedLeftShoulder;
static JCFIdGetterIMP JCFOrigExtendedRightShoulder;
static JCFIdGetterIMP JCFOrigExtendedLeftTrigger;
static JCFIdGetterIMP JCFOrigExtendedRightTrigger;

static JCFIdGetterIMP JCFOrigMicroButtonA;
static JCFIdGetterIMP JCFOrigMicroButtonX;

static JCFFloatGetterIMP JCFOrigButtonValue;
static JCFBoolGetterIMP JCFOrigButtonIsPressed;

static id JCFCallId(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *JCFCallString(id object, SEL selector) {
    id value = JCFCallId(object, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *JCFCallDictionary(id object, SEL selector) {
    id value = JCFCallId(object, selector);
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *JCFNormalizeName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) {
        return @"";
    }

    NSMutableString *normalized = [NSMutableString stringWithCapacity:name.length];
    NSString *lower = name.lowercaseString;

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        BOOL isNumber = (ch >= '0' && ch <= '9');
        BOOL isLetter = (ch >= 'a' && ch <= 'z');
        if (isNumber || isLetter) {
            [normalized appendFormat:@"%C", ch];
        }
    }

    if ([normalized hasPrefix:@"gcinput"]) {
        [normalized deleteCharactersInRange:NSMakeRange(0, 7)];
    }

    return normalized;
}

static BOOL JCFStringMatchesAny(NSString *candidate, NSArray<NSString *> *wanted) {
    NSString *normalizedCandidate = JCFNormalizeName(candidate);
    if (normalizedCandidate.length == 0) {
        return NO;
    }

    for (NSString *entry in wanted) {
        NSString *normalizedEntry = JCFNormalizeName(entry);
        if ([normalizedCandidate isEqualToString:normalizedEntry]) {
            return YES;
        }
    }

    return NO;
}

static BOOL JCFObjectNameMatches(id object, NSArray<NSString *> *wanted) {
    if (!object) {
        return NO;
    }

    NSArray<NSString *> *stringSelectors = @[
        @"localizedName",
        @"unmappedLocalizedName",
        @"sfSymbolsName",
        @"name"
    ];

    for (NSString *selectorName in stringSelectors) {
        NSString *value = JCFCallString(object, NSSelectorFromString(selectorName));
        if (JCFStringMatchesAny(value, wanted)) {
            return YES;
        }
    }

    id aliases = JCFCallId(object, NSSelectorFromString(@"aliases"));
    if ([aliases respondsToSelector:@selector(objectEnumerator)]) {
        for (id alias in aliases) {
            if ([alias isKindOfClass:NSString.class] && JCFStringMatchesAny(alias, wanted)) {
                return YES;
            }
        }
    }

    return NO;
}

static id JCFControllerForProfile(id profile) {
    id directController = JCFCallId(profile, NSSelectorFromString(@"controller"));
    if (directController) {
        return directController;
    }

    NSArray *controllers = [GCController controllers];
    for (id controller in controllers) {
        if (JCFCallId(controller, NSSelectorFromString(@"extendedGamepad")) == profile ||
            JCFCallId(controller, NSSelectorFromString(@"microGamepad")) == profile ||
            JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile")) == profile) {
            return controller;
        }
    }

    return nil;
}

static BOOL JCFControllerLooksLikeJoyCon(id controller) {
    if (!controller) {
        return NO;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSArray<NSString *> *selectors = @[
        @"vendorName",
        @"productCategory",
        @"debugDescription",
        @"description"
    ];

    for (NSString *selectorName in selectors) {
        NSString *value = JCFCallString(controller, NSSelectorFromString(selectorName));
        if (value.length > 0) {
            [names addObject:value.lowercaseString];
        }
    }

    NSString *combined = [names componentsJoinedByString:@" "];
    if ([combined containsString:@"joy"] ||
        [combined containsString:@"nintendo"] ||
        [combined containsString:@"wireless gamepad"]) {
        return YES;
    }

    NSDictionary *buttons = JCFCallDictionary(JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile")),
                                              NSSelectorFromString(@"buttons"));
    BOOL hasButton1 = NO;
    BOOL hasButton2 = NO;
    BOOL hasButton3 = NO;
    BOOL hasButton4 = NO;

    for (id key in buttons) {
        NSString *keyString = [key isKindOfClass:NSString.class] ? key : [key description];
        id value = buttons[key];

        hasButton1 |= JCFStringMatchesAny(keyString, @[@"Button 1", @"1"]) || JCFObjectNameMatches(value, @[@"Button 1", @"1"]);
        hasButton2 |= JCFStringMatchesAny(keyString, @[@"Button 2", @"2"]) || JCFObjectNameMatches(value, @[@"Button 2", @"2"]);
        hasButton3 |= JCFStringMatchesAny(keyString, @[@"Button 3", @"3"]) || JCFObjectNameMatches(value, @[@"Button 3", @"3"]);
        hasButton4 |= JCFStringMatchesAny(keyString, @[@"Button 4", @"4"]) || JCFObjectNameMatches(value, @[@"Button 4", @"4"]);
    }

    return hasButton1 && hasButton2 && hasButton3 && hasButton4;
}

static NSDictionary *JCFButtonsForController(id controller) {
    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    NSDictionary *buttons = JCFCallDictionary(profile, NSSelectorFromString(@"buttons"));
    return buttons ?: @{};
}

static id JCFButtonFromDictionary(NSDictionary *buttons, NSArray<NSString *> *wanted) {
    if (buttons.count == 0) {
        return nil;
    }

    for (id key in buttons) {
        NSString *keyString = [key isKindOfClass:NSString.class] ? key : [key description];
        if (JCFStringMatchesAny(keyString, wanted)) {
            return buttons[key];
        }
    }

    for (id key in buttons) {
        id button = buttons[key];
        if (JCFObjectNameMatches(button, wanted)) {
            return button;
        }
    }

    return nil;
}

static NSArray<NSString *> *JCFNamesForRole(NSString *role) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *roleMap;
    if (!roleMap) {
        roleMap = @{
            @"A": @[@"Button 2", @"button2", @"2", @"Right Button", @"Face Right"],
            @"B": @[@"Button 1", @"button1", @"1", @"Bottom Button", @"Face Bottom"],
            @"X": @[@"Button 4", @"button4", @"4", @"Top Button", @"Face Top"],
            @"Y": @[@"Button 3", @"button3", @"3", @"Left Button", @"Face Left"],
            @"LS": @[@"Button 5", @"button5", @"5", @"SL", @"Left SL"],
            @"RS": @[@"Button 6", @"button6", @"6", @"SR", @"Right SR"]
        };
    }

    return roleMap[role] ?: @[];
}

static id JCFSourceButtonForRoleOnController(id controller, NSString *role) {
    if (!JCFControllerLooksLikeJoyCon(controller)) {
        return nil;
    }

    NSDictionary *buttons = JCFButtonsForController(controller);
    id source = JCFButtonFromDictionary(buttons, JCFNamesForRole(role));
    if (source) {
        JCFLog(@"mapped role %@ to %@", role, source);
    }
    return source;
}

static id JCFSourceButtonForRoleOnProfile(id profile, NSString *role) {
    id controller = JCFControllerForProfile(profile);
    return JCFSourceButtonForRoleOnController(controller, role);
}

static id JCFOriginalButtonForRoleOnProfile(id profile, NSString *role) {
    if ([role isEqualToString:@"A"] && JCFOrigExtendedButtonA) return JCFOrigExtendedButtonA(profile, @selector(buttonA));
    if ([role isEqualToString:@"B"] && JCFOrigExtendedButtonB) return JCFOrigExtendedButtonB(profile, @selector(buttonB));
    if ([role isEqualToString:@"X"] && JCFOrigExtendedButtonX) return JCFOrigExtendedButtonX(profile, @selector(buttonX));
    if ([role isEqualToString:@"Y"] && JCFOrigExtendedButtonY) return JCFOrigExtendedButtonY(profile, @selector(buttonY));
    if ([role isEqualToString:@"LS"] && JCFOrigExtendedLeftShoulder) return JCFOrigExtendedLeftShoulder(profile, @selector(leftShoulder));
    if ([role isEqualToString:@"RS"] && JCFOrigExtendedRightShoulder) return JCFOrigExtendedRightShoulder(profile, @selector(rightShoulder));
    if ([role isEqualToString:@"LT"] && JCFOrigExtendedLeftTrigger) return JCFOrigExtendedLeftTrigger(profile, @selector(leftTrigger));
    if ([role isEqualToString:@"RT"] && JCFOrigExtendedRightTrigger) return JCFOrigExtendedRightTrigger(profile, @selector(rightTrigger));
    return nil;
}

static id JCFRemappedGetter(id profile, SEL selector, NSString *role, JCFIdGetterIMP original) {
    id source = JCFSourceButtonForRoleOnProfile(profile, role);
    if (source) {
        return source;
    }

    return original ? original(profile, selector) : nil;
}

static id JCFExtendedButtonA(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"A", JCFOrigExtendedButtonA);
}

static id JCFExtendedButtonB(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"B", JCFOrigExtendedButtonB);
}

static id JCFExtendedButtonX(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"X", JCFOrigExtendedButtonX);
}

static id JCFExtendedButtonY(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"Y", JCFOrigExtendedButtonY);
}

static id JCFExtendedLeftShoulder(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"LS", JCFOrigExtendedLeftShoulder);
}

static id JCFExtendedRightShoulder(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"RS", JCFOrigExtendedRightShoulder);
}

static id JCFExtendedLeftTrigger(id self, SEL _cmd) {
    id source = JCFSourceButtonForRoleOnProfile(self, @"LS");
    return source ?: (JCFOrigExtendedLeftTrigger ? JCFOrigExtendedLeftTrigger(self, _cmd) : nil);
}

static id JCFExtendedRightTrigger(id self, SEL _cmd) {
    id source = JCFSourceButtonForRoleOnProfile(self, @"RS");
    return source ?: (JCFOrigExtendedRightTrigger ? JCFOrigExtendedRightTrigger(self, _cmd) : nil);
}

static id JCFMicroButtonA(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"A", JCFOrigMicroButtonA);
}

static id JCFMicroButtonX(id self, SEL _cmd) {
    return JCFRemappedGetter(self, _cmd, @"X", JCFOrigMicroButtonX);
}

static id JCFSourceForOriginalButtonObject(id buttonObject) {
    if (!buttonObject) {
        return nil;
    }

    for (id controller in [GCController controllers]) {
        if (!JCFControllerLooksLikeJoyCon(controller)) {
            continue;
        }

        id extended = JCFCallId(controller, NSSelectorFromString(@"extendedGamepad"));
        if (extended) {
            NSDictionary<NSString *, NSString *> *roles = @{
                @"A": @"buttonA",
                @"B": @"buttonB",
                @"X": @"buttonX",
                @"Y": @"buttonY",
                @"LS": @"leftShoulder",
                @"RS": @"rightShoulder",
                @"LT": @"leftTrigger",
                @"RT": @"rightTrigger"
            };

            for (NSString *role in roles) {
                id original = JCFOriginalButtonForRoleOnProfile(extended, role);
                if (original == buttonObject) {
                    NSString *sourceRole = [role isEqualToString:@"LT"] ? @"LS" : ([role isEqualToString:@"RT"] ? @"RS" : role);
                    id source = JCFSourceButtonForRoleOnController(controller, sourceRole);
                    if (source && source != buttonObject) {
                        return source;
                    }
                }
            }
        }

        id micro = JCFCallId(controller, NSSelectorFromString(@"microGamepad"));
        if (micro) {
            id originalA = JCFOrigMicroButtonA ? JCFOrigMicroButtonA(micro, @selector(buttonA)) : nil;
            if (originalA == buttonObject) {
                id source = JCFSourceButtonForRoleOnController(controller, @"A");
                if (source && source != buttonObject) return source;
            }

            id originalX = JCFOrigMicroButtonX ? JCFOrigMicroButtonX(micro, @selector(buttonX)) : nil;
            if (originalX == buttonObject) {
                id source = JCFSourceButtonForRoleOnController(controller, @"X");
                if (source && source != buttonObject) return source;
            }
        }
    }

    return nil;
}

static float JCFButtonValue(id self, SEL _cmd) {
    id source = JCFSourceForOriginalButtonObject(self);
    if (source && source != self && JCFOrigButtonValue) {
        return JCFOrigButtonValue(source, _cmd);
    }

    return JCFOrigButtonValue ? JCFOrigButtonValue(self, _cmd) : 0.0f;
}

static BOOL JCFButtonIsPressed(id self, SEL _cmd) {
    id source = JCFSourceForOriginalButtonObject(self);
    if (source && source != self && JCFOrigButtonIsPressed) {
        return JCFOrigButtonIsPressed(source, _cmd);
    }

    return JCFOrigButtonIsPressed ? JCFOrigButtonIsPressed(self, _cmd) : NO;
}

static void JCFHookGetter(Class cls, SEL selector, IMP replacement, JCFIdGetterIMP *storage) {
    if (!cls || !selector || !replacement || !storage) {
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    *storage = (JCFIdGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
    JCFLog(@"hooked %@ - %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFHookFloatGetter(Class cls, SEL selector, IMP replacement, JCFFloatGetterIMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    *storage = (JCFFloatGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void JCFHookBoolGetter(Class cls, SEL selector, IMP replacement, JCFBoolGetterIMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    *storage = (JCFBoolGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void JCFInstallHooks(void) {
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    installed = YES;

    dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

    Class extendedClass = NSClassFromString(@"GCExtendedGamepad");
    Class microClass = NSClassFromString(@"GCMicroGamepad");
    Class buttonClass = NSClassFromString(@"GCControllerButtonInput");

    JCFHookGetter(extendedClass, @selector(buttonA), (IMP)JCFExtendedButtonA, &JCFOrigExtendedButtonA);
    JCFHookGetter(extendedClass, @selector(buttonB), (IMP)JCFExtendedButtonB, &JCFOrigExtendedButtonB);
    JCFHookGetter(extendedClass, @selector(buttonX), (IMP)JCFExtendedButtonX, &JCFOrigExtendedButtonX);
    JCFHookGetter(extendedClass, @selector(buttonY), (IMP)JCFExtendedButtonY, &JCFOrigExtendedButtonY);
    JCFHookGetter(extendedClass, @selector(leftShoulder), (IMP)JCFExtendedLeftShoulder, &JCFOrigExtendedLeftShoulder);
    JCFHookGetter(extendedClass, @selector(rightShoulder), (IMP)JCFExtendedRightShoulder, &JCFOrigExtendedRightShoulder);
    JCFHookGetter(extendedClass, @selector(leftTrigger), (IMP)JCFExtendedLeftTrigger, &JCFOrigExtendedLeftTrigger);
    JCFHookGetter(extendedClass, @selector(rightTrigger), (IMP)JCFExtendedRightTrigger, &JCFOrigExtendedRightTrigger);

    JCFHookGetter(microClass, @selector(buttonA), (IMP)JCFMicroButtonA, &JCFOrigMicroButtonA);
    JCFHookGetter(microClass, @selector(buttonX), (IMP)JCFMicroButtonX, &JCFOrigMicroButtonX);

    JCFHookFloatGetter(buttonClass, @selector(value), (IMP)JCFButtonValue, &JCFOrigButtonValue);
    JCFHookBoolGetter(buttonClass, @selector(isPressed), (IMP)JCFButtonIsPressed, &JCFOrigButtonIsPressed);

    JCFLog(@"installed GameController hooks");
}

__attribute__((constructor))
static void JCFConstructor(void) {
    @autoreleasepool {
        JCFInstallHooks();
    }
}
