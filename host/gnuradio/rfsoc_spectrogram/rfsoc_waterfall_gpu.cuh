/* The GPU half of rfsoc_waterfall, behind a CUDA-free interface so the UHD
 * half (rfsoc_waterfall.cpp) is compiled by the host compiler alone. */
#ifndef RFSOC_WATERFALL_GPU_CUH
#define RFSOC_WATERFALL_GPU_CUH

#include <stddef.h>
#include <stdint.h>

struct GpuPipe;

/* nch channels; a slot holds slot_samples sc16 samples per channel,
 * (frames - 1) * hop + nfft of them; a frame f of a channel starts at
 * sample f * hop. Returns NULL and fills err on failure. */
GpuPipe* gpu_create(int nch, int nfft, int hop, int frames, int bins, int window,
                    char* err, int errlen);
void gpu_destroy(GpuPipe* g);

/* Pinned host memory for slots (and for the caller's synthetic sources). */
void* gpu_alloc_pinned(size_t bytes);
void gpu_free_pinned(void* p);

/* Enqueue the window, FFT and accumulate of the frames of one slot
 * ([nch][slot_samples] sc16, pinned); nothing blocks the host. *buf names the
 * copy: the slot may be reused once gpu_copy_done(g, *buf, ...) says so.
 * 0 ok, -1 error. */
int gpu_process(GpuPipe* g, const int16_t* slot, int* buf, char* err, int errlen);

/* Has the slot's copy to the GPU finished? block != 0 waits for it. */
int gpu_copy_done(GpuPipe* g, int buf, int block);

/* Finish the accumulated frames into one line (nch * bins dB), reset the
 * accumulators; `frames` = frames accumulated since the last line. */
int gpu_line(GpuPipe* g, int detector, int frames, float* out, char* err, int errlen);

/* GPU milliseconds of the most recent completed batch (0 until one finished). */
double gpu_last_batch_ms(GpuPipe* g);

#endif
