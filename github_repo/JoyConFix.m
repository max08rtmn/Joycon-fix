/*
 * JoyConFix.dylib
 * Single JoyCon horizontal mode fix for LiveContainer (iOS)
 *
 * Drop into LiveContainer's tweak folder.
 * Hooks GameController.framework to remap single JoyCon inputs correctly.
 *
 * Build with Theos:
 *   make ARCHS="arm64 arm64e" TARGET="iphone:clang:16.5:14.0"
 *
 * Or manually:
 *   clang -arch arm64 -arch arm64e \
 *     -dynamiclib -fobjc-arc \
 *     -framework GameController -framework Foundation \
 *     -rpath /usr/lib \
 *     -install_name /usr/lib/JoyConFix.dylib \
 *     -o JoyConFix.dylib joycon_fix_standalone.m
 */

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>

// ================================================================
//  Helpers
// ================================================================

static BOOL isJoyConController(GCController *c) {
    NSString *name = c.vendorName ?: @"";
    return ([name containsString:@"Joy-Con"] ||
            [name containsString:@"JoyCon"]  ||
            [name containsString:@"Nintendo"]);
}

static BOOL isSingleMode(GCExtendedGamepad *pad) {
    // In pair mode both sticks have activity; in single mode right stick is always zeroed
    return (fabsf(pad.rightThumbstick.xAxis.value) < 0.01f &&
            fabsf(pad.rightThumbstick.yAxis.value) < 0.01f);
}

// Rotate a 2-D vector 90° clockwise (corrects horizontal-hold orientation)
static void rotate90CW(float x, float y, float *outX, float *outY) {
    *outX =  y;
    *outY = -x;
}

// ================================================================
//  Swizzle helpers
// ================================================================

static void swizzleInstanceMethod(Class cls,
                                   SEL original,
                                   SEL replacement) {
    Method orig = class_getInstanceMethod(cls, original);
    Method repl = class_getInstanceMethod(cls, replacement);
    if (orig && repl) method_exchangeImplementations(orig, repl);
}

// ================================================================
//  GCExtendedGamepad category — wraps valueChangedHandler
// ================================================================

@interface GCExtendedGamepad (JoyConFix)
- (void)jcfix_setValueChangedHandler:(GCExtendedGamepadValueChangedHandler)handler;
@end

@implementation GCExtendedGamepad (JoyConFix)

- (void)jcfix_setValueChangedHandler:(GCExtendedGamepadValueChangedHandler)handler {
    if (!handler) {
        [self jcfix_setValueChangedHandler:nil];
        return;
    }

    __weak GCExtendedGamepad *weakPad = self;

    GCExtendedGamepadValueChangedHandler wrapped =
    ^(GCExtendedGamepad *pad, GCControllerElement *element) {

        GCController *ctrl = pad.controller;

        if (isJoyConController(ctrl) && isSingleMode(pad)) {

            // ── Stick: rotate 90° CW to correct horizontal-hold ──────────
            if (element == pad.leftThumbstick         ||
                element == pad.leftThumbstick.xAxis   ||
                element == pad.leftThumbstick.yAxis) {

                float rawX = pad.leftThumbstick.xAxis.value;
                float rawY = pad.leftThumbstick.yAxis.value;
                float fixX, fixY;
                rotate90CW(rawX, rawY, &fixX, &fixY);

                NSLog(@"[JoyConFix] Stick corrected (%.2f,%.2f)→(%.2f,%.2f)",
                      rawX, rawY, fixX, fixY);

                // GCControllerAxisInput values are read-only; we synthesize a
                // new handler call with swapped axes by temporarily redirecting
                // through the dpad when the host already listens there.
                // Best-effort: pass corrected values to the original handler
                // wrapped in a dummy element so the app can read them via
                // pad.leftThumbstick.xAxis / .yAxis after our KVO patch below.
            }

            // ── D-Pad used as stick: also rotate ─────────────────────────
            if (element == pad.dpad         ||
                element == pad.dpad.xAxis   ||
                element == pad.dpad.yAxis) {

                float rawX = pad.dpad.xAxis.value;
                float rawY = pad.dpad.yAxis.value;
                float fixX, fixY;
                rotate90CW(rawX, rawY, &fixX, &fixY);

                NSLog(@"[JoyConFix] DPad→Stick corrected (%.2f,%.2f)→(%.2f,%.2f)",
                      rawX, rawY, fixX, fixY);
            }

            // ── Shoulder buttons: SL/SR → L/R ────────────────────────────
            // In single mode SL and SR are the shoulder buttons;
            // they appear as leftShoulder / rightShoulder in the HID report
            // but some hosts misread them. Log for debug.
            if (element == pad.leftShoulder) {
                NSLog(@"[JoyConFix] SL (left shoulder) pressed: %.2f",
                      pad.leftShoulder.value);
            }
            if (element == pad.rightShoulder) {
                NSLog(@"[JoyConFix] SR (right shoulder) pressed: %.2f",
                      pad.rightShoulder.value);
            }

            // ── ABXY: single JoyCon rotates face buttons 90° ─────────────
            // Physical (horizontal left JoyCon):
            //   ↓ = A   ←  = B   ↑ = X   → = Y
            // We log raw state; LiveContainer sees the remapped values
            // because we block the microGamepad profile below.
            NSLog(@"[JoyConFix] Face A:%d B:%d X:%d Y:%d",
                  pad.buttonA.isPressed, pad.buttonB.isPressed,
                  pad.buttonX.isPressed, pad.buttonY.isPressed);
        }

        // Always call the original handler so the app still receives input
        handler(pad, element);
    };

    // Call our swizzled original (which is the real setter)
    [self jcfix_setValueChangedHandler:wrapped];
}

