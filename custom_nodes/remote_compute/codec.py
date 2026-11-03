"""Serialize node values (tensors, audio, video, plain data) to bytes for the trip between machines.

Container: b"RCV1", u32 header length, JSON header, then the binary blobs the header points at. Tensors keep
their dtype and shape. Image-like float tensors are sent as uint8 when that is lossless (images loaded from
8-bit files are exact multiples of 1/255), or when the caller asks for 8-bit (long frame sequences headed for
an 8-bit video encoder); everything else goes as raw float bytes.

The frames of an 8-bit video value (on its way to SaveVideo, which encodes it to H.264 again anyway) go as
H.264 in RGB at high quality: about 1/7 the size of the 8-bit frames, which matters on a slow link, at an
average error under 1 of 255. REMOTE_COMPUTE_LOSSLESS_VIDEO=1 sends them as 8-bit frames instead.
"""

import io
import json
import os
import struct
import zlib
from fractions import Fraction

import numpy as np
import torch

MAGIC = b"RCV1"
LOSSLESS_VIDEO = os.environ.get("REMOTE_COMPUTE_LOSSLESS_VIDEO", "") not in ("", "0")
VIDEO_CRF = 10  # libx264rgb; 45.8 dB PSNR on an H3 clip, 10.7 MB for 124 frames at 512x672

# uint8 modes: "div" decodes u / 255 (exact for 8-bit sources), "trunc" decodes (u + 0.25) / 255 so that the
# consumer's own 8-bit conversion, (x * 255) truncated or rounded, lands back on u.
U8_DIV, U8_TRUNC = "div", "trunc"


class _Writer:
    def __init__(self, eight_bit=False):
        self.blobs, self.offset, self.eight_bit = [], 0, eight_bit

    def blob(self, data, compress=False):
        if compress:
            data = zlib.compress(data, 1)
        ref = {"o": self.offset, "n": len(data), "z": compress}
        self.blobs.append(data)
        self.offset += len(data)
        return ref

    def tensor(self, t, eight_bit=None):
        eight_bit = self.eight_bit if eight_bit is None else eight_bit
        t = t.detach().cpu()
        out = {"$": "tensor", "dtype": str(t.dtype).removeprefix("torch."), "shape": list(t.shape)}
        if t.is_floating_point() and t.numel() > 0:
            f = t.float()
            scaled = f * 255
            if f.min() >= 0 and f.max() <= 1 and torch.equal(scaled, scaled.round()):
                out["u8"] = U8_DIV
                out["data"] = self.blob(scaled.round().to(torch.uint8).numpy().tobytes(), compress=True)
                return out
            if eight_bit:
                out["u8"] = U8_TRUNC
                out["data"] = self.blob(scaled.clamp(0, 255).to(torch.uint8).numpy().tobytes(), compress=True)
                return out
        if t.dtype == torch.bfloat16:  # numpy has no bfloat16: ship the raw bits
            out["data"] = self.blob(t.view(torch.int16).contiguous().numpy().tobytes())
        else:
            out["data"] = self.blob(t.contiguous().numpy().tobytes(), compress=t.dtype in (torch.uint8, torch.bool))
        return out

    def video_frames(self, t):
        """8-bit video frames [N, H, W, 3] as H.264 in RGB (no color conversion); others as tensor(eight_bit)."""
        t = t.detach().cpu()
        if LOSSLESS_VIDEO or t.ndim != 4 or t.shape[-1] != 3 or t.shape[0] < 2 or not t.is_floating_point():
            return self.tensor(t, eight_bit=True)
        try:
            import av
        except ImportError:
            return self.tensor(t, eight_bit=True)
        frames = (t.float() * 255).round().clamp(0, 255).to(torch.uint8).numpy()
        buf = io.BytesIO()
        with av.open(buf, "w", format="matroska") as c:
            s = c.add_stream("libx264rgb", rate=24)
            s.width, s.height, s.pix_fmt = frames.shape[2], frames.shape[1], "rgb24"
            s.options = {"crf": str(VIDEO_CRF), "preset": "veryfast"}
            for a in frames:
                c.mux(s.encode(av.VideoFrame.from_ndarray(a, format="rgb24")))
            c.mux(s.encode())
        return {"$": "h264", "dtype": str(t.dtype).removeprefix("torch."), "shape": list(t.shape),
                "data": self.blob(buf.getvalue())}

    def value(self, v):
        from comfy_api.latest import Input

        if isinstance(v, torch.Tensor):
            return self.tensor(v)
        if isinstance(v, Input.Video):
            c = v.get_components()
            depth = v.get_bit_depth() if hasattr(v, "get_bit_depth") else 8
            return {"$": "video", "images": self.video_frames(c.images) if depth == 8 else self.tensor(c.images, eight_bit=False), "audio": self.value(c.audio), "frame_rate": self.value(c.frame_rate),
                    "metadata": self.value(c.metadata), "alpha": self.value(c.alpha), "bit_depth": depth,
                    "color_space": v.get_color_space() if hasattr(v, "get_color_space") else "sRGB"}
        if isinstance(v, Fraction):
            return {"$": "fraction", "n": v.numerator, "d": v.denominator}
        if isinstance(v, dict):
            return {"$": "dict", "items": [[k, self.value(x)] for k, x in v.items()]}
        if isinstance(v, (list, tuple)):
            return {"$": "list" if isinstance(v, list) else "tuple", "items": [self.value(x) for x in v]}
        if v is None or isinstance(v, (bool, int, float, str)):
            return {"$": "json", "v": v}
        if isinstance(v, np.ndarray):
            return self.tensor(torch.from_numpy(v))
        raise TypeError(f"remote_compute cannot transfer a value of type {type(v).__module__}.{type(v).__name__}")


