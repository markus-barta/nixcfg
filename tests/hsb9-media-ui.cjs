// OPS-729/OPS-739: exercise the recording UI without launching a browser.
// A small fake DOM supports exactly the calls app.js makes. Only neutral
// synthetic data ("Beispielaufnahme …") is used.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const appPath = require.resolve("../hosts/hsb9/docker/media/app.js");
const serverPath = path.join(__dirname, "../hosts/hsb9/docker/media/app.py");
const browserGlobals = [
  "document",
  "navigator",
  "XMLHttpRequest",
  "window",
  "location",
  "history",
  "fetch",
];
const originalGlobals = new Map(
  browserGlobals.map((name) => [
    name,
    Object.getOwnPropertyDescriptor(globalThis, name),
  ]),
);
test.afterEach(() => {
  delete require.cache[appPath];
  for (const [name, descriptor] of originalGlobals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete globalThis[name];
  }
});
function freshApp() {
  delete require.cache[appPath];
  return require(appPath);
}

const spaceError =
  "Auf dem Gerät ist nicht genug Platz für dieses Video. Bitte die Betreuung verständigen.";
const unreadable =
  "Die Antwort konnte nicht gelesen werden. Bitte erneut versuchen.";
const serverError =
  "Die Aufnahmen sind gerade nicht erreichbar. Bitte in einem Moment erneut versuchen. Wenn es so bleibt, bitte die Betreuung verständigen.";

// ------------------------------------------------------------ fake DOM

class FakeText {
  constructor(data) {
    this.nodeType = 3;
    this.data = String(data);
    this.parentNode = null;
  }
  get textContent() {
    return this.data;
  }
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }
}
class FakeElement {
  constructor(document, tag, namespace) {
    this.ownerDocument = document;
    this.nodeType = 1;
    this.localName = tag;
    this.tagName = tag.toUpperCase();
    this.namespaceURI = namespace || "http://www.w3.org/1999/xhtml";
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.listeners = new Map();
    this.hidden = false;
    this.disabled = false;
    this.value = "";
    this.open = false;
    const props = new Map();
    this.style = {
      props,
      setProperty: (name, value) => props.set(name, String(value)),
      getPropertyValue: (name) => props.get(name) || "",
    };
    const element = this;
    this.classList = {
      add: (...names) => {
        const set = new Set(element.className.split(/\s+/).filter(Boolean));
        names.forEach((name) => set.add(name));
        element.className = [...set].join(" ");
      },
      remove: (...names) => {
        element.className = element.className
          .split(/\s+/)
          .filter((name) => name && !names.includes(name))
          .join(" ");
      },
      contains: (name) => element.className.split(/\s+/).includes(name),
      toggle: (name, force) => {
        const on = force === undefined ? !element.classList.contains(name) : force;
        if (on) element.classList.add(name);
        else element.classList.remove(name);
        return on;
      },
    };
    if (tag === "video") {
      this.readyState = 0;
      this.currentTime = 0;
      this.duration = NaN;
      this.plays = 0;
      this.play = () => {
        this.plays++;
        return Promise.resolve();
      };
      this.pause = () => {
        this.paused = true;
      };
      // Like the media load algorithm: a new or removed source starts over.
      this.load = () => {
        this.readyState = 0;
        this.currentTime = 0;
        this.duration = NaN;
      };
    }
  }
  get id() {
    return this.getAttribute("id") || "";
  }
  set id(value) {
    this.setAttribute("id", value);
  }
  get className() {
    return this.getAttribute("class") || "";
  }
  set className(value) {
    this.setAttribute("class", value);
  }
  get src() {
    return this.getAttribute("src") || "";
  }
  set src(value) {
    this.setAttribute("src", value);
    if (this.load) this.load();
  }
  get children() {
    return this.childNodes.filter((node) => node.nodeType === 1);
  }
  get lastChild() {
    return this.childNodes[this.childNodes.length - 1] || null;
  }
  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node === this.ownerDocument.body;
  }
  get textContent() {
    return this.childNodes.map((node) => node.textContent).join("");
  }
  set textContent(value) {
    this.replaceChildren();
    if (value !== "" && value !== null && value !== undefined)
      this.append(String(value));
  }
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }
  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }
  removeAttribute(name) {
    this.attributes.delete(name);
  }
  hasAttribute(name) {
    return this.attributes.has(name);
  }
  removeChild(child) {
    this.childNodes = this.childNodes.filter((node) => node !== child);
    child.parentNode = null;
  }
  append(...items) {
    for (const item of items) {
      const node =
        typeof item === "string" || typeof item === "number"
          ? new FakeText(item)
          : item;
      if (node.parentNode) node.parentNode.removeChild(node);
      node.parentNode = this;
      this.childNodes.push(node);
    }
  }
  replaceChildren(...items) {
    for (const node of this.childNodes) node.parentNode = null;
    this.childNodes = [];
    this.append(...items);
  }
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }
  replaceWith(node) {
    const parent = this.parentNode;
    if (!parent) return;
    const index = parent.childNodes.indexOf(this);
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = parent;
    parent.childNodes.splice(index, 1, node);
    this.parentNode = null;
  }
  addEventListener(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(callback);
  }
  removeEventListener(type, callback) {
    const list = this.listeners.get(type) || [];
    this.listeners.set(
      type,
      list.filter((item) => item !== callback),
    );
  }
  dispatch(type, extra = {}) {
    const event = {
      type,
      target: this,
      currentTarget: this,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true;
      },
      stopPropagation() {},
      ...extra,
    };
    for (const callback of [...(this.listeners.get(type) || [])])
      callback(event);
    return event;
  }
  click() {
    return this.dispatch("click");
  }
  focus() {
    this.ownerDocument.activeElement = this;
  }
  showModal() {
    this.open = true;
  }
  // Like browsers, the "close" event is a queued task, not dispatched inline:
  // code that re-opens a dialog in the same task sees it arrive afterwards.
  close() {
    if (!this.open) return;
    this.open = false;
    setImmediate(() => this.dispatch("close"));
  }
  matches() {
    return false;
  }
  getContext() {
    return { drawImage() {} };
  }
}
function walk(root, visit) {
  visit(root);
  for (const child of root.childNodes || [])
    if (child.nodeType === 1) walk(child, visit);
}
function findAll(root, predicate) {
  const found = [];
  walk(root, (node) => {
    if (predicate(node)) found.push(node);
  });
  return found;
}
function hasClass(node, name) {
  return node.className.split(/\s+/).includes(name);
}
function byClass(root, name) {
  return findAll(root, (node) => hasClass(node, name));
}
function buttonByText(root, text) {
  return findAll(
    root,
    (node) =>
      node.localName === "button" &&
      node.textContent.trim() === text &&
      shown(node),
  );
}
function shown(node) {
  for (let current = node; current; current = current.parentNode) {
    if (current.hidden) return false;
    if (current.localName === "dialog" && !current.open) return false;
  }
  return true;
}
// Every string a user can see or hear: text, labels, placeholders, titles.
function userStrings(root) {
  const strings = [];
  walk(root, (node) => {
    if (!shown(node)) return;
    for (const child of node.childNodes)
      if (child.nodeType === 3 && child.data.trim()) strings.push(child.data.trim());
    for (const name of ["aria-label", "placeholder", "title"]) {
      const value = node.getAttribute(name);
      if (value) strings.push(value);
    }
  });
  return strings;
}

// ------------------------------------------------------------ page harness

function sample(number, extra = {}) {
  return {
    filename: `Beispielaufnahme ${number}.mp4`,
    title: `Beispielaufnahme ${number}`,
    description: "Eine kurze Beispielbeschreibung.",
    channel: "Beispielsender",
    recorded: "2026-01-02",
    duration_min: 45,
    added: `2026-01-0${number}T12:00:00+00:00`,
    trash: false,
    video_url: `/fernsehen/video/Beispielaufnahme%20${number}.mp4`,
    ...extra,
  };
}

