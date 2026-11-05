/* Dhrystone (riscv-tests' version, sw/dhrystone) inside the Linux REPL
   (#24, #23): `bench dhrystone` runs it in U-mode and prints the same
   lines as the bare-metal harness. Linux allows only rdtime in U-mode, so
   cycles are rdtime ticks times the SoC's fixed CYCLES_PER_TICK.

   The Dhrystone sources include "util.h" from their own directory, which
   pulls in the MCU's mcu.h and reads mcycle (illegal in U-mode); defining
   its include guard first keeps it out. main is renamed after nolibc (in
   front of every file, -include) has defined _start, which still calls
   the REPL's main. The same trick keeps newlib's <alloca.h> out. */
#define UTIL_H
/* and newlib's alloca.h (the bare-metal compiler's), for nolibc */
#define _NEWLIB_ALLOCA_H
#define alloca __builtin_alloca
#define NUMBER_OF_RUNS 2000
#define CYCLES_PER_TICK 50u

static unsigned long long dhry_time(void)
{
  unsigned int hi, lo, hi2;
  do {
    __asm__ volatile("rdtimeh %0" : "=r"(hi));
    __asm__ volatile("rdtime %0" : "=r"(lo));
    __asm__ volatile("rdtimeh %0" : "=r"(hi2));
  } while (hi != hi2);
  return ((unsigned long long)hi << 32) | lo;
}

#define read_csr(reg) ((long)(dhry_time() * CYCLES_PER_TICK))
void setStats(int enable);

#define main dhrystone_main
#include "../dhrystone/dhrystone_main.c"
#undef main
#include "../dhrystone/dhrystone.c"

static unsigned long long dhry_start;

void setStats(int enable)
{
  if (enable) {
    dhry_start = dhry_time();
    return;
  }
  unsigned int cycles = (unsigned int)((dhry_time() - dhry_start) * CYCLES_PER_TICK);
  /* DMIPS/MHz = runs * 1e6 / (cycles * 1757), in thousandths */
  unsigned int milli = (unsigned int)((unsigned long long)NUMBER_OF_RUNS * 569152u / cycles);
  printf("dhrystone: runs=%d cycles=%u (%u per run)\n", NUMBER_OF_RUNS, cycles, cycles / NUMBER_OF_RUNS);
  printf("dhrystone: DMIPS/MHz=%u.%u%u%u\n", milli / 1000, milli / 100 % 10, milli / 10 % 10, milli % 10);
}
