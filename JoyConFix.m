#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m v6

 Fix for separated fake Joy-Cons in LiveContainer apps.

 Important:
   This version does NOT rotate sticks. The Gemini stick code proved that
   per-object dynamic subclassing works inside LiveContainer/MelonX, but stick
   rotation is not part of the fix.

 From your HID captures in separated mode:

   Face bottom -> physical Button 1
   Face right  -> physical Button 2
   Face left   -> physical Button 3
   Face top    -> physical Button 4
   SL          -> physical Button 5
   SR          -> physical Button 6

 Desired normal gamepad mapping:

   A              -> physical Button 2
   B              -> physical Button 1
   X              -> physical Button 4
   Y              -> physical Button 3
   Left Shoulder  -> physical Button 5 / SL
   Right Shoulder -> physical Button 6 / SR

 What this tweak does:
   1. Swizzles GCController.microGamepad / extendedGamepad so button objects are
      patched as soon as the emulator asks for the profile.
   2. Dynamically subclasses only the concrete button objects belonging to the
      fake Joy-Con. This is the safer Gemini-style method, but applied to
      buttons instead of axes.
   3. Patches GCPhysicalInputProfile.buttons/elements/allButtons dictionaries so
      apps that inspect the physical profile see normal keys.

 It does not globally hook GCControllerButtonInput, and it does not touch axes.
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

static char kSourceButtonKey;
static char kRoleNameKey;

static JCFIdGetterIMP origExtendedButtonA;
static JCFIdGetterIMP origExtendedButtonB;
static JCFIdGetterIMP origExtendedButtonX;
static JCFIdGetterIMP origExtendedButtonY;
static JCFIdGetterIMP origExtendedLeftShoulder;
static JCFIdGetterIMP origExtendedRightShoulder;
static JCFIdGetterIMP origExtendedLeftTrigger;
static JCFIdGetterIMP origExtendedRightTrigger;
static JCFIdGetterIMP origMicroButtonA;
static JCFIdGetterIMP origMicroButtonX;
static JCFIdGetterIMP origProfileButtons;
static JCFIdGetterIMP origProfileElements;
static JCFIdGetterIMP origProfileAllButtons;

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

static NSString *JCFNormalize(NSString *value) {
    NSString *lower = JCFString(value).lowercaseString;
    NSMutableString *out = [NSMutableString stringWithCapacity:lower.length];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        BOOL digit = (ch >= '0' && ch <= '9');
        BOOL letter = (ch >= 'a' && ch <= 'z');
        if (digit || letter) {
            [out appendFormat:@"%C", ch];
        }
    }
    if ([out hasPrefix:@"gcinput"]) {
        [out deleteCharactersInRange:NSMakeRange(0, 7)];
    }
    return out;
}

