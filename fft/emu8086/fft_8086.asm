;==============================================================================
; FFT (Fast Fourier Transform) - Radix-2 DIT Implementation
; Target:  8086 + 8087 FPU (emu8086 v4.08)
;==============================================================================
; Algorithm: Cooley-Tukey Radix-2 Decimation-In-Time (DIT) FFT
;   N=8 points, complex single-precision (32-bit IEEE 754) floating point
;
; FFT Formula:  X[k] = SUM(n=0..N-1) x[n] * W_N^(n*k)
;   where W_N = e^(-j*2*pi/N)  (twiddle factor)
;
; DIT Butterfly (in-place):
;   t = W * A_lo
;   A_lo_new = A_hi - t
;   A_hi_new = A_hi + t
;
; Memory per complex number: 8 bytes (4 real + 4 imag)
;==============================================================================

.model small
.386                    ; 80386 for 32-bit regs (emu8086 v4.08 supports this)
.8087                   ; 8087 FPU coprocessor
.stack 200h

.data
    ; ===== FFT Parameters =====
    N       equ 8
    LOG2N   equ 3

    ; ===== Input Data: all-ones signal =====
    ; Expected: X[0] = 8.0 + 0.0i, X[1..7] = 0.0 + 0.0i
    data_arr label dword
    dd 1.0, 0.0           ; x[0]
    dd 1.0, 0.0           ; x[1]
    dd 1.0, 0.0           ; x[2]
    dd 1.0, 0.0           ; x[3]
    dd 1.0, 0.0           ; x[4]
    dd 1.0, 0.0           ; x[5]
    dd 1.0, 0.0           ; x[6]
    dd 1.0, 0.0           ; x[7]

    ; ===== Twiddle Factors: W^k = cos(2*pi*k/N) - j*sin(2*pi*k/N) =====
    ; k=0:  cos(0)      - j*sin(0)     =  1.000 + 0.000j
    ; k=1:  cos(pi/4)   - j*sin(pi/4)  =  0.707 - 0.707j
    ; k=2:  cos(pi/2)   - j*sin(pi/2)  =  0.000 - 1.000j
    ; k=3:  cos(3pi/4)  - j*sin(3pi/4) = -0.707 - 0.707j
    twiddle_arr label dword
    dd  1.0,        0.0
    dd  0.70710678, -0.70710678
    dd  0.0,        -1.0
    dd -0.70710678, -0.70710678

    ; ===== Bit-Reversal Table for N=8 =====
    ; bitrev[0..7] = {0, 4, 2, 6, 1, 5, 3, 7}
    bitrev_tbl db 0, 4, 2, 6, 1, 5, 3, 7

    ; ===== Temporary Storage for Butterfly =====
    tmp_r     dd ?
    tmp_i     dd ?
    d1_r_save dd ?
    d1_i_save dd ?

    ; ===== FFT Loop Control Variables =====
    idx1      dd ?          ; upper butterfly index
    idx2      dd ?          ; lower butterfly index
    tw_idx    dd ?          ; twiddle factor index
    tw_stride dd ?          ; N / m

    ; ===== Messages =====
    msg_title  db '============================================', 0Dh, 0Ah
               db '  FFT: Radix-2 DIT (8086 + 8087 FPU)', 0Dh, 0Ah
               db '  N=8 Complex Floating-Point', 0Dh, 0Ah
               db '============================================', 0Dh, 0Ah, '$'
    msg_input  db 0Dh, 0Ah, '>>> INPUT: Time-domain data', 0Dh, 0Ah, '$'
    msg_brev   db 0Dh, 0Ah, '>>> STEP 1: After bit-reversal permutation', 0Dh, 0Ah, '$'
    msg_stage  db 0Dh, 0Ah, '>>> STEP 2: FFT butterfly computation', 0Dh, 0Ah, '$'
    msg_out    db 0Dh, 0Ah, '>>> OUTPUT: Frequency-domain (FFT result)', 0Dh, 0Ah, '$'
    msg_verify db 0Dh, 0Ah, '[VERIFY] All-ones input -> X[0]=8.0, X[1..7]=0.0', 0Dh, 0Ah, '$'
    msg_lb     db 'X[', '$'
    msg_rb     db '] = ', '$'
    msg_plus   db ' + j', '$'
    msg_nl     db 0Dh, 0Ah, '$'

    ; ===== Float Printing Buffer =====
    pfp_scale dd 1000.0
    pfp_int   dd ?
    pfp_ten   dd 10

