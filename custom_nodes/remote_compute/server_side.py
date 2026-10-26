"""Compute-server half: hold job inputs and results in RAM only, and the two nodes that use them.

A client uploads each input value (an image a local LoadImage read, say) to /remote_compute/value/{fingerprint},
then queues a normal prompt in which RemoteComputeValue nodes stand in for those values and RemoteComputeCapture
nodes collect whatever the client's local save/preview nodes need. The client fetches the results once from
/remote_compute/results/{job} and calls /remote_compute/cleanup, which also drops the job's history entry.
Nothing touches the disk. Anything left behind by a client that went away expires after STORE_TTL seconds.
"""

import logging
import threading
import time

from aiohttp import web

from server import PromptServer

from . import codec

STORE_TTL = 30 * 60
STORE_LIMIT = 8 * 1024**3  # bytes across inputs and results

_lock = threading.Lock()
_values = {}   # fingerprint -> [bytes or bytearray (while uploading), last_used]
_results = {}  # job -> {key: bytes}, plus "_t": created
_used = 0


def _sweep():
    global _used
    now = time.time()
    for fp in [fp for fp, (_, t) in _values.items() if now - t > STORE_TTL]:
        _used -= len(_values.pop(fp)[0])
    for job in [j for j, r in _results.items() if now - r["_t"] > STORE_TTL]:
        _used -= sum(len(v) for k, v in _results.pop(job).items() if k != "_t")


def _reserve(n):
    global _used
    if _used + n > STORE_LIMIT:
        _sweep()
    if _used + n > STORE_LIMIT:
        raise web.HTTPInsufficientStorage(text=f"remote_compute store is full ({_used >> 20} MB held)")
    _used += n


routes = PromptServer.instance.routes


@routes.put("/remote_compute/value/{fp}")
async def put_value(request):
    """Upload one encoded value. ?part=N appends (N > 0) so large values fit under --max-upload-size."""
    global _used
    fp, part = request.match_info["fp"], int(request.query.get("part", 0))
    data = await request.read()
    with _lock:
        _reserve(len(data))
        if part == 0 or fp not in _values:
            if fp in _values:
                _used -= len(_values[fp][0])
            _values[fp] = [bytearray(data), time.time()]
        else:
            _values[fp][0].extend(data)
            _values[fp][1] = time.time()
    return web.json_response({"ok": True})


@routes.get("/remote_compute/value/{fp}")
async def has_value(request):
    with _lock:
        return web.json_response({"present": request.match_info["fp"] in _values})


@routes.get("/remote_compute/results/{job}")
async def get_results(request):
    with _lock:
        res = _results.get(request.match_info["job"])
        if res is None:
            raise web.HTTPNotFound(text="no results for this job")
        items = {k: v for k, v in res.items() if k != "_t"}
    # u32 count, then per key: u32 length + key, u64 length + encoded value
    out = bytearray(len(items).to_bytes(4, "big"))
    for k, v in items.items():
        kb = k.encode()
        out += len(kb).to_bytes(4, "big") + kb + len(v).to_bytes(8, "big") + v
    return web.Response(body=bytes(out), content_type="application/octet-stream")


@routes.post("/remote_compute/cleanup")
async def cleanup(request):
    """Drop a job's results, the input values it used, and its history entry."""
    global _used
    d = await request.json()
    with _lock:
        res = _results.pop(d.get("job"), None)
        if res:
            _used -= sum(len(v) for k, v in res.items() if k != "_t")
        for fp in d.get("fingerprints", []):
            if fp in _values:
                _used -= len(_values.pop(fp)[0])
    if d.get("prompt_id"):
        PromptServer.instance.prompt_queue.delete_history_item(d["prompt_id"])
    return web.json_response({"ok": True})


class RemoteComputeValue:
    """Stands in for a value computed on the client (e.g. a loaded image). Internal to remote_compute."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"fingerprint": ("STRING", {"default": ""})}}

    RETURN_TYPES = ("*",)
    FUNCTION = "load"
    CATEGORY = "remote_compute/internal"

    def load(self, fingerprint):
        with _lock:
            entry = _values.get(fingerprint)
            if entry is None:
                raise RuntimeError(f"remote_compute: input value {fingerprint[:12]} was not uploaded (or expired)")
            entry[1] = time.time()
            data = bytes(entry[0])
        import comfy.model_management
        return (codec.decode(data, device=comfy.model_management.intermediate_device()),)


class RemoteComputeCapture:
    """Keeps a value in RAM for the client to fetch. `job` changes per run, so this always executes."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"value": ("*",), "job": ("STRING", {"default": ""}), "key": ("STRING", {"default": ""}),
                             "eight_bit": ("BOOLEAN", {"default": False})}}

    RETURN_TYPES = ()
    FUNCTION = "capture"
    OUTPUT_NODE = True
    CATEGORY = "remote_compute/internal"

    def capture(self, value, job, key, eight_bit):
        data = codec.encode(value, eight_bit=eight_bit)
        with _lock:
            _reserve(len(data))
            _results.setdefault(job, {"_t": time.time()})[key] = data
        return {}


NODE_CLASS_MAPPINGS = {"RemoteComputeValue": RemoteComputeValue, "RemoteComputeCapture": RemoteComputeCapture}
NODE_DISPLAY_NAME_MAPPINGS = {"RemoteComputeValue": "Remote value (internal)", "RemoteComputeCapture": "Remote capture (internal)"}
logging.info("remote_compute: compute-server routes ready (inputs and results are kept in RAM only)")
