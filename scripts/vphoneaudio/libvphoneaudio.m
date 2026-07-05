// libvphoneaudio.m — injected into /usr/libexec/audiomxd via LC_LOAD_DYLIB.
//
// MUST NEVER crash the host daemon. All work runs on a detached thread; the
// constructor returns immediately. Errors log to /tmp/vphoneaudio.log and
// degrade to silence — never abort audiomxd.
//
// audiomxd's sandbox blocks AF_VSOCK (socket() -> EPERM), so this dylib does
// NOT touch vsock. Instead it is the PRODUCER side of a shared-memory ring
// (vphoned_audio.h): it writes guest output PCM into the ring, and vphoned
// (root, has vsock perms) drains the ring and ships it to the host over
// vsock 1339. See research/audio/ + the vcam bridge it mirrors.
//
// Current revision (proof): when vphoned signals a host connected (by bumping
// header->consumer_gen), play a soft one-shot chime into the ring. This proves
// audiomxd -> shm -> vphoned -> vsock -> host end-to-end. The real output-IO
// tap (Task 2.4) replaces the chime with live audio later.

#import <Foundation/Foundation.h>

#include "vphoned_audio.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <ptrauth.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// MARK: - logging

static void vpa_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/vphoneaudio.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

// MARK: - shared ring (producer side)

static uint8_t *g_shm = NULL;

