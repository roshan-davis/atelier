#!/usr/bin/env python3
"""How much memory one ONNX model run needs under each ONNX Runtime setting (AT-077).

Atelier's Fine Edges runs BiRefNet with ONNX Runtime's Objective-C API, which can't turn off the
CPU memory arena or memory patterns. On a Z f photo (Mac check 4 of PR #157) the Fast model's run
added about 18 GB to Atelier's memory and Hair Detail about 46 GB, whatever session options were
set. This script runs the same model files with ONNX Runtime's Python package, one setting per
process, so we can see which setting (arena off, memory patterns off, sequential execution,
Core ML) actually lowers the peak before changing the app.

Usage (on a Mac, in a virtual environment with `pip install onnxruntime==1.24.2 numpy`):

    python3 Scripts/models/onnx_memory_probe.py --model ~/Library/Application\\ Support/Atelier/Models/BiRefNet-lite-....onnx --size 1024
    python3 Scripts/models/onnx_memory_probe.py --model <file> --size 1024 --only arena-off

Each setting runs in a fresh child process; the peak is the child's maximum resident size
(`ru_maxrss`), which on macOS is in bytes. The input is random (memory doesn't depend on the
picture), so no photo is needed.
"""

import argparse
import json
import resource
import subprocess
import sys
import time

SETTINGS = {
    "default": {},
    "arena-off": {"arena": False},
    "mempattern-off": {"mem_pattern": False},
    "arena-off+mempattern-off": {"arena": False, "mem_pattern": False},
    "arena-off+mempattern-off+sequential": {"arena": False, "mem_pattern": False, "sequential": True},
    "arena-off+mempattern-off+threads-4": {"arena": False, "mem_pattern": False, "threads": 4},
    "coreml-mlprogram-all": {"coreml": "ALL"},
    "coreml-mlprogram-cpugpu": {"coreml": "CPUAndGPU"},
    "coreml-mlprogram-all+arena-off+mempattern-off": {"coreml": "ALL", "arena": False, "mem_pattern": False},
}


def child(model, size, name):
    import numpy as np
    import onnxruntime as ort

    setting = SETTINGS[name]
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.enable_cpu_mem_arena = setting.get("arena", True)
    options.enable_mem_pattern = setting.get("mem_pattern", True)
    if setting.get("sequential"):
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    if "threads" in setting:
        options.intra_op_num_threads = setting["threads"]
    options.add_session_config_entry("session.use_device_allocator_for_initializers", "1")
    providers = ["CPUExecutionProvider"]
    if "coreml" in setting:
        providers = [("CoreMLExecutionProvider", {"ModelFormat": "MLProgram", "MLComputeUnits": setting["coreml"]}),
                     "CPUExecutionProvider"]
    loaded_at = time.time()
    session = ort.InferenceSession(model, sess_options=options, providers=providers)
    load_seconds = time.time() - loaded_at
    after_load = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    feed = {session.get_inputs()[0].name: np.random.rand(1, 3, size, size).astype(np.float32)}
    times = []
    for _ in range(2):
        started = time.time()
        session.run(None, feed)
        times.append(time.time() - started)
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(json.dumps({
        "setting": name, "providers": session.get_providers(), "load_s": round(load_seconds, 1),
        "peak_after_load_mb": after_load // 1_048_576, "peak_mb": peak // 1_048_576,
        "run_s": [round(t, 1) for t in times],
    }))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--size", type=int, required=True, help="the model's square input (1024 Fast, 2048 Hair Detail)")
    parser.add_argument("--only", choices=sorted(SETTINGS), help="run one setting")
    parser.add_argument("--child", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.child:
        child(args.model, args.size, args.child)
        return
    for name in ([args.only] if args.only else SETTINGS):
        result = subprocess.run([sys.executable, __file__, "--model", args.model, "--size", str(args.size), "--child", name],
                                capture_output=True, text=True)
        lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
        if result.returncode != 0 or not lines:
            print(f"PROBE {name}: failed (exit {result.returncode}): {result.stderr.strip().splitlines()[-3:]}")
        else:
            print(f"PROBE {lines[-1]}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