.code

;==============================================================================
; MAIN
;==============================================================================
main proc
    mov ax, @data
    mov ds, ax
    finit

    ; === Display Header ===
    lea dx, msg_title
    call print_str

    ; === Display Input ===
    lea dx, msg_input
    call print_str
    call display_data

    ; === Bit-Reversal Permutation ===
    call bit_reverse

    lea dx, msg_brev
    call print_str
    call display_data

    ; === FFT Computation ===
    lea dx, msg_stage
    call print_str
    call fft_radix2

    ; === Display Output ===
    lea dx, msg_out
    call print_str
    call display_data

    lea dx, msg_verify
    call print_str

    ; === Exit ===
    mov ah, 4Ch
    int 21h
main endp

;==============================================================================
; print_str - Print $-terminated string at DX
;==============================================================================
print_str proc
    mov ah, 09h
    int 21h
    ret
print_str endp

;==============================================================================
; display_data - Print all N complex numbers in data_arr
;==============================================================================
display_data proc
    push ecx
    push esi

    xor ecx, ecx
dd_loop:
    cmp ecx, N
    jge dd_done

    ; Print "X[n] = "
    lea dx, msg_lb
    call print_str
    mov eax, ecx
    call print_u32
    lea dx, msg_rb
    call print_str

    ; Address of data_arr[ecx] = data_arr + ecx*8
    mov esi, offset data_arr
    mov eax, ecx
    shl eax, 3
    add esi, eax

    ; Print real part
    fld dword ptr [esi]
    call print_fp
    ffree st(0)

    ; Print " + j"
    lea dx, msg_plus
    call print_str

    ; Print imag part
    fld dword ptr [esi+4]
    call print_fp
    ffree st(0)

    ; Newline
    lea dx, msg_nl
    call print_str

    inc ecx
    jmp dd_loop

dd_done:
    pop esi
    pop ecx
    ret
display_data endp

;==============================================================================
; bit_reverse - In-place bit-reversal permutation using lookup table
;   For i = 0..N-1:
;     j = bitrev_tbl[i]
;     if i < j: swap(data_arr[i], data_arr[j])
;==============================================================================
bit_reverse proc
    push eax
    push ebx
    push ecx
    push esi
    push edi

    xor ecx, ecx                    ; i = 0
br_loop:
    cmp ecx, N
    jge br_done

    ; j = bitrev_tbl[i]
    movzx eax, byte ptr [bitrev_tbl + ecx]
    mov edi, eax                    ; edi = j

    cmp ecx, edi
    jge br_skip                     ; swap only if i < j

    ; esi = &data_arr[i] = data_arr + i*8
    mov esi, offset data_arr
    mov eax, ecx
    shl eax, 3
    add esi, eax

    ; edi = &data_arr[j] = data_arr + j*8
    push edi                        ; save j
    mov edi, offset data_arr
    movzx eax, byte ptr [bitrev_tbl + ecx]
    shl eax, 3
    add edi, eax

    ; Swap real: [esi] <-> [edi]
    fld dword ptr [esi]
    fld dword ptr [edi]
    fstp dword ptr [esi]
    fstp dword ptr [edi]

    ; Swap imag: [esi+4] <-> [edi+4]
    fld dword ptr [esi+4]
    fld dword ptr [edi+4]
    fstp dword ptr [esi+4]
    fstp dword ptr [edi+4]

    pop edi                         ; restore j

br_skip:
    inc ecx
    jmp br_loop

br_done:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    ret
bit_reverse endp

