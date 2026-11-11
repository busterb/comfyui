"""Train a character LoRA for Qwen Image 2.1 (the Character Edit Turbo model) on a compute machine. Run through lora.sh.

Photos of a character go in ComfyUI/input/lora/NAME/ on this machine, each with an optional caption NAME.txt
next to it (photo.jpg -> photo.txt). The compute machine runs ComfyUI's own training nodes; this script only
talks to its ComfyUI over an SSH tunnel, plus one SSH command to put a missing base model or the result in place.
"""

import argparse
import asyncio
import hashlib
import io
import json
import os
import shlex
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

import aiohttp
from PIL import Image, ImageOps

PROJECT = Path(__file__).resolve().parent.parent
DATASETS = PROJECT / "ComfyUI" / "input" / "lora"
LOCAL_LORAS = PROJECT / "ComfyUI" / "models" / "loras" / "characters"
PHOTO_TYPES = (".jpg", ".jpeg", ".png", ".webp")
HF = "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main"
BASE_MODEL = "qwen_image_2.1_bf16.safetensors"  # train on the full model, not the turbo one; the LoRA works with both
MODELS = {  # file -> (folder on the compute machine, URL)
    BASE_MODEL: ("diffusion_models", f"{HF}/diffusion_models/{BASE_MODEL}"),
    "qwen3vl_8b_bf16.safetensors": ("text_encoders", f"{HF}/text_encoders/qwen3vl_8b_bf16.safetensors"),
    "qwen_image_2.1_vae_bf16.safetensors": ("vae", f"{HF}/vae/qwen_image_2.1_vae_bf16.safetensors"),
}
LOADER_OF = {"diffusion_models": ("UNETLoader", "unet_name"), "text_encoders": ("CLIPLoader", "clip_name"),
             "vae": ("VAELoader", "vae_name")}
TRAIN_PIXELS = 1024 * 1024  # photos are scaled to about this many pixels, sides multiples of 32

CAPTION_PROMPT = """This photo shows a {kind} called {trigger}. Write a caption for training an image \
model on this character. Start with "{trigger}, a {kind}," and then describe in one or two plain sentences: \
the pose and action, the camera angle and framing, the setting and background, and the lighting. {look} \
Write only the caption."""
PUPPET_LOOK = "Don't describe the puppet's own colors, materials, face or clothing: the name {trigger} stands for those."
PERSON_LOOK = ("Mention what {trigger} is wearing and any other people in the photo, but don't describe {trigger}'s "
               "face, hair or build: the name {trigger} stands for those.")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def photos(name):
    folder = DATASETS / name
    if not folder.is_dir():
        die(f"no folder {folder.relative_to(PROJECT)}: put the character's photos there")
    found = sorted(p for p in folder.iterdir() if p.suffix.lower() in PHOTO_TYPES)
    if not found:
        die(f"no photos in {folder.relative_to(PROJECT)}")
    return found


def scaled_jpeg(path, pixels=TRAIN_PIXELS):
    """The photo upright (EXIF), RGB, scaled to about `pixels` with sides multiples of 32, as JPEG bytes."""
    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    ratio = img.width / img.height
    w = max(32, round((pixels * ratio) ** 0.5 / 32) * 32)
    h = max(32, round((pixels / ratio) ** 0.5 / 32) * 32)
    # cover w x h, then crop the middle, so nothing is stretched
    scale = max(w / img.width, h / img.height)
    img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    left, top = (img.width - w) // 2, (img.height - h) // 2
    buf = io.BytesIO()
    img.crop((left, top, left + w, top + h)).save(buf, "JPEG", quality=95)
    return buf.getvalue()


