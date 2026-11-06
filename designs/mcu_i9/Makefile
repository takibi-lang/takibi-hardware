.DELETE_ON_ERROR:
PROJECT := designs/mcu_i9
# 32 DP16KD = 64 KiB RAM (the register file uses distributed RAM).
EXPECT_BRAM := 32
# 1419-1571 TRELLIS_COMB with the cloud/CI toolchain on 2026-10-28, 1631
# with the start-up hold and LED logic of #16 (varies
# with packing; other Yosys/nextpnr releases differ further, B-0015).
# 2026-10-29, pinned toolchain: 1438 without Zicsr, 2516 with Zicsr,
# interrupts and the timer (#3), MMIO CYCLE/INSTRET dropped (the CSRs
# replace them); 2766 with the second register-file copy (#4); 2874 with
# the fetch overlap (#4); 3981 with M and A (#5: multiplier adders,
# divider, AMO unit; 4 MULT18X18D). The
# LFE5U-45F has 43,848 LUTs.
# Raise deliberately and note why in HISTORY.md.
MAX_LC := 5000
FIRMWARE := sw/dhrystone_rv32i.bin
# The board simulation runs the 50-run image (the 500-run one takes minutes).
BOARD_SIM_FIRMWARE := sw/dhrystone_sim.bin
# The post-synthesis board stage runs the interrupt test (sw/irq).
NETLIST_SIM_FIRMWARE := sw/irq_rv32i.bin
include ../../mk/ecp5.mk
