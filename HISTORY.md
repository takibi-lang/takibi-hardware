# History

A dated log of the project, newest entry first. Each entry records what was
done, what was learned, and the numbers measured that day.

## 2026-10-29: M and A extensions in the core (#5, Linux L1)

- Decoder: M, A, FENCE.I behind flags; checked against the model on 1.67M
  words (all A funct5 codes with aq/rl now in the exhaustive part).
- Core: multiply in one extra cycle (33 x 33 product registered, 4
  MULT18X18D on the ECP5), restoring divide (32 cycles), LR as a load
  with a reservation, SC in Execute, AMO read / register / write. Core
  ~reset_pc for tests linked at 0x8000_0000.
- Checks: random lockstep with M/A and random interrupts (0 failures),
  riscv-arch-test M 8/8 on the core, riscv-tests rv32ui/um/ua 59/59 on the
  core in lockstep with the model. testlib/netlist: MULT18X18D model,
  checked against RTL (3000 random products, 0 mismatches).
- B-0024 (S3): the one-cycle AMO read-modify-write missed 50 MHz (45.6
  MHz); fixed with an extra state, 52.8 MHz.
- i9: 3981 TRELLIS_COMB (budget 4500), Dhrystone 0.385 DMIPS/MHz (19.3
  DMIPS at 50 MHz), CPI 2.69.

## 2026-10-29: Linux plan (#21) and L0 on the golden model (#25)

- Maintainer decisions for #21: MMU (Sv32, S-mode Linux), own M-mode boot
  stub instead of OpenSBI, UART with interrupts (16550 + PLIC), DTB at a
  fixed offset in the flash read in place, no XIP, a C REPL as the only
  user program (shared with Takibi for benchmarks). Child issues #24-#29;
  closed #13, #15, #17.
- rv32_model: M, A, Zifencei, S/U modes with delegation, S-mode CSRs,
  SRET, SFENCE.VMA, Sstc, counter enables, Sv32 with Svade, PMP/trigger
  CSRs reading zero, RAM at a configurable base. Behaviour without the new
  flags unchanged (all core lockstep suites pass).
- Independent checks: riscv-arch-test M 8/8 on the model; riscv-tests
  139/139 on the model (rv32ui/um/ua in p and v environments, rv32mi,
  rv32si; ma_data and pmpaddr skipped with reasons).
