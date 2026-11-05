/* The REPL that runs as init on the Linux SoC (#24): reads a line from the
   console, runs a command, prints the result. Benchmarks report counts
   from the user-readable RISC-V counters (rdtime: CLINT mtime at the
   device tree's timebase; rdcycle/rdinstret where the OS allows them) so
   the same commands compare Linux and Takibi on the same SoC.

   Commands: help, echo TEXT, uptime, bench syscall [N], bench memcpy [KB]. */
#include "os.h"

#define TIMEBASE_HZ 1000000u /* Soc_map.timebase_hz */

static void puts_(const char *s)
{
  unsigned int n = 0;
  while (s[n])
    n++;
  os_write(s, n);
}

static void putu(unsigned long long v)
{
  char buf[24];
  int i = sizeof buf;
  do {
    buf[--i] = '0' + v % 10;
    v /= 10;
  } while (v);
  os_write(buf + i, sizeof buf - i);
}

static unsigned long long rdtime(void)
{
  unsigned int hi, lo, hi2;
  do {
    __asm__ volatile("rdtimeh %0" : "=r"(hi));
    __asm__ volatile("rdtime %0" : "=r"(lo));
    __asm__ volatile("rdtimeh %0" : "=r"(hi2));
  } while (hi != hi2);
  return ((unsigned long long)hi << 32) | lo;
}

static int streq(const char *a, const char *b)
{
  while (*a && *a == *b)
    a++, b++;
  return *a == *b;
}

static unsigned int atou(const char *s, unsigned int def)
{
  unsigned int v = 0;
  if (!*s)
    return def;
  while (*s >= '0' && *s <= '9')
    v = v * 10 + (*s++ - '0');
  return v ? v : def;
}

/* Split off the first word of s (modifies s); returns the rest. */
static char *word(char *s)
{
  while (*s && *s != ' ')
    s++;
  if (!*s)
    return s;
  *s++ = 0;
  while (*s == ' ')
    s++;
  return s;
}

static unsigned char buffer[2][64 * 1024];

static void bench_syscall(unsigned int n)
{
  unsigned long long t0 = rdtime();
  for (unsigned int i = 0; i < n; i++)
    os_null_syscall();
  unsigned long long dt = rdtime() - t0;
  puts_("syscall: ");
  putu(n);
  puts_(" calls in ");
  putu(dt * 1000000ull / TIMEBASE_HZ);
  puts_(" us\n");
}

static void bench_memcpy(unsigned int kb)
{
  if (kb > sizeof buffer[0] / 1024)
    kb = sizeof buffer[0] / 1024;
  unsigned int n = kb * 1024 / 4;
  unsigned int *src = (unsigned int *)buffer[0], *dst = (unsigned int *)buffer[1];
  unsigned long long t0 = rdtime();
  for (unsigned int i = 0; i < n; i++)
    dst[i] = src[i];
  unsigned long long dt = rdtime() - t0;
  puts_("memcpy: ");
  putu(kb);
  puts_(" KiB in ");
  putu(dt * 1000000ull / TIMEBASE_HZ);
  puts_(" us\n");
}

static void run(char *line)
{
  char *rest = word(line);
  if (!*line)
    return;
  if (streq(line, "help"))
    puts_("commands: help, echo TEXT, uptime, bench syscall [N], bench memcpy [KB]\n");
  else if (streq(line, "echo")) {
    puts_(rest);
    puts_("\n");
  } else if (streq(line, "uptime")) {
    putu(rdtime() * 1000ull / TIMEBASE_HZ);
    puts_(" ms\n");
  } else if (streq(line, "bench")) {
    char *arg = word(rest);
    if (streq(rest, "syscall"))
      bench_syscall(atou(arg, 1000));
    else if (streq(rest, "memcpy"))
      bench_memcpy(atou(arg, 16));
    else
      puts_("bench: syscall [N] | memcpy [KB]\n");
  } else {
    puts_(line);
    puts_(": unknown command (try help)\n");
  }
}

int main(void)
{
  char line[128];
  puts_("takibi-hardware REPL on ");
  puts_(os_name());
  puts_("\n");
  for (;;) {
    unsigned int n = 0;
    int c;
    puts_("> ");
    while ((c = os_getc()) >= 0 && c != '\n' && c != '\r')
      if (n < sizeof line - 1)
        line[n++] = c;
    line[n] = 0;
    if (c < 0)
      break;
    run(line);
  }
  puts_("console closed\n");
  os_halt();
  return 0;
}
