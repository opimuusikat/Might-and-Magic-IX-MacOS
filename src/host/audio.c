// Miles Sound System 6 (mss32.dll) API on macOS: the 84 _AIL_* calls lithtech.exe imports, on one
// CoreAudio output unit with a software mixer.
//  - voices: 2D samples (HSAMPLE), 3D samples (H3DSAMPLE), streams (HSTREAM); linear-interpolation
//    resampling, volume/pan, loop blocks and counts
//  - 3D: one software provider ("Miles Fast 2D Positional Audio"); gain from distance (inverse, silent
//    beyond max distance), pan from the listener's orientation; obstruction/occlusion lower the gain
//  - formats: PCM 8/16-bit mono/stereo, IMA ADPCM (decoded here), MP3 (AudioToolbox; in memory for
//    AIL_decompress_ASI and compressed WAVs, on a decoder thread for streams)
// How the engine drives it (decompiled, see m1/decomp/lt_sound.c): 3D sounds get raw PCM through
// AIL_set_3D_sample_info after AIL_decompress_ADPCM/ASI; 2D sounds use set_sample_address/type or
// set_sample_file; music plays as streams by file name; the engine times sound ends with AIL_ms_count.
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "shims.h"

#define OUT_RATE 44100.0
#define MAXV 96
enum { SMP_FREE = 1, SMP_DONE = 2, SMP_PLAYING = 4, SMP_STOPPED = 8 };
enum { K_2D = 1, K_3D, K_STREAM, K_LISTENER };

typedef struct {                 // decoded stream: fixed 1-second chunks, filled by a decoder thread
    int16_t *chunk[4096];
    volatile uint32_t frames;    // decoded so far
    volatile int done, stop;
    int channels; double rate;
    char path[1024];             // MP3 file (music), or
    int fd;                      // >= 0: 16-bit PCM read from this pipe (Bink soundtracks, see bink.c)
    pthread_t th;
} Dec;

typedef struct {
    int kind, used;
    uint32_t guest;              // guest handle
    int status;
    const uint8_t *data;         // PCM: guest memory or `owned`
    int16_t *owned;
    Dec *dec;                    // streams
    int bits, channels; double rate;
    uint32_t frames;
    double pos;                  // in frames
    int loop_count, loops_done;
    uint32_t loop_start, loop_end;   // frames (loop_end 0: end)
    int volume, pan;             // 0..127
    float pos3[3], vel3[3], face[3], up[3], mind, maxd, obstruction, occlusion;
    int user[8];
    float gl, gr;                // computed gains
} Voice;

static Voice v[MAXV];
static os_unfair_lock ml = OS_UNFAIR_LOCK_INIT;
#define L os_unfair_lock_lock(&ml)
#define UL os_unfair_lock_unlock(&ml)
static AudioUnit au;
static int master = 127, started;
static float lis_pos[3], lis_face[3] = {0, 0, 1}, lis_up[3] = {0, 1, 0};
static uint32_t listener_guest;
static uint32_t err_str;
static int trace_audio(void) { static int t = -1; if (t < 0) t = getenv("M1_TRACE_AUDIO") != NULL; return t; }
static volatile float meter_peak; static volatile int meter_voices;
// called once a second by stats.c: peak output level and most simultaneous voices since the last call
void audio_report(void) {
    if (!trace_audio() || started <= 0) return;
    fprintf(stderr, "[audio] peak %.3f, up to %d voices\n", meter_peak, meter_voices);
    meter_peak = 0; meter_voices = 0;
}

static float fa(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }
static Voice *vh(uint32_t g) {
    if (!g) return NULL;
    uint32_t i = G32(g + 12);
    return i < MAXV && v[i].used && v[i].guest == g ? &v[i] : NULL;
}
static Voice *vnew(int kind) {
    for (int i = 0; i < MAXV; i++) if (!v[i].used) {
        Voice *x = &v[i];
        memset(x, 0, sizeof *x);
        x->used = 1; x->kind = kind; x->status = SMP_DONE; x->volume = 127; x->pan = 64; x->loop_count = 1;
        x->face[2] = 1; x->up[1] = 1; x->mind = 1; x->maxd = 1e9f;
        x->guest = gmalloc(64);
        memcpy(MEM + x->guest, kind == K_3D ? "H3DS" : kind == K_STREAM ? "HSTR" : kind == K_LISTENER ? "H3DL" : "HSAM", 4);
        P32(x->guest + 8, SMP_DONE); P32(x->guest + 12, (uint32_t)i);
        return x;
    }
    fprintf(stderr, "[audio] out of voices\n");
    return NULL;
}
static void dec_free(Dec *d) {
    if (!d) return;
    d->stop = 1; pthread_join(d->th, NULL);
    for (int i = 0; i < 4096; i++) free(d->chunk[i]);
    free(d);
}
static void vclear_data(Voice *x) { free(x->owned); x->owned = NULL; x->data = NULL; x->frames = 0; x->pos = 0; }
static void vfree(Voice *x) {
    Dec *d = x->dec; x->dec = NULL;
    vclear_data(x); x->used = 0;
    if (d) { UL; dec_free(d); L; }
}
static void set_status(Voice *x, int s) { x->status = s; if (x->guest) P32(x->guest + 8, (uint32_t)s); }

