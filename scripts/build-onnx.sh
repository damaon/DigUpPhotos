#!/bin/bash
# Faces on Linux and Windows: ONNX Runtime (MIT, Microsoft's release build) into Vendor/onnxruntime, and the two
# OpenCV Zoo models (Apache-2.0) it runs into Vendor/sface: YuNet finds faces and their eyes, nose and mouth, SFace tells
# who each is (the model macOS runs on Core ML, scripts/build-sface.sh). All pinned by version or commit and SHA-256,
# all out of git. Does nothing when they're there already.
set -euo pipefail
cd "$(dirname "$0")/.."
ORT=1.22.0
case "$(uname -s)-$(uname -m)" in
  MINGW*|MSYS*|CYGWIN*) OS=win; ARCH=x64; ORT_SHA=174c616efc0271194488642a72f1a514e01487da4dfe84c49296d66e40ebe0da ;;
  *-aarch64|*-arm64) OS=linux; ARCH=aarch64; ORT_SHA=bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702 ;;
  *-x86_64) OS=linux; ARCH=x64; ORT_SHA=8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3 ;;
  *) echo "build-onnx.sh: no ONNX Runtime build for $(uname -sm)" >&2; exit 1 ;;
esac
ZOO=https://media.githubusercontent.com/media/opencv/opencv_zoo
SFACE_URL=$ZOO/ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
SFACE_SHA=0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
YUNET_URL=$ZOO/f12e12798e8314f7c074a6656816c048dcc95b7a/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
YUNET_SHA=8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4

sha() { (command -v sha256sum > /dev/null && sha256sum "$1" || shasum -a 256 "$1") | cut -d' ' -f1; }
# fetch URL SHA FILE: downloads FILE unless it's there with that checksum.
fetch() {
  [[ -f "$3" && "$(sha "$3")" == "$2" ]] && return
  mkdir -p "$(dirname "$3")"
  curl --fail --silent --show-error --location -o "$3.part" "$1"
  [[ "$(sha "$3.part")" == "$2" ]] || { echo "$3: wrong SHA-256" >&2; rm -f "$3.part"; exit 1; }
  mv "$3.part" "$3"
}

fetch "$SFACE_URL" "$SFACE_SHA" Vendor/sface/sface.onnx
fetch "$YUNET_URL" "$YUNET_SHA" Vendor/sface/yunet.onnx
if [[ "$(cat Vendor/onnxruntime/BUILD 2>/dev/null)" != "$ORT $OS $ARCH" ]]; then
  RELEASE=https://github.com/microsoft/onnxruntime/releases/download/v$ORT/onnxruntime-$OS-$ARCH-$ORT
  rm -rf Vendor/onnxruntime && mkdir -p Vendor/onnxruntime
  if [[ $OS == win ]]; then
    fetch "$RELEASE.zip" "$ORT_SHA" Vendor/onnxruntime.zip
    unzip -q Vendor/onnxruntime.zip -d Vendor && rm Vendor/onnxruntime.zip
    mv Vendor/onnxruntime-$OS-$ARCH-$ORT/* Vendor/onnxruntime/ && rm -rf Vendor/onnxruntime-$OS-$ARCH-$ORT
    rm -f Vendor/onnxruntime/lib/*.pdb   # 350 MB of debug symbols
  else
    fetch "$RELEASE.tgz" "$ORT_SHA" Vendor/onnxruntime.tgz
    tar -xzf Vendor/onnxruntime.tgz -C Vendor/onnxruntime --strip-components 1
    rm Vendor/onnxruntime.tgz
  fi
  echo "$ORT $OS $ARCH" > Vendor/onnxruntime/BUILD
  echo "Fetched ONNX Runtime $ORT ($ARCH) into Vendor/onnxruntime"
fi
