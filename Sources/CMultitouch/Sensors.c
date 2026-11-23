#include "CMultitouch.h"
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/IOKitLib.h>
#include <pthread.h>
#include <string.h>

// Busca el primer dispositivo HID con esa pareja usage page / usage.
static IOHIDDeviceRef find_device(IOHIDManagerRef manager, int page, int usage) {
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), p);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey), u);
    CFRelease(p); CFRelease(u);
    IOHIDManagerSetDeviceMatching(manager, match);
    CFRelease(match);

    CFSetRef set = IOHIDManagerCopyDevices(manager);
    if (!set) return NULL;
    IOHIDDeviceRef result = NULL;
    if (CFSetGetCount(set) > 0) {
        const void *values[16];
        CFIndex count = CFSetGetCount(set);
        if (count > 16) count = 16;
        CFSetGetValues(set, values);
        result = (IOHIDDeviceRef)values[0];
        CFRetain(result);
    }
    CFRelease(set);
    return result;
}

// ---------------------------------------------------------------------------
// Sensor de ángulo de la tapa (usage page 0x20 Sensor, usage 0x8A Orientation)
// ---------------------------------------------------------------------------

static IOHIDDeviceRef g_lid = NULL;
static int g_lid_tried = 0;

int lid_angle(void) {
    if (!g_lid_tried) {
        g_lid_tried = 1;
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        g_lid = find_device(manager, 0x20, 0x8A);
        if (g_lid && IOHIDDeviceOpen(g_lid, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
            CFRelease(g_lid);
            g_lid = NULL;
        }
    }
    if (!g_lid) return -1;

    uint8_t report[8] = {0};
    CFIndex length = sizeof(report);
    if (IOHIDDeviceGetReport(g_lid, kIOHIDReportTypeFeature, 1, report, &length) != kIOReturnSuccess || length < 3)
        return -1;
    return (int)((report[2] << 8) | report[1]);
}

// ---------------------------------------------------------------------------
// Acelerómetro oculto de Apple Silicon (AppleSPU, usage page 0xFF00, usage 3)
// Informes de 22 bytes: x, y, z como int32 en los bytes 6, 10 y 14 (÷ 65536 = g)
// ---------------------------------------------------------------------------

static AccelCallback g_accel_cb = NULL;
static uint8_t g_accel_buffer[64];

static void accel_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t reportID, uint8_t *report, CFIndex length) {
    (void)ctx; (void)result; (void)sender; (void)type; (void)reportID;
    if (length < 18 || !g_accel_cb) return;
    int32_t x, y, z;
    memcpy(&x, report + 6, 4);
    memcpy(&y, report + 10, 4);
    memcpy(&z, report + 14, 4);
    g_accel_cb(x / 65536.0, y / 65536.0, z / 65536.0);
}

// El driver viene dormido (ReportInterval = 0): hay que despertarlo.
static void wake_spu_sensors(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) != KERN_SUCCESS)
        return;
    int one = 1, interval = 1000; // µs
    CFNumberRef n1 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &one);
    CFNumberRef ni = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &interval);
    io_object_t service;
    while ((service = IOIteratorNext(it))) {
        IORegistryEntrySetCFProperty(service, CFSTR("SensorPropertyReportingState"), n1);
        IORegistryEntrySetCFProperty(service, CFSTR("SensorPropertyPowerState"), n1);
        IORegistryEntrySetCFProperty(service, CFSTR("ReportInterval"), ni);
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    CFRelease(n1); CFRelease(ni);
}

static void *accel_thread(void *arg) {
    IOHIDDeviceRef device = (IOHIDDeviceRef)arg;
    IOHIDDeviceRegisterInputReportCallback(device, g_accel_buffer, sizeof(g_accel_buffer), accel_report, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return NULL;
}

int accel_start(AccelCallback callback) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    wake_spu_sensors();
    IOHIDDeviceRef device = find_device(manager, 0xFF00, 3);
    if (!device) return 0;
    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        CFRelease(device);
        return 0;
    }
    g_accel_cb = callback;
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&thread, &attr, accel_thread, device);
    pthread_attr_destroy(&attr);
    return 1;
}
