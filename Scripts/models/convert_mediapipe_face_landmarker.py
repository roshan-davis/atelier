#!/usr/bin/env python3
"""Converts two of the models in Google's MediaPipe Face Landmarker (Apache 2.0) to Core ML.

Cull's Pick By Best Expression and its eyes-closed check use them (AT-059 part 2). The converted
models are checked into Sources/AtelierCore/Models so the app has them without downloading
anything; run this again only to rebuild them.

    python3.11 -m venv /tmp/mpvenv && . /tmp/mpvenv/bin/activate   # 3.11: coremltools 8.3 saves with it on Linux
    pip install "coremltools==8.3.0" tflite "numpy<2.2" ai-edge-litert pillow   # litert, pillow: --check only
    python3 Scripts/models/convert_mediapipe_face_landmarker.py [--check]

face_landmarker.task is a zip of three TFLite models. Atelier finds faces with Vision and, when
Vision misses one, with the task's own face detector inside each person Vision found; all three
are converted, rebuilding each graph op by op with
coremltools' MIL builder (there is no direct TFLite converter), as
convert_mediapipe_multiclass.py does. --check runs the same graphs in NumPy and compares them
with Google's own TFLite runtime on random and real inputs, so the translation is verified even
on Linux, where Core ML can't run. On a Mac the saved models themselves are compared too.

FaceMesh.mlpackage
    Input "image": a face crop, RGB 256 x 256, values 0...1.
    Outputs "landmarks": 1 x 1434, 478 points (x, y, z) in the crop's pixels;
            "face": 1 x 1, the face logit (above 0: more likely a face than not).
FaceBlendshapes.mlpackage
    Input "points": 1 x 146 x 2, the x and y of the 146 landmarks in `SUBSET` (pixels).
    Output "blendshapes": 52 scores 0...1 in the order of `NAMES` (ARKit's names).
FaceDetector.mlpackage (BlazeFace short range, Cull's Find Faces > MediaPipe, Nov 14, 2026)
    Input "image": RGB 128 x 128, values -1...1 (letterboxed).
    Outputs "regressors": 1 x 896 x 16, per anchor the box (center x, y offsets, width, height)
            and six key points, in input pixels; "classificators": 1 x 896 x 1, face logits.
    Anchors: a 16 x 16 grid with 2 per cell, then an 8 x 8 grid with 6 per cell, centered.
"""
import argparse
import hashlib
import os
import sys
import urllib.request
import zipfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from convert_mediapipe_multiclass import Graph, same_padding  # noqa: E402

URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/"
       "float16/latest/face_landmarker.task")
SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
MODELS = os.path.join(HERE, "..", "..", "Sources", "AtelierCore", "Models")

# From mediapipe/tasks/cc/vision/face_landmarker/face_blendshapes_graph.cc.
SUBSET = [0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39, 40, 46, 52, 53, 54, 55, 58, 61, 63, 65, 66, 67,
          70, 78, 80, 81, 82, 84, 87, 88, 91, 93, 95, 103, 105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148,
          149, 150, 152, 153, 154, 155, 157, 158, 159, 160, 161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191,
          195, 197, 234, 246, 249, 251, 263, 267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296, 297,
          300, 308, 310, 311, 312, 314, 317, 318, 321, 323, 324, 332, 334, 336, 338, 356, 361, 362, 365, 373, 374,
          375, 377, 378, 379, 380, 381, 382, 384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415,
          454, 466, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477]
NAMES = ["_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
         "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft",
         "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
         "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight",
         "jawForward", "jawLeft", "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight",
         "mouthFrownLeft", "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft",
         "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight",
         "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft",
         "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
         "noseSneerLeft", "noseSneerRight"]
assert len(SUBSET) == 146 and len(NAMES) == 52


def download(cache):
    path = os.path.join(cache, "face_landmarker.task")
    if not os.path.exists(path):
        os.makedirs(cache, exist_ok=True)
        urllib.request.urlretrieve(URL, path)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != SHA256:
        sys.exit(f"checksum mismatch for {path}: {digest}")
    folder = os.path.join(cache, "face_landmarker")
    zipfile.ZipFile(path).extractall(folder)
    return folder


class Graph2(Graph):
    """Several inputs and outputs, and float16 weights behind DEQUANTIZE."""

    def __init__(self, path):
        super().__init__(path)
        self.inputs = [self.sub.Inputs(i) for i in range(self.sub.InputsLength())]
        self.outputs = [self.sub.Outputs(i) for i in range(self.sub.OutputsLength())]


# MARK: One walk over the graph, two backends

