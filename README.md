# comfyui

A self-contained [ComfyUI](https://github.com/Comfy-Org/ComfyUI) setup that runs the same workflows on
different hardware. It has:

- scripts that build an isolated Python environment and pick ComfyUI's launch flags for the machine,
- a few custom nodes,
- "People" workflows for editing photos of people and turning them into short videos,
- a remote mode that computes on another machine's GPU, or a rented one, while your files stay local.

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

On macOS, start ComfyUI with `./run.sh`; on Linux the service is already running. Open http://127.0.0.1:8188,
load a workflow from the sidebar, and use **Extensions → Download missing models to server** to fetch its
models.

uv, the Python build, the caches and the Hugging Face token all stay inside the project directory. The only
thing outside it is the systemd user unit link on Linux.

## Layout

```
run.sh           start ComfyUI on 127.0.0.1:8188 with flags for this machine's GPU
setup.sh         detect hardware, build .venv with the right PyTorch, link custom nodes and workflows, systemd unit
remote.sh        run ComfyUI here but compute on another machine (see Remote compute)
runpod.sh        rent a RunPod GPU to be that other machine
lib/cloud.sh     used by runpod.sh: set up the project on a rented machine over SSH
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

- **People Edit**: edit a photo of a person from a text instruction, optionally taking clothing, hair or
  style from a reference image. Three versions: standard and Turbo (Qwen-Image 2.1) and 8GB (FLUX.2 Klein,
  for 8 GB GPUs). Each comes as "1 image" and "main + reference"; Turbo also has a "batch folder" version that
  edits every image in a folder.
- **People Video - H3 image to video**: MiniMax H3 image to video, with generated sound. Needs a GB10-class
  machine. The **(Mac)** version uses model files Apple GPUs can load and runs the text encoder on the CPU.
- **People Video - Wan 2.2 5B / 14B image to video**: silent clips. The 14B version keeps the person's
  identity much better.

Each workflow has a "How to use" note below its nodes. The video workflows also list their model links.

## Remote compute

`remote.sh` starts a ComfyUI on this machine that sends the GPU work to another machine running this project.
The web UI, the `input/` and `output/` folders, the history and the assets stay on this machine. The models
and the GPU work are on the other one.

```sh
./remote.sh gb10          # gb10: the compute machine's SSH host
./remote.sh gb10 mac      # several compute machines, fastest first
```

It uses port 8188, or the first free port from 8190 if this machine's own ComfyUI already has 8188. It prints
which one.

With several compute machines, that many jobs run at once, each on the first free machine in the order given.
Queue a batch, or run a batch folder, and the jobs spread over all of them. The first machine provides the node
and model lists, and "Download missing models to server" downloads onto it, so the others need the same models.
A machine that can't be reached is left out.

How it works (`custom_nodes/remote_compute`):

- The local UI shows the compute machine's nodes and model lists.
- Each queued job is split. File loaders (Load Image, the batch folder node) and save/preview nodes run
  locally; everything between them runs on the compute machine as one job.
- Loaded images are sent to the compute machine's RAM, and results come back into the local save nodes.
  Images travel losslessly. Video frames are quantized exactly as the video encoder would quantize them.
- Progress, node highlighting and previews are relayed to the local UI.
- Cancelling stops every job that is running, not just one.
- On the compute machine, job inputs and results stay in RAM and are deleted, with the job's history entry,
  once the client has them. Nothing is written to its disk.

Both machines need the same custom nodes. The compute machine needs the models; the client needs neither
models nor a GPU.

### On a rented cloud GPU

`runpod.sh` rents a [RunPod](https://www.runpod.io) pod to be the compute machine. First put a RunPod API key
in `.cache/runpod/api_key`.

```sh
./runpod.sh offers                        # GPUs in stock and their prices
./runpod.sh run                           # rent an RTX 4090 for the People Edit Turbo workflows, run
                                          # remote.sh against it, and delete the pod when you quit
./runpod.sh run --gpu "RTX 5090" --workflow "Wan 2.2 5B" --hours 1
./runpod.sh run --datacenter EUR-IS-1     # rent in a particular data center
./runpod.sh run --gpu "RTX 4090" --gpu "L4"   # two pods: jobs run on both at once
./runpod.sh run --gpus-per-pod 2          # one pod with two GPUs, one ComfyUI on each
./runpod.sh run --wait 30                 # not in stock? keep checking for 30 min, rent the moment it is
./runpod.sh run --dry-run --wait 30       # the same without renting: shows when it would have
./runpod.sh run --with gb10               # use your own gb10 too, next to the pod
./runpod.sh up; ./runpod.sh connect; ./runpod.sh down   # the same as run, in steps
./runpod.sh extend 1                      # one more hour before the pod deletes itself
./runpod.sh volume                        # list the network volumes
./runpod.sh volume grow 110               # enlarge the volume to 110 GB (it can't shrink again)
./runpod.sh volume delete DC              # delete one, with everything on it
```

The project, its venv and the models live on a RunPod network volume, which outlives the pods. The first pod
on a volume installs everything and downloads the models, which takes about 15 minutes. Later pods are ready
in a few minutes. A volume is billed monthly by size.

The People Edit Turbo models take about 30 GB. The H3 video workflow needs 42 GB more, so grow the volume to
110 GB before renting for it. H3 runs best on a 96 GB RTX PRO 6000:

```sh
./runpod.sh run --gpu "RTX PRO 6000" --workflow "H3 image to video.json" --wait 30
```

A volume belongs to one data center, and pods can only use the volume in their own data center. `runpod.sh`
keeps one volume per data center you rent in. Without `--datacenter`, it rents where one of your volumes is and
the GPUs are in stock. The first time, it picks a data center with them in stock.

Several pods share their data center's volume. They are set up one after another, so only the first one
installs and downloads, and each keeps its ComfyUI database on its own disk. RunPod reports stock per GPU type,
so asking for two of the same type can still get only one; the run then goes on with the pods it got.

`runpod.sh` asks before renting. A pod deletes itself:

- after a time limit, 3 hours by default. The pod enforces this itself, so it holds even if this machine
  goes offline. `./runpod.sh extend HOURS` adds time.
- after 30 minutes with no jobs and no client connected.

The browser and the `connect` terminal show when the pod will delete itself, and warn 10 and 2 minutes before.

Your images pass through the pod's memory while jobs run. Nothing of yours is written to the volume.

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
  folder when asked, using the Hugging Face token in `.cache/`. `server_image_manager` can delete images and
  videos in `input/` and `output/`. Both are only as safe as access to the port.
- `runpod.sh` keeps the RunPod API key, an SSH key for the pods and the pods' host keys in `.cache/runpod/`.
  A pod's ComfyUI also stays on its localhost, reached through the SSH tunnel. Pods never get your Hugging
  Face token, so they can't download gated models. They never get your RunPod API key either: they delete
  themselves with the key RunPod gives each pod.
- The Hugging Face token lives in `.cache/huggingface/`, which git ignores; `dist.sh` refuses to package it.
- Custom nodes run with your user's privileges. Read third-party nodes before installing them.

## Attribution

- [ComfyUI](https://github.com/Comfy-Org/ComfyUI) by Comfy Org and contributors, GPL-3.0. Included as an
  unmodified submodule.
- The workflows are adapted from Comfy Org's [workflow templates](https://github.com/Comfy-Org/workflow_templates),
  including parts of their model-link and how-to notes. MIT License, Copyright (c) 2023-present Comfy Org; see
  [workflows/LICENSE.workflow_templates](workflows/LICENSE.workflow_templates).
- [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) by city96 (Apache-2.0) is referenced, not included.
- Model weights are not included. Each model (FLUX.2 Klein, Qwen-Image, Wan 2.2, MiniMax H3, the lightx2v
  LoRAs, the GGUF quantizations) has its own license. Check it on the model's page before use.

## License

GPL-3.0 (see [LICENSE](LICENSE)), the same as ComfyUI, which the custom nodes build on. The parts of the
workflows taken from Comfy Org's templates stay under their MIT License.