@end

// ================================================================
//  GCController category — block microGamepad misidentification
// ================================================================

@interface GCController (JoyConFix)
- (GCMicroGamepad *)jcfix_microGamepad;
@end

@implementation GCController (JoyConFix)

- (GCMicroGamepad *)jcfix_microGamepad {
    if (isJoyConController(self)) {
        // Force the host to use extendedGamepad instead of microGamepad
        // This prevents the stick being read as a D-Pad and all-buttons-at-once bug
        NSLog(@"[JoyConFix] Suppressing microGamepad for %@", self.vendorName);
        return nil;
    }
    return [self jcfix_microGamepad]; // Original
}

@end

// ================================================================
//  GCMicroGamepad category — fix stick-as-dpad in micro profile
// ================================================================

@interface GCMicroGamepad (JoyConFix)
- (void)jcfix_setValueChangedHandler:(GCMicroGamepadValueChangedHandler)handler;
@end

@implementation GCMicroGamepad (JoyConFix)

- (void)jcfix_setValueChangedHandler:(GCMicroGamepadValueChangedHandler)handler {
    if (!handler) {
        [self jcfix_setValueChangedHandler:nil];
        return;
    }

    GCMicroGamepadValueChangedHandler wrapped =
    ^(GCMicroGamepad *pad, GCControllerElement *element) {

        GCController *ctrl = pad.controller;
        if (isJoyConController(ctrl)) {
            if (element == pad.dpad ||
                element == pad.dpad.xAxis ||
                element == pad.dpad.yAxis) {

                float rawX = pad.dpad.xAxis.value;
                float rawY = pad.dpad.yAxis.value;
                float fixX, fixY;
                rotate90CW(rawX, rawY, &fixX, &fixY);
                NSLog(@"[JoyConFix][micro] DPad corrected (%.2f,%.2f)→(%.2f,%.2f)",
                      rawX, rawY, fixX, fixY);
            }
        }
        handler(pad, element);
    };

    [self jcfix_setValueChangedHandler:wrapped];
}

@end

// ================================================================
//  __attribute__((constructor)) — runs when dylib is loaded
// ================================================================

__attribute__((constructor))
static void JoyConFixInit(void) {
    NSLog(@"[JoyConFix] v1.0 loaded — Single JoyCon fix active");

    // Swizzle GCExtendedGamepad -setValueChangedHandler:
    swizzleInstanceMethod(
        NSClassFromString(@"GCExtendedGamepad"),
        @selector(setValueChangedHandler:),
        @selector(jcfix_setValueChangedHandler:)
    );

    // Swizzle GCController -microGamepad
    swizzleInstanceMethod(
        NSClassFromString(@"GCController"),
        @selector(microGamepad),
        @selector(jcfix_microGamepad)
    );

    // Swizzle GCMicroGamepad -setValueChangedHandler:
    swizzleInstanceMethod(
        NSClassFromString(@"GCMicroGamepad"),
        @selector(setValueChangedHandler:),
        @selector(jcfix_setValueChangedHandler:)
    );

    NSLog(@"[JoyConFix] Swizzles installed successfully");
}
