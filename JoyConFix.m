#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdbool.h>
#import <string.h>
#import <unistd.h>

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
static IMP gOrigSetPressedChangedHandler = NULL;
static BOOL gInstallingHandler = NO;
static BOOL gDidProbeMeloNXClasses = NO;
static BOOL gDidShowLoadProof = NO;

static const void *kJCFControllerKey = &kJCFControllerKey;
static const void *kJCFSemanticKey = &kJCFSemanticKey;
static const void *kJCFCanonicalKey = &kJCFCanonicalKey;
static const void *kJCFStoredHandlerKey = &kJCFStoredHandlerKey;
static const void *kJCFDispatcherInstalledKey = &kJCFDispatcherInstalledKey;
static const void *kJCFAmbiguousCountKey = &kJCFAmbiguousCountKey;
static const void *kJCFProfileControllerKey = &kJCFProfileControllerKey;

static NSMutableDictionary<NSString *, NSValue *> *gGetterOriginals;
static NSMutableSet<NSString *> *gGetterLogged;
static NSMutableDictionary<NSString *, NSValue *> *gButtonInputOriginals;
static NSMutableDictionary<NSString *, NSNumber *> *gButtonStateLast;
static NSMutableDictionary<NSString *, NSNumber *> *gPhysicalPressed;
static void *gLastRyujinxGamepad = NULL;
static BOOL gSawManagedJoyConState = NO;

typedef void (*JCFSetGamepadButtonStateC)(void *gamepad, long buttonId, bool pressed);
typedef void *(*JCFDlsymC)(void *handle, const char *symbol);
static JCFSetGamepadButtonStateC gOrigSetGamepadButtonState = NULL;
static JCFDlsymC gOrigDlsym = NULL;

static NSString *JCFSemanticForPhysicalKey(NSString *key);
static void JCFHookButtonInputState(GCControllerButtonInput *button);

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

static IMP JCFOriginalSetterForSelector(SEL selector) {
    if (selector == @selector(setValueChangedHandler:)) {
        return gOrigSetValueChangedHandler;
    }
    if (selector == NSSelectorFromString(@"setPressedChangedHandler:")) {
        return gOrigSetPressedChangedHandler;
    }
    return NULL;
}

