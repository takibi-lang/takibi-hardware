# takibi-hardware

A CPU written in [HardCaml](https://github.com/janestreet/hardcaml), running
on the [iCEstick](https://www.latticesemi.com/en/Products/DevelopmentBoardsAndKits/iCEstick)
(iCE40HX1K-TQ144, 12 MHz) through the open-source Yosys / nextpnr / icestorm
flow.

The underlying question is whether cheap verification in HardCaml can catch
most hardware defects before simulation of the generated Verilog and testing
on the board. See [docs/WORKFLOW.md](docs/WORKFLOW.md) for the method,
[BUGS.md](BUGS.md) for the evidence, and [HISTORY.md](HISTORY.md) for the
project log.

## Projects

| Directory | Description | Stages |
|-----------|-------------|--------|
| [ip/uart](ip/uart/) | 8N1 UART transmitter and receiver | S1, S2 |
| [ip/rv32](ip/rv32/) | Multi-cycle RV32I / RV32E core | S0 (SAT proofs), S1 (lockstep, random programs) |
| [designs/blink](designs/blink/) | LED blinker | S1, S3 |
| [designs/hello](designs/hello/) | Prints "Hello, iCEstick!" at 115200 baud | S1, S2, S3 |
| [designs/mcu](designs/mcu/) | RV32E MCU on the iCEstick running C firmware (UART echo) | S1, S2, S3 |
| [designs/mcu_i9](designs/mcu_i9/) | RV32I MCU on the Colorlight i9 (ECP5) running Dhrystone | S1, S3 |
| [ip/mcu](ip/mcu/) | The MCU (core + RAM + UART + LEDs + counters), shared by both boards | S1, S2 |
| [bench/ref_cores](bench/ref_cores/) | Area and Dhrystone of reference cores ([docs/BENCHMARKS.md](docs/BENCHMARKS.md)) | -- |
| [models/rv32_model](models/rv32_model/) | RV32E golden model and assembler | tests |
| [sw](sw/) | MCU firmware (C, built with riscv-none-elf-gcc) | -- |

No design has been run on a board yet (S4).

## Quick start

    make setup     # once per clone: enable the git hooks
    make           # langcheck, tests, synthesis, S3 checks
    make ci        # the above plus the Verilator stage

## Running the MCU on an iCEstick

    make mcu-prog  # build designs/mcu with sw/echo.bin and flash it
    make mcu-term  # picocom -b 115200 /dev-host/ttyUSB1 (override with TTY=...)

The iCEstick's FTDI chip exposes two serial ports; the UART is the second
(usually `/dev-host/ttyUSB1`). After reset the MCU prints `RV32E MCU ready` and
a `> ` prompt. Type a line and press Enter: it answers in upper case and
shows the line length on the LEDs. Leave picocom with Ctrl-A Ctrl-X.

Changing only the firmware (`sw/`) is fast: the hardware is synthesised
once with placeholder RAM contents, and `icebram` writes the new program
into the existing bitstream. `make mcu-prog` after editing
`sw/echo/main.c` takes about a second plus flashing; only HDL changes
re-run Yosys and nextpnr (about 16 s).

## Running the MCU on a Colorlight i9 v7.2

    make i9-prog   # build designs/mcu_i9 with sw/dhrystone_rv32i.bin, load it
    make i9-term   # picocom -b 115200 /dev-host/ttyACM0 (override with I9_TTY=...)

The UART goes through the ext board's DAPLink (USB CDC serial). The
firmware runs Dhrystone (500 runs) and prints cycles and DMIPS; reset the
board (or reload) to run it again. `make -C designs/mcu_i9 flash` writes
the SPI flash instead of the FPGA's SRAM. Results so far are from
simulation only; see [docs/BENCHMARKS.md](docs/BENCHMARKS.md). First
session: [docs/BRINGUP_I9.md](docs/BRINGUP_I9.md).

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