class Machine:
    """A compute machine's ComfyUI, reached through an SSH tunnel to its localhost."""

    def __init__(self, host, ssh_config=None, remote_port=8188):
        self.host, self.port = host.split(":")[0], int(host.split(":")[1]) if ":" in host else remote_port
        self.ssh = ["ssh"] + (["-F", ssh_config] if ssh_config else [])
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.local = s.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.local}"
        self.tunnel = None

    def __enter__(self):
        self.tunnel = subprocess.Popen(self.ssh + ["-N", "-o", "ControlPath=none", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                                                   "-L", f"{self.local}:127.0.0.1:{self.port}", self.host])
        for _ in range(30):
            if self.tunnel.poll() is not None:
                die(f"can't open an SSH tunnel to {self.host}")
            try:
                with socket.create_connection(("127.0.0.1", self.local), timeout=1):
                    break
            except OSError:
                time.sleep(1)
        return self

    def __exit__(self, *exc):
        if self.tunnel:
            self.tunnel.terminate()

    def run(self, command):
        return subprocess.run(self.ssh + [self.host, command], check=True, capture_output=True, text=True).stdout


async def get_json(s, url):
    async with s.get(url) as r:
        if r.status != 200:
            die(f"{url}: HTTP {r.status}")
        return await r.json()


async def base_directory(s, m):
    argv = (await get_json(s, f"{m.url}/system_stats"))["system"]["argv"]
    if "--base-directory" in argv:
        return argv[argv.index("--base-directory") + 1]
    die("can't tell where ComfyUI keeps its files on the compute machine (no --base-directory)")


async def ensure_models(s, m, names):
    """Download the models the compute machine lacks, into its ComfyUI/models/FOLDER/."""
    missing = []
    for name in names:
        folder, url = MODELS[name]
        node, field = LOADER_OF[folder]
        options = (await get_json(s, f"{m.url}/object_info/{node}"))[node]["input"]["required"][field][0]
        if name not in options:
            missing.append((name, folder, url))
    if not missing:
        return
    base = await base_directory(s, m)
    for name, folder, url in missing:
        print(f"downloading {name} on {m.host} (one time)...", flush=True)
        dest = f"{base}/models/{folder}/{name}"
        m.run(f"mkdir -p {shlex.quote(os.path.dirname(dest))} && curl -fsSL --retry 5 -C - -o {shlex.quote(dest + '.part')} "
              f"{shlex.quote(url)} && mv {shlex.quote(dest + '.part')} {shlex.quote(dest)}")


async def upload(s, m, data, filename, subfolder):
    form = aiohttp.FormData()
    form.add_field("image", data, filename=filename)
    form.add_field("subfolder", subfolder)
    form.add_field("type", "input")
    form.add_field("overwrite", "true")
    async with s.post(f"{m.url}/upload/image", data=form) as r:
        if r.status != 200:
            die(f"upload of {filename} failed: HTTP {r.status} {await r.text()}")


async def run_prompt(s, m, prompt, label):
    """Queue a prompt, show its progress, and return its history entry."""
    client_id = f"lora-{uuid.uuid4().hex}"
    async with s.ws_connect(f"{m.url}/ws?clientId={client_id}", max_msg_size=0) as ws:
        async with s.post(f"{m.url}/prompt", json={"prompt": prompt, "client_id": client_id}) as r:
            res = await r.json()
            if r.status != 200:
                die(f"the compute machine rejected the {label} job: {json.dumps(res)[:2000]}")
        pid, last = res["prompt_id"], 0.0
        while True:
            msg = await ws.receive()
            if msg.type == aiohttp.WSMsgType.BINARY:
                continue
            if msg.type != aiohttp.WSMsgType.TEXT:
                die(f"lost the connection to the compute machine during {label}")
            m_ = json.loads(msg.data)
            kind, data = m_.get("type"), m_.get("data") or {}
            if data.get("prompt_id") not in (None, pid):
                continue
            if kind == "progress" and time.time() - last > 10:
                last = time.time()
                print(f"  {label}: {data['value']} of {data['max']}", flush=True)
            elif kind == "execution_error":
                die(f"{label} failed in {data.get('node_type')}: {data.get('exception_message', '').strip()}")
            elif kind == "execution_interrupted":
                die(f"{label} was interrupted on the compute machine")
            elif kind == "execution_success":
                break
    return (await get_json(s, f"{m.url}/history/{pid}"))[pid]


