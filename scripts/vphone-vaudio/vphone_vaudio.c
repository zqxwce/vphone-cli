// vphone_vaudio.c — custom AudioServerPlugIn that impersonates Apple's
// VirtualAudio HAL plugin (bundle id com.apple.audio.CoreAudio.VirtualAudio).
//
// Goal: publish a software-clocked virtual OUTPUT device so the iOS routing
// layer (vaem / FigVAEndpointManager, which looks this bundle id up) adopts it
// and creates a system-wide AVAudioSession route for ALL apps — clearing the
// -10851 that blocks AVAudioEngine.start on this codec-less research VM. The
// mixed output PCM is tapped in DoIOOperation and (Phase 4) forwarded to the
// host over the vphone audio relay.
//
// Structure follows Apple's canonical NullAudio AudioServerPlugIn sample,
// implemented against the vendored AudioServerPlugIn.h ABI (iOS SDK omits it).
//
// Phase 2 = standard virtual device + software clock (this file).
// Phase 3 = vaem-specific 'vain'/'duid' properties (stubbed here, refined on device).
// Phase 4 = tap WriteMix PCM -> relay (frame-counter stub here).

#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/AudioHardware.h>        // device/stream property selectors (vendored)
#include <CoreAudio/AudioServerPlugIn.h>    // driver interface (vendored)
#include <mach/mach_time.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <ptrauth.h>

