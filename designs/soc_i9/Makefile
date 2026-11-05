# Colorlight i9 Linux SoC (issue #21, L10).
#
#   make            synthesise, place and route, check resources: build/top.bit
#   make prog       load the bitstream into the FPGA (SRAM) over the DAPLink
#   make flash-images  write the device tree and the kernel (with the REPL as
#                   initramfs) into the SPI flash at Soc_map's offsets
#                   (needs `make linux-model` or `make -C sw/linux images`)
#   make flash      write the bitstream into the SPI flash (boots on power-up)
#
# The top level is rtl/top.v (BB and USRMCLK) around the generated soc_board.
ROOT     := $(abspath ../..)
BUILD    ?= build
EXE      := $(ROOT)/_build/default/designs/soc_i9/bin/main.exe
BOOT     := $(ROOT)/_build/default/sw/linux/boot/boot.bin
LINUX    := $(ROOT)/build/linux
HWSRCS   := $(shell find src bin rtl $(ROOT)/ip $(ROOT)/models -name '*.ml' -o -name dune -o -name '*.v' 2>/dev/null)
LPF      := colorlight_i9.lpf
CLOCK_MHZ = $$($(EXE) clock-mhz)
PNR      = nextpnr-ecp5 -q --45k --package CABGA381 --speed 6 --freq $(CLOCK_MHZ) --lpf $(LPF)
# Raise deliberately and note why in HISTORY.md.
MAX_LC   := 9000
# The boot ROM (Yosys infers a DP16KD for it).
EXPECT_BRAM := 1
FLASH_DTB := 0x200000
FLASH_KERNEL := 0x210000

all: $(BUILD)/top.bit resources

$(EXE) $(BOOT): $(HWSRCS) $(ROOT)/sw/linux/boot/boot.S
	cd $(ROOT) && dune build ./designs/soc_i9/bin/main.exe ./sw/linux/boot/boot.bin

$(BUILD)/soc_board.v: $(EXE) $(BOOT)
	@mkdir -p $(BUILD)
	@$(ROOT)/scripts/versions.sh > $(BUILD)/versions.txt
	$(EXE) verilog $(BOOT) > $@

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

flash: $(BUILD)/top.bit
	openFPGALoader -b colorlight-i9 -f $<

flash-images:
	openFPGALoader -b colorlight-i9 -f --file-type raw -o $(FLASH_DTB) $(LINUX)/boot/soc.dtb
	openFPGALoader -b colorlight-i9 -f --file-type raw -o $(FLASH_KERNEL) $(LINUX)/kernel/arch/riscv/boot/Image

clean:
	rm -rf $(BUILD)

.PHONY: all resources names prog flash flash-images clean
