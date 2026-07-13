#include "CWacomHID.h"
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

struct WacomHIDContext {
    IOHIDManagerRef manager;
    IOHIDDeviceRef  device;        // first matched device
    uint16_t vendorID, productID;
    WacomHIDReportCallback onReport;
    WacomHIDDeviceCallback onAttach, onDetach;
    void *userContext;
    uint8_t inputBuffer[64];
};

static void inputReportCB(void *context, IOReturn result, void *sender,
                          IOHIDReportType type, uint32_t reportID,
                          uint8_t *report, CFIndex reportLength) {
    (void)result; (void)sender; (void)type;
    WacomHIDContext *ctx = (WacomHIDContext *)context;
    if (ctx->onReport)
        ctx->onReport(ctx->userContext, reportID, report, (size_t)reportLength);
}

static void matchCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)result; (void)sender;
    WacomHIDContext *ctx = (WacomHIDContext *)context;
    if (!ctx->device) ctx->device = dev;
    IOHIDDeviceRegisterInputReportCallback(dev, ctx->inputBuffer,
                                           sizeof(ctx->inputBuffer),
                                           inputReportCB, ctx);
    if (ctx->onAttach) ctx->onAttach(ctx->userContext, ctx->vendorID, ctx->productID);
}

static void removalCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)result; (void)sender; (void)dev;
    WacomHIDContext *ctx = (WacomHIDContext *)context;
    if (ctx->device == dev) ctx->device = NULL;
    if (ctx->onDetach) ctx->onDetach(ctx->userContext, ctx->vendorID, ctx->productID);
}

static CFDictionaryRef makeMatch(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    int v = vid;
    CFNumberRef vn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFDictionarySetValue(d, CFSTR(kIOHIDVendorIDKey), vn);
    CFRelease(vn);
    if (pid) {
        int p = pid;
        CFNumberRef pn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
        CFDictionarySetValue(d, CFSTR(kIOHIDProductIDKey), pn);
        CFRelease(pn);
    }
    return d;
}

WacomHIDContext *wacom_hid_create(uint16_t vendorID, uint16_t productID,
                                  WacomHIDReportCallback onReport,
                                  WacomHIDDeviceCallback onAttach,
                                  WacomHIDDeviceCallback onDetach,
                                  void *userContext) {
    WacomHIDContext *ctx = calloc(1, sizeof(*ctx));
    ctx->vendorID = vendorID; ctx->productID = productID;
    ctx->onReport = onReport; ctx->onAttach = onAttach; ctx->onDetach = onDetach;
    ctx->userContext = userContext;
    ctx->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFDictionaryRef m = makeMatch(vendorID, productID);
    IOHIDManagerSetDeviceMatching(ctx->manager, m);
    CFRelease(m);
    IOHIDManagerRegisterDeviceMatchingCallback(ctx->manager, matchCB, ctx);
    IOHIDManagerRegisterDeviceRemovalCallback(ctx->manager, removalCB, ctx);
    return ctx;
}

int wacom_hid_send_feature(WacomHIDContext *ctx, uint32_t reportID,
                           const uint8_t *data, size_t length) {
    if (!ctx->device) return -1;
    IOReturn r = IOHIDDeviceSetReport(ctx->device, kIOHIDReportTypeFeature,
                                      reportID, data, length);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

int wacom_hid_send_output(WacomHIDContext *ctx, uint32_t reportID,
                          const uint8_t *data, size_t length) {
    if (!ctx->device) return -1;
    IOReturn r = IOHIDDeviceSetReport(ctx->device, kIOHIDReportTypeOutput,
                                      reportID, data, length);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

int wacom_hid_start(WacomHIDContext *ctx) {
    IOHIDManagerScheduleWithRunLoop(ctx->manager, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(ctx->manager, kIOHIDOptionsTypeNone);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

void wacom_hid_run_blocking(WacomHIDContext *ctx) {
    if (wacom_hid_start(ctx) == 0) CFRunLoopRun();
}

void wacom_hid_stop(WacomHIDContext *ctx) {
    IOHIDManagerUnscheduleFromRunLoop(ctx->manager, CFRunLoopGetCurrent(),
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(ctx->manager, kIOHIDOptionsTypeNone);
}

void wacom_hid_free(WacomHIDContext *ctx) {
    if (!ctx) return;
    if (ctx->manager) CFRelease(ctx->manager);
    free(ctx);
}
