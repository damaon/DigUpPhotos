#!/bin/bash
# Builds the face-recognition model: SFace from OpenCV Zoo (Apache-2.0, 38 MB ONNX, pinned by commit and SHA-256),
# converted to Core ML (scripts/sface-convert.py, float16) and compiled into Vendor/sface/SFace.mlmodelc (out of git).
# The indexing helper loads it from the app's Resources; `digup` and the tests from Vendor/sface. Needs uv, for a
# Python venv with the converter in Vendor/sface-venv. Does nothing when that build is already there; build.sh runs
# it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT=ba91a3b91d00d76e86540d4013f944bd6b514e39
SHA256=0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
URL="https://media.githubusercontent.com/media/opencv/opencv_zoo/$COMMIT/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
OUT=Vendor/sface
STAMP="$COMMIT $(shasum -a 256 scripts/sface-convert.py | cut -c1-12)"
if [[ -d "$OUT/SFace.mlmodelc" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p "$OUT"
ONNX="$OUT/sface.onnx"
if [[ ! -f "$ONNX" || "$(shasum -a 256 "$ONNX" | cut -d' ' -f1)" != "$SHA256" ]]; then
  curl --fail --silent --show-error --location -o "$ONNX.part" "$URL"
  [[ "$(shasum -a 256 "$ONNX.part" | cut -d' ' -f1)" == "$SHA256" ]] || { echo "sface.onnx: wrong SHA-256" >&2; exit 1; }
  mv "$ONNX.part" "$ONNX"
fi

VENV=Vendor/sface-venv
if [[ ! -x "$VENV/bin/python" ]]; then
  uv venv --quiet "$VENV" --python 3.12
fi
# The versions the conversion was checked with (coremltools 9.0 is tested up to torch 2.7).
uv pip install --quiet --python "$VENV/bin/python" torch==2.7.0 coremltools==9.0 onnx==1.18.0 onnx2torch==1.5.15 \
  numpy==2.2.6 pillow==11.2.1
rm -rf "$OUT/SFace.mlpackage" "$OUT/SFace.mlmodelc"
"$VENV/bin/python" -I scripts/sface-convert.py "$ONNX" "$OUT/SFace.mlpackage" 2>&1 \
  | grep -E "cosine|Error|error" || true
[[ -d "$OUT/SFace.mlpackage" ]] || { echo "SFace: conversion failed" >&2; exit 1; }
xcrun coremlcompiler compile "$OUT/SFace.mlpackage" "$OUT" > /dev/null
echo "$STAMP" > "$OUT/BUILD"
echo "Built $OUT/SFace.mlmodelc"
