/* Boot ROM of the Linux SoC (#21, #25; more harts: #9): runs in M-mode
   from address 0 on every hart.

   1. Hart 0 copies the kernel Image from the flash window to KERNEL_LOAD
      (size from the RISC-V Image header, image_size at offset 16), then
      wakes the other harts with their CLINT msip. The others wait for it.
   2. Every hart prepares S-mode: delegate every exception except ecalls
      from S and M, delegate the S-level interrupts, allow cycle/time/
      instret below M, enable Sstc (menvcfgh.STCE), program PMP to allow
      everything, enable its M software interrupt (IPIs, below).
   3. mret to the kernel in S-mode: a0 = hart id, a1 = the DTB's address
      in the flash window. With more than one hart Linux picks one by
      lottery and parks the others (spinwait boot, no SBI HSM).

   The M-mode trap handler stays resident and answers SBI calls from
   S-mode: the base extension (spec 1.0), and with more than one hart IPI
   (send_ipi) and RFENCE (remote fence.i / sfence.vma, done in full).
   An IPI sets the target's "ipi" mailbox flag and msip; its M software
   interrupt clears msip and raises SSIP for S-mode. A remote fence sets
   the target's "fence" flag and msip, and the caller waits until the
   target has fenced (servicing its own fence requests meanwhile, so two
   harts fencing each other do not deadlock). Anything else returns
   SBI_ERR_NOT_SUPPORTED. Any other trap into M-mode is a bug: it prints
   "!M" and the cause in hex on the UART and stops.

   Memory: one mailbox of 32 bytes per hart at MAILBOX (the top 4 KiB of
   the RAM, left out of the device tree's memory): +0 fence
   flag, +4 ipi flag, +8.. registers saved by the handler. mscratch holds
   the hart's mailbox address. */
#include "soc_map.h"

#define SBI_EXT_BASE 0x10
#define SBI_EXT_IPI 0x735049
#define SBI_EXT_RFENCE 0x52464E43
#define SBI_ERR_NOT_SUPPORTED -2

    .section .text
    .globl _start
_start:
    csrr  t0, mhartid
    bnez  t0, secondary
    li    t0, FLASH_BASE + FLASH_KERNEL_OFFSET
    li    t1, KERNEL_LOAD
    lw    t2, 16(t0)              /* image_size, low word */
    add   t2, t1, t2
1:  bgeu  t1, t2, 2f
    lw    t3, 0(t0)
    sw    t3, 0(t1)
    addi  t0, t0, 4
    addi  t1, t1, 4
    j     1b
2:  fence.i
#if HARTS > 1
    li    t0, CLINT_BASE + 4      /* wake harts 1.. */
    li    t1, CLINT_BASE + 4 * HARTS
    li    t2, 1
3:  sw    t2, 0(t0)
    addi  t0, t0, 4
    bltu  t0, t1, 3b
#endif
    j     prepare

secondary:
    csrr  t0, mip                 /* wait for msip (interrupts are off) */
    andi  t0, t0, 8
    beqz  t0, secondary
    csrr  t0, mhartid
    slli  t0, t0, 2
    li    t1, CLINT_BASE
    add   t0, t0, t1
    sw    zero, 0(t0)
    fence.i

prepare:
    csrr  t0, mhartid
    slli  t0, t0, 5
    li    t1, MAILBOX
    add   t0, t0, t1
    sw    zero, 0(t0)
    sw    zero, 4(t0)
    csrw  mscratch, t0
    la    t0, m_trap
    csrw  mtvec, t0
    li    t0, 0xb1ff              /* causes 0-8, 12, 13, 15 */
    csrw  medeleg, t0
    li    t0, 0x222               /* SSI, STI, SEI */
    csrw  mideleg, t0
    li    t0, 7                   /* CY, TM, IR */
    csrw  mcounteren, t0
    li    t0, 0x80000000          /* STCE */
    csrw  0x31a, t0               /* menvcfgh */
    li    t0, -1
    csrw  pmpaddr0, t0
    li    t0, 0x1f                /* NAPOT, R, W, X */
    csrw  pmpcfg0, t0
    li    t0, 8                   /* MSIE: IPIs and remote fences */
    csrw  mie, t0
    li    t0, 0x1800              /* MPP field */
    csrc  mstatus, t0
    li    t0, 0x0800              /* MPP = S */
    csrs  mstatus, t0
    li    t0, KERNEL_LOAD
    csrw  mepc, t0
    csrr  a0, mhartid
    li    a1, FLASH_BASE + FLASH_DTB_OFFSET
    mret

    .align 2
m_trap:
    csrrw t0, mscratch, t0        /* t0 = this hart's mailbox */
    sw    t1, 8(t0)
    sw    t2, 12(t0)
    sw    t3, 16(t0)
    sw    t4, 20(t0)
    csrr  t1, mcause
    bltz  t1, m_interrupt
    addi  t1, t1, -9              /* ecall from S */
    bnez  t1, unexpected
    li    t1, SBI_EXT_BASE
    beq   a7, t1, sbi_base
