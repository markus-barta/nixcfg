/* OPS-496: execute the shipped script with a minimal DOM and mocked transport.
 * This tests behavior without a browser, sockets, devices or external packages.
 * Rendered geometry/CSP enforcement still requires Tick's browser QA. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const html = fs.readFileSync(
  path.join(__dirname, "../hosts/hsb1/aqara-nightlight-page.html"),
  "utf8",
);
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const flush = () => new Promise((resolve) => setImmediate(resolve));
const defaults = {
  plug: { nacht: { rgb: "FDEDC9", bri: 3 } },
  round: { nacht: { rgb: "FDEDC9", bri: 3 } },
};
const response = (value, status = 200) => ({
  ok: status === 200,
  status,
  json: async () => value,
});
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
class Element {
  constructor(attrs = {}) {
    this.attrs = { ...attrs };
    this.listeners = {};
    this.children = [];
    this.nested = new Map();
    this.dataset = {};
    this.properties = {};
    this.classList = { add() {}, remove() {} };
    this.style = {
      setProperty: (key, value) => (this.properties[key] = value),
    };
    this.hidden = Object.hasOwn(attrs, "hidden");
    this.value = attrs.value || "";
    this.title = attrs.title || "";
    this.textContent = "";
    for (const [key, value] of Object.entries(attrs)) {
      if (key.startsWith("data-"))
        this.dataset[
          key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())
        ] = value;
    }
  }
  setAttribute(key, value) {
    this.attrs[key] = value;
  }
  getAttribute(key) {
    return this.attrs[key];
  }
  addEventListener(key, fn) {
    (this.listeners[key] ||= []).push(fn);
  }
  fire(key, attrs = {}) {
    const event = { button: 0, pointerId: 1, preventDefault() {}, ...attrs };
    return Promise.all((this.listeners[key] || []).map((fn) => fn(event)));
  }
  querySelector(key) {
    if (!this.nested.has(key)) this.nested.set(key, new Element());
    return this.nested.get(key);
  }
  querySelectorAll(key) {
    return [this.querySelector(key)];
  }
  closest(key) {
    return this.querySelector(key);
  }
  replaceChildren(...children) {
    this.children = children;
  }
  append(...children) {
    this.children.push(...children);
  }
  focus() {}
  setPointerCapture() {}
  close() {
    this.open = false;
  }
  showModal() {
    this.open = true;
  }
}
async function setup(stored = {}, storageFails = false) {
  const elements = [];
  for (const match of html.matchAll(/<([\w-]+)\b([^>]*?)>/g)) {
    if (match[1] === "script") break;
    const attrs = {};
    for (const a of match[2].matchAll(/([\w-]+)(?:="([^"]*)")?/g))
      attrs[a[1]] = a[2] ?? "";
    elements.push(new Element(attrs));
  }
  const byId = new Map(
    elements.filter((e) => e.attrs.id).map((e) => [e.attrs.id, e]),
  );
  const root = elements.find((e) => e.attrs.lang === "de");
  const storage = new Map(Object.entries(stored));
  const queries = new Map();
  const document = {
    documentElement: root,
    getElementById: (id) => {
      assert.ok(byId.has(id), `missing actual page id ${id}`);
      return byId.get(id);
    },
    querySelectorAll: (selector) => {
      const key = selector.match(/^\[([\w-]+)\]$/)?.[1];
      assert.ok(key, `unhandled DOM query ${selector}`);
      return elements.filter((e) => Object.hasOwn(e.attrs, key));
    },
    querySelector: (selector) => {
      const hub = selector.match(/^\[data-hub="([^"]+)"\]$/)?.[1];
      if (hub) return elements.find((e) => e.dataset.hub === hub);
      if (!queries.has(selector)) queries.set(selector, new Element());
      return queries.get(selector);
    },
    createElement: () => new Element(),
    createTextNode: (text) => text,
  };
  const calls = [],
    pending = [],
    timers = new Map();
  let time = 0,
    timerId = 0;
  const context = vm.createContext({
    document,
    URLSearchParams,
    console,
    localStorage: {
      getItem(key) {
        if (storageFails) throw new Error("disabled");
        return storage.get(key) ?? null;
      },
      setItem(key, value) {
        if (storageFails) throw new Error("disabled");
        storage.set(key, value);
      },
    },
    location: { reload() {} },
    setTimeout(fn, delay) {
      const id = ++timerId;
      timers.set(id, { fn, at: time + delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    fetch(url, options) {
      const u = new URL(url, "http://hsb1:8765");
      calls.push({ path: u.pathname, params: u.searchParams, options });
      if (pending.length) return pending.shift()(u, options);
      if (u.pathname === "/presets")
        return Promise.resolve(
          response({ ok: true, presets: structuredClone(defaults) }),
        );
      if (u.pathname === "/get")
        return Promise.resolve(
          response({
            ok: true,
            rgb: "FDEDC9",
            brightness: 3,
            illumination: 24,
          }),
        );
      const rgb = u.searchParams.get("rgb") || "FDEDC9",
        bri = Number(u.searchParams.get("bri") ?? 3);
      return Promise.resolve(
        response({ ok: true, rgb, brightness: bri, versuche: 1 }),
      );
    },
  });
  vm.runInContext(script, context, { filename: "shipped-nightlight.js" });
  await flush();
  function tick(delta) {
    time += delta;
    for (const [id, timer] of [...timers])
      if (timer.at <= time) {
        timers.delete(id);
        timer.fn();
      }
  }
  return {
    root,
    context,
    calls,
    pending,
    storage,
    tick,
    el: (id) => byId.get(id),
    eval: (code) => vm.runInContext(code, context),
    buttons: (selector) => document.querySelectorAll(selector),
  };
}

test("first visit, remembered appearance and unavailable localStorage", async () => {
  const a = await setup();
  assert.equal(a.root.dataset.mode, "kind");
  assert.equal(a.eval("selected"), "KI-18FB");
  assert.match(a.el("readback").textContent, /≈.*24 lx/);
  assert.equal(a.el("save-nightlight").hidden, true);
  const b = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-theme": "light",
  });
  assert.equal(b.root.dataset.mode, "erwachsen");
  assert.equal(b.root.dataset.theme, "light");
  const c = await setup({}, true);
  await c.el("theme").fire("click");
  assert.equal(c.root.dataset.theme, "light");
  assert.equal(c.root.dataset.mode, "kind");
});

test("Kind requires a full hold, cancellation works and Erwachsen returns by tap", async () => {
  const a = await setup(),
    mode = a.el("mode");
  await mode.fire("click");
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("pointerdown");
  a.tick(999);
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("pointercancel");
  a.tick(1);
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("pointerdown");
  a.tick(1000);
  await mode.fire("pointerup");
  await mode.fire("click");
  assert.equal(a.root.dataset.mode, "erwachsen");
  assert.equal(a.storage.get("nightlight-mode"), "erwachsen");
  await mode.fire("click");
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("keydown", { key: " " });
  a.tick(1000);
  await mode.fire("keyup", { key: " " });
  assert.equal(a.root.dataset.mode, "erwachsen");
});

test("loud tones require hold in Kind and are closed on returning to Kind", async () => {
  const a = await setup(),
    button = a.el("loud-toggle"),
    list = a.el("alarm-list");
  await button.fire("click");
  assert.equal(list.hidden, true);
  await button.fire("pointerdown");
  a.tick(1000);
  await button.fire("pointerup");
  await button.fire("click");
  assert.equal(list.hidden, false);
  assert.equal(button.getAttribute("aria-expanded"), "true");
  a.eval('root.dataset.mode="erwachsen"; renderMode();');
  await button.fire("click");
  assert.equal(list.hidden, true);
  await button.fire("click");
  assert.equal(list.hidden, false);
  a.eval('root.dataset.mode="kind"; renderMode();');
  assert.equal(list.hidden, true);
});

test("brightness sends once on release and every acting fetch uses POST and header", async () => {
  const a = await setup();
  a.calls.length = 0;
  a.el("bri").value = "2";
  await a.el("bri").fire("input");
  assert.equal(a.calls.length, 0);
  await a.el("bri").fire("change");
  await flush();
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
  assert.equal(a.calls[0].params.get("bri"), "2");
  await a.el("nightlight").fire("click");
  await a.el("stop").fire("click");
  await a.buttons("[data-t]")[0].fire("click");
  await flush();
  assert.equal(
    a.calls.some((c) => c.path === "/apply"),
    true,
  );
  assert.equal(
    a.calls.some((c) => c.path === "/tone"),
    true,
  );
  for (const c of a.calls) {
    assert.equal(c.options.headers["X-Nightlight"], "1");
    assert.equal(c.options.mode, "same-origin");
    assert.equal(c.options.method, c.path === "/get" ? "GET" : "POST");
  }
});

test("late replies cannot replace newer command status, state or selected hub", async () => {
  const a = await setup(),
    first = deferred(),
    second = deferred();
  a.pending.push(
    () => first.promise,
    () => second.promise,
  );
  const p1 = a.eval(
    'command("/set", {hub:"plug",rgb:"FF0000",bri:5}, "Rot", {success:(r,t)=>acceptLight(r,t,"Rot")})',
  );
  assert.match(a.el("status-text").textContent, /wird gesendet/);
  const p2 = a.eval('command("/stop", {hub:"plug"}, "Stopp")');
  second.resolve(response({ ok: true, versuche: 3 }));
  await p2;
  assert.match(
    a.el("status-text").textContent,
    /Stopp.*angekommen nach 3 Versuchen/,
  );
  const latest = a.el("status-text").textContent;
  first.resolve(response({ ok: true, rgb: "FF0000", brightness: 5 }));
  await p1;
  assert.equal(a.el("status-text").textContent, latest);
  assert.equal(a.eval("state().rgb"), "FDEDC9");
  const third = deferred();
  a.pending.push(() => third.promise);
  const p3 = a.eval('command("/stop",{hub:"plug"},"Stopp")');
  a.eval('selectHub("EZ-594F")');
  third.resolve(response({ ok: true }));
  await p3;
  assert.match(a.el("status-text").textContent, /Bereit · EZ-594F/);
});

test("403 HTML becomes reload-only rejection and disables retries", async () => {
  const a = await setup();
  let decoded = false;
  a.pending.push(() =>
    Promise.resolve({
      ok: false,
      status: 403,
      json() {
        decoded = true;
        throw new Error("HTML");
      },
    }),
  );
  await a.eval('command("/stop",{hub:"plug"},"Stopp")');
  assert.equal(decoded, false);
  assert.equal(
    a.el("status-text").textContent,
    "Vom Server abgelehnt · Seite neu laden",
  );
  assert.equal(a.el("retry").hidden, true);
  assert.equal(a.el("reload").hidden, false);
  const calls = a.calls.length;
  await a.el("retry").fire("click");
  await a.el("stop").fire("click");
  a.tick(100000);
  assert.equal(a.calls.length, calls);
});

test("device timeout and transport loss offer only manual retry", async () => {
  const a = await setup();
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: false,
        error: "Hub oder Dienst nicht erreichbar; erneut versuchen",
      }),
    ),
  );
  await a.eval('command("/set",{hub:"plug",rgb:"FDEDC9",bri:3},"Nachtlicht")');
  assert.match(a.el("status-text").textContent, /KI-18FB antwortet nicht/);
  assert.equal(a.el("retry").hidden, false);
  const before = a.calls.length;
  a.tick(100000);
  assert.equal(a.calls.length, before);
  a.pending.push(() => Promise.reject(new Error("offline")));
  await a.el("retry").fire("click");
  await flush();
  assert.equal(
    a.el("status-text").textContent,
    "Keine Verbindung zum Nachtlicht-Server",
  );
  assert.equal(a.el("retry").hidden, false);
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: false,
        error: "Hub oder Dienst nicht erreichbar; erneut versuchen",
      }),
    ),
  );
  await a.eval('command("/apply",{hub:"plug",preset:"nacht"},"Nachtlicht")');
  assert.match(a.el("status-text").textContent, /KI-18FB antwortet nicht/);
});

test("color hint implements channel floor and suppresses near white or ordinary brightness", async () => {
  const a = await setup();
  const hint = a.eval('shiftHint("FF8C28",2,"Warmweiß")');
  assert.equal(hint.rgb, "ff0000");
  assert.match(hint.text, /Bei 2 % wirkt Warmweiß fast rot/);
  for (const expression of [
    'shiftHint("FDEDC9",3,"Nachtlicht")',
    'shiftHint("FFFFFF",2,"Weiß")',
    'shiftHint("FF8C28",10,"Warmweiß")',
    'shiftHint("FF8C28",0,"Warmweiß")',
  ])
    assert.equal(a.eval(expression), null);
});

test("confirm, reset and Undo persist the captured hub preset without a lamp command", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  a.eval(
    'acceptLight({rgb:"FFB46B",brightness:5},"KI-18FB","Hellwarm"); render();',
  );
  assert.equal(a.el("save-nightlight").hidden, false);
  await a.el("save-nightlight").fire("click");
  assert.equal(a.el("save-sheet").open, true);
  assert.match(a.el("old-preset").textContent, /FDEDC9/);
  assert.match(a.el("new-preset").textContent, /FFB46B/);
  a.pending.push((url) =>
    Promise.resolve(
      response({
        ok: true,
        presets: {
          ...structuredClone(defaults),
          plug: {
            nacht: {
              rgb: url.searchParams.get("rgb"),
              bri: Number(url.searchParams.get("bri")),
            },
          },
        },
      }),
    ),
  );
  await a.el("confirm-save").fire("click");
  await flush();
  assert.equal(a.calls.at(-1).path, "/preset");
  assert.equal(a.calls.at(-1).params.get("hub"), "plug");
  assert.equal(a.calls.at(-1).params.get("rgb"), "FFB46B");
  assert.equal(a.el("undo").hidden, false);
  a.pending.push(() =>
    Promise.resolve(response({ ok: true, presets: structuredClone(defaults) })),
  );
  await a.el("undo").fire("click");
  await flush();
  assert.equal(a.calls.at(-1).params.get("rgb"), "FDEDC9");
  assert.equal(a.calls.at(-1).params.get("bri"), "3");
  await a.el("save-nightlight").fire("click");
  a.pending.push(() =>
    Promise.resolve(response({ ok: true, presets: structuredClone(defaults) })),
  );
  await a.el("reset-preset").fire("click");
  await flush();
  assert.equal(a.calls.at(-1).params.get("reset"), "1");
  assert.equal(a.calls.at(-1).options.method, "POST");
  assert.match(
    a.el("status-text").textContent,
    /Nachtlicht gespeichert · KI-18FB/,
  );
});

test("apply uses the server preset and updates its preview after an external save", async () => {
  const a = await setup();
  a.pending.push(() =>
    Promise.resolve(
      response({ ok: true, rgb: "FFB46B", brightness: 5, versuche: 2 }),
    ),
  );
  await a.el("nightlight").fire("click");
  assert.equal(a.eval("presetFor().rgb"), "FFB46B");
  assert.equal(a.eval("presetFor().bri"), 5);
  assert.equal(a.eval("state().last.rgb"), "FFB46B");
  assert.match(
    a.el("status-text").textContent,
    /Nachtlicht.*angekommen nach 2 Versuchen/,
  );
});