// MARK: - logging (never blocks audiomxd; appends to /tmp)
static void vva_log(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[512]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    FILE* f = fopen("/tmp/vphone_vaudio.log", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

// MARK: - object model (fixed AudioObjectIDs)
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 2
    kObjectID_Device        = 3,
    kObjectID_Stream_Output = 4,
};

// MARK: - device constants
// UID MUST be kVirtualAudioDeviceUID_Default — vaem's FigVAEndpointManagerCreate
// resolves the default VAD by querying the system object's 'duid' with qualifier
// "VirtualAudioDevice_Default"; the HAL routes that to our TranslateUIDToDevice,
// so our device UID must match for vaem to find us. (RE: research/audio.)
#define kDevice_UID          "VirtualAudioDevice_Default"
#define kDevice_ModelUID     "VPhoneVirtualAudioModel"
#define kDevice_Name         "vPhone Virtual Audio"
#define kManufacturer_Name   "Apple Inc."
#define kSampleRate          48000.0
#define kChannels            2
#define kRingBufferFrames    19200u   // zero-timestamp period (frames)

// vaem custom property selectors (scope 'glob'); see FigVAEndpointManagerCreate.
// vaem queries 'vain'(virtualDevicePlugInID) + 'prts'(kVirtualAudioPlugInPropertyConnectedPorts)
// on the PlugIn object, and resolves 'duid'(default VADID) on the system object via our
// TranslateUIDToDevice. It then waits on vadInitializationCompleteSemaphore, which is signaled
// when the ConnectedPorts ('prts') listener fires — so we must answer 'prts' AND post a
// PropertiesChanged('prts') once the device is up. (RE in research/audio + memory cont'd #27.)
enum {
    kVAProperty_vain = 'vain',   // virtualDevicePlugInID
    kVAProperty_duid = 'duid',   // default VADID
    kVAProperty_prts = 'prts',   // kVirtualAudioPlugInPropertyConnectedPorts
};

// MARK: - globals
static pthread_mutex_t           gStateMutex      = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef  gHost            = NULL;
static UInt32                    gRefCount        = 0;
static Boolean                   gStreamActive    = true;
static Boolean                   gDeviceRunning   = false;
// Diagnostic gating (read once in Initialize from Data-volume markers, so we can
// iterate behavior with a marker toggle + reboot instead of a ramdisk redeploy):
//   vva_enable_device : publish the virtual device (default OFF → plugin loads but
//                       reports zero devices, like a stock no-HW plugin → VM boots).
//   vva_verbose       : log every property query (the "last line before the wedge"
//                       is the HAL-server block point — our lldb replacement).
#define kMarker_EnableDevice "/var/jb/var/mobile/Library/vva_enable_device"
#define kMarker_Verbose      "/var/jb/var/mobile/Library/vva_verbose"
#define kMarker_Kill         "/var/jb/var/mobile/Library/vva_kill"
static Boolean                   gDeviceEnabled   = false;
static Boolean                   gVerbose         = false;

// MARK: - post-boot vaem re-invoke (self-contained; runs only inside audiomxd)
// Boot-time vaem's getPlugin runs before the HAL loads us (resolves 0, bails). Post-boot
// the plugin IS loaded and the DSC veneer makes vaemGetVirtualAudioPlugin resolve US
// (via 'bidp' -> gCMSM+116), so re-invoking FigVAEndpointManagerCreate now adopts our
// plugin. Feature flags (run_hybrid_hal + startup_sequence_change) already ON at boot;
// no gCMSM seeding / byte-patch needed (the veneer + flags handle those).
#define kMarker_Reinvoke   "/var/jb/var/mobile/Library/vva_reinvoke"
#define kMarker_Inject     "/var/jb/var/mobile/Library/vva_inject"
#define VPA_DSC_MXREGISTER 0x1b3453b30ULL  // exported _MXRegisterEndpointManager (slide anchor)
#define VPA_DSC_VACREATE   0x1b3477398ULL  // _FigVAEndpointManagerCreate
#define VPA_DSC_REGISTER   0x1b3442c4cULL  // _FigRouteDiscoveryManagerRegisterEndpointManager
// FigRoutingContext-injection descriptor-key CFString globals (MediaExperience __DATA_CONST).
// dlsym is tried first; these DSC vmaddrs are the slide-relative fallback (see memory: routing wall).
#define VPA_DSC_KEY_AUDIOROUTENAME 0x1e67cfc08ULL  // kFigEndpointDescriptorKey_AudioRouteName
#define VPA_DSC_KEY_ROUTENAME_USB  0x1e67cfc48ULL  // kFigEndpointDescriptorKey_AudioRouteName_USB
#define VPA_DSC_COPYENDPOINTFORPORT 0x1b33aebf4ULL // _vaemCopyEndpointForPort(uint32 portTypeFourCC)->MXEndpoint
#define VPA_DSC_FIGENDPOINTCOPYPROP 0x1b34577c4ULL // _FigEndpointCopyProperty(endpoint, CFStringRef key)->value
#define VPA_DSC_ROUTEDESCFROMEPS    0x1b33ae334ULL // _MXEndpointDescriptorCopyAvailableRouteDescriptorsFromEndpoints(eps,x1)
#define VPA_DSC_POSTNOTIF           0x1b33f4cc4ULL // _vaemPostAvailableEndpointsChangedNotification(bool) — reads _gCMSM+88, async-posts the endpoints-changed notification cmsm listens on to re-run discovery+selection
// VAD output port-type FourCCs (from live vadOutputPortTypeToFigOutputDeviceNameDict):
//   Speaker=0x7073706B USB=0x7075736F SystemCapture=0x70736370 Receiver=0x70726563
typedef int  (*vpa_va_create_t)(CFAllocatorRef, CFTypeRef, void**);
typedef void (*vpa_va_register_t)(void*);

// Diagnostic: what does 'bidp'(our bundle id) resolve to in-audiomxd, and does querying
// 'vain'/'duid' on that id ROUTE to our plugin's GetPropertyData (we'd see obj=N sel=vain
// in our own verbose log)? Enumerate 'plg#' to find which PlugIn object answers duid (only
// ours does). Answers whether the veneer's gCMSM+116 id actually reaches us. (cont'd #35)
static void vva_probe_routing(void) {
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
    if (!ca) { vva_log("[vva] probe: dlopen CoreAudio failed"); return; }
    int (*gds)(unsigned,const void*,unsigned,const void*,unsigned*) = dlsym(ca,"AudioObjectGetPropertyDataSize");
    int (*gd)(unsigned,const void*,unsigned,const void*,unsigned*,void*) = dlsym(ca,"AudioObjectGetPropertyData");
    if (!gds || !gd) { vva_log("[vva] probe: dlsym failed"); return; }
    unsigned bidp[3]={'bidp','glob',0}; CFStringRef bid=CFSTR("com.apple.audio.CoreAudio.VirtualAudio");
    unsigned pid=0, psz=4; int br=gd(1u,bidp,(unsigned)sizeof(bid),&bid,&psz,&pid);
    vva_log("[vva] probe: bidp rc=0x%x plugInID=%u", (unsigned)br, pid);
    if (br==0 && pid) {
        unsigned vq[3]={'vain','glob',0}; unsigned vv=0xdead, vs=4; int vr=gd(pid,vq,0,NULL,&vs,&vv);
        vva_log("[vva] probe: vain on %u rc=0x%x val=%u (if OUR plugin logged obj=%u sel=vain, routing works)", pid,(unsigned)vr,vv,pid);
    }
    unsigned plgq[3]={'plg#','glob',0}; unsigned plgsz=0; gds(1u,plgq,0,NULL,&plgsz);
    unsigned npl=plgsz/4; if(npl>32)npl=32; unsigned plist[32]; unsigned rd=npl*4;
    if (npl && gd(1u,plgq,0,NULL,&rd,plist)==0) {
        for (unsigned i=0;i<npl;i++){ unsigned p=plist[i];
            unsigned dq[3]={'duid','glob',0}; unsigned dv=0xdead,ds=4; int dr=gd(p,dq,0,NULL,&ds,&dv);
            unsigned dlq[3]={'dev#','glob',0}; unsigned dl=0; gds(p,dlq,0,NULL,&dl);
            vva_log("[vva] probe: PLG[%u]=%u duid(rc=0x%x) dev#=%u", i,p,(unsigned)dr,dl/4); }
    }
}

// Find MY plugin's system AudioObjectID: 'bidp'(bundleid) returns the built-in STUB
// (dev#=0), which shadows us. Instead resolve MY DEVICE via TranslateUIDToDevice, then
// find the PlugIn in 'plg#' that OWNS that device (its 'dev#' contains it). That's the
// real plugin id whose vain/duid/prts route to our GetPropertyData. (Beats cont'd #38,
// which seeded the bidp/stub id.)
#define VPA_DSC_GCMSM_PLUGIN 0x1ea8cd3a4ULL  // gCMSM+116 = "the VirtualAudio plugin" object

static unsigned vva_find_my_plugin_id(void) {
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
    if (!ca) return 0;
    int (*gds)(unsigned,const void*,unsigned,const void*,unsigned*) = dlsym(ca,"AudioObjectGetPropertyDataSize");
    int (*gd)(unsigned,const void*,unsigned,const void*,unsigned*,void*) = dlsym(ca,"AudioObjectGetPropertyData");
    if (!gds || !gd) return 0;
    // 1) my device id via TranslateUIDToDevice('uidd') qualifier = UID CFString
    unsigned uidd[3]={'uidd','glob',0}; CFStringRef uid=CFSTR(kDevice_UID);
    unsigned mydev=0, ds=4; if (gd(1u,uidd,(unsigned)sizeof(uid),&uid,&ds,&mydev)!=0 || !mydev) {
        vva_log("[vva] find: TranslateUIDToDevice(%s) failed", kDevice_UID); return 0; }
    vva_log("[vva] find: my device id=%u", mydev);
    // 2) which plugin owns mydev?
    unsigned plgq[3]={'plg#','glob',0}; unsigned plgsz=0; gds(1u,plgq,0,NULL,&plgsz);
    unsigned npl=plgsz/4; if(npl>32)npl=32; unsigned plist[32]; unsigned rd=npl*4;
    if (!npl || gd(1u,plgq,0,NULL,&rd,plist)!=0) return 0;
    for (unsigned i=0;i<npl;i++){ unsigned P=plist[i];
        unsigned devq[3]={'dev#','glob',0}; unsigned dsz=0; gds(P,devq,0,NULL,&dsz);
        unsigned nd=dsz/4; if(nd==0||nd>64)continue; unsigned dl[64]; unsigned drd=nd*4;
        if (gd(P,devq,0,NULL,&drd,dl)!=0) continue;
        for (unsigned j=0;j<nd;j++) if (dl[j]==mydev) { vva_log("[vva] find: my plugin id=%u (owns dev %u)", P, mydev); return P; }
    }
    vva_log("[vva] find: no plugin owns my device %u", mydev); return 0;
}

static void vva_reinvoke_vaem(void) {
    vva_probe_routing();
    void *me = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    if (!me) { vva_log("[vva] reinvoke: dlopen MediaExperience failed"); return; }
    void *mx = dlsym(me, "MXRegisterEndpointManager");
    if (!mx) { vva_log("[vva] reinvoke: dlsym MXRegisterEndpointManager failed"); return; }
    uintptr_t mx_raw = (uintptr_t)ptrauth_strip((void(*)(void))mx, ptrauth_key_function_pointer);
    uintptr_t slide  = mx_raw - VPA_DSC_MXREGISTER;
    vpa_va_create_t   create = ptrauth_sign_unauthenticated((vpa_va_create_t)(VPA_DSC_VACREATE + slide), ptrauth_key_function_pointer, 0);
    vpa_va_register_t reg    = ptrauth_sign_unauthenticated((vpa_va_register_t)(VPA_DSC_REGISTER + slide), ptrauth_key_function_pointer, 0);
    // Seed gCMSM+116 with MY plugin id (the one owning my device), so create()'s vain/duid/prts
    // queries route to OUR GetPropertyData. Unpatched 'pibi' fails without clobbering the seed.
    unsigned myplug = vva_find_my_plugin_id();
    if (myplug) {
        volatile uint32_t *g = (volatile uint32_t*)(VPA_DSC_GCMSM_PLUGIN + slide);
        uint32_t prev = *g; *g = myplug;
        vva_log("[vva] reinvoke: seeded gCMSM+116 @%p was=%u -> %u", (void*)g, prev, myplug);
    }
    vva_log("[vva] reinvoke: slide=%p create=%p", (void*)slide, (void*)(VPA_DSC_VACREATE+slide));
    void *mgr = NULL;
    int rc = create(NULL, NULL, &mgr);
    if (myplug) { volatile uint32_t *g=(volatile uint32_t*)(VPA_DSC_GCMSM_PLUGIN+slide);
        vva_log("[vva] reinvoke: gCMSM+116 AFTER create = %u (seeded %u)", *g, myplug); }
    vva_log("[vva] reinvoke: FigVAEndpointManagerCreate rc=%d mgr=%p", rc, mgr);
    if (rc == 0 && mgr) { reg(mgr); vva_log("[vva] reinvoke: registered VirtualAudio endpoint manager"); }
}

// MARK: - endpoint-injection swizzle
// Discovery polls -[MXEndpointDescriptorCache copyAvailableEndpointsForManager:] per registered
// manager; on this VM it returns empty (no connected ports). We build real FigVAEndpoints via
// _vaemCopyEndpointForPort and swizzle that method to APPEND them, so discovery sees endpoints
// and builds routes. (research/audio; memory: project_audio_routing_wall.)
static CFMutableArrayRef gInjectedEndpoints = NULL;
static void*             gVVA_msgSend       = NULL;
static void*             gVVA_origSel       = NULL;  // after exchange -> ORIGINAL imp

static void* vva_copyAvail_repl(void* self, void* _cmd, void* manager) {
    (void)_cmd;
    void* orig = NULL;
    if (gVVA_msgSend && gVVA_origSel) { void* (*msg)(void*,void*,void*) = gVVA_msgSend; orig = msg(self, gVVA_origSel, manager); }
    long oc = orig ? (long)CFArrayGetCount(orig) : 0;
    char mgrd[160] = "?"; { CFStringRef s = manager ? CFCopyDescription(manager) : NULL; if (s) { CFStringGetCString(s, mgrd, sizeof mgrd, kCFStringEncodingUTF8); CFRelease(s); } }
    CFMutableArrayRef out = orig ? CFArrayCreateMutableCopy(NULL, 0, orig) : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (gInjectedEndpoints) CFArrayAppendArray(out, gInjectedEndpoints, CFRangeMake(0, CFArrayGetCount(gInjectedEndpoints)));
    vva_log("[vva] swz: copyAvail(mgr=%.120s) orig=%ld -> %ld", mgrd, oc, (long)CFArrayGetCount(out));
    return out;   // "copy" convention -> caller owns/releases (+1 from CFArrayCreateMutable*)
}

static void vva_install_endpoint_swizzle(void* objc, void*(*getClass)(const char*), void*(*selReg)(const char*)) {
    static int done = 0; if (done) return;
    void* (*getInstMethod)(void*,void*)               = dlsym(objc, "class_getInstanceMethod");
    int   (*addMethod)(void*,void*,void*,const char*) = dlsym(objc, "class_addMethod");
    const char* (*methTypes)(void*)                   = dlsym(objc, "method_getTypeEncoding");
    void  (*exchange)(void*,void*)                    = dlsym(objc, "method_exchangeImplementations");
    gVVA_msgSend = dlsym(objc, "objc_msgSend");
    void* cls = getClass("MXEndpointDescriptorCache");
    if (!cls || !getInstMethod || !addMethod || !exchange || !gVVA_msgSend) { vva_log("[vva] swz: setup failed"); return; }
    void* origSel = selReg("copyAvailableEndpointsForManager:");
    gVVA_origSel  = selReg("vva_copyAvailableEndpointsForManager:");
    void* origM = getInstMethod(cls, origSel);
    if (!origM) { vva_log("[vva] swz: no orig method"); return; }
    addMethod(cls, gVVA_origSel, (void*)vva_copyAvail_repl, methTypes ? methTypes(origM) : "@@:@");
    void* newM = getInstMethod(cls, gVVA_origSel);
    if (!newM) { vva_log("[vva] swz: addMethod failed"); return; }
    exchange(origM, newM);
    done = 1;
    vva_log("[vva] swz: installed on -[MXEndpointDescriptorCache copyAvailableEndpointsForManager:]");
}

// MARK: - direct FigRoutingContext output-device injection (the route bypass)
// On this codec-less VM the MX/AVAudioSession route list (FigRoutingContext) is
// disconnected from the HAL device list, so no device becomes an AVAudioSession output
// (currentRoute.outputs.count==0 -> -10851; nothing pulls our DoIOOperation). From INSIDE
// audiomxd we grab the live shared AVFigRoutingContextOutputContextImpl's opaque Fig structs
// (routingContext/volumeController/commChannelManager + the translator), build an
// AVFigRouteDescriptorOutputDeviceImpl from a route descriptor masquerading as a USB audio
// route, wrap it in an AVOutputDevice, and add it to the routing context via the translator.
// If it lands: FigRoutingContext gains an output -> AVAudioSession route -> apps render ->
// audiomxd pulls DoIOOperation -> host relay. (research/audio/virtio_sound_bridge.md; memory:
// project_audio_routing_wall — ivar offsets, ctor/injector VMAs verified against 23F77 DSC.)
static void vva_inject_output_device(void) {
    void *objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW);
    void *avr  = dlopen("/System/Library/Frameworks/AVRouting.framework/AVRouting", RTLD_NOW);
    void *me   = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    if (!objc || !avr || !me) { vva_log("[vva] inject: dlopen failed objc=%p avr=%p me=%p", objc, avr, me); return; }

    void* (*getClass)(const char*)      = dlsym(objc, "objc_getClass");
    void* (*selReg)(const char*)        = dlsym(objc, "sel_registerName");
    void* (*getIvar)(void*,const char*) = dlsym(objc, "class_getInstanceVariable");
    long  (*ivarOff)(void*)             = dlsym(objc, "ivar_getOffset");
    void* msgp = dlsym(objc, "objc_msgSend");
    if (!getClass||!selReg||!getIvar||!ivarOff||!msgp) { vva_log("[vva] inject: dlsym runtime failed"); return; }
    void* (*m0)(void*,void*)             = msgp;         // [obj sel]
    void* (*m1)(void*,void*,void*)       = msgp;         // [obj sel:arg]
    long  (*mCount)(void*,void*)         = msgp;         // [arr count]

    void* CtxCls  = getClass("AVFigRoutingContextOutputContextImpl");
    void* ImplCls = getClass("AVFigRouteDescriptorOutputDeviceImpl");
    void* DevCls  = getClass("AVOutputDevice");
    if (!CtxCls||!ImplCls||!DevCls) { vva_log("[vva] inject: class lookup failed ctx=%p impl=%p dev=%p", CtxCls,ImplCls,DevCls); return; }

    void* ctx = m0(CtxCls, selReg("sharedSystemAudioContext"));
    if (!ctx) { vva_log("[vva] inject: sharedSystemAudioContext nil"); return; }

    void* ivVol = getIvar(CtxCls, "_volumeController");
    void* ivRC  = getIvar(CtxCls, "_routingContext");
    void* ivTr  = getIvar(CtxCls, "_deviceTranslator");
    void* ivCCM = getIvar(CtxCls, "_commChannelManager");
    if (!ivRC || !ivTr) { vva_log("[vva] inject: ivar lookup failed vol=%p rc=%p tr=%p ccm=%p", ivVol,ivRC,ivTr,ivCCM); return; }
    long oVol = ivVol?ivarOff(ivVol):-1, oRC = ivarOff(ivRC), oTr = ivarOff(ivTr), oCCM = ivCCM?ivarOff(ivCCM):-1;
    void* volCtl = (oVol>=0) ? *(void**)((char*)ctx + oVol) : NULL;
    void* rc     = *(void**)((char*)ctx + oRC);
    void* tr     = *(void**)((char*)ctx + oTr);
    void* ccm    = (oCCM>=0) ? *(void**)((char*)ctx + oCCM) : NULL;
    vva_log("[vva] inject: ctx=%p vol=%p rc=%p tr=%p ccm=%p (off v=%ld r=%ld t=%ld c=%ld)", ctx,volCtl,rc,tr,ccm,oVol,oRC,oTr,oCCM);
    if (!rc || !tr) { vva_log("[vva] inject: missing routingContext/translator"); return; }

    // descriptor keys: dlsym first, DSC slide fallback for the two essential ones
    uintptr_t slide = 0; void *mx = dlsym(me, "MXRegisterEndpointManager");
    if (mx) slide = (uintptr_t)ptrauth_strip((void(*)(void))mx, ptrauth_key_function_pointer) - VPA_DSC_MXREGISTER;
    CFStringRef *pRouteName = dlsym(me, "kFigEndpointDescriptorKey_AudioRouteName");
    CFStringRef *pUSB       = dlsym(me, "kFigEndpointDescriptorKey_AudioRouteName_USB");
    CFStringRef *pRouteNm   = dlsym(me, "kFigEndpointDescriptorKey_RouteName");
    CFStringRef *pPortNum   = dlsym(me, "kFigEndpointDescriptorKey_PortNumber");
    CFStringRef kRouteName = pRouteName ? *pRouteName : (slide ? *(CFStringRef*)(VPA_DSC_KEY_AUDIOROUTENAME+slide) : NULL);
    CFStringRef kUSB       = pUSB       ? *pUSB       : (slide ? *(CFStringRef*)(VPA_DSC_KEY_ROUTENAME_USB +slide) : NULL);
    if (!kRouteName || !kUSB) { vva_log("[vva] inject: key resolve failed rn=%p usb=%p slide=%p", kRouteName,kUSB,(void*)slide); return; }

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, kRouteName, kUSB);
    if (pRouteNm && *pRouteNm) CFDictionarySetValue(d, *pRouteNm, CFSTR("vPhone Audio"));
    if (pPortNum && *pPortNum) { int port = 1; CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &port); CFDictionarySetValue(d, *pPortNum, pn); CFRelease(pn); }

    void* factory = m0(CtxCls, selReg("routingContextFactory"));

    // route discoverer: REQUIRED non-nil by the impl init (CFRetain'd + stored at ivar+32;
    // nil -> init bails to the release/return-nil path @0x1aceac48c). AVCreateRouteDiscovererWithType(t)
    // returns a live FigRouteDiscoverer; try types 0..3, prefer an "Output"-classed one.
    const char* (*classNameOf)(void*) = dlsym(objc, "object_getClassName");
    void* (*avCreateDisc)(long) = dlsym(avr, "AVCreateRouteDiscovererWithType");
    void* disc = NULL;
    if (avCreateDisc) for (long t = 0; t <= 3; t++) {
        void* dd = avCreateDisc(t);
        const char* cn = (dd && classNameOf) ? classNameOf(dd) : NULL;
        vva_log("[vva] inject: discoverer type=%ld -> %p (%s)", t, dd, cn ? cn : "?");
        if (dd) { if (!disc) disc = dd; if (cn && strstr(cn, "Output")) disc = dd; }
    }
    if (!disc) { vva_log("[vva] inject: no route discoverer -> abort"); CFRelease(d); return; }

    // BIND to our device: rewrite the VAD-port -> FigOutputDeviceName map so the USB port resolves
    // to OUR device's name, so the endpoint we build for it binds to OUR HAL device (id 37). Must
    // run BEFORE building the endpoint (the port-endpoint cache memoizes on first build per boot).
    {
        void* mxCls = getClass("MXSessionManager");
        void* mxMgr = mxCls ? m0(mxCls, selReg("sharedInstance")) : NULL;
        void* pd    = mxMgr ? m0(mxMgr, selReg("vadOutputPortTypeToFigOutputDeviceNameDict")) : NULL;
        void* md    = pd    ? m0(pd, selReg("mutableCopy")) : NULL;
        if (md) {
            uint32_t usb = 0x7075736F;   // "puso" USB port type
            CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt32Type, &usb);
            void (*m2)(void*,void*,void*,void*) = msgp;
            m2(md, selReg("setObject:forKey:"), (void*)CFSTR(kDevice_Name), (void*)key);
            m1(mxMgr, selReg("setVadOutputPortTypeToFigOutputDeviceNameDict:"), md);
            vva_log("[vva] inject: remapped USB(0x7075736F) -> FigOutputDeviceName '%s'", kDevice_Name);
            CFRelease(key);
        } else vva_log("[vva] inject: port-dict remap skipped (mgr=%p pd=%p)", mxMgr, pd);
    }

    // Build REAL FigVAEndpoints via vaem (port-type FourCC -> endpoint), store them, and swizzle
    // copyAvailableEndpointsForManager: to append them. Port FourCCs from the live dict.
    void* (*copyEP)(uint32_t) = slide ? ptrauth_sign_unauthenticated((void*(*)(uint32_t))(VPA_DSC_COPYENDPOINTFORPORT + slide), ptrauth_key_function_pointer, 0) : NULL;
    static const uint32_t kPorts[] = { 0x7073706B /*Speaker*/, 0x7075736F /*USB*/, 0x70736370 /*SystemCapture*/, 0x70726563 /*Receiver*/ };
    if (!gInjectedEndpoints) gInjectedEndpoints = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayRemoveAllValues(gInjectedEndpoints);
    if (copyEP) for (int i = 0; i < 4; i++) {
        void* e = copyEP(kPorts[i]);
        char db[200] = "nil"; if (e) { CFStringRef s = CFCopyDescription(e); if (s) { CFStringGetCString(s, db, sizeof db, kCFStringEncodingUTF8); CFRelease(s); } }
        vva_log("[vva] inject: endpoint(%08x)=%p %.160s", kPorts[i], e, db);
        if (e) CFArrayAppendValue(gInjectedEndpoints, e);
    }
    long nep = CFArrayGetCount(gInjectedEndpoints);
    if (nep == 0) { vva_log("[vva] inject: no endpoints built -> abort"); CFRelease(d); return; }

    // Dump the first (Speaker) endpoint's key properties to learn the device binding + routability.
    void* (*figProp)(void*,CFStringRef) = slide ? ptrauth_sign_unauthenticated((void*(*)(void*,CFStringRef))(VPA_DSC_FIGENDPOINTCOPYPROP + slide), ptrauth_key_function_pointer, 0) : NULL;
    if (figProp) {
        void* ep0 = (void*)CFArrayGetValueAtIndex(gInjectedEndpoints, 0);
        static const char* kEPKeys[] = { "FigOutputDeviceName","ModelUID","IsRoutable","RouteDescription","PortName","DefaultRouteDescription","PortID" };
        for (int k = 0; k < 7; k++) {
            char sym[96]; snprintf(sym, sizeof sym, "kFigVAEndpointProperty_%s", kEPKeys[k]);
            CFStringRef* pk = dlsym(me, sym);
            if (!pk || !*pk) { vva_log("[vva] epprop: %s -> (key nil)", kEPKeys[k]); continue; }
            void* v = figProp(ep0, *pk);
            char vb[200] = "nil"; if (v) { CFStringRef s = CFCopyDescription(v); if (s) { CFStringGetCString(s, vb, sizeof vb, kCFStringEncodingUTF8); CFRelease(s); } }
            vva_log("[vva] epprop[%s] = %.170s", kEPKeys[k], vb);
        }
    }

    vva_install_endpoint_swizzle(objc, getClass, selReg);

    // UNTRIED LEVER (2026-07-02): on this codec-less VM route SELECTION is inert — no route
    // forms for ANY device (even Apple's native virtio-snd), because the hardware "endpoints
    // changed" event that drives cmsm's discovery+selection never fires (no audio HW to hotplug).
    // _vaemPostAvailableEndpointsChangedNotification(bool) reads _gCMSM+88 and async-dispatches
    // exactly that notification; cmsm re-runs discovery (our swizzle re-appends the injected
    // endpoints) then route selection. This is the one path that could drive establishment WITHOUT
    // a real hardware trigger. If it lands, outputDevicesFromRoutingContext becomes non-empty.
    if (slide) {
        void (*postNotif)(bool) = ptrauth_sign_unauthenticated((void(*)(bool))(VPA_DSC_POSTNOTIF + slide), ptrauth_key_function_pointer, 0);
        vva_log("[vva] inject: posting vaemPostAvailableEndpointsChangedNotification(1) @%p", (void*)(VPA_DSC_POSTNOTIF + slide));
        postNotif(true);
    }

    // discovery re-queries the managers on AVAudioSession activity (routetest triggers it) or its
    // periodic poll; give it a moment, then read the routing context's current outputs.
    sleep(3);
    void* arr = m1(tr, selReg("outputDevicesFromRoutingContext:"), rc);
    long n = arr ? mCount(arr, selReg("count")) : -1;
    vva_log("[vva] inject: %ld endpoints injected + swizzle installed; outputDevices=%ld", nep, n);

    // DEFINITIVE: do my endpoints convert to route DESCRIPTORS? (last call — if it faults, all
    // prior logs survive). Non-empty => endpoints valid, issue is selection; empty => endpoints
    // rejected at conversion (need real device props).
    void* (*rdFromEps)(void*,void*) = slide ? ptrauth_sign_unauthenticated((void*(*)(void*,void*))(VPA_DSC_ROUTEDESCFROMEPS + slide), ptrauth_key_function_pointer, 0) : NULL;
    if (rdFromEps) {
        void* rds = rdFromEps(gInjectedEndpoints, NULL);
        long rn = rds ? (long)CFArrayGetCount(rds) : -1;
        vva_log("[vva] inject: RouteDescriptorsFromEndpoints(%ld eps) -> %ld route descriptors", nep, rn);
        if (rds && rn > 0) { CFStringRef s = CFCopyDescription((CFArrayRef)rds); char b[240]="?"; if (s){CFStringGetCString(s,b,sizeof b,kCFStringEncodingUTF8);CFRelease(s);} vva_log("[vva] inject: rd[0..]=%.220s", b); }
    }
    (void)disc; (void)volCtl; (void)factory; (void)ccm; (void)classNameOf; (void)ImplCls; (void)DevCls; (void)getIvar; (void)ivarOff;
    CFRelease(d);
}