static void JCFSetHandlerRaw(GCControllerButtonInput *button, SEL selector, JCFButtonHandler handler) {
    IMP original = JCFOriginalSetterForSelector(selector);
    if (!button || !original) {
        return;
    }
    gInstallingHandler = YES;
    ((JCFSetHandlerIMP)original)(button, selector, handler);
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

static GCControllerButtonInput *JCFFindPhysicalButtonForSemantic(GCController *controller, NSString *semantic) {
    NSDictionary *buttons = JCFPhysicalButtons(controller);
    for (id key in buttons) {
        NSString *foundSemantic = JCFSemanticForPhysicalKey(JCFString(key));
        if ([foundSemantic isEqualToString:semantic]) {
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

static long JCFBridgeIdForSemantic(NSString *semantic) {
    if ([semantic isEqualToString:@"A"]) return 1;
    if ([semantic isEqualToString:@"B"]) return 2;
    if ([semantic isEqualToString:@"X"]) return 3;
    if ([semantic isEqualToString:@"Y"]) return 4;
    if ([semantic isEqualToString:@"L"]) return 7;
    if ([semantic isEqualToString:@"R"]) return 8;
    return -1;
}

static BOOL JCFBridgeIdIsManaged(long buttonId) {
    return (buttonId >= 1 && buttonId <= 4) || buttonId == 7 || buttonId == 8;
}

static void JCFSendBridgeState(void *gamepad, NSString *semantic, BOOL pressed, const char *reason) {
    if (!gamepad || !gOrigSetGamepadButtonState || !semantic) {
        return;
    }
    long buttonId = JCFBridgeIdForSemantic(semantic);
    if (buttonId < 0) {
        return;
    }
    NSLog(@"[JoyConFixDlsymBridge] send %@ id=%ld pressed=%d reason=%s",
          semantic, buttonId, pressed, reason ?: "unknown");
    gOrigSetGamepadButtonState(gamepad, buttonId, pressed);
}

static void JCFReplayPhysicalStates(void *gamepad, const char *reason) {
    if (!gamepad || !gOrigSetGamepadButtonState || !gPhysicalPressed) {
        return;
    }
    for (NSString *semantic in JCFAllSemantics()) {
        JCFSendBridgeState(gamepad, semantic, [gPhysicalPressed[semantic] boolValue], reason);
    }
}

static void JCFRememberPhysicalState(NSString *semantic, BOOL pressed) {
    if (!semantic || JCFBridgeIdForSemantic(semantic) < 0) {
        return;
    }
    gSawManagedJoyConState = YES;
    NSNumber *old = gPhysicalPressed[semantic];
    if (old && old.boolValue == pressed) {
        return;
    }
    gPhysicalPressed[semantic] = @(pressed);
    if (gLastRyujinxGamepad && gOrigSetGamepadButtonState) {
        JCFSendBridgeState(gLastRyujinxGamepad, semantic, pressed, "physical-state-change");
    }
}

static void JCFBridgeSetGamepadButtonState(void *gamepad, long buttonId, bool pressed) {
    if (gamepad) {
        gLastRyujinxGamepad = gamepad;
    }
    NSLog(@"[JoyConFixDlsymBridge] hit id=%ld pressed=%d sawJoyCon=%d",
          buttonId, pressed, gSawManagedJoyConState);
    if (gSawManagedJoyConState && JCFBridgeIdIsManaged(buttonId)) {
        NSLog(@"[JoyConFixDlsymBridge] suppress original id=%ld pressed=%d and replay physical states",
              buttonId, pressed);
        JCFReplayPhysicalStates(gamepad ?: gLastRyujinxGamepad, "suppress-replay");
        return;
    }
    if (gOrigSetGamepadButtonState) {
        gOrigSetGamepadButtonState(gamepad, buttonId, pressed);
    }
}

static void *JCFDlsym(void *handle, const char *symbol) {
    if (!gOrigDlsym) {
        return NULL;
    }
    void *result = gOrigDlsym(handle, symbol);
    if (symbol &&
        (strcmp(symbol, "set_gamepad_button_state") == 0 ||
         strcmp(symbol, "_set_gamepad_button_state") == 0)) {
        if (result && !gOrigSetGamepadButtonState) {
            gOrigSetGamepadButtonState = (JCFSetGamepadButtonStateC)result;
        }
        NSLog(@"[JoyConFixDlsymBridge] dlsym intercepted %s original=%p replacement=%p",
              symbol, result, JCFBridgeSetGamepadButtonState);
        return (void *)JCFBridgeSetGamepadButtonState;
    }
    return result;
}

static void JCFRebindNamedSymbolInSection(const struct mach_header_64 *header,
                                          intptr_t slide,
                                          struct section_64 *section,
                                          struct symtab_command *symtabCommand,
                                          struct dysymtab_command *dysymtabCommand,
                                          struct segment_command_64 *linkeditSegment,
                                          const char *targetSymbol,
                                          void *replacement,
                                          void **originalOut) {
    if (!section || !symtabCommand || !dysymtabCommand || !linkeditSegment || !targetSymbol || !replacement) {
        return;
    }

    uintptr_t linkeditBase = (uintptr_t)slide + linkeditSegment->vmaddr - linkeditSegment->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(linkeditBase + symtabCommand->symoff);
    char *strtab = (char *)(linkeditBase + symtabCommand->stroff);
    uint32_t *indirectSymtab = (uint32_t *)(linkeditBase + dysymtabCommand->indirectsymoff);
    uint32_t *indirectSymbolIndices = indirectSymtab + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    size_t count = section->size / sizeof(void *);

    for (size_t i = 0; i < count; i++) {
        uint32_t symtabIndex = indirectSymbolIndices[i];
        if (symtabIndex == INDIRECT_SYMBOL_ABS ||
            symtabIndex == INDIRECT_SYMBOL_LOCAL ||
            symtabIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        uint32_t strOffset = symtab[symtabIndex].n_un.n_strx;
        if (strOffset == 0) {
            continue;
        }
        char *symbolName = strtab + strOffset;
        if (strcmp(symbolName, targetSymbol) != 0) {
            continue;
        }

        if (originalOut && !*originalOut) {
            *originalOut = bindings[i];
        }

        vm_size_t pageSize = (vm_size_t)getpagesize();
        vm_address_t page = (vm_address_t)((uintptr_t)&bindings[i] & ~(uintptr_t)(pageSize - 1));
        kern_return_t kr = vm_protect(mach_task_self(), page, pageSize, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            kr = vm_protect(mach_task_self(), page, pageSize, false, VM_PROT_READ | VM_PROT_WRITE);
        }
        if (kr == KERN_SUCCESS) {
            bindings[i] = replacement;
            NSLog(@"[JoyConFixDlsymBridge] rebound %s in %s/%s original=%p replacement=%p",
                  targetSymbol, section->segname, section->sectname, originalOut ? *originalOut : NULL, replacement);
        } else {
            NSLog(@"[JoyConFixDlsymBridge] failed to rebind %s kr=%d", targetSymbol, kr);
        }
    }
}

static void JCFRebindDlsymInImage(const struct mach_header *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64) {
        return;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    struct symtab_command *symtabCommand = NULL;
    struct dysymtab_command *dysymtabCommand = NULL;
    struct segment_command_64 *linkeditSegment = NULL;

    uintptr_t cursor = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmd == LC_SYMTAB) {
            symtabCommand = (struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtabCommand = (struct dysymtab_command *)command;
        } else if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkeditSegment = segment;
            }
        }
        cursor += command->cmdsize;
    }

    if (!symtabCommand || !dysymtabCommand || !linkeditSegment) {
        return;
    }

    cursor = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            struct section_64 *section = (struct section_64 *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; j++) {
                uint32_t type = section[j].flags & SECTION_TYPE;
                if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                    JCFRebindNamedSymbolInSection(header, slide, &section[j],
                                                  symtabCommand, dysymtabCommand, linkeditSegment,
                                                  "_dlsym", (void *)JCFDlsym, (void **)&gOrigDlsym);
                }
            }
        }
        cursor += command->cmdsize;
    }
}

