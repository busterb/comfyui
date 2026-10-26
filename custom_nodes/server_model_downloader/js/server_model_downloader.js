import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const COMMAND_ID = "ServerModelDownloader.DownloadMissing";

// Gather {name, url, directory} entries from the workflow, its nodes and subgraphs.
function collectModels() {
  const found = new Map();
  const add = (list) => {
    for (const m of list ?? []) {
      if (m?.name && m?.url && m?.directory) found.set(`${m.directory}/${m.name}`, m);
    }
  };
  const walk = (nodes) => {
    for (const n of nodes ?? []) add(n.properties?.models);
  };
  const wf = app.graph.serialize();
  add(wf.models);
  walk(wf.nodes);
  for (const sg of wf.definitions?.subgraphs ?? []) walk(sg.nodes);
  const active = app.extensionManager?.workflow?.activeWorkflow;
  add(active?.initialState?.models);
  add(active?.activeState?.models);
  return [...found.values()];
}

function toast(severity, summary, detail, life = 6000) {
  app.extensionManager?.toast?.add({ severity, summary, detail, life });
}

const fmt = (b) => (b / 1024 ** 3).toFixed(2) + " GB";

function panel() {
  let el = document.getElementById("server-model-downloader");
  if (!el) {
    el = document.createElement("div");
    el.id = "server-model-downloader";
    Object.assign(el.style, {
      position: "fixed", right: "16px", bottom: "16px", zIndex: 10000, maxWidth: "460px",
      padding: "10px 12px", borderRadius: "8px", font: "12px monospace", whiteSpace: "pre-wrap",
      background: "var(--comfy-menu-bg, #222)", color: "var(--fg-color, #ddd)",
      border: "1px solid var(--border-color, #444)",
    });
    document.body.appendChild(el);
  }
  return el;
}

async function watch(ids) {
  const el = panel();
  for (;;) {
    const jobs = (await (await api.fetchApi("/server_models/status")).json()).filter((j) => ids.has(j.id));
    el.textContent = "Server model downloads\n" + jobs.map((j) => {
      const pct = j.total ? ` ${((100 * j.done) / j.total).toFixed(0)}% of ${fmt(j.total)}` : j.done ? ` ${fmt(j.done)}` : "";
      return `${j.state.padEnd(11)} ${j.directory}/${j.name}${j.state === "downloading" ? pct : ""}${j.error ? `\n            ${j.error}` : ""}`;
    }).join("\n");
    if (jobs.every((j) => j.state === "complete" || j.state === "error")) {
      const failed = jobs.filter((j) => j.state === "error").length;
      toast(failed ? "warn" : "success", "Model downloads finished",
        `${jobs.length - failed} downloaded${failed ? `, ${failed} failed (see panel / server log)` : ""}`);
      await app.refreshComboInNodes?.();
      setTimeout(() => el.remove(), failed ? 30000 : 5000);
      return;
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
}

async function downloadMissing() {
  const models = collectModels();
  if (!models.length) {
    toast("info", "No model links", "This workflow has no embedded model download links.");
    return;
  }
  const resp = await api.fetchApi("/server_models/download", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ models }),
  });
  if (!resp.ok) {
    toast("error", "Server download failed", await resp.text());
    return;
  }
  const results = await resp.json();
  const errors = results.filter((r) => r.state === "error");
  for (const e of errors) toast("error", `Can't download ${e.name}`, e.error, 15000);
  const ids = new Set(results.filter((r) => r.id).map((r) => r.id));
  if (!ids.size) {
    if (!errors.length) toast("success", "Nothing to download", "All models in this workflow are already on the server.");
    return;
  }
  toast("info", "Downloading on server", `${ids.size} model(s) queued`);
  watch(ids);
}

app.registerExtension({
  name: "ServerModelDownloader",
  commands: [{ id: COMMAND_ID, label: "Download missing models to server", icon: "pi pi-download", function: downloadMissing }],
  menuCommands: [{ path: ["Extensions"], commands: [COMMAND_ID] }],
});
