#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>

/*
 JoyConFix.m - Joy-Con R GameController bridge + MeloNX config scanner

 This build combines three narrow fixes:
 - keep MeloNX's selected controller type unchanged
 - disable likely correct-controller settings from NSUserDefaults/NSProcessInfo
 - strip exactly "--correct-controller" from Foundation arrays while args are built
 - remap Joy-Con R physical D-pad entries to the real A/B/X/Y buttons
 - bridge GCGamepad/GCMicroGamepad button properties to the real physical buttons

 It does not spoof controller identity, force ControllerTypesForID, rotate
 sticks, hook raw HID reports, or rename the controller.

 Search the log for:
   [JoyConBridge]
   [JoyConConfigScan]
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
static BOOL gJCFConfigScanDone;

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

static BOOL JCFControllerLooksLikeRightJoyCon(id controller) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@",
                          JCFString(JCFCallId(controller, @selector(vendorName))),
                          JCFString(JCFCallId(controller, @selector(productCategory)))];
    return JCFTextLooksLikeRightJoyCon(combined);
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
        NSLog(@"[JoyConBridge] remapped Joy-Con R physical buttons original=%lu fixed=%lu A=%p B=%p X=%p Y=%p up=%p right=%p down=%p left=%p",
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
        NSLog(@"[JoyConBridge] disabled %@ object", key);
        return @NO;
    }
    return gOrigDefaultsObjectForKey ? ((id (*)(id, SEL, id))gOrigDefaultsObjectForKey)(self, _cmd, key) : nil;
}

static id JCFDefaultsStringForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConBridge] disabled %@ string", key);
        return @"false";
    }
    return gOrigDefaultsStringForKey ? ((id (*)(id, SEL, id))gOrigDefaultsStringForKey)(self, _cmd, key) : nil;
}

static BOOL JCFDefaultsBoolForKey(id self, SEL _cmd, id key) {
    if (JCFIsCorrectControllerKey(key)) {
        NSLog(@"[JoyConBridge] disabled %@ bool", key);
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
        NSLog(@"[JoyConBridge] removed --correct-controller from NSProcessInfo arguments");
        return filtered;
    }
    return arguments;
}

static void JCFMutableArrayAddObject(id self, SEL _cmd, id object) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConBridge] dropped --correct-controller from NSMutableArray addObject");
        return;
    }
    ((void (*)(id, SEL, id))gOrigMutableArrayAddObject)(self, _cmd, object);
}

static void JCFMutableArrayInsertObject(id self, SEL _cmd, id object, NSUInteger index) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConBridge] dropped --correct-controller from NSMutableArray insertObject");
        return;
    }
    ((void (*)(id, SEL, id, NSUInteger))gOrigMutableArrayInsertObject)(self, _cmd, object, index);
}

static void JCFMutableArraySetObjectAtIndexedSubscript(id self, SEL _cmd, id object, NSUInteger index) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConBridge] dropped --correct-controller from NSMutableArray subscript set");
        return;
    }
    ((void (*)(id, SEL, id, NSUInteger))gOrigMutableArraySetObjectAtIndexedSubscript)(self, _cmd, object, index);
}

static void JCFMutableArrayReplaceObjectAtIndex(id self, SEL _cmd, NSUInteger index, id object) {
    if (JCFIsCorrectControllerArg(object)) {
        NSLog(@"[JoyConBridge] replaced --correct-controller with empty arg");
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
        NSLog(@"[JoyConBridge] removed --correct-controller from NSArray arrayWithObjects:count:");
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
        NSLog(@"[JoyConBridge] removed --correct-controller from NSArray initWithObjects:count:");
    }
    free(buffer);
    return result;
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

static void JCFHookArrayFactory(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getClassMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConBridge] missing +[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConBridge] hooked +[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
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
        NSLog(@"[JoyConBridge] bridged right Joy-Con micro profile=%@ A=%p B=%p X=%p Y=%p L=%p R=%p",
              NSStringFromClass(object_getClass(profile)),
              [buttons objectForKey:@"Button A"],
              [buttons objectForKey:@"Button B"],
              [buttons objectForKey:@"Button X"],
              [buttons objectForKey:@"Button Y"],
              [buttons objectForKey:@"Left Shoulder"],
              [buttons objectForKey:@"Right Shoulder"]);
    } else if (!micro && !loggedGamepad) {
        loggedGamepad = YES;
        NSLog(@"[JoyConBridge] bridged right Joy-Con gamepad profile=%@ A=%p B=%p X=%p Y=%p L=%p R=%p",
              NSStringFromClass(object_getClass(profile)),
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

static BOOL JCFTextContainsInputWords(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"inputconfig"] ||
           [lower containsString:@"buttona"] ||
           [lower containsString:@"button_a"] ||
           [lower containsString:@"button a"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"joy-con"] ||
           [lower containsString:@"controller"];
}

static NSString *JCFSnippetAroundNeedle(NSString *text, NSString *path) {
    NSArray *needles = @[@"InputConfig", @"ButtonA", @"button_a", @"Button A", @"Joycon", @"Joy-Con", @"Controller"];
    NSRange hit = NSMakeRange(NSNotFound, 0);

    for (NSString *needle in needles) {
        hit = [text rangeOfString:needle options:NSCaseInsensitiveSearch];
        if (hit.location != NSNotFound) {
            break;
        }
    }

    if (hit.location == NSNotFound) {
        hit = NSMakeRange(0, 0);
    }

    NSUInteger start = hit.location > 450 ? hit.location - 450 : 0;
    NSUInteger end = MIN(text.length, hit.location + 1600);
    NSString *snippet = [text substringWithRange:NSMakeRange(start, end - start)];
    snippet = [snippet stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    snippet = [snippet stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    snippet = [snippet stringByReplacingOccurrencesOfString:@"\t" withString:@" "];

    if (snippet.length > 1900) {
        snippet = [snippet substringToIndex:1900];
    }

    return [NSString stringWithFormat:@"%@ :: %@", path, snippet];
}

static BOOL JCFPathLooksInteresting(NSString *path) {
    NSString *lower = [path lowercaseString];
    NSArray *extensions = @[@".json", @".config", @".conf", @".cfg", @".ini", @".txt", @".plist", @".xml"];
    for (NSString *ext in extensions) {
        if ([lower hasSuffix:ext]) {
            return YES;
        }
    }
    return [lower containsString:@"config"] || [lower containsString:@"input"] || [lower containsString:@"ryujinx"] || [lower containsString:@"melonx"];
}

static void JCFScanOneFile(NSString *path, NSUInteger *hitCount) {
    if (!JCFPathLooksInteresting(path) || *hitCount >= 18) {
        return;
    }

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    if (size == 0 || size > 1024 * 1024) {
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length) {
        return;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!text || !JCFTextContainsInputWords(text)) {
        return;
    }

    (*hitCount)++;
    NSLog(@"[JoyConConfigScan] hit %lu %@", (unsigned long)*hitCount, JCFSnippetAroundNeedle(text, path));
}

static void JCFScanConfigFiles(void) {
    if (gJCFConfigScanDone) {
        return;
    }
    gJCFConfigScanDone = YES;

    NSString *home = NSHomeDirectory();
    if (!home.length) {
        NSLog(@"[JoyConConfigScan] no home directory");
        return;
    }

    NSLog(@"[JoyConConfigScan] start home=%@", home);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:home];
    NSUInteger hitCount = 0;
    NSUInteger checkedCount = 0;

    for (NSString *relativePath in enumerator) {
        if (hitCount >= 18 || checkedCount >= 4500) {
            break;
        }

        NSString *lower = [relativePath lowercaseString];
        if ([lower containsString:@"/caches/"] ||
            [lower containsString:@"/tmp/"] ||
            [lower containsString:@"/shader"] ||
            [lower containsString:@"/logs/"] ||
            [lower containsString:@"/screenshots/"]) {
            continue;
        }

        NSString *path = [home stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        checkedCount++;
        JCFScanOneFile(path, &hitCount);
    }

    NSLog(@"[JoyConConfigScan] done checked=%lu hits=%lu", (unsigned long)checkedCount, (unsigned long)hitCount);
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
        NSLog(@"[JoyConBridge] LOAD MARKER 2026-06-28-gamepad-bridge");
        NSLog(@"[JoyConConfigScan] LOAD MARKER 2026-06-28-config-scan");
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(NSUserDefaults.class, @selector(objectForKey:), (IMP)JCFDefaultsObjectForKey, &gOrigDefaultsObjectForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(stringForKey:), (IMP)JCFDefaultsStringForKey, &gOrigDefaultsStringForKey);
        JCFSwizzle(NSUserDefaults.class, @selector(boolForKey:), (IMP)JCFDefaultsBoolForKey, &gOrigDefaultsBoolForKey);
        JCFSwizzle(NSProcessInfo.class, @selector(arguments), (IMP)JCFProcessArguments, &gOrigProcessArguments);
        JCFSwizzle(GCController.class, @selector(gamepad), (IMP)JCFControllerGamepad, &gOrigControllerGamepad);
        JCFSwizzle(GCController.class, NSSelectorFromString(@"microGamepad"), (IMP)JCFControllerMicroGamepad, &gOrigControllerMicroGamepad);

        JCFHookArrayFactory(NSArray.class, @selector(arrayWithObjects:count:), (IMP)JCFArrayWithObjectsCount, &gOrigArrayWithObjectsCount);
        JCFSwizzle(NSArray.class, @selector(initWithObjects:count:), (IMP)JCFArrayInitWithObjectsCount, &gOrigArrayInitWithObjectsCount);

        Class mutableConcreteClass = object_getClass([NSMutableArray array]);
        JCFHookMutableArrayClass(mutableConcreteClass);

        JCFScanConfigFiles();

        NSLog(@"[JoyConBridge] ready");
    }
}
