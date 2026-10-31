/* OPS-496: execute the shipped script with a minimal DOM and mocked transport.
 * This tests behavior without a browser, sockets, devices or external packages.
 * Rendered geometry/CSP enforcement still requires Tick's browser QA. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
// Import executable repository code through a fixed module path. File/HTTP
// contents remain data and are never passed to the VM compiler.
const nightlightPage = require("../hosts/hsb1/aqara-nightlight-script.cjs");
const program = nightlightPage.toString();
const prefix = "function nightlightPage() {";
assert.ok(program.startsWith(prefix) && program.endsWith("}"));
const script = program.slice(prefix.length, -1);
const template = fs.readFileSync(
  path.join(__dirname, "../hosts/hsb1/aqara-nightlight-page.html"),
  "utf8",
);
assert.equal(template.split("<!--AQARA_INLINE_SCRIPT-->").length, 2);
const html = template.replace(
  "<!--AQARA_INLINE_SCRIPT-->",
  () => "<script>" + script + "</script>",
);
const scripts = [
  ...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script\b[^>]*>/gi),
];
assert.equal(
  scripts.length,
  1,
  "the shipped page must have exactly one script",
);
assert.equal(scripts[0][1], script);
const shippedScript = new vm.Script(script, {
  filename: "shipped-nightlight.js",
});
const flush = () => new Promise((resolve) => setImmediate(resolve));
const defaultPlaces = [
  { id: "nacht", name: "Nachtlicht", rgb: "5C0701", bri: 44 },
  { id: "p2", name: "Warm", rgb: "FF8C28", bri: 40 },
  { id: "p3", name: "Hell", rgb: "FFF4E0", bri: 80 },
  { id: "p4", name: "Rot leise", rgb: "FF2A00", bri: 5 },
];
const defaults = { plug: defaultPlaces, round: defaultPlaces };
const rules = Object.fromEntries(
  ["urgent", "regular", "open", "idle", "unknown"].map((level) => [
    level,
    {
      rgb: ["idle", "unknown"].includes(level) ? "8FA3B0" : "18C2B0",
      bri: { urgent: 60, regular: 20, open: 0, idle: 0, unknown: 5 }[level],
      mode: level === "urgent" ? "blink" : "steady",
      rgb2: "FFFFFF",
      takt: 2,
    },
  ]),
);
const fakeDesks = [
  {
    id: "ppm",
    short: "PPM",
    name: "Desk A",
    url: "https://desk-a.invalid",
    rgb: "18C2B0",
    key_set: false,
    key_set_at: null,
    override: false,
    rules,
  },
  {
    id: "pma",
    short: "PMA",
    name: "Desk B",
    url: "https://desk-b.invalid",
    rgb: "FFA020",
    key_set: false,
    key_set_at: null,
    override: false,
    rules,
  },
];
const configDefaults = Object.fromEntries(
  ["plug", "round"].map((h) => [
    h,
    {
      version: 33,
      usage: h === "round" ? "desk" : "nightlight",
      rules,
      desks: fakeDesks,
      multiple: { mode: "cycle", rgb: "9B6BFF" },
      thresholds: { ppm: 4, pma: 4 },
      auto_sound: false,
      history: [],
    },
  ]),
);
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
const DATA_ATTRIBUTES = new Map([
  ["data-desk-color", "deskColor"],
  ["data-multiple-color", "multipleColor"],
  ["data-panel", "panel"],
  ["data-tab", "tab"],
  ["data-close", "close"],
  ["data-multiple", "multiple"],
  ["data-threshold-desk", "thresholdDesk"],
  ["data-auto-duration", "autoDuration"],
  ["data-color", "color"],
  ["data-color-name", "colorName"],
  ["data-delete-place", "deletePlace"],
  ["data-disclosure", "disclosure"],
  ["data-duration", "duration"],
  ["data-hub", "hub"],
  ["data-mode", "mode"],
  ["data-preset", "preset"],
  ["data-rename-place", "renamePlace"],
  ["data-rule", "rule"],
  ["data-rule-color", "ruleColor"],
  ["data-rule-mode", "ruleMode"],
  ["data-rule-place", "rulePlace"],
  ["data-rule-slot", "ruleSlot"],
  ["data-save-place", "savePlace"],
  ["data-slider-row", "sliderRow"],
  ["data-t", "t"],
  ["data-theme", "theme"],
  ["data-usage", "usage"],
]);
const HTML_ATTRIBUTES = new Set([
  "aria-selected",
  "autocomplete",
  ...DATA_ATTRIBUTES.keys(),
  "aria-atomic",
  "aria-checked",
  "aria-controls",
  "aria-describedby",
  "aria-expanded",
  "aria-hidden",
  "aria-label",
  "aria-labelledby",
  "aria-live",
  "aria-pressed",
  "aria-valuetext",
  "charset",
  "class",
  "content",
  "cx",
  "cy",
  "d",
  "data-auto-duration",
  "data-color",
  "data-color-name",
  "data-delete-place",
  "data-disclosure",
  "data-duration",
  "data-hub",
  "data-mode",
  "data-preset",
  "data-rename-place",
  "data-rule",
  "data-rule-color",
  "data-rule-mode",
  "data-rule-place",
  "data-rule-slot",
  "data-save-place",
  "data-slider-row",
  "data-t",
  "data-theme",
  "data-usage",
  "disabled",
  "fill",
  "for",
  "height",
  "hidden",
  "href",
  "id",
  "lang",
  "max",
  "maxlength",
  "min",
  "name",
  "opacity",
  "preserveAspectRatio",
  "r",
  "role",
  "rx",
  "ry",
  "step",
  "stroke",
  "stroke-dasharray",
  "stroke-width",
  "style",
  "title",
  "transform",
  "type",
  "value",
  "viewBox",
  "width",
  "x",
  "y",
]);
class Element {
  constructor(attrs = {}) {
    this.attrs = Object.assign(Object.create(null), attrs);
    this.tagName = attrs._tag || "";
    this.min = attrs.min;
    this.max = attrs.max;
    this.step = attrs.step;
    this.disabled = Object.hasOwn(attrs, "disabled");
    this.checked = Object.hasOwn(attrs, "checked");
    this.listeners = Object.create(null);
    this.children = [];
    this.nested = new Map();
    this.dataset = Object.create(null);
    this.properties = new Map();
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
      setProperty: (key, value) => this.properties.set(key, value),
    };
    this.hidden = Object.hasOwn(attrs, "hidden");
    this.value = attrs.value || "";
    this.title = attrs.title || "";
    this.textContent = "";
    for (const [attribute, property] of DATA_ATTRIBUTES) {
      if (Object.hasOwn(attrs, attribute))
        this.dataset[property] = attrs[attribute];
    }
  }
  setAttribute(key, value) {
    assert.ok(HTML_ATTRIBUTES.has(key), `unhandled attribute write ${key}`);
    this.attrs[key] = value;
  }
  getAttribute(key) {
    return this.attrs[key];
  }
  get className() {
    return this.attrs.class || "";
  }
  set className(value) {
    for (const old of (this.attrs.class || "").split(/\s+/))
      this.classList.remove(old);
    this.attrs.class = value;
    for (const name of value.split(/\s+/)) this.classList.add(name);
  }
  get parentNode() {
    return this.parent;
  }
  get nextSibling() {
    if (!this.parent) return null;
    return this.parent.children[this.parent.children.indexOf(this) + 1] || null;
  }
  addEventListener(key, fn) {
    (this.listeners[key] ||= []).push(fn);
  }
  fire(key, attrs = {}) {
    const event = { button: 0, pointerId: 1, preventDefault() {}, ...attrs };
    return Promise.all((this.listeners[key] || []).map((fn) => fn(event)));
  }
  matches(selector) {
    if (selector === "*") return true;
    if (selector.includes(" ")) {
      const parts = selector.split(/\s+/);
      if (!this.matches(parts.pop())) return false;
      let parent = this.parent;
      while (parts.length) {
        const part = parts.pop();
        while (parent && !parent.matches(part)) parent = parent.parent;
        if (!parent) return false;
        parent = parent.parent;
      }
      return true;
    }
    const attr = selector.match(/^(?:([\w-]+))?\[([\w-]+)(?:="([^"]*)")?\]$/);
    if (attr)
      return (
        (!attr[1] || this.tagName === attr[1]) &&
        Object.hasOwn(this.attrs, attr[2]) &&
        (attr[3] === undefined || this.attrs[attr[2]] === attr[3])
      );
    if (selector.startsWith("."))
      return this.classList.contains(selector.slice(1));
    return this.tagName === selector;
  }
  querySelector(key) {
    return this.querySelectorAll(key)[0] || null;
  }
  querySelectorAll(key) {
    const selectors = key.split(",").map((x) => x.trim());
    const found = [];
    const visit = (e) => {
      for (const child of e.children) {
        if (!(child instanceof Element)) continue;
        if (selectors.some((k) => child.matches(k))) found.push(child);
        visit(child);
      }
    };
    visit(this);
    return found;
  }
  closest(key) {
    for (let p = this; p; p = p.parent) if (p.matches(key)) return p;
    return null;
  }
  getBoundingClientRect() {
    return { left: 0, width: 240 };
  }
  dispatchEvent(event) {
    return this.fire(event.type, event);
  }
  userFire(key, attrs = {}) {
    return this.disabled ? Promise.resolve([]) : this.fire(key, attrs);
  }
  replaceChildren(...children) {
    for (const child of this.children)
      if (child instanceof Element) child.parent = null;
    this.children = [];
    this.append(...children);
  }
  append(...children) {
    for (const child of children) this.insertBefore(child, null);
  }
  insertBefore(child, next) {
    if (child instanceof Element) {
      if (child.parent)
        child.parent.children.splice(child.parent.children.indexOf(child), 1);
      child.parent = this;
    }
    const index =
      next === null ? this.children.length : this.children.indexOf(next);
    this.children.splice(index, 0, child);
  }
  click() {
    return this.userFire("click");
  }
  focus() {}
  setPointerCapture() {}
  close() {
    const wasOpen = this.open;
    this.open = false;
    if (wasOpen) this.fire("close");
  }
  showModal() {
    this.open = true;
  }
}
async function setup(
  stored = {},
  storageFails = false,
  initial = {},
  viewport = {},
) {
  const elements = [];
  const stack = [];
  for (const match of html.matchAll(/<(\/?)([\w-]+)\b([^>]*?)>/g)) {
    const closing = match[1],
      tag = match[2];
    if (tag === "script") break;
    if (closing) {
      const i = stack.findLastIndex((e) => e.tagName === tag);
      if (i >= 0) stack.length = i;
      continue;
    }
    const attrs = Object.assign(Object.create(null), { _tag: tag });
    const parsed = new Map(
      [...match[3].matchAll(/([\w-]+)(?:="([^"]*)")?/g)].map((a) => [
        a[1],
        a[2] ?? "",
      ]),
    );
    for (const key of parsed.keys())
      assert.ok(HTML_ATTRIBUTES.has(key), `unhandled page attribute ${key}`);
    for (const key of HTML_ATTRIBUTES)
      if (parsed.has(key)) attrs[key] = parsed.get(key);
    const element = new Element(attrs);
    if (stack.length) {
      element.parent = stack.at(-1);
      element.parent.children.push(element);
    }
    elements.push(element);
    if (
      !["input", "meta", "link", "br", "hr"].includes(tag) &&
      !match[3].trimEnd().endsWith("/")
    )
      stack.push(element);
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
      const liveElements = [root, ...root.querySelectorAll("*")];
      if (selector === "button, input, select")
        return liveElements.filter((e) =>
          ["button", "input", "select"].includes(e.tagName),
        );
      const key = selector.match(/^\[([\w-]+)\]$/)?.[1];
      assert.ok(key, `unhandled DOM query ${selector}`);
      return liveElements.filter((e) => Object.hasOwn(e.attrs, key));
    },
    querySelector: (selector) => {
      const hub = selector.match(/^\[data-hub="([^"]+)"\]$/)?.[1];
      if (hub) return elements.find((e) => e.dataset.hub === hub);
      if (!queries.has(selector)) queries.set(selector, new Element());
      return queries.get(selector);
    },
    createElement: (tag) => new Element({ _tag: tag }),
    createTextNode: (text) => text,
  };
  const calls = [],
    pending = [],
    timers = new Map();
  let time = 0,
    timerId = 0;
  const context = vm.createContext({
    matchMedia(query) {
      return {
        matches: query.includes("reduced-motion")
          ? Boolean(viewport.reducedMotion)
          : Boolean(viewport.phone),
        addEventListener() {},
      };
    },
    document,
    URLSearchParams,
    AbortController,
    TextDecoder,
    Event: class {
      constructor(type, attrs) {
        this.type = type;
        Object.assign(this, attrs);
      }
    },
    Date: class extends Date {
      static now() {
        return time;
      }
    },
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
      if (u.pathname === "/config")
        return Promise.resolve(
          response({ ok: true, settings: structuredClone(configDefaults) }),
        );
      if (u.pathname === "/signal")
        return Promise.resolve(
          response({
            ok: true,
            key: "unknown",
            rule: configDefaults.round.rules.unknown,
            settings: configDefaults.round,
            feed: null,
          }),
        );
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
      if (u.pathname === "/apply") {
        const p = defaultPlaces.find(
          (p) => p.id === u.searchParams.get("preset"),
        );
        return Promise.resolve(
          response(
            p
              ? { ok: true, rgb: p.rgb, brightness: p.bri, versuche: 1 }
              : { ok: false, error: "Preset nicht gespeichert" },
          ),
        );
      }
      const rgb = u.searchParams.get("rgb") || "5C0701",
        bri = Number(u.searchParams.get("bri") ?? 44);
      return Promise.resolve(
        response({ ok: true, rgb, brightness: bri, versuche: 1 }),
      );
    },
  });
  shippedScript.runInContext(context);
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

test("DOM harness allowlists attribute writes and isolates map storage", () => {
  const element = new Element(
    Object.fromEntries([
      ["data-hub", "KI-18FB"],
      ["data-__proto__", "blocked"],
      ["__proto__", "data only"],
    ]),
  );
  assert.equal(Object.getPrototypeOf(element.attrs), null);
  assert.equal(Object.getPrototypeOf(element.dataset), null);
  assert.equal(Object.getPrototypeOf(element.listeners), null);
  assert.equal(element.dataset.hub, "KI-18FB");
  assert.equal(Object.hasOwn(element.dataset, "__proto__"), false);
  assert.throws(() => element.setAttribute("__proto__", "blocked"));
  element.style.setProperty("__proto__", "data only");
  assert.equal(element.properties.get("__proto__"), "data only");
});

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
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
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
  a.eval('selectHub("WZ-594F")');
  third.resolve(response({ ok: true }));
  await p3;
  assert.match(a.el("status-text").textContent, /Bereit · WZ-594F/);
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
    "Hub oder Dienst nicht erreichbar; erneut versuchen",
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
  assert.match(
    a.el("status-text").textContent,
    /Hub oder Dienst nicht erreichbar/,
  );
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
  a.eval('selectHub("WZ-594F")');
  await flush();
  assert.equal(a.storage.get("nightlight-hub"), "WZ-594F");
  const b = await setup(Object.fromEntries(a.storage));
  assert.equal(b.eval("selected"), "WZ-594F");
  assert.equal(
    b.calls.find((c) => c.path === "/get").params.get("hub"),
    "round",
  );
  assert.equal(b.el("status-text").textContent, "Bereit · WZ-594F");
  for (const hub of ["invalid", "__proto__", "constructor"]) {
    const c = await setup({ "nightlight-hub": hub });
    assert.equal(c.eval("selected"), "KI-18FB");
    c.eval('selectHub("invalid")');
    assert.equal(c.eval("selected"), "KI-18FB");
  }
  const d = await setup({ "nightlight-hub": "WZ-594F" }, true);
  assert.equal(d.eval("selected"), "KI-18FB");
  d.eval('selectHub("WZ-594F")');
  assert.equal(d.eval("selected"), "WZ-594F");
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
  assert.deepEqual(a.calls.map((c) => c.path).sort(), [
    "/config",
    "/get",
    "/presets",
  ]);
});

test("every preset, swatch and tone button sends its own bound value", async () => {
  const a = await setup();
  for (const button of a.buttons("[data-preset]")) {
    const before = a.calls.length;
    await button.fire("click");
    await flush();
    const calls = a.calls.slice(before).filter((c) => c.path === "/apply");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].params.get("preset"), button.dataset.preset);
  }
  assert.equal(a.buttons("[data-preset]").length, 5);
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

test("hung fetch or response body aborts after 30 seconds with manual retry", async () => {
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
    a.tick(29999);
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
    a.tick(30000);
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
  assert.equal(a.el("undo").hidden, true);
  assert.equal(a.eval("undoCommand.next.rgb"), "5C0701");
  await a.el("stop").fire("click");
  assert.equal(a.eval("undoCommand"), null);
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
  a.eval('selectHub("WZ-594F")');
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
  a.eval('selectHub("WZ-594F")');
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
    'persistPreset({label:"WZ-594F",old:{rgb:"5C0701",bri:44},next:{rgb:"0000FF",bri:6}})',
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
  assert.equal(a.eval('presetFor("WZ-594F").rgb'), "0000FF");
  assert.equal(a.eval("undoCommand.label"), "WZ-594F");
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

test("tap locks every control immediately, delays the overlay, then unlocks on reply", async () => {
  const a = await setup(),
    pending = deferred();
  a.calls.length = 0;
  a.pending.push(() => pending.promise);
  const action = a.el("nightlight").userFire("click");
  assert.equal(a.el("stop").disabled, true);
  assert.equal(a.el("bri").disabled, true);
  assert.equal(a.buttons("[data-hub]")[1].disabled, true);
  assert.equal(a.el("theme").disabled, true);
  assert.equal(a.el("sending-overlay").hidden, true);
  await a.el("stop").userFire("click");
  await a.buttons("[data-hub]")[1].userFire("click");
  assert.equal(a.calls.length, 1);
  assert.equal(a.eval("selected"), "KI-18FB");
  a.tick(249);
  assert.equal(a.el("sending-overlay").hidden, true);
  a.tick(1);
  assert.equal(a.el("sending-overlay").hidden, false);
  assert.equal(a.el("sending-overlay").open, true);
  pending.resolve(response({ ok: true, rgb: "5C0701", brightness: 44 }));
  await action;
  assert.equal(a.el("sending-overlay").hidden, true);
  assert.equal(a.el("sending-overlay").open, false);
  assert.equal(a.el("stop").disabled, false);
  assert.equal(a.el("bri").disabled, false);
});

test("fast replies never show the overlay and errors release the sending lock", async () => {
  const a = await setup();
  await a.el("stop").userFire("click");
  a.tick(250);
  assert.equal(a.el("sending-overlay").hidden, true);
  a.pending.push(() => Promise.reject(new Error("offline")));
  await a.el("stop").userFire("click");
  assert.equal(a.el("stop").disabled, false);
  assert.equal(a.el("retry").hidden, false);
  assert.equal(a.el("sending-overlay").hidden, true);
});

test("drag throttle waits for reply and one second, coalesces values, sends release value", async () => {
  const a = await setup(),
    first = deferred();
  a.calls.length = 0;
  a.pending.push(() => first.promise);
  a.el("bri").value = "10";
  await a.el("bri").userFire("input");
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
  assert.equal(a.el("stop").disabled, false);
  a.tick(2000);
  assert.equal(a.el("sending-overlay").hidden, true);
  for (const value of [20, 30, 40, 50]) {
    a.el("bri").value = String(value);
    await a.el("bri").userFire("input");
  }
  await a.el("bri").userFire("change");
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
  first.resolve(response({ ok: true, rgb: "FF8C28", brightness: 10 }));
  await flush();
  const values = a.calls
    .filter((c) => c.path === "/set")
    .map((c) => c.params.get("bri"));
  assert.deepEqual(values, ["10", "50"]);
  assert.equal(a.eval("state().bri"), 50);
  a.el("bri").value = "70";
  await a.el("bri").userFire("input");
  a.el("bri").value = "80";
  await a.el("bri").userFire("change");
  a.tick(999);
  await flush();
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 2);
  a.tick(1);
  await flush();
  assert.equal(
    a.calls
      .filter((c) => c.path === "/set")
      .at(-1)
      .params.get("bri"),
    "80",
  );
});

test("tap during a drag locks immediately and waits for that drag reply", async () => {
  const a = await setup(),
    first = deferred();
  a.calls.length = 0;
  a.pending.push(() => first.promise);
  a.el("bri").value = "20";
  await a.el("bri").fire("input");
  const tap = a.el("off").userFire("click");
  assert.equal(a.el("stop").disabled, true);
  assert.equal(a.calls.length, 1);
  first.resolve(response({ ok: true, rgb: "FF8C28", brightness: 20 }));
  await tap;
  await flush();
  assert.deepEqual(
    a.calls.filter((c) => c.path === "/set").map((c) => c.params.get("bri")),
    ["20", "0"],
  );
  assert.equal(a.eval("state().bri"), 0);
});

test("volume and own colour drags use the same latest-value throttle without overlays", async () => {
  const a = await setup();
  await a.buttons("[data-t]")[0].fire("click");
  a.calls.length = 0;
  a.el("vol").value = "12";
  await a.el("vol").fire("input");
  await flush();
  a.el("vol").value = "14";
  await a.el("vol").fire("change");
  assert.equal(a.calls.filter((c) => c.path === "/tone").length, 1);
  a.tick(1000);
  await flush();
  assert.equal(
    a.calls
      .filter((c) => c.path === "/tone")
      .at(-1)
      .params.get("vol"),
    "14",
  );
  a.el("col").value = "#112233";
  await a.el("col").fire("input");
  a.el("col").value = "#445566";
  await a.el("col").fire("change");
  a.tick(1000);
  await flush();
  assert.equal(
    a.calls
      .filter((c) => c.path === "/set")
      .at(-1)
      .params.get("rgb"),
    "445566",
  );
  assert.equal(a.el("sending-overlay").hidden, true);
});

test("sound duration selector, range and field stay in sync and optional ms reaches tone", async () => {
  const a = await setup();
  await a.buttons("[data-duration]")[1].fire("click");
  assert.equal(a.el("duration-controls").hidden, false);
  a.el("duration").value = "1200";
  await a.el("duration").fire("input");
  assert.equal(a.el("duration-ms").value, "1200");
  a.el("duration-ms").value = "2200";
  await a.el("duration-ms").fire("change");
  assert.equal(Number(a.el("duration").value), 2200);
  a.el("duration-ms").value = "199";
  await a.el("duration-ms").fire("change");
  assert.equal(Number(a.el("duration-ms").value), 2200);
  await a.el("tone-test").fire("click");
  assert.equal(a.calls.at(-1).params.get("ms"), "2200");
  await a.buttons("[data-duration]")[0].fire("click");
  await a.el("tone-test").fire("click");
  assert.equal(a.calls.at(-1).params.has("ms"), false);
});

test("WZ defaults to Desk-Signal with honest disconnected and unknown copy in both modes", async () => {
  const a = await setup({ "nightlight-hub": "WZ-594F" });
  assert.equal(a.el("desk-controls").hidden, false);
  assert.equal(a.el("nightlight-controls").hidden, true);
  assert.match(a.el("desk-lit").textContent, /Unbekannt.*5/);
  assert.equal(a.el("desk-signal-rows").children.length, 2);
  for (const row of a.el("desk-signal-rows").children)
    assert.match(row.querySelector(".dr-m").textContent, /keine Daten/);
  assert.equal(a.el("desk-kind").textContent, "WZ-594F zeigt den Desk");
  assert.equal(a.el("usage-text").textContent, "Verwendung: Desk-Signal");
  assert.equal(a.el("desk-seen").disabled, true);
  assert.equal(a.el("auto-sound").getAttribute("aria-checked"), "false");
});

test("Verwendung saves on the server for exactly the selected hub", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  a.pending.push((url) => {
    assert.equal(url.pathname, "/settings");
    assert.equal(url.searchParams.get("hub"), "plug");
    const settings = structuredClone(configDefaults);
    settings.plug.usage = "desk";
    return Promise.resolve(response({ ok: true, settings }));
  });
  await a.buttons("[data-usage]")[1].fire("click");
  await flush();
  assert.equal(a.eval("settings.plug.usage"), "desk");
  assert.equal(a.el("nightlight-controls").hidden, true);
  assert.equal(a.el("desk-controls").hidden, false);
});

test("named places preserve their IDs, previews and safe labels in the save sheet", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  a.eval(
    'acceptLight({rgb:"FFB46B",brightness:5},"KI-18FB","Hellwarm"); render();',
  );
  await a.el("save-nightlight").fire("click");
  await a
    .buttons("[data-save-place]")
    .find((b) => b.dataset.savePlace === "p2")
    .fire("click");
  assert.match(a.el("old-preset").textContent, /FF8C28/);
  assert.match(a.el("new-preset").textContent, /FFB46B/);
  a.pending.push((url) => {
    assert.equal(url.searchParams.get("id"), "p2");
    const presets = structuredClone(defaults);
    Object.assign(presets.plug[1], { rgb: "FFB46B", bri: 5 });
    return Promise.resolve(response({ ok: true, presets }));
  });
  await a.el("confirm-save").fire("click");
  await flush();
  assert.equal(a.eval("placesFor().p2.rgb"), "FFB46B");
  assert.equal(a.el("undo").hidden, false);
  await a.el("off").fire("click");
  assert.equal(a.el("undo").hidden, true);
  assert.equal(a.eval("undoCommand"), null);
});

test("place rename is inline, deletion needs confirmation, nacht cannot be deleted", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  a.eval(
    'acceptLight({rgb:"FFB46B",brightness:5},"KI-18FB","Hellwarm"); render();',
  );
  await a.el("save-nightlight").fire("click");
  await a.el("edit-places").fire("click");
  a.el("rename-p2").value = "<Lesen>";
  a.pending.push((url) => {
    assert.equal(url.searchParams.get("id"), "p2");
    assert.equal(url.searchParams.get("name"), "<Lesen>");
    const presets = structuredClone(defaults);
    presets.plug[1].name = "<Lesen>";
    return Promise.resolve(response({ ok: true, presets }));
  });
  await a
    .buttons("[data-rename-place]")
    .find((b) => b.dataset.renamePlace === "p2")
    .fire("click");
  await flush();
  assert.equal(
    a.buttons("[data-preset]")[0].querySelector(".pre-n").textContent,
    "<Lesen>",
  );
  const before = a.calls.length;
  await a
    .buttons("[data-delete-place]")
    .find((b) => b.dataset.deletePlace === "nacht")
    .fire("click");
  assert.equal(a.calls.length, before);
  await a
    .buttons("[data-delete-place]")
    .find((b) => b.dataset.deletePlace === "p2")
    .fire("click");
  assert.equal(a.calls.length, before);
  assert.equal(a.el("delete-place-confirm").hidden, false);
  a.pending.push((url) => {
    assert.equal(url.searchParams.get("delete"), "1");
    const presets = structuredClone(defaults);
    presets.plug = presets.plug.filter((p) => p.id !== "p2");
    return Promise.resolve(response({ ok: true, presets }));
  });
  await a.el("confirm-place-delete").fire("click");
  await flush();
  assert.equal(a.eval("placesFor().p2"), undefined);
});

test("urgency editor exposes five rules, desk colour, takt minimum and thresholds", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  assert.equal(a.buttons("[data-rule]").length, 5);
  await a.buttons("[data-rule]")[0].fire("click");
  assert.equal(a.el("rule-sheet").open, true);
  assert.equal(a.el("rule-takt").getAttribute("min"), "2");
  await a
    .buttons("[data-rule-mode]")
    .find((b) => b.dataset.ruleMode === "alternate")
    .fire("click");
  await a.buttons("[data-rule-slot]")[1].fire("click");
  await a
    .buttons("[data-rule-color]")
    .find((b) => b.dataset.ruleColor === "FFA020")
    .fire("click");
  assert.equal(a.el("rule-from-desk").hidden, false);
  assert.equal(a.el("rule-thresholds").hidden, false);
  a.pending.push((url) => {
    assert.equal(url.searchParams.get("threshold_ppm"), "4");
    assert.equal(url.searchParams.get("threshold_pma"), "4");
    assert.equal(url.searchParams.get("takt"), "2");
    assert.equal(url.searchParams.get("mode"), "alternate");
    assert.equal(url.searchParams.get("rgb2"), "FFA020");
    return Promise.resolve(
      response({ ok: true, settings: structuredClone(configDefaults) }),
    );
  });
  await a.el("rule-save").fire("click");
});

test("unknown editor cannot blink or turn off and warns when idle is too similar", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  await a
    .buttons("[data-rule]")
    .find((b) => b.dataset.rule === "unknown")
    .fire("click");
  assert.equal(a.el("rule-bri").min, 1);
  assert.equal(
    a.buttons("[data-rule-mode]").find((b) => b.dataset.ruleMode === "blink")
      .disabled,
    true,
  );
  a.eval(
    "settings.round.rules.idle={...settings.round.rules.unknown};renderRuleEditor();",
  );
  assert.match(a.el("rule-warning").textContent, /zu ähnlich/);
});

test("rule color picker rejects black in both slots and sends safe save/test colors", async () => {
  for (const action of ["rule-save", "rule-test"]) {
    const a = await setup({
      "nightlight-mode": "erwachsen",
      "nightlight-hub": "WZ-594F",
    });
    await a
      .buttons("[data-rule]")
      .find((b) => b.dataset.rule === "idle")
      .fire("click");
    a.el("rule-bri").value = "20";
    await a.el("rule-bri").fire("input");
    await a
      .buttons("[data-rule-mode]")
      .find((b) => b.dataset.ruleMode === "alternate")
      .fire("click");
    for (const slot of ["rgb", "rgb2"]) {
      await a
        .buttons("[data-rule-slot]")
        .find((b) => b.dataset.ruleSlot === slot)
        .fire("click");
      const previous = a.eval(`ruleDraft.${slot}`);
      a.el("rule-color").value = "#000000";
      await a.el("rule-color").fire("input");
      assert.equal(a.eval(`ruleDraft.${slot}`), previous);
      assert.equal(a.el("rule-color").value, "#" + previous);
      assert.match(a.el("rule-warning").textContent, /Schwarz/);
    }
    a.pending.push((url) => {
      assert.equal(
        url.pathname,
        action === "rule-save" ? "/settings" : "/signal-test",
      );
      assert.equal(url.searchParams.get("bri"), "20");
      assert.equal(url.searchParams.get("rgb"), "8FA3B0");
      assert.equal(url.searchParams.get("rgb2"), "FFFFFF");
      return Promise.resolve(
        response({ ok: true, settings: structuredClone(configDefaults) }),
      );
    });
    await a.el(action).fire("click");
    await flush();
    assert.equal(a.pending.length, 0);
  }
});

test("black saved places are disabled in the rule editor for both color slots", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.eval('presets.round.p2.rgb="000000";');
  await a
    .buttons("[data-rule]")
    .find((b) => b.dataset.rule === "regular")
    .fire("click");
  await a
    .buttons("[data-rule-mode]")
    .find((b) => b.dataset.ruleMode === "alternate")
    .fire("click");
  const place = a
    .buttons("[data-rule-place]")
    .find((b) => b.dataset.rulePlace === "p2");
  assert.equal(place.disabled, true);
  for (const slot of ["rgb", "rgb2"]) {
    await a
      .buttons("[data-rule-slot]")
      .find((b) => b.dataset.ruleSlot === slot)
      .fire("click");
    const previous = a.eval(`ruleDraft.${slot}`);
    await place.fire("click");
    assert.equal(a.eval(`ruleDraft.${slot}`), previous);
  }
});

test("black off-rule colors become usable colors before brightness is raised", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.eval(
    'settings.round.rules.idle={rgb:"000000",rgb2:"000000",bri:0,mode:"alternate",takt:2};',
  );
  await a
    .buttons("[data-rule]")
    .find((b) => b.dataset.rule === "idle")
    .fire("click");
  a.el("rule-bri").value = "20";
  await a.el("rule-bri").fire("input");
  assert.notEqual(a.eval("ruleDraft.rgb"), "000000");
  assert.notEqual(a.eval("ruleDraft.rgb2"), "000000");
  await a.el("rule-test").fire("click");
  await flush();
  const sent = a.calls.find((c) => c.path === "/signal-test");
  assert.ok(sent);
  assert.equal(sent.params.get("bri"), "20");
  assert.notEqual(sent.params.get("rgb"), "000000");
  assert.notEqual(sent.params.get("rgb2"), "000000");
});

test("rule save/test refuse a black lit draft in either slot without closing", async () => {
  for (const action of ["rule-save", "rule-test"]) {
    for (const slot of ["rgb", "rgb2"]) {
      const a = await setup({
        "nightlight-mode": "erwachsen",
        "nightlight-hub": "WZ-594F",
      });
      await a
        .buttons("[data-rule]")
        .find((b) => b.dataset.rule === "regular")
        .fire("click");
      a.eval(`ruleDraft.${slot}="000000";`);
      const before = a.calls.length;
      await a.el(action).fire("click");
      assert.equal(a.calls.length, before);
      assert.equal(a.el("rule-sheet").open, true);
      assert.match(a.el("rule-warning").textContent, /Schwarz/);
    }
  }
});

test("HTTP 400 rule validation keeps the server's German error visible", async () => {
  for (const action of ["rule-save", "rule-test"]) {
    const a = await setup({
      "nightlight-mode": "erwachsen",
      "nightlight-hub": "WZ-594F",
    });
    await a
      .buttons("[data-rule]")
      .find((b) => b.dataset.rule === "regular")
      .fire("click");
    const message = "Bei Helligkeit über 0 % darf keine Farbe Schwarz sein.";
    a.pending.push(() =>
      Promise.resolve(
        response({ ok: false, code: "invalid_rule", error: message }, 400),
      ),
    );
    await a.el(action).fire("click");
    await flush();
    assert.equal(a.el("status-text").textContent, message);
    assert.equal(a.eval("serverRejected"), false);
  }
});

test("whole slider row takes pointer at both ends and retains native keyboard steps", async () => {
  const a = await setup(),
    row = a.el("bri").closest(".slrow");
  a.calls.length = 0;
  await row.fire("pointerdown", { clientX: 0 });
  await flush();
  assert.equal(Number(a.el("bri").value), 0);
  await row.fire("pointermove", { clientX: 240 });
  await row.fire("pointerup", { clientX: 240 });
  a.tick(1000);
  await flush();
  assert.equal(
    a.calls
      .filter((c) => c.path === "/set")
      .at(-1)
      .params.get("bri"),
    "100",
  );
  assert.equal(a.el("rule-takt").getAttribute("step"), "1");
  assert.equal(a.el("duration").getAttribute("step"), "100");
});

test("automatic audio duration and volume can be saved without playing", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.el("auto-duration").value = "1400";
  await a.el("auto-duration").fire("input");
  a.el("auto-vol").value = "12";
  await a.el("auto-vol").fire("input");
  a.pending.push((url) => {
    assert.equal(url.pathname, "/settings");
    assert.equal(url.searchParams.get("sound_ms"), "1400");
    assert.equal(url.searchParams.get("sound_vol"), "12");
    const settings = structuredClone(configDefaults);
    settings.round.sound_ms = 1400;
    settings.round.sound_vol = 12;
    return Promise.resolve(response({ ok: true, settings }));
  });
  const before = a.calls.length;
  await a.el("auto-tone-save").fire("click");
  await flush();
  assert.equal(
    a.calls.slice(before).some((c) => c.path === "/tone"),
    false,
  );
  await a.el("auto-tone-test").fire("click");
  assert.equal(a.calls.at(-1).params.get("ms"), "1400");
});

test("streamed retries update the actual attempt while the overlay is visible", async () => {
  const a = await setup(),
    final = deferred();
  let reads = 0;
  a.pending.push(() =>
    Promise.resolve({
      ok: true,
      status: 200,
      headers: { get: () => "application/x-ndjson" },
      body: {
        getReader: () => ({
          read() {
            reads++;
            if (reads === 1)
              return Promise.resolve({
                value: Buffer.from(
                  '{"progress":1,"attempts":4}\n{"progress":2,"attempts":4}\n',
                ),
                done: false,
              });
            if (reads === 2) return final.promise;
            return Promise.resolve({ done: true });
          },
        }),
      },
    }),
  );
  const action = a.el("stop").userFire("click");
  await flush();
  a.tick(250);
  assert.equal(a.el("sending-overlay").hidden, false);
  assert.equal(a.el("sending-attempt").textContent, "Versuch 2 von 4");
  assert.equal(a.calls.at(-1).options.headers.Accept, "application/x-ndjson");
  final.resolve({
    value: Buffer.from('{"ok":true,"versuche":2}\n'),
    done: false,
  });
  await action;
  assert.match(a.el("status-text").textContent, /nach 2 Versuchen/);
  assert.equal(a.el("sending-overlay").hidden, true);
});

test("incomplete streamed reply cannot claim success and releases all controls", async () => {
  const a = await setup();
  let reads = 0;
  a.pending.push(() =>
    Promise.resolve({
      ok: true,
      status: 200,
      headers: { get: () => "application/x-ndjson" },
      body: {
        getReader: () => ({
          read: async () =>
            ++reads === 1
              ? {
                  value: Buffer.from('{"progress":1,"attempts":4}\n'),
                  done: false,
                }
              : { done: true },
        }),
      },
    }),
  );
  await a.el("stop").fire("click");
  assert.equal(a.el("retry").hidden, false);
  assert.equal(a.el("stop").disabled, false);
  assert.equal(a.el("sending-overlay").hidden, true);
  assert.match(a.el("status-text").textContent, /Keine Verbindung/);
});

test("adult can manage named places from the initial readback without actuating a hub", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  assert.equal(a.eval("state().last"), null);
  assert.equal(a.el("save-nightlight").hidden, false);
  const count = a.calls.length;
  await a.el("save-nightlight").userFire("click");
  assert.equal(a.el("save-sheet").open, true);
  assert.equal(a.calls.length, count);
  assert.match(a.el("new-preset").textContent, /FF8C28/);
});

test("failed config load offers manual retry and recovers the settings controls", async () => {
  let offline = true;
  const a = await setup({ "nightlight-mode": "erwachsen" }, false, {
    "/config": () =>
      offline
        ? Promise.reject(new Error("offline"))
        : Promise.resolve(
            response({ ok: true, settings: structuredClone(configDefaults) }),
          ),
  });
  assert.equal(a.eval("configReady"), false);
  assert.equal(a.el("retry").hidden, false);
  offline = false;
  await a.el("retry").userFire("click");
  await flush();
  assert.equal(a.eval("configReady"), true);
  assert.equal(a.buttons("[data-usage]")[0].disabled, false);
});

test("brightness from raw Aus uses the server's durable colour, including unknown colour", async () => {
  for (const rgb of ["000000", null]) {
    const a = await setup({}, false, {
      "/get": async () =>
        response({
          ok: true,
          rgb,
          raw: "0x00000000",
          brightness: 0,
          illumination: 12,
          last_rgb: "123456",
        }),
    });
    assert.equal(a.eval("state().rgb"), "123456");
    assert.equal(a.eval("state().readback.rgb"), rgb);
    assert.equal(a.el("col").value, "#123456");
    a.el("bri").value = "70";
    await a.el("bri").userFire("input");
    await flush();
    const sent = a.calls.filter((c) => c.path === "/set");
    assert.equal(sent.length, 1);
    assert.equal(sent[0].params.get("rgb"), "123456");
    assert.equal(sent[0].params.get("bri"), "70");
  }
});

test("without a previous colour, off-state brightness uses that hub's nacht", async () => {
  const presets = structuredClone(defaults);
  presets.plug[0].rgb = "225577";
  const a = await setup({}, false, {
    "/presets": async () => response({ ok: true, presets }),
    "/get": async () =>
      response({ ok: true, rgb: "000000", brightness: 0, illumination: 0 }),
  });
  a.el("bri").value = "60";
  await a.el("bri").userFire("input");
  await flush();
  assert.equal(
    a.calls
      .filter((c) => c.path === "/set")
      .at(-1)
      .params.get("rgb"),
    "225577",
  );
});

test("Eigene Farbe and direct light sends recover black or unknown at positive brightness", async () => {
  const a = await setup();
  a.eval(
    'acceptLight({rgb:"AABBCC",brightness:50},selected,"Eigene Farbe");render();',
  );
  a.el("col").value = "#000000";
  await a.el("col").userFire("input");
  await flush();
  assert.equal(a.calls.at(-1).params.get("rgb"), "AABBCC");
  assert.equal(a.calls.at(-1).params.get("bri"), "50");
  a.eval("state().rgb=null;state().bri=80;");
  await a.eval("sendLight()");
  assert.equal(a.calls.at(-1).params.get("rgb"), "AABBCC");
  assert.equal(
    a.calls.some(
      (c) =>
        c.path === "/set" &&
        c.params.get("rgb") === "000000" &&
        Number(c.params.get("bri")) > 0,
    ),
    false,
  );
});

test("recovery colours remain separate across hub switches and late readbacks", async () => {
  const a = await setup({}, false, {
    "/get": async (url) =>
      response({
        ok: true,
        rgb: "000000",
        brightness: 0,
        illumination: 0,
        last_rgb: url.searchParams.get("hub") === "plug" ? "112233" : "AABBCC",
      }),
  });
  a.eval('settings.round.usage="nightlight";selectHub("WZ-594F");');
  await flush();
  a.el("bri").value = "40";
  await a.el("bri").userFire("input");
  await flush();
  assert.equal(a.calls.at(-1).params.get("rgb"), "AABBCC");
  a.eval('selectHub("KI-18FB");');
  await flush();
  a.tick(1000);
  a.el("bri").value = "50";
  await a.el("bri").userFire("input");
  await flush();
  assert.equal(a.calls.at(-1).params.get("rgb"), "112233");
  a.eval(
    'acceptReadback({rgb:"000000",brightness:0,last_rgb:"999999"},selected,0);',
  );
  assert.equal(a.eval("state().lastRgb"), "112233");
});

test("Verwendung selects exactly one styled radio on both hubs, modes and themes", async () => {
  assert.match(
    html,
    /\.seg button\[aria-checked="true"\]\s*\{[^}]*background: var\(--raised\)/,
  );
  for (const theme of ["dark", "light"])
    for (const mode of ["kind", "erwachsen"])
      for (const [hub, usage] of [
        ["KI-18FB", "nightlight"],
        ["WZ-594F", "desk"],
      ]) {
        const a = await setup({
          "nightlight-theme": theme,
          "nightlight-mode": mode,
          "nightlight-hub": hub,
        });
        const buttons = a.buttons("[data-usage]");
        assert.equal(
          buttons.filter((b) => b.getAttribute("aria-checked") === "true")
            .length,
          1,
        );
        for (const button of buttons) {
          assert.equal(button.getAttribute("role"), "radio");
          assert.equal(
            button.getAttribute("aria-checked"),
            String(button.dataset.usage === usage),
          );
          assert.equal(button.getAttribute("aria-pressed"), undefined);
          assert.equal(
            button.tabIndex,
            button.dataset.usage === usage ? 0 : -1,
          );
        }
      }
});

test("matrix motion uses the frozen wave icon with accessible blink and alternate text", async () => {
  const a = await setup({ "nightlight-hub": "WZ-594F" });
  const urgent = a
    .buttons("[data-rule]")
    .find((b) => b.dataset.rule === "urgent");
  assert.match(urgent.querySelector(".cv").textContent, /^60\s%$/);
  assert.equal(
    urgent.querySelector(".cwave").classList.contains("motion-hidden"),
    false,
  );
  assert.equal(
    urgent.querySelector(".cwave").getAttribute("aria-hidden"),
    "true",
  );
  assert.equal(urgent.querySelector("use").getAttribute("href"), "#i-wave");
  assert.match(urgent.querySelector(".rule-motion").textContent, /blinkt/);
  assert.match(urgent.getAttribute("aria-label"), /blinkt.*2 s/);
  a.eval('settings.round.rules.urgent.mode="alternate";renderDesk();');
  assert.match(urgent.querySelector(".rule-motion").textContent, /wechselt/);
  a.eval('settings.round.rules.urgent.mode="steady";renderDesk();');
  assert.equal(
    urgent.querySelector(".cwave").classList.contains("motion-hidden"),
    true,
  );
  assert.equal(urgent.querySelector(".rule-motion").textContent, "ständig");
});

test("Gesehen appears only for a lit Desk state and hides for unknown, idle and off", async () => {
  const a = await setup({
    "nightlight-hub": "WZ-594F",
    "nightlight-mode": "erwachsen",
  });
  assert.equal(a.el("desk-seen").hidden, true);
  for (const [key, bri, visible] of [
    ["unknown", 5, false],
    ["idle", 0, false],
    ["urgent:ppm", 60, true],
    ["open:ppm", 0, false],
    ["regular:ppm", 20, true],
  ]) {
    a.eval(
      `signal={hub:"round",key:${JSON.stringify(key)},rule:{...settings.round.rules[${JSON.stringify(key)}],bri:${bri}},feed:{updated_at:0,desks:{ppm:{held:1,oldest_held_at:0}}}};renderDesk();`,
    );
    assert.equal(a.el("desk-seen").hidden, !visible, key);
    assert.equal(a.el("desk-seen").disabled, !visible, key);
  }
});

test("Kind WZ hub and Zuletzt use the sofa; Desk card uses the lamp and bell", async () => {
  const a = await setup({ "nightlight-hub": "WZ-594F" });
  const wz = a.buttons("[data-hub]").find((b) => b.dataset.hub === "WZ-594F");
  assert.equal(wz.querySelector(".k use").getAttribute("href"), "#p-sofa");
  assert.equal(
    a.eval(
      'document.querySelector(".hubsays .hspic use").getAttribute("href")',
    ),
    "#p-sofa",
  );
  assert.equal(
    a.el("desk-controls").querySelector(".kpic use").getAttribute("href"),
    "#p-lampbell",
  );
  assert.match(html, /<h2>Ton bei neuer Entscheidung<\/h2>/);
  assert.doesNotMatch(html, /Ton bei neuem Eintrag/);
});

test("identical drag input and release send once, both in flight and after reply", async () => {
  for (const inFlight of [false, true]) {
    const a = await setup(),
      first = deferred();
    a.calls.length = 0;
    if (inFlight) a.pending.push(() => first.promise);
    a.el("bri").value = "100";
    await a.el("bri").userFire("input");
    await flush();
    if (!inFlight) a.tick(1000);
    await a.el("bri").userFire("input");
    await a.el("bri").userFire("change");
    if (inFlight)
      first.resolve(response({ ok: true, rgb: "FF8C28", brightness: 100 }));
    await flush();
    a.tick(2000);
    await flush();
    assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
  }
});

test("returning to the sent value cancels an unsent intermediate drag", async () => {
  const a = await setup();
  a.calls.length = 0;
  a.el("bri").value = "100";
  await a.el("bri").userFire("input");
  await flush();
  a.el("bri").value = "50";
  await a.el("bri").userFire("input");
  a.el("bri").value = "100";
  await a.el("bri").userFire("change");
  a.tick(1000);
  await flush();
  assert.deepEqual(
    a.calls.filter((c) => c.path === "/set").map((c) => c.params.get("bri")),
    ["100"],
  );
});

test("drag deduplication is per hub and is invalidated by intervening tap commands", async () => {
  const a = await setup();
  a.calls.length = 0;
  a.el("bri").value = "100";
  await a.el("bri").userFire("input");
  await flush();
  await a.el("off").userFire("click");
  await flush();
  a.tick(1000);
  a.el("bri").value = "100";
  await a.el("bri").userFire("input");
  await flush();
  a.eval('settings.round.usage="nightlight";selectHub("WZ-594F");');
  await flush();
  a.tick(1000);
  a.el("bri").value = "100";
  await a.el("bri").userFire("input");
  await flush();
  assert.deepEqual(
    a.calls
      .filter((c) => c.path === "/set")
      .map((c) => [c.params.get("hub"), c.params.get("bri")]),
    [
      ["plug", "100"],
      ["plug", "0"],
      ["plug", "100"],
      ["round", "100"],
    ],
  );
});

test("volume and own-colour input/release also skip identical sends", async () => {
  const a = await setup();
  await a.buttons("[data-t]")[0].fire("click");
  a.calls.length = 0;
  a.el("vol").value = "12";
  await a.el("vol").userFire("input");
  await flush();
  a.tick(1000);
  await a.el("vol").userFire("input");
  await a.el("vol").userFire("change");
  a.el("col").value = "#123456";
  await a.el("col").userFire("input");
  await flush();
  a.tick(1000);
  await a.el("col").userFire("input");
  await a.el("col").userFire("change");
  a.tick(1000);
  await flush();
  assert.equal(a.calls.filter((c) => c.path === "/tone").length, 1);
  assert.equal(a.calls.filter((c) => c.path === "/set").length, 1);
});

test("Verwendung radio keyboard saves the new selection and respects the sending lock", async () => {
  const a = await setup({ "nightlight-mode": "erwachsen" });
  const night = a.buttons("[data-usage]")[0];
  const first = deferred();
  a.pending.push(() => first.promise);
  await night.userFire("keydown", { key: "ArrowRight" });
  assert.equal(a.calls.at(-1).params.get("usage"), "desk");
  const count = a.calls.length;
  await night.userFire("keydown", { key: "End" });
  assert.equal(a.calls.length, count);
  const settings = structuredClone(configDefaults);
  settings.plug.usage = "desk";
  first.resolve(response({ ok: true, settings }));
  await flush();
  assert.equal(
    a.buttons("[data-usage]")[1].getAttribute("aria-checked"),
    "true",
  );
  assert.equal(a.buttons("[data-usage]")[1].tabIndex, 0);
});

test("phone tabs remember each hub and keep Kind Desk read-only without a bar", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen" },
    false,
    {},
    { phone: true },
  );
  assert.equal(a.el("tabbar").hidden, false);
  assert.equal(a.eval("tabsByHub.plug"), "light");
  await a.el("tab-sounds").fire("click");
  assert.equal(a.storage.get("nightlight-tab-plug"), "sounds");
  assert.equal(a.el("panel-sounds").classList.contains("active-panel"), true);
  assert.equal(a.el("panel-light").classList.contains("active-panel"), false);
  await a.buttons("[data-hub]")[1].fire("click");
  await flush();
  await a.el("tab-desks").fire("click");
  assert.equal(a.storage.get("nightlight-tab-round"), "desks");
  await a.buttons("[data-hub]")[0].fire("click");
  assert.equal(a.eval("tabsByHub.plug"), "sounds");
  const b = await setup(
    Object.fromEntries(a.storage),
    false,
    {},
    { phone: true },
  );
  assert.equal(b.el("tab-sounds").getAttribute("aria-selected"), "true");
  await b.buttons("[data-hub]")[1].fire("click");
  await b.el("mode").fire("click");
  assert.equal(b.el("tabbar").hidden, true);
  assert.equal(b.el("panel-more").hidden, true);
  assert.equal(b.el("desk-controls").hidden, false);
  assert.equal(b.root.dataset.mode, "kind");
});

test("tab keyboard and desktop columns preserve the selected panel without actuation", async () => {
  const a = await setup({}, false, {}, { phone: true });
  a.calls.length = 0;
  await a.el("tab-light").fire("keydown", { key: "End" });
  assert.equal(a.eval("tabsByHub.plug"), "sounds");
  assert.equal(a.el("tab-sounds").tabIndex, 0);
  await a.el("tab-sounds").fire("keydown", { key: "ArrowRight" });
  assert.equal(a.eval("tabsByHub.plug"), "light");
  assert.equal(a.calls.length, 0);
  const b = await setup({ "nightlight-mode": "erwachsen" });
  assert.equal(b.el("tabbar").hidden, true);
  assert.match(html, /@media\s*\(min-width:\s*980px\)/);
  assert.match(html, /\.cols\s*>\s*\[data-panel\]\s*\{\s*display:\s*block/);
});

test("phone overflow is contained in a sheet and restores the real panel on close", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen" },
    false,
    {},
    { phone: true },
  );
  const panel = a.el("panel-light"),
    parent = panel.parentNode;
  await a.el("panel-more").fire("click");
  assert.equal(a.el("overflow-sheet").open, true);
  assert.equal(panel.parentNode, a.el("overflow-body"));
  a.el("overflow-sheet").close();
  assert.equal(panel.parentNode, parent);
  assert.equal(a.eval("overflowRestore"), null);
  assert.match(
    html,
    /html,\s*body\s*\{\s*height:\s*100%;\s*overflow:\s*hidden/,
  );
  assert.match(html, /height:\s*100dvh/);
  assert.match(html, /\.tabs\s*\{\s*height:\s*64px/);
  assert.match(html, /\.sheet\s*\{[^}]*overflow:\s*auto/s);
});

test("last sent information, loud tones and Kind doorbells open sheets", async () => {
  const a = await setup({}, false, {}, { phone: true });
  await a.el("light-info").fire("click");
  assert.equal(a.el("info-sheet").open, true);
  assert.equal(a.el("last-light").closest("dialog"), a.el("info-sheet"));
  await a.el("doorbell-toggle").fire("click");
  assert.equal(a.el("doorbell-sheet").open, true);
  assert.equal(a.el("tones-group-2").parentNode, a.el("doorbell-sheet-body"));
  a.el("doorbell-sheet").close();
  assert.equal(
    a.el("tones-group-2").parentNode,
    a.el("doorbell-toggle").closest(".grp"),
  );
  await a.el("loud-toggle").fire("pointerdown");
  a.tick(999);
  assert.ok(!a.el("loud-sheet").open);
  a.tick(1);
  assert.equal(a.el("loud-sheet").open, true);
  assert.equal(a.el("alarm-list").closest("dialog"), a.el("loud-sheet"));
  a.el("loud-sheet").close();
  assert.equal(a.el("alarm-list").hidden, true);
  await a.el("sound-options").fire("click");
  assert.equal(a.el("sound-duration").parentNode, a.el("sound-sheet-body"));
});

test("preview pause is device-local, persisted, reduced-motion safe and sends no command", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {},
    { phone: true, reducedMotion: true },
  );
  assert.equal(a.el("preview-pause").getAttribute("aria-pressed"), "true");
  assert.equal(a.el("preview-note").hidden, false);
  a.calls.length = 0;
  await a.el("preview-pause").fire("click");
  assert.equal(a.el("preview-pause").getAttribute("aria-pressed"), "false");
  assert.equal(a.calls.length, 0);
  await a.el("preview-pause").fire("click");
  assert.equal(a.storage.get("nightlight-preview-paused"), "1");
  const b = await setup(Object.fromEntries(a.storage));
  assert.equal(b.eval("previewPaused"), true);
  assert.match(html, /\.lpbtn\s*\{[^}]*width:\s*44px;\s*height:\s*44px/s);
});

test("preview uses last sent colour/confirmation and cycles all colours only on the page", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {},
    { phone: true },
  );
  a.eval(
    'signal={hub:"round",key:"regular:both",rule:settings.round.rules.regular,applied:{key:"regular:both",rgb:"FFA020",rgb2:"FFFFFF",bri:20,takt:2,mode:"steady",colors:["18C2B0","FFA020","AABBCC"],at:0,confirmed:true}};renderDesk();',
  );
  assert.match(a.el("desk-applied").textContent, /bestätigt/);
  assert.equal(a.el("lamp-preview").properties.get("--c"), "#FFA020");
  a.calls.length = 0;
  a.tick(2000);
  assert.equal(a.el("lamp-preview").properties.get("--c"), "#AABBCC");
  a.tick(2000);
  assert.equal(a.el("lamp-preview").properties.get("--c"), "#18C2B0");
  await a.el("preview-pause").fire("click");
  const colour = a.el("lamp-preview").properties.get("--c");
  a.tick(2000);
  assert.equal(a.el("lamp-preview").properties.get("--c"), colour);
  assert.equal(a.calls.length, 0);
  a.eval("signal.applied.confirmed=false;renderDesk();");
  assert.match(a.el("desk-applied").textContent, /nicht bestätigt/);
});

test("zero desks stays Unbekannt and arbitrary desk rows never invent counts", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {},
    { phone: true },
  );
  a.eval("settings.round.desks=[];renderDesk();");
  assert.equal(a.el("no-desks").hidden, false);
  assert.equal(a.el("desk-empty").hidden, false);
  assert.equal(a.el("multiple-settings").hidden, true);
  assert.match(a.el("desk-lit").textContent, /Unbekannt/);
  a.eval(
    'settings.round.desks=Array.from({length:8},(_,i)=>({id:String(i).padStart(32,"0"),short:"D"+i,name:"Example",url:"https://desk.invalid",rgb:"AABBCC",key_set:false,rules:settings.round.rules}));renderDesk();',
  );
  assert.equal(a.el("desk-list").children.length, 8);
  assert.equal(a.el("desk-signal-rows").children.length, 8);
  for (const row of a.el("desk-signal-rows").children)
    assert.match(row.querySelector(".dr-m").textContent, /keine Daten/);
  assert.equal(a.el("multiple-settings").hidden, false);
});

test("desk key POST is write-only, has an adult assertion and never enters retry/storage state", async () => {
  const saved = structuredClone(configDefaults);
  saved.round.desks = [{ ...fakeDesks[0], key_set: true, key_set_at: 1 }];
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {
      "/desk": (_url, options) => {
        const payload = JSON.parse(options.body);
        assert.equal(payload.key, "FAKE-UI-KEY-DO-NOT-USE");
        assert.equal(options.headers["X-Nightlight"], "1");
        assert.equal(options.headers["X-Nightlight-Mode"], "erwachsen");
        assert.equal(options.headers["Content-Type"], "application/json");
        return Promise.resolve(
          response({ ok: true, settings: saved, revoke: false }),
        );
      },
    },
    { phone: true },
  );
  await a.el("add-desk").fire("click");
  a.el("desk-short").value = "ABC";
  a.el("desk-name").value = "Example";
  a.el("desk-url").value = "https://desk.invalid";
  a.el("desk-key").value = "FAKE-UI-KEY-DO-NOT-USE";
  await a.el("desk-save").fire("click");
  await flush();
  const posted = a.calls.find((c) => c.path === "/desk");
  assert.equal(posted.options.method, "POST");
  assert.equal(posted.params.toString(), "");
  assert.equal(a.el("desk-key").value, "");
  assert.equal(a.eval("retryCommand"), null);
  assert.equal(a.eval("undoCommand"), null);
  assert.doesNotMatch(
    JSON.stringify(Object.fromEntries(a.storage)),
    /FAKE-UI-KEY/,
  );
  assert.equal(a.el("desk-sheet").open, false);
});

test("desk key tests refuse safely, clear input and cannot be triggered in Kind", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {
      "/desk-test": () =>
        Promise.resolve(
          response(
            { ok: false, error: "untrusted error must not be rendered" },
            400,
          ),
        ),
    },
    { phone: true },
  );
  await a.el("add-desk").fire("click");
  a.el("desk-key").value = "FAKE-UI-KEY-DO-NOT-USE";
  await a.el("desk-test").fire("click");
  assert.equal(a.el("desk-key").value, "");
  assert.match(
    a.el("desk-error").textContent,
    /mehr als Zählungen|nicht geprüft/,
  );
  assert.doesNotMatch(a.el("desk-error").textContent, /untrusted|FAKE/);
  const before = a.calls.length;
  await a.el("mode").fire("click");
  await a.el("desk-test").fire("click");
  await a.el("desk-save").fire("click");
  await a.el("add-desk").fire("click");
  assert.equal(a.calls.length, before);
  assert.equal(a.el("desk-sheet").open, false);
});

test("replace/remove require a separate confirm and show revocation help", async () => {
  const saved = structuredClone(configDefaults);
  const bodies = [];
  let failedCommit = false;
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {
      "/desk": (_url, options) => {
        bodies.push(JSON.parse(options.body));
        return Promise.resolve(
          response({ ok: !failedCommit, settings: saved, revoke: true }),
        );
      },
    },
    { phone: true },
  );
  a.eval('openDesk("ppm");');
  a.el("desk-key").value = "FAKE-UI-REPLACEMENT-DO-NOT-USE";
  await a.el("desk-save").fire("click");
  assert.equal(bodies.length, 0);
  assert.equal(a.el("desk-confirm").hidden, false);
  await a.el("desk-confirm-ok").fire("click");
  await flush();
  assert.equal(bodies[0].confirm, "replace");
  assert.equal(a.el("revoke-reminder").hidden, false);
  await a.el("revoke-how").fire("click");
  assert.equal(a.el("revoke-sheet").open, true);
  a.el("revoke-sheet").close();
  a.eval('openDesk("ppm");');
  await a.el("desk-remove").fire("click");
  assert.equal(bodies.length, 1);
  await a.el("desk-confirm-ok").fire("click");
  await flush();
  assert.equal(bodies[1].action, "remove");
  assert.equal(bodies[1].confirm, "remove");
  assert.equal(Object.hasOwn(bodies[1], "key"), false);
  failedCommit = true;
  a.el("revoke-reminder").hidden = true;
  a.eval('openDesk("ppm");');
  a.el("desk-key").value = "FAKE-UI-REPLACEMENT-DO-NOT-USE";
  await a.el("desk-save").fire("click");
  await a.el("desk-confirm-ok").fire("click");
  await flush();
  assert.equal(a.el("desk-sheet").open, true);
  assert.equal(a.el("revoke-reminder").hidden, false);
  assert.doesNotMatch(a.el("desk-error").textContent, /FAKE/);
});

test("saved keys never populate the password field and restored keys ask for re-entry", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.eval(
    'settings.round.desks[0].key_set=true;settings.round.desks[0].key_set_at=1;openDesk("ppm");',
  );
  assert.match(a.el("desk-key-state").textContent, /gesetzt seit/);
  assert.equal(a.el("desk-key").value, "");
  a.el("desk-key").value = "FAKE-UNSUBMITTED-KEY-DO-NOT-USE";
  a.el("desk-sheet").close();
  assert.equal(a.el("desk-key").value, "");
  a.eval('settings.round.desks[0].key_set=false;openDesk("ppm");');
  assert.equal(
    a.el("desk-key-state").textContent,
    "Schlüssel fehlt · neu eintragen",
  );
});

test("shared rules keep primary desk colour and optional overrides save the selected desk", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.eval('openRule("urgent");');
  assert.equal(a.el("rule-color-controls").hidden, true);
  assert.equal(a.el("rule-from-desk").hidden, false);
  assert.equal(a.el("rule-thresholds").hidden, false);
  await a
    .buttons("[data-rule-mode]")
    .find((b) => b.dataset.ruleMode === "alternate")
    .fire("click");
  assert.equal(a.el("rule-color-controls").hidden, false);
  assert.equal(a.eval("ruleSlot"), "rgb2");
  a.el("rule-color").value = "#abcdef";
  await a.el("rule-color").fire("input");
  assert.equal(a.eval("ruleDraft.rgb"), "18C2B0");
  assert.equal(a.eval("ruleDraft.rgb2"), "ABCDEF");
  a.el("rule-sheet").close();
  a.eval('openDesk("pma");');
  await a.el("desk-override").fire("click");
  assert.equal(a.el("desk-own-rules").hidden, false);
  await a.el("desk-own-rules").children[0].fire("click");
  assert.equal(a.eval("editingDeskRule"), "pma");
  a.pending.push((url) => {
    assert.equal(url.searchParams.get("desk"), "pma");
    assert.equal(url.searchParams.get("rule"), "urgent");
    return Promise.resolve(
      response({ ok: true, settings: structuredClone(configDefaults) }),
    );
  });
  await a.el("rule-save").fire("click");
  await flush();
  assert.equal(a.pending.length, 0);
});

test("overflow button uses measured panel capacity and Kind preserves the adult tab", async () => {
  const a = await setup(
    { "nightlight-mode": "erwachsen", "nightlight-hub": "WZ-594F" },
    false,
    {},
    { phone: true },
  );
  await a.el("tab-desks").fire("click");
  const panel = a.el("panel-desks");
  panel.clientHeight = 500;
  panel.scrollHeight = 400;
  a.eval("updateOverflowButton();");
  assert.equal(a.el("panel-more").hidden, true);
  panel.scrollHeight = 700;
  a.eval("updateOverflowButton();");
  assert.equal(a.el("panel-more").hidden, false);
  await a.el("mode").fire("click");
  assert.equal(a.eval("tabsByHub.round"), "desks");
  await a.el("mode").fire("pointerdown");
  a.tick(1000);
  await a.el("mode").fire("pointerup");
  assert.equal(a.el("tab-desks").getAttribute("aria-selected"), "true");
});

test("desk and multiple palettes keep unique bindings and an explicit replace entry", async () => {
  const a = await setup({
    "nightlight-mode": "erwachsen",
    "nightlight-hub": "WZ-594F",
  });
  a.eval(
    'settings.round.desks[0].key_set=true;settings.round.desks[0].key_set_at=1;openDesk("ppm");',
  );
  assert.equal(a.el("desk-key").hidden, true);
  assert.equal(a.el("desk-replace").hidden, false);
  await a.el("desk-replace").fire("click");
  assert.equal(a.el("desk-key").hidden, false);
  const colors = a.buttons("[data-desk-color]");
  assert.equal(colors.length, 6);
  for (const button of colors) {
    await button.fire("click");
    assert.equal(a.el("desk-color").value, "#" + button.dataset.deskColor);
  }
  a.el("desk-sheet").close();
  a.pending.push((url) => {
    assert.equal(url.pathname, "/settings");
    assert.equal(url.searchParams.get("multiple_rgb"), "FFA020");
    return Promise.resolve(
      response({ ok: true, settings: structuredClone(configDefaults) }),
    );
  });
  await a
    .buttons("[data-multiple-color]")
    .find((b) => b.dataset.multipleColor === "FFA020")
    .fire("click");
  await flush();
  assert.equal(a.pending.length, 0);
  assert.match(html, /\.pkc\.empty\s*\{[^}]*margin:\s*0\s*!important/s);
});
