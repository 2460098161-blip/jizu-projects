; ============================================================================
; complex.asm — Complex Number Arithmetic for 8086
; ============================================================================
; Provides: cmul, cadd
;
; Complex number layout (8 bytes, little-endian):
;   Bytes 0-3: real part (IEEE 754 float32)
;   Bytes 4-7: imag part (IEEE 754 float32)
;
; Uses float32.asm primitives: FADD, FSUB, FMUL
;
; Temporary buffers in data segment for intermediate results.
; ============================================================================

.MODEL SMALL

EXTERN FADD:FAR, FSUB:FAR, FMUL:FAR

.DATA
    ; --- Work buffers for complex ops ---
    CX_MUL_AC   DD 0.0      ; a*c
    CX_MUL_BD   DD 0.0      ; b*d
    CX_MUL_AD   DD 0.0      ; a*d
    CX_MUL_BC   DD 0.0      ; b*c

    CX_A_REAL   DD 0.0      ; Copy of operand A real
    CX_A_IMAG   DD 0.0      ; Copy of operand A imag
    CX_B_REAL   DD 0.0      ; Copy of operand B real
    CX_B_IMAG   DD 0.0      ; Copy of operand B imag

    CX_SCRATCH  DD 0.0      ; General scratch

.CODE

; ============================================================================
; CMUL — Complex multiply: (a+bi) * (c+di) = (ac-bd) + (ad+bc)i
; Input:  DS:SI → complex A (8 bytes: real, imag)
;         DS:DI → complex B (8 bytes: real, imag)
; Output: DS:BX → complex result (8 bytes: real, imag)
;
; Uses 4 float multiplies, 1 float sub, 1 float add
; Clobbers: AX, CX, DX, BP
; ============================================================================
CMUL PROC FAR
    PUSH SI
    PUSH DI
    PUSH BP

    ; --- Save operands to fixed buffers ---
    ; Copy A's real
    MOV AX, [SI]
    MOV WORD PTR [CX_A_REAL], AX
    MOV AX, [SI+2]
    MOV WORD PTR [CX_A_REAL+2], AX
    ; Copy A's imag
    MOV AX, [SI+4]
    MOV WORD PTR [CX_A_IMAG], AX
    MOV AX, [SI+6]
    MOV WORD PTR [CX_A_IMAG+2], AX
    ; Copy B's real
    MOV AX, [DI]
    MOV WORD PTR [CX_B_REAL], AX
    MOV AX, [DI+2]
    MOV WORD PTR [CX_B_REAL+2], AX
    ; Copy B's imag
    MOV AX, [DI+4]
    MOV WORD PTR [CX_B_IMAG], AX
    MOV AX, [DI+6]
    MOV WORD PTR [CX_B_IMAG+2], AX

    ; --- Step 1: ac = A.real * B.real ---
    LEA SI, CX_A_REAL       ; SI → A.real
    LEA DI, CX_B_REAL       ; DI → B.real
    LEA BP, CX_MUL_AC       ; BP → result buffer
    PUSH BX                  ; Save BX (output pointer)
    MOV BX, BP
    CALL FMUL

    ; --- Step 2: bd = A.imag * B.imag ---
    LEA SI, CX_A_IMAG
    LEA DI, CX_B_IMAG
    LEA BP, CX_MUL_BD
    MOV BX, BP
    CALL FMUL

    ; --- Step 3: ad = A.real * B.imag ---
    LEA SI, CX_A_REAL
    LEA DI, CX_B_IMAG
    LEA BP, CX_MUL_AD
    MOV BX, BP
    CALL FMUL

    ; --- Step 4: bc = A.imag * B.real ---
    LEA SI, CX_A_IMAG
    LEA DI, CX_B_REAL
    LEA BP, CX_MUL_BC
    MOV BX, BP
    CALL FMUL

    POP BX                   ; Restore BX → output

    ; --- Compute real part: ac - bd ---
    PUSH BX                  ; Save output pointer
    LEA SI, CX_MUL_AC
    LEA DI, CX_MUL_BD
    MOV BP, BX               ; Output real directly to [BX]
    MOV BX, BP
    CALL FSUB                ; [BX] = ac - bd

    ; --- Compute imag part: ad + bc ---
    POP BX                   ; BX points to output base
    PUSH BX
    ADD BX, 4                ; BX → output imag part
    PUSH BX
    LEA SI, CX_MUL_AD
    LEA DI, CX_MUL_BC
    POP BX
    CALL FADD                ; [BX+4] = ad + bc

    POP BX                   ; BX → output base

    POP BP
    POP DI
    POP SI
    RET
CMUL ENDP

; ============================================================================
; CADD — Complex add: (a+bi) + (c+di) = (a+c) + (b+d)i
; Input:  DS:SI → complex A (8 bytes: real, imag)
;         DS:DI → complex B (8 bytes: real, imag)
; Output: DS:BX → complex result (8 bytes: real, imag)
; ============================================================================
CADD PROC FAR
    PUSH SI
    PUSH DI
    PUSH BX

    ; --- Compute real part: A.real + B.real → [BX] ---
    PUSH BX                  ; Save output pointer
    ; SI already points to A.real, DI to B.real
    ; BX points to output — store real at [BX]
    CALL FADD                ; [BX] = A.real + B.real

    ; --- Compute imag part: A.imag + B.imag → [BX+4] ---
    POP BX
    PUSH BX
    ADD SI, 4                ; SI → A.imag
    ADD DI, 4                ; DI → B.imag
    ADD BX, 4                ; BX → output imag
    CALL FADD                ; [BX+4] = A.imag + B.imag

    POP BX

    POP DI
    POP SI
    RET
CADD ENDP

; ============================================================================
; CZERO — Set complex number to (0, 0)
; Input:  DS:BX → complex number (8 bytes)
; ============================================================================
CZERO PROC FAR
    PUSH AX
    XOR AX, AX
    MOV [BX], AX
    MOV [BX+2], AX
    MOV [BX+4], AX
    MOV [BX+6], AX
    POP AX
    RET
CZERO ENDP

; ============================================================================
; CCOPY — Copy complex number
; Input:  DS:SI → source complex
; Output: DS:BX → destination (8 bytes)
; ============================================================================
CCOPY PROC FAR
    PUSH AX
    MOV AX, [SI]
    MOV [BX], AX
    MOV AX, [SI+2]
    MOV [BX+2], AX
    MOV AX, [SI+4]
    MOV [BX+4], AX
    MOV AX, [SI+6]
    MOV [BX+6], AX
    POP AX
    RET
CCOPY ENDP

END
