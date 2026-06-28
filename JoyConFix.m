#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - fake Joy-Con separated-mode fix attempt for MeloNX/LiveContainer

 What this build does:
 - patches MeloNX config.json and config-pergame.json so nintendoinput = false
 - removes --correct-controller from process arguments/config additionalArgs
 - keeps a small GameController bridge for right Joy-Con face/shoulder buttons

 It does not rotate sticks and does not spoof the controller name.

 Search the MeloNX log for:
   [JoyConNintendoOff]
   [JoyConBridge]
*/

static IMP gOrigPhysicalButtons;
static IMP gOrigProcessArguments;
static IMP gOrigDefaultsObjectForKey;
static IMP gOrigDefaultsStringForKey;
static IMP gOrigDefaultsBoolForKey;
static IMP gOrigControllerGamepad;
static IMP gOrigControllerMicroGamepad;
static IMP gOrigGamepadButtonA;
static IMP gOrigGamepadButtonB;
static IMP gOrigGamepadButtonX;
static IMP gOrigGamepadButtonY;
static IMP gOrigGamepadLeftShoulder;
static IMP gOrigGamepadRightShoulder;
static IMP gOrigMicroButtonA;
static IMP gOrigMicroButtonX;

static const void *kJCFButtonMapKey = &kJCFButtonMapKey;
static BOOL gJCFConfigPatchSucceeded;
static NSUInteger gJCFConfigPatchAttempts;

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

static BOOL JCFTextLooksLikeJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"joy-con"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"wireless gamepad"];
}

static BOOL JCFTextLooksLikeRightJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    if (!JCFTextLooksLikeJoyCon(lower)) {
        return NO;
    }
    return [lower containsString:@"(r)"] ||
           [lower containsString:@"right"] ||
           [lower hasSuffix:@" r"] ||
           [lower containsString:@" joy-con r"] ||
           [lower containsString:@"joycon r"] ||
           [lower containsString:@"productid = 8199"];
}

static BOOL JCFControllerLooksLikeRightJoyCon(id controller) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@",
                          JCFString(JCFCallId(controller, @selector(vendorName))),
                          JCFString(JCFCallId(controller, @selector(productCategory)))];
    return JCFTextLooksLikeRightJoyCon(combined);
}

static BOOL JCFProfileBelongsToRightJoyCon(id profile) {
    for (GCController *controller in [GCController controllers]) {
        id physical = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
        if (physical != profile) {
            continue;
        }
        if (JCFControllerLooksLikeRightJoyCon(controller)) {
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
    return ([compact containsString:@"correct"] && [compact containsString:@"controller"]);
}

static BOOL JCFPatchConfigDictionary(NSMutableDictionary *dict, BOOL forceNintendoInputKey) {
    BOOL changed = NO;

    id nintendoInput = [dict objectForKey:@"nintendoinput"];
    if (forceNintendoInputKey || nintendoInput) {
        if (![nintendoInput isKindOfClass:NSNumber.class] || [nintendoInput boolValue]) {
            [dict setObject:@NO forKey:@"nintendoinput"];
            changed = YES;
        }
    }

    id additionalArgs = [dict objectForKey:@"additionalArgs"];
    if ([additionalArgs isKindOfClass:NSArray.class]) {
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:[additionalArgs count]];
        BOOL removed = NO;
        for (id arg in (NSArray *)additionalArgs) {
            if (JCFIsCorrectControllerArg(arg)) {
                removed = YES;
                continue;
            }
            [filtered addObject:arg];
        }
        if (removed) {
            [dict setObject:filtered forKey:@"additionalArgs"];
            changed = YES;
        }
    }

    return changed;
}

static BOOL JCFPatchJSONTree(id object, BOOL forceRoot) {
    if ([object isKindOfClass:NSMutableDictionary.class]) {
        BOOL changed = JCFPatchConfigDictionary((NSMutableDictionary *)object, forceRoot);
        for (id key in [(NSMutableDictionary *)object allKeys]) {
            id child = [(NSMutableDictionary *)object objectForKey:key];
            changed |= JCFPatchJSONTree(child, NO);
        }
        return changed;
    }

    if ([object isKindOfClass:NSMutableArray.class]) {
        BOOL changed = NO;
        for (id child in (NSMutableArray *)object) {
            changed |= JCFPatchJSONTree(child, NO);
        }
        return changed;
    }

    return NO;
}

static id JCFMutableJSONFromFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length) {
        return nil;
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:&error];
    if (!object) {
        NSLog(@"[JoyConNintendoOff] json_read_failed path=%@ error=%@", path, error);
    }
    return object;
}