static BOOL JCFNameMatches(id candidate, NSArray<NSString *> *names) {
    NSString *normalizedCandidate = JCFNormalize(JCFString(candidate));
    if (normalizedCandidate.length == 0) {
        return NO;
    }
    for (NSString *name in names) {
        if ([normalizedCandidate isEqualToString:JCFNormalize(name)]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *JCFOriginalButtons(id profile) {
    if (!profile || !origProfileButtons) return @{};
    id value = origProfileButtons(profile, @selector(buttons));
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static NSDictionary *JCFOriginalElements(id profile) {
    if (!profile || !origProfileElements) return @{};
    id value = origProfileElements(profile, @selector(elements));
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static NSArray *JCFOriginalAllButtons(id profile) {
    if (!profile || !origProfileAllButtons) return @[];
    id value = origProfileAllButtons(profile, @selector(allButtons));
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSArray<NSString *> *JCFPhysicalNamesForIndex(NSUInteger index) {
    switch (index) {
        case 1: return @[@"Button 1", @"button1", @"1"];
        case 2: return @[@"Button 2", @"button2", @"2"];
        case 3: return @[@"Button 3", @"button3", @"3"];
        case 4: return @[@"Button 4", @"button4", @"4"];
        case 5: return @[@"Button 5", @"button5", @"5", @"SL"];
        case 6: return @[@"Button 6", @"button6", @"6", @"SR"];
        default: return @[];
    }
}

static NSUInteger JCFPhysicalIndexForRole(NSString *role) {
    if ([role isEqualToString:@"A"]) return 2;
    if ([role isEqualToString:@"B"]) return 1;
    if ([role isEqualToString:@"X"]) return 4;
    if ([role isEqualToString:@"Y"]) return 3;
    if ([role isEqualToString:@"LS"]) return 5;
    if ([role isEqualToString:@"RS"]) return 6;
    if ([role isEqualToString:@"LT"]) return 5;
    if ([role isEqualToString:@"RT"]) return 6;
    return 0;
}

static NSArray<NSString *> *JCFPhysicalNamesForRole(NSString *role) {
    return JCFPhysicalNamesForIndex(JCFPhysicalIndexForRole(role));
}

static NSArray<NSString *> *JCFStandardNamesForRole(NSString *role) {
    if ([role isEqualToString:@"A"]) return @[@"Button A", @"A", @"GCInputButtonA"];
    if ([role isEqualToString:@"B"]) return @[@"Button B", @"B", @"GCInputButtonB"];
    if ([role isEqualToString:@"X"]) return @[@"Button X", @"X", @"GCInputButtonX"];
    if ([role isEqualToString:@"Y"]) return @[@"Button Y", @"Y", @"GCInputButtonY"];
    if ([role isEqualToString:@"LS"]) return @[@"Left Shoulder", @"Left Bumper", @"L1", @"LB", @"GCInputLeftShoulder"];
    if ([role isEqualToString:@"RS"]) return @[@"Right Shoulder", @"Right Bumper", @"R1", @"RB", @"GCInputRightShoulder"];
    if ([role isEqualToString:@"LT"]) return @[@"Left Trigger", @"L2", @"LT", @"GCInputLeftTrigger"];
    if ([role isEqualToString:@"RT"]) return @[@"Right Trigger", @"R2", @"RT", @"GCInputRightTrigger"];
    return @[];
}

static id JCFDictionaryObjectMatching(NSDictionary *dict, NSArray<NSString *> *names) {
    for (id key in dict) {
        if (JCFNameMatches(key, names)) {
            return dict[key];
        }
    }
    return nil;
}

static id JCFAllButtonsObjectAtPhysicalIndex(id profile, NSUInteger physicalIndex) {
    NSArray *buttons = JCFOriginalAllButtons(profile);
    if (physicalIndex == 0 || physicalIndex > buttons.count) {
        return nil;
    }
    return buttons[physicalIndex - 1];
}

static BOOL JCFProfileLooksLikeFakeJoyCon(id profile) {
    NSDictionary *buttons = JCFOriginalButtons(profile);
    BOOL has1 = JCFDictionaryObjectMatching(buttons, JCFPhysicalNamesForIndex(1)) != nil;
    BOOL has2 = JCFDictionaryObjectMatching(buttons, JCFPhysicalNamesForIndex(2)) != nil;
    BOOL has3 = JCFDictionaryObjectMatching(buttons, JCFPhysicalNamesForIndex(3)) != nil;
    BOOL has4 = JCFDictionaryObjectMatching(buttons, JCFPhysicalNamesForIndex(4)) != nil;
    if (has1 && has2 && has3 && has4) {
        return YES;
    }

    if (JCFOriginalAllButtons(profile).count >= 4) {
        return YES;
    }

    GCController *controller = JCFCallId(profile, NSSelectorFromString(@"controller"));
    NSString *vendor = (controller.vendorName ?: @"").lowercaseString;
    NSString *category = (controller.productCategory ?: @"").lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ %@", vendor, category];
    return [combined containsString:@"wireless gamepad"] ||
           [combined containsString:@"joy"] ||
           [combined containsString:@"nintendo"];
}

static id JCFSourceButtonForRole(id profile, NSString *role) {
    if (!profile || !JCFProfileLooksLikeFakeJoyCon(profile)) {
        return nil;
    }

    id source = JCFDictionaryObjectMatching(JCFOriginalButtons(profile), JCFPhysicalNamesForRole(role));
    if (source) return source;

    source = JCFDictionaryObjectMatching(JCFOriginalElements(profile), JCFPhysicalNamesForRole(role));
    if (source) return source;

    return JCFAllButtonsObjectAtPhysicalIndex(profile, JCFPhysicalIndexForRole(role));
}

static GCController *JCFControllerForProfile(id profile) {
    id direct = JCFCallId(profile, NSSelectorFromString(@"controller"));
    if (direct) return direct;

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
    GCController *controller = JCFControllerForProfile(gamepad);
    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    return profile ?: gamepad;
}

static JCFFloatGetterIMP JCFOriginalFloatGetterForObject(id object, SEL selector) {
    Class cls = object_getClass(object);
    if ([NSStringFromClass(cls) hasPrefix:@"JCFixButton_"]) {
        cls = class_getSuperclass(cls);
    }
    Method method = class_getInstanceMethod(cls, selector);
    return method ? (JCFFloatGetterIMP)method_getImplementation(method) : NULL;
}

static JCFBoolGetterIMP JCFOriginalBoolGetterForObject(id object, SEL selector) {
    Class cls = object_getClass(object);
    if ([NSStringFromClass(cls) hasPrefix:@"JCFixButton_"]) {
        cls = class_getSuperclass(cls);
    }
    Method method = class_getInstanceMethod(cls, selector);
    return method ? (JCFBoolGetterIMP)method_getImplementation(method) : NULL;
}

static float JCFButtonValue(id self, SEL _cmd) {
    id source = objc_getAssociatedObject(self, &kSourceButtonKey);
    if (source && source != self) {
        JCFFloatGetterIMP sourceValue = JCFOriginalFloatGetterForObject(source, @selector(value));
        if (sourceValue) {
            return sourceValue(source, @selector(value));
        }
    }

    JCFFloatGetterIMP original = JCFOriginalFloatGetterForObject(self, _cmd);
    return original ? original(self, _cmd) : 0.0f;
}

static BOOL JCFButtonIsPressed(id self, SEL _cmd) {
    id source = objc_getAssociatedObject(self, &kSourceButtonKey);
    if (source && source != self) {
        JCFBoolGetterIMP sourcePressed = JCFOriginalBoolGetterForObject(source, @selector(isPressed));
        if (sourcePressed) {
            return sourcePressed(source, @selector(isPressed));
        }
        return JCFButtonValue(source, @selector(value)) > 0.5f;
    }

    JCFBoolGetterIMP original = JCFOriginalBoolGetterForObject(self, _cmd);
    return original ? original(self, _cmd) : (JCFButtonValue(self, @selector(value)) > 0.5f);
}

static void JCFPatchButtonObject(id targetButton, id sourceButton, NSString *role) {
    if (!targetButton || !sourceButton) {
        return;
    }

    objc_setAssociatedObject(targetButton, &kSourceButtonKey, sourceButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(targetButton, &kRoleNameKey, role, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class originalClass = object_getClass(targetButton);
    NSString *originalName = NSStringFromClass(originalClass);
    if ([originalName hasPrefix:@"JCFixButton_"]) {
        return;
    }

    NSString *subclassName = [@"JCFixButton_" stringByAppendingString:originalName];
    Class subclass = NSClassFromString(subclassName);
    if (!subclass) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass) {
            class_addMethod(subclass, @selector(value), (IMP)JCFButtonValue, "f@:");
            class_addMethod(subclass, @selector(isPressed), (IMP)JCFButtonIsPressed, "B@:");
            objc_registerClassPair(subclass);
        }
    }

    if (subclass) {
        object_setClass(targetButton, subclass);
    }
}

static id JCFRemappedGetter(id gamepad, SEL selector, NSString *role, JCFIdGetterIMP original) {
    id target = original ? original(gamepad, selector) : nil;
    id profile = JCFPhysicalProfileForGamepad(gamepad);
    id source = JCFSourceButtonForRole(profile, role);

    if (target && source) {
        JCFPatchButtonObject(target, source, role);
        return target;
    }

    return source ?: target;
}

static id JCFExtendedButtonA(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"A", origExtendedButtonA); }
static id JCFExtendedButtonB(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"B", origExtendedButtonB); }
static id JCFExtendedButtonX(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"X", origExtendedButtonX); }
static id JCFExtendedButtonY(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"Y", origExtendedButtonY); }
static id JCFExtendedLeftShoulder(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"LS", origExtendedLeftShoulder); }
static id JCFExtendedRightShoulder(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"RS", origExtendedRightShoulder); }
static id JCFExtendedLeftTrigger(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"LT", origExtendedLeftTrigger); }
static id JCFExtendedRightTrigger(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"RT", origExtendedRightTrigger); }
static id JCFMicroButtonA(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"A", origMicroButtonA); }
static id JCFMicroButtonX(id self, SEL _cmd) { return JCFRemappedGetter(self, _cmd, @"X", origMicroButtonX); }