// Map the ring shared with vphoned. vphoned owns/initializes it; we wait
// briefly for it, and self-initialize as a fallback so we work even if we
// happen to start first.
static int vpa_open_shm(void) {
    int fd = open(VPHONED_AUDIO_SHM_PATH, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { vpa_log(@"[vphoneaudio] open(%s) errno=%d", VPHONED_AUDIO_SHM_PATH, errno); return -1; }
    if (ftruncate(fd, VPHONED_AUDIO_SHM_TOTAL_SIZE) < 0) { vpa_log(@"[vphoneaudio] ftruncate errno=%d", errno); close(fd); return -1; }
    void *base = mmap(NULL, VPHONED_AUDIO_SHM_TOTAL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) { vpa_log(@"[vphoneaudio] mmap errno=%d", errno); return -1; }
    g_shm = (uint8_t *)base;

    vphoned_audio_shm_header_t *hdr = (vphoned_audio_shm_header_t *)g_shm;
    // Wait up to ~3s for vphoned to initialize the header; else init ourselves.
    for (int i = 0; i < 30; i++) {
        if (atomic_load_explicit((_Atomic uint32_t *)&hdr->magic, memory_order_acquire) == VPHONED_AUDIO_MAGIC)
            return 0;
        usleep(100000);
    }
    vpa_log(@"[vphoneaudio] vphoned ring not initialized after 3s; self-initializing");
    hdr->sample_rate = VPHONED_AUDIO_SAMPLE_RATE;
    hdr->channels    = (uint16_t)VPHONED_AUDIO_CHANNELS;
    hdr->format      = 0;
    hdr->capacity    = VPHONED_AUDIO_RING_CAPACITY;
    atomic_store_explicit((_Atomic uint64_t *)&hdr->write_pos, 0, memory_order_release);
    atomic_store_explicit((_Atomic uint64_t *)&hdr->read_pos, 0, memory_order_release);
    atomic_store_explicit((_Atomic uint32_t *)&hdr->magic, VPHONED_AUDIO_MAGIC, memory_order_release);
    return 0;
}

// Append interleaved Int16 PCM into the ring and advance write_pos.
static void vpa_ring_write(const uint8_t *pcm, uint32_t bytes) {
    vphoned_audio_shm_header_t *hdr = (vphoned_audio_shm_header_t *)g_shm;
    uint8_t *ring = g_shm + VPHONED_AUDIO_SHM_HEADER_SIZE;
    const uint32_t cap = VPHONED_AUDIO_RING_CAPACITY;
    if (bytes > cap) { pcm += (bytes - cap); bytes = cap; }  // clamp to ring size

    uint64_t wpos = atomic_load_explicit((_Atomic uint64_t *)&hdr->write_pos, memory_order_relaxed);
    uint32_t off = (uint32_t)(wpos % cap);
    if (off + bytes <= cap) {
        memcpy(ring + off, pcm, bytes);
    } else {
        uint32_t first = cap - off;
        memcpy(ring + off, pcm, first);
        memcpy(ring, pcm + first, bytes - first);
    }
    atomic_store_explicit((_Atomic uint64_t *)&hdr->write_pos, wpos + bytes, memory_order_release);
}

// MARK: - connect chime (one-shot, soft)

#define VPA_AMPLITUDE   0.15
#define VPA_NOTE_MS     140u
#define VPA_NOTE_FRAMES (VPHONED_AUDIO_SAMPLE_RATE * VPA_NOTE_MS / 1000u)  // 6720
static const double kVpaChimeHz[4] = { 440.0, 554.365, 659.255, 880.0 };  // A major arpeggio

// Generate a gentle ascending arpeggio (raised-cosine enveloped, soft) and
// write it into the ring in real-time-ish bursts so it doesn't overrun.
static void vpa_play_chime(void) {
    vpa_log(@"[vphoneaudio] playing connect chime into ring");
    int16_t note[VPA_NOTE_FRAMES * VPHONED_AUDIO_CHANNELS];
    for (int n = 0; n < 4; n++) {
        const double phaseInc = 2.0 * M_PI * kVpaChimeHz[n] / (double)VPHONED_AUDIO_SAMPLE_RATE;
        double phase = 0.0;
        for (uint32_t f = 0; f < VPA_NOTE_FRAMES; f++) {
            double env = 0.5 * (1.0 - cos(2.0 * M_PI * f / (double)(VPA_NOTE_FRAMES - 1)));
            int16_t s = (int16_t)lrint(sin(phase) * VPA_AMPLITUDE * env * 32767.0);
            note[f * VPHONED_AUDIO_CHANNELS + 0] = s;
            note[f * VPHONED_AUDIO_CHANNELS + 1] = s;
            phase += phaseInc;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;
        }
        vpa_ring_write((const uint8_t *)note, VPA_NOTE_FRAMES * VPHONED_AUDIO_BYTES_PER_FRAME);
        usleep(VPA_NOTE_MS * 1000);  // pace ≈ real-time so the ring stays bounded
    }
}

// MARK: - producer thread

static void vpa_producer_loop(void) {
    vphoned_audio_shm_header_t *hdr = (vphoned_audio_shm_header_t *)g_shm;
    // Start from 0, not the current gen: audiomxd (and thus this producer) often
    // finishes launching AFTER the host has already connected to vphoned at boot
    // (gen already 1). Initializing to 0 makes us catch that and chime once.
    uint32_t last_gen = 0;
    vpa_log(@"[vphoneaudio] producer ready; waiting for host connects");
    for (;;) {
        uint32_t gen = atomic_load_explicit((_Atomic uint32_t *)&hdr->consumer_gen, memory_order_acquire);
        if (gen != last_gen) {
            last_gen = gen;
            vpa_play_chime();
        }
        usleep(150000);  // 150 ms poll — responsive enough for a connect chime
    }
}

// MARK: - VirtualAudio endpoint registration (the route that lets apps play)
//
// Apple ships a complete VirtualAudio endpoint manager in MediaExperience
// (_FigVAEndpointManagerCreate, type kFigEndpointManagerType_VirtualAudio) but
// the iOS FigRoutingManager never registers it. We create + register it here,
// inside audiomxd, where the virtual-audio plugin (_vaemGetVirtualAudioPlugin)
// is loaded — without it, AVAudioSession has no route and AVAudioEngine.start
// returns -10851. The two functions are private (not exported), so we resolve
// them by slide off the exported MXRegisterEndpointManager. DSC addresses are
// 23F77 (iPhone17,3 26.5)-specific.
//
// Crash-safety: marker-gated one-shot on its own thread. If create/register
// faults, audiomxd respawns but the marker makes us skip it, so no boot loop;
// the shm relay/chime keeps working regardless.

#define VPA_DSC_MXREGISTER 0x1b3453b30ULL  // exported _MXRegisterEndpointManager
#define VPA_DSC_VACREATE   0x1b3477398ULL  // private _FigVAEndpointManagerCreate
#define VPA_DSC_REGISTER   0x1b3442c4cULL  // private _FigRouteDiscoveryManagerRegisterEndpointManager
#define VPA_DSC_CMSM       0x1b3586f48ULL  // private _cmsmInitializeCMSessionManager (sets up gVAEM)
#define VPA_DSC_CMSM_GUARD 0x1ec786048ULL  // cmsm once-guard (body runs only if ==-1)
#define VPA_DSC_MXINIT     0x1b34fc02cULL  // _MXInitialize (resolve real via slide, not dlsym — interposed)
#define VPA_VA_MARKER   "/tmp/vpa_va_attempted"
#define VPA_CMSM_MARKER "/tmp/vpa_cmsm_attempted"

typedef int  (*vpa_va_create_t)(void *alloc, void *cfg, void **out);
typedef void (*vpa_va_register_t)(void *mgr);
typedef void (*vpa_cmsm_t)(void);

// Compute the MediaExperience DSC slide off the exported MXRegisterEndpointManager
// (dlsym returns a PAC-signed ptr on arm64e — strip before using as an address).
// Returns 0 on failure.
static uintptr_t vpa_media_experience_slide(void) {
    void *me = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    if (!me) { vpa_log(@"[vphoneaudio] slide: dlopen MediaExperience failed"); return 0; }
    void *mx = dlsym(me, "MXRegisterEndpointManager");
    if (!mx) { vpa_log(@"[vphoneaudio] slide: dlsym MXRegisterEndpointManager failed"); return 0; }
    uintptr_t mx_raw = (uintptr_t)ptrauth_strip((void (*)(void))mx, ptrauth_key_function_pointer);
    return mx_raw - (uintptr_t)VPA_DSC_MXREGISTER;
}

// Option (a): re-run cmsmInitializeCMSessionManager AFTER our VirtualAudio plugin
// (id 51) is loaded. iOS runs cmsm at MXInitialize before the plugin exists, so
// vaem bails; the standalone FigVAEndpointManagerCreate re-invoke crashes because
// gVAEM is uninitialized. cmsm sets up gVAEM THEN calls create — so we reset cmsm's
// once-guard (data_1ec786048 -> -1) and re-call it, now with the plugin present.
static void vpa_rerun_cmsm(void) {
    if (access(VPA_CMSM_MARKER, F_OK) == 0) { vpa_log(@"[vphoneaudio] cmsm: already attempted, skipping"); return; }
    int mfd = open(VPA_CMSM_MARKER, O_WRONLY | O_CREAT, 0644); if (mfd >= 0) close(mfd);
    uintptr_t slide = vpa_media_experience_slide();
    if (!slide) return;
    volatile intptr_t *guard = (volatile intptr_t *)(VPA_DSC_CMSM_GUARD + slide);
    vpa_log(@"[vphoneaudio] cmsm: slide=%p guard@%p was=%ld -> -1", (void *)slide, (void *)guard, (long)*guard);
    *guard = -1;  // force cmsm's body to re-run
    vpa_cmsm_t cmsm = ptrauth_sign_unauthenticated((vpa_cmsm_t)(VPA_DSC_CMSM + slide), ptrauth_key_function_pointer, 0);
    vpa_log(@"[vphoneaudio] cmsm: calling cmsmInitializeCMSessionManager @%p", (void *)(VPA_DSC_CMSM + slide));
    cmsm();
    vpa_log(@"[vphoneaudio] cmsm: returned (vaem should have queried the VA plugin)");
}

static void vpa_try_register_va_endpoint(void) {
    if (access(VPA_VA_MARKER, F_OK) == 0) {
        vpa_log(@"[vphoneaudio] VA: already attempted this session, skipping"); return;
    }
    int mfd = open(VPA_VA_MARKER, O_WRONLY | O_CREAT, 0644);  // mark BEFORE attempt
    if (mfd >= 0) close(mfd);

    // PROBE (cont'd #35): what does vaemGetVirtualAudioPlugin's lookup see IN-AUDIOMXD?
    // It queries the system object (id 1) with selector 'pibi'(0x70696269)/'glob', no
    // qualifier, then succeeds iff the result !=0. rpcserver's proxied query was
    // inconclusive ('!siz'); this runs in vaem's actual process/context. Compare 'bidp'.
    {
        void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
        if (ca) {
            int (*aogpds)(unsigned, const void *, unsigned, const void *, unsigned *) =
                (int (*)(unsigned, const void *, unsigned, const void *, unsigned *))dlsym(ca, "AudioObjectGetPropertyDataSize");
            int (*aogpd)(unsigned, const void *, unsigned, const void *, unsigned *, void *) =
                (int (*)(unsigned, const void *, unsigned, const void *, unsigned *, void *))dlsym(ca, "AudioObjectGetPropertyData");
            if (aogpds && aogpd) {
                unsigned pibi[3] = { 'pibi', 'glob', 0 };
                unsigned psz = 0; int prcs = aogpds(1u, pibi, 0u, NULL, &psz);
                vpa_log(@"[vphoneaudio] PROBE pibi: sizeRc=%d size=%u", prcs, psz);
                unsigned trysz[3] = { 4u, 32u, 64u };
                for (int ti = 0; ti < 3; ti++) {
                    unsigned char pbuf[64]; memset(pbuf, 0, sizeof(pbuf));
                    unsigned rdsz = trysz[ti];
                    int prcd = aogpd(1u, pibi, 0u, NULL, &rdsz, pbuf);
                    unsigned w0,w1; memcpy(&w0, pbuf, 4); memcpy(&w1, pbuf+4, 4);
                    vpa_log(@"[vphoneaudio] PROBE pibi sz=%u: rc=%d(0x%x) outsz=%u w0=%u w1=%u", trysz[ti], prcd, (unsigned)prcd, rdsz, w0, w1);
                }
                // 'bidp' (TranslateBundleID) with the bundle-id qualifier, for comparison
                unsigned bidp[3] = { 'bidp', 'glob', 0 };
                CFStringRef bid = CFSTR("com.apple.audio.CoreAudio.VirtualAudio");
                unsigned bval = 0, bsz = 4;
                int brc = aogpd(1u, bidp, (unsigned)sizeof(bid), &bid, &bsz, &bval);
                vpa_log(@"[vphoneaudio] PROBE bidp: rc=%d(0x%x) plugInID=%u", brc, (unsigned)brc, bval);
                // SELF-REGISTER attempt: set 'pibi' (the VirtualAudio-plugin id) to my
                // plugInID on the system object, then re-GET to see if it stuck.
                int (*aospd)(unsigned, const void *, unsigned, const void *, unsigned, const void *) =
                    (int (*)(unsigned, const void *, unsigned, const void *, unsigned, const void *))dlsym(ca, "AudioObjectSetPropertyData");
                (void)aospd;
                // ROUTING TEST: does AudioObjectGetPropertyData(plugInID, 'vain') reach my
                // plugin? This is exactly what FigVAEndpointManagerCreate does on gCMSM+116.
                // If my plugin's verbose logs "obj=1 sel=vain" and rc=0, object routing works.
                if (brc == 0 && bval) {
                    unsigned vainq[3] = { 'vain', 'glob', 0 };
                    unsigned vv = 0xdead, vsz = 4;
                    int vrc = aogpd(bval, vainq, 0u, NULL, &vsz, &vv);
                    vpa_log(@"[vphoneaudio] PROBE vain on plugInID %u: rc=%d(0x%x) val=%u", bval, vrc, (unsigned)vrc, vv);
                    unsigned duidq[3] = { 'duid', 'glob', 0 };
                    unsigned dv = 0xdead, dsz = 4;
                    int drc = aogpd(bval, duidq, 0u, NULL, &dsz, &dv);
                    vpa_log(@"[vphoneaudio] PROBE duid on plugInID %u: rc=%d(0x%x) val=%u", bval, drc, (unsigned)drc, dv);
                }
                // ENUMERATE all plugins ('plg#') and probe vain/duid on each, to find MY
                // plugin's REAL PlugIn AudioObjectID (the one where duid returns rc=0 — only
                // my plugin answers duid; the server-answered object returns 'who?'). 'bidp'
                // apparently gives an id that doesn't route vaem props to my plugin.
                {
                    unsigned plgq[3] = { 'plg#', 'glob', 0 };
                    unsigned plgsz = 0; aogpds(1u, plgq, 0u, NULL, &plgsz);
                    unsigned npl = plgsz / 4; if (npl > 64) npl = 64;
                    unsigned plist[64]; unsigned rdsz = npl * 4;
                    if (npl && aogpd(1u, plgq, 0u, NULL, &rdsz, plist) == 0) {
                        for (unsigned i = 0; i < npl; i++) {
                            unsigned pid = plist[i];
                            unsigned vq[3] = {'vain','glob',0}; unsigned vv=0xdead, vs=4;
                            int vr = aogpd(pid, vq, 0u, NULL, &vs, &vv);
                            unsigned dq[3] = {'duid','glob',0}; unsigned dv2=0xdead, ds=4;
                            int dr = aogpd(pid, dq, 0u, NULL, &ds, &dv2);
                            // dev# count on this plugin (my .driver owns 1 device; stubs own 0)
                            unsigned dlq[3] = {'dev#','glob',0}; unsigned dlsz=0;
                            aogpds(pid, dlq, 0u, NULL, &dlsz);
                            vpa_log(@"[vphoneaudio] PLG[%u]=%u vain(rc=0x%x val=%u) duid(rc=0x%x) dev#cnt=%u", i, pid, (unsigned)vr, vv, (unsigned)dr, dlsz/4);
                        }
                    } else vpa_log(@"[vphoneaudio] PLG enum failed (npl=%u)", npl);
                }
            } else vpa_log(@"[vphoneaudio] PROBE: dlsym AudioObjectGetPropertyData failed");
        } else vpa_log(@"[vphoneaudio] PROBE: dlopen CoreAudio failed");
    }

    void *me = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    if (!me) { vpa_log(@"[vphoneaudio] VA: dlopen MediaExperience failed"); return; }
    void *mx = dlsym(me, "MXRegisterEndpointManager");
    if (!mx) { vpa_log(@"[vphoneaudio] VA: dlsym MXRegisterEndpointManager failed"); return; }

    // dlsym returns a PAC-signed function pointer on arm64e — strip the auth
    // bits before using it as a raw address, or the slide picks up garbage.
    uintptr_t mx_raw = (uintptr_t)ptrauth_strip((void (*)(void))mx, ptrauth_key_function_pointer);
    uintptr_t slide = mx_raw - (uintptr_t)VPA_DSC_MXREGISTER;
    uintptr_t craw  = VPA_DSC_VACREATE + slide;
    uintptr_t rraw  = VPA_DSC_REGISTER + slide;
    vpa_log(@"[vphoneaudio] VA: slide=%p create=%p register=%p", (void *)slide, (void *)craw, (void *)rraw);

    vpa_va_create_t create =
        ptrauth_sign_unauthenticated((vpa_va_create_t)craw, ptrauth_key_function_pointer, 0);
    vpa_va_register_t reg =
        ptrauth_sign_unauthenticated((vpa_va_register_t)rraw, ptrauth_key_function_pointer, 0);

    // Force MX_FeatureFlags_IsStartupSequenceChangeEnabled=1 (cached byte at DSC 0x1ea8ca810).
    // FigVAEndpointManagerCreate gates the WHOLE vaem-plugin-adoption block (vaemGetVirtualAudioPlugin
    // + vain/duid/prts) behind this flag; on this VM os_feature_enabled("VirtualAudio",
    // "startup_sequence_change")=0, so the block is skipped entirely (the vain query is never
    // reached). The flag's dispatch_once already ran at MXInitialize, so overwriting the cached
    // byte makes the getter return 1 and create() take the adoption path. (cont'd #37)
    { volatile uint64_t *ssc_once = (volatile uint64_t *)(0x1ea8cbb98ULL + slide); // dispatch_once token
      volatile uint8_t  *ssc      = (volatile uint8_t  *)(0x1ea8ca810ULL + slide); // cached bool
      uint64_t ot = *ssc_once; uint8_t was = *ssc;
      *ssc = 1; *ssc_once = (uint64_t)-1;  // mark once "done" so the getter reads our byte, no recompute
      vpa_log(@"[vphoneaudio] VA: StartupSequenceChange once=0x%llx byte=%u -> byte=1 once=-1", (unsigned long long)ot, was); }

    // Pre-seed gCMSM+116 (DSC 0x1ea8cd3a4) with my plugInID. FigVAEndpointManagerCreate
    // reads gCMSM+116 as the VirtualAudio plugin object for its 'vain' query, and it
    // IGNORES vaemGetVirtualAudioPlugin's return value. vaemGetVirtualAudioPlugin's
    // 'pibi' lookup fails here ('!siz') but neither sets nor clears gCMSM+116 on failure
    // — so seeding it makes create() query OUR plugin's vain/duid/prts. (cont'd #36)
    {
        void *ca2 = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
        int (*aogpd2)(unsigned, const void *, unsigned, const void *, unsigned *, void *) = ca2 ?
            (int (*)(unsigned, const void *, unsigned, const void *, unsigned *, void *))dlsym(ca2, "AudioObjectGetPropertyData") : NULL;
        unsigned bidp2[3] = { 'bidp', 'glob', 0 };
        CFStringRef bid2 = CFSTR("com.apple.audio.CoreAudio.VirtualAudio");
        unsigned pid = 0, psz = 4;
        if (aogpd2 && aogpd2(1u, bidp2, (unsigned)sizeof(bid2), &bid2, &psz, &pid) == 0 && pid) {
            volatile uint32_t *gcmsm_plugin = (volatile uint32_t *)(0x1ea8cd3a4ULL + slide);
            uint32_t prev = *gcmsm_plugin;
            *gcmsm_plugin = (uint32_t)pid;
            vpa_log(@"[vphoneaudio] VA: seeded gCMSM+116 @%p was=%u -> %u", (void *)gcmsm_plugin, prev, (uint32_t)pid);
        } else vpa_log(@"[vphoneaudio] VA: gCMSM+116 seed skipped (bidp lookup failed)");
    }

    void *mgr = NULL;
    int rc = create(NULL, NULL, &mgr);
    { volatile uint32_t *g = (volatile uint32_t *)(0x1ea8cd3a4ULL + slide);
      vpa_log(@"[vphoneaudio] VA: gCMSM+116 AFTER create = %u (was seeded to my plugInID)", *g); }
    vpa_log(@"[vphoneaudio] VA: FigVAEndpointManagerCreate rc=%d mgr=%p", rc, mgr);
    if (rc == 0 && mgr) {
        reg(mgr);
        vpa_log(@"[vphoneaudio] VA: registered VirtualAudio endpoint manager");
    }
}

// MARK: - (c1) MXInitialize hook: force VA plugin load before cmsm/vaem
//
// audiomxd's ONLY audio call is MXInitialize, inside which cmsm runs vaem. vaem's
// vaemGetVirtualAudioPlugin runs before the HAL server has loaded our plugin (the
// server starts lazily, later), so it gets plugInID 0 and never queries us. We
// DYLD_INTERPOSE MXInitialize: before calling the real one, force the HAL server to
// start + poll until our VirtualAudio plugin (id 51) is registered, so the ensuing
// cmsm/vaem finds it on the normal path. Runs in main (not the ctor) → no deadlock.
// Marker-gated (vva_hook_mxinit); the hook ALWAYS falls through to the real
// MXInitialize so audiomxd is never broken even if early-HAL is off/fails.

// iOS SDK omits AudioHardware.h — minimal HAL client decls.
typedef struct { UInt32 mSelector; UInt32 mScope; UInt32 mElement; } VPA_AOPA;
typedef OSStatus (*VPA_AOGPDS)(UInt32, const VPA_AOPA *, UInt32, const void *, UInt32 *);
typedef OSStatus (*VPA_AOGPD)(UInt32, const VPA_AOPA *, UInt32, const void *, UInt32 *, void *);

static void vpa_early_hal_load(void) {
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
    if (!ca) { vpa_log(@"[vphoneaudio] early-HAL: dlopen CoreAudio failed"); return; }
    VPA_AOGPDS aogpds = (VPA_AOGPDS)dlsym(ca, "AudioObjectGetPropertyDataSize");
    VPA_AOGPD  aogpd  = (VPA_AOGPD)dlsym(ca, "AudioObjectGetPropertyData");
    if (!aogpds || !aogpd) { vpa_log(@"[vphoneaudio] early-HAL: dlsym failed"); return; }
    VPA_AOPA devs = { 'dev#', 'glob', 0 };
    UInt32 sz = 0; aogpds(1u, &devs, 0u, NULL, &sz);   // first HAL op → start server + load plugins
    CFStringRef bid = CFSTR("com.apple.audio.CoreAudio.VirtualAudio");
    VPA_AOPA bidp = { 'bidp', 'glob', 0 };              // TranslateBundleIDToPlugIn
    for (int i = 0; i < 60; i++) {                      // poll ~3s until our plugin registers
        UInt32 plug = 0, osz = (UInt32)sizeof(plug);
        OSStatus rc = aogpd(1u, &bidp, (UInt32)sizeof(bid), &bid, &osz, &plug);
        if (rc == 0 && plug != 0) { vpa_log(@"[vphoneaudio] early-HAL: VA plugin loaded as %u after %d polls", (unsigned)plug, i); return; }
        usleep(50000);
    }
    vpa_log(@"[vphoneaudio] early-HAL: VA plugin NOT registered within timeout");
}

static void (*vpa_real_MXInitialize)(void) = NULL;
static int vpa_hook_busy = 0;   // re-entrancy guard
static int vpa_real_done = 0;   // real MXInitialize called exactly once
extern void MXInitialize(void);

// Resolve the REAL MXInitialize by DSC slide (a direct address call bypasses our own
// interpose; dlsym(RTLD_NEXT) returns the INTERPOSED hook). Call it exactly once.
static void vpa_call_real_mxinit(void) {
    if (vpa_real_done) return;
    vpa_real_done = 1;
    if (!vpa_real_MXInitialize) {
        uintptr_t slide = vpa_media_experience_slide();
        if (slide) vpa_real_MXInitialize =
            ptrauth_sign_unauthenticated((void (*)(void))(VPA_DSC_MXINIT + slide), ptrauth_key_function_pointer, 0);
    }
    if (vpa_real_MXInitialize) vpa_real_MXInitialize();
    else vpa_log(@"[vphoneaudio] hook: FATAL real MXInitialize not resolved");
}

static void vpa_hook_MXInitialize(void) {
    // RE-ENTRANCY: early_hal_load's HAL query itself triggers MXInitialize (first HAL
    // use inits the audio subsystem) → re-enters this hook. On re-entry, just run the
    // real MXInitialize once (our plugin is already loading) — no infinite recursion.
    if (vpa_hook_busy) { vpa_call_real_mxinit(); return; }
    vpa_hook_busy = 1;
    @try {
        if (access("/var/jb/var/mobile/Library/vva_hook_mxinit", F_OK) == 0) {
            vpa_log(@"[vphoneaudio] hook MXInitialize: forcing VA plugin load before cmsm");
            vpa_early_hal_load();   // its HAL query re-enters → vpa_call_real_mxinit runs there
        }
    } @catch (id e) { vpa_log(@"[vphoneaudio] hook: early-HAL exception %@", e); }
    vpa_call_real_mxinit();        // ensure real ran (no-op if the re-entry already did)
    vpa_hook_busy = 0;
}
__attribute__((used)) static const struct { const void *replacement; const void *replacee; }
    vpa_interpose_mxinit __attribute__((section("__DATA,__interpose"))) =
    { (const void *)vpa_hook_MXInitialize, (const void *)MXInitialize };

// MARK: - constructor

__attribute__((constructor))
static void vpa_init(void) {
    @try {
        // DEBUG: if the marker exists, BUSY-WAIT (running, in nanosleep) here in our
        // constructor — runs before main/MXInitialize, so a debugger can lldb-attach
        // to the RUNNING pid (lldb cannot attach to a SIGSTOP-held process; it fails
        // the gdb handshake and resumes it). We loop sleeping until a `vva_release`
        // marker appears (or 180s elapses), so the debugger can attach + set
        // breakpoints, then `touch vva_release` to let audiomxd proceed into init.
        if (access("/var/jb/var/mobile/Library/vva_debug_stop", F_OK) == 0) {
            vpa_log(@"[vphoneaudio] DEBUG: ctor wait-loop (pid %d) — touch vva_release to proceed", getpid());
            for (int i = 0; i < 180 && access("/var/jb/var/mobile/Library/vva_release", F_OK) != 0; i++) {
                sleep(1);
            }
            vpa_log(@"[vphoneaudio] DEBUG: proceeding (pid %d)", getpid());
        }
        vpa_log(@"[vphoneaudio] loaded in pid %d", getpid());
        // EARLY-HAL: force the HAL server to start + load our VirtualAudio plugin
        // BEFORE audiomxd's main/MXInitialize runs cmsm/vaem. Normally vaem's
        // vaemGetVirtualAudioPlugin runs first and the HAL server (which loads our
        // plugin) only starts later INSIDE vaem (HALS_System::StartServer), so vaem
        // finds no VA plugin and bails. By issuing one in-process HAL query here (in
        // our ctor, before main), the plugin (id 51) is registered before cmsm runs,
        // so vaem can adopt it on the normal path. Marker-gated for recovery.
        if (access("/var/jb/var/mobile/Library/vva_early_hal", F_OK) == 0) {
            void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW);
            if (ca) {
                int (*aogpds)(unsigned, const void *, unsigned, const void *, unsigned *) =
                    (int (*)(unsigned, const void *, unsigned, const void *, unsigned *))dlsym(ca, "AudioObjectGetPropertyDataSize");
                if (aogpds) {
                    unsigned addr[3] = { 'dev#', 'glob', 0 }; unsigned sz = 0;
                    int rc = aogpds(1u, addr, 0u, NULL, &sz);
                    vpa_log(@"[vphoneaudio] early-HAL dev# rc=%d sz=%u (plugins should now be loaded pre-cmsm)", rc, sz);
                } else vpa_log(@"[vphoneaudio] early-HAL: dlsym failed");
            } else vpa_log(@"[vphoneaudio] early-HAL: dlopen CoreAudio failed");
        }
        // shm relay/chime producer
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @try {
                if (vpa_open_shm() < 0) { vpa_log(@"[vphoneaudio] shm open failed; degrading to silence"); return; }
                vpa_log(@"[vphoneaudio] ring mapped (%s)", VPHONED_AUDIO_SHM_PATH);
                vpa_producer_loop();
            } @catch (id e) {
                vpa_log(@"[vphoneaudio] producer-thread exception: %@; degrading to silence", e);
            }
        });
        // VirtualAudio endpoint re-registration (RE-INVOKE). iOS's FigRoutingManager
        // runs vaem at MXInitialize BEFORE our custom VirtualAudio plugin (id 51) is
        // loaded, so it bails ("VirtualDevicePlugIn not initialized"). We re-invoke
        // FigVAEndpointManagerCreate here, ~6s after load, by which time our plugin is
        // registered (TranslateBundleID('com.apple.audio.CoreAudio.VirtualAudio')=51),
        // so vaem now finds it and queries vain/duid/prts. Marker-gated (toggle without
        // env): touch /var/jb/var/mobile/Library/vva_try_va. The /tmp one-shot guard is
        // removed each killall-iteration. See research/audio + memory cont'd #27.
        if (access("/var/jb/var/mobile/Library/vva_try_va", F_OK) == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try { sleep(6); vpa_try_register_va_endpoint(); }
                @catch (id e) { vpa_log(@"[vphoneaudio] VA: exception %@", e); }
            });
        }
        // Option (a): re-run cmsm (with gVAEM setup) once our plugin is loaded.
        if (access("/var/jb/var/mobile/Library/vva_try_cmsm", F_OK) == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try { sleep(6); vpa_rerun_cmsm(); }
                @catch (id e) { vpa_log(@"[vphoneaudio] cmsm: exception %@", e); }
            });
        }
        // ON-DEMAND re-invoke trigger for IDLE debugging. The re-invoke crash can
        // only be debugged when audiomxd is FULLY initialized and idle: while it is
        // still loading frameworks (early ctor), lldb's dyld-rendezvous *software*
        // breakpoint churns on each image load (remove/step/reinsert = code writes),
        // which trips SPTM's W^X and panics the kernel via debugserver. By arming a
        // persistent poll thread HERE (spawned at ctor, so a debugger attaching later
        // already sees it and can plant a per-thread HW breakpoint on it), we can let
        // audiomxd reach idle, attach, set a HW bp on FigVAEndpointManagerCreate, THEN
        // touch vva_trigger_va to fire the re-invoke with no image loads in flight.
        if (access("/var/jb/var/mobile/Library/vva_arm_trigger", F_OK) == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                vpa_log(@"[vphoneaudio] trigger: armed (pid %d); polling for vva_trigger_va", getpid());
                for (;;) {
                    if (access("/var/jb/var/mobile/Library/vva_trigger_va", F_OK) == 0) {
                        vpa_log(@"[vphoneaudio] trigger: vva_trigger_va seen — running re-invoke");
                        @try { vpa_try_register_va_endpoint(); }
                        @catch (id e) { vpa_log(@"[vphoneaudio] trigger: exception %@", e); }
                        break;
                    }
                    sleep(1);
                }
            });
        }
    } @catch (id e) { /* never propagate into audiomxd */ }
}
