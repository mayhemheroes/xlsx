#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's go-fuzz harness as a sanitized libFuzzer
# binary (OSS-Fuzz Go path: go-fuzz-build -libfuzzer + clang link) plus the
# pre-compiled upstream test runner that mayhem/test.sh RUNS.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV (under /opt/toolchains —
# absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the module cache under $GOMODCACHE.
#   - The module cache doubles as a FILE PROXY at $GOMODCACHE/cache/download. We set
#     GOPROXY to that file proxy FIRST, network LAST: the offline re-run resolves
#     entirely from the cache, and the network fallback only fills cache-misses on
#     this first online build. -mod=mod lets go-fuzz-build's `go get` of go-fuzz-dep
#     update go.mod from the cache. (GOPROXY=off is NOT enough — it blocks reading
#     the version list from the cache, which `go get` needs.)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link (keep ASan regardless of base default).
: "${SANITIZER_FLAGS=-fsanitize=address}"
# DWARF < 4 on the fuzz ELF (SPEC §6.2 item 10): gc emits DWARF4, but the
# clang-linked C shim lands first — thread GO_DEBUG_FLAGS through CGO and the link.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS GO_DEBUG_FLAGS MAYHEM_JOBS
export CGO_CFLAGS="${CGO_CFLAGS:-} $GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} $GO_DEBUG_FLAGS"

# Resolve modules offline-first from the in-image cache; network only as a fallback.
# $(go env GOMODCACHE) reads the pinned ENV, so it is correct under ANY $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

# go-fuzz-build needs the go-fuzz-dep package on the module graph. With -mod=mod +
# the file-proxy GOPROXY this resolves from the cache offline (no-op if already present).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep

# The legacy `func Fuzz(data []byte) int` harness lives at the repo root (fuzz.go,
# build tag gofuzz, package xlsx). Target name `process_cell` preserved from the
# archived Mayhemfile for corpus/run-history continuity.
TARGET="process_cell"

mkdir -p "$SRC/mayhem-build"
echo "=== building $TARGET (go-fuzz-build -libfuzzer) ==="
go-fuzz-build -libfuzzer -func Fuzz -o "$SRC/mayhem-build/$TARGET.a" .
# Link the go-fuzz archive into a libFuzzer binary with clang (ASan).
$CXX $GO_DEBUG_FLAGS $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# Pre-compile the FULL upstream test suite (normal flags, no sanitizers) so
# mayhem/test.sh only RUNS it. The module is a single root package.
# External linkmode -> a dynamically-linked runner (a static pure-Go binary
# ignores LD_PRELOAD, which the behavioral-oracle sabotage gate relies on).
echo "=== building upstream test runner (go test -c) ==="
CGO_ENABLED=1 go test -c -ldflags '-linkmode=external' -o "$SRC/mayhem-build/xlsx.test" .
echo "built $SRC/mayhem-build/xlsx.test"

echo "build.sh complete"