async function page({
  available = 100,
  wake = "supported",
  invalidJSON = false,
  responseStatus = 200,
  errorMessage,
  errorCode,
  videos = [],
  trash = [],
  languages = ["de-AT", "de"],
  stored = {},
  search = "",
  hash = "",
  routes = {},
} = {}) {
  const document = {
    activeElement: null,
    visibilityState: "visible",
    title: "",
    documentElement: { lang: "de" },
    listeners: new Map(),
    addEventListener(type, callback) {
      this.listeners.set(type, callback);
    },
    removeEventListener(type) {
      this.listeners.delete(type);
    },
    createElement(tag) {
      return new FakeElement(document, tag);
    },
    createElementNS(namespace, tag) {
      return new FakeElement(document, tag, namespace);
    },
    getElementById(id) {
      return findAll(document.body, (node) => node.id === id)[0] || null;
    },
  };
  document.body = new FakeElement(document, "body");
  const root = new FakeElement(document, "div");
  root.id = "app";
  document.body.append(root);

  const values = new Map(Object.entries(stored));
  const localStorage = {
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
  const timers = [];
  let now = 0;
  const window = {
    localStorage,
    listeners: new Map(),
    addEventListener(type, callback) {
      if (!this.listeners.has(type)) this.listeners.set(type, []);
      this.listeners.get(type).push(callback);
    },
    removeEventListener(type, callback) {
      this.listeners.set(
        type,
        (this.listeners.get(type) || []).filter((item) => item !== callback),
      );
    },
    dispatch(type, extra = {}) {
      for (const callback of this.listeners.get(type) || [])
        callback({ type, preventDefault() {}, ...extra });
    },
    setTimeout(callback, delay) {
      timers.push({ callback, delay, due: now + delay, active: true });
      return timers.length;
    },
    clearTimeout(id) {
      if (timers[id - 1]) timers[id - 1].active = false;
    },
  };
  const location = { pathname: "/fernsehen/", search, hash };
  const entries = [{ state: null, search, hash }];
  const setUrl = (url) => {
    const parsed = new URL(url, "http://hsb9.test" + location.pathname);
    location.pathname = parsed.pathname;
    location.search = parsed.search;
    location.hash = parsed.hash;
  };
  const history = {
    pushes: [],
    get state() {
      return entries[entries.length - 1].state;
    },
    pushState(state, _title, url) {
      setUrl(url);
      entries.push({ state, search: location.search, hash: location.hash });
      this.pushes.push(url);
    },
    replaceState(state, _title, url) {
      setUrl(url);
      entries[entries.length - 1] = {
        state,
        search: location.search,
        hash: location.hash,
      };
    },
    back() {
      if (entries.length < 2) return;
      entries.pop();
      const entry = entries[entries.length - 1];
      location.search = entry.search;
      location.hash = entry.hash;
      window.dispatch("popstate");
    },
  };
  const locks = [];
  const navigator = { languages, language: languages[0] };
  if (wake !== "unsupported")
    navigator.wakeLock = {
      async request(kind) {
        assert.equal(kind, "screen");
        if (wake === "denied") throw new Error("synthetic denial");
        const lock = {
          released: false,
          releases: 0,
          async release() {
            this.released = true;
            this.releases++;
          },
        };
        locks.push(lock);
        return lock;
      },
    };
  const uploads = [];
  class XMLHttpRequest {
    constructor() {
      this.upload = {};
      this.headers = {};
      uploads.push(this);
    }
    open(method, url) {
      this.method = method;
      this.url = url;
    }
    setRequestHeader(name, value) {
      this.headers[name] = value;
    }
    send(file) {
      this.sent = file;
    }
    abort() {
      this.aborted = true;
      this.onabort();
    }
  }
  const requests = [];
  const fetch = async (url, options = {}) => {
    const method = options.method || "GET";
    requests.push({ url, method, headers: options.headers || {}, body: options.body });
    const route = routes[`${method} ${url}`];
    if (route) return route(options);
    const ok = responseStatus >= 200 && responseStatus < 300;
    return {
      ok,
      status: responseStatus,
      async json() {
        if (invalidJSON) throw new SyntaxError("synthetic non-JSON");
        if (errorMessage || errorCode) return { error: errorMessage, code: errorCode };
        if (url.endsWith("?trash=1"))
          return { videos: trash, free_bytes: available + 20, reserve_bytes: 20 };
        return { videos, free_bytes: available + 20, reserve_bytes: 20 };
      },
    };
  };
  const globals = { document, navigator, XMLHttpRequest, window, location, history, fetch };
  for (const [name, value] of Object.entries(globals))
    Object.defineProperty(globalThis, name, {
      value,
      configurable: true,
      writable: true,
      enumerable: true,
    });
  const app = freshApp();
  await app.start();
  await new Promise(setImmediate);
  return {
    app,
    document,
    window,
    root,
    values,
    history,
    location,
    timers,
    async elapse(milliseconds) {
      now += milliseconds;
      // Only timers already due at this point; timers created by their async
      // work start at the new clock time and need a separate advance.
      for (const timer of [...timers]) {
        if (!timer.active || timer.due > now) continue;
        timer.active = false;
        timer.callback();
      }
      await settle();
    },
    uploads,
    locks,
    requests,
    toasts: () =>
      byClass(root, "toast").map((node) => byClass(node, "toast-text")[0].textContent),
    lastToast() {
      const list = this.toasts();
      return list[list.length - 1];
    },
    cards: () => byClass(root, "card").filter((node) => !hasClass(node, "skeleton")),
    dialog: (className) => findAll(root, (node) => node.localName === "dialog" && hasClass(node, className))[0],
    async upload(size = 10, name = "Beispiel.mp4") {
      await app.startUpload({ name, size });
    },
  };
}
const settle = () => new Promise(setImmediate);

// ------------------------------------------------------------ language

test("language default walks navigator.languages, primary subtag only", () => {
  const app = freshApp();
  const cases = [
    [["fr-FR", "de-AT", "en"], "de"],
    [["en-US", "de"], "en"],
    [["fr", "it"], "en"],
    [["DE-ch"], "de"],
    [[], "en"],
  ];
  for (const [languages, expected] of cases)
    assert.equal(app.browserLanguage({ languages }), expected, languages.join());
  assert.equal(app.browserLanguage({ languages: [], language: "de-DE" }), "de");
  assert.equal(app.browserLanguage({ language: "pt-BR" }), "en");
  assert.equal(app.browserLanguage(undefined), "en");
});

test("a stored hostdash.lang choice overrides the browser; only de/en count", () => {
  const app = freshApp();
  assert.equal(app.LANG_KEY, "hostdash.lang");
  const store = (value) => ({ getItem: (key) => (key === "hostdash.lang" ? value : null) });
  assert.equal(app.resolveLanguage({ languages: ["en-GB"] }, store("de")), "de");
  assert.equal(app.resolveLanguage({ languages: ["de-AT"] }, store("en")), "en");
  for (const invalid of ["fr", "DE", "", null, "de-AT"])
    assert.equal(app.resolveLanguage({ languages: ["de-AT"] }, store(invalid)), "de");
  const throwing = { getItem() { throw new Error("synthetic denied"); } };
  assert.equal(app.resolveLanguage({ languages: ["de"] }, throwing), "de");
});

test("the page follows the browser language and sets <html lang>", async () => {
  const german = await page({ languages: ["fr-FR", "de-AT"], videos: [sample(1)] });
  assert.equal(german.document.documentElement.lang, "de");
  assert.equal(german.document.getElementById("page-title").textContent, "Fernsehaufnahmen");
  const english = await page({ languages: ["en-US"], videos: [sample(1)] });
  assert.equal(english.document.documentElement.lang, "en");
  assert.equal(english.document.getElementById("page-title").textContent, "TV recordings");
  assert.equal(english.document.title, "TV recordings");
  const stored = await page({ languages: ["en-US"], stored: { "hostdash.lang": "de" } });
  assert.equal(stored.document.documentElement.lang, "de");
});

test("the switch persists the choice and re-renders in place", async () => {
  const ui = await page({ languages: ["de-AT"], videos: [sample(1)] });
  const en = findAll(ui.root, (node) => node.localName === "button" && node.getAttribute("lang") === "en")[0];
  const de = findAll(ui.root, (node) => node.localName === "button" && node.getAttribute("lang") === "de")[0];
  assert.equal(de.getAttribute("aria-pressed"), "true");
  const search = ui.document.getElementById("search");
  search.value = "Beispiel";
  search.dispatch("input");
  en.click();
  assert.equal(ui.values.get("hostdash.lang"), "en");
  assert.equal(ui.document.documentElement.lang, "en");
  assert.equal(en.getAttribute("aria-pressed"), "true");
  assert.equal(de.getAttribute("aria-pressed"), "false");
  assert.equal(ui.document.getElementById("page-title").textContent, "TV recordings");
  assert.equal(buttonByText(ui.root, "Edit").length, 1);
  assert.equal(ui.document.getElementById("search").value, "Beispiel", "search text survives");
  assert.equal(ui.cards().length, 1);
  de.click();
  assert.equal(ui.values.get("hostdash.lang"), "de");
  assert.equal(buttonByText(ui.root, "Bearbeiten").length, 1);
});

test("a storage event for hostdash.lang (e.g. from HostDash) switches the page", async () => {
  const ui = await page({ languages: ["de-AT"], videos: [sample(1)] });
  ui.values.set("hostdash.lang", "en");
  ui.window.dispatch("storage", { key: "unrelated" });
  assert.equal(ui.document.documentElement.lang, "de");
  ui.window.dispatch("storage", { key: "hostdash.lang", newValue: "en" });
  assert.equal(ui.document.documentElement.lang, "en");
  assert.equal(ui.document.getElementById("page-title").textContent, "TV recordings");
  ui.values.set("hostdash.lang", "fr");
  ui.window.dispatch("storage", { key: "hostdash.lang", newValue: "fr" });
  assert.equal(ui.document.documentElement.lang, "de", "invalid values fall back to the browser");
  ui.values.set("hostdash.lang", "en");
  ui.window.dispatch("storage", { key: null });
  assert.equal(ui.document.documentElement.lang, "en");
});

test("dictionaries match key for key, placeholder for placeholder", () => {
  const { STRINGS } = freshApp();
  assert.deepEqual(Object.keys(STRINGS.de).sort(), Object.keys(STRINGS.en).sort());
  const placeholders = (value) =>
    JSON.stringify(value).match(/\{\w+\}/g)?.sort().join() || "";
  for (const key of Object.keys(STRINGS.de))
    assert.equal(placeholders(STRINGS.de[key]), placeholders(STRINGS.en[key]), key);
});

test("plural and number formatting follow the language", async () => {
  const ui = await page({ languages: ["de-AT"], videos: [sample(1)], available: 109.2e9 });
  const sub = byClass(ui.root, "hero-sub")[0].textContent;
  assert.match(sub, /^1 Aufnahme/);
  assert.equal(ui.document.getElementById("space").textContent, "Noch frei: 109,2 GB");
  ui.app.setLanguage("en", true);
  assert.match(byClass(ui.root, "hero-sub")[0].textContent, /^1 recording/);
  assert.equal(ui.document.getElementById("space").textContent, "Space left: 109.2 GB");
  assert.match(byClass(ui.root, "card-meta")[0].textContent, /2 January 2026 · 45 min$/);
  ui.app.setLanguage("de", true);
  assert.match(byClass(ui.root, "card-meta")[0].textContent, /2\. Jänner 2026 · 45 Min\.$/);
});

test("no known English UI strings appear in German mode", async () => {
  const ui = await page({
    languages: ["de-AT"],
    videos: [sample(1), sample(2, { thumb_url: "/fernsehen/thumb/x.jpg?v=1" })],
    trash: [sample(3, { trash: true })],
    stored: { "hsb9-media.progress": JSON.stringify({ "Beispielaufnahme 1.mp4": { t: 300, d: 2700, at: 1 } }) },
  });
  const english = /\b(Add video|Edit|Delete|Trash|Restore|Search|Sort|Continue watching|Watched|Close|Cancel|Save|Home|Recently added|Recording date|recordings?|Space left|left|Undo|Player|Language|View|All)\b/;
  const check = () => {
    for (const text of userStrings(ui.root))
      assert.doesNotMatch(text, english, `English in German mode: ${text}`);
  };
  check();
  byClass(ui.cards()[0], "card-link")[0].click();
  check();
  buttonByText(ui.root, "Bearbeiten")[0].click();
  check();
});

// ------------------------------------------------------------ errors

test("server error codes map to localized text, else the server message", () => {
  const app = freshApp();
  const german = "Diese Aufnahme wurde nicht gefunden.";
  assert.equal(app.problemText({ code: "not_found", error: german }, "en"), "This recording was not found.");
  assert.equal(app.problemText({ code: "not_found", error: german }, "de"), german);
  assert.equal(
    app.problemText({ code: "invalid_text", error: "x", limit: 200 }, "en"),
    "Please enter at most 200 characters.",
  );
  assert.equal(app.problemText({ code: "something_new", error: "Servertext" }, "en"), "Servertext");
  assert.equal(app.problemText({ error: "Servertext" }, "en"), "Servertext");
  assert.equal(app.problemText({}, "en"), "Sorry, that didn't work. Please try again.");
  assert.equal(app.problemText(null, "de"), "Das hat leider nicht geklappt. Bitte erneut versuchen.");
});

test("every code the server can send has German and English text", () => {
  const { STRINGS } = freshApp();
  const source = fs.readFileSync(serverPath, "utf8").replace(/\s+/g, " ");
  const codes = new Set();
  for (const match of source.matchAll(/Problem\(\d+, (?:[^()]|\([^()]*\))*?"([a-z]+(?:_[a-z]+)*)"/g))
    codes.add(match[1]);
  for (const match of source.matchAll(/code="([a-z_]+)"/g)) codes.add(match[1]);
  for (const match of source.matchAll(/content_length\([^)]*"([a-z]+(?:_[a-z]+)+)"/g)) codes.add(match[1]);
  assert.ok(codes.size >= 18, [...codes].join());
  for (const code of codes) {
    assert.ok(STRINGS.de["error." + code], "de " + code);
    assert.ok(STRINGS.en["error." + code], "en " + code);
  }
});

test("listing errors with a code are localized; unknown codes keep the German message", async () => {
  const english = await page({
    languages: ["en-GB"],
    responseStatus: 503,
    errorCode: "metadata_unreadable",
    errorMessage: "Die Angaben können gerade nicht gelesen werden. Bitte die Betreuung verständigen.",
  });
  assert.equal(
    english.document.getElementById("load-error").textContent,
    "The details can't be read right now. Please contact your helper.",
  );
  const unknown = await page({ languages: ["en-GB"], responseStatus: 503, errorCode: "future_code", errorMessage: "Deutscher Servertext" });
  assert.equal(unknown.document.getElementById("load-error").textContent, "Deutscher Servertext");
});

// ------------------------------------------------------------ progress

test("progress store: save, watched threshold, ended, and bounded size", () => {
  const app = freshApp();
  let store = app.nextProgress({}, "a.mp4", 61.24, 600, 1000);
  assert.deepEqual(store["a.mp4"], { at: 1000, d: 600, t: 61.2 });
  store = app.nextProgress(store, "a.mp4", 569, 600, 2000);
  assert.deepEqual(store["a.mp4"], { at: 2000, d: 600, t: 569 }, "94.8 % is not watched yet");
  store = app.nextProgress(store, "a.mp4", 570, 600, 3000);
  assert.deepEqual(store["a.mp4"], { at: 3000, d: 600, watched: true }, "95 % drops t");
  store = app.nextProgress(store, "a.mp4", 30, undefined, 4000);
  assert.deepEqual(store["a.mp4"], { at: 4000, d: 600, t: 30, watched: true }, "re-watching keeps the mark");
  store = app.nextProgress(store, "b.mp4", 12, undefined, 5000, true);
  assert.deepEqual(store["b.mp4"], { at: 5000, watched: true }, "ended marks watched");
  let big = {};
  for (let index = 0; index < 305; index++)
    big = app.nextProgress(big, `${index}.mp4`, 20, 100, index);
  assert.equal(Object.keys(big).length, 300);
  assert.ok(!("0.mp4" in big) && "304.mp4" in big, "the oldest entries go first");
});

test("progress store: corrupt or foreign storage reads as empty", () => {
  const app = freshApp();
  const read = (raw) => app.readProgress({ getItem: () => raw });
  for (const raw of ["{broken", "[]", "null", "42", '"text"', null, ""])
    assert.deepEqual(read(raw), {}, String(raw));
  assert.deepEqual(app.readProgress({ getItem() { throw new Error("denied"); } }), {});
  assert.deepEqual(
    read(JSON.stringify({
      "a.mp4": { t: 12, d: 100, at: 5 },
      "b.mp4": { t: "12" },
      "c.mp4": [],
      "d.mp4": { watched: true, d: -1 },
      "e.mp4": { t: -3, d: Infinity },
      "f.mp4": null,
    })),
    { "a.mp4": { t: 12, d: 100, at: 5 }, "d.mp4": { watched: true } },
  );
  const writes = [];
  app.writeProgress({ setItem: (key, value) => writes.push([key, value]) }, { "a.mp4": { t: 1 } });
  assert.deepEqual(writes, [["hsb9-media.progress", '{"a.mp4":{"t":1}}']]);
  assert.doesNotThrow(() => app.writeProgress({ setItem() { throw new Error("quota"); } }, {}));
});

test("partly watched recordings show progress and a Weiterschauen row; finished ones a mark", async () => {
  const progress = {
    "Beispielaufnahme 1.mp4": { t: 900, d: 2700, at: 20 },
    "Beispielaufnahme 2.mp4": { d: 2700, at: 10, watched: true },
  };
  const ui = await page({
    videos: [sample(1), sample(2), sample(3)],
    stored: { "hsb9-media.progress": JSON.stringify(progress) },
  });
  const section = byClass(ui.root, "resume-grid")[0].parentNode;
  assert.equal(section.hidden, false);
  const tiles = byClass(ui.root, "resume-tile");
  assert.equal(tiles.length, 1);
  assert.match(tiles[0].textContent, /Beispielaufnahme 1.*Noch 30 Min\./);
  const card = (number) => ui.cards().find((node) => node.getAttribute("data-filename") === `Beispielaufnahme ${number}.mp4`);
  const fill = byClass(card(1), "poster-progress-fill")[0];
  assert.equal(Number(fill.style.getPropertyValue("--p")).toFixed(3), "0.333");
  assert.equal(byClass(card(2), "chip-watched")[0].textContent, "Gesehen");
  assert.equal(byClass(card(3), "poster-progress").length + byClass(card(3), "chip-watched").length, 0);
  const corrupt = await page({ videos: [sample(1)], stored: { "hsb9-media.progress": "{broken" } });
  assert.equal(byClass(corrupt.root, "resume-tile").length, 0);
});

test("the player offers Weiter ab / Von vorne, mirrors the URL hash and saves progress", async () => {
  const ui = await page({
    videos: [sample(1)],
    stored: { "hsb9-media.progress": JSON.stringify({ "Beispielaufnahme 1.mp4": { t: 754, d: 2700, at: 1 } }) },
  });
  byClass(ui.cards()[0], "card-link")[0].click();
  const player = ui.dialog("player");
  assert.equal(player.open, true);
  assert.equal(ui.location.hash, "#play=Beispielaufnahme%201.mp4");
  const resume = byClass(player, "resume")[0];
  assert.equal(resume.hidden, false);
  assert.equal(buttonByText(player, "Weiter ab 12:34").length, 1);
  assert.equal(buttonByText(player, "Von vorne").length, 1);
  const video = findAll(player, (node) => node.localName === "video")[0];
  assert.equal(video.src, "/fernsehen/video/Beispielaufnahme%201.mp4");
  buttonByText(player, "Von vorne")[0].click();
  assert.equal(resume.hidden, true);
  assert.equal(video.plays, 1);
  video.readyState = 1;
  video.duration = 2700;
  video.currentTime = 754;
  video.dispatch("loadedmetadata");
  assert.equal(video.currentTime, 0, "Von vorne wins over the resume seek");
  video.readyState = 4;
  video.currentTime = 2600;
  video.dispatch("pause");
  const saved = JSON.parse(ui.values.get("hsb9-media.progress"))["Beispielaufnahme 1.mp4"];
  assert.equal(saved.watched, true);
  assert.equal(saved.t, undefined);
  buttonByText(player, "Schließen")[0].click();
  assert.equal(player.open, false);
  assert.equal(ui.location.hash, "", "Back undid the pushed hash");
  assert.equal(video.getAttribute("src"), null, "closing stops loading the video");
  // Opening from the hash (e.g. after a reload) and Back/Esc close it again.
  ui.location.hash = "#play=Beispielaufnahme%201.mp4";
  ui.window.dispatch("hashchange");
  assert.equal(player.open, true);
  player.dispatch("cancel");
  assert.equal(player.open, false);
  assert.equal(ui.location.hash, "");
});

test("closing before the video has loaded keeps the resume point (slow or failed loading)", async () => {
  const name = "Beispielaufnahme 1.mp4";
  const stored = { "hsb9-media.progress": JSON.stringify({ [name]: { t: 754, d: 2700, at: 1 } }) };
  const saved = (ui) => JSON.parse(ui.values.get("hsb9-media.progress"))[name];
  const ui = await page({ videos: [sample(1)], stored });
  const player = ui.dialog("player");
  const video = findAll(player, (node) => node.localName === "video")[0];
  const open = () => byClass(ui.cards()[0], "card-link")[0].click();
  // Slow: closed while the resume prompt still waits for the metadata, with
  // a stray pause event on the way (currentTime still reads 0).
  open();
  assert.equal(video.readyState, 0);
  video.dispatch("pause");
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(saved(ui).t, 754, "a pause before loading saves nothing new");
  assert.equal(byClass(ui.root, "resume-tile").length, 1, "still offered under Weiterschauen");
  // Slow after choosing "Weiter ab": the seek is still pending at Esc.
  open();
  buttonByText(player, "Weiter ab 12:34")[0].click();
  player.dispatch("cancel");
  await settle();
  assert.equal(player.open, false);
  assert.equal(saved(ui).t, 754);
  // Slow from the Weiterschauen row, which resumes without asking.
  byClass(ui.root, "resume-tile")[0].click();
  assert.equal(player.open, true);
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(saved(ui).t, 754);
  // Failed: the video never loads.
  open();
  video.dispatch("error");
  assert.equal(byClass(player, "player-error")[0].hidden, false);
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(saved(ui).t, 754, "a failed load keeps the progress");
  // Once the metadata has loaded, the resume seek applies and the real
  // position is saved again.
  open();
  video.readyState = 1;
  video.duration = 2700;
  video.dispatch("loadedmetadata");
  assert.equal(video.currentTime, 754);
  video.currentTime = 800;
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(saved(ui).t, 800);
  // Only an explicit "Von vorne" may drop the progress before loading.
  open();
  buttonByText(player, "Von vorne")[0].click();
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(saved(ui).t, 0);
  assert.equal(byClass(ui.root, "resume-tile").length, 0);
});

test("switching recordings through the URL hash keeps the new one open", async () => {
  const stored = {
    "hsb9-media.progress": JSON.stringify({
      "Beispielaufnahme 1.mp4": { t: 300, d: 2700, at: 1 },
      "Beispielaufnahme 2.mp4": { t: 600, d: 2700, at: 2 },
    }),
  };
  const ui = await page({ videos: [sample(1), sample(2)], stored });
  const card = (number) => ui.cards().find((node) => node.getAttribute("data-filename") === `Beispielaufnahme ${number}.mp4`);
  const opener = byClass(card(1), "card-link")[0];
  opener.focus();
  opener.click();
  const player = ui.dialog("player");
  const video = findAll(player, (node) => node.localName === "video")[0];
  video.readyState = 1;
  video.duration = 2700;
  video.dispatch("loadedmetadata");
  video.currentTime = 420;
  ui.location.hash = "#play=Beispielaufnahme%202.mp4";
  ui.window.dispatch("hashchange");
  // Browsers deliver a dialog's close event later; let any queued one arrive.
  await settle();
  await settle();
  assert.equal(player.open, true, "the second recording stays open");
  assert.equal(ui.location.hash, "#play=Beispielaufnahme%202.mp4");
  assert.equal(video.src, "/fernsehen/video/Beispielaufnahme%202.mp4");
  assert.equal(findAll(player, (node) => hasClass(node, "player-title"))[0].textContent, "Beispielaufnahme 2");
  assert.equal(buttonByText(player, "Weiter ab 10:00").length, 1);
  const progress = JSON.parse(ui.values.get("hsb9-media.progress"));
  assert.equal(progress["Beispielaufnahme 1.mp4"].t, 420, "the first recording's position is saved");
  assert.equal(progress["Beispielaufnahme 2.mp4"].t, 600, "the second one's is untouched");
  // A close event that arrives after the dialog was opened again is stale.
  player.close();
  player.showModal();
  await settle();
  assert.equal(player.open, true);
  assert.equal(ui.location.hash, "#play=Beispielaufnahme%202.mp4");
  // A real close still closes, and focus leaves the closed player for the page.
  buttonByText(player, "Schließen")[0].click();
  await settle();
  assert.equal(player.open, false);
  assert.equal(ui.location.hash, "");
  const focused = ui.document.activeElement;
  let insidePlayer = false;
  for (let node = focused; node; node = node.parentNode) if (node === player) insidePlayer = true;
  assert.ok(focused && focused.isConnected && !insidePlayer, "focus returns to the page, not into the closed player");
});

test("a stale close event never cancels a re-opened confirm or edit dialog", async () => {
  const video = sample(1);
  const calls = [];
  const json = (body) => async (options) => {
    calls.push(options);
    return { ok: true, status: 200, json: async () => body };
  };
  const ui = await page({
    videos: [video],
    routes: {
      "DELETE /fernsehen/api/videos/Beispielaufnahme%201.mp4": json({ ...video, trash: true }),
      "PATCH /fernsehen/api/videos/Beispielaufnahme%201.mp4": json({ ...video, title: "Beispiel neu" }),
    },
  });
  // Microtasks only: the queued close event has not been delivered yet.
  const microtasks = async () => {
    for (let index = 0; index < 10; index++) await Promise.resolve();
  };
  const confirm = ui.dialog("sheet-small");
  buttonByText(ui.cards()[0], "Löschen")[0].click();
  buttonByText(confirm, "Abbrechen")[0].click();
  await microtasks();
  buttonByText(ui.cards()[0], "Löschen")[0].click();
  assert.equal(confirm.open, true);
  await settle();
  assert.equal(confirm.open, true, "the first close event does not cancel the second confirm");
  buttonByText(confirm, "In den Papierkorb")[0].click();
  await settle();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "DELETE");

  const again = await page({
    videos: [video],
    routes: { "PATCH /fernsehen/api/videos/Beispielaufnahme%201.mp4": json({ ...video, title: "Beispiel neu" }) },
  });
  const edit = again.dialog("sheet");
  buttonByText(again.cards()[0], "Bearbeiten")[0].click();
  buttonByText(edit, "Abbrechen")[0].click();
  buttonByText(again.cards()[0], "Bearbeiten")[0].click();
  await settle();
  assert.equal(edit.open, true);
  findAll(edit, (node) => node.localName === "form")[0].dispatch("submit");
  await settle();
  assert.equal(calls.length, 2, "Speichern still knows which recording it edits");
  assert.equal(calls[1].method, "PATCH");
  assert.equal(edit.open, false);
});

// ------------------------------------------------------------ rendering

test("cards render real thumbnails or a deterministic fallback poster", async () => {
  const withThumb = sample(1, { thumb_url: "/fernsehen/thumb/Beispielaufnahme%201.mp4.jpg?v=123" });
  const without = sample(2, { channel: "", duration_min: null });
  const ui = await page({ videos: [withThumb, without] });
  const [first, second] = ["Beispielaufnahme 1.mp4", "Beispielaufnahme 2.mp4"].map((name) =>
    ui.cards().find((node) => node.getAttribute("data-filename") === name),
  );
  const image = findAll(first, (node) => node.localName === "img")[0];
  assert.equal(image.src, withThumb.thumb_url);
  assert.equal(image.getAttribute("alt"), "");
  assert.equal(byClass(first, "poster-fallback").length, 0);
  assert.equal(byClass(first, "chip-channel")[0].textContent, "Beispielsender");
  assert.equal(byClass(first, "chip-duration")[0].textContent, "45 Min.");
  const fallback = byClass(second, "poster-fallback")[0];
  assert.equal(findAll(second, (node) => node.localName === "img").length, 0);
  assert.equal(byClass(fallback, "poster-fallback-title")[0].textContent, "Beispielaufnahme 2");
  assert.ok(hasClass(fallback, "tone-" + ui.app.paletteIndex("Beispielaufnahme 2")));
  assert.equal(byClass(second, "chip-channel").length, 0);
  // The whole card has one link (title), whose overlay covers the image.
  const links = findAll(first, (node) => node.localName === "a");
  assert.equal(links.length, 1);
  assert.equal(links[0].getAttribute("href"), "#play=Beispielaufnahme%201.mp4");
  assert.equal(links[0].textContent, "Beispielaufnahme 1");
  // A broken thumbnail falls back to the designed poster.
  image.dispatch("error");
  assert.equal(byClass(first, "poster-fallback").length, 1);
  const app = ui.app;
  assert.equal(app.paletteIndex("Beispielaufnahme 2"), app.paletteIndex("Beispielaufnahme 2"));
  const tones = new Set(Array.from({ length: 40 }, (_, index) => app.paletteIndex("Beispielaufnahme " + index)));
  assert.ok(tones.size >= 4, "titles spread over the palette");
  for (const tone of tones) assert.ok(tone >= 0 && tone < 6);
});

test("search filters title, channel and description, accent-insensitively", async () => {
  const ui = await page({
    videos: [
      sample(1, { title: "Beispiel Übersicht", description: "" }),
      sample(2, { channel: "Anderer Sender", description: "" }),
      sample(3, { description: "Mit Musik" }),
    ],
  });
  const search = ui.document.getElementById("search");
  const query = (value) => {
    search.value = value;
    search.dispatch("input");
    return ui.cards().map((node) => node.getAttribute("data-filename"));
  };
  assert.deepEqual(query("ubersicht"), ["Beispielaufnahme 1.mp4"]);
  assert.deepEqual(query("anderer"), ["Beispielaufnahme 2.mp4"]);
  assert.deepEqual(query("MUSIK"), ["Beispielaufnahme 3.mp4"]);
  assert.deepEqual(query("nichts dergleichen"), []);
  assert.match(byClass(ui.root, "empty")[0].textContent, /Nichts gefunden.*„nichts dergleichen“/);
  buttonByText(ui.root, "Suche löschen")[0].click();
  assert.equal(ui.cards().length, 3);
});

test("Löschen asks first, trashes, and Rückgängig calls restore", async () => {
  const video = sample(1);
  const trashed = { ...video, trash: true };
  const calls = [];
  const json = (status, body) => async (options) => {
    calls.push(options);
    return { ok: status < 300, status, json: async () => body };
  };
  const ui = await page({
    videos: [video],
    routes: {
      "DELETE /fernsehen/api/videos/Beispielaufnahme%201.mp4": json(200, trashed),
      "POST /fernsehen/api/restore/Beispielaufnahme%201.mp4": json(200, video),
    },
  });
  const confirm = ui.dialog("sheet-small");
  buttonByText(ui.cards()[0], "Löschen")[0].click();
  await settle();
  assert.equal(confirm.open, true);
  assert.match(confirm.textContent, /„Beispielaufnahme 1“ kommt in den Papierkorb/);
  buttonByText(confirm, "Abbrechen")[0].click();
  await settle();
  assert.equal(calls.length, 0, "cancel sends nothing");
  assert.equal(ui.cards().length, 1);
  buttonByText(ui.cards()[0], "Löschen")[0].click();
  await settle();
  buttonByText(confirm, "In den Papierkorb")[0].click();
  await settle();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "DELETE");
  assert.equal(calls[0].headers["X-Media-Request"], "1");
  assert.equal(ui.cards().length, 0);
  assert.equal(ui.lastToast(), "In den Papierkorb gelegt");
  const undo = buttonByText(ui.root, "Rückgängig")[0];
  undo.click();
  await settle();
  assert.equal(calls.length, 2);
  assert.equal(calls[1].method, "POST");
  assert.equal(calls[1].headers["X-Media-Request"], "1");
  assert.equal(ui.cards().length, 1);
  assert.equal(ui.lastToast(), "Die Aufnahme ist wieder da.");
});

