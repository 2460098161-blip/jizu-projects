; ============================================================================
; conv.asm — 1D Complex Convolution for emu8086
; ============================================================================
; Implements MATLAB-compatible "full" convolution:
;   Y[k] = sum_{i} S[i] * K[k-i]   for k = 0..N+M-2
;
; Input:
;   DS:SI   → Signal S (N complex numbers, 8N bytes)
;   DS:DI   → Kernel K (M complex numbers, 8M bytes)
;   CX      = N (signal length)
;   DX      = M (kernel length)
;
; Output:
;   ES:BX   → Result Y (N+M-1 complex numbers, 8(N+M-1) bytes)
;
; Memory:
;   Each complex number = 8 bytes (real: 4B + imag: 4B)
;   Max signal size limited by 64KB segment: ~8000 complex numbers
;
; Algorithm (direct O(N*M)):
;   For k = 0 to N+M-2:
;       Y[k] = 0
;       i_start = max(0, k-M+1)
;       i_end   = min(k, N-1)
;       For i = i_start to i_end:
;           j = k - i
;           Y[k] += S[i] * K[j]
;
; ============================================================================

.MODEL SMALL

EXTERN CMUL:FAR, CADD:FAR, CZERO:FAR

.DATA
    ; --- Convolution state variables ---
    CONV_N      DW 0        ; Signal length N
    CONV_M      DW 0        ; Kernel length M
    CONV_YLEN   DW 0        ; Output length = N+M-1
    CONV_K      DW 0        ; Outer loop index k
    CONV_I      DW 0        ; Inner loop index i
    CONV_J      DW 0        ; Inner index j = k - i
    CONV_I_START DW 0       ; i_start = max(0, k-M+1)
    CONV_I_END  DW 0        ; i_end = min(k, N-1)

    CONV_S_PTR  DW 0, 0     ; Far pointer to S
    CONV_K_PTR  DW 0, 0     ; Far pointer to K
    CONV_Y_PTR  DW 0, 0     ; Far pointer to Y

    ; --- Accumulator for Y[k] (complex) ---
    CONV_ACC_R  DD 0.0      ; Accumulator real part
    CONV_ACC_I  DD 0.0      ; Accumulator imag part

    ; --- Temporary for S[i] * K[j] result ---
    CONV_PROD   DD 0.0, 0.0 ; Complex product (8 bytes)

    ; --- Scratch buffers for CMUL operands ---
    CONV_OP_A   DD 0.0, 0.0 ; Copy of S[i]
    CONV_OP_B   DD 0.0, 0.0 ; Copy of K[j]

.CODE

; ============================================================================
; CONV — Main convolution routine
; Input:
;   DS:SI → S array
;   DS:DI → K array
;   CX = N, DX = M
;   ES:BX → Y output array (pre-allocated, (N+M-1)*8 bytes)
;
; Registers used:
;   CX, DX: N, M (input)
;   SI, DI: array pointers
;   BX: output base pointer
; ============================================================================
CONV PROC FAR
    PUSH AX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES

    ; --- Save parameters ---
    MOV [CONV_N], CX
    MOV [CONV_M], DX
    MOV [CONV_S_PTR], SI
    MOV [CONV_K_PTR], DI
    MOV [CONV_Y_PTR], BX

    ; Compute Y length = N + M - 1
    MOV AX, CX
    ADD AX, DX
    DEC AX
    MOV [CONV_YLEN], AX

    ; --- Save S and K segment (assume DS) ---
    MOV AX, DS
    MOV [CONV_S_PTR+2], AX
    MOV [CONV_K_PTR+2], AX

    ; --- Outer loop: k = 0 to YLEN-1 ---
    MOV WORD PTR [CONV_K], 0

@@outer_loop:
    MOV AX, [CONV_K]
    CMP AX, [CONV_YLEN]
    JAE @@conv_done          ; k >= YLEN → done

    ; --- Zero the accumulator for this k ---
    LEA BX, CONV_ACC_R
    PUSH BX
    CALL CZERO
    POP BX

    ; --- Compute i_start = max(0, k - M + 1) ---
    MOV AX, [CONV_K]
    SUB AX, [CONV_M]
    ADD AX, 1                ; AX = k - M + 1
    CMP AX, 0
    JGE @@start_ok
    XOR AX, AX               ; i_start = max(0, k-M+1)
@@start_ok:
    MOV [CONV_I_START], AX

    ; --- Compute i_end = min(k, N-1) ---
    MOV AX, [CONV_K]
    MOV CX, [CONV_N]
    DEC CX                   ; CX = N-1
    CMP AX, CX
    JBE @@end_ok
    MOV AX, CX               ; i_end = min(k, N-1)
