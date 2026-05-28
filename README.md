# 计算机组成原理 - 汇编语言课程项目

> Computer Organization & Assembly Language Course Projects  
> 平台：emu8086 (Intel 8086) + 现代 x86-64 (AVX2)  
> 语言：8086 汇编 / NASM / C / MATLAB / Python

---

## 项目概览

本项目包含四个子项目，涵盖从复古 8086 到现代 AVX2 向量化加速的多种汇编/C 语言实现：

| 项目 | 说明 | 核心内容 |
|------|------|----------|
| **[fft](./fft/)** | 快速傅里叶变换 | 8086+8087 FPU 汇编 + AVX2 SIMD 加速 + 性能基准测试 |
| **[convolution](./convolution/)** | 一维复数卷积 | 8086 软件浮点运算 + 复数算术 + 优化策略分析 |
| **[grade-checker](./grade-checker/)** | 成绩判定器 | DOS 终端交互 + 浮点字符串解析 + DFA 状态机 |
| **[matrix-multiplication](./matrix-multiplication/)** | 矩阵乘法 | 8086 定点整数运算 + 三层循环 + 通用矩阵显示 |

---

## 目录结构

```
.
├── README.md
├── .gitignore
├── fft/                          # 快速傅里叶变换 (FFT)
│   ├── README.md                 #   详细文档
│   ├── emu8086/
│   │   └── fft_8086.asm          #   8086 + 8087 FPU 汇编实现
│   ├── modern_x86/
│   │   ├── fft_avx_bench.c       #   C + AVX2 性能基准测试
│   │   ├── fft_avx_asm.nasm      #   NASM 手工汇编优化
│   │   └── Makefile
│   ├── create_ppt.py             #   PPT 自动生成脚本
│   ├── FFT_演示文稿.pptx
│   └── screenshots/
├── convolution/                  # 一维复数卷积
│   ├── src/
│   │   ├── float32.asm           #   IEEE 754 软件浮点运算
│   │   ├── complex.asm           #   复数算术 (cmul, cadd)
│   │   ├── conv.asm              #   直接卷积 O(NM) 实现
│   │   └── test.asm              #   测试驱动
│   ├── ref/
│   │   ├── conv_ref.c            #   C99 参考实现
│   │   └── benchmark.c           #   性能对比 (Naive/AVX2/FFTW/OpenBLAS)
│   ├── matlab/
│   │   └── test_conv.m           #   MATLAB 黄金参考
│   ├── doc/
│   │   ├── report.md             #   完整项目报告
│   │   ├── report.docx
│   │   ├── generate_ppt.py
│   │   └── 卷积项目报告.pptx
│   └── screenshots/
├── grade-checker/                 # 成绩判定器
│   ├── grade_checker.asm          #   浮点字符串解析 + 等级判定
│   └── screenshots/
└── matrix-multiplication/         # 矩阵乘法
    ├── matrix_mul.asm             #   定点整数 ×100 缩放 + 三层循环
    └── screenshots/
```

---

## 快速开始

### 8086 汇编 (emu8086)

1. 下载并安装 [emu8086](https://emu8086.com/)
2. 打开 emu8086，加载对应的 `.asm` 文件
3. 点击 **Emulate** → **Run** 或按 `F9`

### FFT AVX2 性能基准 (现代 x86-64)

```bash
# GCC (MinGW / Linux)
cd fft/modern_x86
make bench
./fft_bench

# MSVC (Windows)
cl /O2 /arch:AVX2 /fp:fast /Fe:fft_bench.exe fft_avx_bench.c
fft_bench.exe
```

### 卷积 C 参考实现

```bash
# 基础版本
cd convolution/ref
gcc -std=c11 -O2 -o conv_ref conv_ref.c -lm
./conv_ref

# AVX2 加速版
gcc -std=c11 -O2 -mavx2 -mfma -o benchmark_avx2 benchmark.c -lm
./benchmark_avx2

# FFTW3 频域卷积 (需先安装 FFTW3)
gcc -std=c11 -O2 -DHAVE_FFTW -o benchmark_fft benchmark.c -lfftw3 -lm
./benchmark_fft
```

---

## 技术栈

- **复古平台**: Intel 8086 + 8087 FPU, 16-bit 实模式, 1MB 寻址
- **现代平台**: x86-64, AVX2 (256-bit SIMD), FMA3 融合乘加
- **浮点运算**: IEEE 754 单精度 (软件模拟 / 硬件 FPU)
- **算法**: Cooley-Tukey FFT, 基-2 DIT, 直接卷积, FFT 频域卷积
- **工具链**: emu8086, NASM, GCC/MSVC, MATLAB, python-pptx

---

## 各项目详情

### FFT (快速傅里叶变换)

- N=8 点复数 FFT，支持 8086+8087 和 AVX2 双平台
- 4 个实现版本：Naive DFT → Scalar FFT → AVX2 FFT → AVX2-Opt
- 性能跨度达 14600 倍（N=16384 时）
- 详见 [fft/README.md](./fft/README.md)

### 卷积 (1D Complex Convolution)

- 在 8086 上用软件模拟 IEEE 754 单精度浮点
- 完整的复数乘法/加法库
- 渐进式优化：循环展开 → AVX2 SIMD → FFT 频域卷积
- 与 MATLAB 逐位验证 + OpenBLAS 性能对比
- 详见 [convolution/doc/report.md](./convolution/doc/report.md)

### 成绩判定器 (Grade Determiner)

- DOS 终端交互，支持浮点输入（如 89.5）
- 逐字符 DFA 解析：整数部分 → 小数点 → 小数部分
- 范围校验 + Y/N 循环重试

### 矩阵乘法 (Matrix Multiplication)

- 通用维度矩阵乘法 C[MxO] = A[MxN] × B[NxO]
- 定点整数 (×100 缩放) 避免 8087 协处理器
- 带两位小数的通用矩阵显示子程序

---

## License

仅供学习参考。Educational use only.