// ---- gains --------------------------------------------------------------------------------------
static void pan_gains(float pan, float g, float *gl, float *gr) {        // pan -1..1, equal power
    float a = (pan + 1) * 0.25f * (float)M_PI;
    *gl = g * cosf(a) * 1.41421356f; *gr = g * sinf(a) * 1.41421356f;
    if (*gl > g) *gl = g; if (*gr > g) *gr = g;
}
static void calc_gains(Voice *x) {
    float g = (x->volume / 127.0f) * (master / 127.0f);
    if (x->kind == K_3D) {
        float d[3] = {x->pos3[0] - lis_pos[0], x->pos3[1] - lis_pos[1], x->pos3[2] - lis_pos[2]};
        float dist = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        float att = dist <= x->mind ? 1.0f : x->mind / dist;
        if (dist >= x->maxd) att = 0;
        // right = up x face (left-handed: x right, y up, z forward)
        float r[3] = {lis_up[1] * lis_face[2] - lis_up[2] * lis_face[1], lis_up[2] * lis_face[0] - lis_up[0] * lis_face[2], lis_up[0] * lis_face[1] - lis_up[1] * lis_face[0]};
        float rl = sqrtf(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
        float pan = dist > 1e-3f && rl > 1e-6f ? (d[0] * r[0] + d[1] * r[1] + d[2] * r[2]) / (dist * rl) : 0;
        g *= att * (1.0f - 0.6f * x->obstruction) * (1.0f - 0.5f * x->occlusion);
        pan_gains(pan * 0.85f, g, &x->gl, &x->gr);
    } else pan_gains((x->pan - 64) / 63.0f, g, &x->gl, &x->gr);
}

// ---- mixer ----------------------------------------------------------------------------------------
static inline float frame_at(Voice *x, uint32_t f, int ch) {
    if (x->dec) {
        Dec *d = x->dec; uint32_t ci = f / (uint32_t)d->rate, off = f % (uint32_t)d->rate;
        int16_t *c = ci < 4096 ? d->chunk[ci] : NULL;
        return c ? c[off * (uint32_t)d->channels + (uint32_t)(ch < d->channels ? ch : 0)] / 32768.0f : 0;
    }
    int c = ch < x->channels ? ch : 0;
    if (x->bits == 16) { int16_t s; memcpy(&s, x->data + ((size_t)f * (size_t)x->channels + (size_t)c) * 2, 2); return s / 32768.0f; }
    return (x->data[(size_t)f * (size_t)x->channels + (size_t)c] - 128) / 128.0f;
}
static OSStatus render(void *ref, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *io) {
    (void)ref; (void)fl; (void)ts; (void)bus;
    float *out = io->mBuffers[0].mData;
    memset(out, 0, n * 2 * sizeof(float));
    L;
    for (int i = 0; i < MAXV; i++) {
        Voice *x = &v[i];
        if (!x->used || x->status != SMP_PLAYING || x->kind == K_LISTENER) continue;
        uint32_t avail = x->dec ? x->dec->frames : x->frames;
        if (!avail || (!x->dec && !x->data)) continue;
        calc_gains(x);
        double step = x->rate / OUT_RATE;
        uint32_t end = x->loop_end && x->loop_end <= avail ? x->loop_end : avail;
        for (UInt32 k = 0; k < n; k++) {
            uint32_t f = (uint32_t)x->pos;
            if (f + 1 >= end) {
                int more = x->dec && !x->dec->done && x->loop_end == 0;
                if (more) break;                                        // decoder behind: wait
                if (x->loop_count == 0 || ++x->loops_done < x->loop_count) { x->pos = x->loop_start + (x->pos - f); f = (uint32_t)x->pos; if (f + 1 >= end) break; }
                else { set_status(x, SMP_DONE); x->pos = 0; break; }
            }
            float t = (float)(x->pos - f);
            float a0 = frame_at(x, f, 0), a1 = frame_at(x, f + 1, 0);
            float sl = a0 + (a1 - a0) * t, sr = sl;
            if (x->channels == 2 || (x->dec && x->dec->channels == 2)) { float b0 = frame_at(x, f, 1), b1 = frame_at(x, f + 1, 1); sr = b0 + (b1 - b0) * t; }
            out[2 * k] += sl * x->gl; out[2 * k + 1] += sr * x->gr;
            x->pos += step;
        }
    }
    int act = 0; for (int i = 0; i < MAXV; i++) act += v[i].used && v[i].status == SMP_PLAYING && v[i].kind != K_LISTENER;
    UL;
    float pk = 0;
    for (UInt32 k = 0; k < 2 * n; k++) {           // soft knee above 0.8 instead of hard clipping
        float s = out[k], a = fabsf(s);
        if (a > pk) pk = a;
        if (a > 0.8f) out[k] = copysignf(0.8f + 0.2f * tanhf((a - 0.8f) / 0.2f), s);
    }
    if (pk > meter_peak) meter_peak = pk;
    if (act > meter_voices) meter_voices = act;
    return noErr;
}
static int audio_start(void) {
    if (started) return started > 0;
    if (getenv("M1_NOSOUND")) { started = -1; return 0; }
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp || AudioComponentInstanceNew(comp, &au)) { fprintf(stderr, "[audio] no output unit\n"); started = -1; return 0; }
    AudioStreamBasicDescription f = {OUT_RATE, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AURenderCallbackStruct cb = {render, NULL};
    AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (AudioUnitInitialize(au) || AudioOutputUnitStart(au)) { fprintf(stderr, "[audio] output start failed\n"); started = -1; return 0; }
    fprintf(stderr, "[audio] CoreAudio output started (44.1 kHz stereo, software mixer)\n");
    started = 1;
    return 1;
}

// ---- decoding ---------------------------------------------------------------------------------------
static const int ima_index[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};
static const int ima_step[89] = {7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
static int16_t ima_nib(int nib, int *pred, int *idx) {
    int step = ima_step[*idx], diff = step >> 3;
    if (nib & 1) diff += step >> 2; if (nib & 2) diff += step >> 1; if (nib & 4) diff += step;
    if (nib & 8) *pred -= diff; else *pred += diff;
    if (*pred > 32767) *pred = 32767; if (*pred < -32768) *pred = -32768;
    *idx += ima_index[nib]; if (*idx < 0) *idx = 0; if (*idx > 88) *idx = 88;
    return (int16_t)*pred;
}
// Microsoft IMA ADPCM -> interleaved PCM16; returns frames
static uint32_t ima_decode(const uint8_t *in, uint32_t len, int ch, uint32_t block, int16_t **out) {
    if (ch < 1 || ch > 2 || block < 4u * (uint32_t)ch) return 0;
    uint32_t per_block = (block - 4u * (uint32_t)ch) * 2 / (uint32_t)ch + 1, nblocks = (len + block - 1) / block;
    int16_t *o = malloc((size_t)per_block * nblocks * (size_t)ch * 2 + 16);
    uint32_t frames = 0;
    for (uint32_t b = 0; b < nblocks; b++) {
        const uint8_t *p = in + b * block; uint32_t bl = len - b * block < block ? len - b * block : block;
        if (bl < 4u * (uint32_t)ch) break;
        int pred[2], idx[2];
        for (int c = 0; c < ch; c++) { int16_t s; memcpy(&s, p + 4 * c, 2); pred[c] = s; idx[c] = p[4 * c + 2] > 88 ? 88 : p[4 * c + 2]; o[(size_t)frames * (size_t)ch + (size_t)c] = s; }
        uint32_t f0 = frames + 1, nf = 1;
        const uint8_t *q = p + 4 * ch, *e = p + bl;
        if (ch == 1) {
            for (; q < e; q++) { o[f0 + nf - 1] = ima_nib(*q & 15, &pred[0], &idx[0]); o[f0 + nf] = ima_nib(*q >> 4, &pred[0], &idx[0]); nf += 2; }
        } else {
            while (q + 8 <= e) {
                for (int c = 0; c < 2; c++)
                    for (int k = 0; k < 4; k++) {
                        uint8_t by = q[c * 4 + k];
                        o[(size_t)(f0 - 1 + nf + (uint32_t)(2 * k)) * 2 + (size_t)c] = ima_nib(by & 15, &pred[c], &idx[c]);
                        o[(size_t)(f0 + nf + (uint32_t)(2 * k)) * 2 + (size_t)c] = ima_nib(by >> 4, &pred[c], &idx[c]);
                    }
                q += 8; nf += 8;
            }
        }
        frames += nf;
    }
    *out = o;
    return frames;
}
// MP3 bytes in memory -> interleaved PCM16
typedef struct { const uint8_t *p; uint32_t n; } MemF;
static OSStatus mf_read(void *u, SInt64 pos, UInt32 req, void *buf, UInt32 *got) {
    MemF *m = u; if (pos >= m->n) { *got = 0; return noErr; }
    UInt32 k = (UInt32)(m->n - pos) < req ? (UInt32)(m->n - pos) : req; memcpy(buf, m->p + pos, k); *got = k; return noErr;
}
static SInt64 mf_size(void *u) { return ((MemF *)u)->n; }
static uint32_t read_all(ExtAudioFileRef ef, int *ch, double *rate, int16_t **out) {
    AudioStreamBasicDescription in; UInt32 sz = sizeof in;
    if (ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &in)) return 0;
    *ch = in.mChannelsPerFrame > 2 ? 2 : (int)in.mChannelsPerFrame; *rate = in.mSampleRate;
    AudioStreamBasicDescription cf = {in.mSampleRate, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                      2u * (UInt32)*ch, 1, 2u * (UInt32)*ch, (UInt32)*ch, 16, 0};
    if (ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof cf, &cf)) return 0;
    size_t cap = 1 << 20, n = 0; int16_t *o = malloc(cap * 2u * (size_t)*ch);
    for (;;) {
        if (n + 8192 > cap) { cap *= 2; o = realloc(o, cap * 2u * (size_t)*ch); }
        AudioBufferList bl = {1, {{(UInt32)*ch, 8192 * 2u * (UInt32)*ch, o + n * (size_t)*ch}}};
        UInt32 fr = 8192;
        if (ExtAudioFileRead(ef, &fr, &bl) || !fr) break;
        n += fr;
    }
    *out = o;
    return (uint32_t)n;
}
static uint32_t mp3_decode(const uint8_t *p, uint32_t n, int *ch, double *rate, int16_t **out) {
    MemF m = {p, n}; AudioFileID af; ExtAudioFileRef ef;
    if (AudioFileOpenWithCallbacks(&m, mf_read, NULL, mf_size, NULL, kAudioFileMP3Type, &af)) return 0;
    if (ExtAudioFileWrapAudioFileID(af, false, &ef)) { AudioFileClose(af); return 0; }
    uint32_t fr = read_all(ef, ch, rate, out);
    ExtAudioFileDispose(ef); AudioFileClose(af);
    return fr;
}
// RIFF WAVE image -> format + data (PCM in place; ADPCM/MP3 decoded into *owned)
typedef struct { int tag, ch, bits; uint32_t rate, block; const uint8_t *data; uint32_t len; } Wav;
static int wav_parse(const uint8_t *p, uint32_t n, Wav *w) {
    if (n < 12 || memcmp(p, "RIFF", 4) || memcmp(p + 8, "WAVE", 4)) return 0;
    memset(w, 0, sizeof *w);
    for (uint32_t o = 12; o + 8 <= n;) {
        uint32_t cl; memcpy(&cl, p + o + 4, 4);
        if (!memcmp(p + o, "fmt ", 4) && cl >= 16) {
            uint16_t t, c, ba, b; uint32_t r; memcpy(&t, p + o + 8, 2); memcpy(&c, p + o + 10, 2); memcpy(&r, p + o + 12, 4); memcpy(&ba, p + o + 20, 2); memcpy(&b, p + o + 22, 2);
            w->tag = t; w->ch = c; w->rate = r; w->block = ba; w->bits = b;
        } else if (!memcmp(p + o, "data", 4)) { w->data = p + o + 8; w->len = cl <= n - o - 8 ? cl : n - o - 8; }
        o += 8 + cl + (cl & 1);
    }
    return w->data && w->tag;
}
static int voice_from_wav(Voice *x, const uint8_t *img, uint32_t n) {
    Wav w;
    if (!wav_parse(img, n, &w)) { if (trace_audio()) fprintf(stderr, "[audio] not a WAV image\n"); return 0; }
    vclear_data(x);
    if (w.tag == 1 && (w.bits == 8 || w.bits == 16) && (w.ch == 1 || w.ch == 2)) {
        x->data = w.data; x->bits = w.bits; x->channels = w.ch; x->rate = w.rate; x->frames = w.len / (uint32_t)(w.bits / 8 * w.ch);
    } else if (w.tag == 0x11) {
        int16_t *o; uint32_t fr = ima_decode(w.data, w.len, w.ch, w.block, &o);
        if (!fr) return 0;
        x->owned = o; x->data = (uint8_t *)o; x->bits = 16; x->channels = w.ch; x->rate = w.rate; x->frames = fr;
    } else if (w.tag == 0x55) {
        int16_t *o; int ch; double r; uint32_t fr = mp3_decode(w.data, w.len, &ch, &r, &o);
        if (!fr) return 0;
        x->owned = o; x->data = (uint8_t *)o; x->bits = 16; x->channels = ch; x->rate = r; x->frames = fr;
    } else { fprintf(stderr, "[audio] unsupported WAV format %#x\n", w.tag); return 0; }
    x->pos = 0; x->loop_start = 0; x->loop_end = 0;
    return 1;
}
// PCM16 -> WAV image in guest memory (for AIL_decompress_*)
static uint32_t wav_image(const int16_t *pcm, uint32_t frames, int ch, uint32_t rate, uint32_t *size) {
    uint32_t dl = frames * 2u * (uint32_t)ch, n = 44 + dl, p = gmalloc(n);
    uint8_t h[44] = "RIFF....WAVEfmt ";
    uint32_t v32; uint16_t v16;
    v32 = n - 8; memcpy(h + 4, &v32, 4); v32 = 16; memcpy(h + 16, &v32, 4); v16 = 1; memcpy(h + 20, &v16, 2);
    v16 = (uint16_t)ch; memcpy(h + 22, &v16, 2); memcpy(h + 24, &rate, 4); v32 = rate * 2u * (uint32_t)ch; memcpy(h + 28, &v32, 4);
    v16 = (uint16_t)(2 * ch); memcpy(h + 32, &v16, 2); v16 = 16; memcpy(h + 34, &v16, 2); memcpy(h + 36, "data", 4); memcpy(h + 40, &dl, 4);
    memcpy(MEM + p, h, 44); memcpy(MEM + p + 44, pcm, dl);
    *size = n;
    return p;
}

