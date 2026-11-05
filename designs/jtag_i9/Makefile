# Issue #10: JTAG from the fabric (JTAGG, ER1) on the Colorlight i9.
#
#   make            build build/top.bit
#   make prog       load it into SRAM
#   make jtag-test  write and read the ER1 register with OpenOCD
ROOT  := $(abspath ../..)
BUILD := build
EXE   := $(ROOT)/_build/default/designs/jtag_i9/bin/main.exe
HIDAPI_LIBUSB := $(firstword $(wildcard $(dir $(shell which openocd))../lib/libhidapi-libusb.so.0*))

all: $(BUILD)/top.bit

$(EXE): $(shell find src bin $(ROOT)/ip/ecp5 -name '*.ml' -o -name dune)
	cd $(ROOT) && dune build ./designs/jtag_i9/bin/main.exe

$(BUILD)/top.v: $(EXE)
	@mkdir -p $(BUILD)
	$(EXE) > $@

$(BUILD)/top.bit: $(BUILD)/top.v colorlight_i9.lpf
	yosys -q -p 'synth_ecp5 -top top -json $(BUILD)/top.json' $<
	nextpnr-ecp5 -q --45k --package CABGA381 --speed 6 --lpf colorlight_i9.lpf \
	  --json $(BUILD)/top.json --textcfg $(BUILD)/top.config
	ecppack --compress $(BUILD)/top.config $@

names: $(BUILD)/top.v
	$(ROOT)/scripts/check_names.sh $<

prog: $(BUILD)/top.bit
	openFPGALoader -b colorlight-i9 $<

# Writes 0x12345679 (LED on), reads back 0xcafe5679; then 0x0 (LED off).
jtag-test:
	LD_PRELOAD=$(HIDAPI_LIBUSB) openocd -f openocd.cfg \
	  -c 'irscan ecp5.tap 0x32; drscan ecp5.tap 32 0x12345679; irscan ecp5.tap 0x32' \
	  -c 'set r [drscan ecp5.tap 32 0x0]; echo "ER1 read: $$r"' \
	  -c 'irscan ecp5.tap 0x32; set r [drscan ecp5.tap 32 0x0]; echo "ER1 read: $$r"' \
	  -c shutdown 2>&1 | grep -E 'ER1|Error|tap/device'

clean:
	rm -rf $(BUILD)

.PHONY: all names prog jtag-test clean
