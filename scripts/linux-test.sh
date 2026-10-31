#!/bin/bash
# Builds and runs the tests on Linux in Docker, as CI does (.github/workflows/linux.yml). The repo is copied into the
# container, so nothing here changes; the Swift build and llama.cpp's are kept in volumes for the next run. With the
# model files in Application Support, the reference-vector test runs on them too.
#   scripts/linux-test.sh                 Swift 6.2 on Ubuntu 24.04
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-swift:6.2-noble}"
MODELS="$HOME/Library/Application Support/DigUpPhotos/Models"
MOUNTS=(-v "$PWD":/src:ro -v digup-linux-build:/work/.build -v digup-linux-vendor:/work/Vendor)
[[ -d "$MODELS" ]] && MOUNTS+=(-v "$MODELS":/models:ro -e DIGUP_MODELS=/models)
docker run --rm "${MOUNTS[@]}" "$IMAGE" bash -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq libsqlite3-dev libheif-dev libheif-plugin-libde265 ffmpeg poppler-utils cmake ninja-build curl >/dev/null
  cd /src && tar --exclude=./.build --exclude=./Vendor --exclude=./build.noindex --exclude=./.dev --exclude=./.git \
    -cf - . | tar -xf - -C /work
  cd /work && scripts/build-llama.sh && scripts/build-onnx.sh && swift build --build-tests && swift test --skip-build'
