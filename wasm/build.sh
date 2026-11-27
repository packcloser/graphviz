#!/usr/bin/env bash
# Build Graphviz and expat for wasm32-wasip1 as one static library, with the
# headers a program compiled against it reads.
#   build.sh <graphviz tree> <expat tree> <graphviz version> <expat version> <wasi-sdk directory> <output directory>
# The trees are the release tarballs pins.yaml pins, fetched, verified and
# unpacked anew by the recipe that calls this: this script edits them, and a
# tree kept from an earlier build would carry that build's edits. The wasi-sdk
# is the pinned one, unpacked.
#
# The output directory gets:
#   lib/libgraphviz.a   every object of Graphviz's libraries, its three
#                       built-in plugins and expat
#   include/graphviz/   config.h and every header under lib/ and plugin/, at
#                       the paths of Graphviz's tree, as these fixes left them
#   include/expat/      expat_config.h and expat's lib/ headers
#   BUILD               what the library was compiled from and with, and the
#                       flags a program linked against it has to share
#
# No configure run: the two configuration headers beside this script stand in
# for its output, so the result does not depend on the host that built it.
# Graphviz's asserts embed __FILE__, so the trees are mapped to fixed names,
# and the sources are ordered under the C locale.
set -euo pipefail
export LC_ALL=C

gv=${1:?graphviz tree}
expat=${2:?expat tree}
graphviz_version=${3:?graphviz version}
expat_version=${4:?expat version}
sdk=${5:?wasi-sdk directory}
out=${6:?output directory}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/jobs.sh
. "${here}/../scripts/jobs.sh"
gv=$(cd "${gv}" && pwd)
expat=$(cd "${expat}" && pwd)
sdk=$(cd "${sdk}" && pwd)
[ -x "${sdk}/bin/clang" ] || { echo "wasm: no clang in ${sdk}/bin" >&2; exit 1; }
[ ! -e "${gv}/.packcloser-edited" ] || { echo "wasm: ${gv} was already edited by a build: unpack it anew" >&2; exit 1; }
: > "${gv}/.packcloser-edited"

# Configure's two outputs are replaced by the headers beside this script, with
# the versions where configure would have put them.
sed "s/@GRAPHVIZ_VERSION@/${graphviz_version}/g" "${here}/config.h" > "${gv}/config.h"
sed "s/@EXPAT_VERSION@/${expat_version}/g" "${here}/expat_config.h" > "${expat}/expat_config.h"

# edit <file> <sed expression> <what the file holds afterwards> <what it is>:
# one line of a source changed in place, and the build stopped when the line
# is not there to change: a Graphviz that moved it needs the fix read again.
edit() {
  local file=$1 expression=$2 after=$3 what=$4
  sed -i.orig "${expression}" "${file}"
  rm -f "${file}.orig"
  [ "$(grep -c -e "${after}" "${file}")" = 1 ] || {
    echo "${file#"${gv}/"}: ${what} does not look like the one this fix is for" >&2
    exit 1
  }
}

# apply <patch> <file> <sha256 of the file it was written against> <its marker>:
# a patch applied only to the file it was written against, by digest. patch
# applies a hunk with fuzz without failing, and macOS's says nothing when it
# does, so after a Graphviz bump a fuzzed hunk could land on changed code. A
# new Graphviz means reading the patch and its digest again.
apply() {
  local patch=$1 file=$2 base=$3 marker=$4
  echo "${base}  ${file}" | sha256sum -c - > /dev/null || {
    echo "${file#"${gv}/"}: not the file ${patch} was written against; read the patch again for this Graphviz" >&2
    exit 1
  }
  # POSIX options only: -p0 for the paths the patch names, -N to refuse a
  # patch already applied.
  (cd "${gv}" && patch -p0 -N) < "${here}/patches/${patch}"
  grep -q "${marker}" "${file}" || { echo "${file#"${gv}/"}: ${patch} did not apply" >&2; exit 1; }
}

# The sources are Graphviz's release with the fixes below, each for a fault
# that a program holding the library in one long-lived process meets and
# upstream's dot, which lays out and exits, does not, or that corrupts memory
# where a native process would go on. UPSTREAM.md says what each is for.

# storeline (lib/common/labels.c) tells gv_recalloc that one more span existed
# than did, so the span it is about to fill is never zeroed, and a label whose
# first line is empty frees a garbage layout pointer.
edit "${gv}/lib/common/labels.c" \
  's/size_t oldsz = lp->u.txt.nspans + 1;/size_t oldsz = lp->u.txt.nspans;/' \
  'size_t oldsz = lp->u.txt.nspans;' storeline

