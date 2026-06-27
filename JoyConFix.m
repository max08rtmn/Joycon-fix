#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m v5

 Goal:
   Fake Joy-Cons work in joined mode, but separated mode is exposed to iOS as
   generic "Wireless Gamepad" controllers. Your HID captures showed:

     Face bottom -> Button 1
     Face right  -> Button 2
     Face left   -> Button 3
     Face top    -> Button 4
     SL          -> Button 5
     SR          -> Button 6

   This file combines the Gemini axis fix that successfully rotates stick input
   with a safer button fix for LiveContainer apps and emulators such as MelonX.

 Why this version should not crash like v3:
   It does not hook GCControllerButtonInput globally. It only:
     - swizzles GCController.microGamepad / extendedGamepad
     - hooks GCPhysicalInputProfile buttons/elements/allButtons dictionaries
     - returns remapped buttons from GCExtendedGamepad/GCMicroGamepad getters
     - dynamically subclasses only axis objects, using Gemini's working method
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

static char kSecondaryAxisKey;
static char kJoyConTypeKey; // 1 = left, 2 = right
static char kAxisTypeKey;   // 1 = x, 2 = y

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
    if (!profile || !origProfileButtons) {
        return @{};
    }
    id value = origProfileButtons(profile, @selector(buttons));
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static NSDictionary *JCFOriginalElements(id profile) {
    if (!profile || !origProfileElements) {
        return @{};
    }
    id value = origProfileElements(profile, @selector(elements));
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static NSArray *JCFOriginalAllButtons(id profile) {
    if (!profile || !origProfileAllButtons) {
        return @[];
    }
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

static NSArray<NSString *> *JCFPhysicalNamesForRole(NSString *role) {
    if ([role isEqualToString:@"A"]) return JCFPhysicalNamesForIndex(2);
    if ([role isEqualToString:@"B"]) return JCFPhysicalNamesForIndex(1);
    if ([role isEqualToString:@"X"]) return JCFPhysicalNamesForIndex(4);
    if ([role isEqualToString:@"Y"]) return JCFPhysicalNamesForIndex(3);
    if ([role isEqualToString:@"LS"]) return JCFPhysicalNamesForIndex(5);
    if ([role isEqualToString:@"RS"]) return JCFPhysicalNamesForIndex(6);
    if ([role isEqualToString:@"LT"]) return JCFPhysicalNamesForIndex(5);
    if ([role isEqualToString:@"RT"]) return JCFPhysicalNamesForIndex(6);
    return @[];
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

    id controller = JCFCallId(profile, NSSelectorFromString(@"controller"));
    NSString *vendor = JCFString(JCFCallId(controller, NSSelectorFromString(@"vendorName"))).lowercaseString;
    NSString *category = JCFString(JCFCallId(controller, NSSelectorFromString(@"productCategory"))).lowercaseString;
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
    if (source) {
        return source;
    }

    source = JCFDictionaryObjectMatching(JCFOriginalElements(profile), JCFPhysicalNamesForRole(role));
    if (source) {
        return source;
    }

    return JCFAllButtonsObjectAtPhysicalIndex(profile, JCFPhysicalIndexForRole(role));
}

static BOOL JCFControllerLooksLikeJoyCon(GCController *controller) {
    NSString *name = controller.vendorName ?: @"";
    NSString *category = controller.productCategory ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@ %@", name, category];

    return [combined containsString:@"Wireless Gamepad"] ||
           [combined containsString:@"Joy-Con"] ||
           [combined containsString:@"Nintendo"] ||
           [combined.lowercaseString containsString:@"joy"];
}

static BOOL JCFControllerIsLeft(GCController *controller) {
    NSString *name = controller.vendorName ?: @"";
    if ([name containsString:@"(R)"] || [name containsString:@"Right"]) {
        return NO;
    }
    return YES;
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
    GCController *controller = JCFControllerForProfile(gamepad);
    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    return profile ?: gamepad;
}

static id JCFRemappedGetter(id gamepad, SEL selector, NSString *role, JCFIdGetterIMP original) {
    id source = JCFSourceButtonForRole(JCFPhysicalProfileForGamepad(gamepad), role);
    if (source) {
        return source;
    }
    return original ? original(gamepad, selector) : nil;
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
    if (!source) {
        return;
    }

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
    NSArray *roles = @[@"A", @"B", @"X", @"Y", @"LS", @"RS", @"LT", @"RT"];
    for (NSString *role in roles) {
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
    NSArray *roles = @[@"A", @"B", @"X", @"Y", @"LS", @"RS", @"LT", @"RT"];
    for (NSString *role in roles) {
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
    NSArray *roles = @[@"B", @"A", @"Y", @"X", @"LS", @"RS"];

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

// Axis rotation, based on the Gemini version that worked on your iPad.
static float JCFAxisValue(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    Class superCls = class_getSuperclass(cls);
    Method origMethod = class_getInstanceMethod(superCls, @selector(value));
    if (!origMethod) {
        return 0.0f;
    }

    float (*origIMP)(id, SEL) = (float (*)(id, SEL))method_getImplementation(origMethod);
    if (!origIMP) {
        return 0.0f;
    }

    NSNumber *axisTypeNumber = objc_getAssociatedObject(self, &kAxisTypeKey);
    if (!axisTypeNumber) {
        return origIMP(self, _cmd);
    }

    int axisType = axisTypeNumber.intValue;
    int joyConType = [objc_getAssociatedObject(self, &kJoyConTypeKey) intValue];
    id otherAxis = objc_getAssociatedObject(self, &kSecondaryAxisKey);
    if (!otherAxis) {
        return origIMP(self, _cmd);
    }

    Class otherCls = object_getClass(otherAxis);
    Class otherSuperCls = class_getSuperclass(otherCls);
    Class targetSuper = [NSStringFromClass(otherCls) hasPrefix:@"JCFixAxis_"] ? otherSuperCls : otherCls;
    Method otherOrigMethod = class_getInstanceMethod(targetSuper, @selector(value));
    float (*otherOrigIMP)(id, SEL) = otherOrigMethod ? (float (*)(id, SEL))method_getImplementation(otherOrigMethod) : origIMP;

    float rawX = (axisType == 1) ? origIMP(self, _cmd) : otherOrigIMP(otherAxis, @selector(value));
    float rawY = (axisType == 2) ? origIMP(self, _cmd) : otherOrigIMP(otherAxis, @selector(value));
    BOOL isLeft = (joyConType == 1);

    if (axisType == 1) {
        return isLeft ? rawY : -rawY;
    }
    return isLeft ? -rawX : rawX;
}

static void JCFHookAxis(GCControllerAxisInput *axis, int axisType, int joyConType, GCControllerAxisInput *otherAxis) {
    if (!axis || !otherAxis) {
        return;
    }

    objc_setAssociatedObject(axis, &kAxisTypeKey, @(axisType), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(axis, &kJoyConTypeKey, @(joyConType), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(axis, &kSecondaryAxisKey, otherAxis, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class originalClass = object_getClass(axis);
    NSString *originalName = NSStringFromClass(originalClass);
    if ([originalName hasPrefix:@"JCFixAxis_"]) {
        return;
    }

    NSString *subclassName = [@"JCFixAxis_" stringByAppendingString:originalName];
    Class subclass = NSClassFromString(subclassName);
    if (!subclass) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass) {
            class_addMethod(subclass, @selector(value), (IMP)JCFAxisValue, "f@:");
            objc_registerClassPair(subclass);
        }
    }

    if (subclass) {
        object_setClass(axis, subclass);
    }
}

static void JCFLinkAxes(GCControllerAxisInput *xAxis, GCControllerAxisInput *yAxis, int joyConType) {
    JCFHookAxis(xAxis, 1, joyConType, yAxis);
    JCFHookAxis(yAxis, 2, joyConType, xAxis);
}

static void JCFPatchControllerAxes(GCController *controller, GCMicroGamepad *micro, GCExtendedGamepad *extended) {
    if (!JCFControllerLooksLikeJoyCon(controller)) {
        return;
    }

    int type = JCFControllerIsLeft(controller) ? 1 : 2;
    if (micro) {
        JCFLinkAxes(micro.dpad.xAxis, micro.dpad.yAxis, type);
    }
    if (extended) {
        JCFLinkAxes(extended.dpad.xAxis, extended.dpad.yAxis, type);
        JCFLinkAxes(extended.leftThumbstick.xAxis, extended.leftThumbstick.yAxis, type);
        JCFLinkAxes(extended.rightThumbstick.xAxis, extended.rightThumbstick.yAxis, type);
    }
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
    JCFPatchControllerAxes(self, pad, nil);
    return pad;
}

- (GCExtendedGamepad *)jcfix_extendedGamepad {
    GCExtendedGamepad *pad = [self jcfix_extendedGamepad];
    JCFPatchControllerAxes(self, nil, pad);
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

        JCFLog(@"v5 installed");
    }
}