// ---- stream decoder thread ------------------------------------------------------------------------------
static void *dec_main(void *arg) {
    Dec *d = arg;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)d->path, (CFIndex)strlen(d->path), false);
    ExtAudioFileRef ef;
    OSStatus e = ExtAudioFileOpenURL(url, &ef); CFRelease(url);
    if (e) { fprintf(stderr, "[audio] cannot open stream %s (%d)\n", d->path, (int)e); d->done = 1; return NULL; }
    AudioStreamBasicDescription in; UInt32 sz = sizeof in;
    ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &in);
    int ch = d->channels;
    AudioStreamBasicDescription cf = {in.mSampleRate, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                      2u * (UInt32)ch, 1, 2u * (UInt32)ch, (UInt32)ch, 16, 0};
    ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof cf, &cf);
    uint32_t cs = (uint32_t)d->rate;
    for (int ci = 0; ci < 4096 && !d->stop; ci++) {
        int16_t *c = calloc(cs, 2u * (size_t)ch);
        uint32_t got = 0;
        while (got < cs) {
            UInt32 fr = cs - got;
            AudioBufferList bl = {1, {{(UInt32)ch, fr * 2u * (UInt32)ch, c + (size_t)got * (size_t)ch}}};
            if (ExtAudioFileRead(ef, &fr, &bl) || !fr) break;
            got += fr;
        }
        d->chunk[ci] = c;
        __atomic_store_n(&d->frames, d->frames + got, __ATOMIC_RELEASE);
        if (got < cs) break;
    }
    ExtAudioFileDispose(ef);
    d->done = 1;
    return NULL;
}

