#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

/*
 JoyConFix.m - MeloNX fake Joy-Con separated-mode handler reroute

 Fresh approach:
 - Does not rotate sticks.
 - Does not spoof Xbox/Pro Controller names.
 - Does not patch raw HID reports.
 - Watches how MeloNX registers GCControllerButtonInput handlers.
 - For Joy-Con-like controllers, reroutes MeloNX's standard button handlers
   onto the distinct buttons exposed by physicalInputProfile.buttons.

 Search the MeloNX log for:
   [JoyConFixReroute]
*/

typedef void (^JCFButtonHandler)(GCControllerButtonInput *button, float value, BOOL pressed);
typedef void (*JCFSetHandlerIMP)(id self, SEL _cmd, JCFButtonHandler handler);

static IMP gOrigSetValueChangedHandler = NULL;
static BOOL gInstallingHandler = NO;
static BOOL gDidProbeMeloNXClasses = NO;

static const void *kJCFControllerKey = &kJCFControllerKey;
static const void *kJCFSemanticKey = &kJCFSemanticKey;
static const void *kJCFCanonicalKey = &kJCFCanonicalKey;
static const void *kJCFStoredHandlerKey = &kJCFStoredHandlerKey;
static const void *kJCFDispatcherInstalledKey = &kJCFDispatcherInstalledKey;
static const void *kJCFAmbiguousCountKey = &kJCFAmbiguousCountKey;

static NSString *JCFString(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return value ? [value description] : @"";
}

static id JCFCall0(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void JCFSetHandlerRaw(GCControllerButtonInput *button, JCFButtonHandler handler) {
    if (!button || !gOrigSetValueChangedHandler) {
        return;
    }
    gInstallingHandler = YES;
    ((JCFSetHandlerIMP)gOrigSetValueChangedHandler)(button, @selector(setValueChangedHandler:), handler);
    gInstallingHandler = NO;
}

static BOOL JCFTextLooksLikeJoyCon(NSString *text) {
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"joy-con"] ||
           [lower containsString:@"joycon"] ||
           [lower containsString:@"wireless gamepad"] ||
           [lower containsString:@"nintendo"];
}

static BOOL JCFControllerLooksLikeJoyCon(GCController *controller) {
    if (!controller) {
        return NO;
    }
    NSMutableString *blob = [NSMutableString string];
    [blob appendFormat:@"%@ ", JCFString(controller.vendorName)];
    if ([controller respondsToSelector:@selector(productCategory)]) {
        [blob appendFormat:@"%@ ", JCFString(JCFCall0(controller, @selector(productCategory)))];
    }
    if ([controller respondsToSelector:@selector(debugDescription)]) {
        [blob appendFormat:@"%@ ", JCFString(controller.debugDescription)];
    }
    return JCFTextLooksLikeJoyCon(blob);
}

static GCControllerButtonInput *JCFButtonFromObject(id object, SEL selector) {
    id value = JCFCall0(object, selector);
    return [value isKindOfClass:GCControllerButtonInput.class] ? value : nil;
}

