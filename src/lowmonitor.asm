; ============================================================================
; LowMonitor - Diagnostico y monitorizacion de hardware (x86-64, Linux, NASM)
; Universidad Mariano Galvez - Proyecto del curso
; ----------------------------------------------------------------------------
; Modulo 1: Identificacion del CPU (CPUID)         [IMPLEMENTADO]
; Modulo 2: Monitor de puertos E/S                 [IMPLEMENTADO]
; Modulo 3: Diagnostico de memoria                 [IMPLEMENTADO]
; Modulo 4: Monitor de rendimiento (RDTSC)         [IMPLEMENTADO]
; Modulo 5: Jerarquia de memoria                   [IMPLEMENTADO]
; Modulo 6: SIMD (bonus)                           [IMPLEMENTADO]
; Ensamblar: make      Ejecutar: ./lowmonitor
; ============================================================================
default rel

%define SYS_WRITE 1
%define SYS_EXIT  60
%define STDOUT    1

; Imprime una cadena terminada en 0 ubicada en la etiqueta %1
%macro PRINT 1
    lea rsi, [%1]
    call print_cstr
%endmacro

; Si el bit %2 del registro %1 esta activo, imprime la cadena %3
%macro FEAT 3
    bt %1, %2
    jnc %%skip
    PRINT %3
%%skip:
%endmacro

section .data
    banner      db "=== LowMonitor ===", 10, 10, 0
    h_mod1      db "[Modulo 1] Identificacion del CPU", 10, 0
    l_vendor    db "Fabricante   : ", 0
    l_brand     db "Procesador   : ", 0
    l_arch      db "Arquitectura : x86_64", 10, 0
    l_family    db "Familia      : ", 0
    l_model     db "Modelo       : ", 0
    l_step      db "Stepping     : ", 0
    l_ext       db "Extensiones  : ", 0
    l_avxos     db "AVX usable (SO habilita YMM): ", 0
    l_avx5os    db "AVX-512 usable (SO habilita ZMM): ", 0
    s_yes       db "Si", 10, 0
    s_no        db "No", 10, 0
    s_unknown   db "(no disponible)", 0
    nl          db 10, 0
    ; nombres de extensiones (con espacio al final)
    f_sse       db "SSE ", 0
    f_sse2      db "SSE2 ", 0
    f_sse41     db "SSE4.1 ", 0
    f_sse42     db "SSE4.2 ", 0
    f_avx       db "AVX ", 0
    f_avx2      db "AVX2 ", 0
    f_avx512    db "AVX-512F ", 0

section .bss
    vendor      resb 13         ; 12 chars + 0
    brand       resb 49         ; 48 chars + 0
    numbuf      resb 24         ; conversion decimal
    has_avx2    resb 1
    has_avx512  resb 1
    recover_rip resq 1          ; destino de recuperacion tras #GP (modulo 2)
    act         resq 4          ; struct sigaction del kernel
    l1_size     resq 1
    l2_size     resq 1
    l3_size     resq 1

section .text
    global _start

_start:
    PRINT banner
    PRINT h_mod1
    call modulo1_cpu
    PRINT nl
    call modulo2_io
    PRINT nl
    call modulo3_mem
    PRINT nl
    call modulo4_perf
    PRINT nl
    call modulo5_hier
    PRINT nl
    call modulo6_simd
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

; ----------------------------------------------------------------------------
; Modulo 1: CPUID. Usa r15d=hoja max, r12d=ECX(1), r13d=EDX(1),
;           r14d=EBX(7,0), ebp=XCR0 (bajo)
; ----------------------------------------------------------------------------
modulo1_cpu:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    ; --- hoja 0: fabricante y hoja maxima ---
    xor eax, eax
    cpuid
    mov r15d, eax
    mov [vendor],   ebx
    mov [vendor+4], edx         ; el orden es EBX, EDX, ECX
    mov [vendor+8], ecx
    PRINT l_vendor
    PRINT vendor
    PRINT nl

    ; --- hojas 0x80000002..4: nombre comercial ---
    PRINT l_brand
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .no_brand
    lea rdi, [brand]
    mov r9d, 0x80000002
.brand_loop:
    mov eax, r9d
    cpuid
    mov [rdi],    eax
    mov [rdi+4],  ebx
    mov [rdi+8],  ecx
    mov [rdi+12], edx
    add rdi, 16
    inc r9d
    cmp r9d, 0x80000004
    jbe .brand_loop
    PRINT brand
    jmp .brand_done
.no_brand:
    PRINT s_unknown
.brand_done:
    PRINT nl
    PRINT l_arch

    ; --- hoja 1: familia, modelo, stepping, banderas ---
    mov eax, 1
    cpuid
    mov r10d, eax
    mov r12d, ecx
    mov r13d, edx

    ; familia = base (+ extendida si base == 0xF)
    mov ebx, r10d
    shr ebx, 8
    and ebx, 0xF
    cmp ebx, 0xF
    jne .fam_ok
    mov edx, r10d
    shr edx, 20
    and edx, 0xFF
    add ebx, edx
