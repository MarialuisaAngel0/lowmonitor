# LowMonitor

Diagnóstico y monitorización de hardware en ensamblador **x86-64** (NASM, Linux, syscalls nativas, sin libc).

Universidad Mariano Gálvez de Guatemala. Facultad de Ingeniería en Sistemas de Información y Ciencias de la Computación.
Autora: Marialuisa

## Módulos

| # | Módulo | Técnica principal |
|---|--------|-------------------|
| 1 | Identificación del CPU | `CPUID` (hojas 0, 1, 7, 0x80000002-4), `XGETBV` |
| 2 | Monitor de puertos E/S | `IN`/`OUT` 8/16/32 bits, `iopl`, captura de #GP con `rt_sigaction` |
| 3 | Diagnóstico de memoria | `mmap`, patrones 0xAA / 0x55 / incremental, `MOVNTI`, `PREFETCHT0`, `POPCNT` |
| 4 | Rendimiento del CPU | `RDTSC` serializado, frecuencia del TSC, IPC/CPI, GFLOPS (SSE2) |
| 5 | Jerarquía de memoria | Pointer chasing (Sattolo), tamaños de caché vía `CPUID` hoja 4 / `0x8000001D` |
| 6 | SIMD (bonus) | AVX2 (YMM) y AVX-512 (ZMM): `vaddps`, `vmulps`, `vcmpltps` |

## Requisitos

- Linux x86-64 (Ubuntu 24.04 o superior)
- `nasm` (2.15+), `binutils` (`ld`), `make`
- Usuario regular (no requiere root; el módulo 2 informa `[BLOQUEADO]` si el SO no concede acceso a puertos)

```
sudo apt install nasm make binutils
```

## Compilar y ejecutar

```
make          # genera bin/lowmonitor (ELF64)
make run      # compila y ejecuta
make clean    # limpia build/ y bin/
```

## Estructura

```
src/lowmonitor.asm      código fuente (.data, .bss, .text)
Makefile                compilación automática
bin/lowmonitor          binario ELF64
docs/evidencia/         salidas reales y lscpu del equipo de pruebas
.devcontainer/          entorno reproducible (Ubuntu 24.04 amd64)
```

## Entorno de pruebas

Las mediciones de los módulos 4 y 5 se tomaron en un equipo x86-64 real (GitHub Codespaces, AMD EPYC 7763). Ver `docs/evidencia/lscpu.txt` y `docs/evidencia/salida_codespaces_*.txt`.

En emulación (Rosetta/QEMU sobre Apple Silicon) los módulos 1, 2, 3 y 6 funcionan, pero el TSC emulado no refleja ciclos reales, por lo que los módulos 4 y 5 no son válidos ahí.

## Notas técnicas

- Los "ciclos" se miden con el TSC (frecuencia constante), no con el reloj real del núcleo.
- Sin permisos de E/S, `IN`/`OUT` provocan #GP (SIGSEGV); el programa lo captura y lo reporta sin terminar.
- AVX-512 solo se ejecuta si `CPUID` lo reporta y `XGETBV` confirma que el SO habilitó el estado ZMM.
