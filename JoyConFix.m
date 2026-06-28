#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>

/*
 JoyConFix.m - MeloNX button mapping probe

 This version is diagnostic on purpose. It does not spoof the controller name,
 does not force ControllerTypesForID, does not rotate sticks, and does not
 change button values.

 It logs:
 - which GC button object MeloNX receives for extended A/B/X/Y/L/R
 - which physical button dictionary keys exist
 - which GameController button value/isPressed changes are read
 - a short call stack when a watched button is pressed

 Search the MeloNX log for:
   [JoyConMap]
*/

static IMP gOrigValue;
static IMP gOrigIsPressed;
static IMP gOrigExtButtonA;
static IMP gOrigExtButtonB;
static IMP gOrigExtButtonX;
static IMP gOrigExtButtonY;
static IMP gOrigExtLeftShoulder;
static IMP gOrigExtRightShoulder;
static IMP gOrigPhysicalButtons;

static NSString *JCFString(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return value ? [value description] : @"";
}

static id JCFCallId(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *JCFButtonName(id button) {
    if (!button) {
        return @"<nil>";
    }

    NSArray *selectors = @[
        @"unmappedLocalizedName",
        @"localizedName",
        @"name",
        @"sfSymbolsName"
    ];

    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *selectorName in selectors) {
        id value = JCFCallId(button, NSSelectorFromString(selectorName));
        NSString *text = JCFString(value);
        if (text.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", selectorName, text]];
        }
    }

    if (parts.count == 0) {
        return [NSString stringWithFormat:@"class=%@", NSStringFromClass([button class])];
    }
    return [parts componentsJoinedByString:@" "];
}

static BOOL JCFIsWatchedButton(id button) {
    NSString *name = [JCFButtonName(button) lowercaseString];
    return [name containsString:@"button a"] ||
           [name containsString:@"button b"] ||
           [name containsString:@"button x"] ||
           [name containsString:@"button y"] ||
           [name containsString:@"left shoulder"] ||
           [name containsString:@"right shoulder"] ||
           [name containsString:@"left bumper"] ||
           [name containsString:@"right bumper"];
}

static NSString *JCFStackSummary(void) {
    NSArray *symbols = [NSThread callStackSymbols];
    NSUInteger count = MIN((NSUInteger)12, symbols.count);
    NSMutableArray *shortSymbols = [NSMutableArray arrayWithCapacity:count];

    for (NSUInteger i = 2; i < count; i++) {
        NSString *line = symbols[i];
        if ([line containsString:@"JoyConFix"] || [line containsString:@"Foundation"]) {
            continue;
        }
        [shortSymbols addObject:line];
    }

    return [shortSymbols componentsJoinedByString:@" || "];
}

static void JCFLogGetter(NSString *role, id button) {
    static NSMutableDictionary *seen;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableDictionary dictionary];
    });

    NSString *key = [NSString stringWithFormat:@"%@:%p", role, button];
    @synchronized(seen) {
        if (seen[key]) {
            return;
        }
        seen[key] = @YES;
    }

    NSLog(@"[JoyConMap] getter %@ -> ptr=%p %@", role, button, JCFButtonName(button));
}

static void JCFLogTransition(id button, NSString *kind, float value) {
    if (!JCFIsWatchedButton(button)) {
        return;
    }

    static NSMutableDictionary *lastValues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lastValues = [NSMutableDictionary dictionary];
    });

    NSString *key = [NSString stringWithFormat:@"%p:%@", button, kind];
    NSNumber *oldValue;
    @synchronized(lastValues) {
        oldValue = lastValues[key];
        if (oldValue && fabsf(oldValue.floatValue - value) < 0.001f) {
            return;
        }
        lastValues[key] = @(value);
    }

    NSLog(@"[JoyConMap] %@ ptr=%p value=%.3f %@", kind, button, value, JCFButtonName(button));
    if (value > 0.5f) {
        NSLog(@"[JoyConMap] stack ptr=%p %@", button, JCFStackSummary());
    }
}