test("Papierkorb lists trashed recordings with Wiederherstellen and the Betreuung note", async () => {
  const ui = await page({ search: "?trash=1", videos: [sample(1)], trash: [sample(2, { trash: true })] });
  assert.equal(ui.cards().length, 1);
  const card = ui.cards()[0];
  assert.ok(hasClass(card, "is-trashed"));
  assert.equal(findAll(card, (node) => node.localName === "a").length, 0, "trash cannot play");
  assert.equal(buttonByText(card, "Wiederherstellen").length, 1);
  assert.match(byClass(ui.root, "trash-note")[0].textContent, /bis die Betreuung den Papierkorb leert/);
  buttonByText(ui.root, "Alle1")[0].click();
  assert.equal(ui.location.search, "");
  assert.equal(ui.cards()[0].getAttribute("data-filename"), "Beispielaufnahme 1.mp4");
});

// ------------------------------------------------------------ thumbnails

test("thumbnail capture crops to cover 960×540", () => {
  const app = freshApp();
  assert.deepEqual(app.coverCrop(1920, 1080), { x: 0, y: 0, width: 1920, height: 1080 });
  assert.deepEqual(app.coverCrop(720, 576), { x: 0, y: 85.5, width: 720, height: 405 });
  assert.deepEqual(app.coverCrop(1080, 1920), { x: 0, y: 656.25, width: 1080, height: 607.5 });
});