;==============================================================================
; fft_radix2 - In-place Radix-2 DIT FFT (Cooley-Tukey)
;
;   Pseudo-code:
;     for s = 1 to log2(N):
;         m = 1 << s
;         half = m >> 1
;         stride = N / m
;         for k = 0 .. N-1 step m:
;             for j = 0 .. half-1:
;                 idx_hi = k + j
;                 idx_lo = k + j + half
;                 W = twiddle[j * stride]
;                 butterfly(idx_hi, idx_lo, W)
;==============================================================================
fft_radix2 proc
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    ; === Stage loop: s = 1 to LOG2N ===
    mov ebp, 1                      ; s = 1

stage_loop:
    cmp ebp, LOG2N
    jg fft2_done

    ; m = 1 << s                    ; group size
    mov eax, 1
    mov ecx, ebp
    shl eax, cl
    mov ebx, eax                    ; ebx = m

    ; half = m >> 1                 ; butterflies per group
    shr eax, 1
    mov edx, eax                    ; edx = half

    ; stride = N / m
    mov eax, N
    xor edx, edx
    div ebx
    mov tw_stride, eax

    ; === Group loop: k = 0 .. N-1 step m ===
    xor esi, esi                    ; esi = k

group_loop:
    cmp esi, N
    jge stage_next

    ; === Butterfly loop: j = 0 .. half-1 ===
    xor edi, edi                    ; edi = j

bfly_loop:
    cmp edi, edx
    jge group_next

    ; idx1 = k + j
    mov eax, esi
    add eax, edi
    mov idx1, eax

    ; idx2 = k + j + half
    add eax, edx
    mov idx2, eax

    ; tw_idx = j * stride
    mov eax, edi
    mul tw_stride
    mov tw_idx, eax

    push edx                        ; save half
    call butterfly
    pop edx

    inc edi
    jmp bfly_loop

group_next:
    add esi, ebx                    ; k += m
    jmp group_loop

stage_next:
    inc ebp                         ; s++
    jmp stage_loop

fft2_done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

fft_radix2 endp

;==============================================================================
; butterfly - Complex butterfly operation
;
;   Operation:
;     t       = W * data[idx2]     (complex multiply)
;     d1_save = data[idx1]         (save original)
;     data[idx1] = d1_save + t     (upper output)
;     data[idx2] = d1_save - t     (lower output)
;
;   Complex multiply (a+bi)(c+di) = (ac-bd) + (ad+bc)i
;
;   FPU stack discipline:
;     - Compute t.real: fld Wr; fmul dr; fld Wi; fmul di; fsubp; fstp tmp_r
;     - Compute t.imag: fld Wr; fmul di; fld Wi; fmul dr; faddp; fstp tmp_i
;     - Load d1, compute d1+t and d1-t, store results
;
;   This uses memory-based temporaries to keep FPU stack clean.
;==============================================================================
butterfly proc
    push eax
    push ebx
    push esi
    push edi

    ; ---- Resolve addresses ----
    ; esi = &data_arr[idx2]  (lower input)
    mov eax, idx2
    shl eax, 3
    mov esi, offset data_arr
    add esi, eax

    ; edi = &data_arr[idx1]  (upper input)
    mov eax, idx1
    shl eax, 3
    mov edi, offset data_arr
    add edi, eax

    ; ebx = &twiddle_arr[tw_idx]
    mov eax, tw_idx
    shl eax, 3
    mov ebx, offset twiddle_arr
    add ebx, eax

    ;------------------------------------------------------------------
    ; Compute t.real = Wr*dr - Wi*di
    ;------------------------------------------------------------------
    fld dword ptr [ebx]        ; st0 = Wr
    fmul dword ptr [esi]       ; st0 = Wr * dr
    fld dword ptr [ebx+4]      ; st0 = Wi, st1 = Wr*dr
    fmul dword ptr [esi+4]     ; st0 = Wi * di, st1 = Wr*dr
    fsubp st(1), st(0)         ; st0 = Wr*dr - Wi*di = t.real
    fstp dword ptr [tmp_r]     ; save t.real, stack empty

    ;------------------------------------------------------------------
    ; Compute t.imag = Wr*di + Wi*dr
    ;------------------------------------------------------------------
    fld dword ptr [ebx]        ; st0 = Wr
    fmul dword ptr [esi+4]     ; st0 = Wr * di
    fld dword ptr [ebx+4]      ; st0 = Wi, st1 = Wr*di
    fmul dword ptr [esi]       ; st0 = Wi * dr, st1 = Wr*di
    faddp st(1), st(0)         ; st0 = Wr*di + Wi*dr = t.imag
    fstp dword ptr [tmp_i]     ; save t.imag, stack empty

    ;------------------------------------------------------------------
    ; Save original d1 values
    ;------------------------------------------------------------------
    fld dword ptr [edi]        ; st0 = d1.real
    fstp dword ptr [d1_r_save]
    fld dword ptr [edi+4]      ; st0 = d1.imag
    fstp dword ptr [d1_i_save]

    ;------------------------------------------------------------------
    ; d1_new = d1_orig + t
    ;------------------------------------------------------------------
    fld dword ptr [d1_r_save]
    fadd dword ptr [tmp_r]
    fstp dword ptr [edi]       ; d1.real = d1.real + t.real

    fld dword ptr [d1_i_save]
    fadd dword ptr [tmp_i]
    fstp dword ptr [edi+4]     ; d1.imag = d1.imag + t.imag

    ;------------------------------------------------------------------
    ; d2_new = d1_orig - t
    ;------------------------------------------------------------------
    fld dword ptr [d1_r_save]
    fsub dword ptr [tmp_r]
    fstp dword ptr [esi]       ; d2.real = d1.real - t.real

    fld dword ptr [d1_i_save]
    fsub dword ptr [tmp_i]
    fstp dword ptr [esi+4]     ; d2.imag = d1.imag - t.imag

