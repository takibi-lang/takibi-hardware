/* riscv-tests' util.h replacement for the takibi-hardware MCU. */
#ifndef UTIL_H
#define UTIL_H

#include "mcu.h"

/* dhrystone.h reads `mcycle` through this: the real CSR on the Zicsr i9
   build, else the MCU's memory-mapped cycle counter. */
#ifdef __riscv_zicsr
#define read_csr(reg) ((long)csr_read(reg))
#else
#define read_csr(reg) ((long)CYCLE)
#endif

void setStats(int enable);

#endif
