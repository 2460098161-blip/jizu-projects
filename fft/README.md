# 快速傅里叶变换（FFT）汇编实现

## 项目概述

本项目实现了快速傅里叶变换（Fast Fourier Transform, FFT）的两种汇编实现：

| 实现版本 | 目标平台 | 指令集 | 数据格式 |
|---------|---------|--------|---------|
| **8086 版** | emu8086 (8086 + 8087 FPU) | x86-16 + x87 | 32-bit 单精度浮点 |
| **AVX 加速版** | 现代 x86-64 (Haswell+) | AVX2 + FMA3 | 32-bit 单精度浮点 |

---

## 一、FFT 算法原理

### 1.1 离散傅里叶变换（DFT）

N 点 DFT 定义：

$$X[k] = \sum_{n=0}^{N-1} x[n] \cdot W_N^{nk}, \quad k = 0, 1, ..., N-1$$

其中 $W_N = e^{-j2\pi/N}$ 称为旋转因子（Twiddle Factor），$j = \sqrt{-1}$。

**计算复杂度**：$O(N^2)$ 次复数乘法。

### 1.2 快速傅里叶变换（Cooley-Tukey 算法）

Cooley-Tukey (1965) 的基-2 按时间抽取（DIT）FFT：

1. **比特逆序重排**（Bit-Reversal Permutation）：将输入数据按比特逆序重新排列
2. **蝶形运算**（Butterfly）：逐层进行 $N/2 \cdot \log_2(N)$ 次蝶形运算

**核心蝶形运算**（基-2 DIT）：

$$\begin{aligned}
X[k] &= A[k] + W_N^k \cdot B[k] \\
X[k+N/2] &= A[k] - W_N^k \cdot B[k]
\end{aligned}$$

其中 $A[k]$, $B[k]$ 分别为上下两个输入，$W_N^k$ 为旋转因子。

**计算复杂度**：$O(N \log_2 N)$ 次复数乘法。

### 1.3 复数乘法

$$(a + jb)(c + jd) = (ac - bd) + j(ad + bc)$$

一次复数乘法 = 4 次实数乘法 + 2 次实数加法。

---

## 二、8086 汇编实现（emu8086）

### 2.1 文件结构

```
emu8086/
└── fft_8086.asm    # 完整的 8086+8087 FFT 实现
```

### 2.2 设计要点

| 特性 | 实现 |
|------|------|
| FFT 算法 | 基-2 DIT Cooley-Tukey |
| 点数 N | 8（可配置） |
| 数值精度 | IEEE 754 单精度浮点（32-bit） |
| 浮点运算 | 8087 FPU 协处理器指令 |
| 复数存储 | 实部/虚部交替存储，每个复数占 8 字节 |
| 比特逆序 | 查表法（256 字节查找表） |
| 显示输出 | 整数部分 + 3 位小数 |

### 2.3 8087 FPU 指令使用

```asm
; 8087 浮点寄存器栈（8 个 80-bit 寄存器：st(0) ~ st(7)）
fld   dword ptr [addr]   ; 加载单精度浮点数到 st(0)
fstp  dword ptr [addr]   ; 存储 st(0) 到内存并弹出栈
fadd  dword ptr [addr]   ; st(0) = st(0) + mem
fsub  dword ptr [addr]   ; st(0) = st(0) - mem
fmul  dword ptr [addr]   ; st(0) = st(0) * mem
ftst                     ; 测试 st(0) 与 0 的关系
fabs                     ; st(0) = |st(0)|
frndint                  ; 舍入到整数
finit                    ; 初始化 FPU
```

### 2.4 内存布局

```
数据段:
  data_arr:  N×8 bytes   (复数输入/输出数组，原地计算)
  twiddle:   N/2×8 bytes  (旋转因子表，预计算)
  bitrev:    N bytes       (比特逆序查找表)
  tmp:       8 bytes       (蝶形运算临时存储)

总内存: 约 200 bytes (适用于 64KB 段内)
```

### 2.5 使用方法

1. 打开 emu8086
2. 加载 `emu8086/fft_8086.asm`
3. 点击 **Emulate** → **Run**
4. 在模拟器终端查看输出

或使用命令行：

```
D:\计组\emu8086\本体\emu8086\emu8086.exe fft_8086.asm
```

---

## 三、AVX 加速实现（现代 x86-64）

### 3.1 文件结构

```
modern_x86/
├── fft_avx_bench.c    # C 语言实现（含4个版本 + 性能基准测试）
├── fft_avx_asm.nasm   # NASM 手工汇编优化版（参考）
└── Makefile           # 编译脚本
```

### 3.2 四个实现版本

| 版本 | 算法 | 复杂度 | 加速技术 |
|------|------|--------|---------|
| **Naive DFT** | 直接计算 DFT 公式 | O(N²) | 无（基准线） |
| **Scalar FFT** | 基-2 DIT Cooley-Tukey | O(N log N) | 比特逆序 + 原地蝶形 |
| **AVX2 FFT** | 同上，内层向量化 | O(N log N / 8) | AVX2 256-bit SIMD |
| **AVX2-Opt** | 同上 + 优化 | O(N log N / 8) | + 循环展开 + 预取 |

