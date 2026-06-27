#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m

 Purpose:
   Fix separated fake Joy-Con button mapping inside LiveContainer-hosted apps.

 What the captures showed:
   The fake Joy-Cons work in joined mode, but in separated mode they expose a
   generic "Wireless Gamepad" style layout. The raw reports from the sniffer
   showed this physical order for the four front buttons:

     bottom -> HID Button 1
     right  -> HID Button 2
     left   -> HID Button 3
     top    -> HID Button 4

   The small side/rail shoulder buttons are:

     SL -> HID Button 5
     SR -> HID Button 6

 Why v1/v2 may not affect apps:
   LiveContainer does not interpret controller buttons itself. TweakLoader
   loads this dylib into the guest app, then the guest app or emulator reads
   Apple's GameController objects. Emulators often read
   GCPhysicalInputProfile.buttons/elements/allButtons directly instead of only
   GCExtendedGamepad.buttonA/buttonB.

 What this version does:
   1. Remaps the high-level GCExtendedGamepad/GCMicroGamepad getters.
   2. Rewrites GCPhysicalInputProfile.buttons and elements dictionaries so
      standard keys like "Button A" point at the correct physical button.
   3. Makes physical Button 1..6 objects report helpful aliases/names.
   4. Redirects value/isPressed polling for broken standard button objects.

 Expected separated-mode mapping:

   buttonA       -> physical Button 2 (right)
   buttonB       -> physical Button 1 (bottom)
   buttonX       -> physical Button 4 (top)
   buttonY       -> physical Button 3 (left)
   leftShoulder  -> physical Button 5 (SL)
   rightShoulder -> physical Button 6 (SR)
   leftTrigger   -> physical Button 5 (SL), fallback for apps using triggers
   rightTrigger  -> physical Button 6 (SR), fallback for apps using triggers
*/

#ifndef JOYCONFIX_DEBUG
#define JOYCONFIX_DEBUG 0
#endif

#if JOYCONFIX_DEBUG
#define JCFLog(fmt, ...) NSLog((@"[JoyConFix] " fmt), ##__VA_ARGS__)
#else
#define JCFLog(fmt, ...)
#endif

typedef id (*JCFIdGetterIMP)(id, SEL);
typedef float (*JCFFloatGetterIMP)(id, SEL);
typedef BOOL (*JCFBoolGetterIMP)(id, SEL);

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

static JCFIdGetterIMP JCFOrigProfileButtons;
static JCFIdGetterIMP JCFOrigProfileElements;
static JCFIdGetterIMP JCFOrigProfileAllButtons;

static JCFIdGetterIMP JCFOrigButtonLocalizedName;
static JCFIdGetterIMP JCFOrigButtonUnmappedLocalizedName;
static JCFIdGetterIMP JCFOrigButtonAliases;
static JCFIdGetterIMP JCFOrigButtonSFSymbolsName;
static JCFFloatGetterIMP JCFOrigButtonValue;
static JCFBoolGetterIMP JCFOrigButtonIsPressed;

static NSString * const JCFA = @"JCFRoleA";
static NSString * const JCFB = @"JCFRoleB";
static NSString * const JCFX = @"JCFRoleX";
static NSString * const JCFY = @"JCFRoleY";
static NSString * const JCFLS = @"JCFRoleLS";
static NSString * const JCFRS = @"JCFRoleRS";
static NSString * const JCFLT = @"JCFRoleLT";
static NSString * const JCFRT = @"JCFRoleRT";

static id JCFCallId(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *JCFStringFromObject(id object) {
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    if (object) {
        return [object description];
    }
    return @"";
}

static NSString *JCFNormalize(NSString *name) {
    NSString *lower = JCFStringFromObject(name).lowercaseString;
    NSMutableString *result = [NSMutableString stringWithCapacity:lower.length];

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        BOOL isDigit = (ch >= '0' && ch <= '9');
        BOOL isLetter = (ch >= 'a' && ch <= 'z');
        if (isDigit || isLetter) {
            [result appendFormat:@"%C", ch];
        }
    }

    if ([result hasPrefix:@"gcinput"]) {
        [result deleteCharactersInRange:NSMakeRange(0, 7)];
    }

    return result;
}

