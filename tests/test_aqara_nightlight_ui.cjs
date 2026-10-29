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
  plug: { nacht: { rgb: "5C0701", bri: 44 } },
  round: { nacht: { rgb: "5C0701", bri: 44 } },
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
    const classes = new Set((attrs.class || "").split(/\s+/));
    this.classList = {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
      toggle(name, on = !classes.has(name)) {
        if (on) classes.add(name);
        else classes.delete(name);
        return on;
      },
    };
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
async function setup(stored = {}, storageFails = false, initial = {}) {
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
  const documentEvents = new Element();
  const document = {
    addEventListener: (...args) => documentEvents.addEventListener(...args),
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
    AbortController,
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
      if (initial[u.pathname]) return initial[u.pathname](u, options);
      if (pending.length) return pending.shift()(u, options);
      if (u.pathname === "/presets")
        return Promise.resolve(
          response({ ok: true, presets: structuredClone(defaults) }),
        );
      if (u.pathname === "/get")
        return Promise.resolve(
          response({
            ok: true,
            rgb: "FF8C28",
            brightness: 40,
            illumination: 24,
          }),
        );
      const rgb = u.searchParams.get("rgb") || "5C0701",
        bri = Number(u.searchParams.get("bri") ?? 44);
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
    documentEvents,
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
  assert.equal(a.el("bri").value, 40);
  assert.equal(a.el("bri").disabled, false);
  assert.equal(a.el("last-light").textContent, "Zuletzt: noch kein Befehl");
  for (const button of [
    a.el("nightlight"),
    a.el("off"),
    a.el("own-color"),
    ...a.buttons("[data-preset]"),
    ...a.buttons("[data-color]"),
  ])
    assert.equal(button.getAttribute("aria-pressed"), "false");
  assert.match(a.el("readback").textContent, /≈.*24 lx/);
  assert.equal(a.el("save-nightlight").hidden, true);
  assert.equal(a.el("mode-hint").textContent, "");
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
  assert.match(a.el("mode-hint").textContent, /1 Sekunde/);
  assert.equal(mode.classList.contains("holding"), false);
  a.tick(2500);
  assert.equal(a.el("mode-hint").textContent, "");
  await mode.fire("pointerdown");
  assert.equal(mode.classList.contains("holding"), true);
  assert.match(a.el("mode-hint").textContent, /1 Sekunde/);
  a.tick(999);
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("pointercancel");
  assert.equal(mode.classList.contains("holding"), false);
  assert.equal(a.el("mode-hint").textContent, "");
  a.tick(1);
  assert.equal(a.root.dataset.mode, "kind");
  await mode.fire("pointerdown");
  a.tick(1000);
  await mode.fire("pointerup");
  await mode.fire("click");
  assert.equal(a.root.dataset.mode, "erwachsen");
  assert.equal(a.el("mode-hint").textContent, "");
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

test("late replies preserve confirmed light effects without replacing newer status or hub", async () => {
  const a = await setup(),
    first = deferred(),
    second = deferred();
  a.pending.push(
    () => first.promise,
    () => second.promise,
  );
  const p1 = a.eval(
    'command("/set", {hub:"plug",rgb:"FF0000",bri:5}, "Rot", {success:(r,t,n)=>acceptLight(r,t,"Rot",n)})',
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
  assert.equal(a.eval("state().rgb"), "FF0000");
  assert.match(a.el("last-light").textContent, /Zuletzt: Rot.*5/);
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
  await a.eval('command("/set",{hub:"plug",rgb:"5C0701",bri:44},"Nachtlicht")');
  assert.equal(
    a.el("status-text").textContent,
    "KI-18FB antwortet nicht (4 Versuche)",
  );
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
    'shiftHint("5C0701",44,"Nachtlicht")',
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
  assert.match(a.el("old-preset").textContent, /5C0701/);
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
  assert.equal(a.calls.at(-1).params.get("rgb"), "5C0701");
  assert.equal(a.calls.at(-1).params.get("bri"), "44");
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

test("hub choice is remembered, validated and safe when storage is disabled", async () => {
  const a = await setup();
  a.eval('selectHub("EZ-594F")');
  await flush();
  assert.equal(a.storage.get("nightlight-hub"), "EZ-594F");
  const b = await setup(Object.fromEntries(a.storage));
  assert.equal(b.eval("selected"), "EZ-594F");
  assert.equal(
    b.calls.find((c) => c.path === "/get").params.get("hub"),
    "round",
  );
  assert.equal(b.el("status-text").textContent, "Bereit · EZ-594F");
  for (const hub of ["invalid", "__proto__", "constructor"]) {
    const c = await setup({ "nightlight-hub": hub });
    assert.equal(c.eval("selected"), "KI-18FB");
    c.eval('selectHub("invalid")');
    assert.equal(c.eval("selected"), "KI-18FB");
  }
  const d = await setup({ "nightlight-hub": "EZ-594F" }, true);
  assert.equal(d.eval("selected"), "KI-18FB");
  d.eval('selectHub("EZ-594F")');
  assert.equal(d.eval("selected"), "EZ-594F");
});

test("first readback initializes brightness without selecting or claiming a command", async () => {
  const readback = deferred();
  const a = await setup({}, false, { "/get": () => readback.promise });
  assert.equal(a.el("bri").disabled, true);
  assert.equal(a.el("bri-value").textContent, "—");
  assert.equal(a.el("nightlight").getAttribute("aria-pressed"), "false");
  assert.equal(a.el("last-light").textContent, "Zuletzt: noch kein Befehl");
  readback.resolve(
    response({ ok: true, rgb: "FF8C28", brightness: 40, illumination: 8 }),
  );
  await flush();
  assert.equal(a.el("bri").value, 40);
  assert.equal(a.eval("state().last"), null);
  assert.equal(
    a.buttons("[data-color]")[0].getAttribute("aria-pressed"),
    "false",
  );
  assert.equal(a.el("last-light").textContent, "Zuletzt: noch kein Befehl");
  assert.deepEqual(a.calls.map((c) => c.path).sort(), ["/get", "/presets"]);
});

test("every preset, swatch and tone button sends its own bound value", async () => {
  const a = await setup();
  for (const button of a.buttons("[data-preset]")) {
    const before = a.calls.length;
    await button.fire("click");
    await flush();
    const calls = a.calls.slice(before).filter((c) => c.path === "/set");
    assert.equal(calls.length, 1);
    const p = a.eval(`FIXED_PRESETS[${JSON.stringify(button.dataset.preset)}]`);
    assert.equal(calls[0].params.get("rgb"), p.rgb);
    assert.equal(calls[0].params.get("bri"), String(p.bri));
  }
  assert.equal(a.buttons("[data-preset]").length, 3);
  for (const button of a.buttons("[data-color]")) {
    const before = a.calls.length;
    await button.fire("click");
    await flush();
    const calls = a.calls.slice(before).filter((c) => c.path === "/set");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].params.get("rgb"), button.dataset.color);
  }
  assert.equal(a.buttons("[data-color]").length, 6);
  for (const button of a.buttons("[data-t]")) {
    const before = a.calls.length;
    await button.fire("click");
    const calls = a.calls.slice(before).filter((c) => c.path === "/tone");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].params.get("id"), button.dataset.t);
    assert.equal(calls[0].params.get("vol"), "15");
  }
  assert.equal(a.buttons("[data-t]").length, 25);
});

test("Stop fills only after a successful tone and stays filled until a successful Stop", async () => {
  const a = await setup(),
    tone = deferred();
  const stop = a.el("stop"),
    button = a.buttons("[data-t]")[0];
  assert.equal(stop.classList.contains("on"), false);
  a.pending.push(() => tone.promise);
  const playing = button.fire("click");
  assert.equal(stop.classList.contains("on"), false);
  tone.resolve(response({ ok: false, error: "Hub hat den Befehl abgelehnt" }));
  await playing;
  assert.equal(stop.classList.contains("on"), false);
  await button.fire("click");
  assert.equal(stop.classList.contains("on"), true);
  assert.equal(button.getAttribute("aria-pressed"), "true");
  const stopping = deferred();
  a.pending.push(() => stopping.promise);
  const pendingStop = stop.fire("click");
  assert.equal(stop.classList.contains("on"), true);
  stopping.resolve(
    response({ ok: false, error: "Hub hat den Befehl abgelehnt" }),
  );
  await pendingStop;
  assert.equal(stop.classList.contains("on"), true);
  await stop.fire("click");
  assert.equal(stop.classList.contains("on"), false);
  assert.equal(button.getAttribute("aria-pressed"), "false");
});

test("an old tone ACK cannot relight Stop after a newer Stop ACK", async () => {
  const a = await setup(),
    tone = deferred();
  a.pending.push(() => tone.promise);
  const old = a.buttons("[data-t]")[0].fire("click");
  await a.el("stop").fire("click");
  const latest = a.el("status-text").textContent;
  tone.resolve(response({ ok: true }));
  await old;
  assert.equal(a.el("stop").classList.contains("on"), false);
  assert.equal(a.eval("state().tone"), null);
  assert.equal(a.el("status-text").textContent, latest);
});

test("both startup requests failing use the server connection error and recover on Nochmal", async () => {
  let offline = true;
  const a = await setup({}, false, {
    "/presets": () =>
      offline
        ? Promise.reject(new TypeError("offline"))
        : Promise.resolve(
            response({ ok: true, presets: structuredClone(defaults) }),
          ),
    "/get": () =>
      offline
        ? Promise.reject(new TypeError("offline"))
        : Promise.resolve(
            response({
              ok: true,
              rgb: "FF8C28",
              brightness: 40,
              illumination: 24,
            }),
          ),
  });
  assert.equal(
    a.el("status-text").textContent,
    "Keine Verbindung zum Nachtlicht-Server",
  );
  assert.equal(a.el("retry").hidden, false);
  assert.equal(a.el("bri").disabled, true);
  offline = false;
  await a.el("retry").fire("click");
  await flush();
  assert.equal(a.eval("presetsReady"), true);
  assert.equal(a.el("bri").value, 40);
  assert.equal(a.el("bri").disabled, false);
});

test("hung fetch or response body aborts after 12 seconds with manual retry", async () => {
  for (const stage of ["fetch", "json"]) {
    const a = await setup();
    let signal;
    a.pending.push((_, options) => {
      signal = options.signal;
      const wait = () =>
        new Promise((_, reject) => {
          signal.addEventListener(
            "abort",
            () =>
              reject(
                Object.assign(new Error("aborted"), { name: "AbortError" }),
              ),
            { once: true },
          );
        });
      return stage === "fetch"
        ? wait()
        : Promise.resolve({ ok: true, status: 200, json: wait });
    });
    const action = a.el("stop").fire("click");
    await flush();
    a.tick(11999);
    assert.equal(signal.aborted, false);
    assert.match(a.el("status-text").textContent, /wird gesendet/);
    a.tick(1);
    await action;
    assert.equal(signal.aborted, true);
    assert.match(a.el("status-text").textContent, /KI-18FB antwortet nicht/);
    assert.equal(a.el("retry").hidden, false);
    const count = a.calls.length;
    a.tick(60000);
    assert.equal(a.calls.length, count);
    await a.el("retry").fire("click");
    await flush();
    assert.match(a.el("status-text").textContent, /Stopp.*angekommen/);
    const completed = a.calls.at(-1).options.signal;
    a.tick(12000);
    assert.equal(completed.aborted, false);
  }
});

test("structured hub errors use the design copy regardless of server wording", async () => {
  const a = await setup();
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: false,
        code: "hub_unavailable",
        attempts: 4,
        error: "Wording can change",
      }),
    ),
  );
  await a.el("stop").fire("click");
  assert.equal(
    a.el("status-text").textContent,
    "KI-18FB antwortet nicht (4 Versuche)",
  );
  assert.equal(a.el("retry").hidden, false);
});

