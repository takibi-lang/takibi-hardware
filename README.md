# takibi-hardware

A Linux-capable RISC-V SoC written in
[HardCaml](https://github.com/janestreet/hardcaml), running on the
[Colorlight i9 v7.2](https://github.com/wuxx/Colorlight-FPGA-Projects)
(Lattice ECP5 LFE5U-45F, 8 MiB SDRAM) through the open-source Yosys /
nextpnr / Project Trellis flow. Linux 6.18 boots on the board, with one or
two cores (SMP), to a small REPL on the UART.

The underlying question is whether cheap verification in HardCaml can catch
most hardware defects before simulation of the generated Verilog and testing
on the board. See [docs/WORKFLOW.md](docs/WORKFLOW.md) for the method,
[BUGS.md](BUGS.md) for the evidence, and [HISTORY.md](HISTORY.md) for the
project log.

## The SoC

- Core: multi-cycle RV32IMA with Zicsr, M/S/U modes, Sv32 MMU (TLB and
  page walker), Sstc; checked in lockstep against an OCaml golden model at
  every retired instruction.
- One or two cores (`HARTS=2`) sharing a cache in front of the SDRAM, with
  an arbiter for AMOs and LR/SC (proved with SymbiYosys, `formal/`).
- CLINT, PLIC, 16550 UART, SPI flash (bitstream, device tree, kernel),
  boot ROM with a minimal SBI (timer, IPI, remote fences).
- 50 MHz on the board. Numbers: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Quick start

    make setup     # once per clone: enable the git hooks
    make           # langcheck, tests, formal, synthesis, S3 checks
    make ci        # the above plus the Verilator stages

## Linux on the Colorlight i9

    make soc-i9-images  # kernel 6.18 + the REPL (initramfs), boot ROM, device tree
    make soc-i9-flash   # bitstream, device tree and kernel into the SPI flash
    make i9-term        # the console: Linux boots to "takibi-hardware REPL on Linux"

Writing the flash takes about 10 minutes over the ext board's DAPLink,
which also carries the UART (USB CDC serial). In the REPL, `bench
dhrystone`, `bench syscall` and `bench memcpy` measure the system.
`make soc-i9-sim` boots the same images on the SoC RTL in Verilator with
the board models, every instruction in lockstep with the golden model.

Two cores: `HARTS=2 make -C designs/soc_i9 BOOT=sw/linux/boot_smp/boot.bin
BUILD=build-smp LINUX=$PWD/build/linux-smp` with the images from `make -C
sw/linux images-smp`. Bring-up aid: `make -C designs/soc_i9
BOOT=sw/soc_test/memtest.bin BUILD=build-memtest prog` (SDRAM and flash
test from the boot ROM). First session with a board:
[docs/BRINGUP_I9.md](docs/BRINGUP_I9.md).

## Projects

| Directory | Description | Stages |
|-----------|-------------|--------|
| [designs/soc_i9](designs/soc_i9/) | The Linux SoC on the Colorlight i9 | S1, S2 (Verilator boot), S3, S4 |
| [ip/rv32](ip/rv32/) | RV32 cores: multi-cycle (S/U, Sv32) and a 4-stage pipeline (M only) | S0, S1 (lockstep, random programs, riscv-tests, arch-test) |
| [ip/soc](ip/soc/) | Cache, arbiter, CLINT, PLIC, 16550, SoC top | S0f, S1, S2 |
| [ip/sdram](ip/sdram/), [ip/spi_flash](ip/spi_flash/), [ip/ecp5](ip/ecp5/) | SDRAM controller, flash reader, ECP5 primitives (PLL, ODDR, JTAG) | S1, S4 |
| [formal](formal/) | SymbiYosys proofs on the generated Verilog | S0f |
| [models](models/) | Golden models: RV32 machine, SoC devices, assembler | tests |
| [sw](sw/) | Boot ROMs, Linux build and REPL, firmware, Dhrystone | -- |
| [bench/ref_cores](bench/ref_cores/) | Area and Dhrystone of reference cores | -- |

### Smaller designs

Kept building and tested by `make`, no longer the focus:

| Directory | Description |
|-----------|-------------|
| [designs/mcu_i9](designs/mcu_i9/) | RV32I MCU (pipelined core, no MMU) on the i9 running Dhrystone: `make i9-prog`, `make i9-term` |
| [designs/jtag_i9](designs/jtag_i9/) | ECP5 JTAG register test |
| [designs/mcu](designs/mcu/), [ip/mcu](ip/mcu/) | RV32E MCU on the iCEstick (iCE40HX1K): `make mcu-prog`, `make mcu-term` |
| [designs/hello](designs/hello/), [designs/blink](designs/blink/), [ip/uart](ip/uart/) | First iCEstick designs and the UART |

## Toolchain

- Local: open the repository in the devcontainer (`.devcontainer/`).
- Claude Code cloud sessions: `.claude/hooks/session-start.sh` installs the
  same tools. The environment's network policy must allow `opam.ocaml.org`
  (and preferably `github.com` and `codeload.github.com`).

Contributors and coding agents: read [AGENTS.md](AGENTS.md).

## License

takibi-hardware is distributed under the
[GNU General Public License version 3](LICENSE) or (at your option) any
later version. Files that carry their own license, such as the Dhrystone
sources in `sw/dhrystone/` (see `LICENSE.riscv-tests`), stay under it.

Commercial licenses, for uses the GPLv3 does not fit, are available on
request; please contact the maintainer, Kiwamu Okabe
<kiwamu@metasepi.org>.

Contributions are accepted under the
[takibi-hardware Contributor License Agreement](CLA.md).
