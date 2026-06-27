#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>

/*
 JoyConFix.m - label patch build

 Keeps the working ProController spoof, then labels the physical Joy-Con button
 objects with stable names. This avoids object_setClass and avoids reading
 button values. It is meant for apps that map inputs by GameController element
 names/aliases and get confused by fake Joy-Con descriptors.

 No stick rotation. No value/isPressed hooks. No event handlers.
*/

static char kJCFButtonLabelKey;

static IMP gOrigVendorName;
static IMP gOrigProductCategory;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigLocalizedName;
static IMP gOrigUnmappedLocalizedName;
static IMP gOrigSfSymbolsName;
static IMP gOrigName;
static IMP gOrigAliases;

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
    return label.length ? label : nil;
}

static NSString *JCFSymbolForLabel(NSString *label) {
    NSDictionary<NSString *, NSString *> *symbols = @{
        @"Button A": @"a.circle",
        @"Button B": @"b.circle",
        @"Button X": @"x.circle",
        @"Button Y": @"y.circle",
        @"Left Shoulder": @"l1.button.roundedbottom.horizontal",
        @"Right Shoulder": @"r1.button.roundedbottom.horizontal",
        @"Left Trigger": @"l2.button.roundedtop.horizontal",
        @"Right Trigger": @"r2.button.roundedtop.horizontal",
        @"Direction Pad Up": @"dpad.up.filled",
        @"Direction Pad Down": @"dpad.down.filled",
        @"Direction Pad Left": @"dpad.left.filled",
        @"Direction Pad Right": @"dpad.right.filled"
    };
    return symbols[label];
}

static id JCFButtonLocalizedName(id self, SEL _cmd) {
    NSString *label = JCFLabelForButton(self);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigLocalizedName);
}

static id JCFButtonUnmappedLocalizedName(id self, SEL _cmd) {
    NSString *label = JCFLabelForButton(self);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigUnmappedLocalizedName);
}

static id JCFButtonSfSymbolsName(id self, SEL _cmd) {
    NSString *label = JCFLabelForButton(self);
    NSString *symbol = label ? JCFSymbolForLabel(label) : nil;
    return symbol ?: JCFOriginalGetter(self, _cmd, gOrigSfSymbolsName);
}

static id JCFButtonName(id self, SEL _cmd) {
    NSString *label = JCFLabelForButton(self);
    return label ?: JCFOriginalGetter(self, _cmd, gOrigName);
}

static id JCFButtonAliases(id self, SEL _cmd) {
    NSString *label = JCFLabelForButton(self);
    if (label) {
        return [NSSet setWithObjects:label, [label stringByReplacingOccurrencesOfString:@" " withString:@""], nil];
    }
    return JCFOriginalGetter(self, _cmd, gOrigAliases);
}

static void JCFSetButtonLabel(id button, NSString *label) {
    if (!button || label.length == 0) {
        return;
    }

    NSString *oldLabel = JCFLabelForButton(button);
    if (![oldLabel isEqualToString:label]) {
        objc_setAssociatedObject(button, &kJCFButtonLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSLog(@"[JoyConFix] label %@ -> %p", label, button);
    }
}

static void JCFLabelButtonDictionary(NSDictionary *buttons) {
    for (NSString *key in buttons) {
        id button = buttons[key];
        if ([key isKindOfClass:NSString.class] && button) {
            JCFSetButtonLabel(button, key);
        }
    }
}

static void JCFLabelController(GCController *controller) {
    if (!JCFLooksLikeJoyConController(controller)) {
        return;
    }

    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(profile, NSSelectorFromString(@"buttons"));
    if ([buttons isKindOfClass:NSDictionary.class]) {
        JCFLabelButtonDictionary((NSDictionary *)buttons);
    }

    GCExtendedGamepad *extended = controller.extendedGamepad;
    if (extended) {
        JCFSetButtonLabel(extended.buttonA, @"Button A");
        JCFSetButtonLabel(extended.buttonB, @"Button B");
        JCFSetButtonLabel(extended.buttonX, @"Button X");
        JCFSetButtonLabel(extended.buttonY, @"Button Y");
        JCFSetButtonLabel(extended.leftShoulder, @"Left Shoulder");
        JCFSetButtonLabel(extended.rightShoulder, @"Right Shoulder");
        JCFSetButtonLabel(extended.leftTrigger, @"Left Trigger");
        JCFSetButtonLabel(extended.rightTrigger, @"Right Trigger");
    }
}

static void JCFLabelAllControllers(void) {
    for (GCController *controller in [GCController controllers]) {
        JCFLabelController(controller);
    }
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

        JCFSwizzle(GCControllerButtonInput.class, NSSelectorFromString(@"localizedName"), (IMP)JCFButtonLocalizedName, &gOrigLocalizedName);
        JCFSwizzle(GCControllerButtonInput.class, NSSelectorFromString(@"unmappedLocalizedName"), (IMP)JCFButtonUnmappedLocalizedName, &gOrigUnmappedLocalizedName);
        JCFSwizzle(GCControllerButtonInput.class, NSSelectorFromString(@"sfSymbolsName"), (IMP)JCFButtonSfSymbolsName, &gOrigSfSymbolsName);
        JCFSwizzle(GCControllerButtonInput.class, NSSelectorFromString(@"name"), (IMP)JCFButtonName, &gOrigName);
        JCFSwizzle(GCControllerButtonInput.class, NSSelectorFromString(@"aliases"), (IMP)JCFButtonAliases, &gOrigAliases);

        NSLog(@"[JoyConFix] label patch loaded");

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