// PCM from a pipe (interleaved 16-bit, little-endian) in the same 1-second chunks
static void *dec_pipe_main(void *arg) {
    Dec *d = arg;
    uint32_t cs = (uint32_t)d->rate, fb = 2u * (uint32_t)d->channels;
    for (int ci = 0; ci < 4096 && !d->stop; ci++) {
        int16_t *c = calloc(cs, fb);
        size_t got = 0, want = (size_t)cs * fb;
        while (got < want && !d->stop) { ssize_t r = read(d->fd, (uint8_t *)c + got, want - got); if (r <= 0) break; got += (size_t)r; }
        d->chunk[ci] = c;
        __atomic_store_n(&d->frames, d->frames + (uint32_t)(got / fb), __ATOMIC_RELEASE);
        if (got < want) break;
    }
    close(d->fd);
    d->done = 1;
    return NULL;
}
// For other host modules (bink.c): play 16-bit PCM arriving on fd as one stream voice at the game's
// master volume. audio_pipe_start returns an id (-1 without sound); the voice starts paused.
int audio_pipe_start(int fd, int channels, double rate) {
    if (!audio_start()) return -1;
    Dec *d = calloc(1, sizeof *d);
    d->fd = fd; d->channels = channels; d->rate = rate;
    L; Voice *x = vnew(K_STREAM);
    if (x) { x->dec = d; x->channels = channels; x->bits = 16; x->rate = rate; set_status(x, SMP_STOPPED); }
    UL;
    if (!x) { free(d); return -1; }
    pthread_create(&d->th, NULL, dec_pipe_main, d);
    return (int)(x - v);
}
int audio_pipe_ready(int id) { return id >= 0 && v[id].used && v[id].dec && (v[id].dec->frames || v[id].dec->done); }
void audio_pipe_play(int id) { if (id < 0) return; L; if (v[id].used && v[id].dec) set_status(&v[id], SMP_PLAYING); UL; }
// The writer must be gone (pipe closed) first, so the reader thread sees EOF.
void audio_pipe_stop(int id) { if (id < 0) return; L; if (v[id].used && v[id].dec) vfree(&v[id]); UL; }

