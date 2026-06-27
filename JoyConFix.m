#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>

/*
 JoyConFix.m - button object patch build

 This keeps the working ProController spoof and additionally patches the
 concrete GCControllerButtonInput objects for A/B/X/Y/SL/SR. This is closer to
 the Gemini stick-rotation approach that worked for axes: patch the actual
 input object MeloNX may have cached, not only the profile getter.

 No stick rotation. No global value/isPressed hook. No button handlers.
*/

static char kJCFSourceButtonKey;
static char kJCFPatchedKey;

static IMP gOrigVendorName;
static IMP gOrigProductCategory;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;

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

static float JCFPatchedValue(id self, SEL _cmd) {
    id source = objc_getAssociatedObject(self, &kJCFSourceButtonKey);
    if (source && source != self && [source respondsToSelector:@selector(value)]) {
        return ((float (*)(id, SEL))objc_msgSend)(source, @selector(value));
    }

    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass(object_getClass(self))
    };
    return ((float (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, _cmd);
}

static BOOL JCFPatchedPressed(id self, SEL _cmd) {
    id source = objc_getAssociatedObject(self, &kJCFSourceButtonKey);
    if (source && source != self && [source respondsToSelector:@selector(isPressed)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(source, @selector(isPressed));
    }

    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass(object_getClass(self))
    };
    return ((BOOL (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, _cmd);
}

static Class JCFPatchedClassForButton(id button) {
    Class originalClass = object_getClass(button);
    NSString *subclassName = [NSString stringWithFormat:@"%@_JoyConButtonPatch", NSStringFromClass(originalClass)];
    Class subclass = NSClassFromString(subclassName);
    if (subclass) {
        return subclass;
    }

    subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
    if (!subclass) {
        return originalClass;
    }

    class_addMethod(subclass, @selector(value), (IMP)JCFPatchedValue, "f@:");
    class_addMethod(subclass, @selector(isPressed), (IMP)JCFPatchedPressed, "B@:");
    objc_registerClassPair(subclass);
    return subclass;
}

static void JCFPatchButtonObject(id target, id source, NSString *label) {
    if (!target || !source || target == source) {
        return;
    }

    objc_setAssociatedObject(target, &kJCFSourceButtonKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!objc_getAssociatedObject(target, &kJCFPatchedKey)) {
        object_setClass(target, JCFPatchedClassForButton(target));
        objc_setAssociatedObject(target, &kJCFPatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSLog(@"[JoyConFix] patched %@ target=%p source=%p", label, target, source);
}

static id JCFPhysicalButton(GCController *controller, NSString *key) {
    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(profile, NSSelectorFromString(@"buttons"));
    if (![buttons isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    id button = ((NSDictionary *)buttons)[key];
    if (!button && [key hasPrefix:@"Button "]) {
        button = ((NSDictionary *)buttons)[[key substringFromIndex:[@"Button " length]]];
    }
    return button;
}

static void JCFPatchController(GCController *controller) {
    if (!JCFLooksLikeJoyConController(controller)) {
        return;
    }

    GCExtendedGamepad *extended = controller.extendedGamepad;
    if (extended) {
        JCFPatchButtonObject(extended.buttonA, JCFPhysicalButton(controller, @"Button A"), @"extended.buttonA");
        JCFPatchButtonObject(extended.buttonB, JCFPhysicalButton(controller, @"Button B"), @"extended.buttonB");
        JCFPatchButtonObject(extended.buttonX, JCFPhysicalButton(controller, @"Button X"), @"extended.buttonX");
        JCFPatchButtonObject(extended.buttonY, JCFPhysicalButton(controller, @"Button Y"), @"extended.buttonY");
        JCFPatchButtonObject(extended.leftShoulder, JCFPhysicalButton(controller, @"Left Shoulder"), @"extended.leftShoulder");
        JCFPatchButtonObject(extended.rightShoulder, JCFPhysicalButton(controller, @"Right Shoulder"), @"extended.rightShoulder");
        JCFPatchButtonObject(extended.leftTrigger, JCFPhysicalButton(controller, @"Left Trigger"), @"extended.leftTrigger");
        JCFPatchButtonObject(extended.rightTrigger, JCFPhysicalButton(controller, @"Right Trigger"), @"extended.rightTrigger");
    }

    GCMicroGamepad *micro = controller.microGamepad;
    if (micro) {
        JCFPatchButtonObject(micro.buttonA, JCFPhysicalButton(controller, @"Button A"), @"micro.buttonA");
        JCFPatchButtonObject(micro.buttonX, JCFPhysicalButton(controller, @"Button X"), @"micro.buttonX");
    }
}

static void JCFPatchAllControllers(void) {
    for (GCController *controller in [GCController controllers]) {
        JCFPatchController(controller);
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

        NSLog(@"[JoyConFix] button object patch loaded");

        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
            JCFPatchController(notification.object);
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFPatchAllControllers();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFPatchAllControllers();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFPatchAllControllers();
        });
    }
}