test("late save keeps its preset cache and Undo without replacing a newer status", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" }),
    save = deferred();
  a.pending.push(() => save.promise);
  const saving = a.eval(
    'persistPreset({label:"KI-18FB",old:{rgb:"5C0701",bri:44},next:{rgb:"FFB46B",bri:5}})',
  );
  await a.el("stop").fire("click");
  const latest = a.el("status-text").textContent;
  save.resolve(
    response({
      ok: true,
      presets: {
        ...structuredClone(defaults),
        plug: { nacht: { rgb: "FFB46B", bri: 5 } },
      },
    }),
  );
  await saving;
  assert.equal(a.el("status-text").textContent, latest);
  assert.equal(a.eval("presetFor().rgb"), "FFB46B");
  assert.equal(a.el("undo").hidden, false);
  a.pending.push(() =>
    Promise.resolve(response({ ok: true, presets: structuredClone(defaults) })),
  );
  await a.el("undo").fire("click");
  await flush();
  assert.equal(a.calls.at(-1).path, "/preset");
  assert.equal(a.calls.at(-1).params.get("rgb"), "5C0701");
  assert.equal(a.el("undo").hidden, true);
});

test("reverse light ACKs preserve the newer light state and last command", async () => {
  const a = await setup(),
    old = deferred(),
    current = deferred();
  a.pending.push(
    () => old.promise,
    () => current.promise,
  );
  const first = a.eval(
    'command("/set",{hub:"plug",rgb:"FF0000",bri:5},"Rot",{success:(r,t,n)=>acceptLight(r,t,"Rot",n)})',
  );
  const second = a.eval(
    'command("/set",{hub:"plug",rgb:"0000FF",bri:6},"Blau",{success:(r,t,n)=>acceptLight(r,t,"Blau",n)})',
  );
  current.resolve(response({ ok: true, rgb: "0000FF", brightness: 6 }));
  await second;
  const latest = a.el("status-text").textContent;
  old.resolve(response({ ok: true, rgb: "FF0000", brightness: 5 }));
  await first;
  assert.equal(a.eval("state().last.rgb"), "0000FF");
  assert.equal(a.eval("state().rgb"), "0000FF");
  assert.equal(a.el("status-text").textContent, latest);
});

