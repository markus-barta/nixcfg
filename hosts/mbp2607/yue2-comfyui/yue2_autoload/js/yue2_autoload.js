import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const FLAG = "yue2_autoload_v1";
// ComfyUI's /userdata/{file} route takes ONE path segment, so the slash in
// "workflows/…" must be URL-encoded. api.getUserData does exactly that (the
// raw "/userdata/workflows/…" URLs used before never matched — NIX-518 gate).
const CANDIDATES = ["workflows/yue2_full.json", "workflows/YuE2 Full.json"];

async function fetchWorkflow() {
  for (const file of CANDIDATES) {
    try {
      const res = await api.getUserData(file, { cache: "no-store" });
      if (!res.ok) continue;
      const data = await res.json();
      if (data && (data.nodes || data.workflow)) return data;
    } catch (_) {
      /* try next */
    }
  }
  return null;
}

app.registerExtension({
  name: "yue2.autoload",
  async setup() {
    // Always prefer the music graph over a restored image/default workflow.
    if (window.__yue2AutoloadBusy) return;
    window.__yue2AutoloadBusy = true;
    try {
      const data = await fetchWorkflow();
      if (!data) {
        console.warn("[yue2] music workflow not found in userdata");
        return;
      }
      const graph = data.workflow || data;
      if (typeof app.loadGraphData === "function") {
        await app.loadGraphData(graph);
      } else if (app.graph && typeof app.graph.configure === "function") {
        app.graph.clear?.();
        app.graph.configure(graph);
      }
      sessionStorage.setItem(FLAG, "1");
      console.log("[yue2] loaded yue2_full music workflow");
    } catch (err) {
      console.warn("[yue2] autoload failed", err);
    } finally {
      window.__yue2AutoloadBusy = false;
    }
  },
});
