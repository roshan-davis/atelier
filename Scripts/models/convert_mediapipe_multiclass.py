#!/usr/bin/env python3
"""Converts Google's MediaPipe Multiclass Selfie Segmentation model (Apache 2.0) to Core ML.

Select People uses it for Face Skin, Body Skin, Hair and Clothes. The converted model is checked
into Sources/AtelierCore/Models so the app has it without downloading anything; run this again
only to rebuild it.

    python3 -m venv /tmp/mpvenv && . /tmp/mpvenv/bin/activate
    pip install "coremltools==8.3.0" tflite "numpy<2.2" ai-edge-litert   # ai-edge-litert: --check only
    python3 Scripts/models/convert_mediapipe_multiclass.py [--check]

The TFLite graph is rebuilt op by op with coremltools' MIL builder (there is no direct TFLite
converter). --check runs the same graph in NumPy and compares it with Google's own TFLite runtime
on random and real inputs, so the op-by-op translation is verified even on Linux, where Core ML
can't run. On a Mac the saved model itself is compared too.

Input: "image", RGB 256 x 256, values 0...1 (the model's own normalization).
Output: "segmentation", 1 x 256 x 256 x 6 class chances (softmax of the TFLite logits), in order:
background, hair, body skin, face skin, clothes, others (accessories).
"""
import argparse
import hashlib
import os
import sys
import urllib.request

import numpy as np

URL = ("https://storage.googleapis.com/mediapipe-models/image_segmenter/"
       "selfie_multiclass_256x256/float32/latest/selfie_multiclass_256x256.tflite")
SHA256 = "c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0"
CLASSES = ["background", "hair", "body-skin", "face-skin", "clothes", "others"]
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Sources", "AtelierCore", "Models", "PeopleParts.mlpackage")


def download(cache):
    path = os.path.join(cache, "selfie_multiclass_256x256.tflite")
    if not os.path.exists(path):
        os.makedirs(cache, exist_ok=True)
        urllib.request.urlretrieve(URL, path)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != SHA256:
        sys.exit(f"checksum mismatch for {path}: {digest}")
    return path


# MARK: Reading the TFLite graph

class Graph:
    def __init__(self, path):
        import tflite
        self.tflite = tflite
        buf = open(path, "rb").read()
        self.model = tflite.Model.GetRootAsModel(buf, 0)
        self.sub = self.model.Subgraphs(0)
        names = {v: k for k, v in tflite.BuiltinOperator.__dict__.items() if not k.startswith("_")}
        self.ops = []
        for i in range(self.sub.OperatorsLength()):
            op = self.sub.Operators(i)
            code = self.model.OperatorCodes(op.OpcodeIndex())
            name = names[max(code.BuiltinCode(), code.DeprecatedBuiltinCode())]
            self.ops.append((name, list(op.InputsAsNumpy()), list(op.OutputsAsNumpy()), op))
        self.input = self.sub.Inputs(0)
        self.output = self.sub.Outputs(0)

    def const(self, index):
        t = self.sub.Tensors(index)
        data = self.model.Buffers(t.Buffer()).DataAsNumpy()
        if isinstance(data, int) or data is None or len(data) == 0:
            return None
        dtype = {0: np.float32, 2: np.int32, 4: np.int64, 1: np.float16}[t.Type()]
        shape = list(t.ShapeAsNumpy()) if t.ShapeLength() else []
        return np.frombuffer(data.tobytes(), dtype=dtype).reshape(shape)

    def shape(self, index):
        t = self.sub.Tensors(index)
        return list(t.ShapeAsNumpy()) if t.ShapeLength() else []

    def options(self, op, kind):
        o = op.BuiltinOptions()
        x = getattr(self.tflite, kind)()
        x.Init(o.Bytes, o.Pos)
        return x


