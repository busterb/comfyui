"""Client half: run the browser's jobs on the compute servers in COMFYUI_REMOTE_URL, keep files local.

- COMFYUI_REMOTE_URL is one server's URL, or several separated by commas, most preferred first.
- /object_info and the model-list routes come from the first server, so workflows see its nodes and models, and
  "Download missing models to server" downloads onto it. The others should have the same nodes and models.
  Nodes that run here (file loaders, save/preview nodes, this pack's own) keep their local definitions.
- Each queued prompt is split (see split.py): local loaders run here, their outputs are uploaded to a server's
  RAM, the rest runs there, and the results come back into the local save/preview nodes. Progress, node
  highlighting and latent previews are relayed from the server with the local prompt id.
- With several servers, as many prompts run here at once, each on the first server that is free.
"""

import asyncio
import hashlib
import json
import logging
import os
import sys
import threading
import time
import urllib.request
import uuid

import aiohttp
from aiohttp import web

import comfy.model_management
import comfy_execution.progress as progress
import execution
import nodes
from comfy_execution.graph import DynamicPrompt
from server import PromptServer

from . import codec, split

REMOTE_URLS = [u.strip().rstrip("/") for u in os.environ.get("COMFYUI_REMOTE_URL", "").split(",") if u.strip()]
REMOTE_URL = REMOTE_URLS[0]  # node definitions, model lists and downloads, the time limit
SERVER_DOWN_FOR = 60  # seconds a server that refused a connection is skipped
UPLOAD_PART = 64 * 1024**2  # stays under the server's default 100 MB --max-upload-size
PREVIEW_IMAGE, PREVIEW_IMAGE_WITH_METADATA = 1, 4
RELAYED_EVENTS = {"executing", "progress", "progress_state", "execution_cached"}
REMOTE_MODEL_ROUTES = ("/models", "/experiment/models", "/embeddings")
# Routes forwarded with any method: "Download missing models to server" should fetch onto the compute server,
# and the browser's time-limit warning asks about the compute server's limit
REMOTE_ROUTES = ("/server_models/", "/remote_compute/deadline")
ORIGINAL_PROMPT = "remote_compute_prompt"  # extra_data key

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
        logging.error(f"remote_compute: can't run this prompt remotely: {e}")
        json_data["prompt"] = {"remote_compute_error": {"class_type": "RemoteComputeError", "inputs": {"message": str(e)}}}
        json_data.pop("partial_execution_targets", None)
        return json_data
    if spec is not None:
        json_data["prompt"] = local
        # Save nodes embed the executed prompt in their files: give them the one that was queued (see below)
        json_data.setdefault("extra_data", {})[ORIGINAL_PROMPT] = prompt
        if json_data.get("partial_execution_targets") is not None:
            json_data["partial_execution_targets"] = list(json_data["partial_execution_targets"]) + [split.EXEC_ID]
        logging.info(f"remote_compute: {len(spec['remote_ids'])} nodes run on a compute server, "
                     f"{len(local) - len(spec['captures']) - 1} here; {len(spec['inputs'])} values up, {len(spec['captures'])} back")
    return json_data


class _QueuedPrompt:
    """The execution's DynamicPrompt, but its original prompt is the one queued before the split."""

    def __init__(self, dynprompt, prompt):
        self._dynprompt, self._prompt = dynprompt, prompt

    def get_original_prompt(self):
        return self._prompt

    def __getattr__(self, name):
        return getattr(self._dynprompt, name)


_get_input_data = execution.get_input_data


def _get_input_data_queued(inputs, class_def, unique_id, execution_list=None, dynprompt=None, extra_data={}):
    """Fills nodes' hidden PROMPT input (the "prompt" metadata of saved images and videos) with the queued prompt."""
    if dynprompt is not None and ORIGINAL_PROMPT in extra_data:
        dynprompt = _QueuedPrompt(dynprompt, extra_data[ORIGINAL_PROMPT])
    return _get_input_data(inputs, class_def, unique_id, execution_list, dynprompt, extra_data)


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