static void JCFInstallDlsymRebind(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        JCFRebindDlsymInImage(header, slide);
    }
}

static GCControllerButtonInput *JCFCanonicalButton(GCController *controller, NSString *semantic) {
    if ([semantic isEqualToString:@"A"]) return JCFFindPhysicalButtonForSemantic(controller, @"A");
    if ([semantic isEqualToString:@"B"]) return JCFFindPhysicalButtonForSemantic(controller, @"B");
    if ([semantic isEqualToString:@"X"]) return JCFFindPhysicalButtonForSemantic(controller, @"X");
    if ([semantic isEqualToString:@"Y"]) return JCFFindPhysicalButtonForSemantic(controller, @"Y");
    if ([semantic isEqualToString:@"L"]) return JCFFindPhysicalButtonForSemantic(controller, @"L");
    if ([semantic isEqualToString:@"R"]) return JCFFindPhysicalButtonForSemantic(controller, @"R");
    return nil;
}

static NSString *JCFGetterKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%s|%@", class_getName(cls), NSStringFromSelector(selector)];
}

static IMP JCFOriginalGetterForObject(id object, SEL selector) {
    Class cls = object_getClass(object);
    NSString *key = JCFGetterKey(cls, selector);
    NSValue *value = gGetterOriginals[key];
    return value ? value.pointerValue : NULL;
}

