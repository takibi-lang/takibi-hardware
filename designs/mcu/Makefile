.DELETE_ON_ERROR:
PROJECT := designs/mcu
EXPECT_BRAM := 10
# 1119 LCs with the cloud/CI toolchain (Ubuntu 24.04), 1139 with the
# devcontainer's Yosys/nextpnr on 2026-10-28 (B-0015): the budget allows
# for that spread. Raise it deliberately and note why in HISTORY.md.
MAX_LC := 1160
FIRMWARE := sw/echo_rv32e.bin
include ../../mk/icestick.mk
