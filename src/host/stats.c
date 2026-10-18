// Frame timing for the M1 gate. A frame ends at Flip. Once the world is on screen (draws per frame
// above M1_MIN_DRAWS for 3 seconds) the next M1_SECS seconds (default 30) are measured: frames, wall
// time, main-thread CPU time and whole-process CPU time. Then the summary is printed and the host exits.
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
#include <string.h>
#include "host.h"

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t thread_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static uint64_t proc_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID); }

static uint64_t t_start, sec_t0, sec_frames, sec_draws0, sec_verts0, sec_cpu0, frames;
static int good_secs, measuring, done;
static uint64_t m_t0, m_cpu0, m_pcpu0, m_frames0, m_draws0, m_verts0, m_scenes0;
static double worst_ms; static uint64_t last_frame_t;
static uint64_t fr_draws0, dmin = ~0ull, dmax;
static uint64_t hist[8];   // frame-time histogram: <5, <10, <16.7, <33, <50, <100, <250, >=250 ms

static void summary(const char *why) {
    if (!measuring || done) return;
    done = 1;
    uint64_t t = now_ns(), cpu = thread_cpu_ns(), pcpu = proc_cpu_ns();
    double secs = (t - m_t0) / 1e9;
    uint64_t f = frames - m_frames0;
    double ms_wall = f ? (t - m_t0) / 1e6 / (double)f : 0, ms_cpu = f ? (cpu - m_cpu0) / 1e6 / (double)f : 0;
    fprintf(stderr, "\n[m1] ===== M1 headless gate (%s) =====\n", why);
    fprintf(stderr, "[m1] window %.1f s, %llu frames, %.1f fps\n", secs, (unsigned long long)f, f / secs);
    fprintf(stderr, "[m1] wall ms/frame %.2f, main-thread CPU ms/frame %.2f (main thread busy %.0f%%), process CPU %.0f%% of one core\n",
            ms_wall, ms_cpu, 100.0 * (cpu - m_cpu0) / (double)(t - m_t0), 100.0 * (pcpu - m_pcpu0) / (double)(t - m_t0));
    fprintf(stderr, "[m1] per frame: %.0f draws, %.0f vertices, %.2f scenes; worst frame %.1f ms\n",
            f ? (double)(st_draws - m_draws0) / f : 0, f ? (double)(st_verts - m_verts0) / f : 0, f ? (double)(st_scenes - m_scenes0) / f : 0, worst_ms);
    fprintf(stderr, "[m1] draws per frame: min %llu, max %llu\n", (unsigned long long)dmin, (unsigned long long)dmax);
    fprintf(stderr, "[m1] frame-time histogram (ms) <5:%llu <10:%llu <16.7:%llu <33:%llu <50:%llu <100:%llu <250:%llu >=250:%llu\n",
            (unsigned long long)hist[0], (unsigned long long)hist[1], (unsigned long long)hist[2], (unsigned long long)hist[3],
            (unsigned long long)hist[4], (unsigned long long)hist[5], (unsigned long long)hist[6], (unsigned long long)hist[7]);
    fflush(stderr);
}
uint64_t host_frames(void) { return frames; }
void stats_exit(void) { summary("guest exited"); }

void stats_frame(void) {
    uint64_t t = now_ns();
    if (!t_start) { t_start = t; sec_t0 = t; sec_cpu0 = thread_cpu_ns(); last_frame_t = t; }
    frames++; sec_frames++;
    static long trace_at = -2, trace_n;
    if (trace_at == -2) { const char *e = getenv("M1_TRACE_AT"); trace_at = e ? atol(e) : -1; trace_n = e && strchr(e, ',') ? atol(strchr(e, ',') + 1) : 3000; }
    if (trace_at >= 0 && (long)frames == trace_at) { extern volatile int host_trace_lines; host_trace_lines = (int)trace_n; fprintf(stderr, "[imp] trace window starts at frame %ld\n", trace_at); }
    if (measuring && !done) {
        double ms = (t - last_frame_t) / 1e6;
        if (ms > worst_ms) worst_ms = ms;
        int b = ms < 5 ? 0 : ms < 10 ? 1 : ms < 16.7 ? 2 : ms < 33 ? 3 : ms < 50 ? 4 : ms < 100 ? 5 : ms < 250 ? 6 : 7;
        hist[b]++;
        uint64_t d = st_draws - fr_draws0;
        if (d < dmin) dmin = d;
        if (d > dmax) dmax = d;
    }
    fr_draws0 = st_draws;
    last_frame_t = t;
    if (t - sec_t0 >= 1000000000ull) {
        uint64_t cpu = thread_cpu_ns();
        double el = (t - sec_t0) / 1e9;
        double dpf = sec_frames ? (double)(st_draws - sec_draws0) / sec_frames : 0;
        if (!getenv("M1_QUIET_SEC"))
            fprintf(stderr, "[m1] t=%5.1fs %5.1f fps  %6.2f ms/frame  main CPU %6.2f ms/frame  %5.0f draws/frame  %6.0f verts/frame%s\n",
                    (t - t_start) / 1e9, sec_frames / el, el * 1000 / sec_frames, (cpu - sec_cpu0) / 1e6 / sec_frames, dpf,
                    sec_frames ? (double)(st_verts - sec_verts0) / sec_frames : 0, measuring && !done ? "  [measuring]" : "");
        int min_draws = getenv("M1_MIN_DRAWS") ? atoi(getenv("M1_MIN_DRAWS")) : 200;
        if (!measuring) {
            good_secs = dpf >= min_draws ? good_secs + 1 : 0;
            if (good_secs >= 3) {
                measuring = 1; m_t0 = t; m_cpu0 = cpu; m_pcpu0 = proc_cpu_ns(); m_frames0 = frames;
                m_draws0 = st_draws; m_verts0 = st_verts; m_scenes0 = st_scenes;
                fprintf(stderr, "[m1] world on screen: measuring\n");
            }
        } else if (!done) {
            double secs = getenv("M1_SECS") ? atof(getenv("M1_SECS")) : 30;
            if ((t - m_t0) / 1e9 >= secs) {
                summary("measurement window complete");
                if (!getenv("M1_NO_EXIT")) exit(0);
            }
        }
        { extern void audio_report(void); audio_report(); }
        sec_t0 = t; sec_frames = 0; sec_draws0 = st_draws; sec_verts0 = st_verts; sec_cpu0 = cpu;
    }
}