static GCController *JCFControllerForProfile(id profile) {
    GCController *controller = objc_getAssociatedObject(profile, kJCFProfileControllerKey);
    if (controller) {
        return controller;
    }
    for (GCController *candidate in [GCController controllers]) {
        if (JCFCall0(candidate, @selector(gamepad)) == profile ||
            JCFCall0(candidate, NSSelectorFromString(@"extendedGamepad")) == profile ||
            JCFCall0(candidate, NSSelectorFromString(@"microGamepad")) == profile) {
            objc_setAssociatedObject(profile, kJCFProfileControllerKey, candidate, OBJC_ASSOCIATION_ASSIGN);
            return candidate;
        }
    }
    return nil;
}

static id JCFProfileGetter(id profile, SEL selector, NSString *semantic) {
    GCController *controller = JCFControllerForProfile(profile);
    if (controller && JCFControllerLooksLikeJoyCon(controller)) {
        GCControllerButtonInput *button = JCFCanonicalButton(controller, semantic);
        if (button) {
            NSString *logKey = [NSString stringWithFormat:@"%p|%@|%@", profile, NSStringFromSelector(selector), semantic];
            if (![gGetterLogged containsObject:logKey]) {
                [gGetterLogged addObject:logKey];
                NSLog(@"[JoyConFixReroute] getter %@ on %@ -> physical %@ %p",
                      NSStringFromSelector(selector), NSStringFromClass(object_getClass(profile)), semantic, button);
            }
            return button;
        }
    }

    IMP original = JCFOriginalGetterForObject(profile, selector);
    if (original) {
        return ((id (*)(id, SEL))original)(profile, selector);
    }
    return nil;
}

static id JCFGetterButtonA(id self, SEL selector) { return JCFProfileGetter(self, selector, @"A"); }
static id JCFGetterButtonB(id self, SEL selector) { return JCFProfileGetter(self, selector, @"B"); }
static id JCFGetterButtonX(id self, SEL selector) { return JCFProfileGetter(self, selector, @"X"); }
static id JCFGetterButtonY(id self, SEL selector) { return JCFProfileGetter(self, selector, @"Y"); }
static id JCFGetterLeftShoulder(id self, SEL selector) { return JCFProfileGetter(self, selector, @"L"); }
static id JCFGetterRightShoulder(id self, SEL selector) { return JCFProfileGetter(self, selector, @"R"); }
static id JCFGetterLeftTrigger(id self, SEL selector) { return JCFProfileGetter(self, selector, @"L"); }
static id JCFGetterRightTrigger(id self, SEL selector) { return JCFProfileGetter(self, selector, @"R"); }

static IMP JCFReplacementForSelector(SEL selector) {
    if (selector == @selector(buttonA)) return (IMP)JCFGetterButtonA;
    if (selector == @selector(buttonB)) return (IMP)JCFGetterButtonB;
    if (selector == @selector(buttonX)) return (IMP)JCFGetterButtonX;
    if (selector == @selector(buttonY)) return (IMP)JCFGetterButtonY;
    if (selector == @selector(leftShoulder)) return (IMP)JCFGetterLeftShoulder;
    if (selector == @selector(rightShoulder)) return (IMP)JCFGetterRightShoulder;
    if (selector == NSSelectorFromString(@"leftTrigger")) return (IMP)JCFGetterLeftTrigger;
    if (selector == NSSelectorFromString(@"rightTrigger")) return (IMP)JCFGetterRightTrigger;
    return NULL;
}

