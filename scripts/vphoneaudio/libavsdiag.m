// libavsdiag — diagnostic injection into audiomxd to trace AppleVirtIOSound
// (AVIOPlugin/AVIODevice) device creation. All key methods live on the ASD
// base classes (ASDPlugin/ASDAudioDevice), which exist at ctor time, so we
// swizzle them race-free and log the full create/add flow to /tmp/avsdiag.log.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>

static void dlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/avsdiag.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

typedef id  (*msg_id)(id, SEL);
typedef long(*msg_long)(id, SEL);

static IMP orig_addAudioDevice, orig_initDev, orig_addOut, orig_addIn, orig_setDefOut, orig_setDefSys;

static IMP swz(Class c, SEL sel, IMP nimp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { dlog(@"[avsdiag] MISSING %@ on %s", NSStringFromSelector(sel), c?class_getName(c):"(nil)"); return NULL; }
    return method_setImplementation(m, nimp);
}

static NSString *uidOf(id dev) {
    if (dev && [dev respondsToSelector:@selector(deviceUID)])
        return ((msg_id)objc_msgSend)(dev, @selector(deviceUID));
    return @"?";
}
static NSUInteger devCount(id plugin) {
    if (plugin && [plugin respondsToSelector:@selector(audioDevices)]) {
        id a = ((msg_id)objc_msgSend)(plugin, @selector(audioDevices));
        return a ? [a count] : 0;
    }
    return 9999;
}

static long my_addAudioDevice(id self, SEL _cmd, id dev) {
    dlog(@"[avsdiag] >> addAudioDevice: plugin=%s dev=%@ uid=%@ (before count=%lu)",
         object_getClassName(self), dev, uidOf(dev), (unsigned long)devCount(self));
    long r = ((long(*)(id,SEL,id))orig_addAudioDevice)(self, _cmd, dev);
    dlog(@"[avsdiag] << addAudioDevice ret=%ld (after count=%lu)", r, (unsigned long)devCount(self));
    return r;
}
static id my_initDev(id self, SEL _cmd, id uid, id plugin) {
    dlog(@"[avsdiag] >> initWithDeviceUID:%@ withPlugin:%s", uid, object_getClassName(plugin));
    id r = ((id(*)(id,SEL,id,id))orig_initDev)(self, _cmd, uid, plugin);
    dlog(@"[avsdiag] << initWithDeviceUID ret=%@ (nil=%d)", r, r==nil);
    return r;
}
static void my_addOut(id self, SEL _cmd, id s)  { dlog(@"[avsdiag] addOutputStream: dev=%@ stream=%@", uidOf(self), s); ((void(*)(id,SEL,id))orig_addOut)(self,_cmd,s); }
static void my_addIn(id self, SEL _cmd, id s)   { dlog(@"[avsdiag] addInputStream: dev=%@ stream=%@", uidOf(self), s); ((void(*)(id,SEL,id))orig_addIn)(self,_cmd,s); }
static void my_setDefOut(id self, SEL _cmd, BOOL b){ dlog(@"[avsdiag] setCanBeDefaultOutputDevice:%d dev=%@", b, uidOf(self)); ((void(*)(id,SEL,BOOL))orig_setDefOut)(self,_cmd,b); }
static void my_setDefSys(id self, SEL _cmd, BOOL b){ dlog(@"[avsdiag] setCanBeDefaultSystemDevice:%d dev=%@", b, uidOf(self)); ((void(*)(id,SEL,BOOL))orig_setDefSys)(self,_cmd,b); }

static void dumpOwn(const char *clsname) {
    Class c = objc_getClass(clsname);
    if (!c) return;
    unsigned n=0; Method *ml = class_copyMethodList(c, &n);
    NSMutableString *s=[NSMutableString string];
    for (unsigned j=0;j<n;j++) [s appendFormat:@"%@ ", NSStringFromSelector(method_getName(ml[j]))];
    if (ml) free(ml);
    dlog(@"[avsdiag] %s OWN methods(%u): %@", clsname, n, s);
}

__attribute__((constructor))
static void avsdiag_init(void) {
    @autoreleasepool {
        dlog(@"[avsdiag] ===== loaded in pid %d =====", getpid());
        void *h = dlopen("/System/Library/PrivateFrameworks/AudioServerDriver.framework/AudioServerDriver", RTLD_NOW);
        Class plug = objc_getClass("ASDPlugin");
        Class dev  = objc_getClass("ASDAudioDevice");
        dlog(@"[avsdiag] dlopen ASD=%p ASDPlugin=%p ASDAudioDevice=%p", h, plug, dev);
        orig_addAudioDevice = swz(plug, @selector(addAudioDevice:), (IMP)my_addAudioDevice);
        orig_initDev   = swz(dev, @selector(initWithDeviceUID:withPlugin:), (IMP)my_initDev);
        orig_addOut    = swz(dev, @selector(addOutputStream:), (IMP)my_addOut);
        orig_addIn     = swz(dev, @selector(addInputStream:), (IMP)my_addIn);
        orig_setDefOut = swz(dev, @selector(setCanBeDefaultOutputDevice:), (IMP)my_setDefOut);
        orig_setDefSys = swz(dev, @selector(setCanBeDefaultSystemDevice:), (IMP)my_setDefSys);
        dlog(@"[avsdiag] swizzles installed");
        // When the plugin loads, dump what AVIOPlugin/AVIODevice override (the trigger entry points).
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            for (int i=0;i<5000;i++) {
                if (objc_getClass("AVIOPlugin")) {
                    dlog(@"[avsdiag] AVIOPlugin appeared after %dms", i);
                    dumpOwn("AVIOPlugin");
                    dumpOwn("AVIODevice");
                    dumpOwn("AVIOStream");
                    return;
                }
                usleep(1000);
            }
            dlog(@"[avsdiag] AVIOPlugin never appeared within 5s");
        });
    }
}
