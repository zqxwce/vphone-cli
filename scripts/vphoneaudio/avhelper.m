// avhelper — entitled observer for AppleVirtIOSound.driver device creation.
// Loads the HAL plugin, interposes IOKit, swizzles AVIO/ASD ObjC methods,
// then drives AVIOPluginFactory -> Initialize itself (with the virtio
// UserClient entitlement) and logs exactly where the virtio device-setup dies.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>

static FILE *gLog;
static void L(const char *fmt, ...) {
    va_list a; va_start(a, fmt);
    if (gLog) { vfprintf(gLog, fmt, a); fputc('\n', gLog); fflush(gLog); }
    va_end(a);
}

// ---------- IOKit interpose (catch the virtio UserClient interaction) ----------
#define INTERPOSE(newf, oldf) \
  __attribute__((used)) static struct { const void *n; const void *o; } \
  _interp_##oldf __attribute__((section("__DATA,__interpose"))) = { (const void*)(newf), (const void*)(oldf) };

static kern_return_t my_IOServiceOpen(io_service_t svc, task_port_t task, uint32_t type, io_connect_t *conn) {
    static kern_return_t (*real)(io_service_t,task_port_t,uint32_t,io_connect_t*) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "IOServiceOpen");
    kern_return_t r = real(svc, task, type, conn);
    L("[io] IOServiceOpen(svc=%u type=%u) -> 0x%x conn=%u", svc, type, r, conn?*conn:0);
    return r;
}
INTERPOSE(my_IOServiceOpen, IOServiceOpen)

static CFMutableDictionaryRef my_IOServiceMatching(const char *name) {
    static CFMutableDictionaryRef (*real)(const char*) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "IOServiceMatching");
    L("[io] IOServiceMatching(\"%s\")", name?name:"(null)");
    return real(name);
}
INTERPOSE(my_IOServiceMatching, IOServiceMatching)

static kern_return_t my_IOServiceGetMatchingServices(mach_port_t mp, CFDictionaryRef m, io_iterator_t *it) {
    static kern_return_t (*real)(mach_port_t,CFDictionaryRef,io_iterator_t*) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "IOServiceGetMatchingServices");
    kern_return_t r = real(mp, m, it);
    L("[io] IOServiceGetMatchingServices -> 0x%x", r);
    return r;
}
INTERPOSE(my_IOServiceGetMatchingServices, IOServiceGetMatchingServices)

static kern_return_t my_IOConnectCallMethod(mach_port_t c, uint32_t sel,
    const uint64_t *in, uint32_t inc, const void *ins, size_t insc,
    uint64_t *out, uint32_t *outc, void *outs, size_t *outsc) {
    static kern_return_t (*real)(mach_port_t,uint32_t,const uint64_t*,uint32_t,const void*,size_t,uint64_t*,uint32_t*,void*,size_t*) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "IOConnectCallMethod");
    kern_return_t r = real(c, sel, in, inc, ins, insc, out, outc, outs, outsc);
    L("[io] IOConnectCallMethod(conn=%u sel=%u inScalar=%u inStruct=%zu) -> 0x%x", c, sel, inc, insc, r);
    return r;
}
INTERPOSE(my_IOConnectCallMethod, IOConnectCallMethod)

// ---------- ObjC swizzles on the ASD device-creation chain ----------
typedef id (*msg_id)(id, SEL);
static IMP o_init, o_add, o_addIn, o_addOut, o_setDef;

static NSString *uidOf(id d){ return (d && [d respondsToSelector:@selector(deviceUID)]) ? ((msg_id)objc_msgSend)(d,@selector(deviceUID)) : @"?"; }

static id s_init(id self, SEL _c, id uid, id plug){ L("[asd] >> -[%s initWithDeviceUID:%s withPlugin:%s]", object_getClassName(self), [[uid description]UTF8String], object_getClassName(plug)); id r=((id(*)(id,SEL,id,id))o_init)(self,_c,uid,plug); L("[asd] << initWithDeviceUID ret=%p", r); return r; }
static long s_add(id self, SEL _c, id dev){ L("[asd] >> -[%s addAudioDevice:%s]", object_getClassName(self), [[uidOf(dev)description]UTF8String]); long r=((long(*)(id,SEL,id))o_add)(self,_c,dev); L("[asd] << addAudioDevice ret=%ld", r); return r; }
static void s_addIn(id self, SEL _c, id s){ L("[asd] addInputStream: dev=%s", [[uidOf(self)description]UTF8String]); ((void(*)(id,SEL,id))o_addIn)(self,_c,s); }
static void s_addOut(id self, SEL _c, id s){ L("[asd] addOutputStream: dev=%s", [[uidOf(self)description]UTF8String]); ((void(*)(id,SEL,id))o_addOut)(self,_c,s); }
static void s_setDef(id self, SEL _c, BOOL b){ L("[asd] setCanBeDefaultOutputDevice:%d", b); ((void(*)(id,SEL,BOOL))o_setDef)(self,_c,b); }

static IMP swz(const char *cls, SEL sel, IMP nimp){ Class c=objc_getClass(cls); if(!c){L("[swz] no class %s",cls);return NULL;} Method m=class_getInstanceMethod(c,sel); if(!m){L("[swz] no %s on %s",sel_getName(sel),cls);return NULL;} return method_setImplementation(m,nimp); }

static void dumpMethods(const char *cls){ Class c=objc_getClass(cls); if(!c){L("[dump] no class %s",cls);return;} unsigned n=0; Method*ml=class_copyMethodList(c,&n); NSMutableString*s=[NSMutableString string]; for(unsigned i=0;i<n;i++)[s appendFormat:@"%s ",sel_getName(method_getName(ml[i]))]; if(ml)free(ml); L("[dump] %s own methods(%u): %s", cls, n, [s UTF8String]); }

