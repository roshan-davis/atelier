#!/usr/bin/env python3
"""Builds AI Denoise's model, Sources/AtelierCore/Models/PMRID.onnx, from PMRID's published weights.

PMRID ("Practical Deep Raw Image Denoising on Mobile Devices", Wang et al., ECCV 2020;
https://github.com/megvii-research/PMRID, Apache 2.0) ships a PyTorch checkpoint. This script reads
it without PyTorch (a restricted unpickler that only rebuilds tensors), rebuilds models/net_torch.py
as an ONNX graph op by op and writes it with a fixed 1 x 4 x 512 x 512 input, so Core ML can compile
it. The result is checked into the repository; run this again only to rebuild it.

    python3 -m venv /tmp/pmrid && . /tmp/pmrid/bin/activate
    pip install onnx numpy onnxruntime        # onnxruntime: --check only
    python3 Scripts/models/convert_pmrid_onnx.py [--check]

Input "input" and output "output": the four Bayer planes (R, G, G, B) after PMRID's k-sigma
transform, times 256. --check runs the graph on random input and compares it with the expected
SHA-256 of the file this script wrote when the model was added.
"""
import argparse
import collections
import hashlib
import io
import os
import pickle
import sys
import urllib.request
import zipfile

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

URL = "https://raw.githubusercontent.com/megvii-research/PMRID/main/models/torch_pretrained.ckp"
CHECKPOINT_SHA256 = "9361614f3514d27351d81909f2215c0fdc38619c0288d936b7266485ac106c14"
MODEL_SHA256 = "2c76727c7b2048b317aa6e759460cb7208fedbfcfe59e46efb2595774ad03966"
TILE = 512
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "Sources", "AtelierCore", "Models", "PMRID.onnx")


def load_checkpoint(data):
    """The checkpoint's state dict as NumPy arrays; only tensors and OrderedDicts are unpickled."""
    z = zipfile.ZipFile(io.BytesIO(data))
    prefix = z.namelist()[0].split("/")[0]
    dtypes = {"FloatStorage": np.float32, "HalfStorage": np.float16, "LongStorage": np.int64}

    class Storage:
        def __init__(self, key, dtype):
            self.key, self.dtype = key, dtype

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if name == "_rebuild_tensor_v2":
                def rebuild(storage, offset, size, stride, *_):
                    raw = np.frombuffer(z.read(f"{prefix}/data/{storage.key}"), dtype=storage.dtype)
                    if not size:
                        return raw[offset:offset + 1].reshape(())
                    return np.lib.stride_tricks.as_strided(
                        raw[offset:], shape=size, strides=[s * raw.itemsize for s in stride]).copy()
                return rebuild
            if module == "collections" and name == "OrderedDict":
                return collections.OrderedDict
            if name.endswith("Storage"):
                return name
            raise pickle.UnpicklingError(f"refusing {module}.{name}")

        def persistent_load(self, pid):
            _, kind, key, _, _ = pid
            return Storage(key, dtypes[kind])

    return Unpickler(z.open(f"{prefix}/data.pkl")).load()


