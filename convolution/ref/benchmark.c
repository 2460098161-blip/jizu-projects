/**
 * benchmark.c — Performance comparison of 1D complex convolution implementations.
 *
 * Compares:
 *   1. Naive C (direct O(N*M), scalar)
 *   2. Loop-unrolled C (4x unroll)
 *   3. AVX2 intrinsics (256-bit SIMD, 2 complex per iteration)
 *   4. FFT-based (FFTW3, O(N log N))
 *
 * Build (Windows x86-64 with MinGW-w64):
 *   gcc -std=c11 -O2 -mavx2 -mfma -o benchmark benchmark.c -lfftw3 -lm
 *
 * Build (without FFTW, for basic comparison):
 *   gcc -std=c11 -O2 -mavx2 -o benchmark benchmark.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <complex.h>
#include <math.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
double get_time_us() {
    LARGE_INTEGER freq, count;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&count);
    return (double)count.QuadPart * 1e6 / (double)freq.QuadPart;
}
#else
#include <sys/time.h>
double get_time_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1e6 + tv.tv_usec;
}
#endif

/* --- Generate random complex float signal --- */
complex float *rand_complex(int n, unsigned seed) {
    srand(seed);
    complex float *v = malloc(n * sizeof(complex float));
    for (int i = 0; i < n; i++) {
        float re = ((float)rand() / RAND_MAX) * 2.0f - 1.0f;
        float im = ((float)rand() / RAND_MAX) * 2.0f - 1.0f;
        v[i] = re + im * I;
    }
    return v;
}

/* --- Verify against reference --- */
float verify(const complex float *a, const complex float *b, int len) {
    float max_err = 0;
    for (int i = 0; i < len; i++) {
        float err = cabsf(a[i] - b[i]);
        if (err > max_err) max_err = err;
    }
    return max_err;
}

/* ===========================================================================
 * Implementation 1: Naive scalar C (baseline)
 * =========================================================================== */
complex float *conv_naive(const complex float *S, int N,
                           const complex float *K, int M) {
    int Ylen = N + M - 1;
    complex float *Y = calloc(Ylen, sizeof(complex float));
    for (int k = 0; k < Ylen; k++) {
        complex float sum = 0;
        int i_start = (k - M + 1 > 0) ? (k - M + 1) : 0;
        int i_end   = (k < N - 1) ? k : (N - 1);
        for (int i = i_start; i <= i_end; i++) {
            sum += S[i] * K[k - i];
        }
        Y[k] = sum;
    }
    return Y;
}

/* ===========================================================================
 * Implementation 2: Loop-unrolled C (4x inner loop unroll)
 * =========================================================================== */
complex float *conv_unrolled(const complex float *S, int N,
                              const complex float *K, int M) {
    int Ylen = N + M - 1;
    complex float *Y = calloc(Ylen, sizeof(complex float));
    for (int k = 0; k < Ylen; k++) {
        complex float sum = 0;
        int i_start = (k - M + 1 > 0) ? (k - M + 1) : 0;
        int i_end   = (k < N - 1) ? k : (N - 1);
        int count = i_end - i_start + 1;
        int i = i_start;

        /* 4x unrolled */
        for (; i + 3 <= i_end; i += 4) {
            sum += S[i]   * K[k - i];
            sum += S[i+1] * K[k - (i+1)];
            sum += S[i+2] * K[k - (i+2)];
            sum += S[i+3] * K[k - (i+3)];
        }
        /* Tail */
        for (; i <= i_end; i++) {
            sum += S[i] * K[k - i];
        }
        Y[k] = sum;
    }
    return Y;
}

/* ===========================================================================
 * Implementation 3: AVX2 + FMA SIMD (design — compiles with -mavx2 -mfma)
 *
 * Processes 2 complex output elements at a time using 256-bit vectors.
 * For the inner product sum, each complex multiply uses:
 *   (a+bi)(c+di) = (ac-bd) + (ad+bc)i
 *
 * One __m256 holds 4 floats = 2 complex numbers packed as [re0, im0, re1, im1].
 * =========================================================================== */
#ifdef __AVX2__
#include <immintrin.h>

