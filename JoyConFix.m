#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 JoyConFix.m

 Built for the simple GitHub Actions workflow:

   clang -dynamiclib -fobjc-arc -framework GameController -framework Foundation JoyConFix.m

 The captured Joy-Con reports use Nintendo's simple input report 0x3F:

   byte 0: report id, 0x3F
   byte 1: face buttons and SL/SR
   byte 2: menu/system/large shoulder buttons
   byte 3: hat/stick direction, neutral is 0x0F

 From the supplied captures:

   face cluster, physical order top/right/bottom/left:
     0x08, 0x02, 0x01, 0x04

   small rail shoulder buttons:
     SL = 0x10, SR = 0x20

   large shoulder/trigger buttons:
     shoulder = 0x40, trigger = 0x80 in byte 2

 This dylib wraps IOHIDDeviceRegisterInputReportCallback when it is injected
 early enough, then normalizes Joy-Con report 0x3F before GameController or
 the host app sees it.
*/

#ifndef JOYCONFIX_DEBUG_LOG
#define JOYCONFIX_DEBUG_LOG 0
#endif

#if JOYCONFIX_DEBUG_LOG
#define JCFLog(fmt, ...) NSLog((@"[JoyConFix] " fmt), ##__VA_ARGS__)
#else
#define JCFLog(fmt, ...)
#endif

typedef void (*JCFHIDReportCallback)(void *context,
                                     int32_t result,
                                     void *sender,
                                     uint32_t type,
                                     uint32_t reportID,
                                     uint8_t *report,
                                     CFIndex reportLength);

typedef void (*JCFRegisterInputReportCallbackFn)(void *device,
                                                 uint8_t *report,
                                                 CFIndex reportLength,
                                                 JCFHIDReportCallback callback,
                                                 void *context);

typedef CFTypeRef (*JCFIOHIDDeviceGetPropertyFn)(void *device, CFStringRef key);

typedef struct {
    JCFHIDReportCallback callback;
    void *context;
    BOOL shouldNormalize;
} JCFCallbackContext;

static JCFRegisterInputReportCallbackFn JCFOriginalRegisterInputReportCallbackStorage = NULL;

static void JCFReplacementRegisterInputReportCallback(void *device,
                                                      uint8_t *report,
                                                      CFIndex reportLength,
                                                      JCFHIDReportCallback callback,
                                                      void *context);

typedef struct {
    const char *name;
    void *replacement;
    void **replaced;
} JCFRebinding;

static void JCFWritePointer(void **slot, void *value) {
    uintptr_t address = (uintptr_t)slot;
    uintptr_t pageSize = (uintptr_t)getpagesize();
    vm_address_t pageStart = (vm_address_t)(address & ~(pageSize - 1));

    vm_protect(mach_task_self(),
               pageStart,
               (vm_size_t)pageSize,
               false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *slot = value;
}

static void JCFRebindSection(uintptr_t slide,
                             struct section_64 *section,
                             struct nlist_64 *symtab,
                             char *strtab,
                             uint32_t *indirectSymtab,
                             const JCFRebinding *rebinding) {
    if (!section || !symtab || !strtab || !indirectSymtab || !rebinding || !rebinding->name) {
        return;
    }

    void **bindings = (void **)(slide + section->addr);
    uint32_t *indirectIndexes = indirectSymtab + section->reserved1;
    uint64_t count = section->size / sizeof(void *);

    for (uint64_t i = 0; i < count; i++) {
        uint32_t symIndex = indirectIndexes[i];
        if (symIndex == INDIRECT_SYMBOL_ABS ||
            symIndex == INDIRECT_SYMBOL_LOCAL ||
            symIndex == (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) {
            continue;
        }

        uint32_t strOffset = symtab[symIndex].n_un.n_strx;
        if (strOffset == 0) {
            continue;
        }

        const char *symbolName = strtab + strOffset;
        if (symbolName[0] == '_') {
            symbolName++;
        }

        if (strcmp(symbolName, rebinding->name) != 0) {
            continue;
        }

        void *current = bindings[i];
        if (current == rebinding->replacement) {
            continue;
        }

        if (rebinding->replaced && !*rebinding->replaced && current) {
            *rebinding->replaced = current;
        }

        JCFWritePointer(&bindings[i], rebinding->replacement);
    }
}

static void JCFRebindImage(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) {
        return;
    }

    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    struct symtab_command *symtabCommand = NULL;
    struct dysymtab_command *dysymtabCommand = NULL;
    struct segment_command_64 *linkeditSegment = NULL;

    uintptr_t cursor = (uintptr_t)header64 + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        struct load_command *loadCommand = (struct load_command *)cursor;

        if (loadCommand->cmd == LC_SYMTAB) {
            symtabCommand = (struct symtab_command *)loadCommand;
        } else if (loadCommand->cmd == LC_DYSYMTAB) {
            dysymtabCommand = (struct dysymtab_command *)loadCommand;
        } else if (loadCommand->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)loadCommand;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkeditSegment = segment;
            }
        }

        cursor += loadCommand->cmdsize;
    }

    if (!symtabCommand || !dysymtabCommand || !linkeditSegment) {
        return;
    }

    uintptr_t linkeditBase = (uintptr_t)slide + linkeditSegment->vmaddr - linkeditSegment->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(linkeditBase + symtabCommand->symoff);
    char *strtab = (char *)(linkeditBase + symtabCommand->stroff);
    uint32_t *indirectSymtab = (uint32_t *)(linkeditBase + dysymtabCommand->indirectsymoff);

    JCFRebinding rebinding = {
        "IOHIDDeviceRegisterInputReportCallback",
        (void *)JCFReplacementRegisterInputReportCallback,
        (void **)&JCFOriginalRegisterInputReportCallbackStorage
    };

    cursor = (uintptr_t)header64 + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        struct load_command *loadCommand = (struct load_command *)cursor;

        if (loadCommand->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)loadCommand;
            struct section_64 *section = (struct section_64 *)(cursor + sizeof(struct segment_command_64));

            for (uint32_t j = 0; j < segment->nsects; j++) {
                uint32_t sectionType = section[j].flags & SECTION_TYPE;
                if (sectionType == S_LAZY_SYMBOL_POINTERS || sectionType == S_NON_LAZY_SYMBOL_POINTERS) {
                    JCFRebindSection((uintptr_t)slide, &section[j], symtab, strtab, indirectSymtab, &rebinding);
                }
            }
        }

        cursor += loadCommand->cmdsize;
    }
}

