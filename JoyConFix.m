#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>

/*
 JoyConFix.m - polling diagnostic

 This build does not modify controller input at all.
 It does not swizzle button value/isPressed, does not install handlers, and
 does not rotate sticks.

 It polls GameController button objects and logs changes. Search for:

   [JoyConPoll]

 Test order:
 A, B, X, Y, SL, SR, then each stick direction once.
*/

static NSMutableDictionary<NSString *, NSNumber *> *gLastValues;
static NSMutableDictionary<NSString *, NSNumber *> *gLastPressed;
static dispatch_source_t gTimer;

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

static NSString *JCFNameForButton(id button) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (NSString *selectorName in @[@"localizedName", @"unmappedLocalizedName", @"sfSymbolsName", @"name"]) {
        id value = JCFCallId(button, NSSelectorFromString(selectorName));
        if (value) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", selectorName, JCFString(value)]];
        }
    }

    id aliases = JCFCallId(button, NSSelectorFromString(@"aliases"));
    if (aliases) {
        [parts addObject:[NSString stringWithFormat:@"aliases=%@", aliases]];
    }

    return parts.count ? [parts componentsJoinedByString:@" "] : NSStringFromClass([button class]);
}

static float JCFButtonValue(id button) {
    if (!button || ![button respondsToSelector:@selector(value)]) {
        return 0.0f;
    }
    return ((float (*)(id, SEL))objc_msgSend)(button, @selector(value));
}

static BOOL JCFButtonPressed(id button) {
    if (!button || ![button respondsToSelector:@selector(isPressed)]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(button, @selector(isPressed));
}

static void JCFObserveButton(NSString *label, id button) {
    if (!button) {
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%p:%@", button, label];
    float value = JCFButtonValue(button);
    BOOL pressed = JCFButtonPressed(button);

    NSNumber *oldValueNumber = gLastValues[key];
    NSNumber *oldPressedNumber = gLastPressed[key];
    float oldValue = oldValueNumber ? oldValueNumber.floatValue : -999.0f;
    BOOL oldPressed = oldPressedNumber ? oldPressedNumber.boolValue : NO;

    BOOL changed = !oldValueNumber || fabsf(oldValue - value) > 0.01f || oldPressed != pressed;
    gLastValues[key] = @(value);
    gLastPressed[key] = @(pressed);

    if (!changed) {
        return;
    }

    if (pressed || value > 0.10f || oldPressed || oldValue > 0.10f) {
        NSLog(@"[JoyConPoll] %@ value=%.3f pressed=%@ %@",
              label,
              value,
              pressed ? @"YES" : @"NO",
              JCFNameForButton(button));
    }
}

static void JCFObserveDictionary(NSString *prefix, NSDictionary *dictionary) {
    NSArray *keys = [[dictionary allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (id key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(value)] || [value respondsToSelector:@selector(isPressed)]) {
            JCFObserveButton([NSString stringWithFormat:@"%@.%@", prefix, key], value);
        }
    }
}

static void JCFObserveController(GCController *controller, NSUInteger index) {
    NSString *controllerLabel = [NSString stringWithFormat:@"c%lu", (unsigned long)index];

    GCExtendedGamepad *extended = controller.extendedGamepad;
    if (extended) {
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.buttonA"], extended.buttonA);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.buttonB"], extended.buttonB);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.buttonX"], extended.buttonX);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.buttonY"], extended.buttonY);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.leftShoulder"], extended.leftShoulder);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.rightShoulder"], extended.rightShoulder);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.leftTrigger"], extended.leftTrigger);
        JCFObserveButton([controllerLabel stringByAppendingString:@".extended.rightTrigger"], extended.rightTrigger);
    }

    GCMicroGamepad *micro = controller.microGamepad;
    if (micro) {
        JCFObserveButton([controllerLabel stringByAppendingString:@".micro.buttonA"], micro.buttonA);
        JCFObserveButton([controllerLabel stringByAppendingString:@".micro.buttonX"], micro.buttonX);
    }

    id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
    id buttons = JCFCallId(profile, NSSelectorFromString(@"buttons"));
    if ([buttons isKindOfClass:NSDictionary.class]) {
        JCFObserveDictionary([controllerLabel stringByAppendingString:@".physical"], buttons);
    }

    id elements = JCFCallId(profile, NSSelectorFromString(@"elements"));
    if ([elements isKindOfClass:NSDictionary.class]) {
        JCFObserveDictionary([controllerLabel stringByAppendingString:@".element"], elements);
    }
}

static void JCFPoll(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    NSUInteger index = 0;
    for (GCController *controller in controllers) {
        JCFObserveController(controller, index);
        index++;
    }
}

static void JCFDumpControllers(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    NSLog(@"[JoyConPoll] controllers=%lu", (unsigned long)controllers.count);
    NSUInteger index = 0;
    for (GCController *controller in controllers) {
        NSLog(@"[JoyConPoll] c%lu vendorName=%@ productCategory=%@",
              (unsigned long)index,
              controller.vendorName,
              controller.productCategory);

        id profile = JCFCallId(controller, NSSelectorFromString(@"physicalInputProfile"));
        id buttons = JCFCallId(profile, NSSelectorFromString(@"buttons"));
        if ([buttons isKindOfClass:NSDictionary.class]) {
            NSLog(@"[JoyConPoll] c%lu physical.keys=%@",
                  (unsigned long)index,
                  [[(NSDictionary *)buttons allKeys] componentsJoinedByString:@", "]);
        }

        index++;
    }
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY | RTLD_GLOBAL);

        gLastValues = [NSMutableDictionary dictionary];
        gLastPressed = [NSMutableDictionary dictionary];

        NSLog(@"[JoyConPoll] polling diagnostic loaded");

        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *notification) {
            JCFDumpControllers();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFDumpControllers();
        });

        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{
            JCFPoll();
        });
        dispatch_resume(gTimer);
    }
}