test("late save cannot overwrite a newer save or resurrect an already consumed Undo", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" }),
    old = deferred();
  a.pending.push(() => old.promise);
  const saving = a.eval(
    'persistPreset({label:"KI-18FB",old:{rgb:"5C0701",bri:44},next:{rgb:"FF0000",bri:5}})',
  );
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: true,
        presets: {
          ...structuredClone(defaults),
          plug: { nacht: { rgb: "0000FF", bri: 6 } },
        },
      }),
    ),
  );
  await a.eval(
    'persistPreset({label:"KI-18FB",old:{rgb:"5C0701",bri:44},next:{rgb:"0000FF",bri:6}})',
  );
  a.pending.push(() =>
    Promise.resolve(response({ ok: true, presets: structuredClone(defaults) })),
  );
  await a.el("undo").fire("click");
  await flush();
  const latest = a.el("status-text").textContent;
  old.resolve(
    response({
      ok: true,
      presets: {
        ...structuredClone(defaults),
        plug: { nacht: { rgb: "FF0000", bri: 5 } },
      },
    }),
  );
  await saving;
  assert.equal(a.eval("presetFor().rgb"), "5C0701");
  assert.equal(a.eval("undoCommand"), null);
  assert.equal(a.el("undo").hidden, true);
  assert.equal(a.el("status-text").textContent, latest);
});