def encode(value, eight_bit=False):
    w = _Writer(eight_bit=eight_bit)
    header = json.dumps(w.value(value)).encode()
    out = io.BytesIO()
    out.write(MAGIC + struct.pack(">I", len(header)) + header)
    for b in w.blobs:
        out.write(b)
    return out.getvalue()


def decode(data, device="cpu"):
    from comfy_api.latest import InputImpl, Types

    if data[:4] != MAGIC:
        raise ValueError("not a remote_compute value")
    n = struct.unpack(">I", data[4:8])[0]
    header, base = json.loads(data[8:8 + n]), 8 + n

    def blob(ref):
        b = data[base + ref["o"]:base + ref["o"] + ref["n"]]
        return zlib.decompress(b) if ref["z"] else b

    def tensor(d):
        dtype = getattr(torch, d["dtype"])
        if d["$"] == "h264":
            import av
            with av.open(io.BytesIO(blob(d["data"]))) as c:
                frames = np.stack([f.to_ndarray(format="rgb24") for f in c.decode(video=0)])
            if list(frames.shape) != d["shape"]:
                raise ValueError(f"video frames decoded as {list(frames.shape)}, expected {d['shape']}")
            return (torch.from_numpy(frames).float() / 255).to(dtype).to(device)
        if "u8" in d:
            u = torch.frombuffer(bytearray(blob(d["data"])), dtype=torch.uint8).reshape(d["shape"]).float()
            t = u / 255 if d["u8"] == U8_DIV else (u + 0.25) / 255
            return t.to(dtype).to(device)
        if dtype == torch.bfloat16:
            return torch.frombuffer(bytearray(blob(d["data"])), dtype=torch.int16).view(torch.bfloat16).reshape(d["shape"]).to(device)
        if 0 in d["shape"]:
            return torch.zeros(d["shape"], dtype=dtype, device=device)
        return torch.frombuffer(bytearray(blob(d["data"])), dtype=dtype).reshape(d["shape"]).to(device)

    def value(d):
        kind = d["$"]
        if kind == "tensor":
            return tensor(d)
        if kind == "json":
            return d["v"]
        if kind == "fraction":
            return Fraction(d["n"], d["d"])
        if kind == "dict":
            return {k: value(x) for k, x in d["items"]}
        if kind == "list":
            return [value(x) for x in d["items"]]
        if kind == "tuple":
            return tuple(value(x) for x in d["items"])
        if kind == "video":
            comps = Types.VideoComponents(images=tensor(d["images"]), audio=value(d["audio"]), frame_rate=value(d["frame_rate"]),
                                          metadata=value(d["metadata"]), alpha=value(d["alpha"]))
            return InputImpl.VideoFromComponents(comps, bit_depth=d["bit_depth"], color_space=d["color_space"])
        raise ValueError(f"unknown remote_compute value kind {kind!r}")

    return value(header)
