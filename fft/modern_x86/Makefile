# FFT Project Makefile
# Supports: GCC (MinGW/Linux) and MSVC (Windows)

# --- Compiler selection ---
CC = gcc
CFLAGS = -O3 -mavx2 -mfma -march=native -ffast-math -Wall
LDFLAGS = -lm

# OpenBLAS (optional: set OPENBLAS=1 to enable)
ifdef OPENBLAS
    CFLAGS += -DUSE_OPENBLAS
    LDFLAGS += -lopenblas
endif

# --- Targets ---
.PHONY: all bench clean

all: bench

bench: fft_avx_bench.c
	$(CC) $(CFLAGS) -o fft_bench fft_avx_bench.c $(LDFLAGS)
	@echo "Build complete. Run: ./fft_bench"

bench-msvc: fft_avx_bench.c
	cl /O2 /arch:AVX2 /fp:fast /Fe:fft_bench.exe fft_avx_bench.c

clean:
	rm -f fft_bench fft_bench.exe