def same_padding(size, kernel, stride, dilation=1):
    """TensorFlow's SAME padding: (before, after)."""
    effective = (kernel - 1) * dilation + 1
    out = -(-size // stride)
    total = max((out - 1) * stride + effective - size, 0)
    return total // 2, total - total // 2


# MARK: One walk over the graph, two backends

def walk(graph, backend, x):
    """Runs every op through `backend` and returns the output tensor."""
    values = {graph.input: x}

    def get(index):
        if index in values:
            return values[index]
        c = graph.const(index)
        if c is None:
            raise KeyError(index)
        return backend.const(c)

    for name, ins, outs, op in graph.ops:
        if name == "CONV_2D":
            o = graph.options(op, "Conv2DOptions")
            w = graph.const(ins[1]); b = graph.const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            y = backend.conv(values[ins[0]], w, b, o.StrideH(), o.StrideW(), o.DilationHFactor(),
                             o.Padding() == 0, groups=1)
            act = o.FusedActivationFunction()
        elif name == "DEPTHWISE_CONV_2D":
            o = graph.options(op, "DepthwiseConv2DOptions")
            assert o.DepthMultiplier() == 1
            w = graph.const(ins[1]); b = graph.const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            # [1, H, W, C] -> [C, H, W, 1]: one filter per channel.
            w = np.transpose(w, (3, 1, 2, 0))
            y = backend.conv(values[ins[0]], w, b, o.StrideH(), o.StrideW(), o.DilationHFactor(),
                             o.Padding() == 0, groups=w.shape[0])
            act = o.FusedActivationFunction()
        elif name == "TRANSPOSE_CONV":
            o = graph.options(op, "TransposeConvOptions")
            out_shape = [int(v) for v in graph.const(ins[0])]
            w = graph.const(ins[1])
            b = graph.const(ins[3]) if len(ins) > 3 and ins[3] >= 0 else None
            y = backend.transpose_conv(values[ins[2]], w, b, o.StrideH(), o.StrideW(), out_shape, o.Padding() == 0)
            act = o.FusedActivationFunction() if hasattr(o, "FusedActivationFunction") else 0
        elif name in ("ADD", "MUL"):
            o = graph.options(op, "AddOptions" if name == "ADD" else "MulOptions")
            y = backend.binary(name, get(ins[0]), get(ins[1]))
            act = o.FusedActivationFunction()
        elif name == "RESHAPE":
            y = backend.reshape(values[ins[0]], [int(v) for v in graph.shape(outs[0])])
            act = 0
        elif name == "TRANSPOSE":
            y = backend.transpose(values[ins[0]], [int(v) for v in graph.const(ins[1])])
            act = 0
        elif name == "SOFTMAX":
            assert graph.options(op, "SoftmaxOptions").Beta() == 1.0
            y = backend.softmax(values[ins[0]])
            act = 0
        elif name == "SUM":
            axes = [int(v) for v in np.atleast_1d(graph.const(ins[1]))]
            assert graph.options(op, "ReducerOptions").KeepDims()
            y = backend.sum(values[ins[0]], axes)
            act = 0
        elif name in ("RESIZE_BILINEAR", "RESIZE_NEAREST_NEIGHBOR"):
            o = graph.options(op, "ResizeBilinearOptions" if name == "RESIZE_BILINEAR" else "ResizeNearestNeighborOptions")
            assert not o.AlignCorners() and o.HalfPixelCenters()
            size = [int(v) for v in graph.const(ins[1])]
            y = backend.resize(values[ins[0]], size, bilinear=name == "RESIZE_BILINEAR")
            act = 0
        else:
            raise NotImplementedError(name)
        assert act in (0, 1, 3), (name, act)
        if act:
            y = backend.relu(y, six=act == 3)
        values[outs[0]] = y
    return values[graph.output]


class NumpyBackend:
    """Reference semantics in NHWC, for --check."""

    def const(self, c):
        return c.astype(np.float32)

    def conv(self, x, w, b, sh, sw, d, same, groups):
        n, h, wd, c = x.shape
        o, kh, kw, ci = w.shape
        if same:
            pt, pb = same_padding(h, kh, sh, d); pl, pr = same_padding(wd, kw, sw, d)
        else:
            pt = pb = pl = pr = 0
        xp = np.pad(x, ((0, 0), (pt, pb), (pl, pr), (0, 0)))
        oh = (h + pt + pb - ((kh - 1) * d + 1)) // sh + 1
        ow = (wd + pl + pr - ((kw - 1) * d + 1)) // sw + 1
        out = np.zeros((n, oh, ow, o), np.float32)
        for i in range(kh):
            for j in range(kw):
                patch = xp[:, i * d: i * d + (oh - 1) * sh + 1: sh, j * d: j * d + (ow - 1) * sw + 1: sw, :]
                if groups == 1:
                    out += np.einsum("nhwc,oc->nhwo", patch, w[:, i, j, :], optimize=True)
                else:
                    out += patch * w[:, i, j, 0]
        if b is not None:
            out += b
        return out

    def transpose_conv(self, x, w, b, sh, sw, out_shape, same):
        n, h, wd, c = x.shape
        o, kh, kw, ci = w.shape
        _, oh, ow, _ = out_shape
        full_h = (h - 1) * sh + kh; full_w = (wd - 1) * sw + kw
        full = np.zeros((n, full_h, full_w, o), np.float32)
        for i in range(kh):
            for j in range(kw):
                full[:, i: i + (h - 1) * sh + 1: sh, j: j + (wd - 1) * sw + 1: sw, :] += \
                    np.einsum("nhwc,oc->nhwo", x, w[:, i, j, :], optimize=True)
        pt = max((h - 1) * sh + kh - oh, 0) // 2 if same else 0
        pl = max((wd - 1) * sw + kw - ow, 0) // 2 if same else 0
        out = full[:, pt: pt + oh, pl: pl + ow, :]
        if b is not None:
            out = out + b
        return out

    def binary(self, name, a, b):
        return a + b if name == "ADD" else a * b

    def reshape(self, x, shape):
        return x.reshape(shape)

    def transpose(self, x, perm):
        return np.transpose(x, perm)

    def softmax(self, x):
        e = np.exp(x - x.max(axis=-1, keepdims=True))
        return e / e.sum(axis=-1, keepdims=True)

    def sum(self, x, axes):
        return x.sum(axis=tuple(axes), keepdims=True)

    def resize(self, x, size, bilinear):
        n, h, w, c = x.shape
        oh, ow = size
        if not bilinear:
            ys = np.minimum(np.floor((np.arange(oh) + 0.5) * h / oh).astype(int), h - 1)
            xs = np.minimum(np.floor((np.arange(ow) + 0.5) * w / ow).astype(int), w - 1)
            return x[:, ys][:, :, xs]
        def axis(o, i):
            s = (np.arange(o) + 0.5) * i / o - 0.5
            s = np.clip(s, 0, None)
            lo = np.minimum(np.floor(s).astype(int), i - 1)
            hi = np.minimum(lo + 1, i - 1)
            return lo, hi, (s - lo).astype(np.float32)
        y0, y1, fy = axis(oh, h); x0, x1, fx = axis(ow, w)
        top = x[:, y0] * (1 - fy)[None, :, None, None] + x[:, y1] * fy[None, :, None, None]
        return top[:, :, x0] * (1 - fx)[None, None, :, None] + top[:, :, x1] * fx[None, None, :, None]

    def relu(self, x, six):
        return np.clip(x, 0, 6 if six else None)


class MILBackend:
    """Core ML ops; tensors stay NHWC, transposed around the ops that need NCHW."""

    def __init__(self, mb):
        self.mb = mb

    def const(self, c):
        return c.astype(np.float32)

    def nchw(self, x):
        return self.mb.transpose(x=x, perm=[0, 3, 1, 2])

    def nhwc(self, x):
        return self.mb.transpose(x=x, perm=[0, 2, 3, 1])

    def conv(self, x, w, b, sh, sw, d, same, groups):
        mb = self.mb
        h, wd = x.shape[1], x.shape[2]
        o, kh, kw, ci = w.shape
        if same:
            pt, pb = same_padding(h, kh, sh, d); pl, pr = same_padding(wd, kw, sw, d)
        else:
            pt = pb = pl = pr = 0
        weight = np.transpose(w, (0, 3, 1, 2)).astype(np.float32)  # O, I/groups, kH, kW
        y = mb.conv(x=self.nchw(x), weight=weight, bias=None if b is None else b.astype(np.float32),
                    strides=[sh, sw], pad_type="custom", pad=[pt, pb, pl, pr], dilations=[d, d], groups=groups)
        return self.nhwc(y)

    def transpose_conv(self, x, w, b, sh, sw, out_shape, same):
        mb = self.mb
        h, wd = x.shape[1], x.shape[2]
        o, kh, kw, ci = w.shape
        _, oh, ow, _ = out_shape
        th = max((h - 1) * sh + kh - oh, 0); tw = max((wd - 1) * sw + kw - ow, 0)
        pad = [th // 2, th - th // 2, tw // 2, tw - tw // 2] if same else [0, 0, 0, 0]
        weight = np.transpose(w, (3, 0, 1, 2)).astype(np.float32)  # I, O, kH, kW
        y = mb.conv_transpose(x=self.nchw(x), weight=weight, bias=None if b is None else b.astype(np.float32),
                              strides=[sh, sw], pad_type="custom", pad=pad, output_shape=[1, o, oh, ow])
        return self.nhwc(y)

    def binary(self, name, a, b):
        return self.mb.add(x=a, y=b) if name == "ADD" else self.mb.mul(x=a, y=b)

    def reshape(self, x, shape):
        return self.mb.reshape(x=x, shape=shape)

    def transpose(self, x, perm):
        return self.mb.transpose(x=x, perm=perm)

    def softmax(self, x):
        return self.mb.softmax(x=x, axis=-1)

    def sum(self, x, axes):
        return self.mb.reduce_sum(x=x, axes=axes, keep_dims=True)

    def resize(self, x, size, bilinear):
        mb = self.mb
        h, w = x.shape[1], x.shape[2]
        if bilinear:
            y = mb.resize_bilinear(x=self.nchw(x), target_size_height=size[0], target_size_width=size[1],
                                   sampling_mode="UNALIGN_CORNERS")
        else:
            assert size[0] % h == 0 and size[1] % w == 0
            y = mb.upsample_nearest_neighbor(x=self.nchw(x), scale_factor_height=size[0] // h,
                                             scale_factor_width=size[1] // w)
        return self.nhwc(y)

    def relu(self, x, six):
        return self.mb.relu6(x=x) if six else self.mb.relu(x=x)


# MARK: Building and checking

def build(graph):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 256, 256, 3))], opset_version=ct.target.macOS15)
    def program(image):
        # The TFLite model ends in logits; Atelier wants chances.
        return mb.softmax(x=walk(graph, MILBackend(mb), image), axis=-1, name="segmentation")

    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.TensorType(name="image", shape=(1, 256, 256, 3))],
                       outputs=[ct.TensorType(name="segmentation")])
    model.short_description = ("MediaPipe Multiclass Selfie Segmentation (Google, Apache License 2.0), "
                               "converted for Atelier's Select People. Classes: " + ", ".join(CLASSES))
    model.license = "Apache License 2.0"
    model.author = "Google (MediaPipe); converted by Scripts/models/convert_mediapipe_multiclass.py"
    model.version = SHA256[:12]
    return model