// ---- API ----------------------------------------------------------------------------------------------
extern _Thread_local const HostImport *host_cur_import;
static void ret_float(CPU *c, float f, int nargs) {       // F32 results come back in x87 ST0
    uint8_t *R = c->r;
    for (int i = 7; i > 0; i--) memcpy(R + 4352 + 16 * i, R + 4352 + 16 * (i - 1), 8);
    double d = f; memcpy(R + 4352, &d, 8);
    R[REG_TOP] = (uint8_t)((R[REG_TOP] - 1) & 7);
    RET(c, 0, nargs);
}
#define A(i) ARG(c, i)
#define FA(i) fa(ARG(c, i))
#define VX(i) Voice *x = vh(A(i))

SHIM(_AIL_startup) { RET(c, 1, 0); }
SHIM(_AIL_shutdown) { RET(c, 0, 0); }
static int prefs[64];
SHIM(_AIL_set_preference) { uint32_t i = A(0) & 63; int old = prefs[i]; prefs[i] = (int)A(1); RET(c, (uint32_t)old, 2); }
SHIM(_AIL_get_preference) { RET(c, (uint32_t)prefs[A(0) & 63], 1); }
SHIM(_AIL_lock) { RET(c, 0, 0); }
SHIM(_AIL_unlock) { RET(c, 0, 0); }
SHIM(_AIL_last_error) { if (!err_str) err_str = gstrdup(""); RET(c, err_str, 0); }
SHIM(_AIL_ms_count) { RET(c, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000ull), 0); }
SHIM(_AIL_mem_alloc_lock) { RET(c, gmalloc(A(0)), 1); }
SHIM(_AIL_mem_free_lock) { gfree(A(0)); RET(c, 0, 1); }
SHIM(_AIL_waveOutOpen) {
    if (!audio_start()) { if (!err_str) err_str = gstrdup("No sound output"); RET(c, (uint32_t)-1, 4); return; }
    uint32_t dig = gmalloc(64); memcpy(MEM + dig, "HDIG", 4);
    if (A(0)) P32(A(0), dig);
    if (A(1)) P32(A(1), 0x00777777);
    RET(c, 0, 4);
}
SHIM(_AIL_waveOutClose) { RET(c, 0, 1); }
SHIM(_AIL_digital_handle_release) { RET(c, 1, 1); }
SHIM(_AIL_digital_handle_reacquire) { RET(c, 1, 1); }
SHIM(_AIL_digital_master_volume) { RET(c, (uint32_t)master, 1); }
SHIM(_AIL_set_digital_master_volume) { L; master = (int)A(1); UL; RET(c, 0, 2); }

// 2D samples
SHIM(_AIL_allocate_sample_handle) { L; Voice *x = vnew(K_2D); UL; RET(c, x ? x->guest : 0, 1); }
SHIM(_AIL_release_sample_handle) { L; VX(0); if (x) vfree(x); UL; RET(c, 0, 1); }
SHIM(_AIL_init_sample) {
    L; VX(0);
    if (x) { vclear_data(x); set_status(x, SMP_DONE); x->volume = 127; x->pan = 64; x->loop_count = 1; x->loops_done = 0; x->loop_start = x->loop_end = 0; x->bits = 8; x->channels = 1; x->rate = 11025; }
    UL; RET(c, 0, 1);
}
SHIM(_AIL_set_sample_type) {
    L; VX(0); uint32_t f = A(1);
    if (x) { x->bits = (f & 1) ? 16 : 8; x->channels = (f & 2) ? 2 : 1; }
    UL; RET(c, 0, 3);
}
SHIM(_AIL_set_sample_address) {
    L; VX(0);
    if (x) { free(x->owned); x->owned = NULL; x->data = MEM + A(1); x->frames = A(2) / (uint32_t)(x->bits / 8 * x->channels); x->pos = 0; }
    UL; RET(c, 0, 3);
}
SHIM(_AIL_set_sample_file) {
    L; VX(0); uint32_t img = A(1); int ok = 0;
    if (x && img) { uint32_t riff = G32(img + 4) + 8; ok = voice_from_wav(x, MEM + img, riff); }
    UL; RET(c, (uint32_t)ok, 3);
}
SHIM(_AIL_set_sample_playback_rate) { L; VX(0); if (x) x->rate = (double)(int32_t)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_set_sample_volume) { L; VX(0); if (x) x->volume = (int)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_sample_volume) { VX(0); RET(c, x ? (uint32_t)x->volume : 0, 1); }
SHIM(_AIL_set_sample_pan) { L; VX(0); if (x) x->pan = (int)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_sample_pan) { VX(0); RET(c, x ? (uint32_t)x->pan : 64, 1); }
SHIM(_AIL_set_sample_loop_count) { L; VX(0); if (x) { x->loop_count = (int)A(1); x->loops_done = 0; } UL; RET(c, 0, 2); }
static uint32_t bytes2frames(Voice *x, int32_t b) { int fb = x->bits / 8 * x->channels; return b <= 0 ? 0 : (uint32_t)b / (uint32_t)(fb ? fb : 1); }
SHIM(_AIL_set_sample_loop_block) {
    L; VX(0);
    if (x) { x->loop_start = bytes2frames(x, (int32_t)A(1)); x->loop_end = (int32_t)A(2) < 0 ? 0 : bytes2frames(x, (int32_t)A(2)); }
    UL; RET(c, 0, 3);
}
SHIM(_AIL_set_sample_ms_position) { L; VX(0); if (x) x->pos = (int32_t)A(1) * x->rate / 1000.0; UL; RET(c, 0, 2); }
SHIM(_AIL_set_sample_reverb) { RET(c, 0, 4); }
SHIM(_AIL_resume_sample) { L; VX(0); if (x && (x->data || x->dec)) { if (x->pos >= x->frames) x->pos = 0; set_status(x, SMP_PLAYING); } UL; RET(c, 0, 1); }
SHIM(_AIL_stop_sample) { L; VX(0); if (x && x->status == SMP_PLAYING) set_status(x, SMP_STOPPED); UL; RET(c, 0, 1); }
SHIM(_AIL_set_sample_user_data) { VX(0); if (x && A(1) < 8) x->user[A(1)] = (int)A(2); RET(c, 0, 3); }
SHIM(_AIL_sample_user_data) { VX(0); RET(c, x && A(1) < 8 ? (uint32_t)x->user[A(1)] : 0, 2); }

