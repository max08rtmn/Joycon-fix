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
