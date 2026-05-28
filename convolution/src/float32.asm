; ============================================================================
; float32.asm — IEEE 754 Single-Precision Floating-Point Library for 8086
; ============================================================================
; Provides: fadd, fsub, fmul, fcmp, itof, ftoi
;
; IEEE 754 binary32 format (little-endian in memory):
;   Byte 0-1: mantissa bits [15:0]
;   Byte 2:   mantissa bits [22:16]
;   Byte 3:   bit[7]=sign, bits[6:0]=exponent[7:1]
;   Byte 2 bit[7] = exponent[0]
;
;   Value = (-1)^sign * 2^(exp-127) * (1.mantissa)   (normalized)
;   Value = (-1)^sign * 2^(-126) * (0.mantissa)       (denormal, exp=0)
;   exp=0xFF, mant=0 → +/-infinity
;   exp=0xFF, mant≠0 → NaN
;
; Calling convention:
;   Input:  DS:SI → operand A (4 bytes)
;           DS:DI → operand B (4 bytes)
;   Output: DS:BX → result (4 bytes)
;   Clobbers: AX, CX, DX, BP (SI, DI preserved after reading)
;
; Temporary storage in data segment:
;   Uses word-sized stack frames for intermediates
; ============================================================================

.MODEL SMALL
.386                    ; Allow 32-bit registers for clarity in comments
                        ; Actual code uses only 8086 instructions

.DATA
; --- Work buffers for FP operations ---
FPA_SIGN    DW 0        ; Sign of operand A (0=pos, 1=neg)
FPA_EXP     DW 0        ; Biased exponent of A (0-255)
FPA_MANT_H  DW 0        ; Mantissa of A, high word (bits 23-16, with hidden)
FPA_MANT_L  DW 0        ; Mantissa of A, low word (bits 15-0)

FPB_SIGN    DW 0
FPB_EXP     DW 0
FPB_MANT_H  DW 0
FPB_MANT_L  DW 0

FPR_SIGN    DW 0        ; Result sign
FPR_EXP     DW 0        ; Result exponent
FPR_MANT_H  DW 0        ; Result mantissa high
FPR_MANT_L  DW 0        ; Result mantissa low

FP_TEMP_A   DD 0        ; General temp storage
FP_TEMP_B   DD 0
FP_TEMP_C   DD 0

; Constants
FP_BIAS     DW 127      ; Exponent bias
FP_ZERO     DD 0.0      ; 0.0 constant
FP_ONE      DD 1.0      ; 1.0 constant
FP_NEG_ONE  DD -1.0     ; -1.0 constant

.CODE

; ============================================================================
; UNPACK — Extract sign, exponent, mantissa from float at DS:SI
; Input:  DS:SI → float
; Output: FPA_SIGN, FPA_EXP, FPA_MANT_H, FPA_MANT_L populated
; ============================================================================
UNPACK_A PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX

    ; Load the float as two words (little-endian)
    MOV AX, [SI]        ; AX = bits 15-0 (mantissa low)
    MOV BX, [SI+2]      ; BX = bits 31-16 (sign|exp[7:1]|exp[0]+mant[22:16])

    ; Extract sign: bit 15 of BX
    MOV CX, BX
    AND CX, 8000h
    CMP CX, 0
    JE @@sign_pos
    MOV FPA_SIGN, 1
    JMP @@extract_exp
@@sign_pos:
    MOV FPA_SIGN, 0

@@extract_exp:
    ; Extract exponent: (BX >> 7) & 0xFF
    ; BX bits: [15:sign][14:8:exp7-1][7:exp0|mant22-16][6:0:-]
    ; Exponent bits are at BX[14:8] (high 7 bits) and BX[7] (low bit)
    MOV CX, BX
    AND CX, 7F80h       ; Mask bits 14:8 → 0x7F80
    SHR CX, 1            ; CX >> 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1            ; Now CX has bits 14:8 in positions 6:0
    MOV FPA_EXP, CX      ; Store shifted value as exponent base

    ; Get exponent bit 0 from BX bit 7
    MOV DX, BX
    AND DX, 0080h        ; Extract bit 7 (exp[0])
    SHL DX, 1            ; DX bit 8 has exp[0]
    ADD FPA_EXP, DX      ; Now FPA_EXP = full 8-bit exponent

    ; Now FPA_EXP holds the raw biased exponent.
    ; But we need the actual exponent value. Let me redo this.
    ; Actually the exponent in BX is:
    ; bit 15: sign
    ; bits 14-8: exponent[7:1]
    ; bit 7: exponent[0]
    ; bits 6-0: mantissa[22:16]
    ;
    ; exponent = ((BX & 0x7F80) >> 7) | ((BX & 0x0080) << 0)
    ;          = ((BX >> 7) & 0xFF)

    ; Let's do it more simply:
    MOV CX, BX
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1            ; CX = BX >> 7
    AND CX, 00FFh        ; CX = exponent[7:0]
    MOV FPA_EXP, CX

    ; Extract mantissa:
    ; Upper part from BX bits 6-0 (mantissa[22:16])
    MOV CX, BX
    AND CX, 007Fh        ; CX = mantissa bits 22-16
    MOV FPA_MANT_H, CX

    ; Lower part from AX (mantissa[15:0])
    MOV FPA_MANT_L, AX

    ; Handle denormal vs normal
    CMP FPA_EXP, 0
    JNE @@normal
    ; Denormal: no hidden bit, value = 0.mantissa * 2^(-126)
    ; We flush denormals to zero for simplicity
    MOV FPA_MANT_H, 0
    MOV FPA_MANT_L, 0
    JMP @@done