// 3D provider, listener, samples
#define PROVIDER 0x00003D01u
static uint32_t prov_name;
SHIM(_AIL_enumerate_3D_providers) {
    uint32_t next = A(0), dest = A(1), name = A(2);
    if (G32(next) != 0) { RET(c, 0, 3); return; }
    if (!prov_name) prov_name = gstrdup("Miles Fast 2D Positional Audio");
    P32(next, 1); P32(dest, PROVIDER); P32(name, prov_name);
    RET(c, 1, 3);
}
SHIM(_AIL_open_3D_provider) { RET(c, A(0) == PROVIDER && audio_start() ? 0 : 1, 1); }
SHIM(_AIL_close_3D_provider) { RET(c, 0, 1); }
SHIM(_AIL_3D_provider_attribute) { if (A(2)) P32(A(2), 0xFFFFFFFFu); RET(c, 0, 3); }   // no EAX
SHIM(_AIL_set_3D_provider_preference) { RET(c, 0, 3); }
SHIM(_AIL_open_3D_listener) { L; Voice *x = vnew(K_LISTENER); if (x) listener_guest = x->guest; UL; RET(c, x ? x->guest : 0, 1); }
SHIM(_AIL_close_3D_listener) { L; VX(0); if (x) vfree(x); if (A(0) == listener_guest) listener_guest = 0; UL; RET(c, 0, 1); }
SHIM(_AIL_allocate_3D_sample_handle) { L; Voice *x = vnew(K_3D); if (x) { x->mind = 1; x->maxd = 1e9f; } UL; RET(c, x ? x->guest : 0, 1); }
SHIM(_AIL_release_3D_sample_handle) { L; VX(0); if (x) vfree(x); UL; RET(c, 0, 1); }
SHIM(_AIL_set_3D_sample_info) {
    L; VX(0); uint32_t info = A(1); int ok = 0;
    if (x && info) {
        uint32_t fmt = G32(info), data = G32(info + 4), len = G32(info + 8), rate = G32(info + 12), bits = G32(info + 16), ch = G32(info + 20), blk = G32(info + 28);
        vclear_data(x);
        if (fmt == 1 && (bits == 8 || bits == 16) && (ch == 1 || ch == 2)) {
            x->data = MEM + data; x->bits = (int)bits; x->channels = (int)ch; x->rate = rate; x->frames = len / (bits / 8 * ch); ok = 1;
        } else if (fmt == 0x11) {
            int16_t *o; uint32_t fr = ima_decode(MEM + data, len, (int)ch, blk, &o);
            if (fr) { x->owned = o; x->data = (uint8_t *)o; x->bits = 16; x->channels = (int)ch; x->rate = rate; x->frames = fr; ok = 1; }
        } else if (trace_audio()) fprintf(stderr, "[audio] 3D sample format %#x not supported\n", fmt);
        x->loop_count = 1; x->loops_done = 0; x->loop_start = x->loop_end = 0; x->volume = 127;
        set_status(x, SMP_DONE);
    }
    UL; RET(c, (uint32_t)ok, 2);
}
SHIM(_AIL_start_3D_sample) { L; VX(0); if (x && x->data) { x->pos = 0; x->loops_done = 0; set_status(x, SMP_PLAYING); } UL; RET(c, 0, 1); }
SHIM(_AIL_stop_3D_sample) { L; VX(0); if (x && x->status == SMP_PLAYING) set_status(x, SMP_STOPPED); UL; RET(c, 0, 1); }
SHIM(_AIL_resume_3D_sample) { L; VX(0); if (x && x->data && (x->status == SMP_STOPPED || x->status == SMP_DONE)) set_status(x, SMP_PLAYING); UL; RET(c, 0, 1); }
SHIM(_AIL_end_3D_sample) { L; VX(0); if (x) { set_status(x, SMP_DONE); x->pos = 0; } UL; RET(c, 0, 1); }
SHIM(_AIL_3D_sample_status) { VX(0); RET(c, x ? (uint32_t)x->status : SMP_FREE, 1); }
SHIM(_AIL_set_3D_sample_volume) { L; VX(0); if (x) x->volume = (int)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_set_3D_sample_playback_rate) { L; VX(0); if (x) x->rate = (double)(int32_t)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_set_3D_sample_loop_count) { L; VX(0); if (x) { x->loop_count = (int)A(1); x->loops_done = 0; } UL; RET(c, 0, 2); }
SHIM(_AIL_set_3D_sample_loop_block) {
    L; VX(0);
    if (x) { x->loop_start = bytes2frames(x, (int32_t)A(1)); x->loop_end = (int32_t)A(2) < 0 ? 0 : bytes2frames(x, (int32_t)A(2)); }
    UL; RET(c, 0, 3);
}
SHIM(_AIL_set_3D_sample_offset) { L; VX(0); if (x) x->pos = bytes2frames(x, (int32_t)A(1)); UL; RET(c, 0, 2); }
SHIM(_AIL_set_3D_sample_distances) { L; VX(0); if (x) { x->maxd = FA(1); x->mind = FA(2) > 0 ? FA(2) : 1; } UL; RET(c, 0, 3); }
SHIM(_AIL_set_3D_sample_obstruction) { L; VX(0); if (x) x->obstruction = FA(1); UL; RET(c, 0, 2); }
SHIM(_AIL_set_3D_sample_occlusion) { L; VX(0); if (x) x->occlusion = FA(1); UL; RET(c, 0, 2); }
SHIM(_AIL_3D_sample_obstruction) { VX(0); ret_float(c, x ? x->obstruction : 0, 1); }
SHIM(_AIL_set_3D_sample_preference) { RET(c, 0, 3); }
SHIM(_AIL_set_3D_position) {
    L; uint32_t h = A(0); float p[3] = {FA(1), FA(2), FA(3)};
    if (h == listener_guest) memcpy(lis_pos, p, sizeof p);
    else { Voice *x = vh(h); if (x) memcpy(x->pos3, p, sizeof p); }
    UL; RET(c, 0, 4);
}
SHIM(_AIL_3D_position) {
    uint32_t h = A(0); float *p = NULL; Voice *x = vh(h);
    if (h == listener_guest) p = lis_pos; else if (x) p = x->pos3;
    for (int i = 0; i < 3; i++) if (A(1 + i)) { float f = p ? p[i] : 0; memcpy(MEM + A(1 + i), &f, 4); }
    RET(c, 0, 4);
}
SHIM(_AIL_set_3D_velocity_vector) { L; VX(0); if (x) { x->vel3[0] = FA(1); x->vel3[1] = FA(2); x->vel3[2] = FA(3); } UL; RET(c, 0, 4); }
SHIM(_AIL_3D_velocity) {
    VX(0);
    for (int i = 0; i < 3; i++) if (A(1 + i)) { float f = x ? x->vel3[i] : 0; memcpy(MEM + A(1 + i), &f, 4); }
    RET(c, 0, 4);
}
SHIM(_AIL_set_3D_orientation) {
    L; uint32_t h = A(0); float f[3] = {FA(1), FA(2), FA(3)}, u[3] = {FA(4), FA(5), FA(6)};
    if (h == listener_guest) { memcpy(lis_face, f, sizeof f); memcpy(lis_up, u, sizeof u); }
    else { Voice *x = vh(h); if (x) { memcpy(x->face, f, sizeof f); memcpy(x->up, u, sizeof u); } }
    UL; RET(c, 0, 7);
}
SHIM(_AIL_3D_orientation) {
    uint32_t h = A(0); Voice *x = vh(h);
    float *f = h == listener_guest ? lis_face : x ? x->face : NULL, *u = h == listener_guest ? lis_up : x ? x->up : NULL;
    for (int i = 0; i < 3; i++) { if (A(1 + i)) { float t = f ? f[i] : 0; memcpy(MEM + A(1 + i), &t, 4); } if (A(4 + i)) { float t = u ? u[i] : 0; memcpy(MEM + A(4 + i), &t, 4); } }
    RET(c, 0, 7);
}
SHIM(_AIL_set_3D_user_data) { VX(0); if (x && A(1) < 8) x->user[A(1)] = (int)A(2); RET(c, 0, 3); }
SHIM(_AIL_3D_user_data) { VX(0); RET(c, x && A(1) < 8 ? (uint32_t)x->user[A(1)] : 0, 2); }