static void JCFHookGetterOnProfile(id profile, GCController *controller, SEL selector) {
    if (!profile || !selector) {
        return;
    }
    Class cls = object_getClass(profile);
    NSString *key = JCFGetterKey(cls, selector);
    if (gGetterOriginals[key]) {
        objc_setAssociatedObject(profile, kJCFProfileControllerKey, controller, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    IMP replacement = JCFReplacementForSelector(selector);
    if (!replacement) {
        return;
    }

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    BOOL added = class_addMethod(cls, selector, replacement, types);
    if (!added) {
        original = method_setImplementation(method, replacement);
    }
    gGetterOriginals[key] = [NSValue valueWithPointer:original];
    objc_setAssociatedObject(profile, kJCFProfileControllerKey, controller, OBJC_ASSOCIATION_ASSIGN);
    NSLog(@"[JoyConFixReroute] hooked getter %@ on %@ added=%d",
          NSStringFromSelector(selector), NSStringFromClass(cls), added);
}

static void JCFHookProfileGetters(GCController *controller) {
    NSArray *profiles = @[
        JCFCall0(controller, @selector(gamepad)) ?: [NSNull null],
        JCFCall0(controller, NSSelectorFromString(@"extendedGamepad")) ?: [NSNull null],
        JCFCall0(controller, NSSelectorFromString(@"microGamepad")) ?: [NSNull null]
    ];
    SEL selectors[] = {
        @selector(buttonA),
        @selector(buttonB),
        @selector(buttonX),
        @selector(buttonY),
        @selector(leftShoulder),
        @selector(rightShoulder),
        NSSelectorFromString(@"leftTrigger"),
        NSSelectorFromString(@"rightTrigger")
    };
    for (id profile in profiles) {
        if ((id)profile == [NSNull null]) {
            continue;
        }
        objc_setAssociatedObject(profile, kJCFProfileControllerKey, controller, OBJC_ASSOCIATION_ASSIGN);
        for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
            JCFHookGetterOnProfile(profile, controller, selectors[i]);
        }
    }
}

static IMP JCFOriginalButtonInputIMP(id object, SEL selector) {
    Class cls = object_getClass(object);
    NSString *key = JCFGetterKey(cls, selector);
    NSValue *value = gButtonInputOriginals[key];
    return value ? value.pointerValue : NULL;
}

static float JCFOriginalButtonValue(GCControllerButtonInput *button) {
    IMP original = JCFOriginalButtonInputIMP(button, @selector(value));
    if (original) {
        return ((float (*)(id, SEL))original)(button, @selector(value));
    }
    return 0.0f;
}

static BOOL JCFOriginalButtonPressed(GCControllerButtonInput *button) {
    IMP original = JCFOriginalButtonInputIMP(button, @selector(isPressed));
    if (original) {
        return ((BOOL (*)(id, SEL))original)(button, @selector(isPressed));
    }
    return JCFOriginalButtonValue(button) > 0.05f;
}

static GCControllerButtonInput *JCFRedirectTargetForButton(GCControllerButtonInput *button) {
    GCController *controller = objc_getAssociatedObject(button, kJCFControllerKey);
    NSString *semantic = objc_getAssociatedObject(button, kJCFSemanticKey);
    if (controller && semantic && JCFControllerLooksLikeJoyCon(controller)) {
        GCControllerButtonInput *canonical = JCFCanonicalButton(controller, semantic);
        if (canonical) {
            return canonical;
        }
    }
    return button;
}

static void JCFLogButtonState(GCControllerButtonInput *source,
                              GCControllerButtonInput *target,
                              SEL selector,
                              float value,
                              BOOL pressed) {
    NSString *semantic = objc_getAssociatedObject(source, kJCFSemanticKey);
    if (!semantic) {
        semantic = objc_getAssociatedObject(target, kJCFSemanticKey);
    }
    if (!semantic) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%p|%@|%@", source, NSStringFromSelector(selector), semantic];
    BOOL active = pressed || value > 0.05f;
    NSNumber *old = gButtonStateLast[key];
    if (!old || old.boolValue != active) {
        gButtonStateLast[key] = @(active);
        JCFRememberPhysicalState(semantic, active);
        NSLog(@"[JoyConFixReroute] state %@ via %@ source=%p target=%p value=%.3f pressed=%d",
              semantic, NSStringFromSelector(selector), source, target, value, pressed);
    }
}

static float JCFButtonValue(id self, SEL selector) {
    GCControllerButtonInput *source = (GCControllerButtonInput *)self;
    GCControllerButtonInput *target = JCFRedirectTargetForButton(source);
    float value = JCFOriginalButtonValue(target);
    BOOL pressed = value > 0.05f;
    JCFLogButtonState(source, target, selector, value, pressed);
    return value;
}

static BOOL JCFButtonIsPressed(id self, SEL selector) {
    GCControllerButtonInput *source = (GCControllerButtonInput *)self;
    GCControllerButtonInput *target = JCFRedirectTargetForButton(source);
    BOOL pressed = JCFOriginalButtonPressed(target);
    float value = pressed ? MAX(JCFOriginalButtonValue(target), 1.0f) : JCFOriginalButtonValue(target);
    JCFLogButtonState(source, target, selector, value, pressed);
    return pressed;
}

static void JCFHookButtonInputState(GCControllerButtonInput *button) {
    if (!button) {
        return;
    }
    SEL selectors[] = {
        @selector(value),
        @selector(isPressed)
    };
    IMP replacements[] = {
        (IMP)JCFButtonValue,
        (IMP)JCFButtonIsPressed
    };
    Class cls = object_getClass(button);
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        NSString *key = JCFGetterKey(cls, selector);
        if (gButtonInputOriginals[key]) {
            continue;
        }
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            continue;
        }
        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        BOOL added = class_addMethod(cls, selector, replacements[i], types);
        if (!added) {
            original = method_setImplementation(method, replacements[i]);
        }
        gButtonInputOriginals[key] = [NSValue valueWithPointer:original];
        NSLog(@"[JoyConFixReroute] hooked button-state %@ on %@ added=%d",
              NSStringFromSelector(selector), NSStringFromClass(cls), added);
    }
}

