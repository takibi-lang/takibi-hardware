# Formal proofs with SymbiYosys (sby) on the Verilog that HardCaml
# generates. Properties live in hand-written SystemVerilog next to the
# .sby files; the generated Verilog is never edited.
#
#   make -C formal        (top level: make formal)
ROOT := $(abspath ..)

all: arbiter negative

build/arbiter.v: $(shell find $(ROOT)/ip/soc/src -name '*.ml')
	@mkdir -p build
	cd $(ROOT) && dune build ./ip/soc/bin/arbiter_verilog.exe
	$(ROOT)/_build/default/ip/soc/bin/arbiter_verilog.exe > $@

arbiter: build/arbiter.v
	sby -f arbiter.sby

# Negative test: the arbiter's rule before B-0048 must fail the proof.
build/arbiter_b0048.v: $(shell find $(ROOT)/ip/soc/src -name '*.ml')
	@mkdir -p build
	cd $(ROOT) && dune build ./ip/soc/bin/arbiter_verilog.exe
	EXPERIMENT=arbiter-b0048 $(ROOT)/_build/default/ip/soc/bin/arbiter_verilog.exe > $@

negative: build/arbiter_b0048.v
	sed 's|build/arbiter.v|build/arbiter_b0048.v|; s|^read_verilog arbiter.v|read_verilog arbiter_b0048.v|' arbiter.sby > build/arbiter_b0048.sby
	@if sby -f build/arbiter_b0048.sby prove > build/negative.log 2>&1; \
	  then echo "FAIL: the B-0048 arbiter passed the proof" >&2; exit 1; \
	  else grep -q 'failed assertion' build/negative.log && echo "OK: the B-0048 arbiter fails the proof"; fi

clean:
	rm -rf build arbiter_*/

.PHONY: all arbiter negative clean
