# This file is the project's own.
# Add recipes leveraging provided `do` ready-made recipes, or create your own.
# The import must be kept: it mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

# The time every archive entry gets (scripts/archive.sh): the commit's, so
# that two builds of one commit record the same. No binary records a time.
export SOURCE_DATE_EPOCH := env("SOURCE_DATE_EPOCH", `git log -1 --format=%ct 2> /dev/null || echo 0`)

# Every platform dot is built for, as os-arch.
platforms := "linux-amd64 linux-arm64 darwin-arm64 windows-amd64 windows-arm64"

# What `just build` builds, each a recipe of that name and a lane of the
# workflows: the native dot for every platform, and the wasm library.
products := "native wasm"

# The FIRST recipe defined here becomes `just`'s default.
lint: do::lint::default
fix: do::fix::default
# dot built for this host and run on it; the wasm library built, a program
# linked against it and run.
test: native-test wasm-test
security: do::security::default

# Build everything a release carries into $LIMEN_BUILD/dist.
build: (product "native") (product "wasm")

# Build one product as a release carries it: dot for every platform, or the
# wasm library.
product name:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ name }}" in
        native) just native {{ platforms }} ;;
        wasm) just wasm ;;
        *) echo "unknown product {{ name }} (one of {{ products }})" >&2; exit 1 ;;
    esac

# Build dot (Graphviz, its layout engines and core renderers, expat linked in)
# for the given platforms, from the release as it ships, unpatched: the
# reference other repositories hold their own output to. Archived with
# Graphviz's and expat's licence notices, and those of the two pieces of
# Graphviz under terms of their own, into
# $LIMEN_BUILD/dist/graphviz-<platform>.tar.gz.
native +targets: (_fetch "graphviz") (_fetch "expat")
    #!/usr/bin/env bash
    set -euo pipefail
    export ZIG_GLOBAL_CACHE_DIR="${LIMEN_BUILD}/zig/global" ZIG_LOCAL_CACHE_DIR="${LIMEN_BUILD}/zig/local"
    version=$(limen pins get graphviz version)
    src="${LIMEN_BUILD}/src/graphviz-${version}"
    expat_tag=$(limen pins get expat version)
    expat="${LIMEN_BUILD}/src/expat-${expat_tag}"
    expat_version=$(just _expat-version)
    mkdir -p "${LIMEN_BUILD}/dist"
    set -- {{ targets }}
    for platform in "$@"; do
        out="${LIMEN_BUILD}/native/${platform}"
        rm -rf "${out}"
        native/build.sh "${src}" "${expat}" "${version}" "${expat_version}" "$(just _zig-target "${platform}")" "${out}"
        x=""
        case "${platform}" in windows-*) x=".exe" ;; esac
        name="graphviz-${platform}"
        stage="${LIMEN_BUILD}/stage/${name}"
        rm -rf "${stage}"
        mkdir -p "${stage}"
        cp "${out}/bin/dot${x}" "${stage}/"
        cp "${src}/COPYING" "${src}/cpl1.0.txt" "${src}/AUTHORS" "${stage}/"
        cp "${expat}/COPYING" "${stage}/COPYING.expat"
        native/notices.sh "${src}" "${stage}"
        scripts/archive.sh "${LIMEN_BUILD}/stage" "${name}" "${LIMEN_BUILD}/dist"
    done

# Build dot for this host, and require it to name the pinned Graphviz, to write
# a graph back in canonical form and to lay it out; then once more as the
# release workflow asks, which has no pin to name.
native-test:
    #!/usr/bin/env bash
    set -euo pipefail
    platform=$(just _host-platform)
    just native "${platform}"
    native/smoke.sh "${LIMEN_BUILD}/native/${platform}/bin" "$(limen pins get graphviz version)"
    native/smoke.sh "${LIMEN_BUILD}/native/${platform}/bin"