# --- several prompts at once ------------------------------------------------------------------------------
# ComfyUI runs one prompt at a time, keeping the running prompt's id and progress in globals. With several
# servers, more workers run prompts side by side, so the id (and the progress registry, when there are several
# workers) is kept per thread instead: every prompt executes in one thread, its async nodes included.

_job = threading.local()
_execute_async = execution.PromptExecutor.execute_async


async def _execute_async_tracked(self, prompt, prompt_id, extra_data={}, execute_outputs=[]):
    _job.prompt_id, _job.client_id = prompt_id, extra_data.get("client_id")
    return await _execute_async(self, prompt, prompt_id, extra_data, execute_outputs)


def _reset_progress_state(prompt_id, dynprompt):
    if getattr(_job, "registry", None) is not None:
        _job.registry.reset_handlers()
    _job.registry = progress.ProgressRegistry(prompt_id, dynprompt)


def _get_progress_state():
    if getattr(_job, "registry", None) is None:
        _job.registry = progress.ProgressRegistry(prompt_id="", dynprompt=DynamicPrompt({}))
    return _job.registry


def _add_progress_handler(handler):
    registry = _get_progress_state()
    handler.set_registry(registry)
    registry.register_handler(handler)


def _per_thread_progress():
    import comfy_api.latest
    for module in (progress, execution, comfy_api.latest, sys.modules.get("__main__")):
        for name, f in (("reset_progress_state", _reset_progress_state), ("get_progress_state", _get_progress_state),
                        ("add_progress_handler", _add_progress_handler)):
            if hasattr(module, name):
                setattr(module, name, f)


def _worker():
    """What ComfyUI's own prompt worker does for a prompt, minus its model and memory housekeeping (nothing is
    loaded here)."""
    q = server.prompt_queue
    e = execution.PromptExecutor(server, cache_type=execution.CacheType.CLASSIC, asset_manager=server.asset_manager,
                                 cache_args={"lru": 0, "ram": 2.0, "ram_inactive": 4.0})  # as main.py's defaults, small
    while True:
        try:
            _run_one(q, e)
        except Exception:
            logging.exception("remote_compute: worker error")


def _run_one(q, e):
    queue_item = q.get(timeout=1000.0)
    if queue_item is None:
        return
    item, item_id = queue_item
    prompt_id = item[1]
    extra_data = item[3].copy()
    extra_data.update(item[5])  # the sensitive part, kept out of the history
    start = time.perf_counter()
    try:
        e.execute(item[2], prompt_id, extra_data, item[4])
    except Exception as ex:  # execute reports node errors itself; this is anything else, so the prompt still ends
        logging.exception("remote_compute: worker error")
        e.success, e.history_result = False, {"outputs": {}, "meta": {}}
        e.status_messages = [("execution_error", {"prompt_id": prompt_id, "exception_message": str(ex)})]
    q.task_done(item_id, e.history_result,
                status=execution.PromptQueue.ExecutionStatus(status_str="success" if e.success else "error",
                                                             completed=e.success, messages=e.status_messages),
                process_item=lambda prompt: prompt[:5] + prompt[6:])
    if extra_data.get("client_id") is not None:
        server.send_sync("executing", {"node": None, "prompt_id": prompt_id}, extra_data["client_id"])
    logging.info(f"Prompt executed in {time.perf_counter() - start:.2f} seconds")


class _Servers:
    """Which compute servers are busy; a job takes the first free one, in COMFYUI_REMOTE_URL's order."""

    def __init__(self, urls):
        self.urls, self.busy, self.down_until, self.lock = urls, set(), {}, threading.Lock()

    async def acquire(self):
        while True:
            with self.lock:
                now = time.time()
                free = [u for u in self.urls if u not in self.busy]
                up = [u for u in free if self.down_until.get(u, 0) <= now]
                if up or (free and len(free) == len(self.urls)):  # all down: try anyway rather than wait forever
                    url = (up or free)[0]
                    self.busy.add(url)
                    return url
            comfy.model_management.throw_exception_if_processing_interrupted()
            await asyncio.sleep(0.2)

    def release(self, url, refused=False):
        with self.lock:
            self.busy.discard(url)
            if refused:
                self.down_until[url] = time.time() + SERVER_DOWN_FOR


