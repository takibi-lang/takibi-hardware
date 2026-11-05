# riscv-tests (self-checking) on the golden model (#25): the independent
# check for its I, M, A, privilege (rv32mi, rv32si) and Sv32 behaviour.
# `p` tests run bare; `v` tests run the user-level groups in U-mode under
# riscv-tests' small S-mode kernel with Sv32 demand paging (Svade: it sets
# A/D itself). Needs network access the first time.
ROOT := $(abspath ../..)
RUN := $(ROOT)/_build/default/bench/riscv_tests/run.exe
GROUPS := rv32ui rv32um rv32ua rv32mi rv32si
V_GROUPS := rv32ui rv32um rv32ua
# On the core (M, A, S/U and Sv32) in lockstep with the model, p and v.
CORE_GROUPS := rv32ui rv32um rv32ua rv32mi rv32si
MARCH := rv32ima_zicsr_zifencei

all: run

fetch:
	./fetch.sh

build: fetch
	@for g in $(GROUPS) selftest; do ./build.sh $$g $(MARCH) build/$$g || exit 1; done
	@for g in $(V_GROUPS); do ./build.sh $$g $(MARCH) build/$${g}_v v || exit 1; done

run: build
	cd $(ROOT) && dune build ./bench/riscv_tests/run.exe
	@if $(RUN) build/selftest > /dev/null; \
	  then echo "FAIL: riscv-tests runner accepted a failing test" >&2; exit 1; \
	  else echo "OK: riscv-tests runner rejects a failing test"; fi
	$(RUN) $(addprefix build/,$(GROUPS)) $(addsuffix _v,$(addprefix build/,$(V_GROUPS)))
	$(RUN) --pipeline $(addprefix build/,rv32ui rv32um rv32ua rv32mi)
	$(RUN) --core $(addprefix build/,$(CORE_GROUPS)) $(addsuffix _v,$(addprefix build/,$(V_GROUPS)))

clean:
	rm -rf build

.PHONY: all fetch build run clean
