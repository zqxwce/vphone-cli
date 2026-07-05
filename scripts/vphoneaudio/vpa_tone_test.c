// vpa_tone_test.c — standalone guest-side transport proof for Task 2.3.
//
// Opens AF_VSOCK port 1339, accepts the host VPhoneAudioBridge, and pumps a
// 440 Hz stereo Int16 sine tone using the exact 24-byte VPhoneAudioFrame
// header the host expects. This decouples "does the vsock transport + host
// playback work" from "can we inject into audiomxd". Run on the guest over
// SSH; the host bridge (retrying every 3s) connects and should play the tone.
//
// Frame == libvphoneaudio.m / VPhoneAudioFrame.swift. Pure C, no Foundation.

#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY 0xFFFFFFFF
#define VPA_PORT 1339

struct sockaddr_vm { unsigned char svm_len, svm_family; unsigned short svm_reserved1;
                     unsigned int svm_port, svm_cid; };

#define VPA_MAGIC 0x56504155u
#define VPA_HEADER_SIZE 24
#define VPA_SAMPLE_RATE 48000u
#define VPA_CHANNELS    2u
#define VPA_FRAMES      480u            // 10 ms @ 48 kHz
#define VPA_TONE_HZ     440.0
#define VPA_AMPLITUDE   0.3

static void put_u16(uint8_t *p, uint16_t v) { p[0]=v&0xFF; p[1]=(v>>8)&0xFF; }
static void put_u32(uint8_t *p, uint32_t v) { for(int i=0;i<4;i++) p[i]=(v>>(8*i))&0xFF; }
static void put_u64(uint8_t *p, uint64_t v) { for(int i=0;i<8;i++) p[i]=(v>>(8*i))&0xFF; }

static int write_full(int fd, const void *buf, size_t n) {
    size_t off=0; while(off<n){ ssize_t w=write(fd,(const char*)buf+off,n-off); if(w<=0) return 0; off+=w; } return 1;
}

int main(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { fprintf(stderr, "socket errno=%d\n", errno); return 1; }
    struct sockaddr_vm a = { sizeof(a), AF_VSOCK, 0, VPA_PORT, VMADDR_CID_ANY };
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) { fprintf(stderr, "bind errno=%d\n", errno); return 1; }
    if (listen(s, 1) < 0) { fprintf(stderr, "listen errno=%d\n", errno); return 1; }
    fprintf(stderr, "listening on vsock %d\n", VPA_PORT);

    uint8_t hdr[VPA_HEADER_SIZE];
    put_u32(&hdr[0], VPA_MAGIC);
    hdr[4] = 0;   // direction guest->host
    hdr[5] = 0;   // format Int16 interleaved
    put_u16(&hdr[6], VPA_CHANNELS);
    put_u32(&hdr[8], VPA_SAMPLE_RATE);
    put_u32(&hdr[12], VPA_FRAMES);
    put_u64(&hdr[16], 0);

    const size_t pcmBytes = (size_t)VPA_FRAMES * VPA_CHANNELS * sizeof(int16_t);
    int16_t pcm[VPA_FRAMES * VPA_CHANNELS];
    const double phaseInc = 2.0 * M_PI * VPA_TONE_HZ / (double)VPA_SAMPLE_RATE;

    for (;;) {
        struct sockaddr_vm peer; socklen_t plen = sizeof(peer);
        int fd = accept(s, (struct sockaddr *)&peer, &plen);
        if (fd < 0) { fprintf(stderr, "accept errno=%d\n", errno); usleep(100000); continue; }
        fprintf(stderr, "host connected; pumping 440 Hz tone\n");
        double phase = 0.0;
        for (;;) {
            for (uint32_t f = 0; f < VPA_FRAMES; f++) {
                int16_t sample = (int16_t)lrint(sin(phase) * VPA_AMPLITUDE * 32767.0);
                pcm[f*VPA_CHANNELS+0] = sample;
                pcm[f*VPA_CHANNELS+1] = sample;
                phase += phaseInc;
                if (phase >= 2.0*M_PI) phase -= 2.0*M_PI;
            }
            if (!write_full(fd, hdr, VPA_HEADER_SIZE)) break;
            if (!write_full(fd, pcm, pcmBytes)) break;
            usleep(10000);
        }
        fprintf(stderr, "peer closed; re-accepting\n");
        close(fd);
    }
    return 0;
}
