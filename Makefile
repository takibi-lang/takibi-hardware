# Top-level driver for the test ladder (see docs/WORKFLOW.md).
#
#   make            setup + langcheck + test + synth + names  (the per-commit gate)
#   make test       stage 1: Cyclesim and model tests (dune test), seconds
#   make verilate   stage 2: the same benches on Verilator, tens of seconds
#   make synth      stage 3: Yosys + nextpnr for every board project
#   make board-sim  the generated iCEstick Verilog, firmware and UART at pin
#                   level in Icarus Verilog (catches board-top problems);
#                   board-sim-i9 does the same for the i9 (slow, in ci)
#   make names      naming discipline on the generated Verilog
#   make langcheck  ASCII-only policy on all tracked files
#   make selftest   negative tests for the checks themselves
#   make netlist-sim the S1 MCU bench (lockstep) on the Yosys iCE40 and ECP5
#                   netlists read back into HardCaml, and the iCEstick board
#                   top (firmware in BRAM INIT) (post-synthesis stage S2n);
#                   netlist-sim-i9 does the i9 board top (slow, in ci)
#   make arch-test  riscv-arch-test RV32I on the core, M on the golden model
#   make riscv-tests riscv-tests (ui/um/ua p and v, mi, si; self-checking) on the golden
#                   model (fetches them once; #25)
#   make linux-model Linux + the REPL booted on the golden SoC model (#25)
#   make ci         everything above, including verilate and icebram-check
#
# The RV32E MCU on an iCEstick (S4, by hand):
#   make mcu        build designs/mcu/build/top.bin (firmware sw/echo.bin)
#   make mcu-prog   build and flash it
#   make mcu-term   open the UART at 115200 baud (TTY=/dev-host/ttyUSB1)
#
# The RV32I MCU on a Colorlight i9 v7.2 with the ext board (S4, by hand):
#   make i9         build designs/mcu_i9/build/top.bit (firmware: Dhrystone)
#   make i9-prog    build and load it over the ext board's DAPLink
#   make i9-term    open the DAPLink serial port (I9_TTY: the DAPLink's
#                   by-id link, so another USB serial device does not matter)
#
# The Linux SoC on the Colorlight i9 (#21):
#   make soc-i9          build designs/soc_i9/build/top.bit
#   make soc-i9-images   the kernel, REPL, boot ROM and device tree (as linux-model)
#   make soc-i9-sim      boot Linux on the SoC RTL with Verilator (L9, minutes)
#   make soc-i9-flash    write the bitstream, the device tree and the kernel
#                        into the SPI flash (then the board boots Linux)
#   make soc-i9-prog     load the bitstream into SRAM only (flash images kept)
# Other designs: make -C designs/<name> prog.

# Serial ports: the devcontainer sees the host's /dev read-only under
# /dev-host (devcontainer.json runArgs); device nodes there are usable.
TTY ?= /dev-host/ttyUSB1
I9_TTY ?= $(firstword $(wildcard /dev-host/serial/by-id/usb-ARM_DAPLink*-if01) /dev-host/ttyACM0)

BOARD_PROJECTS := designs/blink designs/hello designs/mcu designs/mcu_i9

all: setup langcheck selftest test board-sim netlist-sim synth names

setup:
	@scripts/setup_clone.sh

versions:
	@scripts/versions.sh

langcheck:
	@scripts/check_ascii.sh

selftest:
	@scripts/selftest.sh

test:
	dune build @runtest

verilate:
	@for p in $(BOARD_PROJECTS); do $(MAKE) --no-print-directory -C $$p verilate || exit 1; done

synth:
	@for p in $(BOARD_PROJECTS); do echo "== $$p"; $(MAKE) --no-print-directory -C $$p all || exit 1; done
	@echo "== designs/soc_i9"; $(MAKE) --no-print-directory -C designs/soc_i9 all

board-sim:
	$(MAKE) --no-print-directory -C designs/mcu board-sim

