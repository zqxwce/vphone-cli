/*
 * vphoned_audio — shared-ring -> vsock 1339 audio publisher.
 *
 * audiomxd's libvphoneaudio (the producer) cannot open AF_VSOCK (sandbox).
 * It writes guest output PCM into a shared-memory ring (vphoned_audio.h);
 * this consumer, running in vphoned (root, has vsock perms), accepts the
 * host VPhoneAudioBridge on vsock 1339, drains the ring, and emits the
 * 24-byte 'VPAU' frames the host expects (VPhoneAudioFrame.swift).
 *
 * On each host connect we bump header->consumer_gen + notify_post so the
 * producer plays its one-shot connect chime; we also resync read_pos to
 * write_pos so a stale backlog isn't replayed.
 */

#import "vphoned_audio.h"

#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xFFFFFFFFu
#endif

struct vp_sockaddr_vm {
  __uint8_t   svm_len;
  sa_family_t svm_family;
  __uint16_t  svm_reserved1;
  __uint32_t  svm_port;
  __uint32_t  svm_cid;
};

/* VPhoneAudioFrame wire header (must byte-match VPhoneAudioFrame.swift). */
#define VPA_WIRE_MAGIC 0x56504155u /* 'VPAU' */
#define VPA_WIRE_HEADER_SIZE 24
#define VPA_MAX_CHUNK_FRAMES 480u /* 10 ms @ 48k per emitted frame */

static pthread_once_t s_start_once = PTHREAD_ONCE_INIT;
static uint8_t       *s_shm_base   = NULL;
static int            s_notify_token = -1;

#define VPA_LOG_PATH "/var/jb/var/mobile/Library/vphone-audio.log"

__attribute__((format(printf, 1, 2)))
static void vpa_logf(const char *fmt, ...) {
  FILE *fp = fopen(VPA_LOG_PATH, "a");
  if (!fp) return;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(fp, fmt, ap);
  va_end(ap);
  fputc('\n', fp);
  fclose(fp);
}

/* Create (if needed) + map the shared ring, initializing the header if this
 * is a fresh file. vphoned is the owner/initializer; the producer maps the
 * same file and only initializes if it happens to win the race. */
static int open_shm(void) {
  int fd = open(VPHONED_AUDIO_SHM_PATH, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    vpa_logf("vphoned_audio: open(%s) failed: %s",
             VPHONED_AUDIO_SHM_PATH, strerror(errno));
    return -1;
  }
  if (ftruncate(fd, VPHONED_AUDIO_SHM_TOTAL_SIZE) < 0) {
    vpa_logf("vphoned_audio: ftruncate failed: %s", strerror(errno));
    close(fd);
    return -1;
  }
  /* 0666: audiomxd runs as uid 501 (mobile), not root, and is the PRODUCER —
   * it needs O_RDWR on this root-created file, so it must be world-writable. */
  fchmod(fd, 0666);
  void *base = mmap(NULL, VPHONED_AUDIO_SHM_TOTAL_SIZE,
                    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vpa_logf("vphoned_audio: mmap failed: %s", strerror(errno));
    return -1;
  }
  vphoned_audio_shm_header_t *hdr = (vphoned_audio_shm_header_t *)base;
  /* Fresh-init on every vphoned start: reset the ring (consumer owns lifecycle). */
  hdr->sample_rate = VPHONED_AUDIO_SAMPLE_RATE;
  hdr->channels    = (uint16_t)VPHONED_AUDIO_CHANNELS;
  hdr->format      = 0;
  hdr->capacity    = VPHONED_AUDIO_RING_CAPACITY;
  atomic_store_explicit((_Atomic uint64_t *)&hdr->write_pos, 0, memory_order_release);
  atomic_store_explicit((_Atomic uint64_t *)&hdr->read_pos, 0, memory_order_release);
  /* consumer_gen is preserved across nothing here — start at 0 each boot. */
  atomic_store_explicit((_Atomic uint32_t *)&hdr->consumer_gen, 0, memory_order_release);
  atomic_store_explicit((_Atomic uint32_t *)&hdr->magic,
                        VPHONED_AUDIO_MAGIC, memory_order_release);
  s_shm_base = (uint8_t *)base;
  return 0;
}

static int write_full(int fd, const void *buf, size_t n) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t off = 0;
  while (off < n) {
    ssize_t w = write(fd, p + off, n - off);
    if (w > 0) { off += (size_t)w; continue; }
    if (w < 0 && errno == EINTR) continue;
    return 0;
  }
  return 1;
}

static void put_u16(uint8_t *p, uint16_t v) { p[0]=v&0xFF; p[1]=(v>>8)&0xFF; }
static void put_u32(uint8_t *p, uint32_t v) { for (int i=0;i<4;i++) p[i]=(v>>(8*i))&0xFF; }

