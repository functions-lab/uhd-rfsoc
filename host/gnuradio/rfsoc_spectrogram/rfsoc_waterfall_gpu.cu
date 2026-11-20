// GPU pipeline of rfsoc_waterfall: sc16 -> window -> cuFFT -> |X|^2 -> sum / max
// per bin over the frames of a line -> dB, fftshifted and reduced to `bins`.
//
// Scaling: the window is divided by its sum and the samples by 32768, so a
// full-scale complex tone is 1.0 in its bin, i.e. 0 dBFS.
#include "rfsoc_waterfall_gpu.cuh"

#include <cuda_runtime.h>
#include <cufft.h>

#include <cmath>
#include <cstdio>
#include <vector>

struct GpuPipe {
    int nch, nfft, hop, F, bins;
    size_t S;  // samples per channel per slot
    int16_t* d_in[2] = {nullptr, nullptr};
    float2* d_x = nullptr;
    float *d_win = nullptr, *d_sum = nullptr, *d_max = nullptr, *d_line = nullptr;
    float* h_line = nullptr;
    cufftHandle plan = 0;
    bool have_plan = false;
    cudaStream_t sc = nullptr, scopy = nullptr;
    cudaEvent_t copied[2] = {nullptr, nullptr}, done[2] = {nullptr, nullptr};
    cudaEvent_t t0[2] = {nullptr, nullptr}, t1[2] = {nullptr, nullptr};
    bool timed[2] = {false, false};
    double last_ms = 0;
    unsigned long k = 0;
};

#define CK(call)                                                                       \
    do {                                                                               \
        cudaError_t e_ = (call);                                                       \
        if (e_ != cudaSuccess) {                                                       \
            snprintf(err, errlen, "%s: %s", #call, cudaGetErrorString(e_));            \
            return -1;                                                                 \
        }                                                                              \
    } while (0)

__global__ void k_convert(const int32_t* __restrict__ in, float2* __restrict__ x,
                          const float* __restrict__ win, int nfft, int hop, int F,
                          size_t S) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nfft) return;
    int f = blockIdx.y, c = blockIdx.z;
    int32_t v = in[(size_t)c * S + (size_t)f * hop + i];  // I (LE low half), Q (high half)
    float w = win[i];
    x[((size_t)c * F + f) * nfft + i] =
        make_float2((float)(int16_t)(v & 0xffff) * w, (float)(int16_t)(v >> 16) * w);
}

__global__ void k_accum(const float2* __restrict__ x, float* __restrict__ sum,
                        float* __restrict__ mx, int nfft, int F) {
    int b = blockIdx.x * blockDim.x + threadIdx.x;
    if (b >= nfft) return;
    int c = blockIdx.y;
    const float2* p = x + (size_t)c * F * nfft + b;
    float s = 0.f, m = 0.f;
    for (int f = 0; f < F; ++f) {
        float2 v = p[(size_t)f * nfft];
        float pw = v.x * v.x + v.y * v.y;
        s += pw;
        m = fmaxf(m, pw);
    }
    sum[(size_t)c * nfft + b] += s;
    mx[(size_t)c * nfft + b] = fmaxf(mx[(size_t)c * nfft + b], m);
}

__global__ void k_line(const float* __restrict__ sum, const float* __restrict__ mx,
                       float* __restrict__ line, int nfft, int bins, int frames,
                       int detector) {
    int o = blockIdx.x * blockDim.x + threadIdx.x;
    if (o >= bins) return;
    int c = blockIdx.y, G = nfft / bins;
    float acc = 0.f;
    for (int g = 0; g < G; ++g) {
        int j = (o * G + g + nfft / 2) % nfft;  // fftshift: output 0 = -fs/2
        size_t idx = (size_t)c * nfft + j;
        if (detector) acc = fmaxf(acc, mx[idx]);
        else acc += sum[idx] / (float)frames;
    }
    if (!detector) acc /= (float)G;
    line[(size_t)c * bins + o] = 10.f * log10f(fmaxf(acc, 1e-20f));
}

