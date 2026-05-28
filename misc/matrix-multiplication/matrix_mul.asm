; ===================================================================
; Matrix Multiplication - Integer Fixed-Point  (for emu8086)
;   C[M_rows x O_cols] = A[M_rows x N_cols] * B[N_cols x O_cols]
;
; All values scaled by 100. Uses integer MUL/DIV - NO 8087 needed.
;
; Demo: A[2x3] x B[3x2] = C[2x2]
;
;         | 1  2  3 |          | 1  2 |
;   A =   | 4  5  6 |    B =   | 3  4 |
;                              | 5  6 |
;
; Expected C = A * B:
;   | 1*1+2*3+3*5   1*2+2*4+3*6 |   | 22  28 |
;   | 4*1+5*3+6*5   4*2+5*4+6*6 | = | 49  64 |
;
; NOTE: 8086 has no MMX/SSE/AVX and no multi-core.
; ===================================================================

.model small
.stack 200h

.data
    ; ---- Matrix dimensions ----
    M_rows  dw  2           ; rows of A
    N_cols  dw  3           ; cols of A = rows of B
    O_cols  dw  2           ; cols of B

    ; ---- Matrix A [2x3] (row-major, scaled by 100) ----
    ;       col0  col1  col2
    A_mat   dw  100,  200,  300     ; row0:  1.0   2.0   3.0
            dw  400,  500,  600     ; row1:  4.0   5.0   6.0

    ; ---- Matrix B [3x2] (scaled by 100) ----
    ;       col0  col1
    B_mat   dw  100,  200           ; row0:  1.0   2.0
            dw  300,  400           ; row1:  3.0   4.0
            dw  500,  600           ; row2:  5.0   6.0

    ; ---- Result matrix C [2x2] (scaled by 100) ----
    C_mat   dw  4 dup(0)

    ; ---- Loop counters ----
    r_idx   dw  0
    c_idx   dw  0
    k_idx   dw  0

    ; ---- Temporary variables ----
    dot_sum dw  0               ; accumulator for dot product
    tmp_a   dw  0               ; holds A[r][k] while we load B[k][c]

    ; ---- Display strings ----
    str_title db 'MATRIX MULTIPLICATION (Integer Fixed-Point)', 0Dh, 0Ah
              db 'A[2x3] * B[3x2] = C[2x2]', 0Dh, 0Ah, 0Dh, 0Ah, '$'
    str_a     db 'Matrix A (2x3):', 0Dh, 0Ah, '$'
    str_b     db 0Dh, 0Ah, 'Matrix B (3x2):', 0Dh, 0Ah, '$'
    str_c     db 0Dh, 0Ah, 'Result C = A * B (2x2):', 0Dh, 0Ah, '$'
    str_exit  db 0Dh, 0Ah, 'Press any key to exit...$'
    str_nl    db 0Dh, 0Ah, '$'
    str_sp    db '  $'

.code
main proc
    mov     ax, @data
    mov     ds, ax

    ; ---- Print header ----
    lea     dx, str_title
    mov     ah, 09h
    int     21h

    ; ---- Display matrix A ----
    lea     dx, str_a
    mov     ah, 09h
    int     21h
    lea     si, A_mat
    mov     cx, M_rows
    mov     dx, N_cols
    call    show_matrix

    ; ---- Display matrix B ----
    lea     dx, str_b
    mov     ah, 09h
    int     21h
    lea     si, B_mat
    mov     cx, N_cols
    mov     dx, O_cols
    call    show_matrix

    ; ============================================================
    ;     C[r][c] = sum_{k} A[r][k] * B[k][c]
    ;
    ;  Values are scaled by 100.
    ;  raw     = A_val * B_val            (scaled by 10000)
    ;  product = raw / 100                (scaled by 100)
    ;  C[r][c] = sum of products          (scaled by 100)
    ; ============================================================
    mov     [r_idx], 0

L1: mov     ax, [r_idx]
    cmp     ax, M_rows
    jge     L1_end

    mov     [c_idx], 0

L2: mov     ax, [c_idx]
    cmp     ax, O_cols
    jge     L2_end

    mov     [dot_sum], 0            ; accumulator = 0
    mov     [k_idx], 0

L3: mov     ax, [k_idx]
    cmp     ax, N_cols
    jge     L3_end

    ; ---- Load A[r][k] ----
    mov     ax, [r_idx]
    mul     [N_cols]                ; AX = r * N_cols
    add     ax, [k_idx]             ; AX = r * N_cols + k
    add     ax, ax                  ; *2 (word = 2 bytes)
    mov     bx, ax
    mov     ax, A_mat[bx]           ; AX = A[r][k] (scaled)
    mov     [tmp_a], ax             ; save A value

    ; ---- Load B[k][c] ----
    mov     ax, [k_idx]
    mul     [O_cols]                ; AX = k * O_cols
    add     ax, [c_idx]             ; AX = k * O_cols + c
    add     ax, ax                  ; *2
    mov     bx, ax
    mov     ax, B_mat[bx]           ; AX = B[k][c] (scaled)

    ; ---- MUL: DX:AX = A_val * B_val ----
    mov     bx, [tmp_a]             ; BX = A_val
    mul     bx                      ; DX:AX = A_val * B_val (scaled 10000)

    ; ---- DIV by 100: AX = quotient (scaled 100) ----
    mov     bx, 100
    div     bx                      ; AX = (DX:AX) / 100

    ; ---- Accumulate ----
    add     [dot_sum], ax

    inc     [k_idx]
    jmp     L3