static BOOL JCFWriteJSONToFile(id object, NSString *path) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        NSLog(@"[JoyConNintendoOff] json_invalid path=%@", path);
        return NO;
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (!data) {
        NSLog(@"[JoyConNintendoOff] json_write_prepare_failed path=%@ error=%@", path, error);
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *backupPath = [path stringByAppendingString:@".joyconfix.bak"];
    if (![fm fileExistsAtPath:backupPath] && [fm fileExistsAtPath:path]) {
        [fm copyItemAtPath:path toPath:backupPath error:nil];
    }

    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!ok) {
        NSLog(@"[JoyConNintendoOff] json_write_failed path=%@ error=%@", path, error);
    }
    return ok;
}

static BOOL JCFPatchOneJSONFile(NSString *path, BOOL forceRoot) {
    id object = JCFMutableJSONFromFile(path);
    if (!object) {
        NSLog(@"[JoyConNintendoOff] missing path=%@", path);
        NSLog(@"[JoyConBridge] HARD-MARKER config missing path=%@", path);
        return NO;
    }

    BOOL changed = JCFPatchJSONTree(object, forceRoot);
    if (!changed) {
        NSLog(@"[JoyConNintendoOff] unchanged path=%@", path);
        NSLog(@"[JoyConBridge] HARD-MARKER config unchanged path=%@", path);
        return YES;
    }

    BOOL ok = JCFWriteJSONToFile(object, path);
    NSLog(@"[JoyConNintendoOff] patched=%@ path=%@", ok ? @"YES" : @"NO", path);
    NSLog(@"[JoyConBridge] HARD-MARKER config patched=%@ path=%@", ok ? @"YES" : @"NO", path);
    return YES;
}

static void JCFPatchMeloNXConfigFiles(void) {
    if (gJCFConfigPatchSucceeded) {
        return;
    }

    gJCFConfigPatchAttempts++;

    NSString *home = NSHomeDirectory();
    if (!home.length) {
        NSLog(@"[JoyConNintendoOff] no_home_directory");
        return;
    }

    NSLog(@"[JoyConNintendoOff] attempt=%lu home=%@", (unsigned long)gJCFConfigPatchAttempts, home);
    NSLog(@"[JoyConBridge] HARD-MARKER config attempt=%lu home=%@", (unsigned long)gJCFConfigPatchAttempts, home);
    BOOL sawGlobal = JCFPatchOneJSONFile([home stringByAppendingPathComponent:@"Documents/config.json"], YES);
    BOOL sawPergame = JCFPatchOneJSONFile([home stringByAppendingPathComponent:@"Documents/config-pergame.json"], NO);

    gJCFConfigPatchSucceeded = sawGlobal || sawPergame;
    if (!gJCFConfigPatchSucceeded) {
        NSLog(@"[JoyConNintendoOff] will_retry_when_controller_is_seen");
    }
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

    NSLog(@"[JoyConBridge] HARD-MARKER config patch called from physical buttons");
    JCFPatchMeloNXConfigFiles();

    NSMutableDictionary *fixed = [original mutableCopy];

    JCFSetAlias(fixed, @"Direction Pad Up", @"Button X");
    JCFSetAlias(fixed, @"Direction Pad Right", @"Button A");
    JCFSetAlias(fixed, @"Direction Pad Down", @"Button B");
    JCFSetAlias(fixed, @"Direction Pad Left", @"Button Y");
    JCFSetAlias(fixed, @"D-Pad Up", @"Button X");
    JCFSetAlias(fixed, @"D-Pad Right", @"Button A");
    JCFSetAlias(fixed, @"D-Pad Down", @"Button B");
    JCFSetAlias(fixed, @"D-Pad Left", @"Button Y");
    JCFSetAlias(fixed, @"SL", @"Left Shoulder");
    JCFSetAlias(fixed, @"L", @"Left Shoulder");
    JCFSetAlias(fixed, @"L1", @"Left Shoulder");
    JCFSetAlias(fixed, @"SR", @"Right Shoulder");
    JCFSetAlias(fixed, @"R", @"Right Shoulder");
    JCFSetAlias(fixed, @"R1", @"Right Shoulder");

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConBridge] physical_buttons_mapped count=%lu A=%p B=%p X=%p Y=%p L=%p R=%p",
              (unsigned long)fixed.count,
              [fixed objectForKey:@"Button A"],
              [fixed objectForKey:@"Button B"],
              [fixed objectForKey:@"Button X"],
              [fixed objectForKey:@"Button Y"],
              [fixed objectForKey:@"Left Shoulder"],
              [fixed objectForKey:@"Right Shoulder"]);
    }

    return fixed;
}