static void* vva_reinvoke_thread(void* arg) {
    (void)arg;
    for (;;) {                                  // markers touched from host after audiomxd settles
        if (access(kMarker_Reinvoke, F_OK) == 0) { unlink(kMarker_Reinvoke); vva_reinvoke_vaem(); }
        if (access(kMarker_Inject,   F_OK) == 0) { unlink(kMarker_Inject);   vva_inject_output_device(); }
        sleep(1);
    }
    return NULL;
}

static void vva_reinvoke_once(void) {
    pthread_t t; pthread_create(&t, NULL, vva_reinvoke_thread, NULL); pthread_detach(t);
    vva_log("[vva] reinvoke: waiter armed (audiomxd) — touch %s to fire", kMarker_Reinvoke);
}

// Spawn the re-invoke waiter ONCE, and only inside audiomxd (client processes lack the
// cmsm-set-up gVAEM that FigVAEndpointManagerCreate needs -> would NULL-deref).
static void vva_maybe_start_reinvoke(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    const char* pn = getprogname();
    if (!pn || strcmp(pn, "audiomxd") != 0) return;
    pthread_once(&once, vva_reinvoke_once);
}

// Format a FourCC selector as 4 printable chars for logging.
static void fourcc(UInt32 v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff); out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >>  8) & 0xff); out[3] = (char)(v & 0xff); out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 32 || out[i] > 126) out[i] = '.';
}