.fam_ok:
    PRINT l_family
    mov eax, ebx
    call print_u64
    PRINT nl

    ; modelo = base (+ extendido<<4 si familia base es 6 o 15)
    mov ecx, r10d
    shr ecx, 8
    and ecx, 0xF
    mov ebx, r10d
    shr ebx, 4
    and ebx, 0xF
    cmp ecx, 6
    je .ext_model
    cmp ecx, 0xF
    jne .model_ok
.ext_model:
    mov edx, r10d
    shr edx, 16
    and edx, 0xF
    shl edx, 4
    add ebx, edx
.model_ok:
    PRINT l_model
    mov eax, ebx
    call print_u64
    PRINT nl

    PRINT l_step
    mov eax, r10d
    and eax, 0xF
    call print_u64
    PRINT nl

    ; --- hoja 7: AVX2 / AVX-512 ---
    xor r14d, r14d
    cmp r15d, 7
    jb .no_leaf7
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov r14d, ebx
.no_leaf7:

    ; --- XGETBV: el SO debe habilitar los registros YMM/ZMM ---
    xor ebp, ebp
    bt r12d, 27                 ; OSXSAVE
    jnc .no_xsave
    xor ecx, ecx
    xgetbv
    mov ebp, eax
.no_xsave:

    ; --- lista de extensiones ---
    PRINT l_ext
    FEAT r13d, 25, f_sse
    FEAT r13d, 26, f_sse2
    FEAT r12d, 19, f_sse41
    FEAT r12d, 20, f_sse42
    FEAT r12d, 28, f_avx
    FEAT r14d, 5,  f_avx2
    FEAT r14d, 16, f_avx512
    PRINT nl

    ; AVX usable: XCR0 bits 1 (SSE) y 2 (AVX) activos
    PRINT l_avxos
    mov eax, ebp
    and eax, 0x6
    cmp eax, 0x6
    jne .avx_no
    PRINT s_yes
    jmp .avx5
.avx_no:
    PRINT s_no
.avx5:
    ; AVX-512 usable: XCR0 bits 5,6,7 ademas de 1,2
    PRINT l_avx5os
    mov eax, ebp
    and eax, 0xE6
    cmp eax, 0xE6
    jne .avx5_no
    PRINT s_yes
    jmp .done
.avx5_no:
    PRINT s_no
.done:
    PRINT nl
    ; guardar banderas "usable" para el modulo 6
    mov eax, ebp
    and eax, 0x6
    cmp eax, 0x6
    jne .flags_end
    bt r14d, 5
    jnc .chk512
    mov byte [has_avx2], 1
.chk512:
    mov eax, ebp
    and eax, 0xE6
    cmp eax, 0xE6
    jne .flags_end
    bt r14d, 16
    jnc .flags_end
    mov byte [has_avx512], 1
.flags_end:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Rutinas de salida
; ----------------------------------------------------------------------------
; print_cstr: RSI = cadena terminada en 0. Preserva todos los registros.
print_cstr:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push r11
    mov rdx, rsi
.len:
    cmp byte [rdx], 0
    je .go
    inc rdx
    jmp .len
.go:
    sub rdx, rsi                ; longitud
    mov eax, SYS_WRITE
    mov edi, STDOUT
    syscall
    pop r11
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; print_u64: RAX = numero sin signo. Imprime en decimal. Preserva registros.
print_u64:
    push rax
    push rbx
    push rdx
    push rdi
    push rsi
    lea rdi, [numbuf+23]
    mov byte [rdi], 0
    mov rbx, 10
.digit:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .digit
    mov rsi, rdi
    call print_cstr
    pop rsi
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; ============================================================================
; Utilidades comunes
; ============================================================================
; print_fixed2: RAX = valor*100 -> imprime "ent.dd". Preserva registros.
print_fixed2:
    push rax
    push rcx
    push rdx
    push rsi
    mov ecx, 100
    xor edx, edx
    div rcx                     ; rax = parte entera, rdx = decimales
    push rdx
    call print_u64
    PRINT s_dot
    pop rax
    cmp rax, 10
    jae .two
    PRINT s_zero
.two:
    call print_u64
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; print_size: RAX = bytes -> "NN KB" o "NN MB". Preserva registros.
print_size:
    push rax
    push rsi
    cmp rax, 1048576
    jb .kb
    shr rax, 20
    call print_u64
    PRINT s_mb
    jmp .out
.kb:
    shr rax, 10
    call print_u64
    PRINT s_kb
.out:
    pop rsi
    pop rax
    ret

; read_tsc: RAX = TSC serializado con LFENCE. Solo modifica RAX.
read_tsc:
    push rdx
    lfence
    rdtsc
    shl rdx, 32
    or rax, rdx
    lfence
    pop rdx
    ret

; get_ns: RAX = CLOCK_MONOTONIC_RAW en nanosegundos. Solo modifica RAX.
get_ns:
    push rdi
    push rsi
    push rcx
    push r11
    sub rsp, 16
    mov eax, 228                ; clock_gettime
    mov edi, 4                  ; CLOCK_MONOTONIC_RAW
    mov rsi, rsp
    syscall
    mov rax, [rsp]
    imul rax, rax, 1000000000
    add rax, [rsp+8]
    add rsp, 16
    pop r11
    pop rcx
    pop rsi
    pop rdi
    ret