static BOOL JCFNameMatchesAny(NSString *candidate, NSArray<NSString *> *wanted) {
    NSString *normalized = JCFNormalize(candidate);
    if (normalized.length == 0) {
        return NO;
    }

    for (NSString *entry in wanted) {
        if ([normalized isEqualToString:JCFNormalize(entry)]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *JCFOriginalButtonsForProfile(id profile) {
    if (profile && JCFOrigProfileButtons) {
        id buttons = JCFOrigProfileButtons(profile, @selector(buttons));
        if ([buttons isKindOfClass:NSDictionary.class]) {
            return buttons;
        }
    }
    return @{};
}

static NSDictionary *JCFOriginalElementsForProfile(id profile) {
    if (profile && JCFOrigProfileElements) {
        id elements = JCFOrigProfileElements(profile, @selector(elements));
        if ([elements isKindOfClass:NSDictionary.class]) {
            return elements;
        }
    }
    return @{};
}

static NSArray *JCFOriginalAllButtonsForProfile(id profile) {
    if (profile && JCFOrigProfileAllButtons) {
        id allButtons = JCFOrigProfileAllButtons(profile, @selector(allButtons));
        if ([allButtons isKindOfClass:NSArray.class]) {
            return allButtons;
        }
    }
    return @[];
}

static BOOL JCFObjectHasName(id object, NSArray<NSString *> *wanted) {
    if (!object) {
        return NO;
    }

    NSArray<NSString *> *selectors = @[@"localizedName", @"unmappedLocalizedName", @"sfSymbolsName", @"name", @"description"];
    for (NSString *selectorName in selectors) {
        id value = JCFCallId(object, NSSelectorFromString(selectorName));
        if (JCFNameMatchesAny(JCFStringFromObject(value), wanted)) {
            return YES;
        }
    }

    id aliases = JCFCallId(object, NSSelectorFromString(@"aliases"));
    if ([aliases respondsToSelector:@selector(objectEnumerator)]) {
        for (id alias in aliases) {
            if (JCFNameMatchesAny(JCFStringFromObject(alias), wanted)) {
                return YES;
            }
        }
    }

    return NO;
}

static NSArray<NSString *> *JCFPhysicalNamesForRole(NSString *role) {
    if ([role isEqualToString:JCFA]) return @[@"Button 2", @"button2", @"2", @"Face Right", @"Right Button"];
    if ([role isEqualToString:JCFB]) return @[@"Button 1", @"button1", @"1", @"Face Bottom", @"Bottom Button"];
    if ([role isEqualToString:JCFX]) return @[@"Button 4", @"button4", @"4", @"Face Top", @"Top Button"];
    if ([role isEqualToString:JCFY]) return @[@"Button 3", @"button3", @"3", @"Face Left", @"Left Button"];
    if ([role isEqualToString:JCFLS]) return @[@"Button 5", @"button5", @"5", @"SL", @"Left Shoulder", @"Left Bumper"];
    if ([role isEqualToString:JCFRS]) return @[@"Button 6", @"button6", @"6", @"SR", @"Right Shoulder", @"Right Bumper"];
    if ([role isEqualToString:JCFLT]) return JCFPhysicalNamesForRole(JCFLS);
    if ([role isEqualToString:JCFRT]) return JCFPhysicalNamesForRole(JCFRS);
    return @[];
}

static NSArray<NSString *> *JCFStandardKeysForRole(NSString *role) {
    if ([role isEqualToString:JCFA]) return @[@"Button A", @"A", @"GCInputButtonA"];
    if ([role isEqualToString:JCFB]) return @[@"Button B", @"B", @"GCInputButtonB"];
    if ([role isEqualToString:JCFX]) return @[@"Button X", @"X", @"GCInputButtonX"];
    if ([role isEqualToString:JCFY]) return @[@"Button Y", @"Y", @"GCInputButtonY"];
    if ([role isEqualToString:JCFLS]) return @[@"Left Shoulder", @"Left Bumper", @"L1", @"LB", @"GCInputLeftShoulder"];
    if ([role isEqualToString:JCFRS]) return @[@"Right Shoulder", @"Right Bumper", @"R1", @"RB", @"GCInputRightShoulder"];
    if ([role isEqualToString:JCFLT]) return @[@"Left Trigger", @"L2", @"LT", @"GCInputLeftTrigger"];
    if ([role isEqualToString:JCFRT]) return @[@"Right Trigger", @"R2", @"RT", @"GCInputRightTrigger"];
    return @[];
}

static NSString *JCFDisplayNameForRole(NSString *role) {
    if ([role isEqualToString:JCFA]) return @"Button A";
    if ([role isEqualToString:JCFB]) return @"Button B";
    if ([role isEqualToString:JCFX]) return @"Button X";
    if ([role isEqualToString:JCFY]) return @"Button Y";
    if ([role isEqualToString:JCFLS]) return @"Left Shoulder";
    if ([role isEqualToString:JCFRS]) return @"Right Shoulder";
    if ([role isEqualToString:JCFLT]) return @"Left Trigger";
    if ([role isEqualToString:JCFRT]) return @"Right Trigger";
    return nil;
}

static id JCFButtonMatchingNames(NSDictionary *buttons, NSArray<NSString *> *names) {
    for (id key in buttons) {
        if (JCFNameMatchesAny(JCFStringFromObject(key), names)) {
            return buttons[key];
        }
    }

    for (id key in buttons) {
        id button = buttons[key];
        if (JCFObjectHasName(button, names)) {
            return button;
        }
    }

    return nil;
}

static BOOL JCFProfileLooksLikeSeparatedFakeJoyCon(id profile) {
    NSDictionary *buttons = JCFOriginalButtonsForProfile(profile);
    if (buttons.count == 0) {
        return NO;
    }

    BOOL has1 = JCFButtonMatchingNames(buttons, @[@"Button 1", @"button1", @"1"]) != nil;
    BOOL has2 = JCFButtonMatchingNames(buttons, @[@"Button 2", @"button2", @"2"]) != nil;
    BOOL has3 = JCFButtonMatchingNames(buttons, @[@"Button 3", @"button3", @"3"]) != nil;
    BOOL has4 = JCFButtonMatchingNames(buttons, @[@"Button 4", @"button4", @"4"]) != nil;

    if (has1 && has2 && has3 && has4) {
        return YES;
    }

    id controller = JCFCallId(profile, NSSelectorFromString(@"controller"));
    NSString *vendor = JCFStringFromObject(JCFCallId(controller, NSSelectorFromString(@"vendorName"))).lowercaseString;
    NSString *category = JCFStringFromObject(JCFCallId(controller, NSSelectorFromString(@"productCategory"))).lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ %@", vendor, category];

    return ([combined containsString:@"wireless gamepad"] ||
            [combined containsString:@"joy"] ||
            [combined containsString:@"nintendo"]);
}

static id JCFSourceButtonForRole(id profile, NSString *role) {
    if (!JCFProfileLooksLikeSeparatedFakeJoyCon(profile)) {
        return nil;
    }

    id source = JCFButtonMatchingNames(JCFOriginalButtonsForProfile(profile), JCFPhysicalNamesForRole(role));
    if (source) {
        return source;
    }

    return JCFButtonMatchingNames(JCFOriginalElementsForProfile(profile), JCFPhysicalNamesForRole(role));
}

static id JCFControllerForProfile(id profile) {
    id direct = JCFCallId(profile, NSSelectorFromString(@"controller"));
    if (direct) {
        return direct;
    }

    for (GCController *controller in [GCController controllers]) {
        if (controller.extendedGamepad == profile ||
            controller.microGamepad == profile ||
            controller.physicalInputProfile == profile) {
            return controller;
        }
    }

    return nil;
}

static id JCFPhysicalProfileForGamepad(id gamepad) {
    id controller = JCFControllerForProfile(gamepad);
    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    return profile ?: gamepad;
}

static id JCFRemappedGamepadGetter(id gamepad, SEL selector, NSString *role, JCFIdGetterIMP original) {
    id source = JCFSourceButtonForRole(JCFPhysicalProfileForGamepad(gamepad), role);
    if (source) {
        return source;
    }
    return original ? original(gamepad, selector) : nil;
}

static id JCFExtendedButtonA(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFA, JCFOrigExtendedButtonA); }
static id JCFExtendedButtonB(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFB, JCFOrigExtendedButtonB); }
static id JCFExtendedButtonX(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFX, JCFOrigExtendedButtonX); }
static id JCFExtendedButtonY(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFY, JCFOrigExtendedButtonY); }
static id JCFExtendedLeftShoulder(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFLS, JCFOrigExtendedLeftShoulder); }
static id JCFExtendedRightShoulder(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFRS, JCFOrigExtendedRightShoulder); }
static id JCFExtendedLeftTrigger(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFLT, JCFOrigExtendedLeftTrigger); }
static id JCFExtendedRightTrigger(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFRT, JCFOrigExtendedRightTrigger); }
static id JCFMicroButtonA(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFA, JCFOrigMicroButtonA); }
static id JCFMicroButtonX(id self, SEL _cmd) { return JCFRemappedGamepadGetter(self, _cmd, JCFX, JCFOrigMicroButtonX); }

