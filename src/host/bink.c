// Bink video (binkw32.dll): the 13 calls lithtech's BinkVideoMgr looks up with GetProcAddress
// (decompiled in m1/decomp/lt_bink.c, lt_bink2.c), backed by the ffmpeg command-line tool in child
// processes: video frames come back as raw BGRA over one pipe, the soundtrack as 16-bit PCM over a
// second pipe into audio.c. Nothing from FFmpeg is linked into the host (Homebrew's build is GPL).
// Without an ffmpeg binary, or with M1_NOMOVIES=1, LoadLibrary("Binkw32.dll") fails as before and the
// engine skips its movies ("Unable to find Binkw32.dll, video playback disabled").
//
// How the engine plays a movie on screen: BinkOpen, then a DDraw surface of Width x Height; per game
// frame BinkWait (0 = time for the next frame) -> Lock the surface -> BinkDoFrame -> BinkCopyToBuffer
// (32-bit, 555 or 565) -> Unlock -> BltFast/Blt to the back buffer -> BinkNextFrame. It treats the
// movie as finished when FrameNum == Frames - 1. Only Width, Height, Frames and FrameNum are read from
// the BINK structure.
// Env: M1_FFMPEG=<path> (default: /opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg), M1_NOMOVIES=1.
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "shims.h"

extern char **environ;
int audio_pipe_start(int fd, int channels, double rate);
int audio_pipe_ready(int id);
void audio_pipe_play(int id);
void audio_pipe_stop(int id);

