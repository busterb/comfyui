"""Browse, preview and delete images and videos in ComfyUI/input and ComfyUI/output from the browser.

The local ComfyUI build can't delete imported files (the Assets panel hides Delete for inputs, and
deleting an output only drops its history entry). This adds an "Manage server images" window,
opened from the Extensions menu or a batch folder node, with thumbnails, a large preview and
delete. Deletes are limited to image and video files inside the input and output folders.
"""

import asyncio
import io
import logging
import os

import av
from aiohttp import web
from PIL import Image, ImageOps

import folder_paths
import node_helpers
from server import PromptServer

WEB_DIRECTORY = "./js"
NODE_CLASS_MAPPINGS = {}

ROOTS = {"input": folder_paths.get_input_directory, "output": folder_paths.get_output_directory}
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".avif")
VIDEO_EXTENSIONS = (".mp4", ".webm", ".mov", ".mkv", ".m4v")
EXTENSIONS = IMAGE_EXTENSIONS + VIDEO_EXTENSIONS
THUMB_SIZE = 320

routes = PromptServer.instance.routes


def resolve(root, rel):
    """Absolute path of an image or video file `rel` inside the input/output folder, or ValueError."""
    if root not in ROOTS:
        raise ValueError(f"Unknown root {root!r}")
    base = os.path.realpath(ROOTS[root]())
    path = os.path.realpath(os.path.join(base, rel))
    if os.path.commonpath([base, path]) != base or path == base:
        raise ValueError(f"Outside the {root} folder: {rel!r}")
    if not path.lower().endswith(EXTENSIONS) or not os.path.isfile(path):
        raise ValueError(f"Not an image or video file: {rel!r}")
    return path


@routes.get("/server_images/list")
async def list_images(request):
    root = request.query.get("root", "input")
    if root not in ROOTS:
        return web.json_response({"error": f"Unknown root {root!r}"}, status=400)
    base = ROOTS[root]()
    items = []
    for dirpath, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for f in files:
            if f.lower().endswith(EXTENSIONS):
                full = os.path.join(dirpath, f)
                st = os.stat(full)
                rel = os.path.relpath(full, base).replace(os.sep, "/")
                kind = "video" if f.lower().endswith(VIDEO_EXTENSIONS) else "image"
                items.append({"path": rel, "kind": kind, "size": st.st_size, "mtime": st.st_mtime})
    items.sort(key=lambda i: i["mtime"], reverse=True)
    return web.json_response({"root": root, "images": items})


@routes.get("/server_images/thumb")
async def thumb(request):
    try:
        path = resolve(request.query.get("root", ""), request.query.get("path", ""))
    except ValueError as e:
        return web.Response(status=404, text=str(e))
    try:
        body = await asyncio.to_thread(make_thumb, path)
    except (OSError, av.error.FFmpegError) as e:
        return web.Response(status=415, text=f"Can't read {os.path.basename(path)}: {e}")
    return web.Response(body=body, content_type="image/jpeg", headers={"Cache-Control": "max-age=300"})


def make_thumb(path):
    if path.lower().endswith(VIDEO_EXTENSIONS):
        img = video_frame(path)
    else:
        img = node_helpers.pillow(Image.open, path)
        img = node_helpers.pillow(ImageOps.exif_transpose, img)
    img.thumbnail((THUMB_SIZE, THUMB_SIZE))
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=82)
    return buf.getvalue()


def video_frame(path):
    # A frame from the middle: the first frame of an image-to-video clip is just the source photo
    with av.open(path) as container:
        stream = container.streams.video[0]
        if container.duration:
            container.seek(container.duration // 2)
        return next(container.decode(stream)).to_image()


@routes.post("/server_images/delete")
async def delete_images(request):
    body = await request.json()
    root = body.get("root", "")
    deleted, errors = [], []
    for rel in body.get("paths", []):
        try:
            os.remove(resolve(root, rel))
            deleted.append(rel)
        except (ValueError, OSError) as e:
            errors.append({"path": rel, "error": str(e)})
    if deleted:
        logging.info("[server_image_manager] deleted %d file(s) from %s: %s", len(deleted), root, ", ".join(deleted[:20]))
        rescan(root)
    return web.json_response({"deleted": deleted, "errors": errors})


def rescan(root):
    # Let the asset index notice the missing files now rather than on its next scan
    try:
        from app.assets.seeder import ScanPhase, asset_seeder

        if not asset_seeder.is_disabled():
            asset_seeder.enqueue_scan(roots=(root,), phase=ScanPhase.FAST)
    except Exception:
        logging.exception("[server_image_manager] asset rescan failed")