static JCFRegisterInputReportCallbackFn JCFOriginalRegisterInputReportCallback(void) {
    static JCFRegisterInputReportCallbackFn fn = NULL;
    if (!fn) {
        fn = (JCFRegisterInputReportCallbackFn)dlsym(RTLD_NEXT, "IOHIDDeviceRegisterInputReportCallback");
    }

    return fn ?: JCFOriginalRegisterInputReportCallbackStorage;
}

static JCFIOHIDDeviceGetPropertyFn JCFGetPropertyFunction(void) {
    static JCFIOHIDDeviceGetPropertyFn fn = NULL;
    if (!fn) {
        fn = (JCFIOHIDDeviceGetPropertyFn)dlsym(RTLD_DEFAULT, "IOHIDDeviceGetProperty");
    }
    return fn;
}

static NSInteger JCFIntegerHIDProperty(void *device, CFStringRef key, NSInteger fallback) {
    JCFIOHIDDeviceGetPropertyFn getProperty = JCFGetPropertyFunction();
    if (!device || !getProperty) {
        return fallback;
    }

    CFTypeRef value = getProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return fallback;
    }

    NSInteger result = fallback;
    CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &result);
    return result;
}

static NSString *JCFStringHIDProperty(void *device, CFStringRef key) {
    JCFIOHIDDeviceGetPropertyFn getProperty = JCFGetPropertyFunction();
    if (!device || !getProperty) {
        return nil;
    }

    CFTypeRef value = getProperty(device, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return nil;
    }

    return [(__bridge NSString *)value copy];
}

static BOOL JCFDeviceLooksLikeJoyCon(void *device) {
    NSInteger vendorID = JCFIntegerHIDProperty(device, CFSTR("VendorID"), -1);
    NSInteger productID = JCFIntegerHIDProperty(device, CFSTR("ProductID"), -1);

    if (vendorID == 0x057e && (productID == 0x2006 || productID == 0x2007)) {
        return YES;
    }

    NSString *manufacturer = JCFStringHIDProperty(device, CFSTR("Manufacturer"));
    NSString *product = JCFStringHIDProperty(device, CFSTR("Product"));
    NSString *combined = [[NSString stringWithFormat:@"%@ %@", manufacturer ?: @"", product ?: @""] lowercaseString];

    if ([combined containsString:@"nintendo"] && [combined containsString:@"joy"]) {
        return YES;
    }

    if ([combined containsString:@"nintendo"] && [combined containsString:@"wireless gamepad"]) {
        return YES;
    }

    return NO;
}

static BOOL JCFResolveReportIndexes(uint8_t *report,
                                    CFIndex reportLength,
                                    uint32_t callbackReportID,
                                    CFIndex *buttons1Index,
                                    CFIndex *buttons2Index,
                                    CFIndex *hatIndex) {
    if (!report || reportLength < 3) {
        return NO;
    }

    if (reportLength >= 4 && report[0] == 0x3f) {
        *buttons1Index = 1;
        *buttons2Index = 2;
        *hatIndex = 3;
        return YES;
    }

    if (callbackReportID == 0x3f) {
        *buttons1Index = 0;
        *buttons2Index = 1;
        *hatIndex = 2;
        return YES;
    }

    return NO;
}