### 3.3 AVX2 向量化策略

```
策略：一次处理 4 个蝶形运算（8 个复数）

AVX 寄存器布局（256-bit = 8×32-bit float）：
  ymm0 = [ar0, ai0, ar1, ai1, ar2, ai2, ar3, ai3]  (4 个复数)

关键 SIMD 操作：
  - vmovaps:    对齐加载/存储 8 个 float
  - vmulps:     并行乘法 (8-way)
  - vfmadd231ps: 融合乘加 a*b+c (FMA3)
  - vmovsldup:  复制奇数 lane → 提取实部
  - vmovshdup:  复制偶数 lane → 提取虚部
  - vunpcklps:  交叉合并低半部分
  - vinsertf128: 合并两个 128-bit 为 256-bit
```

### 3.4 编译与运行

**GCC (MinGW / Linux)**：

```bash
cd modern_x86
make bench
./fft_bench
```

**MSVC (Windows)**：

```bash
cd modern_x86
cl /O2 /arch:AVX2 /fp:fast /Fe:fft_bench.exe fft_avx_bench.c
fft_bench.exe
```

### 3.5 预期性能（参考值，Intel Core i7-12700H）

| N | Naive DFT | Scalar FFT | AVX2 FFT | AVX2-Opt FFT |
|---|-----------|-----------|----------|-------------|
| 256 | 0.45 ms | 0.003 ms | 0.001 ms | 0.001 ms |
| 1024 | 7.2 ms | 0.018 ms | 0.006 ms | 0.005 ms |
| 4096 | 118 ms | 0.09 ms | 0.028 ms | 0.022 ms |
| 16384 | 1900 ms | 0.42 ms | 0.13 ms | 0.10 ms |

---

## 四、与 OpenBLAS 性能对比分析

### 4.1 OpenBLAS 的优势

OpenBLAS 的 FFT（通过 FFTW API）在单线程下性能卓越，原因包括：

1. **自动调优**（Auto-tuning）：启动时探测 CPU 特性，选择最优 kernel
2. **微架构特化**：针对 Intel/AMD 不同微架构手写汇编 kernel
3. **多层缓存分块**（Cache blocking / tiling）：减少缓存未命中
4. **寄存器分配优化**：最大化寄存器复用
5. **SIMD 指令深度优化**：充分利用 AVX-512 / AVX2

### 4.2 本项目的竞争力

| 技术 | 本项目 | OpenBLAS |
|------|--------|----------|
| SIMD 宽度 | AVX2 (256-bit) | AVX2/AVX-512 |
| FMA 指令 | 使用 vfmadd | 密集使用 |
| 循环展开 | 手动 2x | 自动 + 手写 |
| 缓存优化 | 预取指令 | 多层分块 |
| 微架构适配 | 通用 | 按型号特化 |

### 4.3 要在单线程下超越 OpenBLAS 需要

1. 使用 **AVX-512**（512-bit SIMD，16 个 float 并行）
2. **缓存分块**：将大 N 的 FFT 拆分为适合 L1/L2 缓存的小块
3. **寄存器溢出最小化**：手工编排指令顺序
4. **免冲突的旋转因子访问模式**

---

## 五、架构对比：8086 vs 现代 x86-64

| 特性 | 8086 + 8087 | 现代 x86-64 + AVX2 |
|------|-------------|-------------------|
| 发布年份 | 1978 / 1980 | 2013+ |
| 数据总线 | 16-bit | 64-bit |
| 通用寄存器 | 8 个 16-bit | 16 个 64-bit |
| SIMD 寄存器 | 无 | 16 个 256-bit (YMM) |
| 浮点支持 | 8087 协处理器 (80-bit) | 内置 SSE/AVX (32/64-bit) |
| 最大寻址 | 1 MB (段式) | 256 TB (平坦) |
| FFT(N=8) | ~500 条指令 | ~50 条指令 |
| 单指令并行度 | 1 (标量) | 8 (256-bit SIMD) |

---

## 六、项目文件清单

```
FTT/
├── README.md                    # 本文档
├── emu8086/
│   └── fft_8086.asm             # 8086+8087 汇编 FFT
├── modern_x86/
│   ├── fft_avx_bench.c          # C + AVX2 性能基准测试
│   ├── fft_avx_asm.nasm         # 手工 AVX2 汇编优化
│   └── Makefile                 # 编译脚本
└── create_ppt.py                 # PPT 自动生成脚本
```

---

## 七、参考资料

1. Cooley, J. W., & Tukey, J. W. (1965). "An algorithm for the machine calculation of complex Fourier series." *Mathematics of Computation*, 19(90), 297-301.
2. Intel 64 and IA-32 Architectures Optimization Reference Manual
3. OpenBLAS: https://github.com/OpenMathLib/OpenBLAS
4. emu8086 使用手册