static void JCFAssociateButton(GCControllerButtonInput *button, GCController *controller, NSString *semantic, BOOL canonical) {
    if (!button || !controller || !semantic) {
        return;
    }
    JCFHookButtonInputState(button);
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
    JCFSetHandlerRaw(canonical, @selector(setValueChangedHandler:), dispatcher);
    if (gOrigSetPressedChangedHandler) {
        JCFSetHandlerRaw(canonical, NSSelectorFromString(@"setPressedChangedHandler:"), dispatcher);
    }
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

        JCFHookProfileGetters(controller);

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

static void JCFSetAnyButtonHandler(GCControllerButtonInput *button, SEL selector, JCFButtonHandler handler) {
    IMP original = JCFOriginalSetterForSelector(selector);
    if (!original) {
        return;
    }
    if (gInstallingHandler) {
        ((JCFSetHandlerIMP)original)(button, selector, handler);
        return;
    }

    JCFRefreshMappings();

    GCController *controller = nil;
    NSString *semantic = JCFSemanticForRegisteredButton(button, &controller);
    if (!handler || !controller || !semantic || !JCFControllerLooksLikeJoyCon(controller)) {
        ((JCFSetHandlerIMP)original)(button, selector, handler);
        return;
    }

    GCControllerButtonInput *canonical = JCFCanonicalButton(controller, semantic);
    if (!canonical) {
        NSLog(@"[JoyConFixReroute] no physical button for semantic %@", semantic);
        ((JCFSetHandlerIMP)original)(button, selector, handler);
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
        JCFSetHandlerRaw(button, selector, suppress);
        NSLog(@"[JoyConFixReroute] rerouted %@ handler %@ standard=%p physical=%p",
              NSStringFromSelector(selector), semantic, button, canonical);
    } else {
        JCFSetHandlerRaw(button, selector, handler);
        NSLog(@"[JoyConFixReroute] kept direct %@ handler %@ physical=%p",
              NSStringFromSelector(selector), semantic, canonical);
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

static void JCFWriteLoadProof(void) {
    NSString *home = NSHomeDirectory();
    NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
    NSString *path = [documents stringByAppendingPathComponent:@"JoyConFixReroute_loaded.txt"];
    NSString *text = [NSString stringWithFormat:
                      @"JoyConFixReroute loaded\nDate: %@\nHome: %@\nBundle: %@\n",
                      [NSDate date],
                      home ?: @"",
                      NSBundle.mainBundle.bundleIdentifier ?: @""];
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    NSLog(@"[JoyConFixReroute] load proof write %@ path=%@ error=%@",
          ok ? @"ok" : @"failed", path, error);
}

static void JCFShowLoadProofIfPossible(void) {
    if (gDidShowLoadProof) {
        return;
    }
    gDidShowLoadProof = YES;

    Class alertClass = NSClassFromString(@"UIAlertController");
    Class appClass = NSClassFromString(@"UIApplication");
    if (!alertClass || !appClass) {
        NSLog(@"[JoyConFixReroute] UIKit alert unavailable");
        return;
    }

    SEL makeSel = NSSelectorFromString(@"alertControllerWithTitle:message:preferredStyle:");
    SEL actionSel = NSSelectorFromString(@"actionWithTitle:style:handler:");
    SEL addActionSel = NSSelectorFromString(@"addAction:");
    SEL presentSel = NSSelectorFromString(@"presentViewController:animated:completion:");
    SEL sharedSel = NSSelectorFromString(@"sharedApplication");
    SEL keyWindowSel = NSSelectorFromString(@"keyWindow");
    SEL rootSel = NSSelectorFromString(@"rootViewController");

    id alert = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(alertClass, makeSel,
                                                                  @"JoyConFix geladen",
                                                                  @"Der Reroute-Tweak wurde in diese App injiziert.",
                                                                  1);
    Class actionClass = NSClassFromString(@"UIAlertAction");
    id action = ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(actionClass, actionSel, @"OK", 0, nil);
    ((void (*)(id, SEL, id))objc_msgSend)(alert, addActionSel, action);

    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sharedSel);
    id window = JCFCall0(app, keyWindowSel);
    id root = JCFCall0(window, rootSel);
    if (root && [root respondsToSelector:presentSel]) {
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(root, presentSel, alert, YES, nil);
        NSLog(@"[JoyConFixReroute] load proof alert shown");
    } else {
        NSLog(@"[JoyConFixReroute] load proof alert no root view controller");
    }
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

static void JCFLogStatus(NSString *phase) {
    NSLog(@"[JoyConFixDlsymBridge] %@ active version=2026-06-30 dlsym-bridge valueHook=%p pressedHook=%p dlsym=%p bridgeOrig=%p controllers=%lu",
          phase,
          gOrigSetValueChangedHandler,
          gOrigSetPressedChangedHandler,
          gOrigDlsym,
          gOrigSetGamepadButtonState,
          (unsigned long)[GCController controllers].count);
}

__attribute__((constructor))
static void JCFInit(void) {
    @autoreleasepool {
        NSLog(@"[JoyConFixDlsymBridge] loaded 2026-06-30 dlsym-bridge exact-button-match");
        gGetterOriginals = [NSMutableDictionary dictionary];
        gGetterLogged = [NSMutableSet set];
        gButtonInputOriginals = [NSMutableDictionary dictionary];
        gButtonStateLast = [NSMutableDictionary dictionary];
        gPhysicalPressed = [NSMutableDictionary dictionary];
        JCFWriteLoadProof();
        Class cls = NSClassFromString(@"GCControllerButtonInput");
        JCFSwizzle(cls, @selector(setValueChangedHandler:), (IMP)JCFSetAnyButtonHandler, &gOrigSetValueChangedHandler);
        JCFSwizzle(cls, NSSelectorFromString(@"setPressedChangedHandler:"), (IMP)JCFSetAnyButtonHandler, &gOrigSetPressedChangedHandler);
        JCFInstallDlsymRebind();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFInstallDlsymRebind();
            JCFLogStatus(@"after-1s");
            JCFRefreshMappings();
            JCFProbeMeloNXClasses();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFInstallDlsymRebind();
            JCFLogStatus(@"after-4s");
            JCFRefreshMappings();
            JCFProbeMeloNXClasses();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCFInstallDlsymRebind();
            JCFLogStatus(@"after-8s");
            JCFRefreshMappings();
        });
    }
}
