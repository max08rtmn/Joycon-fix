#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>

/*
 JoyConFix.m - Joy-Con R dpad-face remap + stronger correct-controller bypass

 Your latest log showed:
   --correct-controller
   --controller-type-1
   JoyconRight

 So the previous D-pad remap was active, but MeloNX/Ryujinx still ran its own
 controller correction afterwards. This build combines both:
 - keep MeloNX's selected controller type unchanged
 - disable likely correct-controller settings from NSUserDefaults/NSProcessInfo
 - strip exactly "--correct-controller" from Foundation arrays while args are built
 - remap Joy-Con R physical D-pad entries to the real A/B/X/Y buttons

 It does not spoof controller identity, force ControllerTypesForID, rotate
 sticks, hook value/isPressed, or alter raw HID reports.

 Search the log for:
   [JoyConStrip]
*/

static IMP gOrigPhysicalButtons;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigDefaultsBoolForKey;
static IMP gOrigProcessArguments;
static IMP gOrigMutableArrayAddObject;
static IMP gOrigMutableArrayInsertObject;
static IMP gOrigMutableArraySetObjectAtIndexedSubscript;
static IMP gOrigMutableArrayReplaceObjectAtIndex;
static IMP gOrigArrayWithObjectsCount;
static IMP gOrigArrayInitWithObjectsCount;

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

static BOOL JCFTextLooksLikeRightJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return ([lower containsString:@"joy-con"] || [lower containsString:@"joycon"]) &&
           ([lower containsString:@"(r)"] || [lower containsString:@"right"] || [lower containsString:@" r"]);
}

static BOOL JCFProfileBelongsToRightJoyCon(id profile) {
    for (GCController *controller in [GCController controllers]) {
        id physical = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
        if (physical != profile) {
            continue;
        }

        NSString *combined = [NSString stringWithFormat:@"%@ %@",
                              JCFString(JCFCallId(controller, @selector(vendorName))),
                              JCFString(JCFCallId(controller, @selector(productCategory)))];
        if (JCFTextLooksLikeRightJoyCon(combined)) {
            return YES;
        }
    }

    return NO;
}

static BOOL JCFHasFaceButtons(NSDictionary *buttons) {
    return [buttons objectForKey:@"Button A"] &&
           [buttons objectForKey:@"Button B"] &&
           [buttons objectForKey:@"Button X"] &&
           [buttons objectForKey:@"Button Y"];
}

static void JCFSetAlias(NSMutableDictionary *dict, NSString *alias, NSString *source) {
    id button = [dict objectForKey:source];
    if (button) {
        [dict setObject:button forKey:alias];
    }
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    NSDictionary *original = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;
    if (![original isKindOfClass:NSDictionary.class] ||
        !JCFHasFaceButtons(original) ||
        !JCFProfileBelongsToRightJoyCon(self)) {
        return original;
    }

    NSMutableDictionary *fixed = [original mutableCopy];

    JCFSetAlias(fixed, @"Direction Pad Up", @"Button X");
    JCFSetAlias(fixed, @"Direction Pad Right", @"Button A");
    JCFSetAlias(fixed, @"Direction Pad Down", @"Button B");
    JCFSetAlias(fixed, @"Direction Pad Left", @"Button Y");

    JCFSetAlias(fixed, @"D-Pad Up", @"Button X");
    JCFSetAlias(fixed, @"D-Pad Right", @"Button A");
    JCFSetAlias(fixed, @"D-Pad Down", @"Button B");
    JCFSetAlias(fixed, @"D-Pad Left", @"Button Y");

    JCFSetAlias(fixed, @"Up", @"Button X");
    JCFSetAlias(fixed, @"Right", @"Button A");
    JCFSetAlias(fixed, @"Down", @"Button B");
    JCFSetAlias(fixed, @"Left", @"Button Y");

    JCFSetAlias(fixed, @"A Button", @"Button A");
    JCFSetAlias(fixed, @"B Button", @"Button B");
    JCFSetAlias(fixed, @"X Button", @"Button X");
    JCFSetAlias(fixed, @"Y Button", @"Button Y");

    JCFSetAlias(fixed, @"SL", @"Left Shoulder");
    JCFSetAlias(fixed, @"L", @"Left Shoulder");
    JCFSetAlias(fixed, @"L1", @"Left Shoulder");
    JCFSetAlias(fixed, @"Left Bumper", @"Left Shoulder");
    JCFSetAlias(fixed, @"SR", @"Right Shoulder");
    JCFSetAlias(fixed, @"R", @"Right Shoulder");
    JCFSetAlias(fixed, @"R1", @"Right Shoulder");
    JCFSetAlias(fixed, @"Right Bumper", @"Right Shoulder");

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConStrip] remapped Joy-Con R physical buttons original=%lu fixed=%lu A=%p B=%p X=%p Y=%p up=%p right=%p down=%p left=%p",
              (unsigned long)original.count,
              (unsigned long)fixed.count,
              [fixed objectForKey:@"Button A"],
              [fixed objectForKey:@"Button B"],
              [fixed objectForKey:@"Button X"],
              [fixed objectForKey:@"Button Y"],
              [fixed objectForKey:@"Direction Pad Up"],
              [fixed objectForKey:@"Direction Pad Right"],
              [fixed objectForKey:@"Direction Pad Down"],
              [fixed objectForKey:@"Direction Pad Left"]);
    }

    return fixed;
}