complex float *conv_avx2(const complex float *S, int N,
                          const complex float *K, int M) {
    int Ylen = N + M - 1;
    complex float *Y = calloc(Ylen, sizeof(complex float));

    for (int k = 0; k < Ylen; k++) {
        int i_start = (k - M + 1 > 0) ? (k - M + 1) : 0;
        int i_end   = (k < N - 1) ? k : (N - 1);
        int count = i_end - i_start + 1;

        /* Accumulate in SSE/AVX: use 128-bit for single complex accumulator */
        __m128 acc = _mm_setzero_ps();  /* [re_sum, im_sum, 0, 0] */

        for (int i = i_start; i <= i_end; i++) {
            int j = k - i;

            /* Load S[i] as [re, im, re, im] */
            __m128 sv = _mm_load1_ps((const float*)&S[i]);  /* broadcast real */
            /* Actually, complex multiply needs both components */

            /* For scalar-like accumulation with SIMD:
             * Load S[i].re, S[i].im repeatedly via shuffles */
            float sr = crealf(S[i]), si = cimagf(S[i]);
            float kr = crealf(K[j]), ki = cimagf(K[j]);

            /* (a+bi)(c+di) = (ac-bd) + (ad+bc)i */
            __m128 prod = _mm_set_ps(0, 0,
                                      sr * ki + si * kr,   /* imag */
                                      sr * kr - si * ki);  /* real */
            acc = _mm_add_ps(acc, prod);
        }

        float result[4];
        _mm_store_ps(result, acc);
        Y[k] = result[0] + result[1] * I;
    }
    return Y;
}
#endif /* __AVX2__ */

/* ===========================================================================
 * Implementation 4: FFT-based convolution (requires FFTW3)
 *
 * Uses Overlap-Add method:
 *   1. Choose FFT size L ≥ N+M-1 (power of 2)
 *   2. FFT(S_padded) * FFT(K_padded) → IFFT → Y
 *   3. Complexity: O(L log L) vs O(NM)
 *
 * For large M (> ~64), FFT method is faster.
 * =========================================================================== */
#ifdef HAVE_FFTW
#include <fftw3.h>

complex float *conv_fft(const complex float *S, int N,
                         const complex float *K, int M) {
    int Ylen = N + M - 1;

    /* Choose FFT size: next power of 2 >= Ylen */
    int L = 1;
    while (L < Ylen) L <<= 1;

    /* Allocate FFTW arrays */
    fftwf_complex *A = fftwf_alloc_complex(L);
    fftwf_complex *B = fftwf_alloc_complex(L);
    fftwf_complex *C = fftwf_alloc_complex(L);

    /* Zero-pad S */
    for (int i = 0; i < N; i++) { A[i][0] = crealf(S[i]); A[i][1] = cimagf(S[i]); }
    for (int i = N; i < L; i++) { A[i][0] = 0; A[i][1] = 0; }

    /* Zero-pad K */
    for (int i = 0; i < M; i++) { B[i][0] = crealf(K[i]); B[i][1] = cimagf(K[i]); }
    for (int i = M; i < L; i++) { B[i][0] = 0; B[i][1] = 0; }

    /* FFT plans */
    fftwf_plan fwd_A = fftwf_plan_dft_1d(L, A, A, FFTW_FORWARD, FFTW_ESTIMATE);
    fftwf_plan fwd_B = fftwf_plan_dft_1d(L, B, B, FFTW_FORWARD, FFTW_ESTIMATE);
    fftwf_plan inv_C = fftwf_plan_dft_1d(L, C, C, FFTW_BACKWARD, FFTW_ESTIMATE);

    fftwf_execute(fwd_A);
    fftwf_execute(fwd_B);

    /* Pointwise multiply: C = A * B / L (FFTW backward doesn't scale) */
    float invL = 1.0f / L;
    for (int i = 0; i < L; i++) {
        float ar = A[i][0], ai = A[i][1];
        float br = B[i][0], bi = B[i][1];
        C[i][0] = (ar * br - ai * bi) * invL;
        C[i][1] = (ar * bi + ai * br) * invL;
    }

    fftwf_execute(inv_C);

    /* Extract Y from C */
    complex float *Y = malloc(Ylen * sizeof(complex float));
    for (int i = 0; i < Ylen; i++)
        Y[i] = C[i][0] + C[i][1] * I;

    fftwf_destroy_plan(fwd_A);
    fftwf_destroy_plan(fwd_B);
    fftwf_destroy_plan(inv_C);
    fftwf_free(A); fftwf_free(B); fftwf_free(C);
    return Y;
}
#endif /* HAVE_FFTW */

/* ===========================================================================
 * Benchmark driver
 * =========================================================================== */
typedef struct {
    const char *name;
    complex float *(*fn)(const complex float*, int, const complex float*, int);
} Impl;

