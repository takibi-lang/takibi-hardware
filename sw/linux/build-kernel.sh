#!/usr/bin/env bash
# Build the pinned Linux kernel (toolchain/linux.conf) for the Linux SoC
# (#21) out of tree: unpack under $TAKIBI_HARDWARE_HOME/src, configure
# from tinyconfig + sw/linux/kernel.config, build arch/riscv/boot/Image.
#
#   build-kernel.sh OUT [INITRAMFS_LIST [EXTRA_FRAGMENT]]
#
# INITRAMFS_LIST: a gen_init_cpio file list (CONFIG_INITRAMFS_SOURCE).
# EXTRA_FRAGMENT: options applied after kernel.config (kernel-smp.config, #9).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "$1")
initramfs=${2:+$(realpath "$2")}
extra=${3:+$(realpath "$3")}
home=${TAKIBI_HARDWARE_HOME:-$HOME/.takibi-hardware}
version=$(sed -n 's/^LINUX_VERSION=//p' "$root/toolchain/linux.conf")
sha=$(sed -n 's/^LINUX_SHA256=//p' "$root/toolchain/linux.conf")
major=${version%%.*}
tarball=$home/downloads/linux-$version.tar.xz
src=$home/src/linux-$version
if [ ! -d "$src" ]; then
  mkdir -p "$home/downloads" "$home/src"
  [ -f "$tarball" ] || curl -fL -o "$tarball" "https://cdn.kernel.org/pub/linux/kernel/v$major.x/linux-$version.tar.xz"
  echo "$sha  $tarball" | sha256sum -c --quiet
  tar -xJf "$tarball" -C "$home/src"
fi
mkdir -p "$out"
make_k() { make -C "$src" O="$out" ARCH=riscv CROSS_COMPILE=riscv32-buildroot-linux-musl- "$@"; }
make_k -s tinyconfig
# The extra fragment's options replace kernel.config's.
if [ -n "$extra" ]; then
  keys=$(sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=.*/\1/p' "$extra" | paste -sd'|')
  grep -Ev "^($keys)=" "$root/sw/linux/kernel.config" > "$out/fragment.config"
  cat "$extra" >> "$out/fragment.config"
else
  cp "$root/sw/linux/kernel.config" "$out/fragment.config"
fi
if [ -n "$initramfs" ]; then
  echo "CONFIG_INITRAMFS_SOURCE=\"$initramfs\"" >> "$out/fragment.config"
fi
(cd "$src" && ARCH=riscv scripts/kconfig/merge_config.sh -m -O "$out" "$out/.config" "$out/fragment.config" > "$out/merge.log")
make_k -s olddefconfig
# Every requested option must have survived (dependencies can drop them).
missing=0
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  key=${line%%=*} val=${line#*=}
  if [ "$val" = n ]; then
    grep -q "^$key=" "$out/.config" && { echo "not disabled: $line" >&2; missing=1; }
  else
    grep -qxF "$line" "$out/.config" || { echo "not set: $line ($(grep "^$key=\|^# $key " "$out/.config" || echo absent))" >&2; missing=1; }
  fi
done < "$out/fragment.config"
[ $missing = 0 ] || { echo "kernel config: requested options missing" >&2; exit 1; }
make_k -j"$(nproc)" Image
ls -l "$out/arch/riscv/boot/Image" "$out/vmlinux"