// software clock
static Float64  gHostTicksPerFrame = 0.0;
static UInt64   gAnchorHostTime    = 0;
static UInt64   gNumberTimeStamps  = 0;

// Phase 4 tap stats
static UInt64   gWriteMixCalls     = 0;
static UInt64   gWriteMixFrames    = 0;

// MARK: - forward declarations (driver interface)
static HRESULT  VVA_QueryInterface(void*, REFIID, LPVOID*);
static ULONG    VVA_AddRef(void*);
static ULONG    VVA_Release(void*);
static OSStatus VVA_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus VVA_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus VVA_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus VVA_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus VVA_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus VVA_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus VVA_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  VVA_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus VVA_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus VVA_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus VVA_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus VVA_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus VVA_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus VVA_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus VVA_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus VVA_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus VVA_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus VVA_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus VVA_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

// MARK: - driver interface instance
static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    VVA_QueryInterface, VVA_AddRef, VVA_Release,
    VVA_Initialize, VVA_CreateDevice, VVA_DestroyDevice,
    VVA_AddDeviceClient, VVA_RemoveDeviceClient,
    VVA_PerformDeviceConfigurationChange, VVA_AbortDeviceConfigurationChange,
    VVA_HasProperty, VVA_IsPropertySettable,
    VVA_GetPropertyDataSize, VVA_GetPropertyData, VVA_SetPropertyData,
    VVA_StartIO, VVA_StopIO, VVA_GetZeroTimeStamp,
    VVA_WillDoIOOperation, VVA_BeginIOOperation, VVA_DoIOOperation, VVA_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;

