; ============================================================
;  GRADE DETERMINER v1.0  -  emu8086 Assembly
;  Converts Score (0-100, floating-point) to Grade (A-D)
;  Grade Rules:
;    A: Score >= 90
;    B: 75 <= Score < 90
;    C: 60 <= Score < 75
;    D: Score < 60
;  Error Handling: Score > 100 or Score < 0
; ============================================================

#make_COM#
org 100h

jmp main

; ===== DATA SECTION =====

; ---- UI Title ----
title_msg    db 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |        GRADE  DETERMINER  v1.0           |', 0dh, 0ah
             db '  |        Score (0-100) --> Grade (A-D)     |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

prompt_msg   db 0dh, 0ah
             db '  Please enter score (e.g. 89.5, 100, 74.0): $'

; ---- Result Messages ----
result_a     db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |    Grade: A   (Score >= 90)              |', 0dh, 0ah
             db '  |    Excellent! Keep up the great work!    |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

result_b     db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |    Grade: B   (75 <= Score < 90)        |', 0dh, 0ah
             db '  |    Good! Solid performance!              |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

result_c     db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |    Grade: C   (60 <= Score < 75)        |', 0dh, 0ah
             db '  |    Pass. Room for improvement.           |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

result_d     db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |    Grade: D   (Score < 60)              |', 0dh, 0ah
             db '  |    Fail. More effort needed!             |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

; ---- Error Messages ----
err_too_high db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |  ERROR: Score cannot exceed 100!         |', 0dh, 0ah
             db '  |  Please enter a value between 0 and 100. |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

err_negative db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |  ERROR: Score cannot be negative!        |', 0dh, 0ah
             db '  |  Please enter a value between 0 and 100. |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

err_invalid  db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |  ERROR: Invalid input format!            |', 0dh, 0ah
             db '  |  Please enter a number like 89.5 or 100. |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

again_msg    db 0dh, 0ah
             db '  Try again? (Y/N): $'

goodbye_msg  db 0dh, 0ah, 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  |      Thank you for using the             |', 0dh, 0ah
             db '  |      Grade Determiner. Goodbye!           |', 0dh, 0ah
             db '  |                                          |', 0dh, 0ah
             db '  +==========================================+', 0dh, 0ah
             db '$'

; ---- Input Buffer (INT 21h / AH=0Ah) ----
buf_max      db 12           ; max characters to read
buf_len      db 0            ; actual length read
buf_data     db 12 dup(0)    ; input characters

; ---- Working Variables ----
score_val    dw 0            ; score * 10 (e.g. 89.5 -> 895)

; ============================================================
;  MAIN PROGRAM
; ============================================================
main proc
    ; ---- Display Title Screen ----
    mov ah, 09h
    mov dx, offset title_msg
    int 21h

    ; ---- Prompt and Read Input ----
    mov ah, 09h
    mov dx, offset prompt_msg
    int 21h

    ; Read buffered input
    mov ah, 0ah
    mov dx, offset buf_max
    int 21h

    ; ---- Parse Input String ----
    call parse_score

    ; AX = score*10 on success, AX = 0FFFFh on error
    cmp ax, 0ffffh
    je show_invalid

    ; ---- Range Validation ----
    ; Check > 100.0 (i.e. > 1000)
    cmp ax, 1000
    ja show_too_high

    ; Check = 0 exactly -- valid
    ; (negative already caught by parse_score returning FFFFh)

    mov [score_val], ax

    ; ---- Grade Determination ----
    cmp ax, 900            ; >= 90.0 ?
    jae show_a

    cmp ax, 750            ; >= 75.0 ?
    jae show_b

    cmp ax, 600            ; >= 60.0 ?
    jae show_c

    jmp show_d             ; < 60.0

    ; ---- Display Results ----
show_a:
    mov ah, 09h
    mov dx, offset result_a
    int 21h
    jmp ask_again

show_b:
    mov ah, 09h
    mov dx, offset result_b
    int 21h
    jmp ask_again

show_c:
    mov ah, 09h
    mov dx, offset result_c
    int 21h
    jmp ask_again

show_d:
    mov ah, 09h
    mov dx, offset result_d
    int 21h
    jmp ask_again

