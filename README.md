# graphviz

[Graphviz](https://gitlab.com/graphviz/graphviz) built two ways, from the release `pins.yaml`
pins, with [expat](https://github.com/libexpat/libexpat) for HTML-like labels:

- **`dot`**, the native program, for linux and windows on amd64 and arm64 and for darwin on
  arm64. The sources are compiled as they ship, unpatched: this dot is the reference other
  repositories hold their own output to.
- **`libgraphviz.a`**, Graphviz and expat as one static library for `wasm32-wasip1`, with its
  headers, for a program that links its own code against Graphviz and runs it as a WebAssembly
  module. It carries the fixes [UPSTREAM.md](./UPSTREAM.md) lists.

Both are built without running configure: the configuration headers in `native/` and `wasm/`
stand in for its output, the same on every host.

## Using a release

A release is tagged `v<graphviz version>.<n>`, `n` counting this repository's releases of that
Graphviz from 1. It carries:

| Asset | Holds |
| --- | --- |
| `graphviz-<os>-<arch>.tar.gz` | `dot` (`dot.exe` on windows) and the licence notices |
| `graphviz-wasm32-wasip1.tar.gz` | `lib/libgraphviz.a`, `include/`, `BUILD` and the licence notices |
| `checksums.txt` | the sha256 of each archive |

Each archive holds one directory of its own name. Every asset has a GitHub build provenance
attestation:

```sh
gh attestation verify graphviz-linux-amd64.tar.gz --repo packcloser/graphviz
```

A repository consumes an archive through its `pins.yaml`, with
`verify: github-attestation packcloser/graphviz packcloser/graphviz/.github/workflows/release.yaml`.

### The wasm library

`BUILD`, in the archive, is the record a consumer builds from: the compiler the library was
built with, the flags a program linked against it has to share, the libraries it is linked with
and the stack it needs. In short:

- compile and link with the same wasi-sdk release (`pins.yaml` here, `BUILD` there);
- compile with `--target=wasm32-wasip1 -funsigned-char -fno-strict-aliasing` and the three
  `-D_WASI_EMULATED_*` definitions;
- add `include/graphviz`, `include/graphviz/lib` and the directories under it whose headers the
  program includes; `include/graphviz/config.h` is the configuration the library was compiled
  with;
- register the built-in plugins: the library holds `gvplugin_dot_layout_LTX_library`,
  `gvplugin_neato_layout_LTX_library` and `gvplugin_core_LTX_library` and registers none.

`wasm/smoke.c` and `wasm/smoke.sh` are a whole program built that way.

## Building

```sh
just test    # dot for this host and the wasm library, each built and run
just build   # everything a release carries, into .build/dist
```

- `native/build.sh` compiles dot for one zig target; `native/smoke.sh` requires `dot -V` to
  name the pinned release, `-Tcanon` to write a fixed graph back byte for byte, and the dot
  engine to lay it out.
- `wasm/build.sh` applies the fixes, compiles the library with the pinned wasi-sdk and writes
  its headers and `BUILD`; `wasm/smoke.sh` links a program against it and runs it under the
  pinned wasmtime.
- `native/notices.sh` writes the notices of the two pieces of Graphviz under terms of their
  own; both kinds of archive carry them.

The archives are the same bytes whoever builds a commit: CI builds each twice on two runners and
compares, and builds the wasm library on macOS too, which has to give linux's bytes.

## What these builds leave out

They take no library but expat. A dot from a distribution is usually built with more, and
answers differently in the cases below. Each was observed on this build's `dot` 16.1.1.

- **No triangulation library (GTS).** `sfdp` is among the engines and cannot succeed in `dot`:
  on every graph, a single node included, it prints `Error: remove_overlap: Graphviz not built
  with triangulation library`, writes its layout and exits 1. (The wasm library reports that
  error only for a layout that asked for the library: UPSTREAM.md.) `overlap=prism` is ignored
  with a warning (`Overlap value "prism" unsupported - ignored`). `overlap=false` is accepted
  with no message, and removes overlaps by another method than the Prism one a build with the
  library uses, so `neato` and `fdp` can place nodes elsewhere than a standard dot does.
- **No IPSEPCOLA.** `neato` with `mode=ipsep` warns (`Illegal value ipsep for attribute
  "mode"`), ignores the attribute and lays out in its default mode.
- **No pango, no cairo.** Text is measured by Graphviz's own estimate, so a node with a label is
  not the size a build with pango gives it, and every coordinate of a laid-out graph with text
  can differ from such a build's. None of the cairo formats (`pdf`, `png` and the others) is
  written.
- **No gd.** `gif`, `jpeg`, `gd`, `gd2`, `wbmp` and `vrml` are not written.
- **No zlib.** `svgz` is not written.
- **No ltdl, and no plugin beyond the built-in ones** (core and the dot and neato layouts; `dot`
  has vt as well): `kitty`, `webp` and every other plugin's format are not written.

A format that is not written is refused: `Format: "svgz" not recognized. Use one of: …`, exit 1.
The formats `dot` writes are those `dot -T?` lists: `canon`, `cmap`, `cmapx`, `cmapx_np`, `dot`,
`dot_json`, `eps`, `fig`, `gv`, `imap`, `imap_np`, `ismap`, `json`, `json0`, `pic`, `plain`,
`plain-ext`, `pov`, `ps`, `ps2`, `svg`, `svg_inline`, `tk`, the `vt` forms, `xdot`, `xdot1.2`,
`xdot1.4` and `xdot_json`. The engines are `circo`, `dot`, `fdp`, `neato`, `nop`, `nop1`,
`nop2`, `osage`, `patchwork`, `sfdp` and `twopi`.

On windows the C library has no `drand48`, and Graphviz falls back to `rand`: a seeded layout
(`neato`, `fdp`) differs there from the other platforms.

## Licence

This repository's own files are under the MIT licence (`LICENSE`). Graphviz is under the Eclipse
Public License 2.0 and expat under the MIT licence; each archive carries their notices, and
those of the two pieces of Graphviz under terms of their own.