def caption_text(trigger, kind):
    look = (PUPPET_LOOK if kind == "puppet" else PERSON_LOOK).format(trigger=trigger)
    return CAPTION_PROMPT.format(trigger=trigger, kind=kind, look=look)


def caption_prompt(image, trigger, kind):
    return {
        "1": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen3vl_8b_bf16.safetensors", "type": "qwen_image", "device": "default"}},
        "2": {"class_type": "LoadImage", "inputs": {"image": image}},
        "3": {"class_type": "TextGenerate", "inputs": {"clip": ["1", 0], "image": ["2", 0], "prompt": caption_text(trigger, kind),
                                                     "max_length": 256, "sampling_mode": "off", "thinking": False}},
        "4": {"class_type": "PreviewAny", "inputs": {"source": ["3", 0]}},
    }


def train_prompt(folder, name, a):
    return {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": BASE_MODEL, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen3vl_8b_bf16.safetensors", "type": "qwen_image", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": "qwen_image_2.1_vae_bf16.safetensors"}},
        "4": {"class_type": "LoadImageTextDataSetFromFolder", "inputs": {"folder": folder}},
        "5": {"class_type": "MakeTrainingDataset", "inputs": {"images": ["4", 0], "texts": ["4", 1], "vae": ["3", 0], "clip": ["2", 0]}},
        "6": {"class_type": "TrainLoraNode", "inputs": {
            "model": ["1", 0], "latents": ["5", 0], "positive": ["5", 1], "batch_size": 1, "grad_accumulation_steps": 1,
            "steps": a.steps, "learning_rate": a.learning_rate, "rank": a.rank, "optimizer": "AdamW", "loss_function": "MSE",
            "seed": a.seed, "training_dtype": "bf16", "lora_dtype": "bf16", "quantized_backward": False, "algorithm": "LoRA",
            "gradient_checkpointing": True, "checkpoint_depth": 1, "offloading": False, "existing_lora": "[None]",
            "bucket_mode": False, "bypass_mode": False}},
        "7": {"class_type": "SaveLoRA", "inputs": {"lora": ["6", 0], "prefix": f"loras/{name}", "steps": ["6", 2]}},
    }


async def cmd_caption(a):
    files = photos(a.name)
    todo = [p for p in files if a.overwrite or not p.with_suffix(".txt").exists()]
    if not todo:
        print("every photo has a caption already (--overwrite rewrites them)")
        return
    with Machine(a.host, a.ssh_config) as m:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None)) as s:
            await ensure_models(s, m, ["qwen3vl_8b_bf16.safetensors"])
            for i, p in enumerate(todo, 1):
                filename = f"{a.name}-{p.stem}.jpg"
                await upload(s, m, scaled_jpeg(p, 768 * 768), filename, "lora_captions")
                h = await run_prompt(s, m, caption_prompt(f"lora_captions/{filename}", a.trigger, a.kind), f"caption {i}/{len(todo)}")
                text = h["outputs"]["4"]["text"][0].strip().strip('"')
                p.with_suffix(".txt").write_text(text + "\n")
                print(f"{p.name}: {text}")
    print(f"\nCheck the captions in {(DATASETS / a.name).relative_to(PROJECT)}/*.txt and fix any that are wrong, then train.")


