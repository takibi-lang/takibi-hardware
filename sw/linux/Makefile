# Linux on the golden SoC model (#21, L0 #25): build the REPL (#24), the
# kernel with it as initramfs, the boot ROM and the device tree, boot the
# model, type a few commands and check the answers.
#
#   make -C sw/linux model     (top level: make linux-model)
ROOT := $(abspath ../..)
OUT := $(ROOT)/build/linux
BOOT := $(ROOT)/_build/default/models/soc_model/bin/boot.exe
INPUT := help\recho hello from U-mode\rbench syscall 1000\rbench sleep 5\rbench dhrystone\r

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
	  --input '$(INPUT)' --until 'DMIPS/MHz' --max 200000000 | tee $(OUT)/model.log
	@for l in 'Linux version 6' 'SBI specification v1.0 detected' 'is a 16550A' \
	          'takibi-hardware REPL on Linux' 'commands: help' 'hello from U-mode' \
	          'syscall: 1000 calls in' 'cycles, ' 'us per sleep' 'dhrystone: DMIPS/MHz'; do \
	  grep -qF "$$l" $(OUT)/model.log || { echo "FAIL: missing '$$l'" >&2; exit 1; }; done
	@echo "OK: Linux boots on the SoC model and the REPL answers"

.PHONY: all images model images-smp model-smp

# Two harts (#9): SMP kernel, boot ROM and device tree for two harts, booted
# on the model with two harts.
OUT_SMP := $(ROOT)/build/linux-smp
images-smp:
	mkdir -p $(OUT_SMP)
	$(ROOT)/sw/linux/build-kernel.sh $(OUT_SMP)/kernel "" $(ROOT)/sw/linux/kernel-smp.config > $(OUT_SMP)/kernel-headers.log 2>&1 || \
	  { tail -20 $(OUT_SMP)/kernel-headers.log; exit 1; }
	$(ROOT)/sw/repl/build-linux.sh $(OUT_SMP)/repl $(OUT_SMP)/kernel
	$(ROOT)/sw/linux/build-kernel.sh $(OUT_SMP)/kernel $(OUT_SMP)/repl/initramfs.list $(ROOT)/sw/linux/kernel-smp.config > $(OUT_SMP)/kernel.log 2>&1 || \
	  { tail -20 $(OUT_SMP)/kernel.log; exit 1; }
	$(ROOT)/sw/linux/build-boot.sh $(OUT_SMP)/boot $(OUT_SMP)/kernel 2
	@ls -l $(OUT_SMP)/kernel/arch/riscv/boot/Image

model-smp: images-smp
	cd $(ROOT) && dune build ./models/soc_model/bin/boot.exe
	$(BOOT) $(OUT_SMP)/boot/boot.bin $(OUT_SMP)/boot/soc.dtb $(OUT_SMP)/kernel/arch/riscv/boot/Image \
	  --harts 2 --input '$(INPUT)' --until 'DMIPS/MHz' --max 300000000 | tee $(OUT_SMP)/model.log
	@for l in 'Linux version 6' 'smp: Brought up 1 node, 2 CPUs' 'takibi-hardware REPL on Linux' \
	          'hello from U-mode' 'dhrystone: DMIPS/MHz'; do \
	  grep -qF "$$l" $(OUT_SMP)/model.log || { echo "FAIL: missing '$$l'" >&2; exit 1; }; done
	@echo "OK: Linux boots with two harts on the SoC model and the REPL answers"