@@normal:
    CMP FPA_EXP, 0FFh
    JNE @@add_hidden
    ; Infinity or NaN — keep mantissa as-is
    JMP @@done

@@add_hidden:
    ; Add hidden bit (bit 23 = 0x800000)
    ; High word: bits 23-16, so hidden bit is bit 7 of high byte
    OR FPA_MANT_H, 0080h   ; Set hidden bit (bit 23, which is bit 7 of high word)

@@done:
    POP CX
    POP BX
    POP AX
    RET
UNPACK_A ENDP

; ============================================================================
; UNPACK_B — Same as UNPACK_A but reads from DS:DI into FPB_*
; ============================================================================
UNPACK_B PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH SI               ; Save SI, use it temporarily

    MOV SI, DI            ; Point SI at operand B

    MOV AX, [SI]
    MOV BX, [SI+2]

    ; Extract sign
    MOV CX, BX
    AND CX, 8000h
    CMP CX, 0
    JE @@sign_pos
    MOV FPB_SIGN, 1
    JMP @@extract_exp
@@sign_pos:
    MOV FPB_SIGN, 0

@@extract_exp:
    MOV CX, BX
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    AND CX, 00FFh
    MOV FPB_EXP, CX

    MOV CX, BX
    AND CX, 007Fh
    MOV FPB_MANT_H, CX

    MOV FPB_MANT_L, AX

    CMP FPB_EXP, 0
    JNE @@normal
    MOV FPB_MANT_H, 0
    MOV FPB_MANT_L, 0
    JMP @@done

@@normal:
    CMP FPB_EXP, 0FFh
    JNE @@add_hidden
    JMP @@done

@@add_hidden:
    OR FPB_MANT_H, 0080h

@@done:
    POP SI
    POP CX
    POP BX
    POP AX
    RET
UNPACK_B ENDP

; ============================================================================
; PACK_RESULT — Pack FPR_SIGN, FPR_EXP, FPR_MANT_H/L into float at DS:BX
; Also handles normalization (called after arithmetic ops)
; ============================================================================
PACK_RESULT PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX

    ; Check for zero result
    MOV AX, FPR_MANT_H
    OR AX, FPR_MANT_L
    JNZ @@not_zero
    ; Result is zero
    MOV WORD PTR [BX], 0
    MOV WORD PTR [BX+2], 0
    JMP @@done

@@not_zero:
    ; Normalize: shift mantissa left until bit 23 is set
@@norm_loop:
    TEST FPR_MANT_H, 0080h    ; Check hidden bit position
    JNZ @@normalized
    ; Shift mantissa left by 1
    SHL FPR_MANT_L, 1
    RCL FPR_MANT_H, 1
    DEC FPR_EXP
    JMP @@norm_loop

@@normalized:
    ; Check for exponent overflow
    CMP FPR_EXP, 0FEh
    JBE @@check_under
    ; Overflow → return infinity
    MOV CX, FPR_SIGN
    CMP CX, 0
    JE @@inf_pos
    MOV WORD PTR [BX+2], 0FF80h    ; -inf
    MOV WORD PTR [BX], 0
    JMP @@done
@@inf_pos:
    MOV WORD PTR [BX+2], 7F80h     ; +inf
    MOV WORD PTR [BX], 0
    JMP @@done

@@check_under:
    CMP FPR_EXP, 0
    JG @@pack
    ; Underflow → flush to zero
    MOV WORD PTR [BX], 0
    MOV WORD PTR [BX+2], 0
    JMP @@done