test("a missing hub preset has honest copy and cannot generate an invalid Undo", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  a.eval(
    'presets={round:{}}; acceptLight({rgb:"FFB46B",brightness:5},"KI-18FB","Hellwarm"); render();',
  );
  await a.el("save-nightlight").fire("click");
  assert.equal(a.el("old-preset").textContent, "Nicht gespeichert");
  assert.equal(a.el("old-dot").hidden, true);
  assert.doesNotMatch(a.el("old-preset").textContent, /undefined/);
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: true,
        presets: { round: {}, plug: { nacht: { rgb: "FFB46B", bri: 5 } } },
      }),
    ),
  );
  await a.el("confirm-save").fire("click");
  await flush();
  assert.equal(a.eval("undoCommand"), null);
  assert.equal(a.el("undo").hidden, true);
  const count = a.calls.length;
  await a.el("undo").fire("click");
  a.eval('undoCommand={label:"KI-18FB",next:{}}');
  await a.el("undo").fire("click");
  assert.equal(a.calls.length, count);
});

test("late effects belong to their original hub while current hub status stays unchanged", async () => {
  const a = await setup(),
    light = deferred();
  a.pending.push(() => light.promise);
  const action = a.eval(
    'command("/set",{hub:"plug",rgb:"FF0000",bri:5},"Rot",{success:(r,t,n)=>acceptLight(r,t,"Rot",n)})',
  );
  a.eval('selectHub("EZ-594F")');
  await flush();
  const latest = a.el("status-text").textContent;
  light.resolve(response({ ok: true, rgb: "FF0000", brightness: 5 }));
  await action;
  assert.equal(a.el("status-text").textContent, latest);
  assert.equal(a.eval('states["KI-18FB"].last.rgb'), "FF0000");
  assert.equal(a.eval("state().last"), null);
  a.eval('selectHub("KI-18FB")');
  assert.match(a.el("last-light").textContent, /Zuletzt: Rot.*5/);
});

