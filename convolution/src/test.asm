; ============================================================================
; test.asm — emu8086 Test Harness for Complex Convolution
; ============================================================================
; Tests the convolution with small known inputs.
; Results written to memory at known location for verification.
;
; To run in emu8086:
;   1. Load float32.asm, complex.asm, conv.asm, test.asm
;   2. Assemble and run
;   3. Examine memory at TEST_RESULT to verify against MATLAB golden values
;
; Test case: N=4, M=3 complex signal and kernel
; ============================================================================

.MODEL SMALL
.STACK 100h

EXTERN CONV:FAR

.DATA
    ; --- Test input: Signal S (4 complex numbers) ---
    ; Values from MATLAB (rng(99), randn):
    ; These are IEEE 754 single-precision encoded as hex
    TEST_S:
    ; S[0] = -0.1253 + 0.2877i
    DD 0BE004E00h     ; real: -0.1253...
    DD 3E935000h      ; imag: 0.2877...
    ; S[1] = -1.1465 - 1.1909i
    DD 0BF92B000h     ; real: -1.1465...
    DD 0BF986000h     ; imag: -1.1909...
    ; S[2] = 1.1892 + 0.0376i
    DD 3F983000h      ; real: 1.1892...
    DD 3D1A0000h      ; imag: 0.0376...
    ; S[3] = -0.0376 + 0.3273i
    DD 0BD1A0000h     ; real: -0.0376...
    DD 3EA79000h      ; imag: 0.3273...

    ; --- Test input: Kernel K (3 complex numbers) ---
    TEST_K:
    ; K[0] = 0.1746 + 1.1892i
    DD 3E32D000h      ; real: 0.1746...
    DD 3F983000h      ; imag: 1.1892...
    ; K[1] = 1.1909 - 0.1867i
    DD 3F986000h      ; real: 1.1909...
    DD 0BE3F000h      ; imag: -0.1867...
    ; K[2] = 2.1832 - 0.1364i
    DD 400BB000h      ; real: 2.1832...
    DD 0BE0BC00h      ; imag: -0.1364...

    ; --- Output buffer: Y (4+3-1 = 6 complex numbers, 48 bytes) ---
    TEST_RESULT:
    DD 0,0,0,0,0,0,0,0,0,0,0,0   ; 12 DWORDs = 48 bytes = 6 complex

    ; --- String messages ---
    MSG_START   DB 'emu8086 Complex Convolution Test', 0Dh, 0Ah, '$'
    MSG_DONE    DB 'Convolution complete.', 0Dh, 0Ah, '$'
    MSG_CHECK   DB 'Check memory at TEST_RESULT for output.', 0Dh, 0Ah, '$'
    MSG_N       DB 'N=4, M=3, YLEN=6', 0Dh, 0Ah, '$'

.CODE
MAIN PROC FAR
    MOV AX, @DATA
    MOV DS, AX
    MOV ES, AX

    ; --- Print start message ---
    LEA DX, MSG_START
    MOV AH, 09h
    INT 21h

    LEA DX, MSG_N
    MOV AH, 09h
    INT 21h

    ; --- Setup CONV parameters ---
    LEA SI, TEST_S          ; DS:SI → S signal
    LEA DI, TEST_K          ; DS:DI → K kernel
    MOV CX, 4               ; N = 4
    MOV DX, 3               ; M = 3
    LEA BX, TEST_RESULT     ; ES:BX → Y output

    ; --- Call convolution ---
    CALL CONV

    ; --- Print done message ---
    LEA DX, MSG_DONE
    MOV AH, 09h
    INT 21h

    LEA DX, MSG_CHECK
    MOV AH, 09h
    INT 21h

    ; --- Print hex dump of result (simplified) ---
    ; For emu8086, user can inspect memory window at TEST_RESULT
    ; We print a simple hex dump via INT 21h

    LEA SI, TEST_RESULT
    MOV CX, 48               ; 48 bytes = 6 complex * 8 bytes

@@dump_loop:
    MOV DL, [SI]
    MOV AH, 02h
    ; Print each byte as hex (simplified: just raw bytes)
    ; In real emu8086, user would use the memory dump feature
    INC SI
    LOOP @@dump_loop

    ; --- Exit ---
    MOV AH, 4Ch
    INT 21h
MAIN ENDP

END MAIN