GpuPipe* gpu_create(int nch, int nfft, int hop, int frames, int bins, int window,
                    char* err, int errlen) {
    GpuPipe* g = new GpuPipe();
    g->nch = nch; g->nfft = nfft; g->hop = hop; g->F = frames; g->bins = bins;
    g->S = (size_t)(frames - 1) * hop + nfft;
    auto fail = [&](const char* what, cudaError_t e) {
        snprintf(err, errlen, "%s: %s", what, cudaGetErrorString(e));
        gpu_destroy(g);
        return (GpuPipe*)nullptr;
    };
    cudaError_t e;
    cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);  // sleep, not spin, in the waits left
    if ((e = cudaSetDevice(0)) != cudaSuccess) return fail("cudaSetDevice", e);
    size_t in_bytes = (size_t)nch * g->S * 4;
    size_t nx = (size_t)nch * frames * nfft;
    for (int b = 0; b < 2; ++b)
        if ((e = cudaMalloc(&g->d_in[b], in_bytes)) != cudaSuccess) return fail("cudaMalloc in", e);
    if ((e = cudaMalloc(&g->d_x, nx * sizeof(float2))) != cudaSuccess) return fail("cudaMalloc x", e);
    if ((e = cudaMalloc(&g->d_win, nfft * sizeof(float))) != cudaSuccess) return fail("cudaMalloc win", e);
    size_t nacc = (size_t)nch * nfft;
    if ((e = cudaMalloc(&g->d_sum, nacc * 4)) != cudaSuccess) return fail("cudaMalloc sum", e);
    if ((e = cudaMalloc(&g->d_max, nacc * 4)) != cudaSuccess) return fail("cudaMalloc max", e);
    if ((e = cudaMalloc(&g->d_line, (size_t)nch * bins * 4)) != cudaSuccess) return fail("cudaMalloc line", e);
    if ((e = cudaMallocHost(&g->h_line, (size_t)nch * bins * 4)) != cudaSuccess) return fail("cudaMallocHost", e);
    cudaMemset(g->d_sum, 0, nacc * 4);
    cudaMemset(g->d_max, 0, nacc * 4);

    std::vector<float> w(nfft);
    double sw = 0;
    const double a[4] = {0.35875, 0.48829, 0.14128, 0.01168};
    for (int n = 0; n < nfft; ++n) {
        double ph = 2.0 * M_PI * n / nfft, v;
        if (window == 0) v = 0.5 - 0.5 * cos(ph);
        else v = a[0] - a[1] * cos(ph) + a[2] * cos(2 * ph) - a[3] * cos(3 * ph);
        w[n] = (float)v;
        sw += v;
    }
    for (int n = 0; n < nfft; ++n) w[n] = (float)(w[n] / sw / 32768.0);
    cudaMemcpy(g->d_win, w.data(), nfft * sizeof(float), cudaMemcpyHostToDevice);

    if ((e = cudaStreamCreateWithFlags(&g->sc, cudaStreamNonBlocking)) != cudaSuccess) return fail("stream", e);
    if ((e = cudaStreamCreateWithFlags(&g->scopy, cudaStreamNonBlocking)) != cudaSuccess) return fail("stream", e);
    for (int b = 0; b < 2; ++b) {
        cudaEventCreateWithFlags(&g->copied[b], cudaEventDisableTiming);
        cudaEventCreateWithFlags(&g->done[b], cudaEventDisableTiming);
        cudaEventCreate(&g->t0[b]);
        cudaEventCreate(&g->t1[b]);
    }
    int n = nfft;
    cufftResult r = cufftPlanMany(&g->plan, 1, &n, nullptr, 1, nfft, nullptr, 1, nfft,
                                  CUFFT_C2C, nch * frames);
    if (r != CUFFT_SUCCESS) {
        snprintf(err, errlen, "cufftPlanMany failed (%d)", (int)r);
        gpu_destroy(g);
        return nullptr;
    }
    g->have_plan = true;
    cufftSetStream(g->plan, g->sc);
    return g;
}

