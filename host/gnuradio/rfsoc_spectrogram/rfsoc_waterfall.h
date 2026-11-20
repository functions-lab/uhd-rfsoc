/* rfsoc_waterfall: gap-free GPU spectrogram of an N-channel uhd-rfsoc stream.
 *
 * A capture thread pulls sc16 samples of every channel straight from UHD's
 * rx_streamer into pinned memory (GNU Radio's gr-uhd source cannot move this
 * much data: measured ~2-11 % of a 2.5 GS/s aggregate), a GPU thread runs
 * window -> cuFFT -> power -> per-line average / peak-hold, and one spectrum
 * line per channel is handed to the caller at `line_rate` lines per second.
 * The GNU Radio block (rfsoc_spectrogram.py) wraps this C API with ctypes.
 */
#ifndef RFSOC_WATERFALL_H
#define RFSOC_WATERFALL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wf wf_t;

typedef struct {
    const char* dev_args;  /* UHD device args ("" with sim); channels=N is added if missing */
    const char* otw;       /* over-the-wire format: "sc16" (default), "sc12", "sc8" */
    int nch;               /* channels, 1..16 */
    double rate;           /* per-channel sample rate requested, Hz (served from below) */
    double center_freq;    /* RF centre, Hz */
    double gain;           /* RX gain, dB */
    int nfft;              /* FFT length, power of two, 64..65536 */
    int overlap_pct;       /* 0, 50 or 75: frame overlap (hop = nfft * (100 - overlap) / 100) */
    int window;            /* 0 Hann, 1 Blackman-Harris (4-term) */
    int bins;              /* spectrum bins per line, divides nfft */
    int detector;          /* 0 average power, 1 peak hold over the line interval */
    double line_rate;      /* spectrum lines per second and channel */
    int sim;               /* 0 device; 1 synthetic source paced to `rate`; 2 synthetic, unpaced (GPU benchmark) */
    double sim_tone_hz;    /* sim: tone offset of channel c is sim_tone_hz * (c + 1), wrapped into +-rate/2 */
    double sim_tone_dbfs;  /* sim: tone level; the noise floor is -80 dBFS per sample */
} wf_config_t;

typedef struct {
    uint64_t samples_captured;  /* per channel */
    uint64_t samples_processed; /* per channel (captured - dropped batches) */
    uint64_t batches_dropped;   /* GPU too slow: a captured batch was overwritten unprocessed */
    uint64_t overflows;         /* UHD overflow events (samples lost before the host) */
    uint64_t lines;             /* lines produced */
    uint64_t lines_dropped;     /* lines overwritten before the reader took them */
    double gpu_ms_per_batch;    /* last measured GPU time of one batch (convert + FFT + accumulate) */
    double batch_ms;            /* real-time duration of one batch (samples per batch / rate) */
    double rate;                /* actual per-channel rate, Hz */
    double center_freq;         /* actual RF centre, Hz */
} wf_stats_t;

/* NULL on failure, with a message in err. */
wf_t* wf_create(const wf_config_t* cfg, char* err, int errlen);
int wf_start(wf_t* w);          /* 0 ok, -1 error (wf_error) */
/* Wait up to timeout_ms for the next line: nch * bins floats, channel-major,
 * dB relative to a full-scale complex tone, low to high frequency
 * (centre - rate/2 .. centre + rate/2). 1 = line, 0 = timeout, -1 = error. */
int wf_read_line(wf_t* w, float* out, int timeout_ms);
int wf_set_freq(wf_t* w, double hz);
int wf_set_gain(wf_t* w, double db);
void wf_set_detector(wf_t* w, int detector);
void wf_set_line_rate(wf_t* w, double lines_per_s);
void wf_get_stats(wf_t* w, wf_stats_t* s);
const char* wf_error(wf_t* w);  /* last error of the capture / GPU threads, "" if none */
void wf_destroy(wf_t* w);       /* stops the stream and joins the threads */

#ifdef __cplusplus
}
#endif
#endif
