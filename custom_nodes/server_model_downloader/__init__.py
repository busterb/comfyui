"""Download a workflow's missing models on the ComfyUI server instead of in the browser.

Adds a frontend command that sends the workflow's model list ({name, url, directory})
to this server, which downloads each missing file into the matching models folder.
Hugging Face downloads use the token from `hf auth login` (HF_HOME).
"""

import asyncio
import logging
import os
import time
import uuid
from urllib.parse import urlparse

import aiohttp
from aiohttp import web

import folder_paths
from server import PromptServer

WEB_DIRECTORY = "./js"
NODE_CLASS_MAPPINGS = {}

ALLOWED_HOSTS = ("huggingface.co", "github.com", "civitai.com")
CHUNK = 8 * 1024 * 1024

jobs = {}  # id -> job dict
lock = asyncio.Lock()  # one download at a time to avoid saturating disk/network


def hf_token():
    try:
        from huggingface_hub import get_token
        return get_token()
    except Exception:
        return None


def validate(model):
    name, url, directory = model.get("name"), model.get("url"), model.get("directory")
    if not (isinstance(name, str) and isinstance(url, str) and isinstance(directory, str)):
        raise ValueError("model needs name, url and directory")
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not any(host == h or host.endswith("." + h) for h in ALLOWED_HOSTS):
        raise ValueError(f"URL not allowed: {url}")
    entry = folder_paths.folder_names_and_paths.get(directory)
    if entry is None or directory in ("custom_nodes", "configs") or not entry[1] or "folder" in entry[1]:
        raise ValueError(f"unknown model directory: {directory}")
    if os.path.splitext(name)[1].lower() not in entry[1]:
        raise ValueError(f"file type not allowed in {directory}: {name}")
    base = os.path.realpath(folder_paths.get_folder_paths(directory)[0])
    dest = os.path.realpath(os.path.join(base, name))
    if os.path.commonpath([base, dest]) != base:
        raise ValueError(f"invalid file name: {name}")
    return name, url, directory, dest


async def download(job):
    async with lock:
        job["state"] = "downloading"
        dest = job["dest"]
        tmp = dest + ".part"
        headers = {}
        if urlparse(job["url"]).hostname.endswith("huggingface.co"):
            token = hf_token()
            if token:
                headers["Authorization"] = f"Bearer {token}"
        try:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            timeout = aiohttp.ClientTimeout(total=None, sock_read=300)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(job["url"], headers=headers) as resp:
                    if resp.status in (401, 403):
                        raise RuntimeError(
                            f"HTTP {resp.status}: gated model or bad token - accept the license on the "
                            "model page and check `./hf.sh auth whoami`")
                    resp.raise_for_status()
                    job["total"] = resp.content_length or 0
                    with open(tmp, "wb") as f:
                        async for chunk in resp.content.iter_chunked(CHUNK):
                            f.write(chunk)
                            job["done"] += len(chunk)
            os.replace(tmp, dest)
            job["state"] = "complete"
            logging.info(f"[server_model_downloader] saved {dest}")
        except Exception as e:
            job["state"] = "error"
            job["error"] = str(e)
            logging.error(f"[server_model_downloader] {job['url']}: {e}")
            if os.path.exists(tmp):
                os.remove(tmp)


routes = PromptServer.instance.routes


@routes.post("/server_models/download")
async def queue_downloads(request):
    body = await request.json()
    results = []
    for model in body.get("models", []):
        try:
            name, url, directory, dest = validate(model)
        except ValueError as e:
            results.append({"name": model.get("name"), "state": "error", "error": str(e)})
            continue
        if folder_paths.get_full_path(directory, name) or os.path.exists(dest):
            results.append({"name": name, "directory": directory, "state": "exists"})
            continue
        active = next((j for j in jobs.values() if j["dest"] == dest and j["state"] in ("queued", "downloading")), None)
        if active:
            results.append(active)
            continue
        job = {"id": uuid.uuid4().hex, "name": name, "directory": directory, "url": url, "dest": dest,
               "state": "queued", "done": 0, "total": 0, "error": None, "created": time.time()}
        jobs[job["id"]] = job
        asyncio.create_task(download(job))
        results.append(job)
    return web.json_response([{k: v for k, v in r.items() if k != "dest"} for r in results])


@routes.get("/server_models/status")
async def status(request):
    return web.json_response([{k: v for k, v in j.items() if k != "dest"} for j in jobs.values()])