bf_done:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret
butterfly endp

;==============================================================================
; print_fp - Print st(0) as decimal with 3 decimal places
;   Multiplies by 1000, rounds to integer, prints with decimal point.
;==============================================================================
print_fp proc
    push eax
    push ebx
    push ecx
    push edx

    ; Check sign
    ftst
    fstsw ax
    sahf
    jae pfp_pos

    ; Print minus sign
    mov ah, 02h
    mov dl, '-'
    int 21h
    fabs

pfp_pos:
    ; st0 = round(value * 1000)
    fmul dword ptr [pfp_scale]
    frndint

    ; Convert to integer and pop
    fistp dword ptr [pfp_int]
    mov eax, [pfp_int]

    ; Integer part = eax / 1000, Fraction = eax % 1000
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ebx, edx                ; ebx = fraction

    ; Print integer part
    call print_u32_signed       ; eax = integer part

    ; Print decimal point
    mov ah, 02h
    mov dl, '.'
    int 21h

    ; Print fraction with 3 digits (zero-padded)
    mov eax, ebx
    mov bl, 100
    div bl                      ; al = tenths, ah = hundredths+thousandths

    push ax
    add al, '0'
    mov dl, al
    mov ah, 02h
    int 21h
    pop ax

    mov al, ah
    xor ah, ah
    mov bl, 10
    div bl
    push ax
    add al, '0'
    mov dl, al
    int 21h
    pop ax
    add ah, '0'
    mov dl, ah
    int 21h

pfp_done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
print_fp endp

;==============================================================================
; print_u32 - Print EAX as unsigned decimal
;==============================================================================
print_u32 proc
    push eax
    push ebx
    push ecx
    push edx
    push edi

    mov edi, 0                  ; digit counter
    mov ebx, 10

pu32_div:
    xor edx, edx
    div ebx                     ; eax /= 10, edx = remainder
    push edx                    ; store digit on stack
    inc edi
    test eax, eax
    jnz pu32_div

pu32_out:
    cmp edi, 0
    je pu32_done
    pop edx
    add dl, '0'
    mov ah, 02h
    int 21h
    dec edi
    jmp pu32_out

pu32_done:
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
print_u32 endp

;==============================================================================
; print_u32_signed - Print EAX as signed decimal
;==============================================================================
print_u32_signed proc
    push eax
    test eax, eax
    jns pus_positive

    ; Print minus sign
    mov ah, 02h
    mov dl, '-'
    int 21h
    neg eax

pus_positive:
    call print_u32
    pop eax
    ret
print_u32_signed endp

end main
