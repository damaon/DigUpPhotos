#!/bin/bash
# Builds the core and runs its tests on Linux in Docker, as CI does (.github/workflows/linux.yml). The repo is copied
# into the container, so nothing here changes; the build is kept in a volume for the next run.
#   scripts/linux-test.sh                 Swift 6.2 on Ubuntu 24.04
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-swift:6.2-noble}"
docker run --rm -v "$PWD":/src:ro -v digup-linux-build:/work/.build "$IMAGE" bash -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq libsqlite3-dev >/dev/null
  cd /src && tar --exclude=./.build --exclude=./Vendor --exclude=./build.noindex --exclude=./.dev --exclude=./.git \
    -cf - . | tar -xf - -C /work
  cd /work && swift build --target DigUpCore && swift test'
