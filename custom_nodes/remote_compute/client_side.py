"""Client half: run the browser's jobs on the compute server at COMFYUI_REMOTE_URL, keep files local.

- /object_info and the model-list routes come from the compute server, so workflows see its nodes and models, and
  "Download missing models to server" downloads onto it.
  Nodes that run here (file loaders, save/preview nodes, this pack's own) keep their local definitions.
- Each queued prompt is split (see split.py): local loaders run here, their outputs are uploaded to the server's
  RAM, the rest runs there, and the results come back into the local save/preview nodes. Progress, node
  highlighting and latent previews are relayed from the server with the local prompt id.
"""

import asyncio
import hashlib
import json
import logging
import os
import time
import urllib.request
import uuid

import aiohttp
from aiohttp import web

import comfy.model_management
import nodes
from server import PromptServer

from . import codec, split

REMOTE_URL = os.environ.get("COMFYUI_REMOTE_URL", "").rstrip("/")
UPLOAD_PART = 64 * 1024**2  # stays under the server's default 100 MB --max-upload-size
PREVIEW_IMAGE, PREVIEW_IMAGE_WITH_METADATA = 1, 4
RELAYED_EVENTS = {"executing", "progress", "progress_state", "execution_cached"}
REMOTE_MODEL_ROUTES = ("/models", "/experiment/models", "/embeddings")
# Routes forwarded with any method: "Download missing models to server" should fetch onto the compute server
REMOTE_ROUTES = ("/server_models/",)

server = PromptServer.instance
_object_info = {"t": 0.0, "info": None}


def _remote_object_info_sync(max_age=300):
    """The server's /object_info, cached; fetched synchronously when on_prompt needs it and the cache is stale."""
    if _object_info["info"] is None or time.time() - _object_info["t"] > max_age:
        with urllib.request.urlopen(REMOTE_URL + "/object_info", timeout=10) as r:
            _object_info.update(info=json.load(r), t=time.time())
    return _object_info["info"]


def _is_local_output(class_type):
    cls = nodes.NODE_CLASS_MAPPINGS.get(class_type)
    return cls is not None and getattr(cls, "OUTPUT_NODE", False) is True and not class_type.startswith("RemoteCompute")


def _runs_locally(class_type):
    return class_type in split.SOURCE_CLASSES or _is_local_output(class_type) or class_type.startswith("RemoteCompute")


# --- node definitions and model lists from the compute server ---------------------------------------------

@web.middleware
async def remote_definitions(request, handler):
    path = request.path.removeprefix("/api")
    if path.startswith(REMOTE_ROUTES) or (request.method == "GET" and path.startswith(REMOTE_MODEL_ROUTES)):
        headers = {"Content-Type": request.headers["Content-Type"]} if "Content-Type" in request.headers else {}
        async with aiohttp.ClientSession() as s, s.request(request.method, REMOTE_URL + request.path_qs,
                                                           data=await request.read(), headers=headers) as r:
            return web.Response(body=await r.read(), status=r.status, content_type=r.content_type)
    if request.method != "GET" or not path.startswith("/object_info"):
        return await handler(request)
    response = await handler(request)
    try:
        local = json.loads(response.body)
        async with aiohttp.ClientSession() as s, s.get(REMOTE_URL + path, timeout=aiohttp.ClientTimeout(total=30)) as r:
            remote = await r.json()
    except Exception as e:
        logging.warning(f"remote_compute: using local node definitions, compute server unreachable ({e})")
        return response
    if path == "/object_info":
        _object_info.update(info=remote, t=time.time())
    merged = dict(remote)
    merged.update({k: v for k, v in local.items() if k not in remote or _runs_locally(k)})
    return web.json_response(merged)


# --- prompt rewriting ------------------------------------------------------------------------------------