static NSDictionary *JCFPhysicalButtonsForController(id controller) {
    id physical = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    NSDictionary *buttons = JCFCallId(physical, @selector(buttons));
    if (![buttons isKindOfClass:NSDictionary.class] || !JCFHasFaceButtons(buttons)) {
        return nil;
    }
    return buttons;
}

static id JCFMappedButton(id gamepad, NSString *key, IMP original, SEL selector) {
    NSDictionary *buttons = objc_getAssociatedObject(gamepad, kJCFButtonMapKey);
    id button = [buttons objectForKey:key];
    if (button) {
        return button;
    }
    return original ? ((id (*)(id, SEL))original)(gamepad, selector) : nil;
}

static id JCFGamepadButtonA(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button A", gOrigGamepadButtonA, _cmd);
}

static id JCFGamepadButtonB(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button B", gOrigGamepadButtonB, _cmd);
}

static id JCFGamepadButtonX(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button X", gOrigGamepadButtonX, _cmd);
}

static id JCFGamepadButtonY(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button Y", gOrigGamepadButtonY, _cmd);
}

static id JCFGamepadLeftShoulder(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Left Shoulder", gOrigGamepadLeftShoulder, _cmd);
}

static id JCFGamepadRightShoulder(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Right Shoulder", gOrigGamepadRightShoulder, _cmd);
}

static id JCFMicroButtonA(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button A", gOrigMicroButtonA, _cmd);
}

static id JCFMicroButtonX(id self, SEL _cmd) {
    return JCFMappedButton(self, @"Button X", gOrigMicroButtonX, _cmd);
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConBridge] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }

    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConBridge] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

static void JCFHookGamepadClass(Class cls) {
    static NSMutableSet *hookedClasses;
    if (!hookedClasses) {
        hookedClasses = [NSMutableSet set];
    }
    if (!cls) {
        return;
    }

    NSString *className = NSStringFromClass(cls);
    if ([hookedClasses containsObject:className]) {
        return;
    }
    [hookedClasses addObject:className];

    JCFSwizzle(cls, @selector(buttonA), (IMP)JCFGamepadButtonA, &gOrigGamepadButtonA);
    JCFSwizzle(cls, @selector(buttonB), (IMP)JCFGamepadButtonB, &gOrigGamepadButtonB);
    JCFSwizzle(cls, @selector(buttonX), (IMP)JCFGamepadButtonX, &gOrigGamepadButtonX);
    JCFSwizzle(cls, @selector(buttonY), (IMP)JCFGamepadButtonY, &gOrigGamepadButtonY);
    JCFSwizzle(cls, @selector(leftShoulder), (IMP)JCFGamepadLeftShoulder, &gOrigGamepadLeftShoulder);
    JCFSwizzle(cls, @selector(rightShoulder), (IMP)JCFGamepadRightShoulder, &gOrigGamepadRightShoulder);
}

static void JCFHookMicroClass(Class cls) {
    static NSMutableSet *hookedClasses;
    if (!hookedClasses) {
        hookedClasses = [NSMutableSet set];
    }
    if (!cls) {
        return;
    }

    NSString *className = NSStringFromClass(cls);
    if ([hookedClasses containsObject:className]) {
        return;
    }
    [hookedClasses addObject:className];

    JCFSwizzle(cls, @selector(buttonA), (IMP)JCFMicroButtonA, &gOrigMicroButtonA);
    JCFSwizzle(cls, @selector(buttonX), (IMP)JCFMicroButtonX, &gOrigMicroButtonX);
}