L3_end:
    ; ---- Store C[r][c] = dot_sum ----
    mov     ax, [r_idx]
    mul     [O_cols]                ; AX = r * O_cols
    add     ax, [c_idx]             ; AX = r * O_cols + c
    add     ax, ax                  ; *2
    mov     bx, ax
    mov     ax, [dot_sum]
    mov     C_mat[bx], ax

    inc     [c_idx]
    jmp     L2

L2_end:
    inc     [r_idx]
    jmp     L1

L1_end:
    ; ---- Display result matrix C ----
    lea     dx, str_c
    mov     ah, 09h
    int     21h
    lea     si, C_mat
    mov     cx, M_rows
    mov     dx, O_cols
    call    show_matrix

    ; ---- Wait for keypress and exit ----
    lea     dx, str_exit
    mov     ah, 09h
    int     21h
    mov     ah, 01h
    int     21h
    mov     ah, 4Ch
    int     21h
main endp

; ===================================================================
; show_matrix
;   Displays a matrix row-by-row.
;   Input: SI = base address, CX = rows, DX = cols
; ===================================================================
show_matrix proc
    push    cx
    push    dx
    push    si

    mov     [r_idx], 0

sm_r: mov     ax, [r_idx]
    cmp     ax, cx
    jge     sm_done

    mov     [c_idx], 0

sm_c: mov     ax, [c_idx]
    cmp     ax, dx
    jge     sm_c_end

    ; offset = (r_idx * cols + c_idx) * 2
    mov     ax, [r_idx]
    push    dx                  ; save cols (DX is destroyed by MUL)
    mul     dx                  ; AX = r_idx * cols
    pop     dx                  ; restore cols
    add     ax, [c_idx]
    add     ax, ax                  ; *2
    mov     bx, ax
    mov     ax, [si + bx]           ; AX = value (scaled by 100)
    call    print_fixed

    inc     [c_idx]
    jmp     sm_c

sm_c_end:
    push    dx                  ; save column count
    lea     dx, str_nl
    mov     ah, 09h
    int     21h
    pop     dx                  ; restore column count

    inc     [r_idx]
    jmp     sm_r

sm_done:
    pop     si
    pop     dx
    pop     cx
    ret
show_matrix endp

; ===================================================================
; print_fixed
;   Prints AX (scaled by 100) as XX.XX
;   Examples: AX=150 -> " 1.50", AX=-5 -> "-0.05"
; ===================================================================
print_fixed proc
    push    ax
    push    bx
    push    cx
    push    dx

    ; ---- Handle sign ----
    or      ax, ax
    jns     pf_pos
    neg     ax
    push    ax
    mov     dl, '-'
    mov     ah, 02h
    int     21h
    pop     ax

pf_pos:
    ; ---- Separate integer / fractional: AX/100 -> int, remainder -> frac ----
    mov     dx, 0
    mov     bx, 100
    div     bx                      ; AX = integer part, DX = fraction (0..99)

    push    dx                      ; save fraction on stack

    ; ---- Print integer part ----
    call    print_uint

    ; ---- Print '.' ----
    mov     dl, '.'
    mov     ah, 02h
    int     21h

    ; ---- Print fractional part (always 2 digits, zero-padded) ----
    pop     ax                      ; AX = fraction (0..99)
    mov     bl, 10
    div     bl                      ; AL = tens, AH = ones  (AH < 10)
    add     al, '0'
    mov     dl, al
    mov     ah, 02h
    int     21h                     ; tens
    mov     al, ah
    add     al, '0'                 ; AH = ones (0..9)
    mov     dl, al
    mov     ah, 02h
    int     21h                     ; ones

    ; ---- Trailing spaces ----
    lea     dx, str_sp
    mov     ah, 09h
    int     21h

pf_done:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret
print_fixed endp

; ===================================================================
; print_uint
;   Prints AX as an unsigned decimal integer (no leading zeros).
;   AX=0 prints "0".  AX>0 prints digits.
; ===================================================================
print_uint proc
    push    bx
    push    cx
    push    dx

    mov     bx, 10
    mov     cx, 0

pu_div:
    mov     dx, 0
    div     bx                      ; DX=digit(0..9), AX=quotient
    push    dx
    inc     cx
    or      ax, ax
    jnz     pu_div

pu_pop:
    pop     dx
    add     dl, '0'
    mov     ah, 02h
    int     21h
    loop    pu_pop

    pop     dx
    pop     cx
    pop     bx
    ret
print_uint endp

end main
