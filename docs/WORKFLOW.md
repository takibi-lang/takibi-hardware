# Workflow

This document records why this repository uses HardCaml, how it compares
with other hardware description approaches (including for AI-assisted
development), and the workflow we adopt.

## 1. Where HardCaml sits

HardCaml is **not** high-level synthesis. It is a register-transfer-level
(RTL) language embedded in OCaml: the designer still decides every register
and every cycle. What changes is the host language (types, modules,
functors, the OCaml test ecosystem) and the availability of a fast native
cycle simulator (Cyclesim). The experiment here therefore asks whether *RTL
in a strong host language with native simulation* gives cheaper iterations
than Verilog with iverilog/Verilator, not whether HLS works.

Abstraction levels of common alternatives:

| Language | Host | Level | Distance to generated Verilog | Simulator without Verilog |
|----------|------|-------|-------------------------------|---------------------------|
| Veryl | own language | SystemVerilog level | almost none (1:1) | none (Verilator, iverilog, cocotb) |
| HardCaml | OCaml | RTL | small (structural output) | yes: Cyclesim |
| Chisel | Scala | RTL | small (FIRRTL -> CIRCT) | effectively no (treadle deprecated; ChiselSim uses Verilator) |
| SpinalHDL | Scala | RTL | small | no (SpinalSim drives Verilator/iverilog/GHDL) |
| Bluespec | BSV / BH | guarded atomic rules; compiler builds the scheduler | medium (control logic is inserted) | yes: Bluesim, cycle accurate |
| Google XLS | DSLX | dataflow; compiler pipelines and schedules | large | yes: untimed DSLX interpreter/JIT |

Trade-off: the smaller the distance, the more a cheap first-stage test says
about the final hardware, but the less the language abstracts. Only
Bluespec and XLS actually test the "is HLS good enough" question; a future
rewrite of the same CPU in one of them, with its own defect ledger, would
answer that directly.

Notes per language:

- **Veryl**: modern tooling for SystemVerilog (package manager, formatter,
  LSP); readable output; no cheap stage of its own.
- **Chisel**: the largest ecosystem (Rocket, BOOM, Chipyard, Hammer to
  OpenROAD, commercial tape-outs). Cheap stage regressed to Verilator; many
  breaking changes (Chisel 3 -> 5 -> 6), so online material is often stale.
- **SpinalHDL**: catches latches, combinational loops and clock-domain
  crossings at elaboration time with Scala stack traces. VexRiscv is the
  reference RISC-V for iCE40/ECP5.
- **Bluespec**: rule scheduling removes a class of control and hazard bugs,
  which matters most for CPUs. Debugging "why did this rule not fire" is a
  skill of its own; small community.
- **XLS**: the cheapest first stage (untimed functions) but the largest gap;
  closes it with formal equivalence checks and ships process delay models
  (sky130, asap7). ASIC-native, no iCE40 model, heavy Bazel build.

## 2. AI-assisted development

Most code in this repository is written by coding agents, so the language
also has to suit them.

| | Verilog / SV | Veryl | HardCaml | Chisel / SpinalHDL | Bluespec / XLS |
|---|---|---|---|---|---|
| Training data | very large | small | small | medium (Chisel large but stale) | small |
| What catches agent mistakes | lint, simulation | compiler + lint | OCaml type checker, width checks at elaboration, expect tests | Scala types, elaboration checks | rule/type checker, scheduler |
| Feedback loop | C++ build (Verilator) | same | native, seconds | JVM + Verilator | Bluesim / JIT |
| Typical agent failure | width/sign bugs, blocking vs non-blocking, sim/synth mismatch | as Verilog | outdated API from older versions (seen: `select ~high ~low`, `srl ~by`, `<--` on wires) | API drift across versions | unfamiliar semantics |

Observations so far: agents write HardCaml with frequent API slips, but the
compiler rejects every one of them within seconds, and expect tests show the
exact behavioural diff. Errors are cheap; that suits an agent loop. The
largest risk is an agent "fixing" an expect test by promoting a wrong output,
so expected values for new tests should be derived independently (by hand
or from the golden model), as done in `rv32_model/test`.

## 3. The workflow we adopt

### Test ladder

| Stage | What | Command | Runs |
|-------|------|---------|------|
| S0 | OCaml type check, HardCaml elaboration checks; SAT equivalence proofs (`Hardcaml_verify.Sec` + z3) | `dune build`, `make test` | every change |
| S0f | Formal proofs of temporal properties with SymbiYosys (sby: BMC, k-induction, cover) on the generated Verilog; properties in hand-written SystemVerilog next to the .sby files (formal/) | `make formal` | every change |
| S1 | Cyclesim expect tests; OCaml golden model | `make test` | every change |
| S1 | also: riscv-arch-test RV32I (independent reference signatures) on the plain and the i9 core, lockstep; Cyclesim like the rest of S1, but a separate command because it fetches the tests | `make arch-test` | in CI |
| S2 | the same benches on Verilator | `make verilate` | before pushing; in CI |
| S2b | the generated board Verilog with firmware, four-state, pin-level UART (Icarus) | `make board-sim` | every change |
| S2n | post-synthesis: the Yosys iCE40 and ECP5 netlists read back into HardCaml (`hardcaml_of_verilog`, cell models in `testlib/netlist`); the MCU benches in lockstep (iCEstick echo, i9 interrupt test), and the board tops with the firmware only in block RAM initial values and the full start-up hold | `make netlist-sim` (i9 board top: `make netlist-sim-i9`) | every change (i9 board top: in CI) |
| S3 | Yosys + nextpnr (LCs, Fmax), expected BRAM count, naming check | `make synth names` | every change |
| S4 | iCEstick (frozen), Colorlight i9 | `make mcu-prog`, `make i9-prog` | milestones, by hand |

