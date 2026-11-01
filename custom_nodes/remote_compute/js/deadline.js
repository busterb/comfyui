// Warn before the compute server deletes itself (a rented cloud GPU's time limit): once when the page loads,
// then 10 and 2 minutes before. The server reports the limit at /remote_compute/deadline; on a client
// (remote.sh) that request goes to the compute server. Machines without a limit report null: no toasts.
import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const WARN_MINUTES = [10, 2];

function toast(severity, summary, detail, life) {
  app.extensionManager?.toast?.add({ severity, summary, detail, life });
}

function clock(t) {
  return new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

let announced = null; // the deadline last shown
let warned = Infinity; // the smallest warning threshold already shown for it

async function check() {
  let info;
  try {
    const resp = await api.fetchApi("/remote_compute/deadline");
    if (!resp.ok) return;
    info = await resp.json();
  } catch {
    return; // compute server unreachable: the job errors will say so
  }
  if (!info.deadline) return;
  // Minutes left by the server's clock, so a skewed browser clock doesn't matter
  const left = Math.floor((info.deadline - info.now) / 60);
  const hint = info.hint ? ` ${info.hint}.` : "";
  if (info.deadline !== announced) { // first look, or extended
    const extended = announced !== null && info.deadline > announced;
    announced = info.deadline;
    warned = Infinity;
    toast("info", extended ? "Compute server time limit extended" : "Compute server time limit",
      `The compute server deletes itself at ${clock(info.deadline)} (in ${left} min).${hint}`, 8000);
  }
  const due = Math.min(...WARN_MINUTES.filter((m) => left <= m)); // the tightest threshold passed
  if (due < warned) {
    warned = due;
    toast("warn", `Compute server: ${Math.max(left, 0)} min left`,
      `It deletes itself at ${clock(info.deadline)}; jobs still running then are lost.${hint}`); // stays until closed
  }
}

app.registerExtension({
  name: "RemoteCompute.Deadline",
  setup() {
    check();
    setInterval(check, 60 * 1000);
  },
});