section .data
    s_dot       db ".", 0
    s_zero      db "0", 0
    s_kb        db " KB", 0
    s_mb        db " MB", 0
    s_ok        db "[OK]", 10, 0

section .text
; ============================================================================
; MODULO 2: Monitor de puertos E/S (IN/OUT 8/16/32 bits)
; En Linux, IN/OUT en ring 3 requieren permiso (iopl/ioperm => root). Sin el,
; la CPU lanza #GP -> SIGSEGV. Se instala un manejador que redirige la
; ejecucion a una etiqueta de recuperacion y marca el error en R8D (1 = fallo).
; ============================================================================
section .data
    h_mod2      db "[Modulo 2] Monitor de puertos E/S", 10, 0
    m2_iopl_ok  db "Permiso E/S: concedido via iopl(3) (puertos 0-65535)", 10, 0
    m2_iopl_no  db "Permiso E/S: denegado (se requiere root); #GP sera capturado", 10, 0
    p60         db "Puerto 60h (teclado): ", 0
    p61         db "Puerto 61h (panel): ", 0
    p3f8        db "Puerto 3F8h (COM1): ", 0
    p80         db "Puerto 80h (POST, OUT 8/16/32): ", 0
    pffff       db "Puerto FFFFh (limite del espacio E/S): ", 0
    m2_blocked  db "[BLOQUEADO: #GP capturado, sin permiso de E/S]", 10, 0
    m2_nodev    db "[SIN DISPOSITIVO: scratch UART no responde]", 10, 0

section .text
modulo2_io:
    push rbx
    push r12
    push r13
    push r14

    PRINT h_mod2

    ; --- instalar manejador de SIGSEGV (rt_sigaction = 13) ---
    lea rax, [segv_handler]
    mov [act], rax
    mov qword [act+8], 0x04000004      ; SA_RESTORER | SA_SIGINFO
    lea rax, [segv_restorer]
    mov [act+16], rax
    mov qword [act+24], 0
    mov eax, 13
    mov edi, 11                         ; SIGSEGV
    lea rsi, [act]
    xor edx, edx
    mov r10d, 8
    syscall

    ; --- intentar obtener permiso (iopl = 172) ---
    mov eax, 172
    mov edi, 3
    syscall
    test rax, rax
    jnz .no_perm
    PRINT m2_iopl_ok
    jmp .tests
.no_perm:
    PRINT m2_iopl_no

.tests:
    ; ---- Puerto 60h: IN 8 bits ----
    PRINT p60
    mov dx, 0x60
    call io_in8
    mov r12d, r8d
    call report_status

    ; ---- Puerto 61h: IN8, OUT8 (mismo valor), IN16, IN32 ----
    PRINT p61
    xor r12d, r12d
    mov dx, 0x61
    call io_in8
    or r12d, r8d
    mov bl, al
    mov al, bl
    call io_out8
    or r12d, r8d
    call io_in16
    or r12d, r8d
    call io_in32
    or r12d, r8d
    call report_status

    ; ---- Puerto 80h: OUT 8/16/32 ----
    PRINT p80
    xor r12d, r12d
    mov dx, 0x80
    xor eax, eax
    call io_out8
    or r12d, r8d
    call io_out16
    or r12d, r8d
    call io_out32
    or r12d, r8d
    call report_status

    ; ---- COM1: registro scratch (3FFh): escribir 0xA5 y leer de vuelta ----
    PRINT p3f8
    xor r12d, r12d
    xor r14d, r14d
    mov dx, 0x3FF
    call io_in8
    or r12d, r8d
    mov r13b, al                        ; valor original
    mov al, 0xA5
    call io_out8
    or r12d, r8d
    call io_in8
    or r12d, r8d
    cmp al, 0xA5
    sete r14b
    mov al, r13b                        ; restaurar
    call io_out8
    test r12d, r12d
    jnz .com_blocked
    test r14d, r14d
    jz .com_nodev
    PRINT s_ok
    jmp .com_done
.com_blocked:
    PRINT m2_blocked
    jmp .com_done
.com_nodev:
    PRINT m2_nodev
.com_done:

    ; ---- Limite superior del espacio de E/S (direccion 65535) ----
    PRINT pffff
    mov dx, 0xFFFF
    call io_in8
    mov r12d, r8d
    call report_status

    ; --- restaurar manejador por defecto (SIG_DFL) ---
    mov qword [act], 0
    mov qword [act+8], 0
    mov qword [act+16], 0
    mov eax, 13
    mov edi, 11
    lea rsi, [act]
    xor edx, edx
    mov r10d, 8
    syscall

    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; report_status: R12D = 0 -> [OK], otro -> [BLOQUEADO]
report_status:
    test r12d, r12d
    jnz .bad
    PRINT s_ok
    ret
.bad:
    PRINT m2_blocked
    ret

; Manejador de SIGSEGV: RDX = ucontext. Cambia RIP guardado (offset 168).
segv_handler:
    mov rax, [recover_rip]
    mov [rdx+168], rax
    ret
segv_restorer:
    mov eax, 15                         ; rt_sigreturn
    syscall

