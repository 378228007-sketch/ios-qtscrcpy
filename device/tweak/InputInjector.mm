#import "InputInjector.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
// Private IOKit HID SPI, not in the public headers, so declared here. Touches are
// synthesized as digitizer events and dispatched through the system HID client.
// That only works from inside SpringBoard (the bundle identity is the
// authorization) and routes the event to whatever app is in the foreground.
typedef uint32_t IOHIDDigitizerTransducerType;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOOptionBits;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern "C" {
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                             IOHIDDigitizerTransducerType type, uint32_t index,
                                             uint32_t identity, uint32_t eventMask,
                                             uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y,
                                             IOHIDFloat z, IOHIDFloat tipPressure,
                                             IOHIDFloat barrelPressure, Boolean range, Boolean touch,
                                             IOOptionBits options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                                   uint32_t index, uint32_t identity,
                                                   uint32_t eventMask, IOHIDFloat x, IOHIDFloat y,
                                                   IOHIDFloat z, IOHIDFloat tipPressure,
                                                   IOHIDFloat twist, Boolean range, Boolean touch,
                                                   IOOptionBits options);
void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child);
void IOHIDEventSetIntegerValue(IOHIDEventRef e, IOHIDEventField f, int v);
void IOHIDEventSetFloatValue(IOHIDEventRef e, IOHIDEventField f, IOHIDFloat v);
void IOHIDEventSetSenderID(IOHIDEventRef e, uint64_t senderID);
uint64_t IOHIDEventGetSenderID(IOHIDEventRef e);
uint32_t IOHIDEventGetType(IOHIDEventRef e);
IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                            uint32_t usagePage, uint32_t usage, Boolean down,
                                            IOOptionBits options);
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef, void *cb, void *target,
                                                 void *refcon);
}
#define kIOHIDDigitizerEventRange 0x00000001u
#define kIOHIDDigitizerEventTouch 0x00000002u
#define kIOHIDDigitizerEventPosition 0x00000004u
#define kIOHIDDigitizerEventIdentity 0x00000020u
#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDEventTypeDigitizer 11
// Digitizer field selectors (same magic values long-used by touch tools).
#define kFieldDigitizerIsDisplayInteg 0x000b0019
#define kFieldDigitizerEventMask 0x000b0007
#define kFieldDigitizerRange 0x000b0008
#define kFieldDigitizerTouch 0x000b0009
#define kFieldDigitizerMajorRadius 0x000b0014
#define kFieldDigitizerMinorRadius 0x000b0015
static uint64_t gSenderID = 0;
static IOHIDEventSystemClientRef gClient = NULL;
static IOHIDEventSystemClientRef gMonitor = NULL;
// Learn the real digitizer sender id from the first physical touch. Some builds
// drop injected events without it.
static void senderCallback(void *target, void *refcon, void *service, IOHIDEventRef event) {
    if (gSenderID == 0 && IOHIDEventGetType(event) == kIOHIDEventTypeDigitizer) {
        gSenderID = IOHIDEventGetSenderID(event);
        NSLog(@"[ioscpyhook] captured digitizer senderID 0x%llx", gSenderID);
    }
}
static void hidInit(void) {
    if (gClient) {
        return;
    }
    gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) {
        NSLog(@"[ioscpyhook] IOHIDEventSystemClientCreate returned NULL (not in SpringBoard?)");
        return;
    }
    gMonitor = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (gMonitor) {
        IOHIDEventSystemClientRegisterEventCallback(gMonitor, (void *)senderCallback, NULL, NULL);
        IOHIDEventSystemClientScheduleWithRunLoop(gMonitor, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
}
// Rotate a normalized point into the panel's native-portrait space. The digitizer
// space does not rotate with the UI. orient: 1=portrait, 2=upsideDown,
// 3=landscapeLeft, 4=landscapeRight.
static void rotatePoint(int orient, float nx, float ny, float *rx, float *ry) {
    switch (orient) {
        case 3:  *rx = ny;        *ry = 1.0f - nx; break;
        case 4:  *rx = 1.0f - ny; *ry = nx;        break;
        case 2:  *rx = 1.0f - nx; *ry = 1.0f - ny; break;
        default: *rx = nx;        *ry = ny;        break;
    }
    *rx = fmaxf(0.0f, fminf(1.0f, *rx));
    *ry = fmaxf(0.0f, fminf(1.0f, *ry));
}
// Cached foreground-app orientation (1=portrait, 2=upsideDown, 3=landscapeLeft,
// 4=landscapeRight). Updated on the main thread (UIApplication is main-only).
// The off-main capture and touch paths just read this.
static volatile int gOrientation = 1;
// Map a UIInterfaceOrientation to our internal 1-4. Uses the enum constants so
// it's correct regardless of their raw numeric values.
static int mapInterfaceOrientation(NSInteger o) {
    switch (o) {
        case UIInterfaceOrientationPortrait:           return 1;
        case UIInterfaceOrientationPortraitUpsideDown: return 2;
        case UIInterfaceOrientationLandscapeLeft:      return 3;
        case UIInterfaceOrientationLandscapeRight:     return 4;
        default:                                       return 1;
    }
}
// Read the frontmost app's interface orientation. Must run on the main thread.
// activeInterfaceOrientation is SpringBoard's frontmost-app orientation across
// the versions we target. Fall back to the status bar orientation, then portrait,
// so an OS that lacks it just stays upright instead of failing.
static int readForegroundOrientation(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return 1;
    }
    // Resolve both selectors at runtime so the build doesn't trip on the
    // undeclared (private) one or the deprecated one.
    SEL active = NSSelectorFromString(@"activeInterfaceOrientation");
    if ([app respondsToSelector:active]) {
        NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(app, active);
        return mapInterfaceOrientation(o);
    }
    SEL bar = NSSelectorFromString(@"statusBarOrientation");
    if ([app respondsToSelector:bar]) {
        NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(app, bar);
        return mapInterfaceOrientation(o);
    }
    return 1;
}
void IOSPYOrientationStart(void) {
    static dispatch_source_t timer = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Poll on the main queue (UIApplication is main-thread only). Just a cheap
        // selector read a few times a second, never blocks the main thread.
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(0.4 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            int o = readForegroundOrientation();
            if (o >= 1 && o <= 4 && o != gOrientation) {
                gOrientation = o;
                NSLog(@"[ioscpyhook] orientation -> %d", o);
            }
        });
        dispatch_resume(timer);
    });
}
int IOSPYCurrentOrientation(void) {
    return gOrientation;
}
static int currentOrientation(void) {
    return gOrientation;
}