// MARK: - factory (referenced by Info.plist CFPlugInFactories)
void* VPhoneVAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* VPhoneVAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    char buf[64] = "(nil)";
    Boolean match = false;
    if (inRequestedTypeUUID) {
        CFStringRef s = CFUUIDCreateString(NULL, inRequestedTypeUUID);
        if (s) { CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8); CFRelease(s); }
        match = CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID);
    }
    vva_log("[vva] factory create (pid %d) requestedType=%s match=%d", getpid(), buf, match);
    // Return the driver. The HAL server only ever invokes this factory for the
    // type registered in Info.plist (kAudioServerPlugInTypeUUID), so returning
    // the driver unconditionally is safe — and avoids a NULL return that makes
    // the HAL server crash dereferencing a NULL driver object during activation.
    return gDriverRef;
}

// MARK: - IUnknown
static HRESULT VVA_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex); gRefCount++; pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef; r = S_OK;
    }
    if (req) CFRelease(req);
    if (gVerbose) vva_log("[vva] QueryInterface -> 0x%x (refcount=%u)", (unsigned)r, gRefCount);
    return r;
}
static ULONG VVA_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex); ULONG c = ++gRefCount; pthread_mutex_unlock(&gStateMutex);
    if (gVerbose) vva_log("[vva] AddRef -> %u", (unsigned)c); return c;
}
static ULONG VVA_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex); ULONG c = gRefCount ? --gRefCount : 0; pthread_mutex_unlock(&gStateMutex);
    if (gVerbose) vva_log("[vva] Release -> %u", (unsigned)c); return c;
}

