#include "CNibHID.h"
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

struct NibHIDContext {
    IOHIDManagerRef manager;
    IOHIDDeviceRef  device;        // first matched device
    uint16_t vendorID, productID;
    NibHIDReportCallback onReport;
    NibHIDDeviceCallback onAttach, onDetach;
    void *userContext;
    uint8_t inputBuffer[64];
};

// Read a numeric IOHIDDevice property (e.g. VendorID/ProductID). Returns 0 if absent.
static uint16_t readDeviceID(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef p = IOHIDDeviceGetProperty(dev, key);   // "get" rule: not owned, no release
    int v = 0;
    if (p && CFGetTypeID(p) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)p, kCFNumberIntType, &v);
    return (uint16_t)v;
}

static void inputReportCB(void *context, IOReturn result, void *sender,
                          IOHIDReportType type, uint32_t reportID,
                          uint8_t *report, CFIndex reportLength) {
    (void)result; (void)sender; (void)type;
    NibHIDContext *ctx = (NibHIDContext *)context;
    if (ctx->onReport)
        ctx->onReport(ctx->userContext, reportID, report, (size_t)reportLength);
}

static void matchCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)result; (void)sender;
    NibHIDContext *ctx = (NibHIDContext *)context;
    if (!ctx->device) ctx->device = dev;
    IOHIDDeviceRegisterInputReportCallback(dev, ctx->inputBuffer,
                                           sizeof(ctx->inputBuffer),
                                           inputReportCB, ctx);
    // Report the device's real IDs (the match filter may be vendor-only, productID = 0).
    if (ctx->onAttach) ctx->onAttach(ctx->userContext,
                                     readDeviceID(dev, CFSTR(kIOHIDVendorIDKey)),
                                     readDeviceID(dev, CFSTR(kIOHIDProductIDKey)));
}

static void removalCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)result; (void)sender;
    NibHIDContext *ctx = (NibHIDContext *)context;
    uint16_t vid = readDeviceID(dev, CFSTR(kIOHIDVendorIDKey));
    uint16_t pid = readDeviceID(dev, CFSTR(kIOHIDProductIDKey));
    if (ctx->device == dev) ctx->device = NULL;
    if (ctx->onDetach) ctx->onDetach(ctx->userContext, vid, pid);
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

size_t nib_hid_enumerate(uint16_t vendorID, NibHIDDeviceInfo *out, size_t maxOut) {
    if (!out || maxOut == 0) return 0;
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (vendorID) {
        CFDictionaryRef m = makeMatch(vendorID, 0);
        IOHIDManagerSetDeviceMatching(mgr, m);
        CFRelease(m);
    } else {
        IOHIDManagerSetDeviceMatching(mgr, NULL);   // match everything
    }
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef devices = IOHIDManagerCopyDevices(mgr);
    size_t n = 0;
    if (devices) {
        CFIndex count = CFSetGetCount(devices);
        const void **arr = calloc((size_t)count, sizeof(void *));
        if (arr) {
            CFSetGetValues(devices, arr);
            for (CFIndex i = 0; i < count && n < maxOut; i++) {
                IOHIDDeviceRef dev = (IOHIDDeviceRef)arr[i];
                out[n].vendorID  = readDeviceID(dev, CFSTR(kIOHIDVendorIDKey));
                out[n].productID = readDeviceID(dev, CFSTR(kIOHIDProductIDKey));
                n++;
            }
            free(arr);
        }
        CFRelease(devices);
    }
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);
    return n;
}

NibHIDContext *nib_hid_create(uint16_t vendorID, uint16_t productID,
                                  NibHIDReportCallback onReport,
                                  NibHIDDeviceCallback onAttach,
                                  NibHIDDeviceCallback onDetach,
                                  void *userContext) {
    NibHIDContext *ctx = calloc(1, sizeof(*ctx));
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

int nib_hid_send_feature(NibHIDContext *ctx, uint32_t reportID,
                           const uint8_t *data, size_t length) {
    if (!ctx->device) return -1;
    IOReturn r = IOHIDDeviceSetReport(ctx->device, kIOHIDReportTypeFeature,
                                      reportID, data, length);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

int nib_hid_send_output(NibHIDContext *ctx, uint32_t reportID,
                          const uint8_t *data, size_t length) {
    if (!ctx->device) return -1;
    IOReturn r = IOHIDDeviceSetReport(ctx->device, kIOHIDReportTypeOutput,
                                      reportID, data, length);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

int nib_hid_start(NibHIDContext *ctx) {
    IOHIDManagerScheduleWithRunLoop(ctx->manager, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(ctx->manager, kIOHIDOptionsTypeNone);
    return (r == kIOReturnSuccess) ? 0 : (int)r;
}

void nib_hid_run_blocking(NibHIDContext *ctx) {
    if (nib_hid_start(ctx) == 0) CFRunLoopRun();
}

void nib_hid_stop(NibHIDContext *ctx) {
    IOHIDManagerUnscheduleFromRunLoop(ctx->manager, CFRunLoopGetCurrent(),
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(ctx->manager, kIOHIDOptionsTypeNone);
}

void nib_hid_free(NibHIDContext *ctx) {
    if (!ctx) return;
    if (ctx->manager) CFRelease(ctx->manager);
    free(ctx);
}