// streams (music)
SHIM(_AIL_open_stream) {
    const char *name = GSTR(A(1));
    char path[1024];
    if (!host_path(name, path, sizeof path)) { RET(c, 0, 3); return; }
    ExtAudioFileRef ef; CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    OSStatus e = ExtAudioFileOpenURL(url, &ef); CFRelease(url);
    if (e) { fprintf(stderr, "[audio] open_stream(%s) failed (%d)\n", name, (int)e); RET(c, 0, 3); return; }
    AudioStreamBasicDescription in; UInt32 sz = sizeof in;
    ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &in);
    ExtAudioFileDispose(ef);
    Dec *d = calloc(1, sizeof *d);
    d->channels = in.mChannelsPerFrame > 2 ? 2 : (int)in.mChannelsPerFrame; d->rate = in.mSampleRate > 0 ? in.mSampleRate : 44100;
    snprintf(d->path, sizeof d->path, "%s", path);
    pthread_create(&d->th, NULL, dec_main, d);
    L; Voice *x = vnew(K_STREAM);
    if (x) { x->dec = d; x->rate = d->rate; x->channels = d->channels; x->bits = 16; set_status(x, SMP_STOPPED); }
    UL;
    if (!x) { dec_free(d); RET(c, 0, 3); return; }
    if (trace_audio()) fprintf(stderr, "[audio] stream %s: %d ch, %.0f Hz\n", name, d->channels, d->rate);
    RET(c, x->guest, 3);
}
SHIM(_AIL_close_stream) { L; VX(0); if (x) vfree(x); UL; RET(c, 0, 1); }
SHIM(_AIL_start_stream) { L; VX(0); if (x) { x->pos = 0; x->loops_done = 0; set_status(x, SMP_PLAYING); } UL; RET(c, 0, 1); }
SHIM(_AIL_pause_stream) { L; VX(0); if (x) set_status(x, A(1) ? SMP_STOPPED : SMP_PLAYING); UL; RET(c, 0, 2); }
SHIM(_AIL_stream_status) { VX(0); RET(c, x ? (uint32_t)x->status : SMP_FREE, 1); }
SHIM(_AIL_set_stream_volume) { L; VX(0); if (x) x->volume = (int)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_stream_volume) { VX(0); RET(c, x ? (uint32_t)x->volume : 0, 1); }
SHIM(_AIL_set_stream_pan) { L; VX(0); if (x) x->pan = (int)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_stream_pan) { VX(0); RET(c, x ? (uint32_t)x->pan : 64, 1); }
SHIM(_AIL_set_stream_playback_rate) { L; VX(0); if (x) x->rate = (double)(int32_t)A(1); UL; RET(c, 0, 2); }
SHIM(_AIL_set_stream_loop_count) { L; VX(0); if (x) { x->loop_count = (int)A(1); x->loops_done = 0; } UL; RET(c, 0, 2); }
SHIM(_AIL_set_stream_ms_position) { L; VX(0); if (x && x->dec) x->pos = (int32_t)A(1) * x->dec->rate / 1000.0; UL; RET(c, 0, 2); }
SHIM(_AIL_stream_ms_position) {
    VX(0);
    uint32_t tot = 0, cur = 0;
    if (x && x->dec) { tot = (uint32_t)(x->dec->frames * 1000.0 / x->dec->rate); cur = (uint32_t)(x->pos * 1000.0 / x->dec->rate); }
    if (A(1)) P32(A(1), tot); if (A(2)) P32(A(2), cur);
    RET(c, 0, 3);
}
SHIM(_AIL_set_stream_user_data) { VX(0); if (x && A(1) < 8) x->user[A(1)] = (int)A(2); RET(c, 0, 3); }