static void JCFBridgeProfileForController(id controller, id profile, BOOL micro) {
    if (!profile || !JCFControllerLooksLikeRightJoyCon(controller)) {
        return;
    }

    NSDictionary *buttons = JCFPhysicalButtonsForController(controller);
    if (!buttons) {
        return;
    }

    NSLog(@"[JoyConBridge] HARD-MARKER config patch called from profile bridge micro=%@", micro ? @"YES" : @"NO");
    JCFPatchMeloNXConfigFiles();
    objc_setAssociatedObject(profile, kJCFButtonMapKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (micro) {
        JCFHookMicroClass(object_getClass(profile));
    } else {
        JCFHookGamepadClass(object_getClass(profile));
    }

    static BOOL loggedGamepad;
    static BOOL loggedMicro;
    if (micro && !loggedMicro) {
        loggedMicro = YES;
        NSLog(@"[JoyConBridge] bridged_micro A=%p B=%p X=%p Y=%p L=%p R=%p",
              [buttons objectForKey:@"Button A"],
              [buttons objectForKey:@"Button B"],
              [buttons objectForKey:@"Button X"],
              [buttons objectForKey:@"Button Y"],
              [buttons objectForKey:@"Left Shoulder"],
              [buttons objectForKey:@"Right Shoulder"]);
    } else if (!micro && !loggedGamepad) {
        loggedGamepad = YES;
        NSLog(@"[JoyConBridge] bridged_gamepad A=%p B=%p X=%p Y=%p L=%p R=%p",
              [buttons objectForKey:@"Button A"],
              [buttons objectForKey:@"Button B"],
              [buttons objectForKey:@"Button X"],
              [buttons objectForKey:@"Button Y"],
              [buttons objectForKey:@"Left Shoulder"],
              [buttons objectForKey:@"Right Shoulder"]);
    }
}

static id JCFControllerGamepad(id self, SEL _cmd) {
    id profile = gOrigControllerGamepad ? ((id (*)(id, SEL))gOrigControllerGamepad)(self, _cmd) : nil;
    JCFBridgeProfileForController(self, profile, NO);
    return profile;
}

static id JCFControllerMicroGamepad(id self, SEL _cmd) {
    id profile = gOrigControllerMicroGamepad ? ((id (*)(id, SEL))gOrigControllerMicroGamepad)(self, _cmd) : nil;
    JCFBridgeProfileForController(self, profile, YES);
    return profile;
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
        NSLog(@"[JoyConNintendoOff] removed --correct-controller from process arguments");
        return filtered;
    }
    return arguments;
}

static id JCFDefaultsObjectForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConNintendoOff] disabled defaults object %@", key);
        return @NO;
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConNintendoOff] disabled defaults string %@", key);
        return @"false";
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static BOOL JCFDefaultsBoolForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConNintendoOff] disabled defaults bool %@", key);
        return NO;
    }
    return gOrigDefaultsBoolForKey ? ((BOOL (*)(id, SEL, id))gOrigDefaultsBoolForKey)(self, _cmd, key) : NO;
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        NSLog(@"[JoyConBridge] HARD-MARKER 2026-06-28-config-patch-visible");
        NSLog(@"[JoyConNintendoOff] LOAD MARKER 2026-06-28-nintendoinput-off-retry");
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        JCFPatchMeloNXConfigFiles();

        JCFSwizzle(NSClassFromString(@"GCPhysicalInputProfile"), @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(NSProcessInfo.class, @selector(arguments), (IMP)JCFProcessArguments, &gOrigProcessArguments);
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(boolForKey:), (IMP)JCFDefaultsBoolForKey, &gOrigDefaultsBoolForKey);
        JCFSwizzle(GCController.class, @selector(gamepad), (IMP)JCFControllerGamepad, &gOrigControllerGamepad);
        JCFSwizzle(GCController.class, NSSelectorFromString(@"microGamepad"), (IMP)JCFControllerMicroGamepad, &gOrigControllerMicroGamepad);

        NSLog(@"[JoyConNintendoOff] ready");
    }
}
