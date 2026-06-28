#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/*
 JoyConFix.m - MeloNX controller correction bypass, identity-neutral build

 The diagnostics showed:
 - iOS/GameController sees the separated fake Joy-Con buttons separately.
 - MeloNX can read Button A/B/X/Y and Left/Right Shoulder separately.
 - The broken step is after that, in MeloNX/Ryujinx controller correction
   or controller-type routing.

 This build intentionally does not spoof vendorName/productCategory, so the
 controller can still appear as Joy-Con R/L instead of Xbox Wireless Controller.
 It only forces MeloNX's stored controller type to ProController and disables
 likely "correct controller" flags.

 It does not touch button values, stick values, labels, or object classes.
*/

static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsDataForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigDefaultsBoolForKey;

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

static BOOL JCFIsControllerTypesKey(id key) {
    return [key isKindOfClass:NSString.class] && [(NSString *)key isEqualToString:@"ControllerTypesForID"];
}

static BOOL JCFIsCorrectControllerKey(id key) {
    if (![key isKindOfClass:NSString.class]) {
        return NO;
    }

    NSString *lower = [(NSString *)key lowercaseString];
    NSString *compact = [[lower stringByReplacingOccurrencesOfString:@"-" withString:@""]
                         stringByReplacingOccurrencesOfString:@"_" withString:@""];

    return ([compact containsString:@"correct"] && [compact containsString:@"controller"]) ||
           [lower isEqualToString:@"correct-controller"] ||
           [lower isEqualToString:@"correct_controller"] ||
           [lower isEqualToString:@"correctcontroller"];
}

static id JCFDefaultsObjectForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        NSLog(@"[JoyConFix] forcing %@ to ProController", key);
        return JCFForcedControllerTypesData();
    }
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConFix] disabled %@", key);
        return @NO;
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsDataForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        NSLog(@"[JoyConFix] forcing %@ data to ProController", key);
        return JCFForcedControllerTypesData();
    }
    return gOrigDefaultsDataForKey ? ((id (*)(id, SEL, id))gOrigDefaultsDataForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsControllerTypesKey(key)) {
        NSLog(@"[JoyConFix] forcing %@ string to ProController", key);
        return JCFForcedControllerTypesString();
    }
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConFix] disabled %@ string", key);
        return @"false";
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static BOOL JCFDefaultsBoolForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConFix] disabled %@ bool", key);
        return NO;
    }
    return gOrigDefaultsBoolForKey ? ((BOOL (*)(id, SEL, id))gOrigDefaultsBoolForKey)(self, _cmd, key) : NO;
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
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(dataForKey:), (IMP)JCFDefaultsDataForKey, &gOrigDefaultsDataForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(boolForKey:), (IMP)JCFDefaultsBoolForKey, &gOrigDefaultsBoolForKey);

        NSLog(@"[JoyConFix] identity-neutral ProController routing fix loaded");
    }
}
