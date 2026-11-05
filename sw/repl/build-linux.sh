#!/usr/bin/env bash
# Build the REPL for Linux (#24) with the kernel's nolibc and the pinned
# bare-metal GCC (soft-float ilp32 libgcc; nolibc makes the system calls
# itself), static, plus the initramfs list for the kernel build.
#
#   build-linux.sh OUT KERNEL_OUT
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "$1")
kout=$(realpath "$2")
home=${TAKIBI_HARDWARE_HOME:-$HOME/.takibi-hardware}
version=$(sed -n 's/^LINUX_VERSION=//p' "$root/toolchain/linux.conf")
src=$home/src/linux-$version
mkdir -p "$out"
# The UAPI headers nolibc includes.
make -s -C "$src" O="$kout" ARCH=riscv CROSS_COMPILE=riscv32-buildroot-linux-musl- headers_install
riscv-none-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -static -nostdlib -fno-stack-protector \
  -ffreestanding -fno-builtin -Wall -Werror \
  -include "$src/tools/include/nolibc/nolibc.h" -I "$src/tools/include/nolibc" -I "$kout/usr/include" \
  -Wl,--no-warn-rwx-segments -o "$out/repl" \
  "$root/sw/repl/repl.c" "$root/sw/repl/os_linux.c" -lgcc
sed "s|@REPL@|$out/repl|" "$root/sw/repl/initramfs.list" > "$out/initramfs.list"
ls -l "$out/repl"
