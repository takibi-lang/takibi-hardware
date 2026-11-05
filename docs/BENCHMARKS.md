# Benchmarks: rv32 vs. the riscv-ice40 survey cores

Measured 2026-10-28. Reproduce with `make -C bench/ref_cores` (needs
network access to fetch the reference cores) and `make test` (our core).

The reference set is the survey in
[MrJake222/riscv-ice40](https://github.com/MrJake222/riscv-ice40) at commit
5f4633a8, using the exact submodule commits it pins
(`bench/ref_cores/fetch.sh`). Its own README reports whole-SoC LUT counts
on the iCE40UP5K and no Dhrystone results, so both tables below were
measured here, under the same conditions for every core.

## Area (core only, Yosys synthesis, no place and route)

Each core alone, configured as in riscv-ice40 (`bench/ref_cores/area.sh`).
No memories or peripherals; the register file is part of each core.

| Core | iCE40 LUT4 | SB_CARRY | FF | SB_RAM40_4K | ECP5 LUT4 | CCU2C | FF | DP16KD | DPR16X4 |
|------|-----------:|---------:|---:|------------:|----------:|------:|---:|-------:|--------:|
| rv32 (this repo, RV32I) | 884 | 94 | 145 | 2 | 1064 | 51 | 177 | 0 | 16 |
| rv32 (this repo, RV32E) | 910 | 94 | 145 | 2 | 1049 | 51 | 177 | 0 | 8 |
| PicoRV32 (ENABLE_COUNTERS=1) | 1678 | 405 | 597 | 4 | 1638 | 211 | 573 | 0 | 32 |
| FemtoRV32 Quark | 883 | 191 | 158 | 4 | 1309 | 103 | 223 | 0 | 32 |
| Hazard3 (riscv-ice40 config) | 3334 | 346 | 572 | 4 | 5286 | 181 | 595 | 0 | 32 |

Notes:
- PicoRV32's counters (64-bit cycle and instret CSRs) account for many of
  its flip-flops; riscv-ice40 enables them for its Dhrystone harness. Our
  core has no CSRs; the MCU's memory-mapped counters are outside the core.
- DarkRISCV is missing: riscv-ice40 builds it with a generation script
  (`darkriscv-build/run.sh`) that is not part of the pinned tree.
- VexRiscv is missing: it is generated from Scala (SpinalHDL).

## Dhrystone (same binary on every core)

`sw/dhrystone_sim.bin`: Dhrystone 2.2 from riscv-tests, 50 runs, built
once with `riscv64-unknown-elf-gcc -O2 -march=rv32i -mabi=ilp32`
(multiply and divide from libgcc), gcc 13.2.0 as shipped with Ubuntu 24.04
(the cloud sessions and CI). Other gcc releases generate different code:
the devcontainer's gcc retires about 1% more instructions (30,481 instead
of 30,138 in the timed loop) and scores 0.219; the CPI (4.25) is the same.
Compare cores only with the same binary. The binary is identical for every core,
so every core retires the same instructions (about 30,100 in the timed loop);
only the cycle count differs. Our core runs in Cyclesim in lockstep with
the golden model (`ip/mcu/test/test_mcu.ml`); the reference cores run in
Icarus Verilog with a memory of the same latency as our block RAM
(`bench/ref_cores/dhrystone.sh`).

| Core | Memory | Cycles / run | DMIPS/MHz | CPI |
|------|--------|-------------:|----------:|----:|
| FemtoRV32 Quark | 1-cycle read latency | 2040 | 0.279 | 3.39 |
| PicoRV32 | zero wait (best case) | 2464 | 0.231 | 4.09 |
| **rv32 (this repo, RV32I)** | 1-cycle read latency (BRAM) | **2562** | **0.222** | **4.25** |
| rv32, Zicsr + dual register-file read (#4 step 1) | 1-cycle read latency (BRAM) | 1898 | 0.299 | 3.26 |
| rv32, + fetch overlap (#4 step 2) | 1-cycle read latency (BRAM) | 1535 | 0.370 | 2.64 |
| rv32, i9 configuration (+ M and A, #5; rv32im binary) | 1-cycle read latency (BRAM) | 1478 | 0.385 | 2.69 |
| **rv32 pipeline (#4: IF, ID, EX, commit; rv32im binary)** | dual-port BRAM, 1-cycle | **916** | **0.621** | **1.67** |
| PicoRV32 | 1-cycle read latency | 3317 | 0.172 | 5.50 |

DMIPS/MHz = 1e6 / (cycles per run x 1757), rounded here; the firmware
itself prints it truncated to thousandths.

The two rv32 rows below the baseline (2026-10-29) are not from the same binary: it is built with the
pinned GCC 15.2 for `rv32i_zicsr` and times the loop with `mcycle`
(29,070 instructions in the timed loop instead of about 30,100), because
the reference cores cannot run that binary unchanged. Compare its CPI
with the other rows, not its cycle count; re-measuring the reference
cores with the pinned toolchain is still to do.

## Reading the results

- rv32 is the smallest core in LUTs on both families (about the size of
  FemtoRV32 Quark on iCE40, 20% smaller on ECP5) and needs no carry chain
  beyond its two adders, at a Dhrystone score between PicoRV32 and
  FemtoRV32.
- Where the cycles go: rv32 spends 4 cycles on every instruction (fetch,
  decode, read rs1, read rs2 + execute) because the register file is a
  block RAM with one read port, and shifts are serial (1 cycle per bit).
  FemtoRV32 reads both registers from LUT/FF storage in parallel and uses
  a 2-cycle decode/execute path for most instructions. A second register
  file read port (duplicated BRAM) or overlapping fetch with execute would
  close most of the gap; see the pipeline issue.
- With the second register-file copy (i9 configuration) every
  instruction takes one cycle less: CPI 4.25 -> 3.26, DMIPS/MHz 0.222 ->
  0.299, for 250 more TRELLIS_COMB cells (distributed RAM).
- Fetching the next instruction in Execute (exact next pc, no
  prediction) saves the Fetch cycle of every instruction that does not
  use the memory bus: CPI 3.26 -> 2.64, 0.370 DMIPS/MHz, for 186 more
  cells (2688 -> 2874), Fmax 57 -> 54 MHz.
- With M (#5) the binary uses MUL/DIV instead of libgcc loops: 6% fewer
  instructions, slightly higher CPI (multi-cycle multiply and divide),
  0.385 DMIPS/MHz.
- The i9 runs at 50 MHz from the PLL (estimated Fmax 52.8 MHz): 0.385 x
  50 = 19.3 DMIPS. Further work on the CPI x Fmax trade-off: issue #23.

## Full designs (place and route)

| Design | Device | Logic | FF | Block RAM | Fmax (needed) |
|--------|--------|------:|---:|----------:|--------------:|
| designs/mcu (RV32E, 4 KiB) | iCE40HX1K | 1059-1093 LC | | 10 / 16 | 45 MHz (12) |
| designs/mcu_i9 (RV32I, 64 KiB) | ECP5 LFE5U-45F | 1491 / 43848 LUT slots | 340 | 32 / 108 DP16KD | 57 MHz (25) |
| designs/mcu_i9, pipelined core (#4, 2026-11-05) | ECP5 LFE5U-45F | 4698 TRELLIS_COMB | | 32 / 108 DP16KD | 40.8 MHz (40): 24.8 DMIPS on the board |
| designs/soc_i9 (Linux SoC, multi-cycle core, cache) | ECP5 LFE5U-45F | 8318 TRELLIS_COMB | | 18 / 108 DP16KD | 52.4 MHz (50): 0.203 DMIPS/MHz in Linux U-mode |