def walk(graph, backend, inputs):
    """Runs every op through `backend`; returns the outputs. Constants stay NumPy arrays (folded),
    so weights reach convolutions as arrays."""
    values = dict(zip(graph.inputs, inputs))

    def get(index):
        if index in values:
            return values[index]
        c = graph.const(index)
        if c is None:
            raise KeyError(index)
        return c.astype(np.float32) if c.dtype in (np.float16, np.float32) else c

    def const(index):
        v = get(index)
        assert isinstance(v, np.ndarray), index
        return v

    def fold(*args):
        return all(isinstance(a, np.ndarray) for a in args)

    for name, ins, outs, op in graph.ops:
        act = 0
        if name == "DEQUANTIZE":
            y = const(ins[0]).astype(np.float32)
        elif name == "CONV_2D":
            o = graph.options(op, "Conv2DOptions")
            b = const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            y = backend.conv(get(ins[0]), const(ins[1]), b, o.StrideH(), o.StrideW(), o.DilationHFactor(),
                             o.Padding() == 0, 1)
            act = o.FusedActivationFunction()
        elif name == "DEPTHWISE_CONV_2D":
            o = graph.options(op, "DepthwiseConv2DOptions")
            assert o.DepthMultiplier() == 1
            w = np.transpose(const(ins[1]), (3, 1, 2, 0))
            b = const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            y = backend.conv(get(ins[0]), w, b, o.StrideH(), o.StrideW(), o.DilationHFactor(),
                             o.Padding() == 0, w.shape[0])
            act = o.FusedActivationFunction()
        elif name in ("ADD", "SUB", "MUL", "DIV", "SQUARED_DIFFERENCE"):
            a, b = get(ins[0]), get(ins[1])
            options = {"ADD": "AddOptions", "SUB": "SubOptions", "MUL": "MulOptions", "DIV": "DivOptions"}
            if name in options:
                act = graph.options(op, options[name]).FusedActivationFunction()
            y = NumpyBackend().binary(name, a, b) if fold(a, b) else backend.binary(name, a, b)
        elif name in ("NEG", "SQRT", "RSQRT", "LOGISTIC"):
            x = get(ins[0])
            y = NumpyBackend().unary(name, x) if fold(x) else backend.unary(name, x)
        elif name == "RELU":
            y = backend.relu(get(ins[0]), six=False)
        elif name == "PRELU":
            y = backend.prelu(get(ins[0]), const(ins[1]))
        elif name == "MAX_POOL_2D":
            o = graph.options(op, "Pool2DOptions")
            y = backend.max_pool(get(ins[0]), o.FilterHeight(), o.FilterWidth(), o.StrideH(), o.StrideW(),
                                 o.Padding() == 0)
            act = o.FusedActivationFunction()
        elif name == "PAD":
            y = backend.pad(get(ins[0]), [[int(a), int(b)] for a, b in const(ins[1])])
        elif name == "RESHAPE":
            x = get(ins[0])
            shape = [int(v) for v in graph.shape(outs[0])]
            y = x.reshape(shape) if fold(x) else backend.reshape(x, shape)
        elif name == "TRANSPOSE":
            x = get(ins[0])
            perm = [int(v) for v in const(ins[1])]
            y = np.transpose(x, perm) if fold(x) else backend.transpose(x, perm)
        elif name in ("MEAN", "SUM"):
            axes = [int(v) for v in np.atleast_1d(const(ins[1]))]
            keep = graph.options(op, "ReducerOptions").KeepDims()
            y = backend.reduce(name, get(ins[0]), axes, keep)
        elif name == "STRIDED_SLICE":
            o = graph.options(op, "StridedSliceOptions")
            assert o.EllipsisMask() == 0 and o.NewAxisMask() == 0
            y = backend.strided_slice(get(ins[0]), [int(v) for v in const(ins[1])], [int(v) for v in const(ins[2])],
                                      [int(v) for v in const(ins[3])], o.BeginMask(), o.EndMask(),
                                      o.ShrinkAxisMask())
        elif name == "CONCATENATION":
            o = graph.options(op, "ConcatenationOptions")
            y = backend.concat([get(i) for i in ins], o.Axis())
            act = o.FusedActivationFunction()
        else:
            raise NotImplementedError(name)
        assert act in (0, 1, 3), (name, act)
        if act:
            y = backend.relu(y, six=act == 3)
        values[outs[0]] = y
    return [values[o] for o in graph.outputs]