// =====================================================================================
// MULTI-FINGER INJECTION
// -------------------------------------------------------------------------------------
// iOS interprets ONE dispatched digitizer "hand" as the complete snapshot of the
// fingers currently on the panel. Any finger that is NOT appended to that hand is
// implicitly lifted. The original implementation created a brand-new hand per touch
// message and appended only the finger that message mentioned, so a second finger
// down silently cancelled the first one - the screen could never show two points.
//
// Fix: keep an active-finger table (id -> position) and append EVERY active finger
// to every dispatched hand. The finger this message is about carries the real
// event mask (down/up = range+touch, move = position); the others carry position
// only so they stay down without re-announcing themselves.
//
// Second fix: the original 1.2 s safety net force-released a hardcoded finger id 0
// with the last global coordinates, which killed a legitimately held steer-wheel
// finger. It now releases only fingers that are actually still down, and each one
// at its own position.
// =====================================================================================
#define IOSPY_MAX_FINGERS 10

static bool     gFingerActive[IOSPY_MAX_FINGERS];
static float    gFingerX[IOSPY_MAX_FINGERS];
static float    gFingerY[IOSPY_MAX_FINGERS];
static int      gFingerCount = 0;
static uint64_t gTouchEpoch = 0;
// Build marker: lets you confirm the running dylib is the multi-touch build
// (`strings ioscpyhook.dylib | grep IOSCPY_MULTITOUCH`).
static bool     gMTLogged = false;
static const char *kIOSPYMTTag = "IOSCPY_MULTITOUCH_V1";