static const char *ffmpeg_path(void) {
    static int init; static const char *p;
    if (!init) {
        init = 1;
        if (getenv("M1_NOMOVIES")) return NULL;
        const char *c[] = {getenv("M1_FFMPEG"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"};
        for (int i = 0; i < 3 && !p; i++) if (c[i] && !access(c[i], X_OK)) p = c[i];
        fprintf(stderr, "[bink] %s\n", p ? p : "no ffmpeg: movies off");
    }
    return p;
}
int bink_available(void) { return ffmpeg_path() != NULL; }

// BINK (Bink 1.x layout; the engine reads the first four fields)
enum { B_WIDTH = 0, B_HEIGHT = 4, B_FRAMES = 8, B_FRAMENUM = 12, B_LASTFRAMENUM = 16, B_FRAMERATE = 20, B_FRAMERATEDIV = 24,
       B_OPENFLAGS = 32, B_SIZE = 0x200 };
typedef struct {
    uint32_t g;                  // guest BINK
    char path[1024];
    uint32_t w, h, frames, num, den;
    pid_t vpid, apid;
    int vfd, audio;
    uint8_t *cur; uint32_t have; // decoded frame `have` (1-based; 0: none yet)
    uint64_t t0;                 // when frame 1 was shown (ns)
} Movie;
#define MAXM 8
static Movie mv[MAXM];
static int sound_track = 0;      // BinkSetSoundTrack(-1) with BINKSNDTRACK: no sound

static Movie *mov(uint32_t g) { for (int i = 0; i < MAXM; i++) if (mv[i].g && mv[i].g == g) return &mv[i]; return NULL; }
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static pid_t spawn_pipe(const char *const argv[], int *rfd) {
    int p[2]; if (pipe(p)) return -1;
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, p[1], 1);
    posix_spawn_file_actions_addclose(&fa, p[0]); posix_spawn_file_actions_addclose(&fa, p[1]);
    pid_t pid = -1;
    int e = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(p[1]);
    if (e) { close(p[0]); return -1; }
    *rfd = p[0];
    return pid;
}
static void reap(pid_t *pid, int *fd) {
    if (*pid > 0) { kill(*pid, SIGKILL); if (fd && *fd >= 0) { close(*fd); *fd = -1; } waitpid(*pid, NULL, 0); *pid = -1; }
    else if (fd && *fd >= 0) { close(*fd); *fd = -1; }
}
static int start_video(Movie *m) {
    const char *av[] = {ffmpeg_path(), "-nostdin", "-v", "error", "-i", m->path, "-map", "0:v:0", "-fps_mode", "passthrough",
                        "-f", "rawvideo", "-pix_fmt", "bgra", "-", NULL};
    m->vpid = spawn_pipe(av, &m->vfd); m->have = 0;
    return m->vpid > 0;
}
static int read_full(int fd, uint8_t *p, size_t n) {
    size_t got = 0;
    while (got < n) { ssize_t r = read(fd, p + got, n - got); if (r <= 0) return 0; got += (size_t)r; }
    return 1;
}

SHIM(_BinkSetSoundSystem) { RET(c, 1, 2); }                 // sound goes through audio.c whichever system is chosen
SHIM(_BinkOpenMiles) { RET(c, 0x7E0B0001u, 1); }              // BINKSNDOPEN tokens: passed back to SetSoundSystem only
SHIM(_BinkOpenDirectSound) { RET(c, 0x7E0B0002u, 1); }
SHIM(_BinkSetSoundTrack) { sound_track = (int)ARG(c, 0); RET(c, 0, 1); }
SHIM(_BinkOpen) {
    const char *name = GSTR(ARG(c, 0)); uint32_t flags = ARG(c, 1);
    Movie *m = NULL; for (int i = 0; i < MAXM && !m; i++) if (!mv[i].g) m = &mv[i];
    char path[1024]; host_path(name ? name : "", path, sizeof path);
    uint8_t hd[44] = {0};
    FILE *f = fopen(path, "rb"); size_t n = f ? fread(hd, 1, sizeof hd, f) : 0; if (f) fclose(f);
    uint32_t v[11]; memcpy(v, hd, sizeof v);
    if (!m || n < sizeof hd || (memcmp(hd, "BIK", 3) && memcmp(hd, "KB2", 3)) || !v[2] || !v[5] || !v[6] || !v[7] || !v[8]) {
        fprintf(stderr, "[bink] BinkOpen(%s): %s\n", name ? name : "", !m ? "too many movies" : n ? "not a Bink file" : "not found");
        RET(c, 0, 2); return;
    }
    memset(m, 0, sizeof *m);
    snprintf(m->path, sizeof m->path, "%s", path);
    m->frames = v[2]; m->w = v[5]; m->h = v[6]; m->num = v[7]; m->den = v[8] ? v[8] : 1;
    m->vfd = -1; m->audio = -1; m->vpid = m->apid = -1;
    m->cur = calloc((size_t)m->w * m->h, 4);
    if (!start_video(m)) { fprintf(stderr, "[bink] cannot run ffmpeg\n"); free(m->cur); RET(c, 0, 2); return; }
    int tracks = (int)v[10];
    if (tracks > 0 && !((flags & 0x4000) && sound_track < 0)) {
        int afd = -1;
        const char *av[] = {ffmpeg_path(), "-nostdin", "-v", "error", "-i", m->path, "-map", "0:a:0", "-f", "s16le", "-ac", "2", "-ar", "44100", "-", NULL};
        m->apid = spawn_pipe(av, &afd);
        if (m->apid > 0) { m->audio = audio_pipe_start(afd, 2, 44100.0); if (m->audio < 0) reap(&m->apid, &afd); }
    }
    m->g = gmalloc(B_SIZE); memset(MEM + m->g, 0, B_SIZE);
    P32(m->g + B_WIDTH, m->w); P32(m->g + B_HEIGHT, m->h); P32(m->g + B_FRAMES, m->frames); P32(m->g + B_FRAMENUM, 1);
    P32(m->g + B_FRAMERATE, m->num); P32(m->g + B_FRAMERATEDIV, m->den); P32(m->g + B_OPENFLAGS, flags);
    fprintf(stderr, "[bink] BinkOpen(%s) %ux%u, %u frames at %.2f fps, %s\n", name, m->w, m->h, m->frames, (double)m->num / m->den,
            m->audio >= 0 ? "sound" : "no sound");
    RET(c, m->g, 2);
}
SHIM(_BinkClose) {
    Movie *m = mov(ARG(c, 0));
    if (m) {
        fprintf(stderr, "[bink] BinkClose at frame %u of %u\n", G32(m->g + B_FRAMENUM), m->frames);
        reap(&m->vpid, &m->vfd);
        reap(&m->apid, NULL);            // the audio pipe's read end belongs to audio.c's reader thread
        audio_pipe_stop(m->audio);
        free(m->cur); gfree(m->g); memset(m, 0, sizeof *m);
    }
    RET(c, 0, 1);
}
// 0: show the next frame now; 1: not yet. Frame k is due (k - 1) / fps after frame 1 was shown.
SHIM(_BinkWait) {
    Movie *m = mov(ARG(c, 0)); uint32_t r = 0;
    if (m && m->t0) {
        uint64_t k = G32(m->g + B_FRAMENUM);
        uint64_t due = m->t0 + (k - 1) * 1000000000ull * m->den / m->num;
        r = now_ns() < due;
    }
    RET(c, r, 1);
}
SHIM(_BinkDoFrame) {
    Movie *m = mov(ARG(c, 0));
    if (m) {
        uint32_t k = G32(m->g + B_FRAMENUM);
        if (k < m->have) { reap(&m->vpid, &m->vfd); start_video(m); }       // went back (loop): decode from the start
        while (m->have < k && m->vfd >= 0) {
            if (!read_full(m->vfd, m->cur, (size_t)m->w * m->h * 4)) { reap(&m->vpid, &m->vfd); break; }
            m->have++;
        }
        if (!m->t0) {          // start the soundtrack with frame 1 once its first second is decoded (at most 0.5 s wait)
            for (int i = 0; i < 250 && m->audio >= 0 && !audio_pipe_ready(m->audio); i++) usleep(2000);
            m->t0 = now_ns(); audio_pipe_play(m->audio);
        }
    }
    RET(c, 0, 1);
}
SHIM(_BinkNextFrame) {
    Movie *m = mov(ARG(c, 0));
    if (m) {
        uint32_t k = G32(m->g + B_FRAMENUM);
        P32(m->g + B_LASTFRAMENUM, k);
        P32(m->g + B_FRAMENUM, k >= m->frames ? 1 : k + 1);
    }
    RET(c, 0, 1);
}
// flags & 15: BINKSURFACE32 3 (B,G,R,x bytes), 32R 4, 555 9, 565 10
SHIM(_BinkCopyToBuffer) {
    Movie *m = mov(ARG(c, 0)); uint32_t dest = ARG(c, 1), pitch = ARG(c, 2), dh = ARG(c, 3), dx = ARG(c, 4), dy = ARG(c, 5), fl = ARG(c, 6) & 15;
    if (m && dest) {
        uint32_t h = m->h < dh ? m->h : dh;
        for (uint32_t y = 0; y < h; y++) {
            const uint8_t *in = m->cur + (size_t)y * m->w * 4;
            uint8_t *o = MEM + dest + (dy + y) * pitch;
            if (fl == 3) memcpy(o + dx * 4, in, (size_t)m->w * 4);
            else if (fl == 4) for (uint32_t x = 0; x < m->w; x++) { uint8_t *q = o + (dx + x) * 4; q[0] = in[4 * x + 2]; q[1] = in[4 * x + 1]; q[2] = in[4 * x]; q[3] = 255; }
            else if (fl == 9 || fl == 10) {
                uint16_t *q = (uint16_t *)(o + dx * 2);
                for (uint32_t x = 0; x < m->w; x++) {
                    uint32_t b = in[4 * x], g = in[4 * x + 1], r = in[4 * x + 2];
                    q[x] = fl == 10 ? (uint16_t)((r >> 3) << 11 | (g >> 2) << 5 | b >> 3) : (uint16_t)((r >> 3) << 10 | (g >> 3) << 5 | b >> 3);
                }
            } else { static int w; if (w++ < 3) fprintf(stderr, "[bink] BinkCopyToBuffer surface type %u not supported\n", fl); break; }
        }
    }
    RET(c, 0, 7);
}
SHIM(_BinkIsSoftwareCursor) { RET(c, 0, 2); }        // the game draws its own cursor
SHIM(_BinkCheckCursor) { RET(c, 0, 5); }
SHIM(_BinkRestoreCursor) { RET(c, 0, 1); }

#define M(n, args) {#n "@" #args, n##_},
static const Shim bink_list[] = {
    M(_BinkSetSoundSystem, 8) M(_BinkOpenMiles, 4) M(_BinkOpenDirectSound, 4) M(_BinkSetSoundTrack, 4) M(_BinkOpen, 8)
    M(_BinkClose, 4) M(_BinkWait, 4) M(_BinkCopyToBuffer, 28) M(_BinkDoFrame, 4) M(_BinkNextFrame, 4)
    M(_BinkIsSoftwareCursor, 8) M(_BinkCheckCursor, 20) M(_BinkRestoreCursor, 4)
};
#undef M
const ShimTable bink_shims = {bink_list, (int)(sizeof bink_list / sizeof *bink_list)};
