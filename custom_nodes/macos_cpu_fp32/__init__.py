"""On Apple Silicon, compute CPU-side models in fp32 and dequantize int8 weights instead of using int8 matmuls.

Apple CPUs only reach full matmul speed in fp32 (through Accelerate): on an M5 Pro, fp32 runs at ~1.4 TFLOPS
while fp16, bf16 and int8 (torch._int_mm) fall back to reference kernels at ~0.002 TFLOPS or less. ComfyUI
defaults CPU text encoders to fp16 and treats the CPU as int8-capable, so a text encoder placed on the CPU (for
example MiniMax H3's 32B Qwen3-VL, too big to share unified memory with the diffusion model) would take hours.
This only changes the CPU branches of model_management.text_encoder_dtype and supports_int8_compute; MPS keeps
ComfyUI's own choices.
"""

import platform

import comfy.model_management as mm
import torch


def _is_cpu(device):
    return (device is not None and mm.is_device_cpu(device)) or (device is None and mm.cpu_mode())


if platform.system() == "Darwin" and platform.machine() == "arm64":
    _text_encoder_dtype = mm.text_encoder_dtype
    _supports_int8_compute = mm.supports_int8_compute

    def text_encoder_dtype(device=None):
        dtype = _text_encoder_dtype(device)
        return torch.float32 if _is_cpu(device) and dtype == torch.float16 else dtype

    def supports_int8_compute(device=None):
        return False if _is_cpu(device) else _supports_int8_compute(device)

    mm.text_encoder_dtype = text_encoder_dtype
    mm.supports_int8_compute = supports_int8_compute

NODE_CLASS_MAPPINGS = {}