void IOSPYInjectTouch(IOSPYTouchPhase phase, uint8_t fingerID, float x, float y) {
    hidInit();
    if (!gClient) {
        return;
    }
    int idx = (int)fingerID;
    if (idx < 0 || idx >= IOSPY_MAX_FINGERS) {
        NSLog(@"[ioscpyhook] finger id %u out of table range", fingerID);
        return;
    }

    // A repeated down for an already-held finger is the client's keep-alive
    // re-assert (the 1.2 s safety net above). Treat it as a move so the digitizer
    // does not see a second "touch begin" for the same finger.
    if (phase == IOSPYTouchDown && gFingerActive[idx]) {
        phase = IOSPYTouchMove;
    }

    if (phase == IOSPYTouchDown) {
        gFingerActive[idx] = true;
        gFingerCount++;
        gTouchEpoch++;
        // Safety net: nothing else down/up for 1.2 s means a system edge gesture
        // probably swallowed the real up. Release everything that is still held,
        // each at its own position (never a hardcoded id 0).
        uint64_t epoch = gTouchEpoch;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gTouchEpoch == epoch && gFingerCount > 0) {
                for (int i = 0; i < IOSPY_MAX_FINGERS; i++) {
                    if (gFingerActive[i]) {
                        IOSPYInjectTouch(IOSPYTouchUp, (uint8_t)i, gFingerX[i], gFingerY[i]);
                    }
                }
            }
        });
    } else if (phase == IOSPYTouchUp) {
        gTouchEpoch++;
    } else {
        if (!gFingerActive[idx]) {
            // A move for a finger we never saw go down: adopt it rather than drop it.
            gFingerActive[idx] = true;
            gFingerCount++;
        }
    }

    gFingerX[idx] = x;
    gFingerY[idx] = y;

    if (!gMTLogged && gFingerCount >= 2) {
        gMTLogged = true;
        NSLog(@"[ioscpyhook] %s active=%d", kIOSPYMTTag, gFingerCount);
    }

    float rx, ry;
    rotatePoint(currentOrientation(), x, y, &rx, &ry);

    uint64_t ts = mach_absolute_time();
    Boolean touch = (phase != IOSPYTouchUp);
    Boolean range = touch;
    uint32_t selfMask = (phase == IOSPYTouchMove)
                            ? kIOHIDDigitizerEventPosition
                            : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0, selfMask, 0, 0, 0, 0, 0,
        0, range, touch, 0);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerIsDisplayInteg, 1);

    // (1) The finger this message is about.
    IOHIDEventRef mainFinger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, (uint32_t)fingerID, (uint32_t)fingerID + 1, selfMask,
        (IOHIDFloat)rx, (IOHIDFloat)ry, 0, touch ? 1.0 : 0.0, 0, range, touch, 0);
    IOHIDEventSetFloatValue(mainFinger, kFieldDigitizerMajorRadius, 0.04f);
    IOHIDEventSetFloatValue(mainFinger, kFieldDigitizerMinorRadius, 0.04f);
    IOHIDEventAppendEvent(parent, mainFinger);
    CFRelease(mainFinger);

    // (2) Every other finger still down. Position-only keeps it alive and moves it,
    //     without claiming a new touch-begin that would reset its gesture state.
    for (int i = 0; i < IOSPY_MAX_FINGERS; i++) {
        if (i == idx || !gFingerActive[i]) {
            continue;
        }
        float orx, ory;
        rotatePoint(currentOrientation(), gFingerX[i], gFingerY[i], &orx, &ory);
        IOHIDEventRef other = IOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault, ts, (uint32_t)i, (uint32_t)i + 1,
            kIOHIDDigitizerEventPosition, (IOHIDFloat)orx, (IOHIDFloat)ory, 0, 1.0, 0,
            true, true, 0);
        IOHIDEventSetFloatValue(other, kFieldDigitizerMajorRadius, 0.04f);
        IOHIDEventSetFloatValue(other, kFieldDigitizerMinorRadius, 0.04f);
        IOHIDEventAppendEvent(parent, other);
        CFRelease(other);
    }

    // What this hand reports. A down/up announces a finger arriving or leaving
    // (range + touch, with its identity); a move announces a position change.
    uint32_t parentMask = (phase == IOSPYTouchMove)
                              ? kIOHIDDigitizerEventPosition
                              : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
                                 kIOHIDDigitizerEventIdentity);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerEventMask, parentMask);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerRange, range ? 1 : 0);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerTouch, touch ? 1 : 0);
    if (gSenderID != 0) {
        IOHIDEventSetSenderID(parent, gSenderID);
    }
    IOHIDEventSystemClientDispatchEvent(gClient, parent);
    CFRelease(parent);

    if (phase == IOSPYTouchUp && gFingerActive[idx]) {
        gFingerActive[idx] = false;
        gFingerCount--;
        if (gFingerCount < 0) {
            gFingerCount = 0;
        }
    }
}