test("thumbnail capture only feeds a checked blob: URL to the media element", () => {
  const app = freshApp();
  const original = Object.getOwnPropertyDescriptor(globalThis, "URL");
  const revoked = [];
  let next;
  class FakeURL extends URL {
    static createObjectURL() {
      return next;
    }
    static revokeObjectURL(url) {
      revoked.push(url);
    }
  }
  Object.defineProperty(globalThis, "URL", { value: FakeURL, configurable: true, writable: true });
  try {
    for (const url of [
      "blob:http://hsb9.test/0f6a7c1e-2b3d-4e5f-8a9b-0c1d2e3f4a5b",
      "blob:null/0f6a7c1e-2b3d-4e5f-8a9b-0c1d2e3f4a5b",
    ]) {
      next = url;
      assert.equal(app.localObjectUrl({ name: "local.mp4" }), url);
    }
    assert.deepEqual(revoked, []);
    for (const url of [
      "javascript:alert(1)",
      "data:text/html,<p>x</p>",
      "http://hsb9.test/video.mp4",
      'blob:http://hsb9.test/"><img>',
      "blob:http://hsb9.test/a b",
    ]) {
      next = url;
      assert.throws(() => app.localObjectUrl({ name: "local.mp4" }), /object URL/, url);
    }
    assert.equal(revoked.length, 5, "a refused URL is released again");
  } finally {
    Object.defineProperty(globalThis, "URL", original);
  }
});

