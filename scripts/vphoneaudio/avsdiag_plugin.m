// Force-activate AppleVirtIOSound's HALS_PlugIn wrapper from inside audiomxd,
// WITHOUT the libdispatch re-entrancy deadlock that HALS_PlugIn::Activate caused
// (Activate dispatch_sync's the init onto the plugin's queue Q; the driver's
// addAudioDevice -> PropertiesChanged re-enters dispatch_sync(Q) -> deadlock).
// Fix: from an off-Q thread, call HALS_UCPlugIn::Initialize(UCobj, host) directly
// (host inline @ wrapper+432), so PropertiesChanged's dispatch_sync(Q) finds Q
// free, then HALS_Object::Activate(wrapper) to Rebuild*List + publish the device.
//
// DSC pre-slide vaddrs (iPhone17,3 26.5 23F77, image CoreAudio):
//   AudioObjectGetPropertyData (slide anchor) = 0x1e193fd7c
//   HALS_PlugInManager::sPlugInList           = 0x1ed0cfb40
//   HALS_UCPlugIn::Initialize(host)           = 0x1e19bf86c   (x0=UCobj, x1=host)
//   HALS_Object::Activate()                   = 0x1e1bce818   (x0=wrapper)
// HALS_PlugIn offsets: driver iface +48, host iface (inline) +432, UC shared_ptr +416, plugInID +352.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ptrauth.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>