// Press and release a HID button (e.g. the home button as consumer "menu").
static void injectButton(uint32_t usagePage, uint32_t usage) {
    hidInit();
    if (!gClient) {
        return;
    }
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                        usagePage, usage, down ? true : false, 0);
        if (!e) {
            continue;
        }
        if (gSenderID != 0) {
            IOHIDEventSetSenderID(e, gSenderID);
        }
        IOHIDEventSystemClientDispatchEvent(gClient, e);
        CFRelease(e);
    }
}
// keyboard: HID keyboard page 0x07 routes to the foreground app's field
#define kHIDPage_Keyboard 0x07
#define kHIDUsage_LeftShift 0xE1
#define kHIDUsage_LeftGUI 0xE3
static void keyEvent(uint32_t usage, bool down) {
    hidInit();
    if (!gClient) {
        return;
    }
    IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                    kHIDPage_Keyboard, usage, down ? true : false, 0);
    if (!e) {
        return;
    }
    // Keyboard events route best with NO sender id (the captured one belongs to
    // the touch panel). Only set it if typing doesn't land during testing.
    IOHIDEventSystemClientDispatchEvent(gClient, e);
    CFRelease(e);
}
// Press a key, optionally with Shift held, like a real keyboard chord.
static void typeUsage(uint32_t usage, bool shift) {
    if (shift) {
        keyEvent(kHIDUsage_LeftShift, true);
    }
    keyEvent(usage, true);
    keyEvent(usage, false);
    if (shift) {
        keyEvent(kHIDUsage_LeftShift, false);
    }
}
// Press a key with Command held (the iOS editing shortcuts).
static void cmdChord(uint32_t usage) {
    keyEvent(kHIDUsage_LeftGUI, true);
    keyEvent(usage, true);
    keyEvent(usage, false);
    keyEvent(kHIDUsage_LeftGUI, false);
}
// Map a US-ASCII character to its HID keyboard usage and whether Shift is needed.
static bool charToUsage(unichar c, uint32_t *usage, bool *shift) {
    *shift = false;
    if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = true; return true; }
    if (c >= '1' && c <= '9') { *usage = 0x1E + (c - '1'); return true; }
    if (c == '0') { *usage = 0x27; return true; }
    switch (c) {
        case ' ':  *usage = 0x2C; return true;
        case '\t': *usage = 0x2B; return true;
        case '\n': case '\r': *usage = 0x28; return true;
        case '!': *usage = 0x1E; *shift = true; return true;
        case '@': *usage = 0x1F; *shift = true; return true;
        case '#': *usage = 0x20; *shift = true; return true;
        case '$': *usage = 0x21; *shift = true; return true;
        case '%': *usage = 0x22; *shift = true; return true;
        case '^': *usage = 0x23; *shift = true; return true;
        case '&': *usage = 0x24; *shift = true; return true;
        case '*': *usage = 0x25; *shift = true; return true;
        case '(': *usage = 0x26; *shift = true; return true;
        case ')': *usage = 0x27; *shift = true; return true;
        case '-': *usage = 0x2D; return true;
        case '_': *usage = 0x2D; *shift = true; return true;
        case '=': *usage = 0x2E; return true;
        case '+': *usage = 0x2E; *shift = true; return true;
        case '[': *usage = 0x2F; return true;
        case '{': *usage = 0x2F; *shift = true; return true;
        case ']': *usage = 0x30; return true;
        case '}': *usage = 0x30; *shift = true; return true;
        case '\\': *usage = 0x31; return true;
        case '|': *usage = 0x31; *shift = true; return true;
        case ';': *usage = 0x33; return true;
        case ':': *usage = 0x33; *shift = true; return true;
        case '\'': *usage = 0x34; return true;
        case '"': *usage = 0x34; *shift = true; return true;
        case '`': *usage = 0x35; return true;
        case '~': *usage = 0x35; *shift = true; return true;
        case ',': *usage = 0x36; return true;
        case '<': *usage = 0x36; *shift = true; return true;
        case '.': *usage = 0x37; return true;
        case '>': *usage = 0x37; *shift = true; return true;
        case '/': *usage = 0x38; return true;
        case '?': *usage = 0x38; *shift = true; return true;
        default: return false;
    }
}
void IOSPYTypeText(NSString *text) {
    if (text.length == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        hidInit();
        if (!gClient) {
            return;
        }
        NSUInteger n = text.length;
        for (NSUInteger i = 0; i < n; i++) {
            unichar c = [text characterAtIndex:i];
            uint32_t usage = 0;
            bool shift = false;
            if (charToUsage(c, &usage, &shift)) {
                typeUsage(usage, shift);
            }
            // Non-ASCII (accents, emoji) go through the clipboard-paste path.
        }
    });
}
void IOSPYKeyAction(uint8_t code) {
    dispatch_async(dispatch_get_main_queue(), ^{
        hidInit();
        if (!gClient) {
            return;
        }
        switch (code) {
            case 1:  typeUsage(0x28, false); break; // Enter
            case 2:  typeUsage(0x2A, false); break; // Backspace
            case 3:  typeUsage(0x2B, false); break; // Tab
            case 4:  typeUsage(0x29, false); break; // Escape
            case 5:  typeUsage(0x50, false); break; // Left
            case 6:  typeUsage(0x4F, false); break; // Right
            case 7:  typeUsage(0x52, false); break; // Up
            case 8:  typeUsage(0x51, false); break; // Down
            case 10: cmdChord(0x04); break;         // Cmd+A select all
            case 11: cmdChord(0x06); break;         // Cmd+C copy
            case 12: cmdChord(0x19); break;         // Cmd+V paste
            case 13: cmdChord(0x1B); break;         // Cmd+X cut
            case 14: cmdChord(0x1D); break;         // Cmd+Z undo
            default: break;
        }
    });
}
// system actions (run in SpringBoard, main thread)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
static id sharedOf(const char *cls) {
    Class c = objc_getClass(cls);
    if (!c) {
        return nil;
    }
    if ([c respondsToSelector:@selector(sharedInstance)]) {
        return [c performSelector:@selector(sharedInstance)];
    }
    if ([c respondsToSelector:@selector(sharedInstanceIfExists)]) {
        return [c performSelector:@selector(sharedInstanceIfExists)];
    }
    return nil;
}
// Close Control Center / Notification Center if they're showing. The HID home
// button doesn't dismiss them on a no-home-button device.
static void dismissOverlays(void) {
    // Control Center.
    id cc = sharedOf("SBControlCenterController");
    if ([cc respondsToSelector:@selector(isPresented)] &&
        [cc respondsToSelector:@selector(dismissAnimated:)]) {
        BOOL (*shown)(id, SEL) = (BOOL (*)(id, SEL))[cc methodForSelector:@selector(isPresented)];
        if (shown(cc, @selector(isPresented))) {
            void (*fn)(id, SEL, BOOL) =
                (void (*)(id, SEL, BOOL))[cc methodForSelector:@selector(dismissAnimated:)];
            fn(cc, @selector(dismissAnimated:), YES);
        }
    }
    // Notification Center is the CoverSheet pulled down over an app, so dismiss it
    // by setting it un-presented.
    id cs = sharedOf("SBCoverSheetPresentationManager");
    SEL setSel = @selector(setCoverSheetPresented:animated:withCompletion:);
    if ([cs respondsToSelector:@selector(isPresented)] && [cs respondsToSelector:setSel]) {
        BOOL (*shown)(id, SEL) = (BOOL (*)(id, SEL))[cs methodForSelector:@selector(isPresented)];
        if (shown(cs, @selector(isPresented))) {
            void (*fn)(id, SEL, BOOL, BOOL, id) =
                (void (*)(id, SEL, BOOL, BOOL, id))[cs methodForSelector:setSel];
            fn(cs, setSel, NO, YES, nil);
        }
    }
}
static void actionHome(void) {
    // Close any pulled-down overlay first, then go home.
    dismissOverlays();
    injectButton(0x0C, 0x40);
}
static void actionLock(void) {
    id mgr = sharedOf("SBLockScreenManager");
    if ([mgr respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
        void (*fn)(id, SEL, long, id) =
            (void (*)(id, SEL, long, id))[mgr methodForSelector:@selector(lockUIFromSource:withOptions:)];
        fn(mgr, @selector(lockUIFromSource:withOptions:), 1, nil);
    }
}
static void actionWake(void) {
    id bl = sharedOf("SBBacklightController");
    if ([bl respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)]) {
        void (*fn)(id, SEL, long) =
            (void (*)(id, SEL, long))[bl methodForSelector:@selector(turnOnScreenFullyWithBacklightSource:)];
        fn(bl, @selector(turnOnScreenFullyWithBacklightSource:), 1);
    } else if ([bl respondsToSelector:@selector(setBacklightFactor:source:)]) {
        void (*fn)(id, SEL, float, long) =
            (void (*)(id, SEL, float, long))[bl methodForSelector:@selector(setBacklightFactor:source:)];
        fn(bl, @selector(setBacklightFactor:source:), 1.0f, 1);
    }
}
static void actionAppSwitcher(void) {
    // SpringBoard's own handler for the "open app switcher" hardware-keyboard
    // shortcut. Closest match to what we want and present across recent iOS
    // releases. It ignores its sender, so nil is fine.
    id sb = [UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(_handleOpenAppSwitcherShortcut:)]) {
        [sb performSelector:@selector(_handleOpenAppSwitcherShortcut:) withObject:nil];
        return;
    }
    // Older layouts kept the switcher on dedicated controllers.
    id sw = sharedOf("SBMainSwitcherViewController");
    if ([sw respondsToSelector:@selector(activateSwitcherNoninteractively)]) {
        [sw performSelector:@selector(activateSwitcherNoninteractively)];
        return;
    }
    if ([sw respondsToSelector:@selector(activateSwitcher)]) {
        [sw performSelector:@selector(activateSwitcher)];
        return;
    }
    id uic = sharedOf("SBUIController");
    if ([uic respondsToSelector:@selector(_toggleSwitcher)]) {
        [uic performSelector:@selector(_toggleSwitcher)];
    }
}
// "Back". Cmd+[ is the most reliable trigger: UIKit registers it as the
// UINavigationController pop and WebKit/Safari as web-back, and it routes to the
// focused foreground app like a real keyboard, so it works cross-process from
// SpringBoard with no touch senderID (no first physical tap needed). Apps with a
// fully custom navigation stack respond to neither this nor a swipe, which is the
// realistic ceiling. We don't also fire an edge-swipe, which would double-back
// wherever both are honored.
static void actionBack(void) {
    cmdChord(0x2F); // Cmd+[
}
void IOSPYSystemAction(uint16_t action) {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (action) {
            case 1: actionHome(); break;
            case 2: actionLock(); break;
            case 3: actionWake(); break;
            case 4: actionAppSwitcher(); break;
            case 8: actionBack(); break;
            default: NSLog(@"[ioscpyhook] unhandled system action %u", action); break;
        }
    });
}
#pragma clang diagnostic pop
