# comfyui

A self-contained [ComfyUI](https://github.com/Comfy-Org/ComfyUI) setup that runs the same workflows on very
different hardware. It adds scripts that build an isolated Python environment and tune ComfyUI's launch flags
to the machine, a few custom nodes, a set of "People" image-edit and image-to-video workflows, and a remote
mode that uses another machine's GPU while files stay on the local machine.

ComfyUI itself is not modified. It is a git submodule pinned to a tested upstream commit.

## Tested hardware

| Machine | GPU / memory | Notes |
|---|---|---|
| NVIDIA DGX Spark class (GB10) | Blackwell, 128 GB unified | Runs everything, including the large Qwen-based edit and MiniMax H3 video workflows |
| Desktop | GeForce GTX 1080, 8 GB | The "8GB" edit workflows |
| Laptop | Radeon 780M iGPU (gfx1103), shared RAM | ROCm wheels built for gfx1103; needs `amdgpu.cwsr_enable=0` (setup.sh explains) |
| MacBook Pro | Apple M5 Pro, 48 GB unified | MPS; no fp8, so bf16/fp16/int8 model files. Wan 2.2 and H3 (Mac) video workflows |

## Quick start

```sh
git clone https://github.com/busterb/comfyui.git ~/projects/comfyui
cd ~/projects/comfyui
./setup.sh --dry-run     # see what it would do
./setup.sh               # fetch ComfyUI, build the venv, link nodes and workflows, install the service (Linux)
./hf.sh auth login       # for gated Hugging Face models
```

Open http://127.0.0.1:8188, load a workflow from the sidebar, and use
**Extensions → Download missing models to server** to fetch its models. On macOS start ComfyUI with `./run.sh`.

Everything ComfyUI and its Python packages need (uv, the Python build, caches, the Hugging Face token) stays
inside the project directory. The only thing outside it is the systemd user unit link on Linux.

## Layout

```
run.sh           start ComfyUI on 127.0.0.1:8188 with flags for this machine's GPU
setup.sh         detect hardware, build .venv with the right PyTorch, link custom nodes and workflows, systemd unit
remote.sh        run ComfyUI here but compute on another machine (see Remote compute)
dist.sh          package the project as a tarball for a machine without git access
hf.sh            the Hugging Face CLI, with its token kept in .cache/
comfyui.service  systemd user unit (setup.sh links it)
custom_nodes/    our custom node packs, symlinked into ComfyUI/custom_nodes/
workflows/       the workflows, symlinked as ComfyUI/user/default/workflows
ComfyUI/         upstream ComfyUI (submodule)
```

`.venv/`, `.uv/`, `.cache/` and `.tmp/` are machine-specific and not tracked. Models, inputs and outputs live
in ComfyUI's own folders and are not tracked either.

## Custom nodes

- **remote_compute**: run jobs on another machine's ComfyUI while inputs and outputs stay local (below).
- **batch_image_folder**: edit every image in an input subfolder with one workflow, one queued job per image.
- **server_image_manager**: browse, preview and delete images and videos in ComfyUI's input and output folders.
- **server_model_downloader**: download a workflow's missing models on the server instead of in the browser.
- **cpu_bf16**: compute in bf16 instead of fp32 on CPUs with native bf16 (AVX512_BF16 or AMX), about 2.5× faster.
- **macos_cpu_fp32**: on Apple Silicon, run CPU-side models (such as a text encoder too big for the GPU) in fp32,
  the only format Apple CPUs compute quickly.

The Wan 2.2 14B workflow also needs [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF), which is not
included; install it into `ComfyUI/custom_nodes/` yourself.

## Workflows

- **People Edit** (standard, Turbo, 8GB; one image or main + reference; batch folder): edit a photo of a
  person from a text instruction, optionally borrowing clothing, hair or style from a reference image.
- **People Video - H3 image to video**: MiniMax H3 image-to-video with generated sound (GB10). The **(Mac)**
  variant uses the model files Apple GPUs can load and runs the text encoder on the CPU.
- **People Video - Wan 2.2 5B / 14B image to video**: silent clips; the 14B one keeps identity much better.

Each workflow has a "How to use" note and a "Model Links" note.

## Remote compute

`remote.sh` starts a local ComfyUI whose web UI, `input/` and `output/` folders, history and assets are on
this machine, while the models and the GPU work are on another machine running this project:

```sh
./remote.sh gb10                     # SSH host of the compute machine
COMFYUI_PORT=8190 ./remote.sh gb10   # if this machine's own ComfyUI already uses 8188
```

How it works (`custom_nodes/remote_compute`):

- The local UI shows the compute machine's nodes and model lists.
- Each queued job is split. File loaders (Load Image, the batch folder node) and save/preview nodes run
  locally; everything between them runs on the compute machine as one job.
- Loaded images are sent to the compute machine's RAM, and results come back into the local save nodes.
  Images travel losslessly. Video frames are quantized exactly as the video encoder would quantize them.
- Progress, node highlighting and previews are relayed to the local UI.
- On the compute machine, job inputs and results live in RAM only and are deleted once the client has them,
  along with the job's history entry. Nothing is written to its disk.

Both machines need the same custom nodes. The compute machine needs the models; the client needs neither
models nor a GPU.

## Security notes

ComfyUI has no authentication. Anyone who can reach its port can run jobs, read and upload images, and use
every route the custom nodes add. This project relies on that port never being exposed:

- `run.sh` binds ComfyUI to `127.0.0.1`. Don't add `--listen 0.0.0.0` or forward the port on a network you
  don't fully trust.
- `remote.sh` reaches the compute machine through an SSH tunnel, so the compute machine's ComfyUI also stays
  on its localhost. The `remote_compute` routes have no authentication of their own: anyone with access to the
  compute machine's port could upload values into its RAM store (capped at 8 GB, entries expire after 30 min)
  or fetch a job's results before the client does.
- `server_model_downloader` downloads files from huggingface.co, github.com and civitai.com into the models
  folder on request, using the Hugging Face token stored in `.cache/`. `server_image_manager` can delete
  images and videos in `input/` and `output/`. Both are only as safe as access to the port.
- The Hugging Face token lives in `.cache/huggingface/`, which git ignores; `dist.sh` refuses to package it.
- Custom nodes run with your user's privileges. Read third-party nodes before installing them.

## Attribution

- [ComfyUI](https://github.com/Comfy-Org/ComfyUI) by Comfy Org and contributors, GPL-3.0. Included as an
  unmodified submodule; `ComfyUI/custom_nodes/websocket_image_save.py` is part of it.
- The workflows are adapted from Comfy Org's [workflow templates](https://github.com/Comfy-Org/workflow_templates),
  including parts of their model-link and how-to notes. MIT License, Copyright (c) 2023-present Comfy Org; see
  [workflows/LICENSE.workflow_templates](workflows/LICENSE.workflow_templates).
- [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) by city96 (Apache-2.0) is referenced, not included.
- Model weights are not included. Each model (FLUX.2 Klein, Qwen-Image, Wan 2.2, MiniMax H3, the lightx2v
  LoRAs, the GGUF quantizations) has its own license; check it on the model's page before use.

## License

GPL-3.0 (see [LICENSE](LICENSE)), matching ComfyUI, which the custom nodes build on. The parts of the
workflows taken from Comfy Org's templates remain under their MIT License.
