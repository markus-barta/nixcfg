import { app } from "../../scripts/app.js";

const FLAG = "yue2_autoload_v1";
const CANDIDATES = [
  "/api/userdata/workflows/yue2_full.json",
  "/userdata/workflows/yue2_full.json",
  "/api/userdata/workflows/YuE2%20Full.json",
  "/userdata/workflows/YuE2%20Full.json",
];

async function fetchWorkflow() {
  for (const url of CANDIDATES) {
    try {
      const res = await fetch(url, { cache: "no-store" });
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