# Graphviz keeps every image file it sizes open for the life of the process;
# gvusershape_file_release always closes it, and gvusershape_file_access
# opens it again when anything reads it.
usershape="${gv}/lib/gvc/gvusershape.c"
edit "${usershape}" 's/^  if (us->nocache) {$/  if (us->f) {/' '^  if (us->f) {$' gvusershape_file_release

# webp_size reads a WebP's size from where only a plain lossy one keeps it.
apply webp-size.patch "${usershape}" 1af7a25ce49beda3222bd12dac1adbf67ffa11301a6112588a755138b5400e67 \
  'go-graphviz: the canvas size of each of the three WebP layouts'

# Graphviz sizes an image once, by name, for as long as the process lives: a
# file that changed between two layouts kept the size it had at the first.
# The patch counts layouts and sizes an image again when its size is of
# another layout; gvLayoutJobs, which every layout goes through, counts.
apply image-size.patch "${usershape}" 046997239f311a80c3c8e49e1d5f149d7536ca87c241b431f15165e00bc33a9e \
  'go-graphviz: an image is sized once a layout'
edit "${gv}/lib/gvc/gvcproc.h" \
  's/^    usershape_t \*gvusershape_find(const char \*name);$/& void gvusershape_layout_begins(void);/' \
  'void gvusershape_layout_begins(void);$' "gvusershape_find's declaration"
edit "${gv}/lib/gvc/gvlayout.c" 's/^    int rc;$/& gvusershape_layout_begins();/' \
  '^    int rc; gvusershape_layout_begins();$' gvLayoutJobs

# When bison runs out of its own stack it returns without the grammar's error
# rule, which is where the parser frees what it holds: agconcat runs that
# rule's clean-up for any parse bison reports failed.
edit "${gv}/lib/cgraph/grammar.c" \
  's/^	aagparse(scanner);$/	if (aagparse(scanner) != 0) graph_error(scanner);/' \
  '^	if (aagparse(scanner) != 0) graph_error(scanner);$' agconcat

# parse_reclbl (lib/common/shapes.c) frees what it built, when a record label
# cannot be read, by a count of fields it sets only once it is done.
apply reclbl-free.patch "${gv}/lib/common/shapes.c" 78370a37daef0003c4a00bd303b744f811dd240668fee57e3e7d6b06321aa82c \
  'go-graphviz: the fields built so far are counted'

# Built without a triangulation library, remove_overlap is a stand-in that
# reports an error whatever it is given, and sfdp calls it at the end of
# every layout: it reports when it is given sizes, which is when it was asked
# for something.
edit "${gv}/lib/neatogen/overlap.c" \
  's/^    if (!atomic_flag_test_and_set(&once)) {$/    if (label_sizes \&\& !atomic_flag_test_and_set(\&once)) {/' \
  '^    if (label_sizes && !atomic_flag_test_and_set(&once)) {$' "the stand-in remove_overlap"

# The DOT writer puts a string in its canonical form into a buffer of 2n+3
# bytes, and the form can be longer: a quote is two bytes, and a line break,
# two more, goes in after every linelength characters. 4n+3 holds any string.
edit "${gv}/lib/cgraph/agstrcanon.h" \
  's/^  return 2 \* strlen(str) + 3;$/  return 4 * strlen(str) + 3;/' \
  '^  return 4 \* strlen(str) + 3;$' agstrcanon_bytes

# Graphviz's libraries, each compiled whole, and its three built-in plugins.
libs=(
  lib/ast lib/cdt lib/cgraph lib/circogen lib/common lib/dotgen lib/edgepaint
  lib/expr lib/fdpgen lib/gvc lib/label lib/ortho lib/osage lib/pack
  lib/patchwork lib/pathplan lib/rbtree lib/sfdpgen lib/sfio lib/sparse
  lib/twopigen lib/util lib/xdot
  plugin/core plugin/dot_layout plugin/neato_layout
)
# lib/neatogen by name: it also holds the sources of engines this
# configuration leaves out (ipsep and its constraint solver, which are C++).
neatogen=(
  adjust bfs call_tri circuit closest compute_hierarchy conjgrad
  constrained_majorization constraint delaunay dijkstra edges embed_graph
  geometry heap hedges info kkutils legal lu matinv matrix_ops multispline
  neatoinit neatosplines opt_arrangement overlap pca poly quad_prog_solve
  randomkit sgd site smart_ini_x solve stress stuff voronoi
)