@@pack:
    ; Pack: sign | exponent << 7 | mantissa high bits 6-0
    ; Result word high:
    ; bit 15 = FPR_SIGN
    ; bits 14-7 = FPR_EXP
    ; bits 6-0 = FPR_MANT_H bits 6-0 (after removing hidden bit)

    ; Remove hidden bit
    AND FPR_MANT_H, 007Fh    ; Clear hidden bit, keep bits 6-0

    MOV AX, FPR_EXP
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1                ; AX = exp << 7  (bits 14-7)

    OR AX, FPR_MANT_H        ; AX = exp << 7 | mantissa_high[6:0]

    CMP FPR_SIGN, 0
    JE @@pack_final
    OR AX, 8000h             ; Set sign bit

@@pack_final:
    MOV [BX+2], AX           ; Store high word
    MOV AX, FPR_MANT_L
    MOV [BX], AX             ; Store low word

@@done:
    POP DX
    POP CX
    POP AX
    RET
PACK_RESULT ENDP

; ============================================================================
; FADD — Add two IEEE 754 single-precision floats
; Input:  DS:SI → A, DS:DI → B
; Output: DS:BX → A + B
;
; Algorithm:
;   1. Unpack both operands
;   2. Handle special cases (zero, infinity, NaN)
;   3. Align exponents by shifting smaller mantissa right
;   4. Add or subtract mantissas based on signs
;   5. Normalize and pack result
; ============================================================================
FADD PROC FAR
    PUSH SI
    PUSH DI
    PUSH BP

    ; Unpack A and B
    CALL UNPACK_A
    CALL UNPACK_B

    ; --- Handle zeros ---
    ; If A is zero, result = B
    MOV AX, FPA_EXP
    CMP AX, 0
    JNE @@check_b_zero
    MOV AX, FPA_MANT_H
    OR AX, FPA_MANT_L
    JNZ @@check_b_zero
    ; A is zero, copy B to result
    MOV AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPB_EXP
    MOV FPR_EXP, AX
    MOV AX, FPB_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

@@check_b_zero:
    MOV AX, FPB_EXP
    CMP AX, 0
    JNE @@check_inf
    MOV AX, FPB_MANT_H
    OR AX, FPB_MANT_L
    JNZ @@check_inf
    ; B is zero, copy A to result
    MOV AX, FPA_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPA_EXP
    MOV FPR_EXP, AX
    MOV AX, FPA_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPA_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

@@check_inf:
    ; Check for infinity in A
    CMP FPA_EXP, 0FFh
    JNE @@check_b_inf
    ; A is inf/NaN, propagate A
    MOV AX, FPA_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPA_EXP
    MOV FPR_EXP, AX
    MOV AX, FPA_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPA_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

@@check_b_inf:
    CMP FPB_EXP, 0FFh
    JNE @@align
    ; B is inf/NaN, propagate B
    MOV AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPB_EXP
    MOV FPR_EXP, AX
    MOV AX, FPB_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

    ; --- Align exponents ---
@@align:
    MOV AX, FPA_EXP
    MOV CX, FPB_EXP

    CMP AX, CX
    JE @@same_exp
    JA @@a_bigger

    ; B has larger exponent — shift A's mantissa right
    SUB CX, AX              ; CX = exp difference
    MOV FPR_EXP, AX         ; Use larger exponent as base
    ADD FPR_EXP, CX          ; FPR_EXP = FPB_EXP (the larger one)

    ; Actually, let's track the larger exponent
    MOV DX, FPB_EXP
    MOV FPR_EXP, DX

@@shift_a:
    CMP CX, 24              ; If shift > 24 bits, A is negligible
    JA @@a_negligible
    CMP CX, 0
    JE @@add_sub
    ; Shift A mantissa right by 1
    SHR FPA_MANT_H, 1
    RCR FPA_MANT_L, 1
    DEC CX
    JMP @@shift_a

@@a_negligible:
    ; A is negligible, result = B
    MOV AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPB_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

