# takibi-hardware: agent and contributor guide

This is the canonical guidance file for every coding agent (Claude Code,
Codex, ...) and human contributor. `CLAUDE.md` only points here.

## Goal

Build a small RV32E CPU entirely in HardCaml and run it on an iCEstick
(Lattice iCE40HX1K-TQ144, 12 MHz, 1280 LCs, 8 KB BRAM) through the open
Yosys / nextpnr / icestorm flow.

The real research question: can cheap HardCaml-level verification (Cyclesim,
expect tests, an OCaml golden model) catch most hardware defects before the
expensive stages (Verilator, synthesis, the board)? `BUGS.md` collects the
evidence; `docs/WORKFLOW.md` describes the method.

## Always-on rules

- **License.** The repository is GPL-3.0-or-later, dual-licensed
  commercially by the maintainer (README.md, `LICENSE`). Contributions
  from anyone but the maintainer need the agreement in `CLA.md`; work by
  coding agents at the maintainer's direction does not. Never copy code
  in under a license that conflicts with this; third-party files keep
  their own license file next to them (e.g. `sw/dhrystone/`).
- **English and ASCII only.** Every file, file name, commit message, code
  comment and document in this repository is written in English using ASCII
  characters only, even when the maintainer talks to you in another
  language. Enforced by `make langcheck`, the git hooks in `.githooks/`
  (enabled by `make setup`) and CI. Do not bypass them with `--no-verify`.
  Write "->" not arrows, "--" not dashes, plain quotes not curly ones.
- **GitHub text is English ASCII too.** Issue titles and bodies, comments,
  pull requests and reviews are written in English using ASCII only, even
  when the maintainer writes to you in Japanese; translate the request.
  Agent hooks enforce this (`scripts/hooks/github-text-ascii-policy.sh`,
  wired into `.claude/settings.json` and `.codex/hooks.json`). Agents
  without hooks (e.g. opencode) must follow this rule by hand.
- **Generated Verilog is an artifact.** Never edit it; change the HardCaml
  source and regenerate.
- **Name every flip-flop.** Use `let%hw`, `let%hw_var` or `(--)` for every
  register, and build designs with `Hierarchy.In_scope` so module boundaries
  survive into the Verilog. `make names` fails on anonymous flip-flops.
- **Test cheapest first.** Every design module gets a Cyclesim expect test in
  its project's `test/` directory before it goes to the board. Testbenches
  live in a library that takes a `Cyclesim.t`, so the same bench also runs on
  Verilator (see `designs/mcu/bench`).
- **Prove what can be proved.** When a block has an area-optimised
  implementation, keep a straightforward `reference` next to it and prove
  them equivalent with `Hardcaml_verify.Sec` (see `ip/rv32e/test/test_formal.ml`).
  Every checker (formal, lockstep, naming) also gets a negative test showing
  it can fail.
- **Memories must land in block RAM.** Build RAMs with `Ram.create`
  (registered read port) and the `no_rw_check` attribute, never read and
  write the same RAM in the same cycle when the read data is used, and set
  `EXPECT_BRAM` in the project Makefile; `make` fails if nextpnr places a
  different number of SB_RAM40_4K blocks.
- **Every defect is recorded in `BUGS.md`, at every stage, S0 and S1
  included.** This covers failures you hit and fix yourself while developing,
  before anything is committed: a failing expect test, a width error from
  HardCaml elaboration, a golden-model mismatch. Cheap-stage catches are the
  experiment's main data; leaving them out makes the cheap stages look
  useless. Not recorded: OCaml syntax errors and API misuse (wrong function
  name or argument labels); count those only in `HISTORY.md` if notable.
  A defect first seen at S2 or later must get a regression test at the
  cheapest stage that can reproduce it, or an explanation of why none can.
- **Push directly to `main`** (maintainer, 2026-10-26). No feature branch
  or pull request is needed; run `make` (or `make ci`) before pushing so
  `main` stays green.
- **Do not rely on implicit power-up state** (B-0014). Board top levels
  hold the core in reset for a documented time after configuration (the
  iCEstick: about 22 ms) before any block RAM is read. Memories whose
  initial contents matter are initialised explicitly in the generated
  Verilog. Registers without a reset are listed in the board testbench
  with their silicon power-up value. `make board-sim` (four-state,
  pin-level) must pass.
- **Board experiments change one thing at a time**, or provide an
  ablation switch (`EXPERIMENT=...`), so that a fix also identifies the
  cause.
- **Toolchain-dependent numbers** (instruction counts, LC counts, Fmax)
  are compared only within one toolchain; `scripts/versions.sh` records
  it (B-0013, B-0015).
- **The iCEstick design is frozen** (maintainer, 2026-10-29): the
  iCE40HX1K is full (about 1120 of 1280 LCs). New features go into the
  ECP5 configuration only (`designs/mcu_i9`, `Mcu.Config` flags such as
  `zicsr`); shared IP keeps them behind a parameter so the iCEstick build
  stays as it is and keeps passing `make`.
- **Keep `HISTORY.md` up to date.** Add a dated entry with the gist of each
  working session: what was done, what was learned, measured numbers.
  Newest entry first. Do not turn `README.md` into a log.
- **Keep `README.md` current.** It describes the present state, not the
  history: the main target (the Linux SoC on the Colorlight i9), what it
  runs, how to build and run it, and the project table. Update it in the
  same commit when a feature, board, make target or directory changes.

## Layout