#if HARTS > 1
    li    t1, SBI_EXT_IPI
    beq   a7, t1, sbi_ipi
    li    t1, SBI_EXT_RFENCE
    beq   a7, t1, sbi_rfence
#endif
not_supported:
    li    a0, SBI_ERR_NOT_SUPPORTED
    li    a1, 0
    j     sbi_return
sbi_base:
    beqz  a6, spec_version        /* FID 0 */
    li    t1, 3                   /* probe_extension */
    beq   a6, t1, probe
    li    t1, 6
    bleu  a6, t1, zero_value      /* impl id/version, mvendorid, marchid, mimpid */
    j     not_supported
probe:
#if HARTS > 1
    li    t1, SBI_EXT_IPI
    beq   a0, t1, one_value
    li    t1, SBI_EXT_RFENCE
    beq   a0, t1, one_value
#endif
    j     zero_value
spec_version:
    li    a0, 0
    li    a1, 0x01000000          /* 1.0 */
    j     sbi_return
one_value:
    li    a0, 0
    li    a1, 1
    j     sbi_return
zero_value:
    li    a0, 0
    li    a1, 0
sbi_return:
    csrr  t1, mepc
    addi  t1, t1, 4
    csrw  mepc, t1
restore:
    lw    t1, 8(t0)
    lw    t2, 12(t0)
    lw    t3, 16(t0)
    lw    t4, 20(t0)
    csrrw t0, mscratch, t0
    mret

#if HARTS > 1
/* t2 = 1 if hart t3 is selected by hart_mask a0, hart_mask_base a1
   (a1 = -1: all harts). Uses t4. */
selected:
    li    t2, 1
    li    t4, -1
    beq   a1, t4, 1f
    sub   t4, t3, a1
    bltz  t4, 2f
    srl   t2, a0, t4
    andi  t2, t2, 1
1:  ret
2:  li    t2, 0
    ret

sbi_ipi:                          /* send_ipi (FID 0) */
    bnez  a6, not_supported
    li    t3, 0
1:  mv    t1, ra
    call  selected
    mv    ra, t1
    beqz  t2, 2f
    slli  t4, t3, 5               /* ipi flag, then msip */
    li    t1, MAILBOX
    add   t4, t4, t1
    li    t1, 1
    sw    t1, 4(t4)
    slli  t4, t3, 2
    li    t1, CLINT_BASE
    add   t4, t4, t1
    li    t1, 1
    sw    t1, 0(t4)
2:  addi  t3, t3, 1
    li    t1, HARTS
    bltu  t3, t1, 1b
    j     zero_value

sbi_rfence:                       /* FIDs 0-2: fence.i, sfence.vma(_asid) */
    li    t1, 2
    bgtu  a6, t1, not_supported
    li    t3, 0
1:  mv    t1, ra
    call  selected
    mv    ra, t1
    beqz  t2, 4f
    csrr  t1, mhartid
    bne   t1, t3, 2f
    sfence.vma                    /* this hart */
    fence.i
    j     4f
2:  slli  t4, t3, 5               /* fence flag and msip of hart t3 */
    li    t1, MAILBOX
    add   t4, t4, t1
    li    t1, 1
    sw    t1, 0(t4)
    slli  t2, t3, 2
    li    t1, CLINT_BASE
    add   t2, t2, t1
    li    t1, 1
    sw    t1, 0(t2)
3:  lw    t1, 0(t0)               /* meanwhile, fence for others */
    beqz  t1, 5f
    sfence.vma
    fence.i
    sw    zero, 0(t0)
5:  lw    t1, 0(t4)               /* until hart t3 has fenced */
    bnez  t1, 3b
4:  addi  t3, t3, 1
    li    t1, HARTS
    bltu  t3, t1, 1b
    j     zero_value
#endif

m_interrupt:                      /* M software interrupt: msip */
    andi  t1, t1, 0xf
    li    t2, 3
    bne   t1, t2, unexpected
    csrr  t1, mhartid
    slli  t1, t1, 2
    li    t2, CLINT_BASE
    add   t1, t1, t2
    sw    zero, 0(t1)             /* clear msip, then look at the flags */
    lw    t1, 0(t0)
    beqz  t1, 1f
    sfence.vma
    fence.i
    sw    zero, 0(t0)
1:  lw    t1, 4(t0)
    beqz  t1, restore
    sw    zero, 4(t0)
    li    t1, 2                   /* SSIP: the IPI for S-mode */
    csrs  mip, t1
    j     restore

unexpected:
    li    t1, UART_BASE
    li    t2, '!'
    sb    t2, 0(t1)
    li    t2, 'M'
    sb    t2, 0(t1)
    csrr  t3, mcause
    li    t4, 28
3:  srl   t2, t3, t4
    andi  t2, t2, 15
    addi  t2, t2, '0'
    li    a2, '9'                 /* (the hart stops here: a2 is free) */
    ble   t2, a2, 4f
    addi  t2, t2, 'a' - '9' - 1
4:  sb    t2, 0(t1)
    addi  t4, t4, -4
    bgez  t4, 3b
5:  j     5b