Two axes run in parallel from the first module:

1. **Function** (S1, S2): proven inside OCaml. Testbenches are libraries
   that take a `Cyclesim.t`, so S1 and S2 run identical stimulus and checks.
   For the CPU, the core will produce the same retirement record as
   `rv32_model` and the bench will compare them instruction by instruction.
2. **Physical** (S3): synthesized from day one. On a 1280-LC part, "does it
   fit" fails before "does it work". LC count and Fmax are logged per change.

### What each stage cannot see

Cyclesim is a zero-delay, two-state simulator. It cannot see timing (setup,
hold, Fmax), X propagation (uninitialised state), what Yosys infers (BRAM
vs. LCs), clocking and PLLs, or pin assignment. S3 covers resources, Fmax
and inference; S4 covers the rest. HardCaml's structural output makes
simulation/synthesis mismatches unlikely; S2n checks that claim by running
the benches on what Yosys produced.

### Three-stage simulation (RTL, post-synthesis, post-route)

The usual FPGA ladder simulates the RTL, the post-synthesis netlist and
the placed-and-routed netlist with cell delays (issue #19). Here:

- RTL: S1, S2, S2b.
- Post-synthesis: S2n, inside the HardCaml ecosystem, for both families
  (`synth_ice40`, `synth_ecp5`). Yosys's netlist becomes a HardCaml
  circuit, so the same OCaml benches (including lockstep against the
  golden model) run on it in Cyclesim. Each cell model is checked against
  the RTL of a small design in every block RAM port width (ECP5 also with
  initial contents read back, because Yosys ships no DP16KD model), and
  complementing every LUT must make the stage fail. Flip-flops start at
  the value the cell model gives them (iCE40: 0; ECP5: their set/reset
  value), so power-up assumptions are tested too (B-0023). Two-state
  only: X propagation stays with S2b.
- Post-route with delays: not simulated. The designs have one clock and
  one synchronised asynchronous input (UART RX); nextpnr's static timing
  analysis (S3) checks every path, which a delay simulation cannot. This
  changes with the Ethernet MAC (RGMII receive clock from the PHY): see
  issue #22 for the clock-domain-crossing plan.

### Iteration rules

- Every defect goes into `BUGS.md`, including those caught at S0/S1
  during development before a commit.
- A defect seen at S2 or S4 gets a regression test at the cheapest stage
  that reproduces it, and a `BUGS.md` entry with "found at" and "catchable
  at". Defects that remain catchable only at S4 are the experiment's answer.
- Bring every new kind of I/O to the board early (blink, then UART, then the
  core), so reset, clocking, BRAM and pinout problems surface once; after
  that, core development stays at S1-S3 between milestones.
- The UART is the board's printf: tests compare the same byte stream from
  Cyclesim, Verilator and the board.

### Program loading without a bootloader

A UART bootloader would cost logic on a 1280-LC device. Instead:

1. The board generator (`designs/mcu/bin/main.exe placeholder`) fills the
   RAM with pseudo-random bytes (fixed seeds) and writes them to
   `placeholder_bN.hex`, one file per byte lane. This design is
   synthesised and placed once (`build/placeholder.asc`, about 16 s).
2. `main.exe hex` splits the firmware into `firmware_bN.hex`.
3. `icebram` finds each lane's BRAMs by their placeholder contents and
   replaces them with the firmware (`build/top.asc`), then `icepack`.
   A firmware-only change takes about 0.3 s.

Checks: every build verifies that only `.ram_data` sections changed
(`scripts/strip_ram_data.sh`); `make icebram-check` (part of `make ci`)
verifies that the result is byte-identical to synthesising with the
firmware directly. The placeholder must be random: icebram cannot locate
low-entropy contents such as runs of zeros, and the register file's
all-zero BRAMs must never match. Simulators load the same image through
the MCU's load port.

### What runs where (MCU)

| Check | Stage | Cost |
|-------|-------|------|
| ALU and immediate generator equal their references (SAT, all inputs) | S0 | < 1 s |
| Decoder classifies 362k instruction words like the golden model | S1 | ~1 s |
| Core lockstep: directed programs, every trap, 300 random programs | S1 | ~2 s |
| MCU runs the C echo firmware, UART in/out, lockstep (46k instructions) | S1 | ~2 s |
| Same MCU test on Verilator | S2 | ~11 s |
| Same MCU test on the Yosys iCE40 netlist (lockstep) | S2n | ~17 s |
| iCEstick top netlist boots from BRAM INIT, echoes at pin level | S2n | ~12 s |
| i9 MCU ECP5 netlist: interrupt test in lockstep | S2n | ~30 s |
| i9 top ECP5 netlist: full start-up hold, firmware from DP16KD INITVAL | S2n (`make ci`) | ~65 s |
| Fits: LC budget, exactly 10 BRAMs, Fmax, all flip-flops named | S3 | ~16 s |
| icebram swap equals direct synthesis | S3 (`make ci`) | ~16 s |

### CPU plan

- ISA: RV32E only (16 registers), no compressed instructions, no CSRs
  beyond what ecall/ebreak need to stop a test.
- Microarchitecture: multi-cycle, not pipelined, register file in BRAM.
- Golden model: `rv32_model`, used in lockstep by the core's bench.

### Out of scope for now

ASIC concerns (SRAM macros, OpenROAD, Tiny Tapeout) are deferred; when they
come, a substantial rewrite is expected. Only the naming and hierarchy
discipline is enforced now, because it is cheap to keep and expensive to
add later.