; Rutinas de E/S: DX = puerto. Estado en R8D (0 = ok, 1 = #GP capturado).
io_in8:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    in al, dx
    ret
.rec:
    mov r8d, 1
    ret
io_in16:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    in ax, dx
    ret
.rec:
    mov r8d, 1
    ret
io_in32:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    in eax, dx
    ret
.rec:
    mov r8d, 1
    ret
io_out8:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    out dx, al
    ret
.rec:
    mov r8d, 1
    ret
io_out16:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    out dx, ax
    ret
.rec:
    mov r8d, 1
    ret
io_out32:
    lea r9, [.rec]
    mov [recover_rip], r9
    xor r8d, r8d
    out dx, eax
    ret
.rec:
    mov r8d, 1
    ret

; ============================================================================
; MODULO 3: Diagnostico de memoria (0xAA, 0x55, secuencia incremental)
; Optimizaciones: MOVNTI (NT stores) para escribir sin contaminar cache y
; PREFETCHT0 al verificar. Errores = POPCNT(leido XOR esperado).
; ============================================================================
%define TEST_BYTES  (32*1024*1024)
%define TEST_QWORDS (TEST_BYTES/8)

section .data
    h_mod3      db "[Modulo 3] Diagnostico de memoria", 10, 0
    m3_total    db "Memoria total: ", 0
    m3_gb       db " GB detectada (", 0
    m3_mb       db " MB)", 10, 0
    m3_block    db "Bloque de prueba: 32 MB (mmap anonimo)", 10, 0
    m3_fail_map db "Error: mmap fallo", 10, 0
    n_aa        db "Patrón 0xAA: ", 0
    n_55        db "Patrón 0x55: ", 0
    n_inc       db "Patrón incremental: ", 0
    m3_pass     db "PASADA (0 errores)", 10, 0
    m3_bad1     db "FALLIDA (", 0
    m3_bad2     db " bits corruptos)", 10, 0

section .text
modulo3_mem:
    push rbx
    push r12
    push r13
    push r14

    PRINT h_mod3

    ; --- memoria total via sysinfo (99) ---
    sub rsp, 112
    mov eax, 99
    mov rdi, rsp
    syscall
    mov rax, [rsp+32]                   ; totalram
    mov ecx, [rsp+104]                  ; mem_unit
    imul rax, rcx
    add rsp, 112
    shr rax, 20                         ; MB
    mov r12, rax
    PRINT m3_total
    lea rax, [r12+512]
    shr rax, 10                         ; GB redondeado
    call print_u64
    PRINT m3_gb
    mov rax, r12
    call print_u64
    PRINT m3_mb

    ; --- reservar bloque de prueba (mmap = 9) ---
    mov eax, 9
    xor edi, edi
    mov esi, TEST_BYTES
    mov edx, 3                          ; PROT_READ|PROT_WRITE
    mov r10d, 0x22                      ; MAP_PRIVATE|MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4096
    ja .map_fail
    mov r13, rax
    PRINT m3_block

    ; --- patron 0xAA ---
    mov rdi, r13
    mov ecx, TEST_QWORDS
    mov rax, 0xAAAAAAAAAAAAAAAA
    call fill_pattern
    mov rdi, r13
    mov ecx, TEST_QWORDS
    mov rax, 0xAAAAAAAAAAAAAAAA
    call verify_pattern
    lea rsi, [n_aa]
    call report_pattern

    ; --- patron 0x55 ---
    mov rdi, r13
    mov ecx, TEST_QWORDS
    mov rax, 0x5555555555555555
    call fill_pattern
    mov rdi, r13
    mov ecx, TEST_QWORDS
    mov rax, 0x5555555555555555
    call verify_pattern
    lea rsi, [n_55]
    call report_pattern

    ; --- secuencia incremental (byte i = i mod 256) ---
    mov rdi, r13
    mov ecx, TEST_QWORDS
    call fill_inc
    mov rdi, r13
    mov ecx, TEST_QWORDS
    call verify_inc
    lea rsi, [n_inc]
    call report_pattern

    ; --- liberar (munmap = 11) ---
    mov eax, 11
    mov rdi, r13
    mov esi, TEST_BYTES
    syscall
    jmp .end
.map_fail:
    PRINT m3_fail_map
.end:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fill_pattern: RDI=buffer, RCX=qwords, RAX=patron (stores no temporales)
fill_pattern:
    push rdi
    push rcx
.l:
    movnti [rdi], rax
    add rdi, 8
    dec rcx
    jnz .l
    sfence
    pop rcx
    pop rdi
    ret

; verify_pattern: RDI=buffer, RCX=qwords, RAX=patron -> RAX = bits erroneos
verify_pattern:
    push rdi
    push rcx
    push rdx
    xor r8d, r8d
.l:
    prefetcht0 [rdi+512]
    mov rdx, [rdi]
    xor rdx, rax
    popcnt rdx, rdx
    add r8, rdx
    add rdi, 8
    dec rcx
    jnz .l
    mov rax, r8
    pop rdx
    pop rcx
    pop rdi
    ret

; fill_inc: qword k = 0x0706050403020100 + ((8k)&0xFF)*0x0101010101010101
fill_inc:
    push rsi
    push rdx
    push r9
    push r10
    mov r9, 0x0101010101010101
    mov r10, 0x0706050403020100
    xor esi, esi
.l:
    mov rdx, rsi
    shl rdx, 3
    and edx, 0xFF
    imul rdx, r9
    add rdx, r10
    movnti [rdi+rsi*8], rdx
    inc rsi
    cmp rsi, rcx
    jb .l
    sfence
    pop r10
    pop r9
    pop rdx
    pop rsi
    ret

verify_inc:
    push rsi
    push rdx
    push r9
    push r10
    mov r9, 0x0101010101010101
    mov r10, 0x0706050403020100
    xor esi, esi
    xor r8d, r8d
.l:
    prefetcht0 [rdi+rsi*8+512]
    mov rdx, rsi
    shl rdx, 3
    and edx, 0xFF
    imul rdx, r9
    add rdx, r10
    xor rdx, [rdi+rsi*8]
    popcnt rdx, rdx
    add r8, rdx
    inc rsi
    cmp rsi, rcx
    jb .l
    mov rax, r8
    pop r10
    pop r9
    pop rdx
    pop rsi
    ret

; report_pattern: RSI = nombre, RAX = bits erroneos
report_pattern:
    push rax
    call print_cstr
    pop rax
    test rax, rax
    jnz .bad
    PRINT m3_pass
    ret
.bad:
    push rax
    PRINT m3_bad1
    pop rax
    call print_u64
    PRINT m3_bad2
    ret

; ============================================================================
; MODULO 4: Rendimiento del CPU (TSC, IPC, CPI, GFLOPS)
; Frecuencia del TSC = ticks / tiempo real (CLOCK_MONOTONIC_RAW) durante 100ms.
; IPC = instrucciones ejecutadas (conocidas por construccion) / ciclos TSC.
; ============================================================================
%define LOOP_ITERS 10000000

section .data
    h_mod4      db "[Modulo 4] Monitor de rendimiento del CPU", 10, 0
    m4_freq     db "Frecuencia (TSC): ", 0
    m4_ghz      db " GHz", 10, 0
    m4_a        db "Prueba A (adds independientes): ", 0
    m4_b        db "Prueba B (cadena dependiente):  ", 0
    m4_ipc      db "IPC=", 0
    m4_cpi      db "  CPI=", 0
    m4_cpi_avg  db "CPI promedio: ", 0
    m4_ipc_avg  db "IPC: ", 0
    m4_total    db "Ciclos totales: ", 0
    m4_thr      db "Throughput (SSE2 addps/mulps): ", 0
    m4_gflops   db " GFLOPS", 10, 0
    align 16
    four_ones   dd 1.0, 1.0, 1.0, 1.0

section .text
modulo4_perf:
    push rbx
    push r12
    push r13
    push r14
    push r15

    PRINT h_mod4

    ; --- frecuencia del TSC ---
    call get_ns
    mov r12, rax
    call read_tsc
    mov r13, rax
    sub rsp, 16
    mov qword [rsp], 0
    mov qword [rsp+8], 100000000        ; 100 ms
    mov eax, 35                         ; nanosleep
    mov rdi, rsp
    xor esi, esi
    syscall
    add rsp, 16
    call read_tsc
    sub rax, r13
    mov r13, rax                        ; ticks
    call get_ns
    sub rax, r12
    mov rbx, rax                        ; ns
    mov rax, r13
    imul rax, 1000
    xor edx, edx
    div rbx                             ; MHz
    xor edx, edx
    mov ecx, 10
    div rcx                             ; MHz/10 = GHz*100
    PRINT m4_freq
    call print_fixed2
    PRINT m4_ghz

    ; --- Prueba A: 4 sumas independientes + dec + jnz (6 instr/iter) ---
    mov ecx, LOOP_ITERS
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    call read_tsc
    mov r12, rax
.loopA:
    add r8, 1
    add r9, 1
    add r10, 1
    add r11, 1
    dec rcx
    jnz .loopA
    call read_tsc
    sub rax, r12
    mov r13, rax                        ; ciclos A
    PRINT m4_a
    mov rax, r13
    mov ebx, 6*LOOP_ITERS
    call print_ipc_cpi

    ; --- Prueba B: 4 sumas dependientes (cadena en r8) + dec + jnz ---
    mov ecx, LOOP_ITERS
    xor r8d, r8d
    call read_tsc
    mov r12, rax
.loopB:
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    dec rcx
    jnz .loopB
    call read_tsc
    sub rax, r12
    mov r14, rax                        ; ciclos B
    PRINT m4_b
    mov rax, r14
    mov ebx, 6*LOOP_ITERS
    call print_ipc_cpi

    ; --- totales ---
    add r13, r14                        ; ciclos totales
    PRINT m4_total
    mov rax, r13
    call print_u64
    PRINT nl
    PRINT m4_cpi_avg
    mov rax, r13
    imul rax, 100
    xor edx, edx
    mov rcx, 12*LOOP_ITERS
    div rcx
    call print_fixed2
    PRINT nl
    PRINT m4_ipc_avg
    mov rax, 12*LOOP_ITERS
    imul rax, 100
    xor edx, edx
    div r13
    call print_fixed2
    PRINT nl

    ; --- Throughput: SSE2, 4 addps + 4 mulps por iteracion (32 FLOP) ---
    movaps xmm8, [four_ones]
    movaps xmm9, [four_ones]
    movaps xmm0, xmm8
    movaps xmm1, xmm8
    movaps xmm2, xmm8
    movaps xmm3, xmm8
    movaps xmm4, xmm8
    movaps xmm5, xmm8
    movaps xmm6, xmm8
    movaps xmm7, xmm8
    mov ecx, LOOP_ITERS
    call get_ns
    mov r12, rax
.loopF:
    addps xmm0, xmm8
    addps xmm1, xmm8
    addps xmm2, xmm8
    addps xmm3, xmm8
    mulps xmm4, xmm9
    mulps xmm5, xmm9
    mulps xmm6, xmm9
    mulps xmm7, xmm9
    dec rcx
    jnz .loopF
    call get_ns
    sub rax, r12
    mov rbx, rax
    mov rax, LOOP_ITERS*32
    imul rax, 100
    xor edx, edx
    div rbx                             ; GFLOPS*100 (FLOP/ns)
    PRINT m4_thr
    call print_fixed2
    PRINT m4_gflops

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; print_ipc_cpi: RAX = ciclos, EBX = instrucciones. Imprime IPC y CPI.
print_ipc_cpi:
    push r13
    push rcx
    push rdx
    mov r13, rax
    PRINT m4_ipc
    mov rax, rbx
    imul rax, 100
    xor edx, edx
    div r13
    call print_fixed2
    PRINT m4_cpi
    mov rax, r13
    imul rax, 100
    xor edx, edx
    div rbx
    call print_fixed2
    PRINT nl
    pop rdx
    pop rcx
    pop r13
    ret

; ============================================================================
; MODULO 5: Jerarquia de memoria (latencia por nivel, en ciclos TSC)
; Registros: cadena dependiente de ADD. Cache/RAM: "pointer chasing" sobre una
; permutacion ciclica aleatoria (algoritmo de Sattolo) con un nodo por linea
; de cache (64 B); cada carga depende de la anterior, asi que no hay solape.
; Tamanos de cache: CPUID hoja 4.
; ============================================================================
%define BUF_BYTES (256*1024*1024)

section .data
    h_mod5      db "[Modulo 5] Gestion jerarquica de memoria", 10, 0
    m5_reg      db "Registros: ", 0
    m5_l1       db "L1 caché: ", 0
    m5_l2       db "L2 caché: ", 0
    m5_l3       db "L3 caché: ", 0
    m5_ram      db "RAM: ", 0
    m5_cyc      db " ciclos (", 0
    m5_cyc2     db " ciclos TSC (", 0
    m5_end      db ")", 10, 0
    m5_nomap    db "Error: mmap fallo", 10, 0

section .text
modulo5_hier:
    push rbx
    push r12
    push r13
    push r14

    PRINT h_mod5

    ; --- registros: 8M sumas dependientes ---
    mov ecx, 1000000
    xor r8d, r8d
    call read_tsc
    mov r12, rax
.reg:
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    add r8, 1
    dec rcx
    jnz .reg
    call read_tsc
    sub rax, r12
    imul rax, 100
    xor edx, edx
    mov rcx, 8000000
    div rcx
    PRINT m5_reg
    call print_fixed2
    PRINT m5_cyc2
    lea rsi, [m5_regtxt]
    call print_cstr
    PRINT m5_end

    call detect_caches

    ; --- buffer comun ---
    mov eax, 9
    xor edi, edi
    mov esi, BUF_BYTES
    mov edx, 3
    mov r10d, 0x22
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4096
    ja .nomap
    mov r13, rax

    ; --- L1: conjunto = L1/2 ---
    PRINT m5_l1
    mov rsi, [l1_size]
    mov r14, rsi
    shr rsi, 1
    mov rdi, r13
    call measure_latency
    mov rbx, r14
    call print_level

    ; --- L2: conjunto = L2/2 ---
    PRINT m5_l2
    mov rsi, [l2_size]
    mov r14, rsi
    shr rsi, 1
    mov rdi, r13
    call measure_latency
    mov rbx, r14
    call print_level

    ; --- L3: conjunto = L3/2 ---
    PRINT m5_l3
    mov rsi, [l3_size]
    mov r14, rsi
    shr rsi, 1
    mov rdi, r13
    call measure_latency
    mov rbx, r14
    call print_level

    ; --- RAM: conjunto = 4*L3 (min 64MB, max 256MB) ---
    PRINT m5_ram
    mov rsi, [l3_size]
    shl rsi, 2
    cmp rsi, 64*1024*1024
    jae .r1
    mov rsi, 64*1024*1024
.r1:
    cmp rsi, BUF_BYTES
    jbe .r2
    mov rsi, BUF_BYTES
.r2:
    mov r14, rsi
    mov rdi, r13
    call measure_latency
    mov rbx, r14
    call print_level_ws

    mov eax, 11
    mov rdi, r13
    mov esi, BUF_BYTES
    syscall
    jmp .end
.nomap:
    PRINT m5_nomap
.end:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .data
    m5_regtxt   db "dependencia de 1 ADD", 0
    m5_cachesz  db "capacidad ", 0
    m5_ws       db "conjunto de trabajo ", 0
section .text

; print_level: RAX = ciclos*100, RBX = capacidad del nivel
print_level:
    call print_fixed2
    PRINT m5_cyc
    push rax
    mov rax, rbx
    call print_size
    pop rax
    PRINT m5_end
    ret
; print_level_ws: igual, pero RBX es el conjunto de trabajo
print_level_ws:
    call print_fixed2
    PRINT m5_cyc
    push rax
    mov rax, rbx
    call print_size
    pop rax
    PRINT m5_end
    ret

; detect_caches: CPUID hoja 4 -> l1_size, l2_size, l3_size (bytes)
detect_caches:
    push rbx
    push r12
    push r13
    mov qword [l1_size], 32768
    mov qword [l2_size], 262144
    mov qword [l3_size], 8388608
    xor eax, eax
    cpuid
    cmp eax, 4
    jb .ret
    xor r12d, r12d
.l:
    mov eax, 4
    mov ecx, r12d
    cpuid
    mov r13d, eax
    and r13d, 0x1F                      ; tipo
    jz .ret
    cmp r13d, 2                         ; saltar cache de instrucciones
    je .next
    mov r8d, eax
    shr r8d, 5
    and r8d, 7                          ; nivel
    mov r9d, ebx
    shr r9d, 22
    inc r9d                             ; vias
    mov r10d, ebx
    shr r10d, 12
    and r10d, 0x3FF
    inc r10d                            ; particiones
    and ebx, 0xFFF
    inc ebx                             ; bytes por linea
    inc ecx                             ; conjuntos
    mov rax, r9
    imul rax, r10
    imul rax, rbx
    imul rax, rcx
    cmp r8d, 1
    jne .t2
    mov [l1_size], rax
    jmp .next
.t2:
    cmp r8d, 2
    jne .t3
    mov [l2_size], rax
    jmp .next
.t3:
    cmp r8d, 3
    jne .next
    mov [l3_size], rax
.next:
    inc r12d
    cmp r12d, 16
    jb .l
.ret:
    pop r13
    pop r12
    pop rbx
    ret

; measure_latency: RDI = buffer, RSI = conjunto de trabajo (bytes)
;   -> RAX = ciclos TSC por acceso * 100
measure_latency:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    shr r13, 6                          ; n nodos (1 por linea de 64 B)
    cmp r13, 2
    jae .n_ok
    mov r13, 2
.n_ok:
    ; arr[i] = i
    xor ecx, ecx
.init:
    mov rax, rcx
    shl rax, 6
    mov [r12+rax], rcx
    inc rcx
    cmp rcx, r13
    jb .init
    ; Sattolo: for i=n-1..1: j = rand % i; swap(arr[i], arr[j])
    mov r14, 0x9E3779B97F4A7C15
    mov rbx, r13
    dec rbx
.shuf:
    test rbx, rbx
    jz .shuf_done
    mov rax, r14
    shl rax, 13
    xor r14, rax
    mov rax, r14
    shr rax, 7
    xor r14, rax
    mov rax, r14
    shl rax, 17
    xor r14, rax
    mov rax, r14
    xor edx, edx
    div rbx                             ; rdx = j en [0, i-1]
    mov rsi, rbx
    shl rsi, 6
    add rsi, r12
    mov rdi, rdx
    shl rdi, 6
    add rdi, r12
    mov rax, [rsi]
    mov rcx, [rdi]
    mov [rsi], rcx
    mov [rdi], rax
    dec rbx
    jmp .shuf
.shuf_done:
    ; indices -> punteros
    xor ecx, ecx
.conv:
    mov rax, rcx
    shl rax, 6
    add rax, r12
    mov rdx, [rax]
    shl rdx, 6
    add rdx, r12
    mov [rax], rdx
    inc rcx
    cmp rcx, r13
    jb .conv
    ; pasos de medicion
    mov r15, r13
    shl r15, 1
    cmp r15, 1000000
    jae .s1
    mov r15, 1000000
.s1:
    cmp r15, 4000000
    jbe .s2
    mov r15, 4000000
.s2:
    ; calentamiento: recorrer el conjunto una vez
    mov rax, r12
    mov rcx, r13
.warm:
    mov rax, [rax]
    dec rcx
    jnz .warm
    mov rbx, rax
    call read_tsc
    mov rbp, rax
    mov rax, rbx
    mov rcx, r15
.chase:
    mov rax, [rax]
    dec rcx
    jnz .chase
    mov rbx, rax
    call read_tsc
    sub rax, rbp
    imul rax, 100
    xor edx, edx
    div r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ============================================================================
; MODULO 6 (bonus): SIMD con AVX2 (YMM, 8 floats) y AVX-512 (ZMM, 16 floats)
; Solo se ejecuta si el modulo 1 confirmo que el SO habilito el estado.
; ============================================================================
section .data
    h_mod6      db "[Modulo 6] Operaciones SIMD (bonus)", 10, 0
    m6_avx2_y   db "AVX2 habilitado: Si", 10, 0
    m6_avx2_n   db "AVX2 habilitado: No (se usa solo SSE2, ver modulo 4)", 10, 0
    m6_thr8     db "Throughput: 8 operaciones paralelas (YMM, 256 bits)", 10, 0
    m6_add      db "Suma vectorizada (vaddps): ", 0
    m6_mul      db "Multiplicación vectorizada (vmulps): ", 0
    m6_cmp      db "Comparación vectorizada (vcmpltps): ", 0
    m6_bad      db "[FALLO]", 10, 0
    m6_bench2   db "Benchmark AVX2: ", 0
    m6_a512_y   db "AVX-512 habilitado: Si (ZMM, 16 operaciones paralelas)", 10, 0
    m6_a512_n   db "AVX-512 habilitado: No", 10, 0
    m6_bench5   db "Benchmark AVX-512: ", 0
    align 32
    vec_a       dd 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0
    vec_b       dd 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0
    vec_sum     dd 3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0, 17.0
    vec_mul     dd 2.0, 6.0, 12.0, 20.0, 30.0, 42.0, 56.0, 72.0
    f_one       dd 1.0

section .text
modulo6_simd:
    push rbx
    push r12
    PRINT h_mod6
    cmp byte [has_avx2], 0
    jne .avx2
    PRINT m6_avx2_n
    jmp .end
.avx2:
    PRINT m6_avx2_y
    PRINT m6_thr8
    vmovaps ymm0, [vec_a]
    vmovaps ymm1, [vec_b]

    PRINT m6_add
    vaddps ymm2, ymm0, ymm1
    vcmpeqps ymm3, ymm2, [vec_sum]
    vmovmskps eax, ymm3
    call check_mask

    PRINT m6_mul
    vmulps ymm2, ymm0, ymm1
    vcmpeqps ymm3, ymm2, [vec_mul]
    vmovmskps eax, ymm3
    call check_mask

    PRINT m6_cmp
    vcmpltps ymm3, ymm0, ymm1           ; a < b en las 8 lineas
    vmovmskps eax, ymm3
    call check_mask

    ; --- benchmark YMM: 4 vaddps + 4 vmulps por iteracion (64 FLOP) ---
    vbroadcastss ymm12, [f_one]
    vmovaps ymm4, ymm12
    vmovaps ymm5, ymm12
    vmovaps ymm6, ymm12
    vmovaps ymm7, ymm12
    vmovaps ymm8, ymm12
    vmovaps ymm9, ymm12
    vmovaps ymm10, ymm12
    vmovaps ymm11, ymm12
    mov ecx, LOOP_ITERS
    call get_ns
    mov r12, rax
.b2:
    vaddps ymm4, ymm4, ymm12
    vaddps ymm5, ymm5, ymm12
    vaddps ymm6, ymm6, ymm12
    vaddps ymm7, ymm7, ymm12
    vmulps ymm8, ymm8, ymm12
    vmulps ymm9, ymm9, ymm12
    vmulps ymm10, ymm10, ymm12
    vmulps ymm11, ymm11, ymm12
    dec rcx
    jnz .b2
    call get_ns
    sub rax, r12
    mov rbx, rax
    mov rax, LOOP_ITERS*64
    imul rax, 100
    xor edx, edx
    div rbx
    PRINT m6_bench2
    call print_fixed2
    PRINT m4_gflops
    vzeroupper

    ; --- AVX-512 (opcional) ---
    cmp byte [has_avx512], 0
    jne .a512
    PRINT m6_a512_n
    jmp .end
.a512:
    PRINT m6_a512_y
    vbroadcastss zmm12, [f_one]
    vmovaps zmm4, zmm12
    vmovaps zmm5, zmm12
    vmovaps zmm6, zmm12
    vmovaps zmm7, zmm12
    vmovaps zmm8, zmm12
    vmovaps zmm9, zmm12
    vmovaps zmm10, zmm12
    vmovaps zmm11, zmm12
    mov ecx, LOOP_ITERS
    call get_ns
    mov r12, rax
.b5:
    vaddps zmm4, zmm4, zmm12
    vaddps zmm5, zmm5, zmm12
    vaddps zmm6, zmm6, zmm12
    vaddps zmm7, zmm7, zmm12
    vmulps zmm8, zmm8, zmm12
    vmulps zmm9, zmm9, zmm12
    vmulps zmm10, zmm10, zmm12
    vmulps zmm11, zmm11, zmm12
    dec rcx
    jnz .b5
    call get_ns
    sub rax, r12
    mov rbx, rax
    mov rax, LOOP_ITERS*128
    imul rax, 100
    xor edx, edx
    div rbx
    PRINT m6_bench5
    call print_fixed2
    PRINT m4_gflops
    vzeroupper
.end:
    pop r12
    pop rbx
    ret

; check_mask: EAX = mascara de 8 bits; 0xFF => [OK]
check_mask:
    cmp eax, 0xFF
    jne .bad
    PRINT s_ok
    ret
.bad:
    PRINT m6_bad
    ret