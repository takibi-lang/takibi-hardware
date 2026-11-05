# Colorlight i9 Linux SoC (issue #21, L10).
#
#   make            synthesise, place and route, check resources: build/top.bit
#   make prog       load the bitstream into the FPGA (SRAM) over the DAPLink
#   make flash      write build/flash.bin into the SPI flash: the bitstream at 0,
#                   the device tree and the kernel (with the REPL as initramfs)
#                   at Soc_map's offsets; the board then boots Linux on
#                   power-up (needs the images: make -C sw/linux images)
#
# The top level is rtl/top.v (BB and USRMCLK) around the generated soc_board.
ROOT     := $(abspath ../..)
BUILD    ?= build
EXE      := $(ROOT)/_build/default/designs/soc_i9/bin/main.exe
# The boot ROM image (a dune target): the Linux boot stub, or a bring-up
# test, e.g. make BOOT=sw/soc_test/memtest.bin BUILD=build-memtest prog
BOOT     ?= sw/linux/boot/boot.bin
BOOT_BIN := $(ROOT)/_build/default/$(BOOT)
LINUX    := $(ROOT)/build/linux
HWSRCS   := $(shell find src bin rtl $(ROOT)/ip $(ROOT)/models -name '*.ml' -o -name dune -o -name '*.v' 2>/dev/null)
LPF      := colorlight_i9.lpf
CLOCK_MHZ = $$($(EXE) clock-mhz)
PNR      = nextpnr-ecp5 -q --45k --package CABGA381 --speed 6 --freq $(CLOCK_MHZ) --lpf $(LPF)
# Raise deliberately and note why in HISTORY.md.
MAX_LC   := 9000
# The boot ROM (Yosys infers a DP16KD for it), the cache: 16 for data and
# 1 for the tags.
EXPECT_BRAM := 18
FLASH_DTB := 0x200000
FLASH_KERNEL := 0x210000

all: $(BUILD)/top.bit resources

$(EXE) $(BOOT_BIN): $(HWSRCS) $(shell find $(ROOT)/sw/linux/boot $(ROOT)/sw/soc_test -type f)
	cd $(ROOT) && dune build ./designs/soc_i9/bin/main.exe ./$(BOOT)

$(BUILD)/soc_board.v: $(EXE) $(BOOT_BIN)
	@mkdir -p $(BUILD)
	@$(ROOT)/scripts/versions.sh > $(BUILD)/versions.txt
	$(EXE) verilog $(BOOT_BIN) > $@

$(BUILD)/top.json: $(BUILD)/soc_board.v rtl/top.v
	yosys -q -l $(BUILD)/yosys.log -p 'read_verilog rtl/top.v $(BUILD)/soc_board.v; synth_ecp5 -top top -json $@'

$(BUILD)/top.config: $(BUILD)/top.json $(LPF)
	$(PNR) -l $(BUILD)/nextpnr.log --json $< --textcfg $@
	@grep -m1 'TRELLIS_COMB:' $(BUILD)/nextpnr.log
	@grep -m1 'DP16KD:' $(BUILD)/nextpnr.log
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1

$(BUILD)/top.bit: $(BUILD)/top.config
	ecppack --compress $< $@

resources: $(BUILD)/top.config
	@$(ROOT)/scripts/check_resources.sh $(BUILD)/nextpnr.log $(EXPECT_BRAM) $(MAX_LC)

names: $(BUILD)/soc_board.v
	$(ROOT)/scripts/check_names.sh $<

prog: $(BUILD)/top.bit
	openFPGALoader -b colorlight-i9 $<

$(BUILD)/flash.bin: $(BUILD)/top.bit $(LINUX)/boot/soc.dtb $(LINUX)/kernel/arch/riscv/boot/Image
	python3 -c 'import sys; \
	  img = bytearray(b"\xff" * $(FLASH_KERNEL)); \
	  bit = open(sys.argv[1], "rb").read(); dtb = open(sys.argv[2], "rb").read(); \
	  assert len(bit) <= $(FLASH_DTB) and len(dtb) <= $(FLASH_KERNEL) - $(FLASH_DTB); \
	  img[0:len(bit)] = bit; img[$(FLASH_DTB):$(FLASH_DTB) + len(dtb)] = dtb; \
	  open(sys.argv[4], "wb").write(img + open(sys.argv[3], "rb").read())' \
	  $(BUILD)/top.bit $(LINUX)/boot/soc.dtb $(LINUX)/kernel/arch/riscv/boot/Image $@
	@ls -l $@

flash: $(BUILD)/flash.bin
	openFPGALoader -b colorlight-i9 --unprotect-flash -f $<

clean:
	rm -rf $(BUILD)

.PHONY: all resources names prog flash clean