test("a captured thumbnail is PUT with the CSRF header; failures stay silent", async () => {
  const ui = await page({ videos: [sample(1)] });
  const blob = { size: 1234, type: "image/jpeg" };
  const before = ui.requests.length;
  const stored = await ui.app.storeThumbnail({ name: "local.mp4" }, sample(1), async () => {
    throw new Error("synthetic decode failure");
  });
  assert.equal(stored, false);
  assert.equal(ui.requests.length, before, "no request without an image");
  assert.equal(ui.toasts().length, 0, "no error toast");
  const ok = await page({
    videos: [sample(1)],
    routes: {
      "PUT /fernsehen/api/videos/Beispielaufnahme%201.mp4/thumb": async () => ({
        ok: true,
        status: 200,
        json: async () => sample(1, { thumb_url: "/fernsehen/thumb/Beispielaufnahme%201.mp4.jpg?v=9" }),
      }),
    },
  });
  assert.equal(await ok.app.storeThumbnail({ name: "local.mp4" }, sample(1), async () => blob), true);
  const put = ok.requests.find((item) => item.method === "PUT");
  assert.equal(put.headers["X-Media-Request"], "1");
  assert.equal(put.headers["Content-Type"], "image/jpeg");
  assert.equal(put.body, blob);
  const image = findAll(ok.cards()[0], (node) => node.localName === "img")[0];
  assert.equal(image.src, "/fernsehen/thumb/Beispielaufnahme%201.mp4.jpg?v=9");
});

// ------------------------------------------------------------ uploads (OPS-729)

test("space preflight refuses before sending and shows the German error", async () => {
  const ui = await page({ available: 5 });
  assert.match(ui.document.getElementById("space").textContent, /^Noch frei: .* GB$/);
  await ui.upload(6);
  assert.equal(ui.uploads.length, 0);
  assert.equal(ui.locks.length, 0);
  assert.equal(ui.lastToast(), spaceError);
  assert.equal(ui.document.getElementById("add-button").disabled, false);
});

test("the file picker change event starts an upload with the CSRF header", async () => {
  const ui = await page();
  const input = ui.document.getElementById("video-file");
  input.files = [{ name: "Beispiel.mp4", size: 10 }];
  input.dispatch("change");
  for (let index = 0; index < 5; index++) await settle();
  assert.equal(ui.uploads.length, 1);
  assert.equal(ui.uploads[0].method, "PUT");
  assert.equal(ui.uploads[0].url, "/fernsehen/api/videos/Beispiel.mp4");
  assert.equal(ui.uploads[0].headers["X-Media-Request"], "1");
  assert.equal(ui.document.getElementById("add-button").disabled, true);
  ui.uploads[0].upload.onprogress({ lengthComputable: true, loaded: 5, total: 10 });
  assert.equal(byClass(ui.root, "upload-percent")[0].textContent.replace(/\s/g, " "), "50 %");
  buttonByText(ui.root, "Abbrechen")[0].click();
  assert.equal(ui.uploads[0].aborted, true);
  assert.equal(ui.lastToast(), "Die Übertragung wurde abgebrochen.");
  assert.equal(ui.document.getElementById("add-button").disabled, false);
});

test("wrong file types are refused before anything is sent", async () => {
  const ui = await page();
  await ui.upload(10, "Beispiel.mp3");
  assert.equal(ui.uploads.length, 0);
  assert.equal(ui.lastToast(), "Bitte eine Datei mit der Endung .mp4, .m4v oder .mov auswählen.");
});

test("non-JSON 5xx uploads request caregiver help and release the screen lock", async () => {
  for (const status of [500, 502, 503, 504, 507, 599]) {
    const ui = await page();
    await ui.upload();
    assert.equal(ui.uploads[0].sent.size, 10);
    assert.equal(ui.locks[0].released, false);
    ui.uploads[0].status = status;
    ui.uploads[0].responseText = "<html>synthetic offline page</html>";
    ui.uploads[0].onload();
    assert.equal(ui.lastToast(), serverError);
    assert.equal(ui.locks[0].releases, 1);
    assert.equal(ui.document.listeners.has("visibilitychange"), false);
  }
});

test("non-JSON uploads outside 5xx retain the German unreadable-response error", async () => {
  for (const status of [201, 400]) {
    const ui = await page();
    await ui.upload();
    ui.uploads[0].status = status;
    ui.uploads[0].responseText = "synthetic non-JSON";
    ui.uploads[0].onload();
    assert.equal(ui.lastToast(), unreadable);
  }
});

test("JSON 503 uploads preserve the app's German message", async () => {
  const error =
    "Speichern oder Lesen ist gerade nicht möglich. Bitte die Betreuung verständigen.";
  const ui = await page();
  await ui.upload();
  ui.uploads[0].status = 503;
  ui.uploads[0].responseText = JSON.stringify({ error });
  ui.uploads[0].onload();
  assert.equal(ui.lastToast(), error);
  assert.equal(ui.locks[0].releases, 1);
});

test("server 507 errors show the storage message (localized by code) and release the lock", async () => {
  const ui = await page();
  await ui.upload();
  ui.uploads[0].status = 507;
  ui.uploads[0].responseText = JSON.stringify({ error: spaceError, code: "insufficient_space" });
  ui.uploads[0].onload();
  assert.equal(ui.lastToast(), spaceError);
  assert.equal(ui.locks[0].releases, 1);
  const english = await page({ languages: ["en"] });
  await english.upload();
  english.uploads[0].status = 507;
  english.uploads[0].responseText = JSON.stringify({ error: spaceError, code: "insufficient_space" });
  english.uploads[0].onload();
  assert.equal(english.lastToast(), "There is not enough space on the device for this video. Please contact your helper.");
});

test("successful uploads open the edit dialog and release the screen lock", async () => {
  const ui = await page();
  await ui.upload();
  ui.uploads[0].status = 201;
  ui.uploads[0].responseText = JSON.stringify(sample(1, { filename: "Beispiel.mp4", title: "Beispiel", description: "" }));
  ui.uploads[0].onload();
  const edit = ui.dialog("sheet");
  assert.equal(edit.open, true);
  assert.equal(ui.document.getElementById("edit-title").value, "Beispiel");
  assert.match(ui.lastToast(), /Video wurde hinzugefügt/);
  assert.equal(ui.locks[0].releases, 1);
  assert.equal(ui.cards().length, 1);
  await settle();
  assert.equal(ui.toasts().length, 1, "a failed thumbnail capture stays silent");
});

test("wake locks are reacquired after returning to the page and released on reset", async () => {
  const ui = await page();
  await ui.upload();
  ui.locks[0].released = true;
  ui.document.listeners.get("visibilitychange")();
  await settle();
  assert.equal(ui.locks.length, 2);
  ui.uploads[0].onerror();
  assert.equal(ui.locks[1].releases, 1);
  assert.match(ui.lastToast(), /Übertragung wurde unterbrochen/);
  assert.equal(ui.document.getElementById("add-button").disabled, false);
});

