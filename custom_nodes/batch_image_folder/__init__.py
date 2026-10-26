"""Edit every image in an input subfolder with one workflow, one queued job per image.

The node loads the image at `index` (in name order) from a subfolder of ComfyUI/input. Its
"Run all images in folder" button queues one job per image, so each result appears as soon as
it is done; "Upload images..." adds files from the browser to the folder. Unlike the core
"Load Image (from Folder)" node, phone photos are rotated upright from their EXIF tag, and each
result's save prefix is named after its source file.
"""

import hashlib
import os

import numpy as np
import torch
from aiohttp import web
from PIL import Image, ImageOps

import folder_paths
import node_helpers
from server import PromptServer

WEB_DIRECTORY = "./js"
EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp")
DEFAULT_FOLDER = "batch"


def folder_path(folder):
    input_dir = os.path.abspath(folder_paths.get_input_directory())
    path = os.path.abspath(os.path.join(input_dir, folder))
    if not folder_paths.is_within_directory(input_dir, path) or path == input_dir:
        raise ValueError(f"Invalid folder: {folder!r}")
    return path


def image_files(path):
    if not os.path.isdir(path):
        return []
    return sorted(f for f in os.listdir(path) if f.lower().endswith(EXTENSIONS) and os.path.isfile(os.path.join(path, f)))


@PromptServer.instance.routes.get("/batch_image_folder/files")
async def list_files(request):
    try:
        path = folder_path(request.query.get("folder", ""))
    except ValueError as e:
        return web.json_response({"error": str(e)}, status=400)
    return web.json_response({"files": image_files(path)})


class LoadImageFolderBatch:
    @classmethod
    def INPUT_TYPES(cls):
        folders = sorted(set(folder_paths.get_input_subfolders()) | {DEFAULT_FOLDER})
        return {
            "required": {
                "folder": (folders, {"default": DEFAULT_FOLDER, "tooltip": "Subfolder of ComfyUI/input holding the images to edit."}),
                "filename_prefix": ("STRING", {"default": "people_edit_batch", "tooltip": "Results are saved as <prefix>_<source name>_00001.png"}),
                "index": ("INT", {"default": 0, "min": 0, "max": 100000, "tooltip": "Which image to load, in name order (wraps around). Run all images in folder sets this for each job."}),
            }
        }

    RETURN_TYPES = ("IMAGE", "STRING", "INT")
    RETURN_NAMES = ("image", "save_prefix", "count")
    FUNCTION = "load"
    CATEGORY = "image"
    DESCRIPTION = "Loads one image (by index, in name order, EXIF-rotated) from an input subfolder."

    def load(self, folder, filename_prefix, index):
        path = folder_path(folder)
        os.makedirs(path, exist_ok=True)
        files = image_files(path)
        if not files:
            raise ValueError(f"No images (.png, .jpg, .jpeg, .webp) in ComfyUI/input/{folder}")
        name = files[index % len(files)]
        img = node_helpers.pillow(Image.open, os.path.join(path, name))
        img = node_helpers.pillow(ImageOps.exif_transpose, img)
        if img.mode == "I":
            img = img.point(lambda i: i * (1 / 255))
        arr = np.array(img.convert("RGB")).astype(np.float32) / 255.0
        return (torch.from_numpy(arr)[None,], f"{filename_prefix}_{os.path.splitext(name)[0]}", len(files))

    @classmethod
    def IS_CHANGED(cls, folder, filename_prefix, index):
        # Re-run when files are added, removed or replaced
        path = folder_path(folder)
        m = hashlib.sha256()
        for f in image_files(path):
            st = os.stat(os.path.join(path, f))
            m.update(f"{f}:{st.st_size}:{st.st_mtime_ns}\n".encode())
        return m.hexdigest()

    @classmethod
    def VALIDATE_INPUTS(cls, folder):
        try:
            folder_path(folder)
        except ValueError as e:
            return str(e)
        return True


NODE_CLASS_MAPPINGS = {"LoadImageFolderBatch": LoadImageFolderBatch}
NODE_DISPLAY_NAME_MAPPINGS = {"LoadImageFolderBatch": "Load Images from Folder (batch edit)"}
