#!/usr/bin/env bash
# Build the Linux SoC's boot ROM and device tree (#25) into OUT:
# boot.bin (M-mode boot stub), soc.dts and soc.dtb (with the kernel's dtc,
# from the pinned kernel build in KERNEL_OUT).
#
#   build-boot.sh OUT KERNEL_OUT [HARTS]
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "$1")
kout=$(realpath "$2")
harts=${3:-1}
mkdir -p "$out"
gen=$root/_build/default/models/soc_model/bin/gen.exe
(cd "$root" && dune build ./models/soc_model/bin/gen.exe)
"$gen" header "$harts" > "$out/soc_map.h"
"$gen" dts "$harts" > "$out/soc.dts"
"$kout/scripts/dtc/dtc" -I dts -O dtb -o "$out/soc.dtb" "$out/soc.dts"
riscv-none-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
  -mno-relax -Wl,--no-warn-rwx-segments -I"$out" -T "$root/sw/linux/boot/link.ld" \
  -o "$out/boot.elf" "$root/sw/linux/boot/boot.S"
riscv-none-elf-objcopy -O binary "$out/boot.elf" "$out/boot.bin"
ls -l "$out/boot.bin" "$out/soc.dtb"