static void JCFAddStandardRole(NSMutableDictionary *dict, id source, NSString *role) {
    if (!source) return;
    for (NSString *key in JCFStandardNamesForRole(role)) {
        dict[key] = source;
    }
}

static id JCFProfileButtons(id self, SEL _cmd) {
    NSDictionary *original = JCFOriginalButtons(self);
    if (!JCFProfileLooksLikeFakeJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *patched = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *role in @[@"A", @"B", @"X", @"Y", @"LS", @"RS", @"LT", @"RT"]) {
        JCFAddStandardRole(patched, JCFSourceButtonForRole(self, role), role);
    }
    return patched;
}

static id JCFProfileElements(id self, SEL _cmd) {
    NSDictionary *original = JCFOriginalElements(self);
    if (!JCFProfileLooksLikeFakeJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *patched = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *role in @[@"A", @"B", @"X", @"Y", @"LS", @"RS", @"LT", @"RT"]) {
        JCFAddStandardRole(patched, JCFSourceButtonForRole(self, role), role);
    }
    return patched;
}

static id JCFProfileAllButtons(id self, SEL _cmd) {
    NSArray *original = JCFOriginalAllButtons(self);
    if (!JCFProfileLooksLikeFakeJoyCon(self)) {
        return original;
    }

    NSMutableArray *patched = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *role in @[@"B", @"A", @"Y", @"X", @"LS", @"RS"]) {
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

static void JCFPatchGamepadButtons(id gamepad) {
    if (!gamepad) return;
    (void)JCFCallId(gamepad, @selector(buttonA));
    (void)JCFCallId(gamepad, @selector(buttonB));
    (void)JCFCallId(gamepad, @selector(buttonX));
    (void)JCFCallId(gamepad, @selector(buttonY));
    (void)JCFCallId(gamepad, @selector(leftShoulder));
    (void)JCFCallId(gamepad, @selector(rightShoulder));
    (void)JCFCallId(gamepad, @selector(leftTrigger));
    (void)JCFCallId(gamepad, @selector(rightTrigger));
}

static BOOL JCFControllerLooksRelevant(GCController *controller) {
    NSString *name = controller.vendorName ?: @"";
    NSString *category = controller.productCategory ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@ %@", name, category].lowercaseString;
    return [combined containsString:@"wireless gamepad"] ||
           [combined containsString:@"joy"] ||
           [combined containsString:@"nintendo"] ||
           JCFProfileLooksLikeFakeJoyCon(controller.physicalInputProfile);
}

static void JCFSwizzle(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface GCController (JoyConFix)
- (GCMicroGamepad *)jcfix_microGamepad;
- (GCExtendedGamepad *)jcfix_extendedGamepad;
@end

@implementation GCController (JoyConFix)

- (GCMicroGamepad *)jcfix_microGamepad {
    GCMicroGamepad *pad = [self jcfix_microGamepad];
    if (pad && JCFControllerLooksRelevant(self)) {
        JCFPatchGamepadButtons(pad);
    }
    return pad;
}

- (GCExtendedGamepad *)jcfix_extendedGamepad {
    GCExtendedGamepad *pad = [self jcfix_extendedGamepad];
    if (pad && JCFControllerLooksRelevant(self)) {
        JCFPatchGamepadButtons(pad);
    }
    return pad;
}

@end

static void JCFHookGetter(Class cls, SEL selector, IMP replacement, JCFIdGetterIMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !storage) {
        return;
    }
    *storage = (JCFIdGetterIMP)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        JCFSwizzle(NSClassFromString(@"GCController"), @selector(microGamepad), @selector(jcfix_microGamepad));
        JCFSwizzle(NSClassFromString(@"GCController"), @selector(extendedGamepad), @selector(jcfix_extendedGamepad));

        Class extended = NSClassFromString(@"GCExtendedGamepad");
        Class micro = NSClassFromString(@"GCMicroGamepad");
        Class profile = NSClassFromString(@"GCPhysicalInputProfile");

        JCFHookGetter(extended, @selector(buttonA), (IMP)JCFExtendedButtonA, &origExtendedButtonA);
        JCFHookGetter(extended, @selector(buttonB), (IMP)JCFExtendedButtonB, &origExtendedButtonB);
        JCFHookGetter(extended, @selector(buttonX), (IMP)JCFExtendedButtonX, &origExtendedButtonX);
        JCFHookGetter(extended, @selector(buttonY), (IMP)JCFExtendedButtonY, &origExtendedButtonY);
        JCFHookGetter(extended, @selector(leftShoulder), (IMP)JCFExtendedLeftShoulder, &origExtendedLeftShoulder);
        JCFHookGetter(extended, @selector(rightShoulder), (IMP)JCFExtendedRightShoulder, &origExtendedRightShoulder);
        JCFHookGetter(extended, @selector(leftTrigger), (IMP)JCFExtendedLeftTrigger, &origExtendedLeftTrigger);
        JCFHookGetter(extended, @selector(rightTrigger), (IMP)JCFExtendedRightTrigger, &origExtendedRightTrigger);

        JCFHookGetter(micro, @selector(buttonA), (IMP)JCFMicroButtonA, &origMicroButtonA);
        JCFHookGetter(micro, @selector(buttonX), (IMP)JCFMicroButtonX, &origMicroButtonX);

        JCFHookGetter(profile, @selector(buttons), (IMP)JCFProfileButtons, &origProfileButtons);
        JCFHookGetter(profile, @selector(elements), (IMP)JCFProfileElements, &origProfileElements);
        JCFHookGetter(profile, @selector(allButtons), (IMP)JCFProfileAllButtons, &origProfileAllButtons);

        JCFLog(@"v6 button-only fix installed");
    }
}