// MARK: - lifecycle
static OSStatus VVA_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    // host ticks per frame = (ns per frame) * (ticks per ns) = (1e9/SR)*(tb.denom/tb.numer)
    double hostClockFreq = (1.0e9 * (double)tb.denom) / (double)tb.numer; // ticks/sec
    gHostTicksPerFrame = hostClockFreq / kSampleRate;
    gDeviceEnabled = (access(kMarker_EnableDevice, F_OK) == 0);
    gVerbose       = (access(kMarker_Verbose, F_OK) == 0);
    // Kill switch: fail Initialize so the HAL server rejects us entirely (acts as
    // if the plugin were absent). Lets us A/B "is the plugin the boot-hang cause"
    // and gives a working-VM off-switch without a ramdisk revert.
    if (access(kMarker_Kill, F_OK) == 0) {
        vva_log("[vva] Initialize: KILL marker present -> returning error (plugin disabled)");
        return kAudioHardwareUnspecifiedError;
    }
    vva_log("[vva] Initialize: hostTicksPerFrame=%.3f deviceEnabled=%d verbose=%d",
            gHostTicksPerFrame, gDeviceEnabled, gVerbose);
    if (gDeviceEnabled) vva_maybe_start_reinvoke();   // arm post-boot vaem re-invoke (audiomxd only)
    return noErr;
}
// Static device — we don't support runtime device creation.
static OSStatus VVA_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef a, const AudioServerPlugInClientInfo* c, AudioObjectID* o)
{ (void)d;(void)a;(void)c;(void)o; if (gVerbose) vva_log("[vva] CreateDevice"); return kAudioHardwareUnsupportedOperationError; }
static OSStatus VVA_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o)
{ (void)d;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus VVA_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c)
{ (void)d;(void)c; if (gVerbose) vva_log("[vva] AddDeviceClient obj=%u", o); return noErr; }
static OSStatus VVA_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c)
{ (void)d;(void)o;(void)c; return noErr; }
static OSStatus VVA_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 x, void* i)
{ (void)d;(void)o;(void)x;(void)i; if (gVerbose) vva_log("[vva] PerformDeviceConfigurationChange obj=%u", o); return noErr; }
static OSStatus VVA_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 x, void* i)
{ (void)d;(void)o;(void)x;(void)i; return noErr; }

