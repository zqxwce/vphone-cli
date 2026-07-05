/*
 * vphoned_audio — bridge guest audio out to the host over vsock 1339.
 *
 * audiomxd's sandbox blocks AF_VSOCK socket creation (socket() -> EPERM),
 * exactly like cameracaptured. So — mirroring the vcam bridge — the vsock
 * endpoint lives in vphoned (root, has vsock perms), and the in-audiomxd
 * dylib (libvphoneaudio) and vphoned exchange PCM through a shared-memory
 * ring under /var/jb (which audiomxd's sandbox CAN read/write).
 *
 * Direction is the REVERSE of vcam: here the sandboxed daemon (audiomxd)
 * is the PRODUCER (writes captured output PCM into the ring) and vphoned
 * is the CONSUMER (drains the ring, frames it, sends to the host). The
 * host side is VPhoneAudioBridge.swift / VPhoneAudioFrame.swift.
 *
 * Wire format vphoned emits to the host == VPhoneAudioFrame: a 24-byte LE
 * header ('VPAU') + interleaved Int16 PCM. vphoned owns that framing now;
 * libvphoneaudio only writes raw PCM into the ring.
 */

#ifndef VPHONED_AUDIO_H
#define VPHONED_AUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Shared ring file — under /var/jb so audiomxd's sandbox allows R/W. */
#ifndef VPHONED_AUDIO_SHM_PATH
#define VPHONED_AUDIO_SHM_PATH "/var/jb/var/mobile/Library/vphone-audio-out.shm"
#endif
#ifndef VPHONED_AUDIO_VSOCK_PORT
#define VPHONED_AUDIO_VSOCK_PORT 1339
#endif
/* Posted by the producer (libvphoneaudio) after each write so vphoned can
 * drain promptly instead of polling hard. */
#ifndef VPHONED_AUDIO_NOTIFY_NAME
#define VPHONED_AUDIO_NOTIFY_NAME "com.vphone.audio.out"
#endif

/* Fixed stream format for the ring + the host wire frames. */
#define VPHONED_AUDIO_SAMPLE_RATE 48000u
#define VPHONED_AUDIO_CHANNELS    2u
#define VPHONED_AUDIO_BYTES_PER_FRAME (VPHONED_AUDIO_CHANNELS * 2u) /* Int16 */

/*
 * Single-producer (audiomxd) / single-consumer (vphoned) byte ring.
 *
 * write_pos / read_pos are free-running absolute byte counters (never wrap);
 * the live data is data[(read_pos .. write_pos) % capacity]. The producer
 * advances write_pos with release ordering after copying; the consumer
 * advances read_pos with release ordering after draining. If the consumer
 * falls a full capacity behind (write_pos - read_pos > capacity), the
 * producer has lapped it — the consumer detects this and resyncs read_pos
 * to (write_pos - capacity), dropping the overrun rather than blocking the
 * realtime producer.
 */
#define VPHONED_AUDIO_SHM_HEADER_SIZE 64u
#define VPHONED_AUDIO_RING_CAPACITY (256u * 1024u) /* ~0.68s @ 48k stereo Int16 */
#define VPHONED_AUDIO_SHM_TOTAL_SIZE                                           \
  (VPHONED_AUDIO_SHM_HEADER_SIZE + VPHONED_AUDIO_RING_CAPACITY)

#define VPHONED_AUDIO_MAGIC 0x52415056u /* 'VPAR' LE */

/* NOT packed: the uint64_t counters are touched with atomics, which fault on
 * arm64 unless naturally (8-byte) aligned. Natural alignment + the explicit
 * pad puts write_pos at offset 24 and read_pos at 32 (both 8-aligned). The
 * mmap base is page-aligned, so the live addresses are aligned too. Both
 * vphoned (arm64) and libvphoneaudio (arm64e) share this ABI layout. The ring
 * data always starts at the fixed VPHONED_AUDIO_SHM_HEADER_SIZE, not sizeof. */
typedef struct {
  uint32_t magic;        /* off 0  — VPHONED_AUDIO_MAGIC once initialized */
  uint32_t sample_rate;  /* off 4  — VPHONED_AUDIO_SAMPLE_RATE */
  uint16_t channels;     /* off 8  — VPHONED_AUDIO_CHANNELS */
  uint16_t format;       /* off 10 — 0 = Int16 interleaved */
  uint32_t capacity;     /* off 12 — VPHONED_AUDIO_RING_CAPACITY */
  uint32_t consumer_gen; /* off 16 — bumped by vphoned on each host connect;
                          * the producer plays its connect chime once per bump */
  uint32_t _pad;         /* off 20 — align the u64 counters to 24/32 */
  uint64_t write_pos;    /* off 24 — producer-advanced absolute byte count */
  uint64_t read_pos;     /* off 32 — consumer-advanced absolute byte count */
} vphoned_audio_shm_header_t;

/* Starts the vsock listener + ring consumer on a background thread.
 * Idempotent (pthread_once). Called from vphoned startup. */
void vp_audio_start(void);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_AUDIO_H */
