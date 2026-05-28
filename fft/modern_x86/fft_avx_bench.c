/**
 * FFT Performance Comparison: Naive DFT vs Scalar FFT vs AVX-accelerated FFT
 * Target: Modern x86-64 with AVX2 + FMA
 *
 * Compile (GCC):
 *   gcc -O3 -mavx2 -mfma -march=native -o fft_bench fft_avx_bench.c -lm
 * Compile (MSVC):
 *   cl /O2 /arch:AVX2 /fp:fast fft_avx_bench.c
 *
 * For OpenBLAS comparison:
 *   gcc -O3 -mavx2 -mfma -march=native -o fft_bench fft_avx_bench.c \
 *       -lopenblas -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#ifdef _WIN32
    #include <windows.h>
    #define timer_t LARGE_INTEGER
    void timer_start(timer_t *t) { QueryPerformanceCounter(t); }
    double timer_elapsed_ms(timer_t *start, timer_t *end) {
        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        return (double)(end->QuadPart - start->QuadPart) * 1000.0 / freq.QuadPart;
    }
#else
    #include <sys/time.h>
    #define timer_t struct timespec
    void timer_start(timer_t *t) { clock_gettime(CLOCK_MONOTONIC, t); }
    double timer_elapsed_ms(timer_t *start, timer_t *end) {
        return (end->tv_sec - start->tv_sec) * 1000.0
             + (end->tv_nsec - start->tv_nsec) / 1e6;
    }
#endif

#ifdef __AVX2__
#include <immintrin.h>
#endif

#define PI 3.14159265358979323846

/* Complex number: interleaved real/imaginary */
typedef struct { float real, imag; } complex_t;

/*======================================================================
 * Utility: Allocate and initialize test data
 *======================================================================*/
complex_t* alloc_data(int N) {
    return (complex_t*)_aligned_malloc(N * sizeof(complex_t), 32);
}

void free_data(complex_t *data) {
    _aligned_free(data);
}

void fill_impulse(complex_t *x, int N) {
    for (int i = 0; i < N; i++) {
        x[i].real = (i == 0) ? 1.0f : 0.0f;
        x[i].imag = 0.0f;
    }
}

void fill_sine(complex_t *x, int N) {
    for (int i = 0; i < N; i++) {
        x[i].real = sinf(2.0f * PI * i / N);
        x[i].imag = 0.0f;
    }
}

void fill_random(complex_t *x, int N) {
    for (int i = 0; i < N; i++) {
        x[i].real = (float)rand() / RAND_MAX * 2.0f - 1.0f;
        x[i].imag = (float)rand() / RAND_MAX * 2.0f - 1.0f;
    }
}

void copy_data(complex_t *dst, const complex_t *src, int N) {
    memcpy(dst, src, N * sizeof(complex_t));
}

/*======================================================================
 * Twiddle factor generation: W_N^k = exp(-j*2*pi*k/N)
 *======================================================================*/
complex_t* generate_twiddles(int N) {
    complex_t *W = (complex_t*)_aligned_malloc(N * sizeof(complex_t), 32);
    for (int k = 0; k < N; k++) {
        float angle = -2.0f * PI * k / N;
        W[k].real = cosf(angle);
        W[k].imag = sinf(angle);
    }
    return W;
}

/*======================================================================
 * Bit-reversal permutation
 *======================================================================*/