# Build Graphviz and expat for wasm32-wasip1 as a static library, with the
# fixes wasm/build.sh applies, and archive it with its headers, its BUILD
# record and the same notices dot's archives carry, into
# $LIMEN_BUILD/dist/graphviz-wasm32-wasip1.tar.gz. The library is the same
# bytes whichever host compiles it.
wasm: (_fetch "graphviz") (_fetch "expat") _wasi-sdk
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(limen pins get graphviz version)
    src="${LIMEN_BUILD}/src/graphviz-${version}"
    expat="${LIMEN_BUILD}/src/expat-$(limen pins get expat version)"
    out="${LIMEN_BUILD}/wasm"
    wasm/build.sh "${src}" "${expat}" "${version}" "$(just _expat-version)" "$(just _wasi-sdk-dir)" "${out}"
    name="graphviz-wasm32-wasip1"
    stage="${LIMEN_BUILD}/stage/${name}"
    rm -rf "${stage}"
    mkdir -p "${stage}"
    cp -R "${out}/lib" "${out}/include" "${out}/BUILD" "${stage}/"
    cp "${src}/COPYING" "${src}/cpl1.0.txt" "${src}/AUTHORS" "${stage}/"
    cp "${expat}/COPYING" "${stage}/COPYING.expat"
    native/notices.sh "${src}" "${stage}"
    mkdir -p "${LIMEN_BUILD}/dist"
    scripts/archive.sh "${LIMEN_BUILD}/stage" "${name}" "${LIMEN_BUILD}/dist"

# Build the wasm library, link a program against it as its BUILD record says
# to, and run it under the pinned wasmtime: the library reads a graph, lays it
# out with the dot engine and writes it, and names the pinned Graphviz.
# Where no wasi-sdk is pinned for the host (windows), there is nothing to run.
wasm-test:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! just _wasi-sdk-pin > /dev/null 2>&1; then
        echo "wasm: not built on $(uname -s)-$(uname -m), nothing to run"
        exit 0
    fi
    just wasm
    wasm/smoke.sh "${LIMEN_BUILD}/wasm" "$(just _wasi-sdk-dir)" "$(limen pins get graphviz version)"

# The release notes' source section: what the binaries and the library are
# built from, as pins.yaml pins it.
release-notes:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "## Corresponding source"
    echo
    echo "Built from upstream's releases, pinned in pins.yaml (url and sha256):"
    echo
    echo "- Graphviz $(limen pins get graphviz version): $(limen pins get graphviz url)"
    echo "- expat $(just _expat-version): $(limen pins get expat url)"
    echo
    echo "dot is built from them as they ship. The wasm library is built from them with the"
    echo "fixes this repository's wasm/build.sh applies at this release's tag (UPSTREAM.md),"
    echo "with wasi-sdk $(limen pins get wasi-sdk-linux-amd64 version)."

# A release's tag names the Graphviz it carries: v<graphviz version>.<n>, n
# counting this repository's releases of that Graphviz from 1.
[positional-arguments]
release-tag tag:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(limen pins get graphviz version)
    tag="$1"
    rest=${tag#"v${version}."}
    if [ "${rest}" = "${tag}" ] || ! [[ "${rest}" =~ ^[1-9][0-9]*$ ]]; then
        echo "tag ${tag}: a release of the pinned Graphviz ${version} is tagged v${version}.<n>" >&2
        exit 1
    fi
    echo "${tag}: Graphviz ${version}, release ${rest}"

# expat's release, from its tag: R_2_10_0 is 2.10.0.
_expat-version:
    #!/usr/bin/env bash
    set -euo pipefail
    tag=$(limen pins get expat version)
    version=${tag#R_}
    echo "${version//_/.}"

# The pin of the wasi-sdk for this host.
_wasi-sdk-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) echo wasi-sdk-macos-arm64 ;;
        Linux-aarch64) echo wasi-sdk-linux-arm64 ;;
        Linux-x86_64) echo wasi-sdk-linux-amd64 ;;
        *) echo "the wasm library is not built on $(uname -s)-$(uname -m)" >&2; exit 1 ;;
    esac

# Where the pinned wasi-sdk is unpacked.
_wasi-sdk-dir:
    #!/usr/bin/env bash
    set -euo pipefail
    pin=$(just _wasi-sdk-pin)
    echo "${LIMEN_BUILD}/toolchain/${pin}-$(limen pins get "${pin}" version)"

# Fetch, verify and unpack the pinned wasi-sdk for this host, once: it is
# unpacked beside its place and renamed there when tar is done, so a
# directory that is there is a whole one.
_wasi-sdk:
    #!/usr/bin/env bash
    set -euo pipefail
    pin=$(just _wasi-sdk-pin)
    just _fetch-file "${pin}"
    dir=$(just _wasi-sdk-dir)
    [ ! -d "${dir}" ] || exit 0
    rm -rf "${dir}.part"
    mkdir -p "${dir}.part"
    tar -xf "${LIMEN_BUILD}/src/${pin}-$(limen pins get "${pin}" version).tar.gz" -C "${dir}.part" --strip-components=1
    mv "${dir}.part" "${dir}"