static NSDictionary *JCFPhysicalButtons(GCController *controller) {
    id profile = JCFCall0(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCall0(profile, NSSelectorFromString(@"buttons"));
    return [buttons isKindOfClass:NSDictionary.class] ? buttons : nil;
}

static GCControllerButtonInput *JCFFindPhysicalButton(GCController *controller, NSArray<NSString *> *needles) {
    NSDictionary *buttons = JCFPhysicalButtons(controller);
    for (id key in buttons) {
        NSString *lower = [JCFString(key) lowercaseString];
        BOOL ok = YES;
        for (NSString *needle in needles) {
            if (![lower containsString:[needle lowercaseString]]) {
                ok = NO;
                break;
            }
        }
        if (ok) {
            id button = buttons[key];
            if ([button isKindOfClass:GCControllerButtonInput.class]) {
                return button;
            }
        }
    }
    return nil;
}

static NSString *JCFSemanticForPhysicalKey(NSString *key) {
    NSString *lower = [key lowercaseString];
    if ([lower containsString:@"button a"] || [lower isEqualToString:@"a"]) return @"A";
    if ([lower containsString:@"button b"] || [lower isEqualToString:@"b"]) return @"B";
    if ([lower containsString:@"button x"] || [lower isEqualToString:@"x"]) return @"X";
    if ([lower containsString:@"button y"] || [lower isEqualToString:@"y"]) return @"Y";
    if ([lower containsString:@"left shoulder"] || [lower containsString:@"left bumper"]) return @"L";
    if ([lower containsString:@"right shoulder"] || [lower containsString:@"right bumper"]) return @"R";
    return nil;
}

static NSArray<NSString *> *JCFAllSemantics(void) {
    return @[@"A", @"B", @"X", @"Y", @"L", @"R"];
}

static GCControllerButtonInput *JCFCanonicalButton(GCController *controller, NSString *semantic) {
    if ([semantic isEqualToString:@"A"]) return JCFFindPhysicalButton(controller, @[@"button", @"a"]);
    if ([semantic isEqualToString:@"B"]) return JCFFindPhysicalButton(controller, @[@"button", @"b"]);
    if ([semantic isEqualToString:@"X"]) return JCFFindPhysicalButton(controller, @[@"button", @"x"]);
    if ([semantic isEqualToString:@"Y"]) return JCFFindPhysicalButton(controller, @[@"button", @"y"]);
    if ([semantic isEqualToString:@"L"]) return JCFFindPhysicalButton(controller, @[@"left", @"shoulder"]);
    if ([semantic isEqualToString:@"R"]) return JCFFindPhysicalButton(controller, @[@"right", @"shoulder"]);
    return nil;
}

static void JCFAssociateButton(GCControllerButtonInput *button, GCController *controller, NSString *semantic, BOOL canonical) {
    if (!button || !controller || !semantic) {
        return;
    }
    objc_setAssociatedObject(button, kJCFControllerKey, controller, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, kJCFSemanticKey, semantic, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (canonical) {
        objc_setAssociatedObject(button, kJCFCanonicalKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSArray<GCControllerButtonInput *> *JCFStandardButtonsForSemantic(GCController *controller, NSString *semantic) {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *profiles = @[
        JCFCall0(controller, @selector(gamepad)) ?: [NSNull null],
        JCFCall0(controller, NSSelectorFromString(@"extendedGamepad")) ?: [NSNull null],
        JCFCall0(controller, NSSelectorFromString(@"microGamepad")) ?: [NSNull null]
    ];
    SEL selectors[3];
    NSUInteger selectorCount = 0;
    if ([semantic isEqualToString:@"A"]) {
        selectors[selectorCount++] = @selector(buttonA);
    } else if ([semantic isEqualToString:@"B"]) {
        selectors[selectorCount++] = @selector(buttonB);
    } else if ([semantic isEqualToString:@"X"]) {
        selectors[selectorCount++] = @selector(buttonX);
    } else if ([semantic isEqualToString:@"Y"]) {
        selectors[selectorCount++] = @selector(buttonY);
    } else if ([semantic isEqualToString:@"L"]) {
        selectors[selectorCount++] = @selector(leftShoulder);
        selectors[selectorCount++] = NSSelectorFromString(@"leftTrigger");
    } else if ([semantic isEqualToString:@"R"]) {
        selectors[selectorCount++] = @selector(rightShoulder);
        selectors[selectorCount++] = NSSelectorFromString(@"rightTrigger");
    }
    for (id profile in profiles) {
        if ((id)profile == [NSNull null]) {
            continue;
        }
        for (NSUInteger i = 0; i < selectorCount; i++) {
            GCControllerButtonInput *button = JCFButtonFromObject(profile, selectors[i]);
            if (button && ![result containsObject:button]) {
                [result addObject:button];
            }
        }
    }
    return result;
}

static void JCFEnsureDispatcher(GCControllerButtonInput *canonical, NSString *semantic) {
    if (!canonical || !semantic) {
        return;
    }
    NSNumber *installed = objc_getAssociatedObject(canonical, kJCFDispatcherInstalledKey);
    if (installed.boolValue) {
        return;
    }
    __weak GCControllerButtonInput *weakButton = canonical;
    NSString *semanticCopy = [semantic copy];
    JCFButtonHandler dispatcher = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GCControllerButtonInput *strongButton = weakButton ?: button;
        JCFButtonHandler stored = objc_getAssociatedObject(strongButton, kJCFStoredHandlerKey);
        if (stored) {
            stored(strongButton, value, pressed);
        }
        if (pressed || value > 0.05f) {
            NSLog(@"[JoyConFixReroute] physical %@ value=%.3f pressed=%d", semanticCopy, value, pressed);
        }
    };
    objc_setAssociatedObject(canonical, kJCFDispatcherInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JCFSetHandlerRaw(canonical, dispatcher);
}

static NSUInteger JCFAmbiguousIndexForButton(GCControllerButtonInput *button) {
    NSNumber *number = objc_getAssociatedObject(button, kJCFAmbiguousCountKey);
    NSUInteger index = number ? number.unsignedIntegerValue : 0;
    objc_setAssociatedObject(button, kJCFAmbiguousCountKey, @(index + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return index;
}

static NSString *JCFSemanticForRegisteredButton(GCControllerButtonInput *button, GCController **outController) {
    GCController *controller = objc_getAssociatedObject(button, kJCFControllerKey);
    NSString *semantic = objc_getAssociatedObject(button, kJCFSemanticKey);
    if (controller && semantic) {
        if (outController) *outController = controller;
        return semantic;
    }

    for (GCController *candidate in [GCController controllers]) {
        if (!JCFControllerLooksLikeJoyCon(candidate)) {
            continue;
        }
        NSMutableArray<NSString *> *matches = [NSMutableArray array];
        for (NSString *candidateSemantic in JCFAllSemantics()) {
            for (GCControllerButtonInput *standard in JCFStandardButtonsForSemantic(candidate, candidateSemantic)) {
                if (standard == button) {
                    [matches addObject:candidateSemantic];
                    break;
                }
            }
        }
        if (matches.count == 1) {
            if (outController) *outController = candidate;
            return matches.firstObject;
        }
        if (matches.count > 1) {
            NSUInteger index = JCFAmbiguousIndexForButton(button) % matches.count;
            NSString *chosen = matches[index];
            NSLog(@"[JoyConFixReroute] ambiguous standard button matched %@; using %@ for registration #%lu",
                  [matches componentsJoinedByString:@","], chosen, (unsigned long)(index + 1));
            if (outController) *outController = candidate;
            return chosen;
        }
    }

    if (outController) *outController = nil;
    return nil;
}

static void JCFRefreshMappings(void) {
    for (GCController *controller in [GCController controllers]) {
        if (!JCFControllerLooksLikeJoyCon(controller)) {
            continue;
        }

        NSDictionary *physical = JCFPhysicalButtons(controller);
        NSMutableArray *physicalKeys = [NSMutableArray array];
        for (id key in physical) {
            NSString *semantic = JCFSemanticForPhysicalKey(JCFString(key));
            id button = physical[key];
            if (semantic && [button isKindOfClass:GCControllerButtonInput.class]) {
                JCFAssociateButton(button, controller, semantic, YES);
                [physicalKeys addObject:[NSString stringWithFormat:@"%@=%@", semantic, JCFString(key)]];
            }
        }

        for (NSString *semantic in JCFAllSemantics()) {
            GCControllerButtonInput *canonical = JCFCanonicalButton(controller, semantic);
            if (canonical) {
                JCFAssociateButton(canonical, controller, semantic, YES);
            }
            for (GCControllerButtonInput *standard in JCFStandardButtonsForSemantic(controller, semantic)) {
                JCFAssociateButton(standard, controller, semantic, NO);
            }
        }

        static NSMutableSet *loggedControllers;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            loggedControllers = [NSMutableSet set];
        });
        NSString *key = [NSString stringWithFormat:@"%p", controller];
        if (![loggedControllers containsObject:key]) {
            [loggedControllers addObject:key];
            NSLog(@"[JoyConFixReroute] controller=%@ category=%@ physical={%@}",
                  JCFString(controller.vendorName),
                  JCFString([controller respondsToSelector:@selector(productCategory)] ? JCFCall0(controller, @selector(productCategory)) : nil),
                  [physicalKeys componentsJoinedByString:@", "]);
        }
    }
}

static void JCFSetValueChangedHandler(GCControllerButtonInput *button, SEL selector, JCFButtonHandler handler) {
    if (gInstallingHandler || !gOrigSetValueChangedHandler) {
        ((JCFSetHandlerIMP)gOrigSetValueChangedHandler)(button, selector, handler);
        return;
    }

    JCFRefreshMappings();

    GCController *controller = nil;
    NSString *semantic = JCFSemanticForRegisteredButton(button, &controller);
    if (!handler || !controller || !semantic || !JCFControllerLooksLikeJoyCon(controller)) {
        ((JCFSetHandlerIMP)gOrigSetValueChangedHandler)(button, selector, handler);
        return;
    }

    GCControllerButtonInput *canonical = JCFCanonicalButton(controller, semantic);
    if (!canonical) {
        NSLog(@"[JoyConFixReroute] no physical button for semantic %@", semantic);
        ((JCFSetHandlerIMP)gOrigSetValueChangedHandler)(button, selector, handler);
        return;
    }

    JCFButtonHandler stored = [handler copy];
    objc_setAssociatedObject(canonical, kJCFStoredHandlerKey, stored, OBJC_ASSOCIATION_COPY_NONATOMIC);
    JCFEnsureDispatcher(canonical, semantic);

    if (canonical != button) {
        JCFButtonHandler suppress = ^(GCControllerButtonInput *source, float value, BOOL pressed) {
            if (pressed || value > 0.05f) {
                NSLog(@"[JoyConFixReroute] suppressed faulty standard %@ value=%.3f pressed=%d", semantic, value, pressed);
            }
        };
        JCFSetHandlerRaw(button, suppress);
        NSLog(@"[JoyConFixReroute] rerouted handler %@ standard=%p physical=%p",
              semantic, button, canonical);
    } else {
        JCFSetHandlerRaw(button, handler);
        NSLog(@"[JoyConFixReroute] kept direct handler %@ physical=%p", semantic, canonical);
    }
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConFixReroute] missing method %@ on %@", NSStringFromSelector(selector), cls);
        return;
    }
    if (originalOut) {
        *originalOut = method_getImplementation(method);
    }
    method_setImplementation(method, replacement);
    NSLog(@"[JoyConFixReroute] hooked %@ on %@", NSStringFromSelector(selector), cls);
}

static void JCFProbeClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        NSLog(@"[JoyConFixReroute] class not found %@", name);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        [names addObject:NSStringFromSelector(method_getName(methods[i]))];
    }
    free(methods);
    NSLog(@"[JoyConFixReroute] class %@ methods=%@", name, [names componentsJoinedByString:@","]);
}

static void JCFProbeMeloNXClasses(void) {
    if (gDidProbeMeloNXClasses) {
        return;
    }
    gDidProbeMeloNXClasses = YES;
    JCFProbeClass(@"_TtC6MeloNX14BaseController");
    JCFProbeClass(@"_TtC6MeloNX16NativeController");
    JCFProbeClass(@"_TtC6MeloNX17ControllerManager");
    JCFProbeClass(@"_TtC6MeloNX13RyujinxBridge");
}

__attribute__((constructor))
static void JCFInit(void) {
    @autoreleasepool {
        NSLog(@"[JoyConFixReroute] loaded 2026-06-29 handler-reroute");
        Class cls = NSClassFromString(@"GCControllerButtonInput");
        JCFSwizzle(cls, @selector(setValueChangedHandler:), (IMP)JCFSetValueChangedHandler, &gOrigSetValueChangedHandler);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFRefreshMappings();
            JCFProbeMeloNXClasses();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFRefreshMappings();
            JCFProbeMeloNXClasses();
        });
    }
}