# What a program linked against the library has to compile with too: the
# target, char's signedness, and the three WASI emulations Graphviz's sources
# are compiled to use. BUILD names them.
shared=(
  --target=wasm32-wasip1 -funsigned-char -fno-strict-aliasing
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS
)
cflags=(
  -g0 -Os "${shared[@]}" "--sysroot=${sdk}/share/wasi-sysroot"
  "-ffile-prefix-map=${gv}=graphviz" "-ffile-prefix-map=${expat}=expat"
  -Wextra -Wno-format-security -Wno-bitwise-instead-of-logical
  -Wno-implicit-function-declaration
  -Wno-incompatible-pointer-types-discards-qualifiers
  -Wno-incompatible-pointer-types -Wno-sign-compare
  -Wno-missing-field-initializers -Wno-undef -Wno-uninitialized -Wno-unused
  -Wno-unused-parameter -Wno-write-strings -Wno-char-subscripts
  -Wno-writable-strings
  -I "${gv}" -I "${gv}/lib" -I "${expat}" -I "${expat}/lib"
)
for dir in "${libs[@]}" lib/neatogen lib/mingle lib/vpsc lib/topfish; do
  cflags+=(-I "${gv}/${dir}")
done

work="${out}/obj"
rm -rf "${out}"
mkdir -p "${work}" "${out}/lib" "${out}/include/graphviz" "${out}/include/expat/lib"

echo "compiling graphviz ${graphviz_version} and expat ${expat_version} for wasm32-wasip1 with $("${sdk}/bin/clang" --version | head -n 1)"
# One object per source, named with its directory: basenames repeat across
# the libraries. The compilers run side by side; join before archiving.
for dir in "${libs[@]}"; do
  for source in "${gv}/${dir}"/*.c; do
    # A test program of its own, with a main.
    [ "${source##*/}" != test_red_black_tree.c ] || continue
    name=${source##*/}
    spawn "${sdk}/bin/clang" "${cflags[@]}" -c "${source}" -o "${work}/${dir//\//-}-${name%.c}.o"
  done
done
spawn "${sdk}/bin/clang" "${cflags[@]}" -c "${gv}/lib/sfio/Sfio_f/_sfslen.c" -o "${work}/lib-sfio-f-_sfslen.o"
for name in "${neatogen[@]}"; do
  spawn "${sdk}/bin/clang" "${cflags[@]}" -c "${gv}/lib/neatogen/${name}.c" -o "${work}/lib-neatogen-${name}.o"
done
for name in xmlparse xmltok xmlrole xcs random_getentropy; do
  spawn "${sdk}/bin/clang" "${cflags[@]}" -c "${expat}/lib/${name}.c" -o "${work}/expat-${name}.o"
done
join

# D: no time, owner or mode of the build in the archive; the glob is in the C
# locale's order.
(cd "${work}" && "${sdk}/bin/llvm-ar" rcsD "${out}/lib/libgraphviz.a" ./*.o)
rm -rf "${work}"

# The headers, as the sources above were compiled against them.
cp "${gv}/config.h" "${out}/include/graphviz/"
(cd "${gv}" && find lib plugin -name '*.h' | sort) | while read -r header; do
  mkdir -p "${out}/include/graphviz/$(dirname "${header}")"
  cp "${gv}/${header}" "${out}/include/graphviz/${header}"
done
cp "${expat}/expat_config.h" "${out}/include/expat/"
cp "${expat}"/lib/*.h "${out}/include/expat/lib/"

{
  echo "libgraphviz.a: Graphviz ${graphviz_version} and expat ${expat_version} for wasm32-wasip1,"
  echo "built by packcloser/graphviz from the two release tarballs its pins.yaml"
  echo "names, with the fixes its wasm/build.sh applies (UPSTREAM.md)."
  echo
  echo "compiler: $("${sdk}/bin/clang" --version | head -n 1)"
  echo "sysroot: wasi-sdk's share/wasi-sysroot"
  echo "optimization: -Os -g0"
  echo
  echo "A program linked against the library is compiled with the same wasi-sdk"
  echo "and with these flags, which change what the library's types and calls"
  echo "mean:"
  echo "  ${shared[*]}"
  echo "and is linked with the emulations they name:"
  echo "  -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-signal -lwasi-emulated-process-clocks"
  echo
  echo "Graphviz recurses with the graph: wasm-ld's default stack of 64 KiB"
  echo "overflows on clusters nested a thousand deep, which native dot draws"
  echo "on its 8 MiB (-Wl,-z,stack-size=8388608)."
  echo
  echo "The built-in plugins are in the library and registered by nothing: the"
  echo "program declares gvplugin_dot_layout_LTX_library,"
  echo "gvplugin_neato_layout_LTX_library and gvplugin_core_LTX_library and"
  echo "gives them to gvContextPlugins."
} > "${out}/BUILD"
sha256sum "${out}/lib/libgraphviz.a"