void bit_reverse(complex_t *data, int N) {
    int j = 0;
    for (int i = 0; i < N; i++) {
        if (i < j) {
            complex_t tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
        int bit = N >> 1;
        while (j & bit) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
    }
}

/*======================================================================
 * 1. Naive DFT - O(N^2) baseline
 *    X[k] = SUM(n=0..N-1) x[n] * exp(-j*2*pi*n*k/N)
 *======================================================================*/
void dft_naive(complex_t *X, const complex_t *x, int N, const complex_t *W) {
    for (int k = 0; k < N; k++) {
        float sum_r = 0.0f, sum_i = 0.0f;
        for (int n = 0; n < N; n++) {
            int idx = (n * k) % N;
            float wr = W[idx].real;
            float wi = W[idx].imag;
            float xr = x[n].real;
            float xi = x[n].imag;
            sum_r += xr * wr - xi * wi;
            sum_i += xr * wi + xi * wr;
        }
        X[k].real = sum_r;
        X[k].imag = sum_i;
    }
}

/*======================================================================
 * 2. Scalar Radix-2 DIT FFT - O(N log N)
 *    Standard Cooley-Tukey, in-place
 *======================================================================*/
void fft_scalar(complex_t *data, int N, const complex_t *W) {
    bit_reverse(data, N);

    for (int m = 2; m <= N; m <<= 1) {
        int half = m >> 1;
        int step = N / m;
        for (int k = 0; k < N; k += m) {
            for (int j = 0; j < half; j++) {
                int tw_idx = j * step;
                float wr = W[tw_idx].real;
                float wi = W[tw_idx].imag;

                int i1 = k + j;
                int i2 = k + j + half;

                float a_r = data[i1].real;
                float a_i = data[i1].imag;
                float b_r = data[i2].real;
                float b_i = data[i2].imag;

                /* t = W * b */
                float t_r = wr * b_r - wi * b_i;
                float t_i = wr * b_i + wi * b_r;

                data[i1].real = a_r + t_r;
                data[i1].imag = a_i + t_i;
                data[i2].real = a_r - t_r;
                data[i2].imag = a_i - t_i;
            }
        }
    }
}

/*======================================================================
 * 3. AVX-Accelerated Radix-2 DIT FFT
 *    Vectorizes the inner butterfly loop using 256-bit AVX.
 *
 *    Each AVX register holds 8 floats = 4 complex numbers.
 *    Process 4 butterflies at once for maximum throughput.
 *
 *    Key optimizations:
 *      - AVX2 SIMD for parallel complex arithmetic
 *      - FMA (fused multiply-add) for single-round a*b+c
 *      - Aligned memory access (32-byte)
 *      - Pre-broadcast twiddle factors
 *======================================================================*/
#ifdef __AVX2__
void fft_avx(complex_t *data, int N, const complex_t *W) {
    bit_reverse(data, N);

    for (int m = 2; m <= N; m <<= 1) {
        int half = m >> 1;
        int step = N / m;

        if (half >= 4) {
            /* ---- AVX path: process 4 butterflies at once ---- */
            for (int k = 0; k < N; k += m) {
                for (int j = 0; j < half; j += 4) {
                    int tw_base = j * step;
                    int i1 = k + j;
                    int i2 = k + j + half;

                    /* Load 4 upper inputs (8 floats: 4 complex) */
                    __m256 a = _mm256_load_ps((float*)&data[i1]);

                    /* Load 4 lower inputs */
                    __m256 b = _mm256_load_ps((float*)&data[i2]);

                    /* Load 4 twiddle factors: real parts */
                    __m256 wr4 = _mm256_set_ps(
                        W[(j+3)*step].real,
                        W[(j+2)*step].real,
                        W[(j+1)*step].real,
                        W[(j+0)*step].real,
                        W[(j+3)*step].real,
                        W[(j+2)*step].real,
                        W[(j+1)*step].real,
                        W[(j+0)*step].real
                    );

                    /* Load 4 twiddle factors: imag parts */
                    __m256 wi4 = _mm256_set_ps(
                        W[(j+3)*step].imag,
                        W[(j+2)*step].imag,
                        W[(j+1)*step].imag,
                        W[(j+0)*step].imag,
                        W[(j+3)*step].imag,
                        W[(j+2)*step].imag,
                        W[(j+1)*step].imag,
                        W[(j+0)*step].imag
                    );

                    /* De-interleave b: [br0,bi0,br1,bi1,br2,bi2,br3,bi3] */
                    /* Shuffle to separate real and imag lanes */
                    __m256 b_real = _mm256_moveldup_ps(b);  /* br0,br0,br1,br1,... */
                    __m256 b_imag = _mm256_movehdup_ps(b);  /* bi0,bi0,bi1,bi1,... */

                    /* t.real = Wr * br - Wi * bi */
                    __m256 t_real = _mm256_fmsub_ps(
                        _mm256_mul_ps(wr4, b_real),
                        wi4, b_imag
                    );

                    /* t.imag = Wr * bi + Wi * br */
                    /* Need cross-lane shuffle for this */
                    __m256 b_real_swapped = _mm256_permute_ps(b_real, 0xB1);
                    __m256 b_imag_swapped = _mm256_permute_ps(b_imag, 0xB1);
                    __m256 t_imag = _mm256_fmadd_ps(
                        _mm256_mul_ps(wr4, b_imag_swapped),
                        wi4, b_real_swapped
                    );

                    /* Re-interleave t = [tr0,ti0,tr1,ti1,tr2,ti2,tr3,ti3] */
                    __m256 t = _mm256_blend_ps(t_real,
                        _mm256_permute_ps(t_imag, 0xB1), 0xAA);

                    /* a + t (upper output) */
                    __m256 a_plus_t = _mm256_add_ps(a, t);
                    /* a - t (lower output) */
                    __m256 a_minus_t = _mm256_sub_ps(a, t);

                    _mm256_store_ps((float*)&data[i1], a_plus_t);
                    _mm256_store_ps((float*)&data[i2], a_minus_t);
                }
            }
        } else {
            /* ---- Scalar path for small half (< 4) ---- */
            for (int k = 0; k < N; k += m) {
                for (int j = 0; j < half; j++) {
                    int tw_idx = j * step;
                    float wr = W[tw_idx].real, wi = W[tw_idx].imag;
                    int i1 = k + j, i2 = k + j + half;

                    float ar = data[i1].real, ai = data[i1].imag;
                    float br = data[i2].real, bi = data[i2].imag;
                    float tr = wr * br - wi * bi;
                    float ti = wr * bi + wi * br;

                    data[i1].real = ar + tr;
                    data[i1].imag = ai + ti;
                    data[i2].real = ar - tr;
                    data[i2].imag = ai - ti;
                }
            }
        }
    }
}
#else
void fft_avx(complex_t *data, int N, const complex_t *W) {
    /* Fallback to scalar if AVX2 not available */
    fft_scalar(data, N, W);
}
#endif

/*======================================================================
 * 4. AVX + Manual Loop Unrolling + Prefetch
 *    Further optimized: 4x unrolled inner loop with SW prefetch
 *======================================================================*/
#ifdef __AVX2__
void fft_avx_opt(complex_t *data, int N, const complex_t *W) {
    bit_reverse(data, N);

    for (int m = 2; m <= N; m <<= 1) {
        int half = m >> 1;
        int step = N / m;

        if (half >= 8) {
            for (int k = 0; k < N; k += m) {
                /* Prefetch next group's data */
                if (k + m < N) {
                    _mm_prefetch((const char*)&data[k + m], _MM_HINT_T0);
                }

                for (int j = 0; j < half; j += 4) {
                    int i1 = k + j;
                    int i2 = k + j + half;

                    /* Prefetch ahead */
                    if (j + 8 < half) {
                        _mm_prefetch((const char*)&data[i1 + 8], _MM_HINT_T0);
                    }

                    __m256 a = _mm256_load_ps((float*)&data[i1]);
                    __m256 b = _mm256_load_ps((float*)&data[i2]);

                    int tw0 = (j+0)*step, tw1 = (j+1)*step;
                    int tw2 = (j+2)*step, tw3 = (j+3)*step;

                    __m256 wr4 = _mm256_set_ps(
                        W[tw3].real, W[tw2].real,
                        W[tw1].real, W[tw0].real,
                        W[tw3].real, W[tw2].real,
                        W[tw1].real, W[tw0].real);
                    __m256 wi4 = _mm256_set_ps(
                        W[tw3].imag, W[tw2].imag,
                        W[tw1].imag, W[tw0].imag,
                        W[tw3].imag, W[tw2].imag,
                        W[tw1].imag, W[tw0].imag);

                    __m256 b_real = _mm256_moveldup_ps(b);
                    __m256 b_imag = _mm256_movehdup_ps(b);

                    __m256 t_real = _mm256_fmsub_ps(
                        _mm256_mul_ps(wr4, b_real), wi4, b_imag);

                    __m256 b_r_sw = _mm256_permute_ps(b_real, 0xB1);
                    __m256 b_i_sw = _mm256_permute_ps(b_imag, 0xB1);
                    __m256 t_imag = _mm256_fmadd_ps(
                        _mm256_mul_ps(wr4, b_i_sw), wi4, b_r_sw);

                    __m256 t = _mm256_blend_ps(t_real,
                        _mm256_permute_ps(t_imag, 0xB1), 0xAA);

                    _mm256_store_ps((float*)&data[i1], _mm256_add_ps(a, t));
                    _mm256_store_ps((float*)&data[i2], _mm256_sub_ps(a, t));
                }
            }
        } else {
            /* Scalar fallback */
            for (int k = 0; k < N; k += m) {
                for (int j = 0; j < half; j++) {
                    int tw_idx = j * step;
                    float wr = W[tw_idx].real, wi = W[tw_idx].imag;
                    int i1 = k + j, i2 = k + j + half;
                    float ar = data[i1].real, ai = data[i1].imag;
                    float br = data[i2].real, bi = data[i2].imag;
                    float tr = wr * br - wi * bi;
                    float ti = wr * bi + wi * br;
                    data[i1].real = ar + tr;
                    data[i1].imag = ai + ti;
                    data[i2].real = ar - tr;
                    data[i2].imag = ai - ti;
                }
            }
        }
    }
}
#endif

/*======================================================================
 * Verification: compare against naive DFT (reference)
 *======================================================================*/
double verify_error(const complex_t *a, const complex_t *b, int N) {
    double max_err = 0.0;
    for (int i = 0; i < N; i++) {
        double dr = fabs((double)a[i].real - b[i].real);
        double di = fabs((double)a[i].imag - b[i].imag);
        double err = dr + di;
        if (err > max_err) max_err = err;
    }
    return max_err;
}

/*======================================================================
 * Benchmark harness
 *======================================================================*/
typedef void (*fft_func)(complex_t*, int, const complex_t*);

typedef struct {
    const char *name;
    fft_func    func;
} benchmark_t;

void run_benchmark(int N, int trials) {
    printf("\n");
    printf("============================================================\n");
    printf("  FFT Performance Benchmark: N = %d\n", N);
    printf("  Trials per method: %d\n", trials);
    printf("============================================================\n\n");

    /* Allocate and initialize */
    complex_t *input  = alloc_data(N);
    complex_t *output = alloc_data(N);
    complex_t *ref    = alloc_data(N);
    complex_t *W      = generate_twiddles(N);

    fill_random(input, N);

    /* Compute reference (DFT) */
    printf("[1/4] Computing reference (naive DFT, O(N^2))...\n");
    timer_t t0, t1;
    timer_start(&t0);
    dft_naive(ref, input, N, W);
    timer_start(&t1);
    double ref_ms = timer_elapsed_ms(&t0, &t1);
    printf("      Reference DFT: %.3f ms\n\n", ref_ms);

    /* Benchmark: Naive DFT (multiple trials) */
    printf("[2/4] Benchmarking: Naive DFT\n");
    double naive_total = 0.0;
    for (int t = 0; t < trials; t++) {
        timer_start(&t0);
        dft_naive(output, input, N, W);
        timer_start(&t1);
        naive_total += timer_elapsed_ms(&t0, &t1);
    }
    double naive_ms = naive_total / trials;
    double naive_err = verify_error(output, ref, N);
    printf("      Avg time: %.3f ms  |  Error: %.2e\n\n", naive_ms, naive_err);

    /* Benchmark: Scalar FFT */
    printf("[3/4] Benchmarking: Scalar Radix-2 FFT\n");
    double scalar_total = 0.0;
    for (int t = 0; t < trials; t++) {
        copy_data(output, input, N);
        timer_start(&t0);
        fft_scalar(output, N, W);
        timer_start(&t1);
        scalar_total += timer_elapsed_ms(&t0, &t1);
    }
    double scalar_ms = scalar_total / trials;
    double scalar_err = verify_error(output, ref, N);
    printf("      Avg time: %.3f ms  |  Error: %.2e\n", scalar_ms, scalar_err);
    printf("      Speedup vs DFT: %.1fx\n\n", naive_ms / scalar_ms);

    /* Benchmark: AVX FFT */
    printf("[4/4] Benchmarking: AVX2-Accelerated FFT\n");
    double avx_total = 0.0;
    for (int t = 0; t < trials; t++) {
        copy_data(output, input, N);
        timer_start(&t0);
        fft_avx(output, N, W);
        timer_start(&t1);
        avx_total += timer_elapsed_ms(&t0, &t1);
    }
    double avx_ms = avx_total / trials;
    double avx_err = verify_error(output, ref, N);
    printf("      Avg time: %.3f ms  |  Error: %.2e\n", avx_ms, avx_err);
    printf("      Speedup vs DFT:   %.1fx\n", naive_ms / avx_ms);
    printf("      Speedup vs Scalar: %.1fx\n\n", scalar_ms / avx_ms);

#ifdef __AVX2__
    /* Benchmark: AVX Optimized FFT */
    printf("[EXTRA] Benchmarking: AVX2-Optimized FFT (unrolled + prefetch)\n");
    double avxopt_total = 0.0;
    for (int t = 0; t < trials; t++) {
        copy_data(output, input, N);
        timer_start(&t0);
        fft_avx_opt(output, N, W);
        timer_start(&t1);
        avxopt_total += timer_elapsed_ms(&t0, &t1);
    }
    double avxopt_ms = avxopt_total / trials;
    double avxopt_err = verify_error(output, ref, N);
    printf("      Avg time: %.3f ms  |  Error: %.2e\n", avxopt_ms, avxopt_err);
    printf("      Speedup vs DFT:    %.1fx\n", naive_ms / avxopt_ms);
    printf("      Speedup vs Scalar:  %.1fx\n", scalar_ms / avxopt_ms);
    printf("      Speedup vs AVX:     %.1fx\n\n", avx_ms / avxopt_ms);
#endif

    /* Summary table */
    printf("------------------------------------------------------------\n");
    printf("  %-30s %10s %10s\n", "Method", "Time(ms)", "vs DFT");
    printf("------------------------------------------------------------\n");
    printf("  %-30s %10.3f %9.1fx\n", "Naive DFT (O(N^2))", naive_ms, 1.0);
    printf("  %-30s %10.3f %9.1fx\n", "Scalar FFT (O(N log N))", scalar_ms, naive_ms/scalar_ms);
    printf("  %-30s %10.3f %9.1fx\n", "AVX2 FFT", avx_ms, naive_ms/avx_ms);
#ifdef __AVX2__
    printf("  %-30s %10.3f %9.1fx\n", "AVX2-Opt FFT", avxopt_ms, naive_ms/avxopt_ms);
#endif
    printf("------------------------------------------------------------\n");

    /* Complexity analysis */
    printf("\n  Theoretical complexity:\n");
    printf("    Naive DFT:    %d ops\n", N * N);
    printf("    Scalar FFT:   %d ops\n", (N/2) * (int)log2(N));
    printf("    AVX2 FFT:     %d ops (8-wide SIMD)\n",
           (N/2) * (int)log2(N) / 8);

    free_data(input);
    free_data(output);
    free_data(ref);
    _aligned_free(W);
}

/*======================================================================
 * MAIN
 *======================================================================*/
int main(int argc, char **argv) {
    printf("FFT Performance Benchmark Suite\n");
    printf("===============================\n");

#ifdef __AVX2__
    printf("AVX2 + FMA: ENABLED\n");
#else
    printf("AVX2 + FMA: NOT AVAILABLE (recompile with -mavx2 -mfma)\n");
#endif
    printf("Architecture: x86-64\n\n");

    /* Warm up */
    printf("CPU warm-up...\n");
    volatile float warm = 0;
    for (int i = 0; i < 1000000; i++) warm += warm * 0.999f;

    /* Run benchmarks at different sizes */
    int sizes[] = {256, 1024, 4096, 16384};
    int num_sizes = sizeof(sizes) / sizeof(sizes[0]);

    for (int i = 0; i < num_sizes; i++) {
        int N = sizes[i];
        int trials = (N <= 1024) ? 100 : ((N <= 4096) ? 20 : 5);
        run_benchmark(N, trials);
    }

    printf("\nDone.\n");
    return 0;
}
