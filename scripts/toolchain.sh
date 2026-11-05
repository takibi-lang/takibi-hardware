#!/usr/bin/env bash
# Pinned toolchain (issues #11, #12): OSS CAD Suite, xPack RISC-V GCC and
# the opam packages, installed under one directory so that the
# devcontainer (bind mount), cloud sessions and CI (actions/cache) run the
# same tool releases.
#
#   toolchain.sh install [--no-opam|--dev]  download, verify, unpack
#                                     (idempotent); --dev adds editor tools
#                                     (constrained by the pins)
#   toolchain.sh env                  print shell code that puts it on PATH
#   toolchain.sh check                fail unless PATH and opam use the pins
#   toolchain.sh sha256 DATE          print the checksum of an OSS CAD Suite
#                                     release (for toolchain/oss-cad-suite.conf)
#   toolchain.sh opam-freeze          rewrite toolchain/opam-packages.txt
#                                     from the current switch
#   toolchain.sh key                  print the cache keys (used by CI)
#
# Pins: toolchain/oss-cad-suite.conf, toolchain/riscv-gcc.conf,
# toolchain/linux-gcc.conf, toolchain/opam-packages.txt. OSS_CAD_SUITE_DATE in the environment
# selects another OSS CAD Suite release (see scripts/with-toolchain.sh);
# its checksum is then printed, not verified.
#
# Location: $TAKIBI_HARDWARE_HOME, default ~/.takibi-hardware.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOME_DIR=${TAKIBI_HARDWARE_HOME:-$HOME/.takibi-hardware}
DOWNLOADS=$HOME_DIR/downloads
TOOLS=$HOME_DIR/toolchain
OCAML_VERSION=5.3.0
OPAM_ROOTS="dune hardcaml ppx_hardcaml hardcaml_waveterm hardcaml_verilator hardcaml_verify hardcaml_of_verilog ppx_jane ppx_expect"

pinned_date=$(sed -n 's/^OSS_CAD_SUITE_DATE=//p' "$ROOT/toolchain/oss-cad-suite.conf")
pinned_sha=$(sed -n 's/^OSS_CAD_SUITE_SHA256=//p' "$ROOT/toolchain/oss-cad-suite.conf")
CAD_DATE=${OSS_CAD_SUITE_DATE:-$pinned_date}
GCC_VERSION=$(sed -n 's/^RISCV_GCC_VERSION=//p' "$ROOT/toolchain/riscv-gcc.conf")
GCC_SHA=$(sed -n 's/^RISCV_GCC_SHA256=//p' "$ROOT/toolchain/riscv-gcc.conf")

LGCC_RELEASE=$(sed -n 's/^LINUX_GCC_RELEASE=//p' "$ROOT/toolchain/linux-gcc.conf")
LGCC_SHA=$(sed -n 's/^LINUX_GCC_SHA256=//p' "$ROOT/toolchain/linux-gcc.conf")
LGCC_DIR=$TOOLS/$LGCC_RELEASE

CAD_DIR=$TOOLS/oss-cad-suite-$CAD_DATE
GCC_DIR=$TOOLS/riscv-gcc-$GCC_VERSION
opam_hash=$(grep -v '^#' "$ROOT/toolchain/opam-packages.txt" | sha256sum | cut -c1-12)
OPAM_ROOT_DIR=$HOME_DIR/opam
SWITCH=hc-$OCAML_VERSION-$opam_hash

cad_url() {
  local d=$1
  echo "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$d/oss-cad-suite-linux-x64-${d//-/}.tgz"
}
lgcc_url() {
  echo "https://toolchains.bootlin.com/downloads/releases/toolchains/riscv32-ilp32d/tarballs/$LGCC_RELEASE.tar.xz"
}
gcc_url() {
  echo "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$GCC_VERSION/xpack-riscv-none-elf-gcc-$GCC_VERSION-linux-x64.tar.gz"
}

# fetch URL FILE [SHA256]: download once; verify when a checksum is given.
fetch() {
  local url=$1 file=$DOWNLOADS/$(basename "$1") sha=${2:-}
  mkdir -p "$DOWNLOADS"
  if [ ! -f "$file" ]; then
    echo "toolchain: downloading $url" >&2
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got
  got=$(sha256sum "$file" | cut -d' ' -f1)
  if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
    echo "toolchain: checksum mismatch for $file: $got, expected $sha" >&2
    rm -f "$file"
    exit 1
  fi
  [ -n "$sha" ] || echo "toolchain: $file not verified (sha256 $got)" >&2
  echo "$file"
}

