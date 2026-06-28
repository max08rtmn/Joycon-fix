#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/*
 JoyConFix.m - physical button alias + name fix

 What we learned from the logs:
 - MeloNX reads GCPhysicalInputProfile.buttons.
 - The physical dictionary contains the right separate button objects.
 - The keys are "Button A/B/X/Y", but the objects report names like
   "A Button", "B Button", "L1 Button", and "R1 Button".

 This build keeps the controller identity and values untouched, but normalizes
 the exposed button names and adds aliases in the physical buttons dictionary.

 It does not spoof Xbox/ProController, does not force ControllerTypesForID,
 does not rotate sticks, and does not change value/isPressed.
*/

static char kJCFButtonLabelKey;

static IMP gOrigPhysicalButtons;
static IMP gOrigLocalizedName;
static IMP gOrigUnmappedLocalizedName;
static IMP gOrigSfSymbolsName;
static IMP gOrigName;
static IMP gOrigAliases;

static NSString *JCFLabelForButton(id button) {
    NSString *label = objc_getAssociatedObject(button, &kJCFButtonLabelKey);
    return label.length ? label : nil;
}

static void JCFSetButtonLabel(id button, NSString *label) {
    if (!button || label.length == 0) {
        return;
    }

    NSString *oldLabel = JCFLabelForButton(button);
    if (![oldLabel isEqualToString:label]) {
        objc_setAssociatedObject(button, &kJCFButtonLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSLog(@"[JoyConFix] normalized %@ -> %p", label, button);
    }
}

static void JCFAddAliases(NSMutableDictionary *dict, id sourceKey, NSArray *aliases) {
    id button = [dict objectForKey:sourceKey];
    if (!button) {
        return;
    }

    JCFSetButtonLabel(button, sourceKey);

    for (id alias in aliases) {
        if ([alias isKindOfClass:NSString.class] && ![dict objectForKey:alias]) {
            [dict setObject:button forKey:alias];
        }
    }
}

static BOOL JCFHasJoyConFaceButtons(NSDictionary *dict) {
    return [dict objectForKey:@"Button A"] &&
           [dict objectForKey:@"Button B"] &&
           [dict objectForKey:@"Button X"] &&
           [dict objectForKey:@"Button Y"];
}

static id JCFOriginalGetter(id self, SEL _cmd, IMP original) {
    return original ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
}

static NSString *JCFSymbolForLabel(NSString *label) {
    NSDictionary *symbols = @{
        @"Button A": @"a.circle",
        @"Button B": @"b.circle",
        @"Button X": @"x.circle",
        @"Button Y": @"y.circle",
        @"Left Shoulder": @"l1.rectangle.roundedbottom",
        @"Right Shoulder": @"r1.rectangle.roundedbottom"
    };
    return [symbols objectForKey:label];
}

static NSSet *JCFAliasesForLabel(NSString *label) {
    if ([label isEqualToString:@"Button A"]) {
        return [NSSet setWithObjects:@"Button A", @"ButtonA", @"A Button", @"A", @"GCInputButtonA", @"buttonA", nil];
    }
    if ([label isEqualToString:@"Button B"]) {
        return [NSSet setWithObjects:@"Button B", @"ButtonB", @"B Button", @"B", @"GCInputButtonB", @"buttonB", nil];
    }
    if ([label isEqualToString:@"Button X"]) {
        return [NSSet setWithObjects:@"Button X", @"ButtonX", @"X Button", @"X", @"GCInputButtonX", @"buttonX", nil];
    }
    if ([label isEqualToString:@"Button Y"]) {
        return [NSSet setWithObjects:@"Button Y", @"ButtonY", @"Y Button", @"Y", @"GCInputButtonY", @"buttonY", nil];
    }
    if ([label isEqualToString:@"Left Shoulder"]) {
        return [NSSet setWithObjects:@"Left Shoulder", @"LeftShoulder", @"Left Bumper", @"L1 Button", @"L1", @"L", @"SL", @"GCInputLeftShoulder", @"leftShoulder", nil];
    }
    if ([label isEqualToString:@"Right Shoulder"]) {
        return [NSSet setWithObjects:@"Right Shoulder", @"RightShoulder", @"Right Bumper", @"R1 Button", @"R1", @"R", @"SR", @"GCInputRightShoulder", @"rightShoulder", nil];
    }
    return nil;
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
    NSSet *aliases = label ? JCFAliasesForLabel(label) : nil;
    return aliases ?: JCFOriginalGetter(self, _cmd, gOrigAliases);
}

static id JCFPhysicalButtons(id self, SEL _cmd) {
    NSDictionary *original = gOrigPhysicalButtons ? ((id (*)(id, SEL))gOrigPhysicalButtons)(self, _cmd) : nil;
    if (![original isKindOfClass:NSDictionary.class] || !JCFHasJoyConFaceButtons(original)) {
        return original;
    }

    NSMutableDictionary *fixed = [original mutableCopy];

    JCFAddAliases(fixed, @"Button A", @[@"A Button", @"A", @"GCInputButtonA", @"buttonA", @"ButtonA"]);
    JCFAddAliases(fixed, @"Button B", @[@"B Button", @"B", @"GCInputButtonB", @"buttonB", @"ButtonB"]);
    JCFAddAliases(fixed, @"Button X", @[@"X Button", @"X", @"GCInputButtonX", @"buttonX", @"ButtonX"]);
    JCFAddAliases(fixed, @"Button Y", @[@"Y Button", @"Y", @"GCInputButtonY", @"buttonY", @"ButtonY"]);
    JCFAddAliases(fixed, @"Left Shoulder", @[@"L1 Button", @"L1", @"L", @"SL", @"Left Bumper", @"GCInputLeftShoulder", @"leftShoulder", @"LeftShoulder"]);
    JCFAddAliases(fixed, @"Right Shoulder", @[@"R1 Button", @"R1", @"R", @"SR", @"Right Bumper", @"GCInputRightShoulder", @"rightShoulder", @"RightShoulder"]);

    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSLog(@"[JoyConFix] physical alias+name fix installed. original=%lu fixed=%lu",
              (unsigned long)original.count,
              (unsigned long)fixed.count);
    }

    return fixed;
}

static void JCFSwizzle(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[JoyConFix] missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
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

        Class physicalClass = NSClassFromString(@"GCPhysicalInputProfile");
        Class buttonClass = NSClassFromString(@"GCControllerButtonInput");

        JCFSwizzle(physicalClass, @selector(buttons), (IMP)JCFPhysicalButtons, &gOrigPhysicalButtons);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"localizedName"), (IMP)JCFButtonLocalizedName, &gOrigLocalizedName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"unmappedLocalizedName"), (IMP)JCFButtonUnmappedLocalizedName, &gOrigUnmappedLocalizedName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"sfSymbolsName"), (IMP)JCFButtonSfSymbolsName, &gOrigSfSymbolsName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"name"), (IMP)JCFButtonName, &gOrigName);
        JCFSwizzle(buttonClass, NSSelectorFromString(@"aliases"), (IMP)JCFButtonAliases, &gOrigAliases);

        NSLog(@"[JoyConFix] physical alias+name fix loaded");
    }
}