static void JCFAddStandardRoleKeys(NSMutableDictionary *dict, id source, NSString *role) {
    if (!dict || !source) {
        return;
    }

    for (NSString *key in JCFStandardKeysForRole(role)) {
        dict[key] = source;
    }
}

static id JCFProfileButtons(id self, SEL _cmd) {
    NSDictionary *original = JCFOriginalButtonsForProfile(self);
    if (!JCFProfileLooksLikeSeparatedFakeJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *patched = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray<NSString *> *roles = @[JCFA, JCFB, JCFX, JCFY, JCFLS, JCFRS, JCFLT, JCFRT];

    for (NSString *role in roles) {
        JCFAddStandardRoleKeys(patched, JCFSourceButtonForRole(self, role), role);
    }

    JCFLog(@"patched buttons keys: %@", patched.allKeys);
    return patched;
}

static id JCFProfileElements(id self, SEL _cmd) {
    NSDictionary *original = JCFOriginalElementsForProfile(self);
    if (!JCFProfileLooksLikeSeparatedFakeJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *patched = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray<NSString *> *roles = @[JCFA, JCFB, JCFX, JCFY, JCFLS, JCFRS, JCFLT, JCFRT];

    for (NSString *role in roles) {
        JCFAddStandardRoleKeys(patched, JCFSourceButtonForRole(self, role), role);
    }

    return patched;
}

static id JCFProfileAllButtons(id self, SEL _cmd) {
    NSArray *original = JCFOriginalAllButtonsForProfile(self);
    if (!JCFProfileLooksLikeSeparatedFakeJoyCon(self)) {
        return original;
    }

    NSMutableArray *patched = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray<NSString *> *roles = @[JCFA, JCFB, JCFX, JCFY, JCFLS, JCFRS];

    for (NSString *role in roles) {
        id button = JCFSourceButtonForRole(self, role);
        if (button && ![seen containsObject:button]) {
            [patched addObject:button];
            [seen addObject:button];
        }
    }

    for (id button in original) {
        if (button && ![seen containsObject:button]) {
            [patched addObject:button];
            [seen addObject:button];
        }
    }

    return patched;
}

static id JCFRoleForButtonObject(id buttonObject) {
    if (!buttonObject) {
        return nil;
    }

    for (GCController *controller in [GCController controllers]) {
        id profile = controller.physicalInputProfile;
        if (!JCFProfileLooksLikeSeparatedFakeJoyCon(profile)) {
            continue;
        }

        NSArray<NSString *> *roles = @[JCFA, JCFB, JCFX, JCFY, JCFLS, JCFRS, JCFLT, JCFRT];
        for (NSString *role in roles) {
            if (JCFSourceButtonForRole(profile, role) == buttonObject) {
                return role;
            }
        }

        id extended = controller.extendedGamepad;
        NSDictionary<NSString *, NSString *> *extendedRoles = @{
            JCFA: @"buttonA",
            JCFB: @"buttonB",
            JCFX: @"buttonX",
            JCFY: @"buttonY",
            JCFLS: @"leftShoulder",
            JCFRS: @"rightShoulder",
            JCFLT: @"leftTrigger",
            JCFRT: @"rightTrigger"
        };

        for (NSString *role in extendedRoles) {
            SEL selector = NSSelectorFromString(extendedRoles[role]);
            id original = nil;
            if ([role isEqualToString:JCFA] && JCFOrigExtendedButtonA) original = JCFOrigExtendedButtonA(extended, selector);
            if ([role isEqualToString:JCFB] && JCFOrigExtendedButtonB) original = JCFOrigExtendedButtonB(extended, selector);
            if ([role isEqualToString:JCFX] && JCFOrigExtendedButtonX) original = JCFOrigExtendedButtonX(extended, selector);
            if ([role isEqualToString:JCFY] && JCFOrigExtendedButtonY) original = JCFOrigExtendedButtonY(extended, selector);
            if ([role isEqualToString:JCFLS] && JCFOrigExtendedLeftShoulder) original = JCFOrigExtendedLeftShoulder(extended, selector);
            if ([role isEqualToString:JCFRS] && JCFOrigExtendedRightShoulder) original = JCFOrigExtendedRightShoulder(extended, selector);
            if ([role isEqualToString:JCFLT] && JCFOrigExtendedLeftTrigger) original = JCFOrigExtendedLeftTrigger(extended, selector);
            if ([role isEqualToString:JCFRT] && JCFOrigExtendedRightTrigger) original = JCFOrigExtendedRightTrigger(extended, selector);

            if (original == buttonObject) {
                return role;
            }
        }
    }

    return nil;
}

static id JCFSourceForMaybeBrokenButtonObject(id buttonObject) {
    NSString *role = JCFRoleForButtonObject(buttonObject);
    if (!role) {
        return nil;
    }

    NSString *sourceRole = role;
    if ([role isEqualToString:JCFLT]) sourceRole = JCFLS;
    if ([role isEqualToString:JCFRT]) sourceRole = JCFRS;

    for (GCController *controller in [GCController controllers]) {
        id source = JCFSourceButtonForRole(controller.physicalInputProfile, sourceRole);
        if (source && source != buttonObject) {
            return source;
        }
    }

    return nil;
}

static id JCFButtonLocalizedName(id self, SEL _cmd) {
    NSString *role = JCFRoleForButtonObject(self);
    NSString *name = JCFDisplayNameForRole(role);
    if (name) {
        return name;
    }
    return JCFOrigButtonLocalizedName ? JCFOrigButtonLocalizedName(self, _cmd) : nil;
}

static id JCFButtonUnmappedLocalizedName(id self, SEL _cmd) {
    NSString *role = JCFRoleForButtonObject(self);
    NSString *name = JCFDisplayNameForRole(role);
    if (name) {
        return name;
    }
    return JCFOrigButtonUnmappedLocalizedName ? JCFOrigButtonUnmappedLocalizedName(self, _cmd) : nil;
}

static id JCFButtonAliases(id self, SEL _cmd) {
    NSString *role = JCFRoleForButtonObject(self);
    NSArray<NSString *> *standard = JCFStandardKeysForRole(role);
    if (standard.count > 0) {
        NSMutableArray *aliases = [standard mutableCopy];
        id original = JCFOrigButtonAliases ? JCFOrigButtonAliases(self, _cmd) : nil;
        if ([original respondsToSelector:@selector(objectEnumerator)]) {
            for (id alias in original) {
                if (alias && ![aliases containsObject:alias]) {
                    [aliases addObject:alias];
                }
            }
        }
        return aliases;
    }

    return JCFOrigButtonAliases ? JCFOrigButtonAliases(self, _cmd) : nil;
}

static id JCFButtonSFSymbolsName(id self, SEL _cmd) {
    NSString *role = JCFRoleForButtonObject(self);
    if ([role isEqualToString:JCFA]) return @"a.circle";
    if ([role isEqualToString:JCFB]) return @"b.circle";
    if ([role isEqualToString:JCFX]) return @"x.circle";
    if ([role isEqualToString:JCFY]) return @"y.circle";
    if ([role isEqualToString:JCFLS]) return @"l1.rectangle.roundedbottom";
    if ([role isEqualToString:JCFRS]) return @"r1.rectangle.roundedbottom";
    return JCFOrigButtonSFSymbolsName ? JCFOrigButtonSFSymbolsName(self, _cmd) : nil;
}

static float JCFButtonValue(id self, SEL _cmd) {
    id source = JCFSourceForMaybeBrokenButtonObject(self);
    if (source && JCFOrigButtonValue) {
        return JCFOrigButtonValue(source, _cmd);
    }
    return JCFOrigButtonValue ? JCFOrigButtonValue(self, _cmd) : 0.0f;
}

static BOOL JCFButtonIsPressed(id self, SEL _cmd) {
    id source = JCFSourceForMaybeBrokenButtonObject(self);
    if (source && JCFOrigButtonIsPressed) {
        return JCFOrigButtonIsPressed(source, _cmd);
    }
    return JCFOrigButtonIsPressed ? JCFOrigButtonIsPressed(self, _cmd) : NO;
}

static void JCFHookIdGetter(Class cls, SEL selector, IMP replacement, JCFIdGetterIMP *storage) {
    if (!cls || !selector || !replacement || !storage) {
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    *storage = (JCFIdGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
    JCFLog(@"hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFHookFloatGetter(Class cls, SEL selector, IMP replacement, JCFFloatGetterIMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !storage) {
        return;
    }

    *storage = (JCFFloatGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void JCFHookBoolGetter(Class cls, SEL selector, IMP replacement, JCFBoolGetterIMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !storage) {
        return;
    }

    *storage = (JCFBoolGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static Class JCFClass(NSString *name) {
    return NSClassFromString(name);
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        Class extended = JCFClass(@"GCExtendedGamepad");
        Class micro = JCFClass(@"GCMicroGamepad");
        Class profile = JCFClass(@"GCPhysicalInputProfile");
        Class button = JCFClass(@"GCControllerButtonInput");

        JCFHookIdGetter(extended, @selector(buttonA), (IMP)JCFExtendedButtonA, &JCFOrigExtendedButtonA);
        JCFHookIdGetter(extended, @selector(buttonB), (IMP)JCFExtendedButtonB, &JCFOrigExtendedButtonB);
        JCFHookIdGetter(extended, @selector(buttonX), (IMP)JCFExtendedButtonX, &JCFOrigExtendedButtonX);
        JCFHookIdGetter(extended, @selector(buttonY), (IMP)JCFExtendedButtonY, &JCFOrigExtendedButtonY);
        JCFHookIdGetter(extended, @selector(leftShoulder), (IMP)JCFExtendedLeftShoulder, &JCFOrigExtendedLeftShoulder);
        JCFHookIdGetter(extended, @selector(rightShoulder), (IMP)JCFExtendedRightShoulder, &JCFOrigExtendedRightShoulder);
        JCFHookIdGetter(extended, @selector(leftTrigger), (IMP)JCFExtendedLeftTrigger, &JCFOrigExtendedLeftTrigger);
        JCFHookIdGetter(extended, @selector(rightTrigger), (IMP)JCFExtendedRightTrigger, &JCFOrigExtendedRightTrigger);

        JCFHookIdGetter(micro, @selector(buttonA), (IMP)JCFMicroButtonA, &JCFOrigMicroButtonA);
        JCFHookIdGetter(micro, @selector(buttonX), (IMP)JCFMicroButtonX, &JCFOrigMicroButtonX);

        JCFHookIdGetter(profile, @selector(buttons), (IMP)JCFProfileButtons, &JCFOrigProfileButtons);
        JCFHookIdGetter(profile, @selector(elements), (IMP)JCFProfileElements, &JCFOrigProfileElements);
        JCFHookIdGetter(profile, @selector(allButtons), (IMP)JCFProfileAllButtons, &JCFOrigProfileAllButtons);

        JCFHookIdGetter(button, @selector(localizedName), (IMP)JCFButtonLocalizedName, &JCFOrigButtonLocalizedName);
        JCFHookIdGetter(button, @selector(unmappedLocalizedName), (IMP)JCFButtonUnmappedLocalizedName, &JCFOrigButtonUnmappedLocalizedName);
        JCFHookIdGetter(button, NSSelectorFromString(@"aliases"), (IMP)JCFButtonAliases, &JCFOrigButtonAliases);
        JCFHookIdGetter(button, NSSelectorFromString(@"sfSymbolsName"), (IMP)JCFButtonSFSymbolsName, &JCFOrigButtonSFSymbolsName);
        JCFHookFloatGetter(button, @selector(value), (IMP)JCFButtonValue, &JCFOrigButtonValue);
        JCFHookBoolGetter(button, @selector(isPressed), (IMP)JCFButtonIsPressed, &JCFOrigButtonIsPressed);

        JCFLog(@"installed v3 fake Joy-Con GameController remapper");
    }
}