def check(graph, tflite_path, model=None):
    from ai_edge_litert.interpreter import Interpreter
    interp = Interpreter(model_path=tflite_path)
    interp.allocate_tensors()
    i = interp.get_input_details()[0]["index"]; o = interp.get_output_details()[0]["index"]
    rng = np.random.default_rng(1)
    inputs = [rng.random((1, 256, 256, 3), dtype=np.float32)]
    portrait = os.path.join(HERE, "..", "..", "Sources", "AtelierApp", "Help", "images", "look-before-portrait.jpg")
    try:
        from PIL import Image
        image = Image.open(portrait).convert("RGB").resize((256, 256), Image.BILINEAR)
        inputs.append(np.asarray(image, np.float32)[None] / 255)
    except Exception as error:  # Pillow is optional
        print("skipping the real portrait:", error)
    worst = 0.0
    for x in inputs:
        interp.set_tensor(i, x); interp.invoke(); expected = interp.get_tensor(o)
        got = walk(graph, NumpyBackend(), x)
        diff = float(np.abs(got - expected).max())
        agree = float((got.argmax(-1) == expected.argmax(-1)).mean())
        shares = np.bincount(expected.argmax(-1).ravel(), minlength=6) / expected[0, :, :, 0].size
        print(f"NumPy graph vs TFLite: max diff {diff:.2e}, same class {agree:.4%}; TFLite class shares "
              + ", ".join(f"{n} {v:.3f}" for n, v in zip(CLASSES, shares)))
        worst = max(worst, diff)
        if model is not None and sys.platform == "darwin":
            ml = model.predict({"image": x})["segmentation"]
            expected = np.exp(expected - expected.max(-1, keepdims=True)); expected /= expected.sum(-1, keepdims=True)
            print(f"Core ML vs TFLite: max diff {np.abs(ml - expected).max():.2e}, "
                  f"same class {(ml.argmax(-1) == expected.argmax(-1)).mean():.4%}")
    return worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="compare with Google's TFLite runtime")
    parser.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "atelier-models"))
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()
    path = download(args.cache)
    graph = Graph(path)
    model = build(graph)
    if os.path.exists(args.out):
        import shutil
        shutil.rmtree(args.out)
    model.save(args.out)
    print("saved", os.path.normpath(args.out))
    if args.check:
        worst = check(graph, path, model)
        if worst > 1e-3:
            sys.exit("the translated graph does not match TFLite")


if __name__ == "__main__":
    main()
