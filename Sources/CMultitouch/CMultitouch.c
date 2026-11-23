#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>

typedef void *MTDeviceRef;
typedef void *MTActuatorRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);
typedef int (*MTDeviceGetDeviceIDFn)(MTDeviceRef, uint64_t *);
typedef int (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef MTActuatorRef (*MTActuatorCreateFn)(uint64_t);
typedef int (*MTActuatorOpenFn)(MTActuatorRef);
typedef int (*MTActuatorActuateFn)(MTActuatorRef, int32_t, uint32_t, float, float);

static MTFrameCallback g_callback = NULL;
static CFArrayRef g_devices = NULL;
static MTDeviceStopFn g_stop = NULL;
static MTRegisterFn g_unregister = NULL;
static MTActuatorRef g_actuator = NULL;
static MTActuatorActuateFn g_actuate = NULL;

static int contact_callback(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)device; (void)frame;
    if (g_callback) g_callback(touches, count, timestamp);
    return 0;
}

int mt_start(MTFrameCallback callback) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "TrackDrum: no se pudo cargar MultitouchSupport: %s\n", dlerror());
        return 0;
    }

    MTDeviceCreateListFn createList = (MTDeviceCreateListFn)dlsym(handle, "MTDeviceCreateList");
    MTRegisterFn registerCb = (MTRegisterFn)dlsym(handle, "MTRegisterContactFrameCallback");
    MTDeviceStartFn start = (MTDeviceStartFn)dlsym(handle, "MTDeviceStart");
    MTDeviceGetDeviceIDFn getID = (MTDeviceGetDeviceIDFn)dlsym(handle, "MTDeviceGetDeviceID");
    MTDeviceIsBuiltInFn isBuiltIn = (MTDeviceIsBuiltInFn)dlsym(handle, "MTDeviceIsBuiltIn");
    MTActuatorCreateFn actCreate = (MTActuatorCreateFn)dlsym(handle, "MTActuatorCreateFromDeviceID");
    MTActuatorOpenFn actOpen = (MTActuatorOpenFn)dlsym(handle, "MTActuatorOpen");
    g_actuate = (MTActuatorActuateFn)dlsym(handle, "MTActuatorActuate");
    g_stop = (MTDeviceStopFn)dlsym(handle, "MTDeviceStop");
    g_unregister = (MTRegisterFn)dlsym(handle, "MTUnregisterContactFrameCallback");

    if (!createList || !registerCb || !start) {
        fprintf(stderr, "TrackDrum: faltan símbolos en MultitouchSupport\n");
        return 0;
    }

    g_callback = callback;
    g_devices = createList();
    if (!g_devices) return 0;

    CFIndex n = CFArrayGetCount(g_devices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
        registerCb(dev, contact_callback);
        start(dev, 0);

        // Motor háptico: preferimos el trackpad integrado.
        if (getID && actCreate && actOpen && g_actuate) {
            int builtin = isBuiltIn ? isBuiltIn(dev) : 1;
            if (!g_actuator || builtin) {
                uint64_t devID = 0;
                if (getID(dev, &devID) == 0) {
                    MTActuatorRef act = actCreate(devID);
                    if (act && actOpen(act) == 0) g_actuator = act;
                }
            }
        }
    }
    return (int)n;
}

void mt_stop(void) {
    if (!g_devices) return;
    CFIndex n = CFArrayGetCount(g_devices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
        if (g_unregister) g_unregister(dev, contact_callback);
        if (g_stop) g_stop(dev);
    }
    CFRelease(g_devices);
    g_devices = NULL;
    g_callback = NULL;
}

int mt_haptic(int actuationID) {
    if (!g_actuator || !g_actuate) return -1;
    return g_actuate(g_actuator, actuationID, 0, 0.0f, 2.0f);
}