test("uploads still work when screen wake locks are denied or unsupported", async () => {
  for (const wake of ["denied", "unsupported"]) {
    const ui = await page({ wake });
    await ui.upload();
    assert.equal(ui.uploads[0].sent.size, 10);
    ui.uploads[0].onabort();
    assert.match(ui.lastToast(), /Übertragung wurde unterbrochen/);
    assert.equal(ui.locks.length, 0);
  }
});

test("edit saves title and description with PATCH", async () => {
  const calls = [];
  const ui = await page({
    videos: [sample(1)],
    routes: {
      "PATCH /fernsehen/api/videos/Beispielaufnahme%201.mp4": async (options) => {
        calls.push(JSON.parse(options.body));
        return { ok: true, status: 200, json: async () => sample(1, { title: "Neuer Titel" }) };
      },
    },
  });
  buttonByText(ui.cards()[0], "Bearbeiten")[0].click();
  const edit = ui.dialog("sheet");
  assert.equal(edit.open, true);
  ui.document.getElementById("edit-title").value = "Neuer Titel";
  findAll(edit, (node) => node.localName === "form")[0].dispatch("submit");
  await settle();
  assert.deepEqual(calls, [{ title: "Neuer Titel", description: "Eine kurze Beispielbeschreibung." }]);
  assert.equal(edit.open, false);
  assert.equal(byClass(ui.cards()[0], "card-title-text")[0].textContent, "Neuer Titel");
  assert.equal(ui.lastToast(), "Die Angaben wurden gespeichert.");
});

// A save of recording 1 that answers only after its dialog was closed and
// recording 2's dialog opened must leave recording 2's dialog alone.
async function staleSave() {
  const first = sample(1);
  const second = sample(2);
  const calls = [];
  let answerFirst;
  const ui = await page({
    videos: [first, second],
    routes: {
      "PATCH /fernsehen/api/videos/Beispielaufnahme%201.mp4": (options) => {
        calls.push(JSON.parse(options.body));
        return new Promise((resolve, reject) => {
          answerFirst = { resolve, reject };
        });
      },
      "PATCH /fernsehen/api/videos/Beispielaufnahme%202.mp4": async (options) => {
        calls.push(JSON.parse(options.body));
        return { ok: true, status: 200, json: async () => ({ ...second, title: "Beispiel zwei neu" }) };
      },
    },
  });
  const edit = ui.dialog("sheet");
  const form = findAll(edit, (node) => node.localName === "form")[0];
  const save = findAll(edit, (node) => node.localName === "button" && node.getAttribute("type") === "submit")[0];
  const title = ui.document.getElementById("edit-title");
  const error = byClass(edit, "form-error")[0];
  const cardFor = (video) => ui.cards().find((node) => node.getAttribute("data-filename") === video.filename);
  buttonByText(cardFor(first), "Bearbeiten")[0].click();
  title.value = "Beispiel eins neu";
  form.dispatch("submit");
  await settle();
  assert.equal(save.disabled, true);
  assert.equal(save.textContent, "Wird gespeichert …");
  buttonByText(edit, "Abbrechen")[0].click();
  await settle();
  assert.equal(edit.open, false);
  buttonByText(cardFor(second), "Bearbeiten")[0].click();
  assert.equal(edit.open, true);
  assert.equal(save.disabled, false, "a new edit starts with Speichern ready while the old save is pending");
  assert.equal(save.textContent, "Speichern");
  title.value = "Beispiel zwei Entwurf";
  return { ui, first, second, calls, answerFirst, edit, form, save, title, error, cardFor };
}
function assertSecondUntouched({ edit, save, title, error }) {
  assert.equal(edit.open, true, "the newer edit dialog stays open");
  assert.equal(title.value, "Beispiel zwei Entwurf", "its draft is kept");
  assert.equal(save.disabled, false, "its Speichern stays ready");
  assert.equal(save.textContent, "Speichern");
  assert.equal(error.hidden, true, "no error from the older save appears in it");
}
async function saveSecond({ ui, form, edit, calls, second, cardFor }) {
  form.dispatch("submit");
  await settle();
  assert.deepEqual(calls[calls.length - 1], {
    title: "Beispiel zwei Entwurf",
    description: second.description,
  }, "Speichern still saves the newer recording");
  assert.equal(edit.open, false);
  assert.equal(byClass(cardFor(second), "card-title-text")[0].textContent, "Beispiel zwei neu");
  assert.equal(ui.lastToast(), "Die Angaben wurden gespeichert.");
}

test("a delayed save never closes or resets a newer edit dialog", async () => {
  const run = await staleSave();
  run.answerFirst.resolve({
    ok: true,
    status: 200,
    json: async () => ({ ...run.first, title: "Beispiel eins neu" }),
  });
  await settle();
  assertSecondUntouched(run);
  assert.equal(
    byClass(run.cardFor(run.first), "card-title-text")[0].textContent,
    "Beispiel eins neu",
    "the older save still reaches the library",
  );
  assert.equal(run.ui.lastToast(), "Die Angaben wurden gespeichert.");
  await settle();
  assertSecondUntouched(run);
  await saveSecond(run);
});

test("a delayed failing save reports as a toast, never in a newer edit dialog", async () => {
  const run = await staleSave();
  run.answerFirst.reject(new Error("synthetic network failure"));
  await settle();
  assertSecondUntouched(run);
  assert.equal(byClass(run.cardFor(run.first), "card-title-text")[0].textContent, "Beispielaufnahme 1");
  assert.equal(run.ui.lastToast(), "Die Verbindung ist unterbrochen. Bitte erneut versuchen.");
  await settle();
  assertSecondUntouched(run);
  await saveSecond(run);
});

test("a finishing upload never replaces an edit in progress", async () => {
  const ui = await page({ videos: [sample(2)] });
  await ui.upload();
  const edit = ui.dialog("sheet");
  const title = ui.document.getElementById("edit-title");
  buttonByText(ui.cards()[0], "Bearbeiten")[0].click();
  title.value = "Beispiel zwei Entwurf";
  ui.uploads[0].status = 201;
  ui.uploads[0].responseText = JSON.stringify(sample(1, { filename: "Beispiel.mp4", title: "Beispiel", description: "" }));
  ui.uploads[0].onload();
  await settle();
  assert.equal(edit.open, true);
  assert.equal(title.value, "Beispiel zwei Entwurf", "the draft survives the finished upload");
  assert.equal(ui.document.getElementById("edit-heading").textContent, "Aufnahme bearbeiten");
  assert.equal(ui.cards().length, 2, "the new recording is in the library");
  assert.match(ui.lastToast(), /Video wurde hinzugefügt/);
});

// ------------------------------------------------ per-recording mutations

// One recording on a fake server. Like the real one, it processes each request
// when it arrives (arrival order) and answers with the record as it stood
// then; the answer is delivered only when the test says so, in any order the
// client allows. `log` is what reached the server, in order.
function recordingServer(initial) {
  const name = encodeURIComponent(initial.filename);
  const server = { record: { ...initial }, trashed: false, pending: [], log: [], signals: [] };
  const reply = (status, body) => ({ ok: status < 300, status, json: async () => body });
  const missing = () => reply(404, { error: "Diese Aufnahme wurde nicht gefunden.", code: "not_found" });
  const entry = () => ({ ...server.record, trash: server.trashed });
  const route = (label, process) => (options) => {
    server.log.push(label(options));
    server.signals.push(options.signal);
    const response = process(options);
    return new Promise((resolve) => server.pending.push(() => resolve(response)));
  };
  server.routes = {
    "GET /fernsehen/api/videos": () => {
      server.log.push("GET videos");
      return reply(200, { videos: server.trashed ? [] : [entry()] });
    },
    "GET /fernsehen/api/videos?trash=1": () => {
      server.log.push("GET trash");
      return reply(200, { videos: server.trashed ? [entry()] : [] });
    },
    [`PATCH /fernsehen/api/videos/${name}`]: route(
      (options) => "PATCH " + JSON.parse(options.body).title,
      (options) => {
        const fields = JSON.parse(options.body);
        if (server.trashed) return missing();
        if (!fields.title.trim())
          return reply(400, { error: "Bitte einen Titel eingeben.", code: "title_required" });
        Object.assign(server.record, fields);
        return reply(200, entry());
      },
    ),
    [`DELETE /fernsehen/api/videos/${name}`]: route(
      () => "DELETE",
      () => {
        if (server.trashed) return missing();
        server.trashed = true;
        return reply(200, entry());
      },
    ),
    [`POST /fernsehen/api/restore/${name}`]: route(
      () => "POST restore",
      () => {
        if (!server.trashed) return missing();
        server.trashed = false;
        return reply(200, entry());
      },
    ),
    [`PUT /fernsehen/api/videos/${name}/thumb`]: route(
      () => "PUT thumb",
      () => {
        if (server.trashed) return missing();
        server.record.thumb_url = `/fernsehen/thumb/${name}.jpg?v=1`;
        return reply(200, entry());
      },
    ),
  };
  const answer = async (index) => {
    server.pending.splice(index, 1)[0]();
    await settle();
  };
  // Deliver every answer, newest (or oldest) pending first, until none is left.
  server.drain = async (order) => {
    while (server.pending.length)
      await answer(order === "newest" ? server.pending.length - 1 : 0);
  };
  server.answerOldest = () => answer(0);
  server.answerNewest = () => answer(server.pending.length - 1);
  return server;
}
async function mutationPage(video = sample(1)) {
  const server = recordingServer(video);
  const ui = await page({ videos: [video], routes: server.routes });
  server.log.length = 0; // The initial listing is separate from mutation order.
  const edit = ui.dialog("sheet");
  const form = findAll(edit, (node) => node.localName === "form")[0];
  const title = ui.document.getElementById("edit-title");
  const save = findAll(edit, (node) => node.localName === "button" && node.getAttribute("type") === "submit")[0];
  const error = byClass(edit, "form-error")[0];
  const card = () => ui.cards().find((node) => node.getAttribute("data-filename") === video.filename);
  const cardTitle = () => byClass(card(), "card-title-text")[0].textContent;
  const cardImage = () => findAll(card(), (node) => node.localName === "img")[0];
  const saveAs = async (value) => {
    buttonByText(card(), "Bearbeiten")[0].click();
    title.value = value;
    form.dispatch("submit");
    await settle();
  };
  const saved = () => ui.toasts().filter((text) => text === "Die Angaben wurden gespeichert.").length;
  return { ui, video, server, edit, form, title, save, error, card, cardTitle, cardImage, saveAs, saved };
}
const thumbBlob = { size: 1234, type: "image/jpeg" };
const thumbUrl = "/fernsehen/thumb/Beispielaufnahme%201.mp4.jpg?v=1";

