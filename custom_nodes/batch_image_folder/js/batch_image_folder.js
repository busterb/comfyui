import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const NODE_TYPE = "LoadImageFolderBatch";

function toast(severity, summary, detail, life = 6000) {
  app.extensionManager?.toast?.add({ severity, summary, detail, life });
}

const widget = (node, name) => node.widgets?.find((w) => w.name === name);

async function listFiles(folder) {
  const resp = await api.fetchApi(`/batch_image_folder/files?folder=${encodeURIComponent(folder)}`);
  const body = await resp.json();
  if (!resp.ok) throw new Error(body.error ?? resp.statusText);
  return body.files;
}

// Upload browser files into ComfyUI/input/<folder> through the standard upload route.
async function uploadFiles(node, files) {
  const folder = widget(node, "folder").value;
  const images = [...files].filter((f) => f.type.startsWith("image/"));
  if (!images.length) return;
  toast("info", `Uploading ${images.length} image(s)`, `to input/${folder}`, 3000);
  let failed = 0;
  for (const file of images) {
    const body = new FormData();
    body.append("image", file);
    body.append("subfolder", folder);
    body.append("type", "input");
    const resp = await api.fetchApi("/upload/image", { method: "POST", body });
    if (!resp.ok) failed++;
  }
  const total = (await listFiles(folder)).length;
  toast(failed ? "warn" : "success", "Upload finished",
    `${images.length - failed} uploaded${failed ? `, ${failed} failed` : ""}; input/${folder} now has ${total} image(s).`);
}

function pickFiles(node) {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = "image/png,image/jpeg,image/webp";
  input.multiple = true;
  input.onchange = () => uploadFiles(node, input.files).catch((e) => toast("error", "Upload failed", String(e)));
  input.click();
}

// Queue one job per image so each result shows up as soon as it is done.
async function runAll(node) {
  const folder = widget(node, "folder").value;
  const files = await listFiles(folder);
  if (!files.length) {
    toast("warn", "No images", `input/${folder} has no images. Use Upload images first.`);
    return;
  }
  const index = widget(node, "index");
  const start = index.value;
  for (let i = 0; i < files.length; i++) {
    index.value = i;
    await app.queuePrompt(0, 1);
  }
  index.value = start;
  node.setDirtyCanvas?.(true, true);
  toast("success", `Queued ${files.length} job(s)`, `One per image in input/${folder}; results appear as each finishes.`);
}

app.registerExtension({
  name: "BatchImageFolder",
  async beforeRegisterNodeDef(nodeType, nodeData) {
    if (nodeData.name !== NODE_TYPE) return;
    const onNodeCreated = nodeType.prototype.onNodeCreated;
    nodeType.prototype.onNodeCreated = function () {
      const r = onNodeCreated?.apply(this, arguments);
      this.addWidget("button", "Upload images…", null, () => pickFiles(this), { serialize: false });
      this.addWidget("button", "Run all images in folder", null,
        () => runAll(this).catch((e) => toast("error", "Couldn't queue the folder", String(e))), { serialize: false });
      this.addWidget("button", "Manage folder images…", null, async () => {
        const { openImageManager } = await import("../server_image_manager/server_image_manager.js");
        openImageManager({ root: "input", kind: "image", folder: widget(this, "folder").value });
      }, { serialize: false });
      return r;
    };
  },
});
