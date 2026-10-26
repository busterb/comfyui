"""Compute in bf16 instead of fp32 when ComfyUI runs on a CPU with native bf16 instructions.

ComfyUI never picks bf16 on the CPU ("bf16 works on CPU but is extremely slow"), which holds for
CPUs that emulate it. With AVX512_BF16 (Zen 4+, Cooper Lake+) or AMX, bf16 matmuls run about 2x
faster than fp32 and the weights take half the memory. This only changes the CPU branch of
model_management.should_use_bf16; GPU devices keep ComfyUI's own choice.
"""

import comfy.model_management as mm


def cpu_has_bf16():
    try:
        with open("/proc/cpuinfo") as f:
            flags = next(line for line in f if line.startswith("flags")).split()
    except (OSError, StopIteration):
        return False
    return "avx512_bf16" in flags or "amx_bf16" in flags


if cpu_has_bf16():
    _should_use_bf16 = mm.should_use_bf16

    def should_use_bf16(device=None, model_params=0, prioritize_performance=True, manual_cast=False):
        if (device is not None and mm.is_device_cpu(device)) or (device is None and mm.cpu_mode()):
            return True
        return _should_use_bf16(device, model_params, prioritize_performance, manual_cast)

    mm.should_use_bf16 = should_use_bf16

NODE_CLASS_MAPPINGS = {}