/* Drain the ring to the connected host until the peer closes. */
static void handle_client(int fd) {
  vphoned_audio_shm_header_t *hdr = (vphoned_audio_shm_header_t *)s_shm_base;
  uint8_t *ring = s_shm_base + VPHONED_AUDIO_SHM_HEADER_SIZE;
  const uint32_t cap = VPHONED_AUDIO_RING_CAPACITY;

  /* Skip any backlog: start from the current write head. */
  uint64_t rpos = atomic_load_explicit((_Atomic uint64_t *)&hdr->write_pos,
                                       memory_order_acquire);
  atomic_store_explicit((_Atomic uint64_t *)&hdr->read_pos, rpos,
                        memory_order_release);

  /* Signal the producer that a host is now listening -> play connect chime. */
  uint32_t gen = atomic_load_explicit((_Atomic uint32_t *)&hdr->consumer_gen,
                                      memory_order_acquire);
  atomic_store_explicit((_Atomic uint32_t *)&hdr->consumer_gen, gen + 1,
                        memory_order_release);
  if (s_notify_token >= 0) notify_post(VPHONED_AUDIO_NOTIFY_NAME);
  vpa_logf("vphoned_audio: host connected fd=%d (gen=%u)", fd, gen + 1);

  uint8_t pkt[VPA_WIRE_HEADER_SIZE + VPA_MAX_CHUNK_FRAMES * VPHONED_AUDIO_BYTES_PER_FRAME];
  uint64_t total_sent = 0;
  for (;;) {
    uint64_t wpos = atomic_load_explicit((_Atomic uint64_t *)&hdr->write_pos,
                                         memory_order_acquire);
    uint64_t avail = wpos - rpos;
    if (avail == 0) { usleep(4000); continue; }       /* ring empty -> wait */
    if (avail > cap) {                                /* producer lapped us */
      rpos = wpos - cap;
      avail = cap;
    }
    uint32_t chunk = avail > (VPA_MAX_CHUNK_FRAMES * VPHONED_AUDIO_BYTES_PER_FRAME)
                       ? (VPA_MAX_CHUNK_FRAMES * VPHONED_AUDIO_BYTES_PER_FRAME)
                       : (uint32_t)avail;
    chunk -= chunk % VPHONED_AUDIO_BYTES_PER_FRAME;   /* frame-align */
    if (chunk == 0) { usleep(4000); continue; }

    /* Copy PCM out of the ring (handle wrap). */
    uint8_t *pcm = pkt + VPA_WIRE_HEADER_SIZE;
    uint32_t off = (uint32_t)(rpos % cap);
    if (off + chunk <= cap) {
      memcpy(pcm, ring + off, chunk);
    } else {
      uint32_t first = cap - off;
      memcpy(pcm, ring + off, first);
      memcpy(pcm + first, ring, chunk - first);
    }

    uint32_t frame_count = chunk / VPHONED_AUDIO_BYTES_PER_FRAME;
    put_u32(&pkt[0], VPA_WIRE_MAGIC);
    pkt[4] = 0;                 /* direction guest->host */
    pkt[5] = 0;                 /* format Int16 interleaved */
    put_u16(&pkt[6], (uint16_t)VPHONED_AUDIO_CHANNELS);
    put_u32(&pkt[8], VPHONED_AUDIO_SAMPLE_RATE);
    put_u32(&pkt[12], frame_count);
    memset(&pkt[16], 0, 8);     /* hostTimeNs */

    if (!write_full(fd, pkt, VPA_WIRE_HEADER_SIZE + chunk)) break;
    rpos += chunk;
    atomic_store_explicit((_Atomic uint64_t *)&hdr->read_pos, rpos,
                          memory_order_release);
    total_sent += chunk;
  }
  vpa_logf("vphoned_audio: host disconnected (%llu bytes sent)",
           (unsigned long long)total_sent);
  close(fd);
}

static void *listener_thread(__unused void *unused) {
  if (open_shm() < 0) return NULL;

  if (notify_register_check(VPHONED_AUDIO_NOTIFY_NAME,
                            &s_notify_token) != NOTIFY_STATUS_OK) {
    s_notify_token = -1;
  }

  int srv = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (srv < 0) {
    vpa_logf("vphoned_audio: socket(AF_VSOCK) failed: %s", strerror(errno));
    return NULL;
  }
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct vp_sockaddr_vm addr = {
      .svm_len    = sizeof(addr),
      .svm_family = AF_VSOCK,
      .svm_port   = VPHONED_AUDIO_VSOCK_PORT,
      .svm_cid    = VMADDR_CID_ANY,
  };
  if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    vpa_logf("vphoned_audio: bind(%d) failed: %s",
             VPHONED_AUDIO_VSOCK_PORT, strerror(errno));
    close(srv);
    return NULL;
  }
  if (listen(srv, 2) < 0) {
    vpa_logf("vphoned_audio: listen failed: %s", strerror(errno));
    close(srv);
    return NULL;
  }
  vpa_logf("vphoned_audio: listening on vsock %d, shm=%s",
           VPHONED_AUDIO_VSOCK_PORT, VPHONED_AUDIO_SHM_PATH);

  for (;;) {
    int fd = accept(srv, NULL, NULL);
    if (fd < 0) {
      if (errno == EINTR) continue;
      vpa_logf("vphoned_audio: accept failed: %s", strerror(errno));
      sleep(1);
      continue;
    }
    handle_client(fd);
  }
}

static void start_listener_once(void) {
  pthread_t thr;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&thr, &attr, listener_thread, NULL);
  pthread_attr_destroy(&attr);
  if (rc != 0) vpa_logf("vphoned_audio: pthread_create failed: %d", rc);
}

void vp_audio_start(void) {
  vpa_logf("vphoned_audio: vp_audio_start called (pid=%d)", getpid());
  pthread_once(&s_start_once, start_listener_once);
}
