#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef double IOHIDFloat;
typedef unsigned int IOOptionBits;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateFn)(CFAllocatorRef allocator);
typedef void (*IOHIDEventSystemClientDispatchEventFn)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t transducerType,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    uint32_t buttonMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat twist,
    Boolean range,
    Boolean touch,
    IOOptionBits options);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFn)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat twist,
    Boolean range,
    Boolean touch,
    IOOptionBits options);
typedef void (*IOHIDEventAppendEventFn)(IOHIDEventRef event, IOHIDEventRef childEvent, IOOptionBits options);
typedef void (*IOHIDEventSetIntegerValueFn)(IOHIDEventRef event, uint32_t field, int value);

enum {
    kDigitizerEventRange = 1u << 0,
    kDigitizerEventTouch = 1u << 1,
    kDigitizerEventPosition = 1u << 2,
    kDigitizerTransducerFinger = 2,
    kDigitizerTransducerHand = 3,
    kDigitizerIntegratedDisplayField = 0x000B000B
};

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s point-x point-y [hold-ms]\n", argv0);
    fprintf(stderr, "Example: %s 187.5 333.5 80\n", argv0);
}

static double parse_coordinate(const char *value, const char *name) {
    char *end = NULL;
    double parsed = strtod(value, &end);
    if (!end || *end != '\0' || parsed < 0.0) {
        fprintf(stderr, "%s must be a non-negative number: %s\n", name, value);
        exit(2);
    }
    return parsed;
}

static void *required_symbol(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol) {
        fprintf(stderr, "Missing IOKit symbol %s: %s\n", name, dlerror());
        exit(3);
    }
    return symbol;
}

static IOHIDEventRef digitizer_event(
    IOHIDEventCreateDigitizerEventFn create_digitizer,
    IOHIDEventCreateDigitizerFingerEventFn create_finger,
    IOHIDEventAppendEventFn append_event,
    IOHIDEventSetIntegerValueFn set_integer,
    double x,
    double y,
    bool touching) {
    uint32_t mask = kDigitizerEventRange | kDigitizerEventPosition;
    if (touching) {
        mask |= kDigitizerEventTouch;
    }

    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = create_digitizer(
        kCFAllocatorDefault,
        now,
        kDigitizerTransducerHand,
        0,
        1,
        mask,
        0,
        x,
        y,
        0.0,
        touching ? 1.0 : 0.0,
        0.0,
        true,
        touching,
        0);

    IOHIDEventRef finger = create_finger(
        kCFAllocatorDefault,
        now,
        1,
        2,
        mask,
        x,
        y,
        0.0,
        touching ? 1.0 : 0.0,
        0.0,
        true,
        touching,
        0);

    if (set_integer) {
        set_integer(hand, kDigitizerIntegratedDisplayField, 1);
        set_integer(finger, kDigitizerIntegratedDisplayField, 1);
    }

    append_event(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        usage(argv[0]);
        return 2;
    }

    double x = parse_coordinate(argv[1], "point-x");
    double y = parse_coordinate(argv[2], "point-y");
    int hold_ms = 80;
    if (argc == 4) {
        hold_ms = atoi(argv[3]);
        if (hold_ms < 10) {
            hold_ms = 10;
        }
    }

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) {
        fprintf(stderr, "Could not load IOKit: %s\n", dlerror());
        return 3;
    }

    IOHIDEventSystemClientCreateFn create_client =
        (IOHIDEventSystemClientCreateFn)required_symbol(iokit, "IOHIDEventSystemClientCreate");
    IOHIDEventSystemClientDispatchEventFn dispatch_event =
        (IOHIDEventSystemClientDispatchEventFn)required_symbol(iokit, "IOHIDEventSystemClientDispatchEvent");
    IOHIDEventCreateDigitizerEventFn create_digitizer =
        (IOHIDEventCreateDigitizerEventFn)required_symbol(iokit, "IOHIDEventCreateDigitizerEvent");
    IOHIDEventCreateDigitizerFingerEventFn create_finger =
        (IOHIDEventCreateDigitizerFingerEventFn)required_symbol(iokit, "IOHIDEventCreateDigitizerFingerEvent");
    IOHIDEventAppendEventFn append_event =
        (IOHIDEventAppendEventFn)required_symbol(iokit, "IOHIDEventAppendEvent");
    IOHIDEventSetIntegerValueFn set_integer =
        (IOHIDEventSetIntegerValueFn)dlsym(iokit, "IOHIDEventSetIntegerValue");

    IOHIDEventSystemClientRef client = create_client(kCFAllocatorDefault);
    if (!client) {
        fprintf(stderr, "Could not create IOHIDEventSystemClient.\n");
        return 4;
    }

    IOHIDEventRef down = digitizer_event(create_digitizer, create_finger, append_event, set_integer, x, y, true);
    dispatch_event(client, down);
    CFRelease(down);

    usleep((useconds_t)hold_ms * 1000);

    IOHIDEventRef up = digitizer_event(create_digitizer, create_finger, append_event, set_integer, x, y, false);
    dispatch_event(client, up);
    CFRelease(up);

    CFRelease(client);
    dlclose(iokit);
    printf("tap %.5f %.5f %dms\n", x, y, hold_ms);
    return 0;
}