- Toolchain: Linux 6.18.59 LTS and Bootlin riscv32 musl GCC 15.3.0 pinned
  (the bare-metal xPack GCC cannot link the kernel's vDSO); flex, bison,
  bc, cpio from apt.
- models/soc_model: Soc_map (single source for the memory map), CLINT,
  PLIC, 16550 models, device tree and C header generated from it.
  sw/linux/boot: 316-byte boot ROM with the M-mode stub; sw/repl: 9.8 KB
  REPL on nolibc.
- Result (`make linux-model`, in CI): the model boots Linux to the REPL and
  the REPL answers. Every L0 question answered: SBI base + Sstc is
  enough; the DTB in the flash window works; Svade works; a Linux GCC is
  needed for the kernel; the boot to init takes 30.6M instructions
  (35M with five REPL commands), the kernel 2.2 MB, 5.5 MB of 8 MB RAM
  free. The model runs at about 4 MIPS (boot to the REPL in 9 s).

## 2026-10-29: i9 system clock 50 MHz from the PLL

- The maintainer asked to measure performance as DMIPS (CPI x Fmax) and to
  optimise later (#23); for now the i9 runs at 50 MHz, below the
  estimated Fmax of 54 MHz.
- designs/mcu_i9/src/pll.ml: EHXPLLL with dividers searched for the target
  (same as ecppll for 50 MHz: CLKI 1, CLKFB 2, CLKOP 12). The MCU is held
  in reset until the synchronised LOCK and the start-up hold. One setting
  (Mcu_i9.clock_mhz) drives the PLL, nextpnr (`main.exe clock-mhz`), the
  UART divider, the hold and the testbenches. EXPERIMENT=no-pll runs from
  the 25 MHz pin.
- Checked: a target above Fmax fails the build (70 MHz: "FAIL at 70.00
  MHz", make exits with an error).
- Icarus board-sim: behavioural EHXPLLL stand-in (tb_cells.v, lock after
  50 us). Netlist stage: EHXPLLL as CLKOP = CLKI, locked (one clock).
- i9: 54.07 MHz estimated at 50, 2798 TRELLIS_COMB; Dhrystone 0.370
  DMIPS/MHz = 18.5 DMIPS. The i9 netlist stage now takes about 2 minutes
  (the hold is twice as many cycles).

## 2026-10-29: fetch overlap (#4, step 2)

- Core ~fetch_overlap: an instruction that does not use the memory bus
  fetches its successor in Execute at the exact next pc and goes on to
  Decode; not after CSR/MRET, not when an interrupt is due. The `fetch`
  output marks the boundary where the interrupt decision is made, and
  the benches sample irq there.
- Lockstep (random programs with and without random interrupts, directed
  interrupt tests, riscv-arch-test 37/37, the i9 netlist stages) passed
  on the first run; no defect.
- i9 Dhrystone: CPI 3.26 -> 2.64, 1535 cycles/run, 0.370 DMIPS/MHz
  (9.3 DMIPS at 25 MHz). 2874 TRELLIS_COMB, 53.8 MHz. iCEstick unchanged.

## 2026-10-29: post-synthesis stage for the ECP5 (S2n); B-0022, B-0023

- docs/WORKFLOW.md and BUGS.md stage tables brought up to date (S2b was
  missing in BUGS.md; S2n and S4 now name both boards).
- testlib/netlist: ECP5 cell models (LUT4, PFUMX, L6MUX21, CCU2C,
  TRELLIS_FF, TRELLIS_DPR16X4, DP16KD). Yosys has no DP16KD model, so the
  cell test also reads back initial contents in every width; that found
  B-0022 in our own model (narrow modes skip array bit 8).
- i9 MCU netlist (2260 LUT4, 32 DP16KD): interrupt test in lockstep,
  60k instructions, 342 interrupts, about 30 s (`make netlist-sim`).
- i9 top netlist, full start-up hold, firmware only in DP16KD INITVAL
  (`make netlist-sim-i9`, about 65 s, in CI). It found B-0023: Yosys had
  mapped the hold counter's msb to a flip-flop that powers up as 1, so
  the i9 would have skipped the B-0014 hold. Fix: the generator states
  power-up 0 for every register without a reset. First byte now at
  21.2 ms. i9 2688 TRELLIS_COMB.
- Issue #22 filed: clock-domain-crossing plan for the Ethernet MAC
  (RGMII); #19 got an addendum.

## 2026-10-29: dual register-file read (#4, step 1)

- Core ~dual_read: a second register-file copy, read in Decode together
  with the first, removes the Read_rs2 state. On in the i9 configuration,
  off on the iCEstick (frozen, 1122 LCs unchanged).
- Lockstep: the random suites (with and without Zicsr and random
  interrupts) and riscv-arch-test (37/37) also run on the dual-read core;
  all passed on the first run, no defect.
- Dhrystone on the i9 (pinned GCC 15.2, rv32i_zicsr): CPI 4.26 -> 3.26,
  1898 cycles/run, 0.299 DMIPS/MHz (7.5 DMIPS at 25 MHz). Area 2516 ->
  2766 TRELLIS_COMB (budget raised to 3200), 57.0 MHz.

## 2026-10-29: Zicsr, traps and interrupts in hardware (#3)

- The maintainer froze the iCEstick (full); new features go to the ECP5
  only. The board check of the 21.8 ms start-up hold (B-0017) passed.
- Decoder: CSR, MRET, WFI behind ~zicsr; 362k words per configuration
  agree with the model.
- Core ~zicsr: M-mode CSRs as in rv32_model, mcycle/minstret, trap entry
  once mtvec <> 0, MRET, interrupts in Fetch (external > software >
  timer). Lockstep takes mip and the counters from the hardware, injects
  interrupts where the core took them and checks priority and missed
  interrupts (negative tests). Random programs with CSR accesses and
  random interrupts: 600 programs, 87k instructions, 2696 interrupts, 0
  failures.
- MCU Config.zicsr (i9): IRQ_ENABLE (UART RX/TX -> MEIP), MSIP, 64-bit
  MTIME/MTIMECMP (MTIP); sw/irq exercises every source in lockstep;
  Dhrystone reads mcycle/minstret (CPI 4.26). MMIO CYCLE/INSTRET dropped
  on the i9.
- Area (pinned toolchain): i9 1438 -> 2516 TRELLIS_COMB (budget 2800),
  60.3 MHz; iCEstick 1122 LCs (Zicsr off).
- Defects: B-0019 (S0), B-0020, B-0021 (S1).

## 2026-10-29: pinned toolchain (#11, #12)

- toolchain/: OSS CAD Suite 2026-10-28 (Yosys 0.70+255, nextpnr 0.11.1+83,
  Icarus 14 devel, Verilator 5.053 devel, z3 4.15.5), xPack
  riscv-none-elf-gcc 15.2.0-1 (multilibs rv32e, rv32i, rv32im), and the
  127 opam packages (hardcaml v0.17.1) with exact versions.
- scripts/toolchain.sh installs them under ~/.takibi-hardware (bind mount
  in the devcontainer, actions/cache in CI keyed by each pin, the same
  script in cloud sessions); `check` fails on unpinned tools (selftest).
  apt no longer installs EDA tools or the cross compiler.
- scripts/with-toolchain.sh DATE|pinned|system runs any command with
  another OSS CAD Suite, building into build-<toolchain>/, to tell tool
  defects from ours.
- New reference numbers (pinned toolchain): iCEstick MCU 1143 LCs (1110 on
  Yosys 0.33), 46.0 MHz; hello 115 LCs (113); i9 58.4 MHz; Dhrystone CPI
  4.27 (4.25 with gcc 13). B-0018: the netlist reader had to skip Yosys
  0.70's $scopeinfo cells.

## 2026-10-29: three-stage simulation survey (#19), post-synthesis stage (#20)

- Survey of the article on RTL / post-synthesis / post-route simulation:
  RTL was covered (S1, S2, S2b), post-synthesis was missing, post-route
  delay simulation adds nothing over nextpnr's STA for this design.
- Readable Verilog: intermediate signals named with let%hw / let%hw_var /
  apply_names in the UART, hello, core and MCU. Anonymous wires: mcu
  745 -> 695, hello 116 -> 109; LCs unchanged. Full_path naming rejected
  (redundant prefixes in non-flattened modules), auto_label_hierarchical_
  ports has no effect without flattening.
- S2n (`make netlist-sim`): Yosys netlist read back with
  hardcaml_of_verilog, iCE40 cells modelled in OCaml (testlib/netlist).
  The MCU lockstep bench passes on the netlist (46,207 instructions,
  200k cycles in 13 s); the iCEstick top netlist boots from BRAM INIT and
  echoes at pin level (12 s). An Icarus gate-level run of the same netlist
  was too slow for the gate. Negative tests: inverted LUTs fail both the
  cell test and the MCU run.
- B-0017: the start-up hold was 10.9 ms, not the documented >= 20 ms
  (counter one bit short since 80f33cd). Fixed (21.8 ms at 12 MHz), S1
  test added. iCEstick 1110 LCs.

## 2026-10-29: riscv-arch-test (#17)

- bench/arch_test: riscv-arch-test 2.7.4 (the last release that ships
  reference signatures, produced by independent simulators) fetched on
  demand; our model_test.h ends tests with EBREAK, no trap handler (no
  CSRs yet). The runner executes each test on the core in Cyclesim in
  lockstep with rv32_model and compares the signature with the reference.
- Result: 37/37 RV32I tests pass (about 5 s); jalr-01 is skipped because
  it does not assemble with current binutils (`la x0, 5b`). This is the
  first check of the core and the golden model against an oracle that is
  not ours. No defect found.
- Not covered yet: RV32E (the 3.x tests have no shipped references; they
  could be run against our model only), tests needing traps (#3).

## 2026-10-29: i9 bring-up preparation (#16)

- Issues filed: toolchain pinning and checks (#11-#15, to be done in a
  later session with persistent storage), i9 bring-up (#16),
  riscv-arch-test (#17).
- Mcu.Startup: the start-up reset hold (about 20 ms at any clock,
  EXPERIMENT=no-hold) shared by both board tops.
- i9 top: reset hold; the single LED shows slow blink (not started),
  steady (firmware started, set by crt0), fast blink (core halted).
- i9 board simulation (Dhrystone 50 runs, pin-level UART) passes; it takes
  about 2 minutes in Icarus, so it runs in `make ci` and before
  `make i9-prog`, not in `make`.
- docs/BRINGUP_I9.md: checklist for the first board session.

## 2026-10-28 (late night): B-0014 root cause by ablation

- On the board: EXPERIMENT=no-hold fails (no output), EXPERIMENT=
  no-regfile-init works. The cause is starting the core 1.25 us after
  configuration; the 22 ms reset hold fixes it. S4-only: board-sim passes
  without the hold.
- Lesson recorded in AGENTS.md: change one thing per board experiment or
  provide an ablation switch; here the switch made a second round trip to
  the board enough.

## 2026-10-28 (night): board works; audit of all defects

- The diagnostic build (80f33cd) works on the iCEstick: banner, echo and
  upper-cased lines. designs/hello also works, so pins and port were
  never the problem.
- Audit (BUGS.md, "Analysis"): no functional RTL defect has escaped the
  cheap stages; the one board-only defect is about power-up state, the
  class two-state Cyclesim hides by construction. Two changes were made
  at once, so the root cause of B-0014 is still to be decided by an
  ablation on the board (EXPERIMENT=no-hold / no-regfile-init).
- The maintainer's build log showed 1139 LCs (over budget) yet flashed:
  `prog` now requires all S3 checks; tool versions are recorded per build
  (B-0015).

## 2026-10-28 (evening): first board test, no UART output (B-0014)

- The maintainer flashed designs/mcu onto the iCEstick: no banner, no echo.
  First S4 observation of the project.
- Added `make board-sim`: the exact generated Verilog (board top + MCU,
  firmware loaded by $readmemh) in Icarus Verilog with a pin-level UART
  model. It boots, prints the banner and echoes, so the fault is not in
  the RTL, the firmware or the RAM initialisation as simulated.
- Four-state simulation exposed two implicit assumptions about silicon:
  registers without reset start at 0 (modelled in the testbench, since
  HardCaml v0.17 cannot express initial register values) and the
  register file starts at 0 (now explicit in the generated Verilog).
- A first hypothesis (non-zero register file in the bitstream) was checked
  against the flashed .asc and rejected.
- Diagnostic build for the next board test: 22 ms reset hold after
  configuration, LEDs for heartbeat / halted / firmware progress.
- Expect tests no longer contain compiler-dependent counts (B-0013): the
  devcontainer's gcc differs from Ubuntu 24.04's.

## 2026-10-28 (later): RV32I, Colorlight i9 port, Dhrystone and comparison

Direction (maintainer): target the Colorlight i9 v7.2 (ECP5 LFE5U-45F)
instead of pico-ice; first RV32I plus a Dhrystone and area comparison with
the riscv-ice40 survey cores; pipeline, M, MMU, caches/SDRAM, Ethernet MAC
and dual core are deferred to issues.

- RV32I: the golden model, decoder and core take `base` (Rv32i | Rv32e).
  The decoder matches the model on 362k words for both; random lockstep
  passes for both (31k and 41k instructions). The register file grows
  from 16 to 32 entries at no block-RAM cost.
- ip/rv32e renamed ip/rv32; the MCU moved to ip/mcu with a Config
  (base, RAM size, baud divider, optional counters); designs/mcu and the
  new designs/mcu_i9 are thin board tops sharing ip/mcu/gen.
- Firmware: minimal libc (printf, string functions), linker scripts per
  RAM size, sw/build.sh; Dhrystone 2.2 from riscv-tests (BSD) with a
  harness reading memory-mapped CYCLE/INSTRET.
- Dhrystone runs in Cyclesim in lockstep with the model (48k instructions,
  no mismatch): 2562 cycles/run, CPI 4.25, 0.222 DMIPS/MHz.
- Colorlight i9 flow (mk/ecp5.mk): synth_ecp5, nextpnr-ecp5, ecpbram swap
  (bit-identical to direct synthesis), ecppack, openFPGALoader. 1491/43848
  LUT slots, 340 FFs, 32 DP16KD (64 KiB), 57 MHz against 25 MHz. Pins from
  wuxx/Colorlight-FPGA-Projects (clock P3, UART J17/H18 via the ext
  board's DAPLink, LED L2); not yet tried on hardware.
- Reference comparison (docs/BENCHMARKS.md): same Dhrystone binary on
  PicoRV32 and FemtoRV32 Quark in iverilog; core-only area for those and
  Hazard3. rv32 is the smallest core in LUTs; its Dhrystone score (0.222)
  sits between PicoRV32 with 1-cycle memory (0.172) / zero-wait memory
  (0.231) and FemtoRV32 Quark (0.279). The 4-cycle minimum per
  instruction (single-port register file in block RAM) is the main cost.
- Build-time finding: per-byte `initial` assignments for 64 KiB took Yosys
  5.5 minutes; `$readmemh` takes seconds (B-0012).
- Defects: B-0009..B-0012 (one resource, caught by the LC budget; the rest
  in scripts and testbenches). Again no functional RTL defect.

## 2026-10-28: RV32E MCU running C over UART (simulation and synthesis)

- Layout: reusable blocks in `ip/`, board top levels in `designs/`, golden
  models in `models/`, firmware in `sw/` (OpenTitan-style ip/top split).
- ip/uart: added a receiver (two-flop synchronizer, mid-bit sampling), a
  serial-line driver and an incremental monitor for benches, and an ASCII
  waveform test. hardcaml_waveterm only draws Unicode boxes, so
  `testlib/ascii_wave.ml` maps them to `-|+`.
- ip/rv32e: multi-cycle RV32E core (4 cycles per instruction, loads 5,
  shifts 5 + shamt; serial shifter instead of a barrel shifter to save
  area). ALU (one shared 33-bit adder for ADD/SUB/SLT/SLTU/branches) and
  immediate generator (per-bit-range muxes) are proved equal to plain
  references with Hardcaml_verify.Sec + z3; a mutant proves the check can
  fail. The decoder matches the golden model on 362,148 words. The core
  matches the model in lockstep on directed programs, every trap, and 300
  random 80-instruction programs (all passed on the first run).
- models/rv32_model: memory-mapped I/O hooks. In lockstep, I/O loads take
  the value the hardware read, because UART status depends on timing.
- designs/mcu: core + 4 KiB RAM (four 1024 x 8 byte lanes) + UART + LEDs.
  sw/echo (C, riscv64-unknown-elf-gcc -march=rv32e -mabi=ilp32e, 431
  bytes) runs in Cyclesim and on Verilator: banner, echo, upper-cased line,
  line length on the LEDs; 46,208 instructions in lockstep, no mismatch.
- iCE40HX1K: 1079/1280 LCs (84%), 10/16 BRAMs, 46 MHz (12 MHz needed).
- S3 additions: `check_resources.sh` (exact BRAM count per design);
  `check_names.sh` now only counts clocked flip-flops.
- Costs: all S0/S1 tests ~5 s; MCU on Verilator ~11 s; MCU synthesis ~16 s.
- Defects: B-0004..B-0008. The cheap stages found everything so far, but
  all hardware-relevant defects were in testbenches and checks, not in the
  RTL; nothing has been on a board yet.
- Later the same day: `make mcu`, `make mcu-prog`, `make mcu-term` at the
  top level; per-design logic-cell budgets (MAX_LC; mcu 1130, blink 50,
  hello 150) enforced by check_resources.sh, with self-tests.
- icebram flow for the MCU: synthesise once with pseudo-random placeholder
  RAM contents, then swap the firmware into the bitstream per byte lane.
  Firmware-only rebuild: 16.5 s -> 0.33 s. The swapped bitstream is
  byte-identical to direct synthesis (checked by `make icebram-check`).
  Learned: swapping back is impossible because firmware has runs of
  zeros that icebram cannot locate, so the per-build check compares the
  bitstream minus `.ram_data` instead.
- Policy: GitHub text (issues, comments, PRs) must be English ASCII,
  enforced by Claude Code and Codex PreToolUse hooks modelled on takibi.
- Tools added: z3 (SAT for Hardcaml_verify), hardcaml_verify,
  gcc-riscv64-unknown-elf.

## 2026-10-26: toolchain, test ladder, UART, RV32E model

- Verified that the devcontainer toolchain also works in a Claude Code cloud
  session (Ubuntu 24.04): yosys, nextpnr-ice40, icestorm from apt; OCaml
  5.3.0 and hardcaml v0.17.1 from opam. Cloud sessions do not use the
  devcontainer, so `.claude/hooks/session-start.sh` now installs the same
  tools. The network policy had to allow `opam.ocaml.org`; with that, all
  sources came from the opam cache even while `codeload.github.com` was
  still blocked.
- Built the test ladder (docs/WORKFLOW.md): S1 Cyclesim expect tests, S2 the
  same bench on Verilator via hardcaml_verilator, S3 Yosys + nextpnr with a
  flip-flop naming check, S4 the board (`make prog`, by hand).
- blink: split into library / generator / test; uses `Hierarchy` and a
  named counter. 29 LCs, ~179 MHz.
- uart: 8N1 transmitter (Always state machine) and a "Hello, iCEstick!"
  top level with a power-on reset (the board has no reset button). Software
  UART decoder in the bench, so the same expected bytes apply to Cyclesim,
  Verilator and a terminal capture from the board. 113 LCs, ~143-160 MHz
  (varies with placement seed), 0 anonymous flip-flops.
- Stage cost: `dune test` for all projects ~2 s incremental; the Verilator
  stage for uart ~21 s (two C++ model builds).
- rv32_model: RV32E decoder, executor with a per-instruction retirement
  record (for future lockstep comparison with the core), traps, and a small
  assembler so tests need no RISC-V toolchain.
- Defects found: three, all at S1 or S3 (BUGS.md B-0001..B-0003).
- Toolchain findings:
  - HardCaml v0.17 API differs from older examples: `select s hi lo` is
    positional; wires use `<==`.
  - hardcaml_verilator v0.17.0 hard-codes `--no-threads` for Verilator 4,
    which Verilator 5 rejects; set `verilator_version = V5`. In quiet mode
    it runs `cmd &>file` through /bin/sh; dash parses that as a background
    job, so the build races the link and fails with "Could not find
    verilator shared library". Workaround: `verbose = true`.
- Policy: English/ASCII-only repository, enforced by `.githooks/` and CI
  (modelled on takibi-lang/takibi).
- Policy: defects caught at every stage, including S0 (elaboration) and S1
  failures fixed before committing, are recorded in BUGS.md.
- Policy: agents push directly to `main`; no branches or pull requests.
- Decision on a UART bootloader: not now. It would cost LCs on a 1280-LC
  part. Program images will instead be swapped into the BRAM initial values
  of an already placed-and-routed bitstream with `icebram`, which takes
  seconds and costs no logic (docs/WORKFLOW.md).
