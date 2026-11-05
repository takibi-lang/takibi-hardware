# Linux on the golden SoC model (#21, L0 #25): build the REPL (#24), the
# kernel with it as initramfs, the boot ROM and the device tree, boot the
# model, type a few commands and check the answers.
#
#   make -C sw/linux model     (top level: make linux-model)
ROOT := $(abspath ../..)
OUT := $(ROOT)/build/linux
BOOT := $(ROOT)/_build/default/models/soc_model/bin/boot.exe
INPUT := help\recho hello from U-mode\rbench syscall 1000\rbench sleep 5\r

all: model

images:
	mkdir -p $(OUT)
	$(ROOT)/sw/linux/build-kernel.sh $(OUT)/kernel > $(OUT)/kernel-headers.log 2>&1 || \
	  { tail -20 $(OUT)/kernel-headers.log; exit 1; }
	$(ROOT)/sw/repl/build-linux.sh $(OUT)/repl $(OUT)/kernel
	$(ROOT)/sw/linux/build-kernel.sh $(OUT)/kernel $(OUT)/repl/initramfs.list > $(OUT)/kernel.log 2>&1 || \
	  { tail -20 $(OUT)/kernel.log; exit 1; }
	$(ROOT)/sw/linux/build-boot.sh $(OUT)/boot $(OUT)/kernel
	@ls -l $(OUT)/kernel/arch/riscv/boot/Image

model: images
	cd $(ROOT) && dune build ./models/soc_model/bin/boot.exe
	$(BOOT) $(OUT)/boot/boot.bin $(OUT)/boot/soc.dtb $(OUT)/kernel/arch/riscv/boot/Image \
	  --input '$(INPUT)' --until 'us per sleep' --max 150000000 | tee $(OUT)/model.log
	@for l in 'Linux version 6' 'SBI specification v1.0 detected' 'is a 16550A' \
	          'takibi-hardware REPL on Linux' 'commands: help' 'hello from U-mode' \
	          'syscall: 1000 calls in' 'cycles, ' 'us per sleep'; do \
	  grep -qF "$$l" $(OUT)/model.log || { echo "FAIL: missing '$$l'" >&2; exit 1; }; done
	@echo "OK: Linux boots on the SoC model and the REPL answers"

.PHONY: all images model