Follows the usual HDL split between reusable IP and chip/board top levels
(as in OpenTitan's `hw/ip` and `hw/top_*`).

| Path | What |
|------|------|
| `ip/uart/` | 8N1 UART transmitter and receiver; bench with line driver and monitors |
| `ip/rv32/` | RV32I/RV32E core: ALU, immediate generator, decoder, multi-cycle core; lockstep bench |
| `ip/mcu/` | The MCU (core + RAM + UART + LEDs + counters) with a `Config.t`; `gen/` holds the board generators' shared code |
| `designs/blink/` | LED blinker, the smallest end-to-end example |
| `designs/hello/` | Prints "Hello, iCEstick!" over the UART |
| `designs/mcu/` | iCEstick top for the MCU (RV32E, 4 KiB) |
| `designs/mcu_i9/` | Colorlight i9 (ECP5 LFE5U-45F) top for the MCU (RV32I, 64 KiB); `mk/ecp5.mk` flow |
| `bench/ref_cores/` | Reference cores (riscv-ice40 survey): area and Dhrystone, see docs/BENCHMARKS.md |
| `models/rv32_model/` | RV32I/RV32E golden model (OCaml), MMIO hooks, tiny assembler |
| `sw/` | Firmware (crt0, linker scripts, `mcu.h`, minimal libc, echo, Dhrystone) |
| `testlib/` | Test helpers: ASCII waveforms, shared Verilator config; `testlib/netlist`: Yosys iCE40/ECP5 netlists back into HardCaml (S2n) |
| `mk/icestick.mk`, `mk/ecp5.mk` | Shared board flows (iCE40: icepack/icebram; ECP5: ecppack/ecpbram) |
| `scripts/` | Policy and S3 checks (`check_ascii.sh`, `check_names.sh`, `check_resources.sh`) |
| `docs/WORKFLOW.md` | HDL landscape, AI-assisted workflows, and the workflow we adopt |

An IP block (`ip/<name>/`) has `src/` (library), `test/` (S0/S1 tests) and
usually `bench/` (testbenches taking a `Cyclesim.t`). A board design
(`designs/<name>/`) adds `bin/main.ml` (prints Verilog for module `top`),
optionally `verilator/` (S2), an `icestick.pcf`, and a short `Makefile`
setting `PROJECT`, `EXPECT_BRAM`, `MAX_LC` and optionally `FIRMWARE` before including
`../../mk/icestick.mk`. Add new designs to `BOARD_PROJECTS` in the root
`Makefile` and to the table in `README.md`.

## Commands

    make                     # per-commit gate: langcheck, S0/S1, synth + S3 checks
    make ci                  # also runs the Verilator stage (S2)
    make -C designs/mcu      # build designs/mcu/build/top.bin with sw/echo.bin inside
    make mcu-prog            # flash it (needs a board on USB)
    make mcu-term            # talk to it at 115200 baud

Firmware-only changes do not re-synthesise: the MCU bitstream is built
with placeholder RAM contents and `icebram` swaps the firmware in
(docs/WORKFLOW.md, "Program loading").

## Environment

The toolchain is pinned (issues #11, #12) and the same everywhere:

| Pin | File |
|-----|------|
| OSS CAD Suite release (Yosys, nextpnr, icestorm, trellis, Icarus, Verilator, z3, openFPGALoader) | `toolchain/oss-cad-suite.conf` |
| RISC-V GCC (xPack `riscv-none-elf-gcc`) | `toolchain/riscv-gcc.conf` |
| opam packages, with all their dependencies | `toolchain/opam-packages.txt` |

`scripts/toolchain.sh install` downloads, verifies and unpacks them under
`~/.takibi-hardware` (`TAKIBI_HARDWARE_HOME`); `eval "$(scripts/toolchain.sh env)"`
puts them on PATH; `scripts/toolchain.sh check` fails on anything else.
The devcontainer bind-mounts `~/.takibi-hardware` from the host, so the
download happens once; CI caches each part under a key derived from its
pin (`.github/workflows/ci.yml`); Claude Code cloud sessions run the same
script (`.claude/hooks/session-start.sh`). apt provides only tools that do
not affect results. Add a tool or opam package in `toolchain/` and the
script, never in one environment only.

Toolchain triage: when a result looks wrong and the cause could be a tool,
rerun with another release before debugging our sources:

    scripts/with-toolchain.sh 2026-09-01 make -C designs/mcu   # older/newer OSS CAD Suite
    scripts/with-toolchain.sh system make -C designs/mcu       # distribution tools (if installed)

Builds go to `build-<toolchain>/`, next to the pinned `build/`, for
comparison. If the behaviour follows the toolchain, it is a tool defect
(record it in BUGS.md as such, with both versions); if it follows our
sources, it is ours. Moving the pin is a deliberate commit: change
`toolchain/oss-cad-suite.conf` (`scripts/toolchain.sh sha256 DATE` prints
the checksum), run `make ci`, record changed numbers in HISTORY.md.

Toolchain notes:
- HardCaml v0.17: `select s hi lo` takes positional arguments; wires are
  assigned with `<==`; Always variables with `<--`.
- HardCaml v0.17: `repeat s n`, `srl s n` are positional; memories have no
  initial contents (the mcu generator inserts `initial` blocks).
- hardcaml_verilator v0.17.0 needs `verilator_version = V5` and
  `verbose = true`; use `Testlib.Verilator_config.config`.
- hardcaml_waveterm draws Unicode boxes; print waveforms with
  `Testlib.Ascii_wave.print` to stay ASCII.
- `Hardcaml_verify.Sec` calls the `z3` binary.
- Firmware: `riscv-none-elf-gcc` with `-march=rv32e -mabi=ilp32e` (iCEstick)
  or `-march=rv32i -mabi=ilp32` (i9), see `sw/build.sh` and `sw/dune`.
- Memory initial contents: emit `$readmemh` (ip/mcu/gen), never one
  assignment per word: Yosys took 5.5 minutes for 64 KiB that way.
