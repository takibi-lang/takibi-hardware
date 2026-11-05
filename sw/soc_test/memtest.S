/* Board bring-up test for the Linux SoC (#21, L10), run from the boot ROM
   instead of boot.S: no flash and no kernel needed, only the bitstream in
   SRAM. Prints on the UART:

     memtest
     flash: <first word of the flash window>
     pass N: E errors [first bad address, read, expected]

   Each pass writes the whole 8 MiB of SDRAM with a pattern derived from
   the address and the pass number, reads it back, then checks byte and
   halfword writes (read-modify-write in the controller) on a few words. */
#include "soc_map.h"

    .section .text
    .globl _start
_start:
    li    s0, UART_BASE
    la    a0, banner
    call  puts
    la    a0, flash_msg
    call  puts
    li    t0, FLASH_BASE
    lw    a0, 0(t0)
    call  puthex
    call  newline
    li    s1, 0                   /* pass */
pass:
    /* write: word = address ^ (pass * 0x9e3779b9) */
    li    t0, 0x9e3779b9
    mul   s2, s1, t0
    li    t1, RAM_BASE
    li    t2, RAM_BASE + RAM_BYTES
1:  xor   t3, t1, s2
    sw    t3, 0(t1)
    addi  t1, t1, 4
    bltu  t1, t2, 1b
    /* read back */
    li    s3, 0                   /* errors */
    li    t1, RAM_BASE
2:  lw    t4, 0(t1)
    xor   t3, t1, s2
    beq   t4, t3, 3f
    bnez  s3, 4f
    mv    s4, t1                  /* first bad address, read, expected */
    mv    s5, t4
    mv    s6, t3
4:  addi  s3, s3, 1
3:  addi  t1, t1, 4
    bltu  t1, t2, 2b
    /* bytes and halfwords on the first words */
    li    t1, RAM_BASE
    li    t3, 0x11223344
    sw    t3, 0(t1)
    li    t3, 0xaa
    sb    t3, 1(t1)
    li    t3, 0xbbcc
    sh    t3, 2(t1)
    lw    t4, 0(t1)
    li    t3, 0xbbccaa44
    beq   t4, t3, 5f
    bnez  s3, 6f
    mv    s4, t1
    mv    s5, t4
    mv    s6, t3
6:  addi  s3, s3, 1
5:  la    a0, pass_msg
    call  puts
    mv    a0, s1
    call  puthex
    la    a0, errors_msg
    call  puts
    mv    a0, s3
    call  puthex
    beqz  s3, 7f
    li    a0, ' '
    call  putc
    mv    a0, s4
    call  puthex
    li    a0, ' '
    call  putc
    mv    a0, s5
    call  puthex
    li    a0, ' '
    call  putc
    mv    a0, s6
    call  puthex
7:  call  newline
    addi  s1, s1, 1
    j     pass

putc:                             /* a0: byte; waits for THRE */
1:  lbu   t5, 5(s0)
    andi  t5, t5, 0x20
    beqz  t5, 1b
    sb    a0, 0(s0)
    ret

puts:                             /* a0: string */
    mv    t6, ra
    mv    a1, a0
1:  lbu   a0, 0(a1)
    beqz  a0, 2f
    call  putc
    addi  a1, a1, 1
    j     1b
2:  mv    ra, t6
    ret

newline:
    mv    t6, ra
    li    a0, '\n'
    call  putc
    mv    ra, t6
    ret

puthex:                           /* a0: word, 8 hex digits */
    mv    t6, ra
    mv    a2, a0
    li    a3, 28
1:  srl   a0, a2, a3
    andi  a0, a0, 15
    addi  a0, a0, '0'
    li    a4, '9'
    ble   a0, a4, 2f
    addi  a0, a0, 'a' - '9' - 1
2:  call  putc
    addi  a3, a3, -4
    bgez  a3, 1b
    mv    ra, t6
    ret

banner:     .asciz "\nmemtest\n"
flash_msg:  .asciz "flash: "
pass_msg:   .asciz "pass "
errors_msg: .asciz ": errors "
