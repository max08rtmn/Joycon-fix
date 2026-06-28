#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>

/*
 JoyConFix.m - read-hook diagnostic

 Purpose:
 MeloNX ignores name/alias fixes, and polling crashes. This build does not poll
 and does not alter input. It only logs when MeloNX itself reads a button.

 Search logs for:
   [JoyConRead]

 Press A, B, X, Y, SL, SR once each.
*/

static char kJCFButtonLabelKey;
static char kJCFLastValueKey;
static char kJCFLastPressedKey;

static IMP gOrigVendorName;
static IMP gOrigProductCategory;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigButtonValue;
static IMP gOrigButtonPressed;

static NSData *JCFForcedControllerTypesData(void) {
    static NSData *data;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *json = @"{\"0\":\"ProController\",\"1\":\"ProController\",\"2\":\"ProController\",\"3\":\"ProController\"}";
        data = [json dataUsingEncoding:NSUTF8StringEncoding];
    });
    return data;
}

static NSString *JCFForcedControllerTypesString(void) {
    static NSString *string;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        string = [[NSString alloc] initWithData:JCFForcedControllerTypesData() encoding:NSUTF8StringEncoding];
    });
    return string;
}

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

static id JCFOriginalGetter(id object, SEL selector, IMP original) {
    if (original) {
        return ((id (*)(id, SEL))original)(object, selector);
    }
    if (object && selector && [object respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    }
    return nil;
}

static BOOL JCFTextLooksLikeJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"joy-con"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"nintendo"] ||
           [lower containsString:@"wireless gamepad"];
}

static BOOL JCFLooksLikeJoyConController(id controller) {
    if (!controller) {
        return NO;
    }

    NSString *vendorName = JCFString(JCFOriginalGetter(controller, @selector(vendorName), gOrigVendorName));
    NSString *productCategory = JCFString(JCFOriginalGetter(controller, @selector(productCategory), gOrigProductCategory));
    return JCFTextLooksLikeJoyCon([NSString stringWithFormat:@"%@ %@", vendorName, productCategory]);
}

static id JCFVendorName(id self, SEL _cmd) {
    id original = JCFOriginalGetter(self, _cmd, gOrigVendorName);
    if (JCFTextLooksLikeJoyCon(JCFString(original))) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static id JCFProductCategory(id self, SEL _cmd) {
    id original = JCFOriginalGetter(self, _cmd, gOrigProductCategory);
    if (JCFTextLooksLikeJoyCon(JCFString(original)) || JCFLooksLikeJoyConController(self)) {
        return @"Xbox Wireless Controller";
    }
    return original;
}

static BOOL JCFIsControllerTypesKey(id key) {
    return [key isKindOfClass:NSString.class] && [(NSString *)key isEqualToString:@"ControllerTypesForID"];
}

static id JCFDefaultsObjectForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesData();
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsDataForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesData();
    }
    return gOrigDefaultsDataForKey ? ((id (*)(id, SEL, id))gOrigDefaultsDataForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        return JCFForcedControllerTypesString();
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static NSString *JCFLabelForButton(id button) {
    NSString *label = objc_getAssociatedObject(button, &kJCFButtonLabelKey);
    if (label.length > 0) {
        return label;
    }
    return [NSString stringWithFormat:@"unlabeled.%@", NSStringFromClass([button class])];
}

static void JCFSetButtonLabel(id button, NSString *label) {
    if (!button || label.length == 0) {
        return;
    }
    if (!objc_getAssociatedObject(button, &kJCFButtonLabelKey)) {
        objc_setAssociatedObject(button, &kJCFButtonLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSLog(@"[JoyConRead] label %@ -> %p", label, button);
    }
}

static void JCFLabelController(GCController *controller) {
    if (!JCFLooksLikeJoyConController(controller)) {
        return;
    }

    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(profile, NSSelectorFromString(@"buttons"));
    if ([buttons isKindOfClass:NSDictionary.class]) {
        for (NSString *key in (NSDictionary *)buttons) {
            JCFSetButtonLabel(((NSDictionary *)buttons)[key], key);
        }
    }

    GCExtendedGamepad *extended = controller.extendedGamepad;
    if (extended) {
        JCFSetButtonLabel(extended.buttonA, @"extended.buttonA");
        JCFSetButtonLabel(extended.buttonB, @"extended.buttonB");
        JCFSetButtonLabel(extended.buttonX, @"extended.buttonX");
        JCFSetButtonLabel(extended.buttonY, @"extended.buttonY");
        JCFSetButtonLabel(extended.leftShoulder, @"extended.leftShoulder");
        JCFSetButtonLabel(extended.rightShoulder, @"extended.rightShoulder");
        JCFSetButtonLabel(extended.leftTrigger, @"extended.leftTrigger");
        JCFSetButtonLabel(extended.rightTrigger, @"extended.rightTrigger");
    }
}

static void JCFLabelAllControllers(void) {
    for (GCController *controller in [GCController controllers]) {
        JCFLabelController(controller);
    }
}

static void JCFMaybeLogRead(id button, NSString *kind, float value, BOOL pressed, BOOL pressedKnown) {
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
        NSLog(@"[JoyConRead] %@ %@ value=%.3f pressed=%@ ptr=%p",
              kind,
              JCFLabelForButton(button),
              value,
              pressedKnown ? (pressed ? @"YES" : @"NO") : @"?",
              button);
    }
}

static float JCFButtonValue(id self, SEL _cmd) {
    float value = gOrigButtonValue ? ((float (*)(id, SEL))gOrigButtonValue)(self, _cmd) : 0.0f;
    JCFMaybeLogRead(self, @"value", value, NO, NO);
    return value;
}

static BOOL JCFButtonPressed(id self, SEL _cmd) {
    BOOL pressed = gOrigButtonPressed ? ((BOOL (*)(id, SEL))gOrigButtonPressed)(self, _cmd) : NO;
    JCFMaybeLogRead(self, @"pressed", pressed ? 1.0f : 0.0f, pressed, YES);
    return pressed;
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

        JCFSwizzle(GCController.class, @selector(vendorName), (IMP)JCFVendorName, &gOrigVendorName);
        JCFSwizzle(GCController.class, @selector(productCategory), (IMP)JCFProductCategory, &gOrigProductCategory);
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(dataForKey:), (IMP)JCFDefaultsDataForKey, &gOrigDefaultsDataForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(GCControllerButtonInput.class, @selector(value), (IMP)JCFButtonValue, &gOrigButtonValue);
        JCFSwizzle(GCControllerButtonInput.class, @selector(isPressed), (IMP)JCFButtonPressed, &gOrigButtonPressed);

        NSLog(@"[JoyConRead] read-hook diagnostic loaded");

        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
            JCFLabelController(notification.object);
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFLabelAllControllers();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFLabelAllControllers();
        });
    }
}