def mask_slices(shape, begin, end, strides, begin_mask, end_mask, shrink):
    slices = []
    for axis in range(len(begin)):
        b = None if begin_mask >> axis & 1 else begin[axis]
        e = None if end_mask >> axis & 1 else end[axis]
        if shrink >> axis & 1:
            slices.append(begin[axis])
        else:
            slices.append(slice(b, e, strides[axis]))
    return tuple(slices)


class NumpyBackend:
    """Reference semantics in NHWC, for --check."""

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

    def binary(self, name, a, b):
        if name == "ADD": return a + b
        if name == "SUB": return a - b
        if name == "MUL": return a * b
        if name == "DIV": return a / b
        return (a - b) ** 2

    def unary(self, name, x):
        if name == "NEG": return -x
        if name == "SQRT": return np.sqrt(x)
        if name == "RSQRT": return 1 / np.sqrt(x)
        return 1 / (1 + np.exp(-x))

    def prelu(self, x, alpha):
        return np.where(x >= 0, x, x * alpha)

    def max_pool(self, x, kh, kw, sh, sw, same):
        n, h, w, c = x.shape
        if same:
            pt, pb = same_padding(h, kh, sh); pl, pr = same_padding(w, kw, sw)
        else:
            pt = pb = pl = pr = 0
        xp = np.pad(x, ((0, 0), (pt, pb), (pl, pr), (0, 0)), constant_values=-np.inf)
        oh = (h + pt + pb - kh) // sh + 1; ow = (w + pl + pr - kw) // sw + 1
        out = np.full((n, oh, ow, c), -np.inf, np.float32)
        for i in range(kh):
            for j in range(kw):
                out = np.maximum(out, xp[:, i: i + (oh - 1) * sh + 1: sh, j: j + (ow - 1) * sw + 1: sw, :])
        return out

    def pad(self, x, pads):
        return np.pad(x, pads)

    def reshape(self, x, shape):
        return x.reshape(shape)

    def transpose(self, x, perm):
        return np.transpose(x, perm)

    def reduce(self, name, x, axes, keep):
        f = np.mean if name == "MEAN" else np.sum
        return f(x, axis=tuple(axes), keepdims=keep)

    def strided_slice(self, x, begin, end, strides, begin_mask, end_mask, shrink):
        return x[mask_slices(x.shape, begin, end, strides, begin_mask, end_mask, shrink)]

    def concat(self, xs, axis):
        return np.concatenate(xs, axis=axis)

    def relu(self, x, six):
        return np.clip(x, 0, 6 if six else None)


class MILBackend:
    """Core ML ops; tensors stay NHWC, transposed around the ops that need NCHW."""

    def __init__(self, mb):
        self.mb = mb

    def nchw(self, x):
        return self.mb.transpose(x=x, perm=[0, 3, 1, 2])

    def nhwc(self, x):
        return self.mb.transpose(x=x, perm=[0, 2, 3, 1])

    def conv(self, x, w, b, sh, sw, d, same, groups):
        h, wd = x.shape[1], x.shape[2]
        o, kh, kw, ci = w.shape
        if same:
            pt, pb = same_padding(h, kh, sh, d); pl, pr = same_padding(wd, kw, sw, d)
        else:
            pt = pb = pl = pr = 0
        weight = np.transpose(w, (0, 3, 1, 2)).astype(np.float32)
        y = self.mb.conv(x=self.nchw(x), weight=weight, bias=None if b is None else b.astype(np.float32),
                         strides=[sh, sw], pad_type="custom", pad=[pt, pb, pl, pr], dilations=[d, d], groups=groups)
        return self.nhwc(y)

    def binary(self, name, a, b):
        mb = self.mb
        a = a.astype(np.float32) if isinstance(a, np.ndarray) else a
        b = b.astype(np.float32) if isinstance(b, np.ndarray) else b
        if name == "ADD": return mb.add(x=a, y=b)
        if name == "SUB": return mb.sub(x=a, y=b)
        if name == "MUL": return mb.mul(x=a, y=b)
        if name == "DIV": return mb.real_div(x=a, y=b)
        diff = mb.sub(x=a, y=b)
        return mb.mul(x=diff, y=diff)

    def unary(self, name, x):
        mb = self.mb
        if name == "NEG": return mb.mul(x=x, y=np.float32(-1))
        if name == "SQRT": return mb.sqrt(x=x)
        if name == "RSQRT": return mb.rsqrt(x=x)
        return mb.sigmoid(x=x)

    def prelu(self, x, alpha):
        mb = self.mb
        negative = mb.minimum(x=x, y=np.float32(0))
        return mb.add(x=mb.relu(x=x), y=mb.mul(x=negative, y=alpha.astype(np.float32)))

    def max_pool(self, x, kh, kw, sh, sw, same):
        h, w = x.shape[1], x.shape[2]
        if same:
            pt, pb = same_padding(h, kh, sh); pl, pr = same_padding(w, kw, sw)
        else:
            pt = pb = pl = pr = 0
        y = self.mb.max_pool(x=self.nchw(x), kernel_sizes=[kh, kw], strides=[sh, sw], pad_type="custom",
                             pad=[pt, pb, pl, pr])
        return self.nhwc(y)

    def pad(self, x, pads):
        return self.mb.pad(x=x, pad=np.array([v for pair in pads for v in pair], np.int32), mode="constant")

    def reshape(self, x, shape):
        return self.mb.reshape(x=x, shape=shape)

    def transpose(self, x, perm):
        return self.mb.transpose(x=x, perm=perm)

    def reduce(self, name, x, axes, keep):
        f = self.mb.reduce_mean if name == "MEAN" else self.mb.reduce_sum
        return f(x=x, axes=axes, keep_dims=keep)

    def strided_slice(self, x, begin, end, strides, begin_mask, end_mask, shrink):
        rank = len(begin)
        bits = lambda m: [bool(m >> i & 1) for i in range(rank)]
        return self.mb.slice_by_index(x=x, begin=begin, end=end, stride=strides, begin_mask=bits(begin_mask),
                                      end_mask=bits(end_mask), squeeze_mask=bits(shrink))

    def concat(self, xs, axis):
        xs = [v.astype(np.float32) if isinstance(v, np.ndarray) else v for v in xs]
        return self.mb.concat(values=xs, axis=axis)

    def relu(self, x, six):
        return self.mb.relu6(x=x) if six else self.mb.relu(x=x)


