import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const COMMAND_ID = "ServerImageManager.Open";
const enc = encodeURIComponent;

function toast(severity, summary, detail, life = 6000) {
  app.extensionManager?.toast?.add({ severity, summary, detail, life });
}

const CSS = `
.sim-overlay { position: fixed; inset: 0; z-index: 10000; background: rgba(0,0,0,.6); display: flex; align-items: center; justify-content: center; }
.sim-panel { width: min(1200px, 96vw); height: min(860px, 92vh); display: flex; flex-direction: column; background: var(--comfy-menu-bg, #202020);
  color: var(--fg-color, #ddd); border: 1px solid var(--border-color, #444); border-radius: 10px; overflow: hidden; font-size: 13px; }
.sim-bar { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 1px solid var(--border-color, #444); flex-wrap: wrap; }
.sim-bar.sim-foot { border-bottom: 0; border-top: 1px solid var(--border-color, #444); }
.sim-title { font-weight: 600; font-size: 15px; margin-right: 8px; }
.sim-spacer { flex: 1; }
.sim-panel button, .sim-panel select { background: var(--comfy-input-bg, #2a2a2a); color: inherit; border: 1px solid var(--border-color, #444);
  border-radius: 6px; padding: 5px 10px; font: inherit; cursor: pointer; }
.sim-panel button:disabled { opacity: .45; cursor: default; }
.sim-panel button.sim-on { border-color: #4a90e2; background: rgba(74,144,226,.25); }
.sim-panel button.sim-danger { background: #8b2020; border-color: #b33; color: #fff; }
.sim-body { flex: 1; display: flex; min-height: 0; }
.sim-grid { flex: 1; overflow: auto; padding: 10px; display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
  grid-auto-rows: max-content; gap: 10px; align-content: start; scrollbar-color: var(--border-color, #555) transparent; } /* rows stay tile-height so the grid scrolls instead of squashing */
.sim-tile { position: relative; border: 2px solid transparent; border-radius: 8px; cursor: pointer; background: var(--comfy-input-bg, #2a2a2a); overflow: hidden; }
.sim-tile.sim-current { border-color: #4a90e2; }
.sim-tile.sim-picked { border-color: #d44; }
.sim-tile img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; }
.sim-tile .sim-play { position: absolute; top: 6px; right: 6px; padding: 1px 6px; border-radius: 4px; background: rgba(0,0,0,.65); color: #fff; font-size: 11px; pointer-events: none; }
.sim-tile .sim-name { padding: 4px 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 11px; opacity: .85; }
.sim-tile input { position: absolute; top: 6px; left: 6px; width: 18px; height: 18px; cursor: pointer; }
.sim-preview { width: 42%; min-width: 280px; border-left: 1px solid var(--border-color, #444); display: flex; flex-direction: column; padding: 10px; gap: 8px; }
.sim-preview .sim-big { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,.25); border-radius: 8px; }
.sim-preview .sim-big img, .sim-preview .sim-big video { max-width: 100%; max-height: 100%; object-fit: contain; }
.sim-meta { font-size: 12px; opacity: .85; word-break: break-all; }
.sim-empty { padding: 30px; opacity: .7; grid-column: 1 / -1; text-align: center; }
.sim-confirm { flex: 1; overflow: auto; padding: 16px; }
.sim-confirm .sim-grid { padding: 10px 0; overflow: visible; }
@media (max-width: 760px) { .sim-body { flex-direction: column; } .sim-preview { width: auto; min-width: 0; height: 45%; border-left: 0; border-top: 1px solid var(--border-color, #444); } }
`;

function el(tag, attrs = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "class") e.className = v;
    else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? "" : v);
  }
  e.append(...children.filter((c) => c !== null && c !== undefined));
  return e;
}

const splitPath = (p) => {
  const i = p.lastIndexOf("/");
  return i < 0 ? ["", p] : [p.slice(0, i), p.slice(i + 1)];
};
const viewUrl = (root, p) => {
  const [sub, name] = splitPath(p);
  return api.apiURL(`/view?filename=${enc(name)}&subfolder=${enc(sub)}&type=${root}`);
};
const thumbUrl = (root, item) => api.apiURL(`/server_images/thumb?root=${root}&path=${enc(item.path)}&v=${item.mtime}`);
const fmtTime = (s) => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, "0")}`;
const fmtSize = (b) => (b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.ceil(b / 1e3)} KB`);