// MARK: - format helper
static void FillASBD(AudioStreamBasicDescription* f) {
    memset(f, 0, sizeof(*f));
    f->mSampleRate       = kSampleRate;
    f->mFormatID         = kAudioFormatLinearPCM;
    f->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket   = 4 * kChannels;
    f->mFramesPerPacket  = 1;
    f->mBytesPerFrame    = 4 * kChannels;
    f->mChannelsPerFrame = kChannels;
    f->mBitsPerChannel   = 32;
}

// MARK: - property dispatch (HasProperty / sizes / data)
// To keep this readable the three query entry points delegate to GetPropertyData
// using a scratch buffer for sizing; GetPropertyData is the single source of truth.

static OSStatus Plugin_GetData(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus Device_GetData(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus Stream_GetData(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);

static OSStatus GetData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 cap, UInt32* used, void* out) {
    switch (o) {
        case kObjectID_PlugIn:        return Plugin_GetData(o, a, q, qd, cap, used, out);
        case kObjectID_Device:        return Device_GetData(o, a, q, qd, cap, used, out);
        case kObjectID_Stream_Output: return Stream_GetData(o, a, q, qd, cap, used, out);
        default: return kAudioHardwareBadObjectError;
    }
}

static Boolean VVA_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t c, const AudioObjectPropertyAddress* a) {
    (void)d;(void)c;
    UInt32 used = 0; char scratch[1024];
    Boolean has = (GetData(o, a, 0, NULL, sizeof(scratch), &used, scratch) == noErr);
    if (gVerbose) { char s[5],sc[5]; fourcc(a->mSelector,s); fourcc(a->mScope,sc);
        vva_log("[vva] HasProperty obj=%u sel=%s scope=%s -> %d", o, s, sc, has); }
    return has;
}
static OSStatus VVA_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t c, const AudioObjectPropertyAddress* a, Boolean* settable) {
    (void)d;(void)c;
    // Only NominalSampleRate / stream formats are conceptually settable; keep all read-only for now.
    UInt32 used = 0; char scratch[1024];
    OSStatus s = GetData(o, a, 0, NULL, sizeof(scratch), &used, scratch);
    if (s == noErr && settable) *settable = false;
    return s;
}
static OSStatus VVA_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t c, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32* outSize) {
    (void)d;(void)c;
    if (gVerbose) { char s[5],sc[5]; fourcc(a->mSelector,s); fourcc(a->mScope,sc);
        vva_log("[vva] GetPropertyDataSize obj=%u sel=%s scope=%s", o, s, sc); }
    UInt32 used = 0; static char scratch[4096];
    OSStatus s = GetData(o, a, q, qd, sizeof(scratch), &used, scratch);
    if (s == noErr && outSize) *outSize = used;
    return s;
}
static OSStatus VVA_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t c, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 cap, UInt32* used, void* out) {
    (void)d;(void)c;
    if (gVerbose) { char s[5],sc[5]; fourcc(a->mSelector,s); fourcc(a->mScope,sc);
        vva_log("[vva] GetPropertyData obj=%u sel=%s scope=%s cap=%u", o, s, sc, cap); }
    return GetData(o, a, q, qd, cap, used, out);
}
static OSStatus VVA_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t c, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 sz, const void* data) {
    (void)d;(void)o;(void)c;(void)a;(void)q;(void)qd;(void)sz;(void)data;
    return noErr; // accept (no-op) sets so clients don't error
}

// helpers to emit a value
#define EMIT(TYPE, VAL) do { if (out) { if (cap < sizeof(TYPE)) return kAudioHardwareBadPropertySizeError; *(TYPE*)out = (VAL); } *used = sizeof(TYPE); return noErr; } while (0)

static OSStatus emitCFString(const char* s, UInt32 cap, UInt32* used, void* out) {
    CFStringRef cf = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    if (out) { if (cap < sizeof(CFStringRef)) { if (cf) CFRelease(cf); return kAudioHardwareBadPropertySizeError; } *(CFStringRef*)out = cf; }
    else if (cf) CFRelease(cf);
    *used = sizeof(CFStringRef); return noErr;
}

// MARK: - PlugIn object properties
static OSStatus Plugin_GetData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 cap, UInt32* used, void* out) {
    (void)o;(void)q;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   EMIT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       EMIT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:       EMIT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer:return emitCFString(kManufacturer_Name, cap, used, out);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            if (!gDeviceEnabled) { *used = 0; return noErr; }  // gated: report no device
            if (out) { if (cap < sizeof(AudioObjectID)) { *used = 0; return noErr; } *(AudioObjectID*)out = kObjectID_Device; }
            *used = sizeof(AudioObjectID); return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID dev = kAudioObjectUnknown;
            if (gDeviceEnabled && qd) { CFStringRef uid = *(CFStringRef*)qd; CFStringRef mine = CFSTR(kDevice_UID);
                      if (uid && CFEqual(uid, mine)) dev = kObjectID_Device; }
            EMIT(AudioObjectID, dev);
        }
        case kAudioPlugInPropertyResourceBundle: return emitCFString("", cap, used, out);
        // vaem-specific (queried on the PlugIn/VirtualAudio object). First-cut values;
        // refine empirically from the verbose query log.
        case kVAProperty_vain: EMIT(AudioObjectID, gDeviceEnabled ? kObjectID_Device : kAudioObjectUnknown);
        case kVAProperty_duid: EMIT(AudioObjectID, gDeviceEnabled ? kObjectID_Device : kAudioObjectUnknown);
        case kVAProperty_prts: { *used = 0; return noErr; }  // ConnectedPorts: empty list (refine)
        default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Device object properties