# MARK: Building and checking

def build_mesh(graph):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 256, 256, 3))], opset_version=ct.target.macOS15)
    def program(image):
        landmarks, face, _ = walk(graph, MILBackend(mb), [image])
        return (mb.reshape(x=landmarks, shape=[1, 1434], name="landmarks"),
                mb.reshape(x=face, shape=[1, 1], name="face"))

    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.TensorType(name="image", shape=(1, 256, 256, 3))],
                       outputs=[ct.TensorType(name="landmarks"), ct.TensorType(name="face")])
    return describe(model, "MediaPipe Face Mesh V2: 478 face landmarks in a 256 px face crop")


def build_blendshapes(graph):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 146, 2))], opset_version=ct.target.macOS15)
    def program(points):
        (scores,) = walk(graph, MILBackend(mb), [points])
        return mb.reshape(x=scores, shape=[52], name="blendshapes")

    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT32,
                       inputs=[ct.TensorType(name="points", shape=(1, 146, 2))],
                       outputs=[ct.TensorType(name="blendshapes")])
    return describe(model, "MediaPipe Blendshape V2: 52 expression scores (" + ", ".join(NAMES) + ")")


def build_detector(graph):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 128, 128, 3))], opset_version=ct.target.macOS15)
    def program(image):
        regressors, classificators = walk(graph, MILBackend(mb), [image])
        return (mb.identity(x=regressors, name="regressors"), mb.identity(x=classificators, name="classificators"))

    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.TensorType(name="image", shape=(1, 128, 128, 3))],
                       outputs=[ct.TensorType(name="regressors"), ct.TensorType(name="classificators")])
    return describe(model, "MediaPipe BlazeFace (short range): face boxes in a 128 px image")


def describe(model, text):
    model.short_description = text + ". Google, Apache License 2.0; converted for Atelier's Cull."
    model.license = "Apache License 2.0"
    model.author = "Google (MediaPipe Face Landmarker); converted by Scripts/models/convert_mediapipe_face_landmarker.py"
    model.version = SHA256[:12]
    return model


def interpreter(path):
    from ai_edge_litert.interpreter import Interpreter
    interp = Interpreter(model_path=path)
    interp.allocate_tensors()
    return interp


def run_tflite(interp, xs):
    for detail, x in zip(interp.get_input_details(), xs):
        interp.set_tensor(detail["index"], x)
    interp.invoke()
    return [interp.get_tensor(d["index"]) for d in interp.get_output_details()]


def portrait():
    path = os.path.join(HERE, "..", "..", "Sources", "AtelierApp", "Help", "images", "look-before-portrait.jpg")
    try:
        from PIL import Image
        return Image.open(path).convert("RGB")
    except Exception as error:  # Pillow is optional
        print("skipping the real portrait:", error)
        return None


