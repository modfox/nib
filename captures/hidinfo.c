// hidinfo.c — enumerate Wacom HID devices and dump their report descriptors.
// Part of the DTH2420 RE toolkit. Build:
//   clang -o hidinfo hidinfo.c -framework IOKit -framework CoreFoundation
// Usage: ./hidinfo            (list all Wacom VID 0x056a HID devices + descriptors)
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

#define WACOM_VID 0x056a

static long propInt(IOHIDDeviceRef d, CFStringRef key) {
    long v = 0;
    CFTypeRef r = IOHIDDeviceGetProperty(d, key);
    if (r && CFGetTypeID(r) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)r, kCFNumberLongType, &v);
    return v;
}
static void propStr(IOHIDDeviceRef d, CFStringRef key, char *buf, size_t n) {
    buf[0] = 0;
    CFTypeRef r = IOHIDDeviceGetProperty(d, key);
    if (r && CFGetTypeID(r) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)r, buf, n, kCFStringEncodingUTF8);
}

int main(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(mgr, NULL);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set) { printf("no HID devices\n"); return 1; }
    CFIndex n = CFSetGetCount(set);
    IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
    CFSetGetValues(set, (const void **)devs);

    for (CFIndex i = 0; i < n; i++) {
        IOHIDDeviceRef d = devs[i];
        long vid = propInt(d, CFSTR(kIOHIDVendorIDKey));
        if (vid != WACOM_VID) continue;
        long pid = propInt(d, CFSTR(kIOHIDProductIDKey));
        long up  = propInt(d, CFSTR(kIOHIDPrimaryUsagePageKey));
        long u   = propInt(d, CFSTR(kIOHIDPrimaryUsageKey));
        char name[256]; propStr(d, CFSTR(kIOHIDProductKey), name, sizeof name);
        printf("\n==== %s  VID=0x%04lx PID=0x%04lx  usagePage=0x%02lx usage=0x%02lx ====\n",
               name, vid, pid, up, u);

        CFTypeRef rd = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDReportDescriptorKey));
        if (rd && CFGetTypeID(rd) == CFDataGetTypeID()) {
            CFDataRef data = (CFDataRef)rd;
            CFIndex len = CFDataGetLength(data);
            const UInt8 *b = CFDataGetBytePtr(data);
            printf("report descriptor (%ld bytes):\n", len);
            for (CFIndex k = 0; k < len; k++) {
                printf("%02x ", b[k]);
                if ((k & 15) == 15) printf("\n");
            }
            printf("\n");
        } else {
            printf("(no report descriptor property available)\n");
        }
    }
    free(devs); CFRelease(set); CFRelease(mgr);
    return 0;
}