@@end_ok:
    MOV [CONV_I_END], AX

    ; --- Inner loop: i = i_start to i_end ---
    MOV AX, [CONV_I_START]
    MOV [CONV_I], AX

@@inner_loop:
    MOV AX, [CONV_I]
    CMP AX, [CONV_I_END]
    JA @@inner_done          ; i > i_end → accumulate done

    ; --- Compute j = k - i ---
    MOV AX, [CONV_K]
    SUB AX, [CONV_I]
    MOV [CONV_J], AX

    ; --- Copy S[i] to CONV_OP_A ---
    ; Address of S[i] = S_base + i * 8
    MOV AX, [CONV_I]
    MOV CX, 8
    MUL CX                   ; DX:AX = i * 8
    ADD AX, [CONV_S_PTR]    ; AX = offset into S
    MOV SI, AX               ; SI → S[i]

    LEA DI, CONV_OP_A        ; DI → temp buffer A
    ; Copy 8 bytes S[i] → CONV_OP_A
    MOV CX, [SI]
    MOV [DI], CX
    MOV CX, [SI+2]
    MOV [DI+2], CX
    MOV CX, [SI+4]
    MOV [DI+4], CX
    MOV CX, [SI+6]
    MOV [DI+6], CX

    ; --- Copy K[j] to CONV_OP_B ---
    MOV AX, [CONV_J]
    MOV CX, 8
    MUL CX
    ADD AX, [CONV_K_PTR]
    MOV DI, AX               ; DI → K[j]

    LEA SI, CONV_OP_B        ; Actually wait, we need K[j] as B operand
    ; Let's copy K[j] to CONV_OP_B
    PUSH SI                  ; Save SI (points to CONV_OP_B)
    MOV SI, DI               ; SI → K[j]
    LEA DI, CONV_OP_B        ; DI → temp buffer B
    MOV CX, [SI]
    MOV [DI], CX
    MOV CX, [SI+2]
    MOV [DI+2], CX
    MOV CX, [SI+4]
    MOV [DI+4], CX
    MOV CX, [SI+6]
    MOV [DI+6], CX
    POP SI                   ; Restore SI → CONV_OP_B... actually

    ; Now: SI should → CONV_OP_A, DI should → CONV_OP_B
    ; Let me set that up cleanly
    LEA SI, CONV_OP_A        ; SI → S[i] copy
    LEA DI, CONV_OP_B        ; DI → K[j] copy

    ; --- CMUL: CONV_PROD = S[i] * K[j] ---
    LEA BX, CONV_PROD
    PUSH BX
    PUSH SI
    PUSH DI
    CALL CMUL
    POP DI
    POP SI
    POP BX

    ; --- CADD: accumulator += CONV_PROD ---
    ; Accumulator is CONV_ACC_R (real) + CONV_ACC_I (imag)
    ; We need to add CONV_PROD to accumulator
    ;
    ; Add real parts
    LEA SI, CONV_ACC_R       ; SI → acc real
    LEA DI, CONV_PROD         ; DI → prod real
    LEA BX, CONV_ACC_R       ; BX → result back to acc real
    PUSH BX
    PUSH SI
    PUSH DI
    CALL FADD
    POP DI
    POP SI
    POP BX

    ; Add imag parts
    LEA SI, CONV_ACC_I       ; SI → acc imag
    LEA DI, CONV_PROD+4       ; DI → prod imag
    LEA BX, CONV_ACC_I       ; BX → result back to acc imag
    PUSH BX
    PUSH SI
    PUSH DI
    CALL FADD
    POP DI
    POP SI
    POP BX

    ; --- Next i ---
    INC WORD PTR [CONV_I]
    JMP @@inner_loop

@@inner_done:
    ; --- Store accumulator to Y[k] ---
    ; Y[k] address = Y_base + k * 8
    MOV AX, [CONV_K]
    MOV CX, 8
    MUL CX
    ADD AX, [CONV_Y_PTR]
    MOV DI, AX               ; DI → Y[k]

    ; Copy accumulator to Y[k]
    MOV AX, WORD PTR [CONV_ACC_R]
    MOV ES:[DI], AX
    MOV AX, WORD PTR [CONV_ACC_R+2]
    MOV ES:[DI+2], AX
    MOV AX, WORD PTR [CONV_ACC_I]
    MOV ES:[DI+4], AX
    MOV AX, WORD PTR [CONV_ACC_I+2]
    MOV ES:[DI+6], AX

    ; --- Next k ---
    INC WORD PTR [CONV_K]
    JMP @@outer_loop

@@conv_done:
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP AX
    RET
CONV ENDP

; ============================================================================
; Note: CONV calls FADD internally for accumulator updates.
; EXTERN FADD:FAR must be declared either here or in the main file.
; ============================================================================

EXTERN FADD:FAR

END