// decompression to WAV images
SHIM(_AIL_decompress_ADPCM) {
    uint32_t info = A(0), outp = A(1), outsz = A(2);
    uint32_t data = G32(info + 4), len = G32(info + 8), rate = G32(info + 12), ch = G32(info + 20), blk = G32(info + 28);
    int16_t *o; uint32_t fr = ima_decode(MEM + data, len, (int)ch, blk, &o);
    if (!fr) { RET(c, 0, 3); return; }
    uint32_t sz, img = wav_image(o, fr, (int)ch, rate, &sz); free(o);
    P32(outp, img); P32(outsz, sz);
    RET(c, 1, 3);
}
SHIM(_AIL_decompress_ASI) {
    uint32_t in = A(0), n = A(1), outp = A(3), outsz = A(4);
    int16_t *o; int ch; double r; uint32_t fr = mp3_decode(MEM + in, n, &ch, &r, &o);
    if (!fr) { if (trace_audio()) fprintf(stderr, "[audio] decompress_ASI failed (%u bytes)\n", n); RET(c, 0, 6); return; }
    uint32_t sz, img = wav_image(o, fr, ch, (uint32_t)r, &sz); free(o);
    P32(outp, img); P32(outsz, sz);
    RET(c, 1, 6);
}

static const Shim mss_list[] = {
#define M(n, args) {#n "@" #args, n##_},
    M(_AIL_startup, 0) M(_AIL_shutdown, 0) M(_AIL_set_preference, 8) M(_AIL_get_preference, 4) M(_AIL_lock, 0) M(_AIL_unlock, 0)
    M(_AIL_last_error, 0) M(_AIL_ms_count, 0) M(_AIL_mem_alloc_lock, 4) M(_AIL_mem_free_lock, 4) M(_AIL_waveOutOpen, 16)
    M(_AIL_waveOutClose, 4) M(_AIL_digital_handle_release, 4) M(_AIL_digital_handle_reacquire, 4) M(_AIL_digital_master_volume, 4)
    M(_AIL_set_digital_master_volume, 8)
    M(_AIL_allocate_sample_handle, 4) M(_AIL_release_sample_handle, 4) M(_AIL_init_sample, 4) M(_AIL_set_sample_type, 12)
    M(_AIL_set_sample_address, 12) M(_AIL_set_sample_file, 12) M(_AIL_set_sample_playback_rate, 8) M(_AIL_set_sample_volume, 8)
    M(_AIL_sample_volume, 4) M(_AIL_set_sample_pan, 8) M(_AIL_sample_pan, 4) M(_AIL_set_sample_loop_count, 8)
    M(_AIL_set_sample_loop_block, 12) M(_AIL_set_sample_ms_position, 8) M(_AIL_set_sample_reverb, 16) M(_AIL_resume_sample, 4)
    M(_AIL_stop_sample, 4) M(_AIL_set_sample_user_data, 12) M(_AIL_sample_user_data, 8)
    M(_AIL_enumerate_3D_providers, 12) M(_AIL_open_3D_provider, 4) M(_AIL_close_3D_provider, 4) M(_AIL_3D_provider_attribute, 12)
    M(_AIL_set_3D_provider_preference, 12) M(_AIL_open_3D_listener, 4) M(_AIL_close_3D_listener, 4)
    M(_AIL_allocate_3D_sample_handle, 4) M(_AIL_release_3D_sample_handle, 4) M(_AIL_set_3D_sample_info, 8)
    M(_AIL_start_3D_sample, 4) M(_AIL_stop_3D_sample, 4) M(_AIL_resume_3D_sample, 4) M(_AIL_end_3D_sample, 4)
    M(_AIL_3D_sample_status, 4) M(_AIL_set_3D_sample_volume, 8) M(_AIL_set_3D_sample_playback_rate, 8)
    M(_AIL_set_3D_sample_loop_count, 8) M(_AIL_set_3D_sample_loop_block, 12) M(_AIL_set_3D_sample_offset, 8)
    M(_AIL_set_3D_sample_distances, 12) M(_AIL_set_3D_sample_obstruction, 8) M(_AIL_set_3D_sample_occlusion, 8)
    M(_AIL_3D_sample_obstruction, 4) M(_AIL_set_3D_sample_preference, 12) M(_AIL_set_3D_position, 16) M(_AIL_3D_position, 16)
    M(_AIL_set_3D_velocity_vector, 16) M(_AIL_3D_velocity, 16) M(_AIL_set_3D_orientation, 28) M(_AIL_3D_orientation, 28)
    M(_AIL_set_3D_user_data, 12) M(_AIL_3D_user_data, 8)
    M(_AIL_open_stream, 12) M(_AIL_close_stream, 4) M(_AIL_start_stream, 4) M(_AIL_pause_stream, 8) M(_AIL_stream_status, 4)
    M(_AIL_set_stream_volume, 8) M(_AIL_stream_volume, 4) M(_AIL_set_stream_pan, 8) M(_AIL_stream_pan, 4)
    M(_AIL_set_stream_playback_rate, 8) M(_AIL_set_stream_loop_count, 8) M(_AIL_set_stream_ms_position, 8)
    M(_AIL_stream_ms_position, 12) M(_AIL_set_stream_user_data, 12)
    M(_AIL_decompress_ADPCM, 12) M(_AIL_decompress_ASI, 24)
#undef M
};
const ShimTable mss_shims = {mss_list, (int)(sizeof mss_list / sizeof *mss_list)};