static float JCFButtonValue(id self, SEL _cmd) {
    float value = gOrigValue ? ((float (*)(id, SEL))gOrigValue)(self, _cmd) : 0.0f;
    JCFLogTransition(self, @"value", value);
    return value;
}

static BOOL JCFButtonIsPressed(id self, SEL _cmd) {
    BOOL pressed = gOrigIsPressed ? ((BOOL (*)(id, SEL))gOrigIsPressed)(self, _cmd) : NO;
    JCFLogTransition(self, @"isPressed", pressed ? 1.0f : 0.0f);
    return pressed;
}

static id JCFExtButtonA(id self, SEL _cmd) {
    id button = gOrigExtButtonA ? ((id (*)(id, SEL))gOrigExtButtonA)(self, _cmd) : nil;
    JCFLogGetter(@"extended.buttonA", button);
    return button;
}

static id JCFExtButtonB(id self, SEL _cmd) {
    id button = gOrigExtButtonB ? ((id (*)(id, SEL))gOrigExtButtonB)(self, _cmd) : nil;
    JCFLogGetter(@"extended.buttonB", button);
    return button;
}

static id JCFExtButtonX(id self, SEL _cmd) {
    id button = gOrigExtButtonX ? ((id (*)(id, SEL))gOrigExtButtonX)(self, _cmd) : nil;
    JCFLogGetter(@"extended.buttonX", button);
    return button;
}

static id JCFExtButtonY(id self, SEL _cmd) {
    id button = gOrigExtButtonY ? ((id (*)(id, SEL))gOrigExtButtonY)(self, _cmd) : nil;
    JCFLogGetter(@"extended.buttonY", button);
    return button;
}

static id JCFExtLeftShoulder(id self, SEL _cmd) {
    id button = gOrigExtLeftShoulder ? ((id (*)(id, SEL))gOrigExtLeftShoulder)(self, _cmd) : nil;
    JCFLogGetter(@"extended.leftShoulder", button);
    return button;
}

static id JCFExtRightShoulder(id self, SEL _cmd) {
    id button = gOrigExtRightShoulder ? ((id (*)(id, SEL))gOrigExtRightShoulder)(self, _cmd) : nil;
    JCFLogGetter(@"extended.rightShoulder", button);
    return button;
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    id buttons = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;

    static BOOL logged;
    if (!logged && [buttons isKindOfClass:NSDictionary.class]) {
        logged = YES;
        NSArray *keys = [[(NSDictionary *)buttons allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSLog(@"[JoyConMap] physical buttons keys=%@", keys);
        for (id key in keys) {
            id button = [(NSDictionary *)buttons objectForKey:key];
            NSLog(@"[JoyConMap] physical %@ -> ptr=%p %@", key, button, JCFButtonName(button));
        }
    }

    return buttons;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConMap] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
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

        Class buttonClass = NSClassFromString(@"GCControllerButtonInput");
        Class extendedClass = NSClassFromString(@"GCExtendedGamepad");
        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");

        JCFSwizzle(buttonClass, @selector(value), (IMP)JCFButtonValue, &gOrigValue);
        JCFSwizzle(buttonClass, @selector(isPressed), (IMP)JCFButtonIsPressed, &gOrigIsPressed);

        JCFSwizzle(extendedClass, @selector(buttonA), (IMP)JCFExtButtonA, &gOrigExtButtonA);
        JCFSwizzle(extendedClass, @selector(buttonB), (IMP)JCFExtButtonB, &gOrigExtButtonB);
        JCFSwizzle(extendedClass, @selector(buttonX), (IMP)JCFExtButtonX, &gOrigExtButtonX);
        JCFSwizzle(extendedClass, @selector(buttonY), (IMP)JCFExtButtonY, &gOrigExtButtonY);
        JCFSwizzle(extendedClass, @selector(leftShoulder), (IMP)JCFExtLeftShoulder, &gOrigExtLeftShoulder);
        JCFSwizzle(extendedClass, @selector(rightShoulder), (IMP)JCFExtRightShoulder, &gOrigExtRightShoulder);

        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);

        NSLog(@"[JoyConMap] mapping probe loaded");
    }
}
