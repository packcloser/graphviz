# Upstream

Builds of [Graphviz](https://gitlab.com/graphviz/graphviz), from its release tarball, with
[expat](https://github.com/libexpat/libexpat), from its release tarball.

- Built from: the `graphviz` and `expat` entries of `pins.yaml`, each tarball verified by
  sha256, expat's by its signature as well.
- `dot`, the native program, is upstream's sources unchanged.
- The wasm library is upstream's sources with the changes below, each applied by
  `wasm/build.sh` to the unpacked tree and each stopping the build when the code it changes is
  not the code it was written for: a new Graphviz means reading each again.

## Changes upstream does not have

All are in the wasm library alone. Most are faults a program that keeps Graphviz in one
long-lived process meets and upstream's `dot`, which lays out one input and exits, does not.
They were written in forkcloser/go-graphviz, which built the library before this repository
did; the two patch files' comments still say so.

| Change | Where | Why |
| --- | --- | --- |
| `storeline` passes the number of spans stored so far as the old size | `lib/common/labels.c` (one line, `wasm/build.sh`) | It told `gv_recalloc` that one more span existed than did, so the span about to be filled was never zeroed: a label whose first line is empty freed a garbage layout pointer, which under wasm is an indirect call into nowhere |
| `gvusershape_file_release` always closes the file | `lib/gvc/gvusershape.c` (one line, `wasm/build.sh`) | Graphviz keeps every image file it sizes open for the life of the process, closing after use only once 50 are open; a host file system pins an open file (Windows will not delete it). `gvusershape_file_access` reopens a closed file |
| `webp_size` reads each of the three WebP layouts' canvas size from where the format keeps it | `lib/gvc/gvusershape.c` (`wasm/patches/webp-size.patch`) | It read the size from where only a plain lossy WebP keeps it: a lossless or extended one came out tens of thousands to hundreds of millions of points a side |
| An image is sized once a layout, not once a process | `lib/gvc/gvusershape.c` (`wasm/patches/image-size.patch`), `lib/gvc/gvcproc.h`, `lib/gvc/gvlayout.c` (one line each) | A file that changed between two layouts kept the size it had at the first |
| `agconcat` runs the grammar's clean-up for any parse bison reports failed | `lib/cgraph/grammar.c` (one line, `wasm/build.sh`) | When bison runs out of its own stack it returns without the grammar's error rule, where the parser frees what it holds: about 175 KiB leaked for clusters nested 4000 deep |
| `parse_reclbl` counts the fields as it builds them | `lib/common/shapes.c` (`wasm/patches/reclbl-free.patch`) | On a record label it cannot read it freed by a count set only at the end: the fields read before the fault leaked, about 330 bytes a layout of `label="{a\|"` |
| The stand-in `remove_overlap` reports only when it is given sizes | `lib/neatogen/overlap.c` (one line, `wasm/build.sh`) | Built without a triangulation library, it reported an error whatever it was given, and sfdp calls it at the end of every layout: an error for a layout that asked nothing of the library |
| `agstrcanon_bytes` is `4n+3` | `lib/cgraph/agstrcanon.h` (one line, `wasm/build.sh`) | The DOT writer's buffer of `2n+3` bytes is too small for a string that is nearly all quotes (two bytes each, and a line break after every `linelength` characters): an 8 KiB label came out with bytes of the heap in it, a 2 MiB one trapped the module |

None has been reported upstream from this repository.