void gpu_destroy(GpuPipe* g) {
    if (!g) return;
    if (g->sc) cudaStreamSynchronize(g->sc);
    if (g->have_plan) cufftDestroy(g->plan);
    for (int b = 0; b < 2; ++b) {
        if (g->d_in[b]) cudaFree(g->d_in[b]);
        if (g->copied[b]) cudaEventDestroy(g->copied[b]);
        if (g->done[b]) cudaEventDestroy(g->done[b]);
        if (g->t0[b]) cudaEventDestroy(g->t0[b]);
        if (g->t1[b]) cudaEventDestroy(g->t1[b]);
    }
    cudaFree(g->d_x); cudaFree(g->d_win); cudaFree(g->d_sum); cudaFree(g->d_max);
    cudaFree(g->d_line);
    if (g->h_line) cudaFreeHost(g->h_line);
    if (g->sc) cudaStreamDestroy(g->sc);
    if (g->scopy) cudaStreamDestroy(g->scopy);
    delete g;
}

void* gpu_alloc_pinned(size_t bytes) {
    void* p = nullptr;
    return cudaMallocHost(&p, bytes) == cudaSuccess ? p : nullptr;
}
void gpu_free_pinned(void* p) { if (p) cudaFreeHost(p); }

int gpu_process(GpuPipe* g, const int16_t* slot, int* buf, char* err, int errlen) {
    int b = (int)(g->k & 1);
    *buf = b;
    // the batch two back must have finished reading d_in[b]
    CK(cudaStreamWaitEvent(g->scopy, g->done[b], 0));
    CK(cudaMemcpyAsync(g->d_in[b], slot, (size_t)g->nch * g->S * 4, cudaMemcpyHostToDevice, g->scopy));
    CK(cudaEventRecord(g->copied[b], g->scopy));
    CK(cudaStreamWaitEvent(g->sc, g->copied[b], 0));

    // timing of the previous batch, if finished (no host stall)
    int pb = b ^ 1;
    if (g->timed[pb] && cudaEventQuery(g->t1[pb]) == cudaSuccess) {
        float ms = 0;
        if (cudaEventElapsedTime(&ms, g->t0[pb], g->t1[pb]) == cudaSuccess) g->last_ms = ms;
        g->timed[pb] = false;
    }
    CK(cudaEventRecord(g->t0[b], g->sc));
    dim3 blk(256);
    dim3 grid1((g->nfft + 255) / 256, g->F, g->nch);
    k_convert<<<grid1, blk, 0, g->sc>>>((const int32_t*)g->d_in[b], g->d_x, g->d_win,
                                        g->nfft, g->hop, g->F, g->S);
    CK(cudaGetLastError());
    cufftResult r = cufftExecC2C(g->plan, (cufftComplex*)g->d_x, (cufftComplex*)g->d_x, CUFFT_FORWARD);
    if (r != CUFFT_SUCCESS) { snprintf(err, errlen, "cufftExecC2C failed (%d)", (int)r); return -1; }
    dim3 grid2((g->nfft + 255) / 256, g->nch);
    k_accum<<<grid2, blk, 0, g->sc>>>(g->d_x, g->d_sum, g->d_max, g->nfft, g->F);
    CK(cudaGetLastError());
    CK(cudaEventRecord(g->t1[b], g->sc));
    g->timed[b] = true;
    CK(cudaEventRecord(g->done[b], g->sc));
    g->k++;
    return 0;
}

int gpu_copy_done(GpuPipe* g, int b, int block) {
    if (block) return cudaEventSynchronize(g->copied[b]) == cudaSuccess;
    return cudaEventQuery(g->copied[b]) == cudaSuccess;
}

int gpu_line(GpuPipe* g, int detector, int frames, float* out, char* err, int errlen) {
    if (frames < 1) frames = 1;
    dim3 blk(256), grid((g->bins + 255) / 256, g->nch);
    k_line<<<grid, blk, 0, g->sc>>>(g->d_sum, g->d_max, g->d_line, g->nfft, g->bins, frames, detector);
    CK(cudaGetLastError());
    CK(cudaMemcpyAsync(g->h_line, g->d_line, (size_t)g->nch * g->bins * 4, cudaMemcpyDeviceToHost, g->sc));
    size_t nacc = (size_t)g->nch * g->nfft * 4;
    CK(cudaMemsetAsync(g->d_sum, 0, nacc, g->sc));
    CK(cudaMemsetAsync(g->d_max, 0, nacc, g->sc));
    CK(cudaStreamSynchronize(g->sc));
    for (size_t i = 0; i < (size_t)g->nch * g->bins; ++i) out[i] = g->h_line[i];
    return 0;
}

double gpu_last_batch_ms(GpuPipe* g) { return g->last_ms; }