# Fetch a pinned source to $LIMEN_BUILD/src/<name>-<version>.<ext>, verify it
# against pins.yaml on every run (a reused build directory keeps the tarball),
# and unpack it anew into $LIMEN_BUILD/src/<name>-<version>, whatever the top
# directory upstream's tarball has: a build may edit the tree.
_fetch name: (_fetch-file name)
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(limen pins get {{ name }} version)
    url=$(limen pins get {{ name }} url)
    case "${url}" in
        *.tar.xz) ext=tar.xz ;;
        *) ext=tar.gz ;;
    esac
    dir="${LIMEN_BUILD}/src"
    archive="${dir}/{{ name }}-${version}.${ext}"
    rm -rf "${dir:?}/{{ name }}-${version}"
    mkdir -p "${dir}/{{ name }}-${version}"
    tar -xf "${archive}" -C "${dir}/{{ name }}-${version}" --strip-components=1

# Fetch a pinned artifact to $LIMEN_BUILD/src/<name>-<version>.<ext> and
# verify it against pins.yaml on every run, without unpacking it.
_fetch-file name:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(limen pins get {{ name }} version)
    url=$(limen pins get {{ name }} url)
    sum=$(limen pins get {{ name }} sha256)
    case "${url}" in
        *.tar.xz) ext=tar.xz ;;
        *.tar.gz) ext=tar.gz ;;
        *) echo "{{ name }}: unsupported archive ${url##*/}" >&2; exit 1 ;;
    esac
    dir="${LIMEN_BUILD}/src"
    archive="${dir}/{{ name }}-${version}.${ext}"
    mkdir -p "${dir}"
    # A kept archive of other bytes (CI's cache, when a pin's sha256 moved under
    # one file name; a download cut short) is fetched again, once: left there,
    # every run would restore it and fail on it.
    if [ -f "${archive}" ] && ! echo "${sum}  ${archive}" | sha256sum -c - > /dev/null 2>&1; then
        rm -f "${archive}"
    fi
    [ -f "${archive}" ] || curl -fsSL --retry 3 -o "${archive}" "${url}"
    if ! echo "${sum}  ${archive}" | sha256sum -c - > /dev/null; then
        echo "${archive}: sha256 does not match pins.yaml's {{ name }} ${version}" >&2
        rm -f "${archive}"
        exit 1
    fi
    # A kept archive (CI's cache) is as old as its download: one no run
    # verifies any more is told from the others by its time.
    touch "${archive}"

# The zig target of a platform: musl on linux (static), the GNU ABI on windows.
_zig-target platform:
    #!/usr/bin/env bash
    case "{{ platform }}" in
        linux-amd64) echo x86_64-linux-musl ;;
        linux-arm64) echo aarch64-linux-musl ;;
        darwin-arm64) echo aarch64-macos ;;
        windows-amd64) echo x86_64-windows-gnu ;;
        windows-arm64) echo aarch64-windows-gnu ;;
        *) echo "unknown platform {{ platform }} (one of {{ platforms }})" >&2; exit 1 ;;
    esac

# This host's platform, as os-arch. In CI, RUNNER_OS and RUNNER_ARCH are the
# truth: Git for Windows' arm64 build ships an x86_64 bash, so uname and
# PROCESSOR_ARCHITECTURE report amd64 there. Elsewhere the pinned zig's own
# native target says what the machine is.
_host-platform:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${RUNNER_OS:-}" ] && [ -n "${RUNNER_ARCH:-}" ]; then
        os=${RUNNER_OS}
        machine=${RUNNER_ARCH}
    else
        native=$(zig env | sed -n -E 's/^ *\.target = "([^"]*)".*/\1/p')
        machine=${native%%-*}
        os=${native#*-}
        os=${os%%[.-]*}
    fi
    case "${os}" in
        Linux | linux) os=linux ;;
        macOS | macos) os=darwin ;;
        Windows | windows) os=windows ;;
        *) echo "unsupported host ${os}" >&2; exit 1 ;;
    esac
    case "${machine}" in
        X64 | x86_64) arch=amd64 ;;
        ARM64 | aarch64) arch=arm64 ;;
        *) echo "unsupported architecture ${machine}" >&2; exit 1 ;;
    esac
    echo "${os}-${arch}"