static uint8_t JCFNormalizeFaceCluster(uint8_t buttons1) {
    uint8_t rawFace = buttons1 & 0x0f;
    uint8_t normalizedFace = 0;

    /*
     Captured physical order:
       top    -> 0x08
       right  -> 0x02
       bottom -> 0x01
       left   -> 0x04

     Normal simple-controller order used by many parsers:
       Y/left -> 0x01
       X/top  -> 0x02
       B/down -> 0x04
       A/right-> 0x08
    */
    if (rawFace & 0x08) normalizedFace |= 0x02;
    if (rawFace & 0x02) normalizedFace |= 0x08;
    if (rawFace & 0x01) normalizedFace |= 0x04;
    if (rawFace & 0x04) normalizedFace |= 0x01;

    return (buttons1 & 0xf0) | normalizedFace;
}

static void JCFNormalizeJoyConReport(uint8_t *report, CFIndex reportLength, uint32_t callbackReportID) {
    CFIndex buttons1Index = 0;
    CFIndex buttons2Index = 0;
    CFIndex hatIndex = 0;

    if (!JCFResolveReportIndexes(report, reportLength, callbackReportID, &buttons1Index, &buttons2Index, &hatIndex)) {
        return;
    }

    uint8_t buttons1 = report[buttons1Index];
    uint8_t buttons2 = report[buttons2Index];
    uint8_t originalButtons1 = buttons1;
    uint8_t originalButtons2 = buttons2;

    buttons1 = JCFNormalizeFaceCluster(buttons1);

    /*
     Make the small rail buttons usable as the main shoulder controls in
     single-Joy-Con mode. The original bits stay set as well, so software that
     already understands SL/SR can still see them.
    */
    if (originalButtons1 & 0x10) {
        buttons2 |= 0x40;
    }

    if (originalButtons1 & 0x20) {
        buttons2 |= 0x80;
    }

    report[buttons1Index] = buttons1;
    report[buttons2Index] = buttons2;

    JCFLog(@"normalized report 0x%02x: b1 %02x->%02x b2 %02x->%02x hat %02x",
           callbackReportID,
           originalButtons1,
           buttons1,
           originalButtons2,
           buttons2,
           report[hatIndex]);
}

static void JCFInputReportCallback(void *context,
                                   int32_t result,
                                   void *sender,
                                   uint32_t type,
                                   uint32_t reportID,
                                   uint8_t *report,
                                   CFIndex reportLength) {
    JCFCallbackContext *wrapped = (JCFCallbackContext *)context;
    if (!wrapped || !wrapped->callback) {
        return;
    }

    if (wrapped->shouldNormalize) {
        JCFNormalizeJoyConReport(report, reportLength, reportID);
    }

    wrapped->callback(wrapped->context, result, sender, type, reportID, report, reportLength);
}

static void JCFReplacementRegisterInputReportCallback(void *device,
                                                      uint8_t *report,
                                                      CFIndex reportLength,
                                                      JCFHIDReportCallback callback,
                                                      void *context) {
    JCFRegisterInputReportCallbackFn original = JCFOriginalRegisterInputReportCallback();
    if (!original) {
        return;
    }

    JCFCallbackContext *wrapped = (JCFCallbackContext *)calloc(1, sizeof(JCFCallbackContext));
    if (!wrapped) {
        original(device, report, reportLength, callback, context);
        return;
    }

    wrapped->callback = callback;
    wrapped->context = context;
    wrapped->shouldNormalize = JCFDeviceLooksLikeJoyCon(device);

    /*
     Some fake or relayed Joy-Cons expose weak identity strings. If identity
     detection fails, still allow report 0x3F to be normalized at callback time
     when this device's actual reports match the captured Joy-Con shape.
    */
    if (!wrapped->shouldNormalize) {
        NSInteger vendorID = JCFIntegerHIDProperty(device, CFSTR("VendorID"), -1);
        NSInteger productID = JCFIntegerHIDProperty(device, CFSTR("ProductID"), -1);
        wrapped->shouldNormalize = (vendorID == -1 && productID == -1);
    }

    JCFLog(@"registered HID report callback, normalize=%@", wrapped->shouldNormalize ? @"YES" : @"NO");
    original(device, report, reportLength, JCFInputReportCallback, wrapped);
}

void IOHIDDeviceRegisterInputReportCallback(void *device,
                                            uint8_t *report,
                                            CFIndex reportLength,
                                            JCFHIDReportCallback callback,
                                            void *context) {
    JCFReplacementRegisterInputReportCallback(device, report, reportLength, callback, context);
}

__attribute__((constructor))
static void JCFInstall(void) {
    @autoreleasepool {
        /*
         Loading this dylib is enough. It first patches existing imports, then
         dyld calls the same rebinder for later-loaded images.
        */
        _dyld_register_func_for_add_image(JCFRebindImage);
        JCFLog(@"loaded");
    }
}