static void DL(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    FILE *f = fopen("/tmp/avsdiag_plugin.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}
typedef id (*mi)(id, SEL);
static IMP o_init, o_add;
static id gAVIOPlugin = nil;   // captured in s_add (the plugin addAudioDevice was sent to)
static NSString *uidOf(id d){ return (d && [d respondsToSelector:@selector(deviceUID)]) ? ((mi)objc_msgSend)(d,@selector(deviceUID)) : @"?"; }
static id s_init(id self, SEL _c, id uid, id plug){ DL(@"[D] >> initWithDeviceUID:%@ dev=%s plugin=%s", uid, object_getClassName(self), object_getClassName(plug)); return ((id(*)(id,SEL,id,id))o_init)(self,_c,uid,plug); }
static long s_add(id self, SEL _c, id dev){ gAVIOPlugin=self; long r=((long(*)(id,SEL,id))o_add)(self,_c,dev); DL(@"[D] addAudioDevice: plugin=%s dev=%@ -> %ld", object_getClassName(self), uidOf(dev), r); return r; }
static unsigned long cnt(id obj, SEL s){ id a = obj && [obj respondsToSelector:s] ? ((mi)objc_msgSend)(obj,s) : nil; return a ? (unsigned long)[a count] : 0; }
static void dumpDevs(id plugin){
    id arr = (plugin && [plugin respondsToSelector:@selector(audioDevices)]) ? ((mi)objc_msgSend)(plugin,@selector(audioDevices)) : nil;
    unsigned long n = arr ? (unsigned long)[arr count] : 0;
    DL(@"[A] plugin %p audioDevices=%lu devices=%lu", plugin, n, cnt(plugin,@selector(devices)));
    for (unsigned long i=0;i<n;i++){
        id d = [arr objectAtIndex:i];
        uint32_t oid = [d respondsToSelector:@selector(objectID)] ? ((uint32_t(*)(id,SEL))objc_msgSend)(d,@selector(objectID)) : 0xffffffff;
        DL(@"[A]   dev[%lu] %s objectID=%u uid=%@", i, object_getClassName(d), oid, uidOf(d));
    }
}
void *AVSDiagFactory(CFAllocatorRef a, CFUUIDRef u){ return NULL; }
static void *signIA0(void *p){ return ptrauth_sign_unauthenticated(ptrauth_strip(p, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0); }

static void forceActivate(void) {
    if (access("/tmp/avs_done", F_OK) == 0) { DL(@"[A] avs_done present; one-shot skip"); return; }
    FILE *m = fopen("/tmp/avs_done", "w"); if (m) fclose(m);   // bound to ONE attempt (set before risky work)
    void *anchor = dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
    if (!anchor) { DL(@"[A] no slide anchor"); return; }
    uint64_t slide = (uint64_t)ptrauth_strip(anchor, ptrauth_key_function_pointer) - 0x1e193fd7cULL;
    DL(@"[A] slide=0x%llx", slide);
    uintptr_t *cb = *(uintptr_t **)(0x1ed0cfb40ULL + slide);
    if (!cb) { DL(@"[A] sPlugInList null"); return; }
    void **begin = (void**)cb[0], **end = (void**)cb[1];
    DL(@"[A] sPlugInList count=%ld", (long)(end - begin));
    if (!begin || end < begin || (end - begin) > 64) { DL(@"[A] implausible list, abort"); return; }
    long (*UCInit)(void*, void*) = (long(*)(void*,void*))signIA0((void*)(0x1e19bf86cULL + slide));
    void (*ObjActivate)(void*)   = (void(*)(void*))signIA0((void*)(0x1e1bce818ULL + slide));
    // HALS_PlugIn::RebuildDeviceList(std::vector<UInt32>* sret /*x0*/, HALS_PlugIn* this /*x1*/)
    void (*RebuildDevList)(void*, void*) = (void(*)(void*,void*))signIA0((void*)(0x1e175c650ULL + slide));
    for (void **p = begin; p < end; p++) {
        char *w = (char*)*p;
        if (!w) continue;
        uint32_t plugID = *(uint32_t*)(w + 352);
        void *drv = *(void**)(w + 48);
        DL(@"[A] wrapper=%p plugInID=%u drviface=%p", w, plugID, drv);
        if (plugID == 34 && drv) {
            void *UCobj = *(void**)(w + 416);
            void *host  = (void*)(w + 432);
            // FIX: bump the plugin's _nextObjectID to a high base BEFORE creating devices,
            // so device objectIDs avoid the reserved kAudioObjectPlugInObject(2) collision.
            void *ref0 = *(void**)((char*)UCobj+24);
            void* (*getASD)(void*) = (void*(*)(void*))signIA0((void*)(0x2478ffca4ULL + slide));
            id plug = ref0 ? (__bridge id)getASD(ref0) : nil;
            if (plug) {
                int32_t ivarOff = *(int32_t*)(0x27de97c20ULL + slide);  // _OBJC_IVAR_$_ASDPlugin._nextObjectID
                if (ivarOff > 0 && ivarOff < 8192) {
                    uint32_t *np = (uint32_t*)((char*)(__bridge void*)plug + ivarOff);
                    DL(@"[A] pre-init: plug=%p _nextObjectID@+%d = %u -> 0x1000", (__bridge void*)plug, ivarOff, *np);
                    *np = 0x1000;
                } else DL(@"[A] implausible _nextObjectID ivarOff=%d, skip bump", ivarOff);
            }
            DL(@"[A] >>> HALS_UCPlugIn::Initialize UCobj=%p host=%p <<<", UCobj, host);
            long r = UCInit(UCobj, host);
            DL(@"[A] Initialize -> %ld; wrapper objID +352=%u +356=%u; HALS_Object::Activate", r,
               *(uint32_t*)(w+352), *(uint32_t*)(w+356));
            ObjActivate(w);
            dumpDevs(gAVIOPlugin);
            if (gAVIOPlugin) {
                uint32_t pid = ((uint32_t(*)(id,SEL))objc_msgSend)(gAVIOPlugin,@selector(objectID));
                id o1 = [gAVIOPlugin respondsToSelector:@selector(objectForObjectID:)] ? ((id(*)(id,SEL,unsigned))objc_msgSend)(gAVIOPlugin,@selector(objectForObjectID:),1u) : nil;
                id o2 = [gAVIOPlugin respondsToSelector:@selector(objectForObjectID:)] ? ((id(*)(id,SEL,unsigned))objc_msgSend)(gAVIOPlugin,@selector(objectForObjectID:),2u) : nil;
                DL(@"[A] gAVIOPlugin objectID=%u; objForID(1)=%p[%s]; objForID(2)=%p[%s]",
                   pid, o1, o1?object_getClassName(o1):"nil", o2, o2?object_getClassName(o2):"nil");
                void *ref = *(void**)((char*)UCobj+24);
                // does the plugin's OWN ObjC getter report the device list?
                uint32_t da[3] = {0x64657623u /*'dev#'*/, 0x676c6f62u /*'glob'*/, 0u};
                SEL dsz = @selector(dataSizeForProperty:withQualifierSize:andQualifierData:);
                uint32_t sz = [gAVIOPlugin respondsToSelector:dsz] ? ((uint32_t(*)(id,SEL,void*,uint32_t,void*))objc_msgSend)(gAVIOPlugin,dsz,da,0u,NULL) : 0xffffffffu;
                DL(@"[A] plugin ObjC dataSizeForProperty(dev#)=%u (~%u devices)", sz, sz==0xffffffffu?999:sz/4);
                // call the EXACT C-ABI ASD_GetPropertyDataSize (standard sig) the HAL uses, for objIDs 1/2/34
                // correct C-ABI sig: GetPropertyDataSize(inDriver, inObjectID, pid_t inClientPID, inAddress, inQualSize, inQual, outSize)
                OSStatus (*ASDGetSize)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t*) =
                    (OSStatus(*)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t*))signIA0((void*)(0x247902108ULL+slide));
                uint32_t oids[3]={1u,2u,34u};
                for (int qi=0; qi<3; qi++){
                    uint32_t outSz=0xeeeeeeeeu; OSStatus st=ASDGetSize(ref, oids[qi], 0, da, 0, NULL, &outSz);
                    DL(@"[A] ASD_GetPropertyDataSize(objID=%u,client=0,dev#) st=0x%x outSize=%u (~%u)", oids[qi], (unsigned)st, outSz, outSz==0xeeeeeeeeu?999:outSz/4);
                }
                // is the interface's GetPropertyDataSize vtable slot (+104) the same fn I called directly?
                void *vt = ref ? *(void**)ref : NULL;
                void *s104 = vt ? *(void**)((char*)vt+104) : NULL;
                DL(@"[A] ref=%p *ref=%p vt[+104]stripped=%p expected ASDGetSize=%p", ref, vt,
                   s104?ptrauth_strip(s104,ptrauth_key_function_pointer):NULL, (void*)(0x247902108ULL+slide));
                // also call the C-ABI via the interface vtable slot exactly like the thunk does
                if (s104) {
                    OSStatus (*viaVT)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t*) =
                        (OSStatus(*)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t*))s104;
                    uint32_t o2=0xeeeeeeeeu; OSStatus st2=viaVT(ref,1,0,da,0,NULL,&o2);
                    DL(@"[A] via vtable slot GetPropertyDataSize(objID=1) st=0x%x outSize=%u", (unsigned)st2, o2);
                }
                // the data query (GetPropertyData, vtable slot +112) - what device IDs does the HAL get?
                void *s112 = vt ? *(void**)((char*)vt+112) : NULL;
                if (s112) {
                    OSStatus (*viaData)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t,uint32_t*,void*) =
                        (OSStatus(*)(void*,uint32_t,int32_t,void*,uint32_t,void*,uint32_t,uint32_t*,void*))s112;
                    uint32_t ids[4]={0,0,0,0}; uint32_t got=0xeeeeeeeeu;
                    OSStatus st3=viaData(ref,1,0,da,0,NULL,16,&got,ids);
                    DL(@"[A] GetPropertyData(objID=1,dev#) st=0x%x got=%u ids=[%u,%u,%u,%u]", (unsigned)st3, got, ids[0],ids[1],ids[2],ids[3]);
                }
            }
            unsigned long vec[3] = {0,0,0};
            RebuildDevList(vec, w);
            DL(@"[A] direct RebuildDeviceList vec count=%lu", vec[0] ? (vec[1]-vec[0])/4 : 0);
            // trigger the HAL's OWN RebuildDeviceList via the device-list-changed notification
            // (dev[1]=4096 is now collision-free). plug->_pluginHost = the real HAL host.
            if (plug) {
                uint32_t da2[3] = {0x64657623u, 0x676c6f62u, 0u};
                DL(@"[A] re-firing [plug changedProperty:{dev#} forObject:plug] to trigger HAL RebuildDeviceList");
                ((void(*)(id,SEL,void*,id))objc_msgSend)(plug, @selector(changedProperty:forObject:), da2, plug);
                DL(@"[A] changedProperty fired");
            }
            // probe CopyDeviceByUCID: confirm 2 collides (non-NULL=reserved) and 4096 is clean (NULL)
            void* (*CopyDevByUCID)(void*,uint32_t) = (void*(*)(void*,uint32_t))signIA0((void*)(0x1e1760308ULL+slide));
            void *d2 = CopyDevByUCID(w, 2);
            void *d4096 = CopyDevByUCID(w, 4096);
            DL(@"[A] CopyDeviceByUCID(2)=%p CopyDeviceByUCID(4096)=%p", d2, d4096);
            // probe the two publish gates
            int (*runHybrid)(void) = (int(*)(void))signIA0((void*)(0x1e199b558ULL+slide));
            DL(@"[A] AMCP run_hybrid_hal = %d", runHybrid());
            int (*isHidden)(void*) = (int(*)(void*))signIA0((void*)(0x1e19fca88ULL+slide));
            DL(@"[A] IsHidden(dev2=%p)=%d IsHidden(dev4096=%p)=%d", d2, d2?isHidden(d2):-1, d4096, d4096?isHidden(d4096):-1);
        }
    }
    DL(@"[A] forceActivate done");
}

__attribute__((constructor))
static void avsdiag_plugin_init(void) {
    @autoreleasepool {
        DL(@"[D] ===== avsdiag_plugin ctor pid %d =====", getpid());
        dlopen("/System/Library/PrivateFrameworks/AudioServerDriver.framework/AudioServerDriver", RTLD_NOW);
        Class P = objc_getClass("ASDPlugin"), D = objc_getClass("ASDAudioDevice");
        if (D){ Method m=class_getInstanceMethod(D,@selector(initWithDeviceUID:withPlugin:)); if(m) o_init=method_setImplementation(m,(IMP)s_init); }
        if (P){ Method m=class_getInstanceMethod(P,@selector(addAudioDevice:)); if(m) o_add=method_setImplementation(m,(IMP)s_add); }
        DL(@"[D] swizzles installed; forceActivate (off-Q) in 12s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)12 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ forceActivate(); });
    }
}