test("gesture prevention remains attached to both iOS pinch events", async () => {
  const a = await setup();
  for (const event of ["gesturestart", "gesturechange"]) {
    let prevented = false;
    await a.documentEvents.fire(event, {
      preventDefault: () => {
        prevented = true;
      },
    });
    assert.equal(prevented, true);
  }
});

test("corrupt preset startup preserves the specific server diagnosis", async () => {
  const message = "Gespeicherte Nachtlicht-Vorgaben beschädigt; Server prüfen";
  const a = await setup({}, false, {
    "/presets": () =>
      Promise.resolve(
        response({ ok: false, code: "presets_corrupt", error: message }),
      ),
  });
  assert.equal(a.el("status-text").textContent, message);
  assert.equal(a.eval("presetsReady"), false);
  assert.equal(a.el("retry").hidden, false);
  assert.equal(a.eval("state().last"), null);
});

test("a late hub save cannot replace the other hub's newer preset or Undo", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" }),
    old = deferred();
  a.pending.push(() => old.promise);
  const first = a.eval(
    'persistPreset({label:"KI-18FB",old:{rgb:"5C0701",bri:44},next:{rgb:"FF0000",bri:5}})',
  );
  a.eval('selectHub("EZ-594F")');
  await flush();
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: true,
        presets: {
          ...structuredClone(defaults),
          round: { nacht: { rgb: "0000FF", bri: 6 } },
        },
      }),
    ),
  );
  await a.eval(
    'persistPreset({label:"EZ-594F",old:{rgb:"5C0701",bri:44},next:{rgb:"0000FF",bri:6}})',
  );
  const latest = a.el("status-text").textContent;
  old.resolve(
    response({
      ok: true,
      presets: {
        ...structuredClone(defaults),
        plug: { nacht: { rgb: "FF0000", bri: 5 } },
      },
    }),
  );
  await first;
  assert.equal(a.eval('presetFor("KI-18FB").rgb'), "FF0000");
  assert.equal(a.eval('presetFor("EZ-594F").rgb'), "0000FF");
  assert.equal(a.eval("undoCommand.label"), "EZ-594F");
  assert.equal(a.el("status-text").textContent, latest);
});

test("a late apply updates last light without undoing a newer saved preset", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" }),
    old = deferred();
  a.pending.push(() => old.promise);
  const applying = a.el("nightlight").fire("click");
  a.pending.push(() =>
    Promise.resolve(
      response({
        ok: true,
        presets: {
          ...structuredClone(defaults),
          plug: { nacht: { rgb: "0000FF", bri: 6 } },
        },
      }),
    ),
  );
  await a.eval(
    'persistPreset({label:"KI-18FB",old:{rgb:"5C0701",bri:44},next:{rgb:"0000FF",bri:6}})',
  );
  const latest = a.el("status-text").textContent;
  old.resolve(response({ ok: true, rgb: "5C0701", brightness: 44 }));
  await applying;
  assert.equal(a.eval("presetFor().rgb"), "0000FF");
  assert.equal(a.eval("state().last.rgb"), "5C0701");
  assert.equal(a.el("undo").hidden, false);
  assert.equal(a.el("status-text").textContent, latest);
});
