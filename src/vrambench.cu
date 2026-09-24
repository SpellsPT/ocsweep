// vrambench.cu — VRAM bandwidth probe for stepping a memory overclock.
//
// WHY THIS EXISTS: GDDR6 does not crash when you overclock it too far. It
// error-corrects by retrying the transfer, so past the real limit you get
// LESS effective bandwidth, not a failure. The only way to find the true
// ceiling is to measure achieved bandwidth at each step and watch for the
// point where the curve stops rising and rolls off.
//
// Streaming triad: c[i] = a[i] + q*b[i]  — purely memory-bound, so the number
// tracks memory clock almost linearly while the memory is behaving.
//
// build: build.sh does it per detected GPU architecture (nvcc -O3 -arch=sm_XY)
// usage: ./vrambench [MB_per_array] [iterations]

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>
#include <cstddef>

// ADDRESS-DEPENDENT data (idea from GpuZelenograd/memtest_vulkan): with one constant fill, a write landing at the
// WRONG address (address-bus / aliasing error) would read back "correct".
// So every element's value is a hash of its index, and every element is verified on the GPU. Values are exact
// integers < 2^16 and the arithmetic is explicitly rounded (no FMA contraction), so a + 3b is bit-exact.
__device__ __forceinline__ unsigned mix(size_t i) {
    unsigned x = (unsigned)i ^ (unsigned)(i >> 32) * 0x9E3779B9u;
    x ^= x >> 16; x *= 0x7FEB352Du; x ^= x >> 15; x *= 0x846CA68Bu; x ^= x >> 16; return x;
}
__device__ __forceinline__ float fa(size_t i) { return (float)(mix(i) & 0xFFFFu); }
__device__ __forceinline__ float fb(size_t i) { return (float)(mix(i) >> 16); }
__global__ void fill(float* a, float* b, size_t n) {
    size_t stride = (size_t)blockDim.x * gridDim.x;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride) { a[i] = fa(i); b[i] = fb(i); }
}
__global__ void triad(float* __restrict__ c, const float* __restrict__ a,
                      const float* __restrict__ b, float q, size_t n) {
    size_t stride = (size_t)blockDim.x * gridDim.x;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride)
        c[i] = __fadd_rn(a[i], __fmul_rn(q, b[i]));
}
__global__ void verify(const float* c, const float* a, const float* b, float q, size_t n, unsigned long long* bad) {
    size_t stride = (size_t)blockDim.x * gridDim.x; unsigned long long k = 0;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride) {
        float x = fa(i), y = fb(i);
        k += (a[i] != x) + (b[i] != y) + (c[i] != __fadd_rn(x, __fmul_rn(q, y)));
    }
    if (k) atomicAdd(bad, k);
}

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
    fprintf(stderr,"CUDA ERROR %s at line %d\n",cudaGetErrorString(e),__LINE__); return 2; } } while(0)

int main(int argc, char** argv) {
    size_t mb   = (argc > 1) ? (size_t)atoll(argv[1]) : 512;
    int    iters= (argc > 2) ? atoi(argv[2]) : 30;

    size_t n = mb * 1024ull * 1024ull / sizeof(float);
    float *a, *b, *c;
    CK(cudaMalloc(&a, n*sizeof(float)));
    CK(cudaMalloc(&b, n*sizeof(float)));
    CK(cudaMalloc(&c, n*sizeof(float)));
    int threads = 256;
    int blocks  = 4096;
    unsigned long long *dbad, hbad = 0;
    CK(cudaMalloc(&dbad, sizeof(unsigned long long))); CK(cudaMemset(dbad, 0, sizeof(unsigned long long)));
    fill<<<blocks,threads>>>(a, b, n);

    // warm up (also lets the card clock up out of its idle P-state)
    for (int i = 0; i < 5; i++) triad<<<blocks,threads>>>(c,a,b,3.0f,n);
    CK(cudaDeviceSynchronize());

    cudaEvent_t t0, t1;
    CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1));

    // triad moves 3 floats per element: 2 read + 1 write
    double bytes = 3.0 * sizeof(float) * (double)n;
    double best = 0.0;

    for (int r = 0; r < 5; r++) {
        CK(cudaEventRecord(t0));
        for (int i = 0; i < iters; i++) triad<<<blocks,threads>>>(c,a,b,3.0f,n);
        CK(cudaEventRecord(t1));
        CK(cudaEventSynchronize(t1));
        float ms = 0.f;
        CK(cudaEventElapsedTime(&ms, t0, t1));
        double gbs = (bytes * iters) / (ms/1000.0) / 1e9;
        if (gbs > best) best = gbs;
        verify<<<blocks,threads>>>(c, a, b, 3.0f, n, dbad);   // every element of a, b and c, after each timed round
    }
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(&hbad, dbad, sizeof hbad, cudaMemcpyDeviceToHost));

    printf("%.2f %llu\n", best, hbad);   // GB/s   mismatches (all of a, b, c, checked after each of the 5 rounds —
                                        // a bad write that a later iteration overwrites is not seen)
    cudaFree(a); cudaFree(b); cudaFree(c); cudaFree(dbad);
    return 0;
}