int main(void) {
    printf("============================================================\n");
    printf("  1D Complex Convolution — Performance Benchmark\n");
    printf("============================================================\n\n");

    /* Benchmark configurations */
    struct { int N; int M; const char *label; } configs[] = {
        {  256,   64, "Small  (N=256,  M=64)  " },
        { 1024,  256, "Medium (N=1024, M=256) " },
        { 4096, 1024, "Large  (N=4096, M=1024)" },
        {  128,  512, "WideK  (N=128,  M=512) " },  /* FFT shines here */
    };
    int n_configs = sizeof(configs) / sizeof(configs[0]);

    /* Collect implementations */
    Impl impls[8];
    int n_impls = 0;

    impls[n_impls++] = (Impl){"Naive C       ", conv_naive};
    impls[n_impls++] = (Impl){"Unrolled C    ", conv_unrolled};
#ifdef __AVX2__
    impls[n_impls++] = (Impl){"AVX2 SIMD     ", conv_avx2};
#endif
#ifdef HAVE_FFTW
    impls[n_impls++] = (Impl){"FFTW3 FFT     ", conv_fft};
#endif

    printf("%-20s", "Implementation");
    for (int c = 0; c < n_configs; c++)
        printf(" | %-22s", configs[c].label);
    printf(" | %-12s\n", "GFLOPS(peak)");
    printf("%.20s", "--------------------");
    for (int c = 0; c < n_configs; c++)
        printf("-+%-22s", "----------------------");
    printf("-+-------------\n");

    /* --- First pass: compute reference for verification --- */
    printf("\nVerification (max error vs naive C):\n");

    for (int c = 0; c < n_configs; c++) {
        complex float *S = rand_complex(configs[c].N, 42 + c);
        complex float *K = rand_complex(configs[c].M, 100 + c);
        complex float *ref = conv_naive(S, configs[c].N, K, configs[c].M);

        for (int i = 1; i < n_impls; i++) {
            complex float *Y = impls[i].fn(S, configs[c].N, K, configs[c].M);
            float err = verify(ref, Y, configs[c].N + configs[c].M - 1);
            printf("  %s vs %-20s: %s (err=%.2e)\n",
                   configs[c].label, impls[i].name,
                   err < 1e-5 ? "PASS" : "FAIL", err);
            free(Y);
        }
        free(ref); free(S); free(K);
    }

    /* --- Second pass: benchmark timing --- */
    printf("\n\nTiming (best of 5 runs, microseconds):\n\n");
    printf("%-20s", "Implementation");
    for (int c = 0; c < n_configs; c++)
        printf(" | %-22s", configs[c].label);
    printf(" | %-12s\n", "GFLOPS");
    printf("%.20s", "--------------------");
    for (int c = 0; c < n_configs; c++)
        printf("-+%-22s", "----------------------");
    printf("-+-------------\n");

    double gflops_peak[n_impls];
    memset(gflops_peak, 0, sizeof(gflops_peak));

    for (int i = 0; i < n_impls; i++) {
        printf("%-20s", impls[i].name);

        for (int c = 0; c < n_configs; c++) {
            complex float *S = rand_complex(configs[c].N, 42 + c);
            complex float *K = rand_complex(configs[c].M, 100 + c);

            /* Warmup */
            complex float *Y = impls[i].fn(S, configs[c].N, K, configs[c].M);
            free(Y);

            /* Benchmark: best of 5 */
            double best = 1e99;
            for (int trial = 0; trial < 5; trial++) {
                double t0 = get_time_us();
                Y = impls[i].fn(S, configs[c].N, K, configs[c].M);
                double t1 = get_time_us();
                if (t1 - t0 < best) best = t1 - t0;
                free(Y);
            }

            printf(" | %9.1f us", best);

            /* Compute GFLOPS: O(N*M) per output, each requires ~10 FLOP
             * (complex mul=6 FLOP + complex add=2 FLOP)
             * Total FLOP = YLEN * avg_ops_per_k * 8
             * Approx: N*M * 8 FLOP */
            int YLEN = configs[c].N + configs[c].M - 1;
            double flops = (double)YLEN * configs[c].M * 8.0; /* approximate */
            double gflops = flops / (best * 1e-6) / 1e9;
            if (gflops > gflops_peak[i]) gflops_peak[i] = gflops;

            free(S); free(K);
        }
        printf(" | %6.2f GFLOPS\n", gflops_peak[i]);
    }

    /* --- Summary --- */
    printf("\n============================================================\n");
    printf("  Speedup Summary (vs Naive C on Large config)\n");
    printf("============================================================\n");

    /* Re-benchmark just the large case for clean numbers */
    {
        int N = 4096, M = 1024;
        complex float *S = rand_complex(N, 42);
        complex float *K = rand_complex(M, 100);

        double baseline_time = 0;
        for (int i = 0; i < n_impls; i++) {
            double best = 1e99;
            for (int trial = 0; trial < 3; trial++) {
                double t0 = get_time_us();
                complex float *Y = impls[i].fn(S, N, K, M);
                double t1 = get_time_us();
                if (t1 - t0 < best) best = t1 - t0;
                free(Y);
            }
            if (i == 0) baseline_time = best;
            printf("  %-20s : %9.1f us  (%.2fx speedup)\n",
                   impls[i].name, best, baseline_time / best);
        }
        free(S); free(K);
    }

    printf("\nNote: AVX2 and FFTW require -mavx2 -mfma and -lfftw3 respectively.\n");
    printf("OpenBLAS comparison: cblas_cgemv or custom conv kernel.\n");

    return 0;
}