_servers = _Servers(REMOTE_URLS)


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
        tried = set()
        while True:
            url = await _servers.acquire()
            try:
                return await self._run_on(url, json.loads(spec), inputs)
            except aiohttp.ClientConnectorError as e:  # nothing was queued there: try another server
                tried.add(url)
                _servers.release(url, refused=True)
                url = None
                if len(tried) == len(REMOTE_URLS):
                    raise RuntimeError(f"can't reach any compute server ({e})")
                logging.warning(f"remote_compute: {e}; trying another compute server")
            finally:
                if url is not None:
                    _servers.release(url)

    async def _run_on(self, url, spec, inputs):
        local_pid, sid = _job.prompt_id, _job.client_id
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
                    async with s.get(f"{url}/remote_compute/value/{fp}") as r:
                        present = (await r.json())["present"]
                    for part, off in enumerate(range(0, len(data), UPLOAD_PART) if not present else []):
                        async with s.put(f"{url}/remote_compute/value/{fp}?part={part}", data=data[off:off + UPLOAD_PART]) as r:
                            if r.status != 200:
                                raise RuntimeError(f"upload to compute server failed: HTTP {r.status} {await r.text()}")
                    prompt_json = prompt_json.replace(json.dumps(f"@in_{i}"), json.dumps(fp))
                prompt_json = prompt_json.replace('"@job"', json.dumps(job))

                # 2. queue it and follow the server's websocket until it finishes
                async with s.ws_connect(f"{url}/ws?clientId={client_id}", max_msg_size=0) as ws:
                    async with s.post(f"{url}/prompt", json={"prompt": json.loads(prompt_json), "client_id": client_id}) as r:
                        res = await r.json()
                    if r.status != 200:
                        raise RuntimeError(f"compute server rejected the prompt: {json.dumps(res.get('error', res))[:500]} "
                                           f"{json.dumps(res.get('node_errors', {}))[:1500]}")
                    remote_pid = res["prompt_id"]
                    if len(REMOTE_URLS) > 1:
                        logging.info(f"remote_compute: prompt {local_pid} runs on {url}")
                    await self._follow(ws, s, url, remote_pid, local_pid, sid)

                # 3. fetch the results (the server forgets them on cleanup)
                async with s.get(f"{url}/remote_compute/results/{job}") as r:
                    if r.status != 200:
                        raise RuntimeError(f"compute server has no results for this job: HTTP {r.status}")
                    results = _decode_results(await r.read())
            finally:
                try:
                    async with s.post(f"{url}/remote_compute/cleanup",
                                      json={"job": job, "fingerprints": fingerprints, "prompt_id": remote_pid}) as r:
                        pass
                except Exception as e:
                    logging.warning(f"remote_compute: cleanup on compute server failed: {e}")
        return (results,)

    async def _follow(self, ws, session, url, remote_pid, local_pid, sid):
        while True:
            if comfy.model_management.processing_interrupted():
                async with session.post(f"{url}/interrupt", json={"prompt_id": remote_pid}):
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
execution.get_input_data = _get_input_data_queued
execution.PromptExecutor.execute_async = _execute_async_tracked
if len(REMOTE_URLS) > 1:
    _per_thread_progress()
    for i in range(len(REMOTE_URLS) - 1):  # ComfyUI's own worker is the first
        threading.Thread(target=_worker, daemon=True, name=f"remote_compute worker {i + 2}").start()
logging.info(f"remote_compute: jobs run on {', '.join(REMOTE_URLS)}; files stay on this machine")