def rewrite_prompt(json_data):
    prompt = json_data.get("prompt")
    if not isinstance(prompt, dict):
        return json_data
    try:
        info = _remote_object_info_sync()
        local, spec = split.split(prompt, _is_local_output, lambda c: bool(info.get(c, {}).get("output_node")),
                                  json_data.get("partial_execution_targets"))
    except Exception as e:
        logging.error(f"remote_compute: can't run this prompt on {REMOTE_URL}: {e}")
        json_data["prompt"] = {"remote_compute_error": {"class_type": "RemoteComputeError", "inputs": {"message": str(e)}}}
        json_data.pop("partial_execution_targets", None)
        return json_data
    if spec is not None:
        json_data["prompt"] = local
        if json_data.get("partial_execution_targets") is not None:
            json_data["partial_execution_targets"] = list(json_data["partial_execution_targets"]) + [split.EXEC_ID]
        logging.info(f"remote_compute: {len(spec['remote_ids'])} nodes run on {REMOTE_URL}, "
                     f"{len(local) - len(spec['captures']) - 1} here; {len(spec['inputs'])} values up, {len(spec['captures'])} back")
    return json_data


# --- relaying the server's progress to the browser ------------------------------------------------------

def _retag(obj, remote_pid, local_pid):
    if isinstance(obj, dict):
        return {k: (local_pid if k == "prompt_id" and v == remote_pid else _retag(v, remote_pid, local_pid)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_retag(v, remote_pid, local_pid) for v in obj]
    return obj


def _relay_bytes(event, payload, sid):
    asyncio.run_coroutine_threadsafe(server.send_bytes(event, payload, sid), server.loop)


def _relay_binary(data, remote_pid, local_pid, sid):
    event = int.from_bytes(data[:4], "big")
    payload = data[4:]
    if event == PREVIEW_IMAGE:
        _relay_bytes(event, payload, sid)
    elif event == PREVIEW_IMAGE_WITH_METADATA:
        n = int.from_bytes(payload[:4], "big")
        meta = json.dumps(_retag(json.loads(payload[4:4 + n]), remote_pid, local_pid)).encode()
        _relay_bytes(event, len(meta).to_bytes(4, "big") + meta + payload[4 + n:], sid)


# --- nodes -----------------------------------------------------------------------------------------------

def _decode_results(body):
    out, i = {}, 4
    for _ in range(int.from_bytes(body[:4], "big")):
        n = int.from_bytes(body[i:i + 4], "big"); key = body[i + 4:i + 4 + n].decode(); i += 4 + n
        n = int.from_bytes(body[i:i + 8], "big"); out[key] = codec.decode(body[i + 8:i + 8 + n]); i += 8 + n
    return out


class RemoteComputeExecute:
    """Runs the remote part of a split prompt on the compute server. Added by remote_compute, not by hand."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"spec": ("STRING", {"default": "{}"})},
                "optional": {f"in_{i}": ("*",) for i in range(64)}}

    RETURN_TYPES = ("REMOTE_COMPUTE_RESULTS",)
    FUNCTION = "run"
    OUTPUT_NODE = True
    CATEGORY = "remote_compute/internal"

    async def run(self, spec, **inputs):
        spec = json.loads(spec)
        local_pid, sid = server.last_prompt_id, server.client_id
        job = uuid.uuid4().hex
        client_id = f"remote_compute-{job}"
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=10)
        fingerprints, remote_pid = [], None
        async with aiohttp.ClientSession(timeout=timeout) as s:
            try:
                # 1. upload the locally computed values the remote part reads
                prompt_json = json.dumps(spec["prompt"])
                for i in range(len(spec["inputs"])):
                    data = codec.encode(inputs[f"in_{i}"])
                    fp = hashlib.sha256(data).hexdigest()
                    fingerprints.append(fp)
                    async with s.get(f"{REMOTE_URL}/remote_compute/value/{fp}") as r:
                        present = (await r.json())["present"]
                    for part, off in enumerate(range(0, len(data), UPLOAD_PART) if not present else []):
                        async with s.put(f"{REMOTE_URL}/remote_compute/value/{fp}?part={part}", data=data[off:off + UPLOAD_PART]) as r:
                            if r.status != 200:
                                raise RuntimeError(f"upload to compute server failed: HTTP {r.status} {await r.text()}")
                    prompt_json = prompt_json.replace(json.dumps(f"@in_{i}"), json.dumps(fp))
                prompt_json = prompt_json.replace('"@job"', json.dumps(job))

                # 2. queue it and follow the server's websocket until it finishes
                async with s.ws_connect(f"{REMOTE_URL}/ws?clientId={client_id}", max_msg_size=0) as ws:
                    async with s.post(f"{REMOTE_URL}/prompt", json={"prompt": json.loads(prompt_json), "client_id": client_id}) as r:
                        res = await r.json()
                    if r.status != 200:
                        raise RuntimeError(f"compute server rejected the prompt: {json.dumps(res.get('error', res))[:500]} "
                                           f"{json.dumps(res.get('node_errors', {}))[:1500]}")
                    remote_pid = res["prompt_id"]
                    await self._follow(ws, s, remote_pid, local_pid, sid)

                # 3. fetch the results (the server forgets them on cleanup)
                async with s.get(f"{REMOTE_URL}/remote_compute/results/{job}") as r:
                    if r.status != 200:
                        raise RuntimeError(f"compute server has no results for this job: HTTP {r.status}")
                    results = _decode_results(await r.read())
            finally:
                try:
                    async with s.post(f"{REMOTE_URL}/remote_compute/cleanup",
                                      json={"job": job, "fingerprints": fingerprints, "prompt_id": remote_pid}) as r:
                        pass
                except Exception as e:
                    logging.warning(f"remote_compute: cleanup on compute server failed: {e}")
        return (results,)

    async def _follow(self, ws, session, remote_pid, local_pid, sid):
        while True:
            if comfy.model_management.processing_interrupted():
                async with session.post(f"{REMOTE_URL}/interrupt", json={"prompt_id": remote_pid}):
                    pass
                comfy.model_management.throw_exception_if_processing_interrupted()
            try:
                msg = await ws.receive(timeout=0.5)
            except asyncio.TimeoutError:
                continue
            if msg.type == aiohttp.WSMsgType.BINARY:
                _relay_binary(msg.data, remote_pid, local_pid, sid)
                continue
            if msg.type != aiohttp.WSMsgType.TEXT:
                raise RuntimeError(f"lost the connection to the compute server ({msg.type.name})")
            m = json.loads(msg.data)
            kind, data = m.get("type"), m.get("data") or {}
            if data.get("prompt_id") not in (None, remote_pid):
                continue
            if kind == "execution_success":
                return
            if kind == "execution_error":
                raise RuntimeError(f"on the compute server, node {data.get('node_id')} ({data.get('node_type')}): "
                                   f"{data.get('exception_message', '').strip()}")
            if kind == "execution_interrupted":
                raise RuntimeError("the job was interrupted on the compute server")
            if kind in RELAYED_EVENTS and sid is not None and not (kind == "executing" and data.get("node") is None):
                server.send_sync(kind, _retag(data, remote_pid, local_pid), sid)


class RemoteComputePick:
    """One value out of RemoteComputeExecute's results."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"results": ("REMOTE_COMPUTE_RESULTS",), "key": ("STRING", {"default": ""})}}

    RETURN_TYPES = ("*",)
    FUNCTION = "pick"
    CATEGORY = "remote_compute/internal"

    def pick(self, results, key):
        return (results[key],)


class RemoteComputeError:
    """Stands in for a prompt that couldn't be split, so the browser shows why instead of running it locally."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"message": ("STRING", {"default": ""})}}

    RETURN_TYPES = ()
    FUNCTION = "fail"
    OUTPUT_NODE = True
    CATEGORY = "remote_compute/internal"

    def fail(self, message):
        raise RuntimeError(f"remote_compute: {message}")


NODE_CLASS_MAPPINGS = {"RemoteComputeExecute": RemoteComputeExecute, "RemoteComputePick": RemoteComputePick,
                       "RemoteComputeError": RemoteComputeError}
NODE_DISPLAY_NAME_MAPPINGS = {"RemoteComputeExecute": "Run on compute server (internal)",
                              "RemoteComputePick": "Remote result (internal)", "RemoteComputeError": "Remote compute error (internal)"}

server.app.middlewares.append(remote_definitions)
server.add_on_prompt_handler(rewrite_prompt)
logging.info(f"remote_compute: jobs run on {REMOTE_URL}; files stay on this machine")