/** Open the image manager. root: "input" | "output"; folder: "" for all, "." for top level, or a subfolder. */
export function openImageManager({ root = "input", folder = "", kind = "" } = {}) {
  if (!document.getElementById("sim-style")) document.head.append(el("style", { id: "sim-style" }, CSS));
  document.querySelector(".sim-overlay")?.remove();

  const state = { root, folder, kind, images: [], picked: new Set(), current: null, confirming: false };
  const overlay = el("div", { class: "sim-overlay", onclick: (e) => e.target === overlay && close() });
  const panel = el("div", { class: "sim-panel", role: "dialog", "aria-label": "Server files" });
  overlay.append(panel);
  const onKey = (e) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      state.confirming ? ((state.confirming = false), render()) : close();
    }
  };
  function close() {
    document.removeEventListener("keydown", onKey, true);
    overlay.remove();
  }
  document.addEventListener("keydown", onKey, true);
  document.body.append(overlay);

  const shown = () =>
    state.images.filter((i) => {
      if (state.kind && i.kind !== state.kind) return false;
      if (!state.folder) return true;
      const [sub] = splitPath(i.path);
      return state.folder === "." ? sub === "" : sub === state.folder || sub.startsWith(state.folder + "/");
    });

  async function load() {
    const resp = await api.fetchApi(`/server_images/list?root=${state.root}`);
    state.images = (await resp.json()).images ?? [];
    const paths = new Set(state.images.map((i) => i.path));
    state.picked = new Set([...state.picked].filter((p) => paths.has(p)));
    if (state.current && !paths.has(state.current)) state.current = null;
    render();
  }

  async function doDelete(paths) {
    const resp = await api.fetchApi("/server_images/delete", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ root: state.root, paths }),
    });
    const r = await resp.json();
    for (const e of r.errors ?? []) toast("error", `Couldn't delete ${e.path}`, e.error, 12000);
    if (r.deleted?.length) toast("success", `Deleted ${r.deleted.length} file(s)`, `from ${state.root}/`);
    state.confirming = false;
    for (const p of r.deleted ?? []) state.picked.delete(p);
    await load();
    app.refreshComboInNodes?.();
  }

  function tile(item, { selectable = true } = {}) {
    const [, name] = splitPath(item.path);
    const picked = state.picked.has(item.path);
    const box = selectable
      ? el("input", {
          type: "checkbox", title: "Select for deletion", checked: picked,
          onclick: (e) => {
            e.stopPropagation();
            e.target.checked ? state.picked.add(item.path) : state.picked.delete(item.path);
            render();
          },
        })
      : null;
    return el("div", {
        class: `sim-tile${state.current === item.path && selectable ? " sim-current" : ""}${picked && selectable ? " sim-picked" : ""}`,
        title: item.path,
        onclick: () => { state.current = item.path; render(); },
      },
      el("img", { src: thumbUrl(state.root, item), loading: "lazy", alt: name }),
      item.kind === "video" ? el("span", { class: "sim-play" }, "▶ video") : null,
      box,
      el("div", { class: "sim-name" }, item.path));
  }

  function render() {
    panel.replaceChildren();
    const list = shown();
    const folders = [...new Set(state.images.map((i) => splitPath(i.path)[0]).filter(Boolean))].sort();
    if (state.folder && state.folder !== "." && !folders.includes(state.folder)) folders.push(state.folder);

    if (state.confirming) {
      const items = state.images.filter((i) => state.picked.has(i.path));
      panel.append(
        el("div", { class: "sim-bar" }, el("span", { class: "sim-title" }, `Delete ${items.length} file(s) from ${state.root}/?`)),
        el("div", { class: "sim-confirm" },
          el("div", {}, "These files will be permanently removed from the server. This can't be undone."),
          el("div", { class: "sim-grid" }, ...items.map((i) => tile(i, { selectable: false })))),
        el("div", { class: "sim-bar sim-foot" },
          el("span", { class: "sim-spacer" }),
          el("button", { onclick: () => { state.confirming = false; render(); } }, "Cancel"),
          el("button", { class: "sim-danger", onclick: (e) => { e.target.disabled = true; doDelete(items.map((i) => i.path)); } },
            `Delete ${items.length} permanently`)));
      return;
    }

    const tab = (r, label) =>
      el("button", { class: state.root === r ? "sim-on" : "", onclick: () => {
        if (state.root === r) return;
        Object.assign(state, { root: r, folder: "", picked: new Set(), current: null });
        load();
      } }, label);
    const select = el("select", { onchange: (e) => { state.folder = e.target.value; render(); } },
      el("option", { value: "" }, "All folders"),
      el("option", { value: "." }, "Top level only"),
      ...folders.map((f) => el("option", { value: f }, f)));
    select.value = state.folder;
    const kindSelect = el("select", { onchange: (e) => { state.kind = e.target.value; render(); } },
      el("option", { value: "" }, "Images and videos"),
      el("option", { value: "image" }, "Images only"),
      el("option", { value: "video" }, "Videos only"));
    kindSelect.value = state.kind;

    panel.append(el("div", { class: "sim-bar" },
      el("span", { class: "sim-title" }, "Server files"),
      tab("input", "Imported (input)"), tab("output", "Generated (output)"), select, kindSelect,
      el("span", {}, `${list.length} file(s)`),
      el("span", { class: "sim-spacer" }),
      el("button", { onclick: load, title: "Reload the list" }, "Refresh"),
      el("button", { onclick: close, "aria-label": "Close" }, "✕")));

    const grid = el("div", { class: "sim-grid" },
      ...(list.length ? list.map((i) => tile(i)) : [el("div", { class: "sim-empty" }, "Nothing here.")]));

    const cur = state.images.find((i) => i.path === state.current);
    let preview;
    if (cur) {
      const meta = el("div", { class: "sim-meta" }, `${state.root}/${cur.path} · ${fmtSize(cur.size)} · ${new Date(cur.mtime * 1000).toLocaleString()}`);
      const big = cur.kind === "video"
        ? el("video", { src: viewUrl(state.root, cur.path), controls: true, preload: "metadata",
            onloadedmetadata: (e) => meta.append(` · ${e.target.videoWidth}×${e.target.videoHeight} · ${fmtTime(e.target.duration)}`) })
        : el("img", { src: viewUrl(state.root, cur.path), alt: cur.path,
            onload: (e) => meta.append(` · ${e.target.naturalWidth}×${e.target.naturalHeight}`) });
      preview = el("div", { class: "sim-preview" }, el("div", { class: "sim-big" }, big), meta,
        el("div", { class: "sim-bar", style: "padding:0;border:0" },
          el("button", { onclick: () => { state.picked = new Set([cur.path]); state.confirming = true; render(); } }, `Delete this ${cur.kind}…`)));
    } else {
      preview = el("div", { class: "sim-preview" }, el("div", { class: "sim-big" }, el("span", { class: "sim-meta" }, "Click a file to preview it")));
    }
    panel.append(el("div", { class: "sim-body" }, grid, preview));

    const pickedShown = list.filter((i) => state.picked.has(i.path)).length;
    panel.append(el("div", { class: "sim-bar sim-foot" },
      el("button", { disabled: !list.length, onclick: () => { list.forEach((i) => state.picked.add(i.path)); render(); } }, "Select all shown"),
      el("button", { disabled: !state.picked.size, onclick: () => { state.picked.clear(); render(); } }, "Clear selection"),
      el("span", { class: "sim-spacer" }),
      el("span", {}, state.picked.size ? `${state.picked.size} selected${pickedShown !== state.picked.size ? ` (${pickedShown} shown)` : ""}` : ""),
      el("button", { class: "sim-danger", disabled: !state.picked.size, onclick: () => { state.confirming = true; render(); } },
        `Delete selected (${state.picked.size})…`)));
  }

  render();
  load().catch((e) => toast("error", "Couldn't list images", String(e)));
}

app.registerExtension({
  name: "ServerImageManager",
  commands: [{ id: COMMAND_ID, label: "Manage server images and videos", icon: "pi pi-images", function: () => openImageManager() }],
  menuCommands: [{ path: ["Extensions"], commands: [COMMAND_ID] }],
});
