#!/usr/bin/env bash
# Require the wasm library to link into a program, as its BUILD record says
# a program is linked against it, and that program to read a graph, lay it
# out and write it, under wasmtime.
#   smoke.sh <directory holding lib/ and include/> <wasi-sdk directory> [<graphviz version>]
# The link is half the check: it takes no --import-undefined, so a source
# missing from the library stops it with the symbol's name. With a version,
# the program must name it.
set -euo pipefail
export LC_ALL=C

library=${1:?directory holding lib/ and include/}
sdk=${2:?wasi-sdk directory}
version=${3:-}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
library=$(cd "${library}" && pwd)
sdk=$(cd "${sdk}" && pwd)
include="${library}/include/graphviz"

work=$(mktemp -d "${TMPDIR:-/tmp}/graphviz-wasm-smoke.XXXXXX")
trap 'rm -rf "${work}"' EXIT

"${sdk}/bin/clang" \
  --target=wasm32-wasip1 "--sysroot=${sdk}/share/wasi-sysroot" -Os -g0 \
  -funsigned-char -fno-strict-aliasing \
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS \
  -I "${include}" -I "${include}/lib" -I "${include}/lib/gvc" -I "${include}/lib/cgraph" \
  -I "${include}/lib/cdt" -I "${include}/lib/common" -I "${include}/lib/pathplan" \
  "${here}/smoke.c" "${library}/lib/libgraphviz.a" \
  -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-signal -lwasi-emulated-process-clocks \
  -Wl,-z,stack-size=8388608 \
  -o "${work}/smoke.wasm"
echo "linked: $(wc -c < "${work}/smoke.wasm" | tr -d ' ') bytes"

# An HTML-like label, so that expat is in the path; a cluster and an edge
# label, as dot's own smoke test has.
cat > "${work}/fixture.dot" <<'GRAPH'
digraph G { a -> b; b -> c [label="x"]; subgraph cluster_0 { c; d } n [label=<<b>h</b>>] }
GRAPH
wasmtime run "${work}/smoke.wasm" < "${work}/fixture.dot" > "${work}/got.plain"

said=$(head -n 1 "${work}/got.plain")
echo "${said}"
case "${said}" in
"graphviz ${version} ("*) ;;
"graphviz "[0-9]*) [ -z "${version}" ] ;;
*) false ;;
esac || {
  echo "the program: expected graphviz version ${version:-<a number>}" >&2
  exit 1
}
nodes=$(grep -c '^node ' "${work}/got.plain")
if [ "${nodes}" != 5 ] || ! tail -n 1 "${work}/got.plain" | grep -qx stop; then
  echo "the program: expected 5 nodes and a closing stop:" >&2
  cat "${work}/got.plain" >&2
  exit 1
fi
echo "the dot engine: 5 nodes laid out"