static OSStatus Device_GetData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 cap, UInt32* used, void* out) {
    (void)o;(void)q;(void)qd;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   EMIT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       EMIT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:       EMIT(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:        return emitCFString(kDevice_Name, cap, used, out);
        case kAudioObjectPropertyManufacturer:return emitCFString(kManufacturer_Name, cap, used, out);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            if (a->mScope == kAudioObjectPropertyScopeInput) { *used = 0; return noErr; }
            if (out) { if (cap < sizeof(AudioObjectID)) { *used = 0; return noErr; } *(AudioObjectID*)out = kObjectID_Stream_Output; }
            *used = sizeof(AudioObjectID); return noErr;
        }
        case kAudioObjectPropertyControlList: { *used = 0; return noErr; }
        case kAudioDevicePropertyDeviceUID:   return emitCFString(kDevice_UID, cap, used, out);
        case kAudioDevicePropertyModelUID:    return emitCFString(kDevice_ModelUID, cap, used, out);
        case kAudioDevicePropertyTransportType: EMIT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: { if (out) { if (cap < sizeof(AudioObjectID)) {*used=0;return noErr;} *(AudioObjectID*)out = kObjectID_Device; } *used = sizeof(AudioObjectID); return noErr; }
        case kAudioDevicePropertyClockDomain: EMIT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: EMIT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: EMIT(UInt32, gDeviceRunning ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: EMIT(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: EMIT(UInt32, 1);
        case kAudioDevicePropertyLatency: EMIT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: EMIT(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: EMIT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            if (out) { if (cap < sizeof(r)) { *used = 0; return noErr; } *(AudioValueRange*)out = r; }
            *used = sizeof(AudioValueRange); return noErr;
        }
        case kAudioDevicePropertyIsHidden: EMIT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: EMIT(UInt32, kRingBufferFrames);
        case kAudioDevicePropertyStreamConfiguration: {
            if (a->mScope == kAudioObjectPropertyScopeInput) {
                if (out) { if (cap < sizeof(UInt32)) {*used=0;return noErr;} ((AudioBufferList*)out)->mNumberBuffers = 0; }
                *used = offsetof(AudioBufferList, mBuffers); return noErr;
            }
            UInt32 need = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
            if (out) { if (cap < need) { *used = 0; return noErr; }
                AudioBufferList* abl = (AudioBufferList*)out; abl->mNumberBuffers = 1;
                abl->mBuffers[0].mNumberChannels = kChannels; abl->mBuffers[0].mDataByteSize = 0; abl->mBuffers[0].mData = NULL; }
            *used = need; return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 pair[2] = {1, 2};
            if (out) { if (cap < sizeof(pair)) { *used = 0; return noErr; } memcpy(out, pair, sizeof(pair)); }
            *used = sizeof(pair); return noErr;
        }
        // vaem-specific (Phase 3): return our own object IDs as placeholders.
        case kVAProperty_vain: EMIT(AudioObjectID, kObjectID_Device);
        case kVAProperty_duid: EMIT(AudioObjectID, kObjectID_Device);
        default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Stream object properties
static OSStatus Stream_GetData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 cap, UInt32* used, void* out) {
    (void)o;(void)q;(void)qd;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: EMIT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     EMIT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     EMIT(AudioObjectID, kObjectID_Device);
        case kAudioStreamPropertyIsActive:  EMIT(UInt32, gStreamActive ? 1 : 0);
        case kAudioStreamPropertyDirection: EMIT(UInt32, 0); // output
        case kAudioStreamPropertyTerminalType: EMIT(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: EMIT(UInt32, 1);
        case kAudioStreamPropertyLatency:   EMIT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f; FillASBD(&f);
            if (out) { if (cap < sizeof(f)) { *used = 0; return noErr; } *(AudioStreamBasicDescription*)out = f; }
            *used = sizeof(f); return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r; memset(&r, 0, sizeof(r)); FillASBD(&r.mFormat);
            r.mSampleRateRange.mMinimum = kSampleRate; r.mSampleRateRange.mMaximum = kSampleRate;
            if (out) { if (cap < sizeof(r)) { *used = 0; return noErr; } *(AudioStreamRangedDescription*)out = r; }
            *used = sizeof(r); return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - IO
static OSStatus VVA_StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    (void)d;(void)client; if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (!gDeviceRunning) { gDeviceRunning = true; gAnchorHostTime = mach_absolute_time(); gNumberTimeStamps = 0; }
    pthread_mutex_unlock(&gStateMutex);
    vva_log("[vva] StartIO"); return noErr;
}
static OSStatus VVA_StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    (void)d;(void)client; if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex); gDeviceRunning = false; pthread_mutex_unlock(&gStateMutex);
    vva_log("[vva] StopIO (%llu writeMix calls, %llu frames)", gWriteMixCalls, gWriteMixFrames); return noErr;
}
static OSStatus VVA_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, Float64* outSample, UInt64* outHost, UInt64* outSeed) {
    (void)d;(void)client; if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    UInt64 now = mach_absolute_time();
    Float64 ticksPerBuffer = gHostTicksPerFrame * (Float64)kRingBufferFrames;
    pthread_mutex_lock(&gStateMutex);
    UInt64 next = gAnchorHostTime + (UInt64)((gNumberTimeStamps + 1) * ticksPerBuffer);
    if (now >= next) gNumberTimeStamps++;
    if (outSample) *outSample = (Float64)(gNumberTimeStamps * kRingBufferFrames);
    if (outHost)   *outHost   = gAnchorHostTime + (UInt64)(gNumberTimeStamps * ticksPerBuffer);
    pthread_mutex_unlock(&gStateMutex);
    if (outSeed) *outSeed = 1;
    return noErr;
}
static OSStatus VVA_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, Boolean* outWill, Boolean* outInPlace) {
    (void)d;(void)client; if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = (op == kAudioServerPlugInIOOperationWriteMix);
    if (outWill) *outWill = will; if (outInPlace) *outInPlace = true; return noErr;
}
static OSStatus VVA_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, UInt32 nframes, const AudioServerPlugInIOCycleInfo* info)
{ (void)d;(void)o;(void)client;(void)op;(void)nframes;(void)info; return noErr; }
static OSStatus VVA_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 nframes, const AudioServerPlugInIOCycleInfo* info, void* mainBuf, void* secBuf) {
    (void)d;(void)stream;(void)client;(void)info;(void)secBuf;
    if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (op == kAudioServerPlugInIOOperationWriteMix && mainBuf) {
        // Phase 4 TAP: mainBuf holds nframes * kChannels Float32 of mixed app output.
        // TODO: forward to host relay (shm -> vphoned -> vsock). For now, count.
        gWriteMixCalls++; gWriteMixFrames += nframes;
        if ((gWriteMixCalls % 200) == 1) vva_log("[vva] WriteMix #%llu nframes=%u", gWriteMixCalls, nframes);
    }
    return noErr;
}
static OSStatus VVA_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, UInt32 nframes, const AudioServerPlugInIOCycleInfo* info)
{ (void)d;(void)o;(void)client;(void)op;(void)nframes;(void)info; return noErr; }