show_too_high:
    mov ah, 09h
    mov dx, offset err_too_high
    int 21h
    jmp ask_again

show_invalid:
    ; Check if buffer starts with '-' (negative)
    mov al, [buf_data]
    cmp al, '-'
    je show_negative
    mov ah, 09h
    mov dx, offset err_invalid
    int 21h
    jmp ask_again

show_negative:
    mov ah, 09h
    mov dx, offset err_negative
    int 21h

    ; ---- Ask to Try Again ----
ask_again:
    mov ah, 09h
    mov dx, offset again_msg
    int 21h

    ; Read a single character
    mov ah, 08h
    int 21h

    ; Echo it
    mov ah, 02h
    mov dl, al
    int 21h

    ; Check Y/y
    cmp al, 'Y'
    je restart
    cmp al, 'y'
    je restart

    ; Anything else -> exit
    jmp exit_prog

restart:
    ; Reset variables for fresh run
    mov [score_val], 0
    mov [buf_len], 0
    mov cx, 12
    mov si, offset buf_data
clear_buf:
    mov byte ptr [si], 0
    inc si
    loop clear_buf
    jmp main

    ; ---- Exit Program ----
exit_prog:
    mov ah, 09h
    mov dx, offset goodbye_msg
    int 21h

    ; Wait for keypress
    mov ah, 08h
    int 21h

    ; Terminate
    mov ah, 4ch
    int 21h
    ret
main endp

; ============================================================
;  PARSE SCORE SUBROUTINE
;  Input:  buf_data (string), buf_len (length)
;  Output: AX = score * 10  (e.g. "89.5" -> 895)
;          AX = 0FFFFh on error
; ============================================================
parse_score proc
    push bx
    push cx
    push dx
    push si
    push di

    mov cl, [buf_len]
    cmp cl, 0
    je ps_error              ; empty input

    mov si, offset buf_data

    ; ---- Check for negative sign ----
    mov al, [si]
    cmp al, '-'
    je ps_error              ; negative score -> return error

    ; ---- Initialize accumulators ----
    xor di, di               ; DI = integer part
    mov bh, 0                ; BH = state: 0=int, 1=after '.', 2=frac done
    xor bl, bl               ; BL = fractional digit

    ; ---- Main parse loop ----
ps_loop:
    cmp cl, 0
    je ps_calc_result        ; end of input

    mov al, [si]

    ; Check for decimal point
    cmp al, '.'
    jne ps_check_digit

    cmp bh, 0
    jne ps_error             ; two decimal points -> error
    mov bh, 1                ; decimal point seen
    inc si
    dec cl
    jmp ps_loop

ps_check_digit:
    cmp al, '0'
    jb ps_error
    cmp al, '9'
    ja ps_error

    sub al, '0'
    mov ah, 0                ; AX = digit value (0-9)

    cmp bh, 0
    jne ps_frac_digit

    ; ---- Integer part digit ----
    cmp di, 100
    ja ps_error              ; integer part > 100 would overflow

    ; DI = DI * 10 + digit
    push ax                  ; save digit
    mov ax, di
    mov dx, 10
    mul dx                   ; AX = DI * 10 (DX ignored, result < 1000)
    mov di, ax
    pop ax                   ; restore digit
    add di, ax

    inc si
    dec cl
    jmp ps_loop

ps_frac_digit:
    ; ---- Fractional digit ----
    cmp bh, 2
    je ps_error              ; more than 1 fractional digit -> error
    mov bl, al               ; store fractional digit
    mov bh, 2                ; mark fractional digit stored
    inc si
    dec cl
    jmp ps_loop

    ; ---- Calculate final value ----
ps_calc_result:
    ; Total = integer_part * 10 + fractional_digit
    mov ax, di
    mov dx, 10
    mul dx                   ; AX = DI * 10
    cmp dx, 0
    jne ps_error             ; overflow (shouldn't happen with our checks)
    add al, bl               ; add fractional digit
    adc ah, 0

    ; Final bounds check (> 100.0 is invalid)
    cmp ax, 1000
    ja ps_error

    jmp ps_ret

ps_error:
    mov ax, 0ffffh

ps_ret:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret
parse_score endp
