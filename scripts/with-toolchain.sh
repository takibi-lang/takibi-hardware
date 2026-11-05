#!/usr/bin/env bash
# Run a command with another EDA toolchain, to tell tool defects from our
# own (AGENTS.md, "Toolchain triage").
#
#   with-toolchain.sh DATE CMD...    OSS CAD Suite release DATE (YYYY-MM-DD),
#                                    downloaded on first use
#   with-toolchain.sh pinned CMD...  the release in toolchain/oss-cad-suite.conf
#   with-toolchain.sh system CMD...  whatever the distribution installed
#                                    (apt), no OSS CAD Suite on PATH
#
# Board builds go to build-<toolchain>/ instead of build/ (BUILD), so
# results of two toolchains can be compared side by side, e.g.
#   scripts/with-toolchain.sh 2026-09-01 make -C designs/mcu
#   diff designs/mcu/build/nextpnr.log designs/mcu/build-oss-2026-09-01/nextpnr.log
# Only the EDA tools change; GCC and the opam switch stay pinned.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
which=${1:?usage: with-toolchain.sh DATE|pinned|system CMD...}
shift
[ $# -gt 0 ] || { echo "usage: with-toolchain.sh DATE|pinned|system CMD..." >&2; exit 2; }
# Drop every OSS CAD Suite from PATH.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/oss-cad-suite-[^/]*/bin$' | paste -sd: -)
case $which in
  system)
    export BUILD=build-system
    ;;
  *)
    [ "$which" = pinned ] || export OSS_CAD_SUITE_DATE=$which
    "$here/toolchain.sh" install --no-opam
    date=${OSS_CAD_SUITE_DATE:-$(sed -n 's/^OSS_CAD_SUITE_DATE=//p' "$here/../toolchain/oss-cad-suite.conf")}
    PATH=${TAKIBI_HARDWARE_HOME:-$HOME/.takibi-hardware}/toolchain/oss-cad-suite-$date/bin:$PATH
    if [ "$which" = pinned ]; then export BUILD=build; else export BUILD=build-oss-$date; fi
    ;;
esac
export PATH
echo "with-toolchain: $(yosys -V 2>/dev/null || echo 'no yosys'), BUILD=$BUILD" >&2
exec "$@"