def build(sd):
    nodes, inits, count = [], {}, [0]

    def name(p):
        count[0] += 1
        return f"{p}_{count[0]}"

    def weight(key):
        if key not in inits:
            inits[key] = numpy_helper.from_array(sd[key].astype(np.float32), key)
        return key

    def conv(x, prefix, k, stride, pad, separable, relu):
        if separable:
            channels = sd[prefix + ".depthwise.weight"].shape[0]
            y = name("dw")
            nodes.append(helper.make_node("Conv", [x, weight(prefix + ".depthwise.weight")], [y], group=channels,
                                          kernel_shape=[k, k], strides=[stride] * 2, pads=[pad] * 4))
            z = name("pw")
            nodes.append(helper.make_node("Conv", [y, weight(prefix + ".pointwise.weight"),
                                                   weight(prefix + ".pointwise.bias")], [z], kernel_shape=[1, 1]))
        else:
            z = name("cv")
            nodes.append(helper.make_node("Conv", [x, weight(prefix + ".conv.weight"), weight(prefix + ".conv.bias")],
                                          [z], kernel_shape=[k, k], strides=[stride] * 2, pads=[pad] * 4))
        if relu:
            r = name("relu")
            nodes.append(helper.make_node("Relu", [z], [r]))
            return r
        return z

    def add(a, b):
        o = name("add")
        nodes.append(helper.make_node("Add", [a, b], [o]))
        return o

    def relu(a):
        o = name("relu")
        nodes.append(helper.make_node("Relu", [a], [o]))
        return o

    def encoder_block(x, p, stride, same):
        projection = x if same else conv(x, p + ".proj", 3, stride, 1, True, False)
        y = conv(x, p + ".conv1", 5, stride, 2, True, True)
        y = conv(y, p + ".conv2", 5, 1, 2, True, False)
        return relu(add(y, projection))

    def encoder_stage(x, p, n):
        x = encoder_block(x, p + ".0", 2, False)
        for i in range(1, n):
            x = encoder_block(x, f"{p}.{i}", 1, True)
        return x

    def decoder_block(x, p, k=3):
        y = conv(x, p + ".conv0", k, 1, k // 2, True, True)
        y = conv(y, p + ".conv1", k, 1, k // 2, True, False)
        return add(y, x)

    def decoder_stage(x, skip, p):
        x = decoder_block(x, p + ".decode_conv")
        up = name("up")
        nodes.append(helper.make_node("ConvTranspose", [x, weight(p + ".upsample.weight"), weight(p + ".upsample.bias")],
                                      [up], kernel_shape=[2, 2], strides=[2, 2]))
        return add(up, conv(skip, p + ".proj_conv", 3, 1, 1, True, True))

    c0 = conv("input", "conv0", 3, 1, 1, False, True)
    c1 = encoder_stage(c0, "enc1", 2)
    c2 = encoder_stage(c1, "enc2", 2)
    c3 = encoder_stage(c2, "enc3", 4)
    c4 = encoder_stage(c3, "enc4", 4)
    c5 = conv(c4, "encdec", 3, 1, 1, True, True)
    x = decoder_stage(c5, c3, "dec1")
    x = decoder_stage(x, c2, "dec2")
    x = decoder_stage(x, c1, "dec3")
    x = decoder_stage(x, c0, "dec4")
    x = decoder_block(x, "out0")
    x = conv(x, "out1", 3, 1, 1, False, False)
    nodes.append(helper.make_node("Add", ["input", x], ["output"]))
    unused = [k for k in sd if k not in inits]
    if unused:
        sys.exit(f"weights not used: {unused}")
    shape = [1, 4, TILE, TILE]
    graph = helper.make_graph(nodes, "pmrid", [helper.make_tensor_value_info("input", TensorProto.FLOAT, shape)],
                              [helper.make_tensor_value_info("output", TensorProto.FLOAT, shape)], list(inits.values()))
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="run the model once with ONNX Runtime")
    args = parser.parse_args()
    data = urllib.request.urlopen(URL).read()
    if hashlib.sha256(data).hexdigest() != CHECKPOINT_SHA256:
        sys.exit("the downloaded checkpoint isn't the expected file")
    model = build(load_checkpoint(data))
    out = os.path.abspath(OUT)
    onnx.save(model, out)
    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    print(f"wrote {out} ({os.path.getsize(out)} bytes, SHA-256 {digest})")
    if digest != MODEL_SHA256:
        print("note: not byte-identical to the checked-in model (a different onnx version can reorder fields)")
    if args.check:
        import onnxruntime
        session = onnxruntime.InferenceSession(out)
        x = (np.random.default_rng(0).random((1, 4, TILE, TILE), dtype=np.float32) * 200)
        y = session.run(None, {"input": x})[0]
        print("ran: output", y.shape, "mean change", float(np.abs(y - x).mean()))


if __name__ == "__main__":
    main()