# unpack ARCHIVE DIR: the archive's single top-level directory becomes DIR.
unpack() {
  local archive=$1 dir=$2 tmp=$2.tmp
  rm -rf "$tmp"
  mkdir -p "$tmp"
  tar -xf "$archive" -C "$tmp"
  mv "$tmp"/* "$dir"
  rmdir "$tmp"
}

install_cad() {
  [ -x "$CAD_DIR/bin/yosys" ] && return
  local sha=""
  [ "$CAD_DATE" = "$pinned_date" ] && sha=$pinned_sha
  unpack "$(fetch "$(cad_url "$CAD_DATE")" "$sha")" "$CAD_DIR"
}

install_gcc() {
  [ -x "$GCC_DIR/bin/riscv-none-elf-gcc" ] && return
  unpack "$(fetch "$(gcc_url)" "$GCC_SHA")" "$GCC_DIR"
}

install_lgcc() {
  [ -x "$LGCC_DIR/bin/riscv32-buildroot-linux-musl-gcc" ] && return
  unpack "$(fetch "$(lgcc_url)" "$LGCC_SHA")" "$LGCC_DIR"
}

install_opam() {
  export OPAMROOT=$OPAM_ROOT_DIR OPAMYES=1
  [ -f "$OPAMROOT/config" ] || opam init --bare --disable-sandboxing -n
  if ! opam switch list --short | grep -Fxq "$SWITCH"; then
    opam update
    opam switch create "$SWITCH" "ocaml-base-compiler.$OCAML_VERSION"
  fi
  if [ $# = 0 ] && [ -z "$(comm -23 <(grep -v '^#' "$ROOT/toolchain/opam-packages.txt" | sort) \
      <(opam list --switch="$SWITCH" --installed --short --columns=name,version | awk '{print $1"."$2}' | sort))" ]; then
    return
  fi
  # Extra packages are solved together with the exact pins, so they
  # cannot move a pinned package.
  # shellcheck disable=SC2046
  opam install --switch="$SWITCH" $(grep -v '^#' "$ROOT/toolchain/opam-packages.txt") "$@"
}

print_env() {
  cat <<EOF
export TAKIBI_HARDWARE_HOME='$HOME_DIR'
export PATH='$CAD_DIR/bin:$GCC_DIR/bin:$LGCC_DIR/bin':"\$PATH"
export OPAMROOT='$OPAM_ROOT_DIR'
eval "\$(opam env --root='$OPAM_ROOT_DIR' --switch='$SWITCH' --set-root --set-switch 2>/dev/null)"
EOF
}

check() {
  local status=0
  for t in yosys nextpnr-ice40 nextpnr-ecp5 icepack icebram ecppack ecpbram iverilog verilator z3; do
    case $(command -v "$t" || true) in
      "$CAD_DIR"/bin/*) ;;
      *) echo "toolchain: $t is $(command -v "$t" || echo missing), not from $CAD_DIR" >&2; status=1 ;;
    esac
  done
  case $(command -v riscv-none-elf-gcc || true) in
    "$GCC_DIR"/bin/*) ;;
    *) echo "toolchain: riscv-none-elf-gcc not from $GCC_DIR" >&2; status=1 ;;
  esac
  case $(command -v riscv32-buildroot-linux-musl-gcc || true) in
    "$LGCC_DIR"/bin/*) ;;
    *) echo "toolchain: riscv32-buildroot-linux-musl-gcc not from $LGCC_DIR" >&2; status=1 ;;
  esac
  local want have
  want=$(grep -v '^#' "$ROOT/toolchain/opam-packages.txt" | sort)
  have=$(opam list --installed --short --columns=name,version 2>/dev/null | awk '{print $1"."$2}' | sort)
  local missing
  missing=$(comm -23 <(echo "$want") <(echo "$have"))
  if [ -n "$missing" ]; then
    echo "toolchain: opam packages not at the pinned versions:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    status=1
  fi
  [ $status = 0 ] && echo "OK: toolchain matches the pins (OSS CAD Suite $CAD_DATE, GCC $GCC_VERSION, $LGCC_RELEASE, opam $SWITCH)"
  return $status
}

case ${1:-} in
  install)
    install_cad
    install_gcc
    install_lgcc
    case ${2:-} in
      --no-opam) ;;
      --dev) install_opam ocaml-lsp-server merlin ocamlformat utop ppx_deriving ;;
      *) install_opam ;;
    esac
    ;;
  env) print_env ;;
  check) check ;;
  sha256)
    f=$(fetch "$(cad_url "$2")")
    sha256sum "$f" | cut -d' ' -f1
    ;;
  opam-freeze)
    roots=$(echo "$OPAM_ROOTS" | tr ' ' ',')
    {
      sed -n '/^#/p' "$ROOT/toolchain/opam-packages.txt"
      opam list --installed --required-by="$roots" --recursive --short --columns=name,version \
        | awk '{print $1"."$2}'
    } > "$ROOT/toolchain/opam-packages.txt.new"
    mv "$ROOT/toolchain/opam-packages.txt.new" "$ROOT/toolchain/opam-packages.txt"
    ;;
  key)
    if [ "$CAD_DATE" = "$pinned_date" ]; then echo "cad=oss-cad-suite-$CAD_DATE-$pinned_sha"
    else echo "cad=oss-cad-suite-$CAD_DATE-unverified"; fi
    echo "gcc=riscv-gcc-$GCC_VERSION-$GCC_SHA"
    echo "lgcc=$LGCC_RELEASE-$LGCC_SHA"
    echo "opam=opam-$SWITCH"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