static BOOL JCFIsCorrectControllerArg(id value) {
    return [value isKindOfClass:NSString.class] &&
           [(NSString *)value isEqualToString:@"--correct-controller"];
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
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConStrip] disabled %@ object", key);
        return @NO;
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConStrip] disabled %@ string", key);
        return @"false";
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static BOOL JCFDefaultsBoolForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConStrip] disabled %@ bool", key);
        return NO;
    }
    return gOrigDefaultsBoolForKey ? ((BOOL (*)(id, SEL, id))gOrigDefaultsBoolForKey)(self, _cmd, key) : NO;
}

static id JCFProcessArguments(id self, SEL _cmd) {
    NSArray *arguments = gOrigProcessArguments ? ((id (*)(id, SEL))gOrigProcessArguments)(self, _cmd) : nil;
    if (![arguments isKindOfClass:NSArray.class]) {
        return arguments;
    }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:arguments.count];
    BOOL removed = NO;
    for (id arg in arguments) {
        if (JCFIsCorrectControllerArg(arg)) {
            removed = YES;
            continue;
        }
        [filtered addObject:arg];
    }

    if (removed) {
        NSLog(@"[JoyConStrip] removed --correct-controller from NSProcessInfo arguments");
        return filtered;
    }
    return arguments;
}

static void JCFMutableArrayAddObject(id self, SEL _cmd, id object) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConStrip] dropped --correct-controller from NSMutableArray addObject");
        return;
    }
    ((void (*)(id, SEL, id))gOrigMutableArrayAddObject)(self, _cmd, object);
}

static void JCFMutableArrayInsertObject(id self, SEL _cmd, id object, NSUInteger index) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConStrip] dropped --correct-controller from NSMutableArray insertObject");
        return;
    }
    ((void (*)(id, SEL, id, NSUInteger))gOrigMutableArrayInsertObject)(self, _cmd, object, index);
}

static void JCFMutableArraySetObjectAtIndexedSubscript(id self, SEL _cmd, id object, NSUInteger index) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConStrip] dropped --correct-controller from NSMutableArray subscript set");
        return;
    }
    ((void (*)(id, SEL, id, NSUInteger))gOrigMutableArraySetObjectAtIndexedSubscript)(self, _cmd, object, index);
}

static void JCFMutableArrayReplaceObjectAtIndex(id self, SEL _cmd, NSUInteger index, id object) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConStrip] replaced --correct-controller with empty arg");
        object = @"";
    }
    ((void (*)(id, SEL, NSUInteger, id))gOrigMutableArrayReplaceObjectAtIndex)(self, _cmd, index, object);
}