# Post-synthesis stage (#20); the second run is its negative test: with
# every LUT complemented the bench must fail.
NETLIST_EXE := _build/default/ip/mcu/netlist/main.exe
netlist-sim:
	dune build ./ip/mcu/netlist/main.exe ./sw/echo_rv32e.bin ./sw/irq_rv32i.bin
	$(NETLIST_EXE) _build/default/sw/echo_rv32e.bin build/netlist_sim
	@if $(NETLIST_EXE) --invert-luts _build/default/sw/echo_rv32e.bin build/netlist_sim >/dev/null 2>&1; \
	  then echo "FAIL: netlist-sim accepted a netlist with inverted LUTs" >&2; exit 1; \
	  else echo "OK: netlist-sim rejects a netlist with inverted LUTs"; fi
	$(MAKE) --no-print-directory -C designs/mcu netlist-sim
	$(NETLIST_EXE) --ecp5 _build/default/sw/irq_rv32i.bin build/netlist_sim_ecp5
	@if $(NETLIST_EXE) --ecp5 --invert-luts _build/default/sw/irq_rv32i.bin build/netlist_sim_ecp5 >/dev/null 2>&1; \
	  then echo "FAIL: ECP5 netlist-sim accepted a netlist with inverted LUTs" >&2; exit 1; \
	  else echo "OK: ECP5 netlist-sim rejects a netlist with inverted LUTs"; fi

# The i9 board-level netlist runs the full start-up hold (about a minute).
netlist-sim-i9:
	$(MAKE) --no-print-directory -C designs/mcu_i9 netlist-sim

# riscv-arch-test (RV32I, reference signatures) on the core; fetches the
# tests on first use. Issue #17.
arch-test:
	$(MAKE) --no-print-directory -C bench/arch_test run

# Linux on the golden SoC model (#25): kernel, REPL, boot ROM, device tree.
linux-model:
	$(MAKE) --no-print-directory -C sw/linux model

riscv-tests:
	$(MAKE) --no-print-directory -C bench/riscv_tests run

# The i9 board simulation takes about 2 minutes (Icarus, UART output).
board-sim-i9:
	$(MAKE) --no-print-directory -C designs/mcu_i9 board-sim

names:
	@for p in $(BOARD_PROJECTS); do $(MAKE) --no-print-directory -C $$p names || exit 1; done
	@$(MAKE) --no-print-directory -C designs/soc_i9 names

ci: langcheck selftest test arch-test riscv-tests linux-model board-sim netlist-sim netlist-sim-i9 board-sim-i9 verilate synth names icebram-check ecpbram-check

soc-i9:
	$(MAKE) -C designs/soc_i9

soc-i9-images:
	$(MAKE) --no-print-directory -C sw/linux images

SOC_LINUX := build/linux
soc-i9-sim: soc-i9-images
	dune build ./designs/soc_i9/sim/main.exe ./sw/linux/boot/boot.bin
	./_build/default/designs/soc_i9/sim/main.exe --verilator \
	  _build/default/sw/linux/boot/boot.bin $(SOC_LINUX)/boot/soc.dtb \
	  $(SOC_LINUX)/kernel/arch/riscv/boot/Image \
	  --input 'help\recho hello from U-mode\r' --until 'hello from U-mode' \
	  | tee build/soc_i9_sim.log

soc-i9-flash: soc-i9
	$(MAKE) -C designs/soc_i9 flash

soc-i9-prog: soc-i9
	$(MAKE) -C designs/soc_i9 prog

# JTAG from the fabric (#10): load designs/jtag_i9, then drscan ER1.
jtag-test:
	$(MAKE) -C designs/jtag_i9 prog jtag-test

mcu:
	$(MAKE) -C designs/mcu

mcu-prog:
	$(MAKE) -C designs/mcu prog

i9:
	$(MAKE) -C designs/mcu_i9

i9-prog:
	$(MAKE) -C designs/mcu_i9 prog

i9-term:
	picocom -b 115200 $(I9_TTY)

ecpbram-check:
	$(MAKE) -C designs/mcu_i9 ecpbram-check

icebram-check:
	$(MAKE) -C designs/mcu icebram-check

mcu-term:
	picocom -b 115200 $(TTY)

clean:
	dune clean
	@for p in $(BOARD_PROJECTS); do $(MAKE) --no-print-directory -C $$p clean; done

.PHONY: jtag-test soc-i9 soc-i9-images soc-i9-sim soc-i9-flash soc-i9-prog versions arch-test riscv-tests linux-model board-sim board-sim-i9 netlist-sim netlist-sim-i9 mcu mcu-prog mcu-term i9 i9-prog i9-term ecpbram-check icebram-check all setup langcheck selftest test verilate synth names ci clean
