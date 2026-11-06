/* The OS interface of the REPL (#24). The REPL and its benchmarks use only
   these functions. Takibi (https://github.com/takibi-lang/takibi) is
   Linux-ABI compatible, so the Linux build (os_linux.c, static, nolibc)
   is also the Takibi build once Takibi runs on RV32; an os_<name>.c is
   only needed for a kernel without the Linux system calls. */
#ifndef REPL_OS_H
#define REPL_OS_H

/* Read one character from the console; -1 at end of input. */
int os_getc(void);
/* Write n bytes to the console. */
void os_write(const char *s, unsigned int n);
/* The cheapest system call the OS offers (for the round-trip benchmark). */
void os_null_syscall(void);
/* Sleep for at least us microseconds (the timer-latency benchmark). */
void os_sleep_us(unsigned int us);
/* Console in raw mode (no line editing, no echo) while on != 0, for the
   UART round-trip benchmark. */
void os_console_raw(int on);
/* Name of the OS, for the banner. */
const char *os_name(void);
/* Stop (never returns). */
void os_halt(void);

#endif
