// Sets the iPhone Duo simulator's hinge angle. Built for the simulator and run
// INSIDE the simulated device by duo-hinge.sh (`xcrun simctl spawn`); not
// part of the app.
//
// Xcode 27.1 has no command or test API for the Duo's hinge: Device Hub's pose
// buttons and its hidden hinge slider are the only built-in controls. The
// slider posts a vendor-defined HID event into the device (usage page 0xFF61,
// usage 0x5B) whose payload is a binary-serialized dictionary carrying the
// angle; this posts the same event through the device's HID event system.
//
//   duo-hinge <degrees>    0 = closed ... 180 = fully open

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// IOKit SPI (exported by IOKit.framework, not in the public headers).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t timeStamp, uint32_t usagePage,
    uint32_t usage, uint32_t version, const uint8_t *data, CFIndex length, uint32_t options);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int type, CFDictionaryRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);

enum {
    kHingeUsagePage = 0xFF61,
    kHingeUsage = 0x5B,
    kClientTypeSimple = 4,
    kSerializeBinary = 1,
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: duo-hinge <degrees 0-180>\n");
        return 64;
    }
    double degrees = atof(argv[1]);
    if (degrees < 0) degrees = 0;
    if (degrees > 180) degrees = 180;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
    if (!client) {
        fprintf(stderr, "duo-hinge: no HID event system client\n");
        return 1;
    }

    // The payload Device Hub's hinge slider sends.
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &degrees);
    const void *keys[] = {CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")};
    const void *values[] = {CFSTR("com.apple.Virtualization"), CFSTR("hinge-slider-control"), CFSTR("range"), value};
    CFDictionaryRef payload = CFDictionaryCreate(NULL, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = IOCFSerialize(payload, kSerializeBinary);
    if (!data) {
        fprintf(stderr, "duo-hinge: could not serialize the payload\n");
        return 1;
    }
    IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), kHingeUsagePage,
        kHingeUsage, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0);
    if (!event) {
        fprintf(stderr, "duo-hinge: could not create the HID event\n");
        return 1;
    }
    IOHIDEventSystemClientDispatchEvent(client, event);
    usleep(100000);  // let the event system deliver it before the process exits

    CFRelease(event);
    CFRelease(data);
    CFRelease(payload);
    CFRelease(value);
    CFRelease(client);
    return 0;
}