@@a_bigger:
    ; A has larger exponent — shift B's mantissa right
    SUB AX, CX              ; AX = exp difference
    MOV FPR_EXP, CX         ; FPR_EXP = FPA_EXP (the larger one)
    ADD FPR_EXP, AX
    ; Actually simpler:
    MOV FPR_EXP, CX         ; CX = FPB_EXP
    ; Hmm, this is getting confused. Let me redo this section cleanly.

    ; If A's exp > B's exp, shift B
    ; diff = FPA_EXP - FPB_EXP
    MOV AX, FPA_EXP
    SUB AX, FPB_EXP         ; AX = diff
    MOV CX, AX
    MOV DX, FPA_EXP
    MOV FPR_EXP, DX          ; Result exponent = larger (A's)

@@shift_b:
    CMP CX, 24
    JA @@b_negligible
    CMP CX, 0
    JE @@add_sub
    SHR FPB_MANT_H, 1
    RCR FPB_MANT_L, 1
    DEC CX
    JMP @@shift_b

@@b_negligible:
    MOV AX, FPA_SIGN
    MOV FPR_SIGN, AX
    MOV AX, FPA_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPA_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit

@@same_exp:
    MOV AX, FPA_EXP
    MOV FPR_EXP, AX

    ; --- Add or subtract mantissas ---
@@add_sub:
    MOV AX, FPA_SIGN
    CMP AX, FPB_SIGN
    JNE @@sub_mant

    ; Signs same → add mantissas
@@add_mant:
    MOV FPR_SIGN, AX        ; Result sign = A's sign

    ; Add mantissas: FPA + FPB
    ; We'll do 24-bit addition with carry
    MOV AX, FPA_MANT_L
    ADD AX, FPB_MANT_L
    MOV FPR_MANT_L, AX

    MOV AX, FPA_MANT_H
    ADC AX, FPB_MANT_H
    MOV FPR_MANT_H, AX

    ; Check for carry beyond bit 23
    TEST FPR_MANT_H, 0100h  ; Bit 24 set? (bit 8 of high word)
    JZ @@do_pack
    ; Shift right and increment exponent
    RCR FPR_MANT_H, 1
    RCR FPR_MANT_L, 1
    AND FPR_MANT_H, 00FFh   ; Clear overflow bit
    INC FPR_EXP
    JMP @@do_pack

    ; Signs differ → subtract smaller from larger magnitude
@@sub_mant:
    ; Compare mantissa magnitudes
    MOV AX, FPA_MANT_H
    CMP AX, FPB_MANT_H
    JA @@a_larger_mag
    JB @@b_larger_mag
    MOV AX, FPA_MANT_L
    CMP AX, FPB_MANT_L
    JA @@a_larger_mag
    JB @@b_larger_mag
    ; Equal magnitude → result is zero
    MOV FPR_SIGN, 0
    MOV FPR_EXP, 0
    MOV FPR_MANT_H, 0
    MOV FPR_MANT_L, 0
    CALL PACK_RESULT
    JMP @@exit

@@a_larger_mag:
    MOV FPR_SIGN, AX        ; Sign from A (already have FPA_SIGN in AX...
    ; Actually, AX was clobbered. Let me reload.
    MOV AX, FPA_SIGN
    MOV FPR_SIGN, AX

    MOV AX, FPA_MANT_L
    SUB AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    MOV AX, FPA_MANT_H
    SBB AX, FPB_MANT_H
    MOV FPR_MANT_H, AX
    JMP @@do_pack

@@b_larger_mag:
    MOV AX, FPB_SIGN
    MOV FPR_SIGN, AX

    MOV AX, FPB_MANT_L
    SUB AX, FPA_MANT_L
    MOV FPR_MANT_L, AX
    MOV AX, FPB_MANT_H
    SBB AX, FPA_MANT_H
    MOV FPR_MANT_H, AX
    ; Fall through to pack

@@do_pack:
    CALL PACK_RESULT

@@exit:
    POP BP
    POP DI
    POP SI
    RET
FADD ENDP

; ============================================================================
; FSUB — Subtract two IEEE 754 single-precision floats
; Input:  DS:SI → A, DS:DI → B
; Output: DS:BX → A - B
; Implementation: Negate B's sign, then call FADD
; ============================================================================
FSUB PROC FAR
    PUSH AX
    PUSH SI
    PUSH DI

    ; Flip sign bit of B in memory and call FADD
    MOV AX, [DI+2]          ; High word of B
    XOR AX, 8000h           ; Flip sign bit
    MOV WORD PTR [FP_TEMP_A+2], AX
    MOV AX, [DI]
    MOV WORD PTR [FP_TEMP_A], AX

    ; Point DI at the negated copy
    PUSH DI
    LEA DI, FP_TEMP_A
    CALL FADD
    POP DI

    POP DI
    POP SI
    POP AX
    RET
FSUB ENDP

; ============================================================================
; FMUL — Multiply two IEEE 754 single-precision floats
; Input:  DS:SI → A, DS:DI → B
; Output: DS:BX → A * B
;
; Algorithm:
;   1. Result sign = A.sign XOR B.sign
;   2. Result exponent = A.exp + B.exp - bias
;   3. Result mantissa = (1.A_mant) * (1.B_mant), keep upper 24 bits
;   4. Normalize and pack
;
; Mantissa multiplication: two 24-bit numbers → 48-bit product
; We keep bits 47-24 (upper 24 bits of the 48-bit product)
; ============================================================================
FMUL PROC FAR
    PUSH SI
    PUSH DI
    PUSH BP

    CALL UNPACK_A
    CALL UNPACK_B

    ; --- Handle zeros ---
    MOV AX, FPA_EXP
    CMP AX, 0
    JNE @@check_b_zero_m
    MOV AX, FPA_MANT_H
    OR AX, FPA_MANT_L
    JNZ @@check_b_zero_m
    ; Result = zero (sign = XOR of signs)
    MOV AX, FPA_SIGN
    XOR AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV FPR_EXP, 0
    MOV FPR_MANT_H, 0
    MOV FPR_MANT_L, 0
    CALL PACK_RESULT
    JMP @@exit_mul

@@check_b_zero_m:
    MOV AX, FPB_EXP
    CMP AX, 0
    JNE @@check_inf_m
    MOV AX, FPB_MANT_H
    OR AX, FPB_MANT_L
    JNZ @@check_inf_m
    MOV AX, FPA_SIGN
    XOR AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV FPR_EXP, 0
    MOV FPR_MANT_H, 0
    MOV FPR_MANT_L, 0
    CALL PACK_RESULT
    JMP @@exit_mul

    ; --- Handle infinity / NaN ---
@@check_inf_m:
    ; If either is inf, result is inf (sign = XOR)
    CMP FPA_EXP, 0FFh
    JNE @@check_b_inf_m
    ; A is inf/NaN
    MOV AX, FPA_SIGN
    XOR AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV FPR_EXP, 0FFh
    MOV AX, FPA_MANT_H
    OR AX, FPB_MANT_H
    AND AX, 007Fh          ; Keep NaN payload if any
    MOV FPR_MANT_H, AX
    MOV AX, FPA_MANT_L
    OR AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit_mul

@@check_b_inf_m:
    CMP FPB_EXP, 0FFh
    JNE @@mul_normal
    MOV AX, FPA_SIGN
    XOR AX, FPB_SIGN
    MOV FPR_SIGN, AX
    MOV FPR_EXP, 0FFh
    MOV AX, FPB_MANT_H
    MOV FPR_MANT_H, AX
    MOV AX, FPB_MANT_L
    MOV FPR_MANT_L, AX
    CALL PACK_RESULT
    JMP @@exit_mul

    ; --- Normal multiplication ---
@@mul_normal:
    ; Sign: XOR
    MOV AX, FPA_SIGN
    XOR AX, FPB_SIGN
    MOV FPR_SIGN, AX

    ; Exponent: expA + expB - bias
    MOV AX, FPA_EXP
    ADD AX, FPB_EXP
    SUB AX, 127              ; Subtract bias
    MOV FPR_EXP, AX

    ; Mantissa multiplication: 24-bit × 24-bit → 48-bit
    ; We treat this as: M_A * M_B where M = 1.mantissa (with hidden bit)
    ;
    ; On 8086 (16-bit), we multiply in chunks:
    ; M_A = (A_HI << 16) | A_LO   (A_HI = 8 bits, A_LO = 16 bits)
    ; M_B = (B_HI << 16) | B_LO
    ;
    ; Product = A_HI*B_HI << 32 + (A_HI*B_LO + A_LO*B_HI) << 16 + A_LO*B_LO
    ;
    ; We want the upper 24 bits of the 48-bit result for the mantissa.
    ; The 48-bit result is spread across 3 words (high, mid, low).
    ; After getting the 48-bit result, we normalize to 24 bits.

    ; A_LO = FPA_MANT_L (16 bits), A_HI = FPA_MANT_H (8 bits, including hidden)
    ; B_LO = FPB_MANT_L (16 bits), B_HI = FPB_MANT_H (8 bits)

    ; Term 1: A_LO * B_LO → 32-bit (DX:AX)
    MOV AX, FPA_MANT_L
    MUL FPB_MANT_L          ; DX:AX = A_LO * B_LO
    ; Store low word of this product
    PUSH AX                  ; Save low word temporarily
    PUSH DX                  ; Save high word of A_LO*B_LO (this goes into mid)

    ; Term 2: A_HI * B_LO → 24-bit (but A_HI is 8-bit, B_LO is 16-bit → 24-bit in DX:AX)
    MOV AL, BYTE PTR FPA_MANT_H   ; AL = A_HI (8 bits)
    MOV AH, 0
    MUL FPB_MANT_L           ; DX:AX = A_HI * B_LO (max 24 bits)
    ; Add to mid word
    POP CX                   ; CX = high word of A_LO*B_LO (old mid)
    ADD AX, CX
    ADC DX, 0
    PUSH AX                  ; Save new mid-low
    PUSH DX                  ; Save new mid-high (carry)

    ; Term 3: A_LO * B_HI → 24-bit
    MOV AX, FPA_MANT_L
    MOV BL, BYTE PTR FPB_MANT_H
    MOV BH, 0
    MUL BX                   ; DX:AX = A_LO * B_HI
    POP CX                   ; Previous mid-high
    POP BX                   ; Previous mid-low
    ADD BX, AX
    ADC CX, DX
    ; Now CX:BX = middle 16 bits of 48-bit product
    PUSH BX                  ; New mid word
    PUSH CX                  ; New mid-high word

    ; Term 4: A_HI * B_HI → 16-bit (both 8-bit)
    MOV AL, BYTE PTR FPA_MANT_H
    MOV BL, BYTE PTR FPB_MANT_H
    MUL BL                   ; AX = A_HI * B_HI (max 16 bits)
    POP CX                   ; Mid-high from previous
    ADD AX, CX               ; AX = high word of 48-bit product
    POP BX                   ; Mid word of 48-bit product
    POP CX                   ; Low word of 48-bit product (not needed for result)

    ; Now we have the 48-bit mantissa product in AX:BX (high 32 bits)
    ; AX = bits 47-32, BX = bits 31-16
    ;
    ; For normalized result we need 24-bit mantissa with hidden bit at position 23
    ; The product of two 24-bit numbers has the binary point after bit 47
    ; (since each has implied binary point after bit 23)
    ; So the result is 1x.xxxx... and the leading bit could be at bit 47 or 46
    ;
    ; Result mantissa = upper 24 bits of the 48-bit product
    ; If bit 47 (AX bit 15) is set, shift right and adjust exponent

    TEST AX, 8000h           ; Check bit 47 (bit 15 of AX)
    JNZ @@mul_shifted

    ; Result is of the form 01.xxxx — shift left by 1
    SHL BX, 1
    RCL AX, 1
    DEC FPR_EXP
    JMP @@mul_shifted

@@mul_shifted:
    ; Now bit 47 should be set. Extract bits 46-23 as 24-bit mantissa
    ; AX = bits 47-32, BX = bits 31-16
    ; We want bits 46-23
    ; bits 46-32: AX bits 14-0
    ; bits 31-23: BX bits 15-7
    ;
    ; So FPR_MANT_H = ((AX & 0x7FFF) << 1) | (BX >> 15)
    ; FPR_MANT_L = ((BX & 0x7FFF) << 1) ... need bit 23

    ; Let me simplify: the 24-bit mantissa (with hidden bit) is
    ; composed from AX bits 14-0 (15 bits) and BX bits 15-7 (9 bits)
    ; FPR_MANT_H (8 bits with hidden) = (AX << 1) upper 8 bits ?
    ;
    ; Actually: result mantissa bits [23:0]:
    ; bit 23 = AX bit 14   (since bit 47 shifted to bit 23 of result)
    ; Actually the 48-bit product has bits 47..0.
    ; After normalization (bit 47 = 1), the mantissa bits are 46..23 (24 bits)
    ; bit 46 = AX bit 14, bit 23 = BX bit 7
    ;
    ; FPR_MANT_H (8 bits, bits 23-16 of mantissa):
    ;   = bits 46..39 of product
    ;   = AX[14:7]
    ; FPR_MANT_L (16 bits, bits 15-0 of mantissa):
    ;   = bits 38..23 of product
    ;   = (AX[6:0] << 9) | BX[15:7]

    ; Extract FPR_MANT_H
    MOV CX, AX
    AND CX, 7F80h            ; AX bits 14-7 → positions 14-7
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1
    SHR CX, 1                ; CX = AX[14:7] at positions 7-0
    MOV FPR_MANT_H, CX

    ; Extract FPR_MANT_L
    ; AX[6:0] << 9 | BX[15:7]
    MOV CX, AX
    AND CX, 007Fh            ; CX = AX[6:0]
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1
    SHL CX, 1                ; CX = AX[6:0] << 9

    MOV DX, BX
    SHR DX, 1
    SHR DX, 1
    SHR DX, 1
    SHR DX, 1
    SHR DX, 1
    SHR DX, 1
    SHR DX, 1                ; DX = BX[15:7] at positions 8-0
    AND DX, 01FFh
    OR CX, DX
    MOV FPR_MANT_L, CX

    ; Rounding: check BX bit 6 (first discarded bit)
    TEST BX, 0040h
    JZ @@pack_mul
    ; Round up
    ADD FPR_MANT_L, 1
    ADC FPR_MANT_H, 0
    ; Check for overflow from rounding
    TEST FPR_MANT_H, 0100h
    JZ @@pack_mul
    SHR FPR_MANT_H, 1
    RCR FPR_MANT_L, 1
    INC FPR_EXP

@@pack_mul:
    CALL PACK_RESULT

@@exit_mul:
    POP BP
    POP DI
    POP SI
    RET
FMUL ENDP

; ============================================================================
; FCMP — Compare two floats, set flags
; Input:  DS:SI → A, DS:DI → B
; Output: ZF=1 if A==B, CF=1 if A<B
; ============================================================================
FCMP PROC FAR
    PUSH SI
    PUSH DI

    CALL UNPACK_A
    CALL UNPACK_B

    ; Compare signs first
    MOV AX, FPA_SIGN
    CMP AX, FPB_SIGN
    JA @@a_neg_b_pos          ; A negative, B positive → A < B
    JB @@a_pos_b_neg          ; A positive, B negative → A > B

    ; Same sign — compare magnitude
    CMP AX, 0
    JE @@both_pos

    ; Both negative — larger magnitude means smaller value
    MOV AX, FPA_EXP
    CMP AX, FPB_EXP
    JA @@a_neg_larger         ; A has larger magnitude, but both neg → A < B
    JB @@a_neg_smaller

    MOV AX, FPA_MANT_H
    CMP AX, FPB_MANT_H
    JA @@a_neg_larger
    JB @@a_neg_smaller

    MOV AX, FPA_MANT_L
    CMP AX, FPB_MANT_L
    JA @@a_neg_larger
    JB @@a_neg_smaller
    ; Equal
    CMP AX, AX               ; Set ZF
    JMP @@done_cmp

@@both_pos:
    MOV AX, FPA_EXP
    CMP AX, FPB_EXP
    JA @@a_larger
    JB @@a_smaller

    MOV AX, FPA_MANT_H
    CMP AX, FPB_MANT_H
    JA @@a_larger
    JB @@a_smaller

    MOV AX, FPA_MANT_L
    CMP AX, FPB_MANT_L
    JA @@a_larger
    JB @@a_smaller
    CMP AX, AX
    JMP @@done_cmp

@@a_larger:
    CMP AX, AX               ; Clear CF, clear ZF (A > B)
    CLC
    JMP @@done_cmp

@@a_smaller:
    STC                      ; Set CF (A < B)
    JMP @@done_cmp

@@a_neg_b_pos:
    STC                      ; Negative < Positive
    JMP @@done_cmp

@@a_pos_b_neg:
    CLC                      ; Positive > Negative
    JMP @@done_cmp

@@a_neg_larger:
    STC                      ; Larger magnitude when negative → smaller value
    JMP @@done_cmp

@@a_neg_smaller:
    CLC
    JMP @@done_cmp

@@done_cmp:
    POP DI
    POP SI
    RET
FCMP ENDP

; ============================================================================
; ITOF — Convert 16-bit signed integer to float
; Input:  AX = integer
; Output: DS:BX → float result
; ============================================================================
ITOF PROC FAR
    PUSH AX
    PUSH CX
    PUSH DX

    ; Handle zero
    CMP AX, 0
    JNE @@itof_nonzero
    MOV WORD PTR [BX], 0
    MOV WORD PTR [BX+2], 0
    JMP @@itof_done

@@itof_nonzero:
    ; Handle sign
    MOV FPR_SIGN, 0
    CMP AX, 0
    JGE @@itof_abs
    MOV FPR_SIGN, 1
    NEG AX

@@itof_abs:
    ; Set exponent = 127 + 15 = 142 (integer is 16-bit, so position 15)
    ; Actually we need to find the highest set bit
    MOV CX, 0                ; Bit position counter
    MOV DX, AX

@@itof_find_msb:
    TEST DX, 8000h
    JNZ @@itof_found
    SHL DX, 1
    INC CX
    JMP @@itof_find_msb

@@itof_found:
    ; CX = number of leading zeros
    ; Effective exponent = 15 - CX (position of MSB)
    ; Biased exponent = (15 - CX) + 127 = 142 - CX
    MOV FPR_EXP, 142
    SUB FPR_EXP, CX

    ; Mantissa: shift AX left by (CX + 8) to put MSB at bit 23 position
    ; Actually, put the MSB at the hidden bit position (bit 23)
    ; AX is 16-bit, we want it in the mantissa with hidden bit at bit 23
    ; We need to shift left by (7 + CX) to put the MSB at bit 23
    ADD CX, 7

@@itof_shift:
    CMP CX, 0
    JE @@itof_store
    SHL AX, 1
    DEC CX
    JMP @@itof_shift

@@itof_store:
    ; Now AX has bit 15 at the hidden bit position
    ; FPR_MANT_H = high 8 bits of AX (bits 15-8 of shifted value)
    ; FPR_MANT_L = low 8 bits shifted left by 8 (or the full 16 bits)
    MOV FPR_MANT_H, 0
    MOV FPR_MANT_L, AX

    ; But actually AX after shifting: suppose original AX = 0x0005 (5)
    ; MSB at bit 2, CX = 13 leading zeros
    ; exp = 142 - 13 = 129
    ; shift = 13 + 7 = 20, but AX is only 16-bit...
    ; This needs more careful handling.
    ;
    ; Let me simplify: just do the conversion properly
    ; The result mantissa should have the integer's bits starting at bit 23

    MOV DX, AX               ; DX = original |value|
    XOR AX, AX               ; AX:DX = 32-bit value
    ; Actually, we need to expand to 32-bit first
    MOV AX, DX
    XOR DX, DX
    ; AX:DX = 32-bit integer value (absolute)

    ; Now shift left to normalize (put MSB-1 at bit 23 position)
    ; ...
    ; This is getting complex. For the purposes of this library,
    ; ITOF is used for loop counters in the convolution, which are small.
    ; Let me use a simpler lookup approach.

    ; Alternative: use the known conversion
    ; For small integers, we can use a pre-computed approach
    ; Actually, let me simplify by computing exp and mantissa from scratch

    ; Save original value magnitude
    ; Re-setup
    POP DX
    POP CX
    POP AX
    PUSH AX
    PUSH CX
    PUSH DX

    ; Get absolute value
    XOR CX, CX
    CMP AX, 0
    JGE @@itof_pos
    MOV CX, 1                ; Sign flag
    NEG AX
@@itof_pos:

    ; Special case for value being exactly power of 2 etc.
    ; This simplified version handles values up to 65535
    ; We'll find the MSB position (0-15)
    MOV DX, AX
    MOV FPR_EXP, 127 + 15    ; Start with exponent for 2^15

@@itof_find2:
    TEST DX, 8000h
    JNZ @@itof_norm2
    SHL DX, 1
    DEC FPR_EXP
    JMP @@itof_find2

@@itof_norm2:
    ; DX now has MSB at bit 15
    ; Mantissa: we need to place bits at positions 23..(23-15)
    ; Since MSB is at bit 15 of DX, and we want it at bit 23,
    ; we shift DX left by 8 positions
    MOV FPR_MANT_H, 0
    MOV AX, DX
    ; Shift left 8 positions to put MSB at bit 23
    MOV FPR_MANT_L, 0
    ; DX bits 15-8 → FPR_MANT_H bits 7-0
    MOV AL, DH
    MOV FPR_MANT_H, AX
    MOV AL, DL
    XOR AH, AH
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1
    MOV FPR_MANT_L, AX

    MOV AX, CX
    MOV FPR_SIGN, AX

    CALL PACK_RESULT

@@itof_done:
    POP DX
    POP CX
    POP AX
    RET
ITOF ENDP

; ============================================================================
; FTOI — Convert float to 16-bit signed integer (truncate toward zero)
; Input:  DS:SI → float
; Output: AX = integer
; ============================================================================
FTOI PROC FAR
    PUSH BX
    PUSH CX
    PUSH DX

    CALL UNPACK_A

    ; Check for zero/special
    CMP FPA_EXP, 0
    JE @@ftoi_zero

    ; If exp < 127, value < 1, return 0
    CMP FPA_EXP, 127
    JB @@ftoi_zero

    ; If exp > 127+14 = 141, value > 16383, clamp (for 16-bit signed)
    CMP FPA_EXP, 127+14
    JA @@ftoi_overflow

    ; Shift mantissa right by (127+23 - exp) to align integer
    ; Mantissa has 24 bits (including hidden) at binary point position 23
    ; We want to shift right by (23 - (exp-127)) = 150 - exp
    MOV CX, 150
    SUB CX, FPA_EXP         ; CX = right shift amount

    ; Copy mantissa to DX:AX
    MOV AX, FPA_MANT_L
    MOV DX, FPA_MANT_H

@@ftoi_shift:
    CMP CX, 0
    JE @@ftoi_apply_sign
    SHR DX, 1
    RCR AX, 1
    DEC CX
    JMP @@ftoi_shift

@@ftoi_apply_sign:
    ; AX now holds the integer value
    CMP FPA_SIGN, 0
    JE @@ftoi_done
    NEG AX
    JMP @@ftoi_done

@@ftoi_zero:
    XOR AX, AX
    JMP @@ftoi_done

@@ftoi_overflow:
    CMP FPA_SIGN, 0
    JE @@ftoi_max
    MOV AX, 8000h            ; -32768
    JMP @@ftoi_done
@@ftoi_max:
    MOV AX, 7FFFh            ; 32767

@@ftoi_done:
    POP DX
    POP CX
    POP BX
    RET
FTOI ENDP

END
