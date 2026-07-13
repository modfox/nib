// CWacomHID.h — minimal C shim over IOHIDManager for the DTH2420 driver.
// Opens a matching Wacom HID interface and delivers raw input reports to a
// Swift callback. Kept deliberately thin; all protocol logic lives in Swift.
#ifndef C_WACOM_HID_H
#define C_WACOM_HID_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Called for each input report. `report` is valid only for the call duration.
// `reportID` is the HID report ID (first byte for numbered reports).
typedef void (*WacomHIDReportCallback)(void *ctx,
                                       uint32_t reportID,
                                       const uint8_t *report,
                                       size_t length);

// Called on device match/removal so the daemon can react to hotplug.
typedef void (*WacomHIDDeviceCallback)(void *ctx, uint16_t vendorID, uint16_t productID);

typedef struct WacomHIDContext WacomHIDContext;

// Create a manager that matches (vendorID, productID). Pass productID = 0 to
// match any product for the vendor. Does not open until wacom_hid_run().
WacomHIDContext *wacom_hid_create(uint16_t vendorID, uint16_t productID,
                                  WacomHIDReportCallback onReport,
                                  WacomHIDDeviceCallback onAttach,
                                  WacomHIDDeviceCallback onDetach,
                                  void *userContext);

// Send a feature report (used for the pen mode-switch / config). Returns 0 on success.
int wacom_hid_send_feature(WacomHIDContext *ctx, uint32_t reportID,
                           const uint8_t *data, size_t length);

// Send an output report (used for the touch enable / vendor config). Returns 0 on success.
int wacom_hid_send_output(WacomHIDContext *ctx, uint32_t reportID,
                          const uint8_t *data, size_t length);

// Open the manager and run its run-loop sources on the current run loop.
// Returns 0 on success (call CFRunLoopRun() after, or use wacom_hid_run_blocking()).
int wacom_hid_start(WacomHIDContext *ctx);

// Convenience: start + CFRunLoopRun() (blocks forever).
void wacom_hid_run_blocking(WacomHIDContext *ctx);

void wacom_hid_stop(WacomHIDContext *ctx);
void wacom_hid_free(WacomHIDContext *ctx);

#ifdef __cplusplus
}
#endif
#endif
