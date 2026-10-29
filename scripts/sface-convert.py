"""SFace (ONNX) → Core ML, for scripts/build-sface.sh: python sface-convert.py <model.onnx> <SFace.mlpackage>.

The Core ML model takes a 112×112 RGB face aligned to the ArcFace template (`FaceIdentity`) and gives the 128 numbers
OpenCV's FaceRecognizerSF would. It's checked against the ONNX graph on random faces before it's saved.
"""
import sys

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert
from PIL import Image

source, out = sys.argv[1], sys.argv[2]
model = onnx.load(source)
# The exporter listed the weights as graph inputs too: keep only the image, or they'd be inputs of the converted model.
weights = {i.name for i in model.graph.initializer}
image_inputs = [i for i in model.graph.input if i.name not in weights]
del model.graph.input[:]
model.graph.input.extend(image_inputs)
net = convert(model).eval()

faces = np.random.default_rng(1).integers(0, 256, (16, 3, 112, 112)).astype(np.float32)
with torch.no_grad():
    traced = torch.jit.trace(net, torch.from_numpy(faces[:1]))
    expected = np.concatenate([net(torch.from_numpy(faces[i:i + 1])).numpy() for i in range(len(faces))])

ml = ct.convert(traced, inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB)],
                outputs=[ct.TensorType(name="vector")], minimum_deployment_target=ct.target.macOS14,
                compute_precision=ct.precision.FLOAT16)
ml.short_description = ("SFace (OpenCV Zoo, Apache-2.0): a 128-number identity vector for a 112x112 RGB face aligned "
                        "to the ArcFace template.")

got = np.stack([np.array(ml.predict({"face": Image.fromarray(face.transpose(1, 2, 0).astype(np.uint8))})["vector"])
                .reshape(-1) for face in faces])
cosine = (got * expected).sum(1) / np.linalg.norm(got, axis=1) / np.linalg.norm(expected, axis=1)
print(f"Core ML vs ONNX: cosine ≥ {cosine.min():.5f}")
if cosine.min() < 0.999:
    sys.exit("the converted model doesn't match the original")
ml.save(out)
