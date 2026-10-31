#!/bin/bash
# Builds llama.cpp (MIT), the embedding runtime: the pinned build tag plus scripts/llama.cpp-no-logits.patch, as static
# libraries combined into Vendor/llama/lib/libllamacpp.a, with the headers in Vendor/llama/include (all out of git).
# On macOS it runs on Metal, whose shaders are embedded and compiled on first use, so no Metal toolchain is needed; on
# Linux and Windows on the CPU (llamacpp.lib on Windows, built from Git Bash). CMake comes from PATH, or from a venv in
# Vendor/ (needs uv). Does nothing when that build is already there; build.sh runs it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461   # the first tags with EmbeddingGemma 2 (text + vision + audio) are b11452+
# A new TAG ships only if `swift test` passes: ReferenceVectorTests checks it makes the same vectors, so every index is
# kept. If it fails, keep this TAG, or bump LlamaEmbedder.vectorVersion and write the reference vectors again
# (DIGUP_WRITE_REFERENCE=1 swift test --filter ReferenceVectorTests): every index then embeds again.
PATCH=scripts/llama.cpp-no-logits.patch
SOURCE=Vendor/llama.cpp
OUT=Vendor/llama
STAMP="$TAG $( (command -v sha256sum > /dev/null && sha256sum "$PATCH" || shasum -a 256 "$PATCH") | cut -c1-12)"
if [[ ( -f "$OUT/lib/libllamacpp.a" || -f "$OUT/lib/llamacpp.lib" ) && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2>/dev/null)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"   # --force also drops the old patch
fi
# Without the patch, every input token costs 1 MiB of logits that an embedding model never produces (262k vocabulary).
if git -C "$SOURCE" apply --check "../../$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "../../$PATCH"
fi

if ! command -v cmake > /dev/null; then
  if [[ ! -x Vendor/cmake-venv/bin/cmake ]]; then
    uv venv --quiet Vendor/cmake-venv --python 3.12
    uv pip install --quiet --python Vendor/cmake-venv/bin/python cmake ninja
  fi
  export PATH="$PWD/Vendor/cmake-venv/bin:$PATH"
fi
GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
B=Vendor/llama-build
LIBS=($B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a
  $B/ggml/src/libggml-cpu.a $B/vendor/hash/libvendor-hash.a)
WINDOWS=$([[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && echo 1 || echo "")
if [[ -n $WINDOWS ]]; then
  # Visual Studio's compiler (from Git Bash, as on GitHub's runners), whichever Visual Studio CMake finds: .lib files in
  # Release/ folders, with the DLL C runtime (/MD) that Swift links too.
  GENERATOR=""
  PLATFORM=(-A x64 -DGGML_OPENMP=OFF -DGGML_BLAS=OFF -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL)
  LIBS=($B/src/Release/llama.lib $B/tools/mtmd/Release/mtmd.lib $B/ggml/src/Release/ggml.lib
    $B/ggml/src/Release/ggml-base.lib $B/ggml/src/Release/ggml-cpu.lib $B/vendor/hash/Release/vendor-hash.lib)
elif [[ "$(uname)" == Darwin ]]; then
  PLATFORM=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  LIBS+=($B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a)
else
  # ggml's own thread pool rather than OpenMP, so the binary needs no libgomp. Swift's own clang, not whatever `cc` is.
  PLATFORM=(-DGGML_OPENMP=OFF -DGGML_BLAS=OFF -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
fi
# Only the libraries: no tools, no server, nothing downloaded at build time.
cmake -S "$SOURCE" -B $B ${GENERATOR:+-G "$GENERATOR"} -DCMAKE_BUILD_TYPE=Release "${PLATFORM[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
cmake --build $B --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" --target llama mtmd > /dev/null

mkdir -p "$OUT/lib" "$OUT/include"
rm -f "$OUT/lib/libllamacpp.a" "$OUT/lib/llamacpp.lib"
if [[ -n $WINDOWS ]]; then
  VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  LIBEXE=$("$VSWHERE" -latest -products '*' -find 'VC/Tools/MSVC/**/bin/Hostx64/x64/lib.exe' | head -1 | tr -d '\r')
  "$LIBEXE" -nologo -out:"$OUT/lib/llamacpp.lib" "${LIBS[@]}"
elif [[ "$(uname)" == Darwin ]]; then
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" "${LIBS[@]}"
else
  { echo "create $OUT/lib/libllamacpp.a"; printf 'addlib %s\n' "${LIBS[@]}"; echo save; echo end; } | ar -M
fi
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
# The build, for logs and `digup status` (indexes record LlamaEmbedder.vectorVersion, not this). SwiftPM doesn't see a
# changed header, so the Swift file that reads it is touched.
printf '// Written by scripts/build-llama.sh.\n#define LLAMA_BUILD_TAG "%s"\n' "$TAG" > "$OUT/include/llama-build.h"
touch Sources/LlamaRuntime/LlamaEmbedder.swift
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched) into $OUT"