def check_detector(folder, detector, model=None):
    tf = interpreter(os.path.join(folder, "face_detector.tflite"))
    rng = np.random.default_rng(2)
    images = [rng.random((1, 128, 128, 3), dtype=np.float32) * 2 - 1]
    image = portrait()
    if image is not None:
        images.append(np.asarray(image.resize((128, 128)), np.float32)[None] / 127.5 - 1)
    worst = 0.0
    for x in images:
        expected = run_tflite(tf, [x])
        got = walk(detector, NumpyBackend(), [x])
        for name, e, g in zip(("regressors", "classificators"), expected, got):
            diff = float(np.abs(e - g).max())
            print(f"Face detector {name}: NumPy vs TFLite max diff {diff:.2e}")
            worst = max(worst, diff / max(1.0, float(np.abs(e).max())))
        print(f"  best face logit {float(expected[1].max()):.2f}")
        if sys.platform == "darwin" and model is not None:
            out = model.predict({"image": x})
            print(f"Core ML detector vs TFLite: max logit diff "
                  f"{np.abs(out['classificators'].ravel() - expected[1].ravel()).max():.2e}")
    return worst


def check(folder, mesh, blend, mesh_model=None, blend_model=None):
    worst = 0.0
    mesh_tf = interpreter(os.path.join(folder, "face_landmarks_detector.tflite"))
    blend_tf = interpreter(os.path.join(folder, "face_blendshapes.tflite"))
    rng = np.random.default_rng(1)
    crops = [rng.random((1, 256, 256, 3), dtype=np.float32)]
    image = portrait()
    if image is not None:
        crops.append(np.asarray(image.resize((256, 256)), np.float32)[None] / 255)
    order = [d["name"] for d in mesh_tf.get_output_details()]
    for crop in crops:
        expected = run_tflite(mesh_tf, [crop])
        by_name = dict(zip(order, expected))
        got = walk(mesh, NumpyBackend(), [crop])
        names = [mesh.sub.Tensors(o).Name().decode() for o in mesh.outputs]
        for name, value in zip(names, got):
            diff = float(np.abs(value - by_name[name]).max())
            print(f"Face mesh {name}: NumPy vs TFLite max diff {diff:.2e}")
            worst = max(worst, diff / max(1.0, float(np.abs(by_name[name]).max())))
        landmarks = by_name[names[0]].reshape(478, 3)
        print(f"  face score {float(by_name[names[1]].ravel()[0]):.3f}, landmark x range "
              f"{landmarks[:, 0].min():.1f}...{landmarks[:, 0].max():.1f}")
        points = landmarks[SUBSET, :2][None].astype(np.float32)
        (scores,) = run_tflite(blend_tf, [points])
        (mine,) = walk(blend, NumpyBackend(), [points])
        diff = float(np.abs(mine - scores).max())
        print(f"Blendshapes: NumPy vs TFLite max diff {diff:.2e}; blink L/R {scores[9]:.2f}/{scores[10]:.2f}, "
              f"smile L/R {scores[44]:.2f}/{scores[45]:.2f}")
        worst = max(worst, diff)
        if sys.platform == "darwin" and mesh_model is not None:
            out = mesh_model.predict({"image": crop})
            print(f"Core ML mesh vs TFLite: max diff {np.abs(out['landmarks'].ravel() - landmarks.ravel()).max():.2e} px")
            b = blend_model.predict({"points": points})["blendshapes"]
            print(f"Core ML blendshapes vs TFLite: max diff {np.abs(b.ravel() - scores.ravel()).max():.2e}")
    return worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="compare with Google's TFLite runtime")
    parser.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "atelier-models"))
    parser.add_argument("--out", default=MODELS)
    args = parser.parse_args()
    folder = download(args.cache)
    mesh = Graph2(os.path.join(folder, "face_landmarks_detector.tflite"))
    blend = Graph2(os.path.join(folder, "face_blendshapes.tflite"))
    detector = Graph2(os.path.join(folder, "face_detector.tflite"))
    models = {"FaceMesh": build_mesh(mesh), "FaceBlendshapes": build_blendshapes(blend),
              "FaceDetector": build_detector(detector)}
    for name, model in models.items():
        path = os.path.join(args.out, name + ".mlpackage")
        if os.path.exists(path):
            import shutil
            shutil.rmtree(path)
        model.save(path)
        print("saved", os.path.normpath(path))
    if args.check:
        worst = check(folder, mesh, blend, models["FaceMesh"], models["FaceBlendshapes"])
        worst = max(worst, check_detector(folder, detector, models["FaceDetector"]))
        if worst > 2e-3:
            sys.exit("the translated graphs do not match TFLite")


if __name__ == "__main__":
    main()
