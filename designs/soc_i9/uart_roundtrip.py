#!/usr/bin/env python3
"""Host side of the REPL's `bench uart N` (issue #24) on the board: types
the command, echoes every 'U' the REPL sends, prints the REPL's result.

    uart_roundtrip.py TTY [N]
"""
import os
import sys
import termios
import time

tty = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
fd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = attrs[5] = termios.B115200
attrs[6][termios.VMIN] = 1
attrs[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attrs)
termios.tcflush(fd, termios.TCIOFLUSH)
os.write(fd, b"\r")
time.sleep(0.5)
termios.tcflush(fd, termios.TCIFLUSH)
os.write(fd, b"bench uart %d\r" % n)
out = b""
echoed = 0
deadline = time.time() + 30
while time.time() < deadline:
    c = os.read(fd, 1)
    if c == b"U" and echoed < n and b"bench uart" in out:
        os.write(fd, b"U")
        echoed += 1
        continue
    out += c
    if out.endswith(b"> ") and b"round trips" in out:
        break
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
print()
