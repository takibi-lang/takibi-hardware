/* Measurement hooks for riscv-tests' Dhrystone on the takibi-hardware MCU.
   setStats(1) is called just before the timed loop, setStats(0) just after
   it; we record mcycle and minstret (the standard CSRs, on the Zicsr i9
   build) or else the memory-mapped CYCLE and INSTRET counters, and print the difference in
   a fixed format that the testbench parses:

     dhrystone: runs=N cycles=C instret=I
     dhrystone: DMIPS/MHz=0.ddd

   DMIPS/MHz = runs * 1e6 / (cycles * 1757); in thousandths that is
   runs * 569152 / cycles (569152 = 1e9 / 1757), which fits in 32 bits
   for up to 7000 runs.

   (debug_printf, used for the verbose output, is defined empty in
   riscv-tests' dhrystone.c.) */
#include "mcu.h"
#include "util.h"
#include "dhrystone.h"

static unsigned int start_cycle, start_instret;

void setStats(int enable)
{
#ifdef __riscv_zicsr
  unsigned int cycle = csr_read(mcycle), instret = csr_read(minstret);
#else
  unsigned int cycle = CYCLE, instret = INSTRET;
#endif
  if (enable) {
    start_cycle = cycle;
    start_instret = instret;
  } else {
    unsigned int cycles = cycle - start_cycle;
    unsigned int milli = (unsigned int)NUMBER_OF_RUNS * 569152u / cycles;
    printf("dhrystone: runs=%d cycles=%u instret=%u\n",
           NUMBER_OF_RUNS, cycles, instret - start_instret);
    printf("dhrystone: DMIPS/MHz=%u.%u%u%u\n",
           milli / 1000, milli / 100 % 10, milli / 10 % 10, milli % 10);
  }
}