static NSUInteger JCFFilterObjects(const id objects[], NSUInteger count, __unsafe_unretained id *buffer, BOOL *removedOut) {
    NSUInteger fixedCount = 0;
    BOOL removed = NO;

    for (NSUInteger i = 0; i < count; i++) {
        id object = objects[i];
        if (JCFIsCorrectControllerArg(object)) {
            removed = YES;
            continue;
        }
        buffer[fixedCount++] = object;
    }

    if (removedOut) {
        *removedOut = removed;
    }
    return fixedCount;
}

static id JCFArrayWithObjectsCount(id self, SEL _cmd, const id objects[], NSUInteger count) {
    if (!objects || count == 0) {
        return ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayWithObjectsCount)(self, _cmd, objects, count);
    }

    __unsafe_unretained id *buffer = (__unsafe_unretained id *)calloc(count, sizeof(id));
    if (!buffer) {
        return ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayWithObjectsCount)(self, _cmd, objects, count);
    }

    BOOL removed = NO;
    NSUInteger fixedCount = JCFFilterObjects(objects, count, buffer, &removed);
    id result = ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayWithObjectsCount)(self, _cmd, removed ? buffer : objects, removed ? fixedCount : count);
    if (removed) {
        NSLog(@"[JoyConStrip] removed --correct-controller from NSArray arrayWithObjects:count:");
    }
    free(buffer);
    return result;
}

static id JCFArrayInitWithObjectsCount(id self, SEL _cmd, const id objects[], NSUInteger count) {
    if (!objects || count == 0) {
        return ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayInitWithObjectsCount)(self, _cmd, objects, count);
    }

    __unsafe_unretained id *buffer = (__unsafe_unretained id *)calloc(count, sizeof(id));
    if (!buffer) {
        return ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayInitWithObjectsCount)(self, _cmd, objects, count);
    }

    BOOL removed = NO;
    NSUInteger fixedCount = JCFFilterObjects(objects, count, buffer, &removed);
    id result = ((id (*)(id, SEL, const id [], NSUInteger))gOrigArrayInitWithObjectsCount)(self, _cmd, removed ? buffer : objects, removed ? fixedCount : count);
    if (removed) {
        NSLog(@"[JoyConStrip] removed --correct-controller from NSArray initWithObjects:count:");
    }
    free(buffer);
    return result;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConStrip] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConStrip] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFHookArrayFactory(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getClassMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConStrip] missing +[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConStrip] hooked +[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFHookMutableArrayClass(Class cls) {
    if (!cls) {
        return;
    }
    JCFSwizzle(cls, @selector(addObject:), (IMP)JCFMutableArrayAddObject, &gOrigMutableArrayAddObject);
    JCFSwizzle(cls, @selector(insertObject:atIndex:), (IMP)JCFMutableArrayInsertObject, &gOrigMutableArrayInsertObject);
    JCFSwizzle(cls, @selector(setObject:atIndexedSubscript:), (IMP)JCFMutableArraySetObjectAtIndexedSubscript, &gOrigMutableArraySetObjectAtIndexedSubscript);
    JCFSwizzle(cls, @selector(replaceObjectAtIndex:withObject:), (IMP)JCFMutableArrayReplaceObjectAtIndex, &gOrigMutableArrayReplaceObjectAtIndex);
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        NSLog(@"[JoyConStrip] LOAD MARKER 2026-06-28-strip-correct-dpad");
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(boolForKey:), (IMP)JCFDefaultsBoolForKey, &gOrigDefaultsBoolForKey);
        JCFSwizzle(NSProcessInfo.class, @selector(arguments), (IMP)JCFProcessArguments, &gOrigProcessArguments);

        JCFHookArrayFactory(NSArray.class, @selector(arrayWithObjects:count:), (IMP)JCFArrayWithObjectsCount, &gOrigArrayWithObjectsCount);
        JCFSwizzle(NSArray.class, @selector(initWithObjects:count:), (IMP)JCFArrayInitWithObjectsCount, &gOrigArrayInitWithObjectsCount);

        Class mutableConcreteClass = object_getClass([NSMutableArray array]);
        JCFHookMutableArrayClass(mutableConcreteClass);

        NSLog(@"[JoyConStrip] ready");
    }
}