test("a stalled thumbnail PUT times out, reloads server truth, then sends the queued save", async () => {
  const run = await mutationPage();
  const { ui, server, video, save } = run;
  const stored = ui.app.storeThumbnail({ name: "local.mp4" }, video, async () => thumbBlob);
  await settle();
  await run.saveAs("Beispiel danach");
  assert.equal(save.disabled, true);
  assert.deepEqual(server.log, ["PUT thumb"]);

  // Virtual time makes the 20-second production deadline immediate in tests.
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.deepEqual(server.log, ["PUT thumb", "GET videos", "GET trash", "PATCH Beispiel danach"],
    "the PATCH must wait for an authoritative listing after the stalled PUT");
  assert.equal(server.signals[0].aborted, true);
  assert.equal(await stored, false);
  assert.equal(run.cardImage().src, thumbUrl, "the listing recovers the committed thumbnail");
  await server.answerNewest();
  assert.equal(run.cardTitle(), "Beispiel danach");
  assert.equal(run.cardImage().src, thumbUrl);
  assert.equal(save.disabled, false);
  assert.equal(run.edit.open, false);
  assert.equal(run.saved(), 1);

  await server.answerOldest(); // A fetch mock deliberately ignores the abort.
  assert.equal(run.cardTitle(), "Beispiel danach", "the late PUT cannot regress the saved title");
  assert.equal(run.cardImage().src, thumbUrl);
});

for (const stalled of ["fetch", "body"]) {
  test(`a stalled PATCH ${stalled} times out, reloads, allows another save and ignores its late answer`, async () => {
    const run = await mutationPage();
    const { ui, server, edit, form, title, save, error, video } = run;
    const routeKey = `PATCH /fernsehen/api/videos/${encodeURIComponent(video.filename)}`;
    const patch = server.routes[routeKey];
    let releaseBody;
    if (stalled === "body") {
      server.routes[routeKey] = async (options) => {
        const response = await patch(options);
        return {
          ...response,
          json: () => new Promise((resolve) => {
            releaseBody = () => resolve(response.json());
          }),
        };
      };
    }
    await run.saveAs("Beispiel unklar");
    if (stalled === "body") {
      await ui.elapse(ui.app.REQUEST_TIMEOUT_MS - 1);
      assert.equal(save.disabled, true);
      await server.answerOldest(); // Headers arrived; JSON stalls.
    }
    server.routes[routeKey] = patch;
    const lang = stalled === "body" ? "en" : "de";
    ui.app.setLanguage(lang, false);
    await ui.elapse(stalled === "body" ? 1 : ui.app.REQUEST_TIMEOUT_MS);

    assert.equal(server.signals[0].aborted, true);
    assert.deepEqual(server.log, ["PATCH Beispiel unklar", "GET videos", "GET trash"]);
    assert.equal(run.cardTitle(), "Beispiel unklar", "the listing recovers the uncertain save's outcome");
    assert.equal(edit.open, true);
    assert.equal(save.disabled, false);
    assert.equal(title.value, "Beispiel unklar", "the draft stays available");
    const message = ui.app.STRINGS[lang]["error.request_timeout"];
    assert.equal(error.textContent, message);
    assert.equal(error.hidden, false);
    assert.deepEqual(ui.toasts(), [message], "the timeout has a localized toast even with the dialog open");

    title.value = "Beispiel danach";
    form.dispatch("submit");
    await settle();
    assert.equal(save.disabled, true);
    await server.answerNewest();
    assert.equal(run.cardTitle(), "Beispiel danach");
    assert.equal(save.disabled, false);
    assert.equal(edit.open, false);
    assert.equal(ui.lastToast(), ui.app.STRINGS[lang]["toast.saved"]);
    const toasts = ui.toasts();

    if (stalled === "fetch") await server.answerOldest();
    else {
      releaseBody();
      await settle();
    }
    assert.equal(run.cardTitle(), "Beispiel danach", "late results must not apply");
    assert.equal(ui.app.state.videos[0].title, "Beispiel danach");
    assert.equal(save.disabled, false);
    assert.equal(edit.open, false);
    assert.deepEqual(ui.toasts(), toasts, "the late response has no UI effects");
    await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
    assert.deepEqual(server.log, ["PATCH Beispiel unklar", "GET videos", "GET trash", "PATCH Beispiel danach"],
      "successful requests clear their deadline timers");
  });
}

test("a timeout uses the listing instead of replaying a superseded save's older answer", async () => {
  const run = await mutationPage();
  const { ui, server, edit, save } = run;
  await run.saveAs("Beispiel A");
  buttonByText(edit, "Abbrechen")[0].click();
  await settle();
  await run.saveAs(" ");
  await server.answerOldest(); // A succeeds; the newer invalid save is pending.
  assert.equal(run.cardTitle(), run.video.title, "A's superseded answer stays aside");
  server.record.title = "Beispiel vom Server";
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.equal(run.cardTitle(), "Beispiel vom Server", "only the authoritative listing is applied");
  assert.equal(save.disabled, false);
  assert.equal(ui.lastToast(), ui.app.STRINGS.de["error.request_timeout"]);
  await server.answerOldest();
  assert.equal(run.cardTitle(), "Beispiel vom Server", "the late error cannot replay A");
});

test("a stalled recovery listing settles the save but fences later mutations until server truth is available", async () => {
  const run = await mutationPage();
  const { ui, server, form, title, save } = run;
  await run.saveAs("Beispiel unklar");
  const listing = server.routes["GET /fernsehen/api/videos"];
  let releaseListing;
  server.routes["GET /fernsehen/api/videos"] = (options) => {
    const response = listing(options);
    return new Promise((resolve) => { releaseListing = () => resolve(response); });
  };
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.equal(save.disabled, true, "reconciliation precedes settling the timed-out mutation");
  assert.deepEqual(server.log, ["PATCH Beispiel unklar", "GET videos", "GET trash"]);
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.equal(save.disabled, false, "even an unresponsive listing cannot wedge the chain");
  assert.equal(run.cardTitle(), run.video.title, "an unknown result is not guessed");

  // An action while reconciliation is still unavailable must settle without
  // sending a mutation. The uncertainty survives the now-idle queue.
  server.routes["GET /fernsehen/api/videos"] = () => { throw new Error("synthetic offline"); };
  title.value = "Beispiel gesperrt";
  form.dispatch("submit");
  await settle();
  assert.equal(save.disabled, false);
  assert.deepEqual(server.log.filter((entry) => entry.startsWith("PATCH")), ["PATCH Beispiel unklar"]);

  server.routes["GET /fernsehen/api/videos"] = listing;
  title.value = "Beispiel danach";
  form.dispatch("submit");
  await settle();
  assert.deepEqual(server.log.slice(-3), ["GET videos", "GET trash", "PATCH Beispiel danach"]);
  assert.equal(run.cardTitle(), "Beispiel unklar", "authoritative state is applied before the next PATCH");
  await server.answerNewest();
  assert.equal(run.cardTitle(), "Beispiel danach");
  assert.equal(save.disabled, false);
  releaseListing();
  await server.answerOldest();
  assert.equal(run.cardTitle(), "Beispiel danach", "late recovery and mutation responses stay ignored");
});

test("stalled trash and restore requests reconcile both lists and ignore late responses", async () => {
  const run = await mutationPage();
  const { ui, server } = run;
  buttonByText(run.card(), "Löschen")[0].click();
  await settle();
  buttonByText(ui.dialog("sheet-small"), "In den Papierkorb")[0].click();
  await settle();
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.equal(server.signals[0].aborted, true);
  assert.equal(ui.cards().length, 0);
  assert.equal(ui.app.state.videos.length, 0);
  assert.equal(ui.app.state.trash.length, 1);
  assert.equal(ui.lastToast(), ui.app.STRINGS.de["error.request_timeout"]);

  const segment = (label) =>
    findAll(ui.root, (node) => hasClass(node, "segment") && node.textContent.startsWith(label))[0];
  segment("Papierkorb").click();
  buttonByText(run.card(), "Wiederherstellen")[0].click();
  await settle();
  await ui.elapse(ui.app.REQUEST_TIMEOUT_MS);
  assert.equal(server.signals[1].aborted, true);
  assert.equal(ui.app.state.videos.length, 1);
  assert.equal(ui.app.state.trash.length, 0);
  segment("Alle").click();
  assert.equal(run.cardTitle(), run.video.title);
  assert.deepEqual(server.log, ["DELETE", "GET videos", "GET trash", "POST restore", "GET videos", "GET trash"]);
  await server.drain("newest");
  assert.equal(ui.app.state.videos.length, 1);
  assert.equal(ui.app.state.trash.length, 0, "the late DELETE cannot move the restored recording back");
});

// Gate 3: save A, close, reopen the same recording, save B. However the answers
// come back, B's fields win and A's never reach the library or B's dialog.
// "newest" answers the newest pending request first: B before A on a client
// that sends both at once; a serialising client only ever has one pending.
for (const order of ["newest", "oldest"]) {
  test(`same recording: save A, reopen, save B (${order} answer first) ends with B's fields`, async () => {
    const run = await mutationPage();
    const { ui, server, edit, save } = run;
    await run.saveAs("Beispiel A");
    buttonByText(edit, "Abbrechen")[0].click();
    await settle();
    await run.saveAs("Beispiel B");
    const sentBeforeFirstSettled = [...server.log];
    const dialogWhilePending = [];
    while (server.pending.length) {
      await (order === "newest" ? server.answerNewest() : server.answerOldest());
      assert.notEqual(run.cardTitle(), "Beispiel A", "a superseded answer never reaches the library");
      if (server.pending.length) dialogWhilePending.push({ open: edit.open, saving: save.disabled });
    }
    assert.equal(run.cardTitle(), "Beispiel B", "B's fields win");
    assert.equal(server.record.title, "Beispiel B");
    assert.equal(edit.open, false);
    assert.deepEqual(dialogWhilePending, [{ open: true, saving: true }], "A's answer leaves B's saving dialog alone");
    assert.equal(run.saved(), 1, "one Gespeichert, from B");
    assert.equal(ui.toasts().length, 1, "no error");
    assert.deepEqual(sentBeforeFirstSettled, ["PATCH Beispiel A"], "the second PATCH waits until the first settled");
    assert.deepEqual(server.log, ["PATCH Beispiel A", "PATCH Beispiel B"], "the server sees user order");
  });
}