async def cmd_train(a):
    files = photos(a.name)
    uncaptioned = [p.name for p in files if not p.with_suffix(".txt").exists()]
    if uncaptioned and not a.no_captions:
        die(f"no caption for {', '.join(uncaptioned)}: run ./lora.sh caption first, or write them (or --no-captions)")
    # The dataset as uploaded: scaled photos and their captions. A folder per content, so photos removed here
    # aren't left behind in the training set there.
    dataset = [(p.stem + ".jpg", scaled_jpeg(p), (p.with_suffix(".txt").read_text().strip() if p.with_suffix(".txt").exists() else ""))
               for p in files]
    digest = hashlib.sha256(json.dumps([(n, hashlib.sha256(d).hexdigest(), c) for n, d, c in dataset]).encode()).hexdigest()[:10]
    folder = f"lora/{a.name}-{digest}"
    with Machine(a.host, a.ssh_config) as m:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None)) as s:
            await ensure_models(s, m, list(MODELS))
            print(f"uploading {len(dataset)} photos to {m.host}...", flush=True)
            for n, data, caption in dataset:
                await upload(s, m, data, n, folder)
                await upload(s, m, caption.encode(), n.rsplit(".", 1)[0] + ".txt", folder)
            print(f"training {a.name}: {a.steps} steps, rank {a.rank}, learning rate {a.learning_rate}", flush=True)
            started = time.time()
            await run_prompt(s, m, train_prompt(folder, a.name, a), "training")
            print(f"trained in {(time.time() - started) / 60:.0f} min")
            # The newest file SaveLoRA wrote, moved into the compute machine's models/loras/characters/ and copied here
            base = await base_directory(s, m)
            out = f"{base}/output/loras"
            newest = m.run(f"ls -t {shlex.quote(out)}/{shlex.quote(a.name)}_*.safetensors | head -1").strip()
            if not newest:
                die(f"the LoRA isn't in {out} on {m.host}")
            final = f"{a.name}.safetensors"
            m.run(f"mkdir -p {shlex.quote(base)}/models/loras/characters && cp {shlex.quote(newest)} {shlex.quote(base)}/models/loras/characters/{final}")
            LOCAL_LORAS.mkdir(parents=True, exist_ok=True)
            async with s.get(f"{m.url}/view", params={"filename": os.path.basename(newest), "subfolder": "loras", "type": "output"}) as r:
                if r.status != 200:
                    die(f"couldn't fetch the LoRA: HTTP {r.status}")
                (LOCAL_LORAS / final).write_bytes(await r.read())
    print(f"\nLoRA: characters/{final}, on {a.host} and in {LOCAL_LORAS.relative_to(PROJECT)}/")
    print(f'Use it with a LoRA loader set to characters/{final}, and "{a.trigger}" in the prompt.')


def main():
    p = argparse.ArgumentParser(prog="lora.sh", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for cmd, help_ in (("caption", "draft a caption for each photo that has none, with Qwen3-VL on HOST"),
                       ("train", "train the LoRA on HOST; it lands there and here in models/loras/characters/")):
        c = sub.add_parser(cmd, help=help_)
        c.add_argument("name", help="the character: its photos are in ComfyUI/input/lora/NAME/")
        c.add_argument("host", help="compute machine: an SSH host with ComfyUI on port 8188, or HOST:PORT")
        c.add_argument("--trigger", help="the word that names the character in prompts (default: NAME)")
        if cmd == "caption":
            c.add_argument("--overwrite", action="store_true", help="rewrite existing captions too")
            c.add_argument("--kind", default="puppet",
                           help='what the character is, as the captions name it: "puppet" (default), "woman", "man", ...')
        else:
            c.add_argument("--steps", type=int, default=2000, help="training steps (default 2000, about 100 per photo)")
            c.add_argument("--rank", type=int, default=16, help="LoRA rank (default 16)")
            c.add_argument("--learning-rate", type=float, default=1e-4, help="(default 0.0001)")
            c.add_argument("--seed", type=int, default=0)
            c.add_argument("--no-captions", action="store_true", help="train photos without a caption on an empty one")
    a = p.parse_args()
    a.trigger = a.trigger or a.name
    a.ssh_config = os.environ.get("SSH_CONFIG")
    asyncio.run(cmd_caption(a) if a.cmd == "caption" else cmd_train(a))


if __name__ == "__main__":
    main()
