/* Linux side of the REPL's OS interface (#24), on the kernel's nolibc.
   The console is stdin/stdout of init (/dev/console). */
#include "os.h"
#include <asm/termbits.h>
#include <asm/ioctls.h>

int os_getc(void)
{
  char c;
  return read(0, &c, 1) == 1 ? (unsigned char)c : -1;
}

void os_write(const char *s, unsigned int n)
{
  while (n > 0) {
    ssize_t k = write(1, s, n);
    if (k <= 0)
      return;
    s += k;
    n -= k;
  }
}

void os_null_syscall(void) { getppid(); }
void os_sleep_us(unsigned int us) { usleep(us); }
const char *os_name(void) { return "Linux"; }

static struct termios saved_termios;

void os_console_raw(int on)
{
  if (on) {
    struct termios t;
    ioctl(0, TCGETS, &saved_termios);
    t = saved_termios;
    t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    t.c_iflag &= ~(ICRNL | IXON | INLCR);
    t.c_oflag &= ~OPOST;
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    ioctl(0, TCSETS, &t);
  } else
    ioctl(0, TCSETS, &saved_termios);
}

void os_halt(void)
{
  for (;;)
    sleep(1000);
}