test("same recording: if the newer save fails, the older success is what the library shows", async () => {
  const run = await mutationPage();
  const { ui, server, edit, save, error } = run;
  await run.saveAs("Beispiel A");
  buttonByText(edit, "Abbrechen")[0].click();
  await settle();
  await run.saveAs(" ");
  const sentBeforeFirstSettled = [...server.log];
  await server.drain("newest");
  assert.equal(run.cardTitle(), "Beispiel A", "the server holds A, so the library shows A");
  assert.equal(edit.open, true, "the failed save keeps its dialog");
  assert.equal(error.hidden, false);
  assert.equal(error.textContent, "Bitte einen Titel eingeben.");
  assert.equal(save.disabled, false);
  assert.deepEqual(sentBeforeFirstSettled, ["PATCH Beispiel A"]);
  assert.deepEqual(server.log, ["PATCH Beispiel A", "PATCH  "]);
  assert.equal(run.saved(), 0, "the superseded success stays quiet; the error speaks");
  assert.equal(ui.toasts().length, 0);
});

test("Löschen then Rückgängig in quick succession: requests in order, the recording is back", async () => {
  const run = await mutationPage();
  const { ui, server, video } = run;
  const confirm = ui.dialog("sheet-small");
  const segment = (label) =>
    findAll(ui.root, (node) => hasClass(node, "segment") && node.textContent.startsWith(label))[0];
  buttonByText(run.card(), "Löschen")[0].click();
  await settle();
  buttonByText(confirm, "In den Papierkorb")[0].click();
  await settle();
  assert.deepEqual(server.log, ["DELETE"]);
  await server.answerOldest();
  assert.equal(ui.cards().length, 0);
  assert.equal(ui.lastToast(), "In den Papierkorb gelegt");
  buttonByText(ui.root, "Rückgängig")[0].click();
  await settle();
  // The restore is still in flight; the Papierkorb still lists the recording
  // and its Wiederherstellen is pressed right away as well.
  segment("Papierkorb").click();
  await settle();
  buttonByText(run.card(), "Wiederherstellen")[0].click();
  await settle();
  const sentWhileRestoring = [...server.log];
  await server.drain("newest");
  assert.equal(server.trashed, false);
  assert.equal(ui.cards().length, 0, "nothing left in the Papierkorb");
  segment("Alle").click();
  await settle();
  assert.equal(ui.cards().length, 1, "the recording is back in the library");
  assert.equal(run.cardTitle(), video.title);
  assert.deepEqual(
    ui.toasts(),
    ["Die Aufnahme ist wieder da."],
    "one confirmation; the second restore found it back already, so no error",
  );
  assert.deepEqual(sentWhileRestoring, ["DELETE", "POST restore"], "the second restore waits for the first");
  assert.deepEqual(server.log, ["DELETE", "POST restore", "POST restore"]);
});

test("Löschen right after Speichern waits for the save; Rückgängig brings back the saved title", async () => {
  const run = await mutationPage();
  const { ui, server, edit } = run;
  const confirm = ui.dialog("sheet-small");
  await run.saveAs("Beispiel A");
  buttonByText(edit, "Abbrechen")[0].click();
  await settle();
  buttonByText(run.card(), "Löschen")[0].click();
  await settle();
  buttonByText(confirm, "In den Papierkorb")[0].click();
  await settle();
  const sentWhileSaving = [...server.log];
  await server.drain("newest");
  assert.equal(ui.cards().length, 0, "the recording is in the Papierkorb");
  assert.equal(ui.app.state.trash[0].title, "Beispiel A", "with the saved title");
  assert.deepEqual(ui.toasts(), ["In den Papierkorb gelegt"], "the superseded save stays quiet");
  buttonByText(ui.root, "Rückgängig")[0].click();
  await settle();
  await server.drain("newest");
  assert.equal(run.cardTitle(), "Beispiel A");
  assert.deepEqual(sentWhileSaving, ["PATCH Beispiel A"], "the DELETE waits for the PATCH");
  assert.deepEqual(server.log, ["PATCH Beispiel A", "DELETE", "POST restore"]);
});

for (const order of ["newest", "oldest"]) {
  test(`Speichern while a thumbnail PUT is pending keeps the title and the thumbnail (${order} first)`, async () => {
    const run = await mutationPage();
    const { ui, server, video } = run;
    const stored = ui.app.storeThumbnail({ name: "local.mp4" }, video, async () => thumbBlob);
    await settle();
    assert.deepEqual(server.log, ["PUT thumb"]);
    await run.saveAs("Beispiel neu");
    const sentWhileStoring = [...server.log];
    await server.drain(order);
    assert.equal(await stored, true);
    assert.equal(run.cardTitle(), "Beispiel neu", "the edit's title survives");
    assert.equal(run.cardImage().src, thumbUrl, "the PUT's thumb_url survives");
    assert.equal(run.saved(), 1);
    assert.deepEqual(sentWhileStoring, ["PUT thumb"], "the PATCH waits for the thumbnail PUT");
    assert.deepEqual(server.log, ["PUT thumb", "PATCH Beispiel neu"]);
  });
}

test("a thumbnail captured during a pending save waits for it and neither hides the save nor its title", async () => {
  const run = await mutationPage();
  const { ui, server, video } = run;
  await run.saveAs("Beispiel neu");
  const stored = ui.app.storeThumbnail({ name: "local.mp4" }, video, async () => thumbBlob);
  await settle();
  const sentWhileSaving = [...server.log];
  await server.drain("newest");
  assert.equal(await stored, true);
  assert.equal(run.cardTitle(), "Beispiel neu");
  assert.equal(run.cardImage().src, thumbUrl);
  assert.equal(run.saved(), 1, "a thumbnail does not supersede the save's Gespeichert");
  assert.deepEqual(sentWhileSaving, ["PATCH Beispiel neu"]);
  assert.deepEqual(server.log, ["PATCH Beispiel neu", "PUT thumb"]);
});

test("save A, thumbnail, failing save B: the library shows A's title and the thumbnail", async () => {
  const run = await mutationPage();
  const { ui, server, video, edit, error } = run;
  await run.saveAs("Beispiel A");
  const stored = ui.app.storeThumbnail({ name: "local.mp4" }, video, async () => thumbBlob);
  buttonByText(edit, "Abbrechen")[0].click();
  await settle();
  await run.saveAs(" ");
  const sentBeforeFirstSettled = [...server.log];
  await server.drain("oldest");
  assert.equal(await stored, true);
  assert.equal(run.cardTitle(), "Beispiel A");
  assert.equal(run.cardImage().src, thumbUrl, "the thumbnail is replayed after the older answer");
  assert.equal(error.textContent, "Bitte einen Titel eingeben.");
  assert.deepEqual(sentBeforeFirstSettled, ["PATCH Beispiel A"]);
  assert.deepEqual(server.log, ["PATCH Beispiel A", "PUT thumb", "PATCH  "]);
});

for (const thumbFirst of [false, true]) {
  test(`a thumbnail PUT never resurrects a recording moved to the Papierkorb (${thumbFirst ? "PUT" : "DELETE"} first)`, async () => {
    const run = await mutationPage();
    const { ui, server, video } = run;
    const confirm = ui.dialog("sheet-small");
    let stored;
    const storeThumb = async () => {
      stored = ui.app.storeThumbnail({ name: "local.mp4" }, video, async () => thumbBlob);
      await settle();
    };
    if (thumbFirst) await storeThumb();
    buttonByText(run.card(), "Löschen")[0].click();
    await settle();
    buttonByText(confirm, "In den Papierkorb")[0].click();
    await settle();
    if (!thumbFirst) await storeThumb();
    const sentFirst = [...server.log];
    await server.drain("newest");
    assert.equal(await stored, thumbFirst, "a PUT after the move fails silently");
    assert.equal(ui.cards().length, 0, "nothing is resurrected in the library");
    assert.equal(ui.app.state.videos.length, 0);
    assert.equal(ui.app.state.trash.length, 1);
    assert.equal(ui.app.state.trash[0].thumb_url, thumbFirst ? thumbUrl : undefined);
    assert.deepEqual(ui.toasts(), ["In den Papierkorb gelegt"], "no error toast");
    assert.deepEqual(sentFirst, [thumbFirst ? "PUT thumb" : "DELETE"]);
    assert.deepEqual(server.log, thumbFirst ? ["PUT thumb", "DELETE"] : ["DELETE", "PUT thumb"]);
  });
}

// ------------------------------------------------------------ listing (OPS-729)

test("non-JSON listing responses show the existing German error", async () => {
  const ui = await page({ invalidJSON: true });
  assert.equal(ui.document.getElementById("load-error").textContent, unreadable);
  assert.equal(buttonByText(ui.root, "Erneut versuchen").length, 1);
});

test("non-JSON 5xx listings request caregiver help", async () => {
  for (const responseStatus of [500, 502, 503, 504, 507, 599]) {
    const ui = await page({ invalidJSON: true, responseStatus });
    assert.equal(ui.document.getElementById("load-error").textContent, serverError);
  }
});

test("JSON 503 listings preserve the app's German message", async () => {
  const errorMessage =
    "Die Angaben können gerade nicht gelesen werden. Bitte die Betreuung verständigen.";
  const ui = await page({ responseStatus: 503, errorMessage });
  assert.equal(ui.document.getElementById("load-error").textContent, errorMessage);
});

test("an empty library offers a friendly start", async () => {
  const ui = await page();
  const empty = byClass(ui.root, "empty")[0];
  assert.match(empty.textContent, /Noch keine Aufnahmen/);
  assert.equal(buttonByText(empty, "Video hinzufügen").length, 1);
});