// ---------- AudioServerPlugIn host interface (minimal logging stubs) ----------
#include <ptrauth.h>
// Host interface: the plugin authenticates these fn ptrs with `blraaz` (key IA,
// ZERO discriminator). Store them as raw void* and sign them ourselves IA/0,
// because the compiler's default function-pointer signing uses a type
// discriminator that mismatches blraaz.
// NOTE: disassembly of -[ASDPlugin changedProperty:forObject:] shows it calls
// host+0 (blraaz), so PropertiesChanged is at offset 0 — NO leading _reserved.
typedef struct {
    void *PropertiesChanged;
    void *CopyFromStorage;
    void *WriteToStorage;
    void *DeleteFromStorage;
    void *RequestDeviceConfigurationChange;
} HostIF;
static OSStatus h_PC(void*h,UInt32 o,UInt32 n,const void*a){ L("[host] PropertiesChanged obj=%u n=%u",o,n); return 0; }
static OSStatus h_CF(void*h,CFStringRef k,CFPropertyListRef*out){ L("[host] CopyFromStorage(%s)", k?[(__bridge NSString*)k UTF8String]:"?"); if(out)*out=NULL; return 0; }
static OSStatus h_WF(void*h,CFStringRef k,CFPropertyListRef v){ L("[host] WriteToStorage(%s)", k?[(__bridge NSString*)k UTF8String]:"?"); return 0; }
static OSStatus h_DF(void*h,CFStringRef k){ L("[host] DeleteFromStorage"); return 0; }
static OSStatus h_RC(void*h,UInt32 o,UInt64 c,void*i){ L("[host] RequestDeviceConfigurationChange obj=%u change=%llu",o,(unsigned long long)c); return 0; }
static HostIF gHost;
// sign a C function ptr as IA/zero-disc (matches the plugin's blraaz)
static void *signIA0(void *fn){ return ptrauth_sign_unauthenticated(ptrauth_strip(fn, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0); }
static void buildHost(void){
    gHost.PropertiesChanged = signIA0((void*)h_PC);
    gHost.CopyFromStorage = signIA0((void*)h_CF);
    gHost.WriteToStorage = signIA0((void*)h_WF);
    gHost.DeleteFromStorage = signIA0((void*)h_DF);
    gHost.RequestDeviceConfigurationChange = signIA0((void*)h_RC);
}

int main(void) {
    gLog = fopen("/tmp/avhelper.log", "w");
    L("=== avhelper start pid %d ===", getpid());
    // Does the plugin's LoadingConditions matching ({IOProviderClass:AppleVirtIOSound}) actually match?
    { io_iterator_t it=0; kern_return_t kr=IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleVirtIOSound"), &it);
      int c=0; io_object_t o; while((o=IOIteratorNext(it))){c++; IOObjectRelease(o);} if(it)IOObjectRelease(it);
      L("[match] IOServiceGetMatchingServices(AppleVirtIOSound) kr=0x%x count=%d (this is what audiomxd LoadingConditions evaluates)", kr, c); }
    { io_iterator_t it=0; kern_return_t kr=IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleVirtIOSoundUserClient"), &it);
      int c=0; io_object_t o; while((o=IOIteratorNext(it))){c++; IOObjectRelease(o);} if(it)IOObjectRelease(it);
      L("[match] AppleVirtIOSoundUserClient kr=0x%x count=%d", kr, c); }
    void *asd = dlopen("/System/Library/PrivateFrameworks/AudioServerDriver.framework/AudioServerDriver", RTLD_NOW);
    void *h = dlopen("/System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver/AppleVirtIOSound", RTLD_NOW);
    L("dlopen ASD=%p plugin=%p", asd, h);
    if (!h) { L("plugin dlopen FAILED: %s", dlerror()); return 1; }
    // swizzle the shared ASD device-creation methods (AVIO subclasses inherit them)
    o_init  = swz("ASDAudioDevice", @selector(initWithDeviceUID:withPlugin:), (IMP)s_init);
    o_add   = swz("ASDPlugin", @selector(addAudioDevice:), (IMP)s_add);
    o_addIn = swz("ASDAudioDevice", @selector(addInputStream:), (IMP)s_addIn);
    o_addOut= swz("ASDAudioDevice", @selector(addOutputStream:), (IMP)s_addOut);
    o_setDef= swz("ASDAudioDevice", @selector(setCanBeDefaultOutputDevice:), (IMP)s_setDef);
    L("swizzles installed");
    dumpMethods("AVIOPlugin"); dumpMethods("AVIODevice"); dumpMethods("AVIOStream");
    // call the factory
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = (void*(*)(CFAllocatorRef,CFUUIDRef))dlsym(h, "AVIOPluginFactory");
    L("AVIOPluginFactory sym=%p", factory);
    if (!factory) { L("no factory sym"); return 1; }
    CFUUIDRef type = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    void *ref = factory(NULL, type);
    L("factory -> ref=%p", ref);
    if (!ref) { L("factory returned NULL"); return 1; }
    void **vt = *(void***)ref;           // ref is Interface**; *ref = vtable
    L("vtable=%p Initialize=%p", vt, vt[4]);
    // Initialize(driver=ref, host=&gHost)  -- index 4 (after _reserved,QI,AddRef,Release)
    OSStatus (*Init)(void*, void*) = (OSStatus(*)(void*,void*))vt[4];
    buildHost();
    L("calling Initialize (host fn ptrs signed IA/0) ...");
    OSStatus st = Init(ref, &gHost);
    L("=== Initialize -> 0x%x (0=noErr) ===", st);
    // give any async discovery a moment
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    L("=== avhelper done ===");
    if (gLog) fclose(gLog);
    return 0;
}
