// OPS-729: exercise upload failures without launching a native browser.
const assert = require("node:assert/strict");
const test = require("node:test");

const appPath = require.resolve("../hosts/hsb9/docker/media/app.js");
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
const spaceError =
  "Auf dem Gerät ist nicht genug Platz für dieses Video. Bitte die Betreuung verständigen.";
const unreadable =
  "Die Antwort konnte nicht gelesen werden. Bitte erneut versuchen.";
const serverError =
  "Die Aufnahmen sind gerade nicht erreichbar. Bitte in einem Moment erneut versuchen. Wenn es so bleibt, bitte die Betreuung verständigen.";

async function page({
  available = 100,
  wake = "supported",
  invalidJSON = false,
  responseStatus = 200,
  errorMessage,
} = {}) {
  const nodes = [];
  function node(tag, id) {
    const result = {
      tag,
      id,
      children: [],
      listeners: new Map(),
      textContent: "",
      disabled: false,
      append(...children) {
        this.children.push(...children);
      },
      replaceChildren(...children) {
        this.children = children;
      },
      setAttribute() {},
      addEventListener(type, callback) {
        this.listeners.set(type, callback);
      },
      removeEventListener(type) {
        this.listeners.delete(type);
      },
      scrollIntoView() {
        this.scrolled = true;
      },
      focus() {},
    };
    nodes.push(result);
    return result;
  }
  for (const id of ["content", "status", "space", "main", "add-link"])
    node("div", id);
  const document = {
    ...node("document"),
    visibilityState: "visible",
    createElement: (tag) => node(tag),
    getElementById: (id) => nodes.find((item) => item.id === id),
  };
  const locks = [];
  const navigator =
    wake === "unsupported"
      ? {}
      : {
          wakeLock: {
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
          },
        };
  const uploads = [];
  class XMLHttpRequest {
    constructor() {
      this.upload = {};
      uploads.push(this);
    }
    open() {}
    setRequestHeader() {}
    send(file) {
      this.sent = file;
    }
  }
  const globals = {
    document,
    navigator,
    XMLHttpRequest,
    window: node("window"),
    location: { search: "?add=1" },
    history: { replaceState() {} },
    fetch: async () => ({
      ok: responseStatus >= 200 && responseStatus < 300,
      status: responseStatus,
      async json() {
        if (invalidJSON) throw new SyntaxError("synthetic non-JSON");
        if (errorMessage) return { error: errorMessage };
        return { videos: [], free_bytes: available + 20, reserve_bytes: 20 };
      },
    }),
  };
  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, {
      value,
      configurable: true,
      writable: true,
      enumerable: true,
    });
  }
  delete require.cache[appPath];
  require(appPath);
  await new Promise(setImmediate);
  const status = document.getElementById("status");
  return {
    document,
    status,
    uploads,
    locks,
    async submit(size = 10) {
      document.getElementById("video-file").files = [
        { name: "Beispiel.mp4", size },
      ];
      const form = document
        .getElementById("content")
        .children.find((item) => item.tag === "form");
      await form.listeners.get("submit")({ preventDefault() {} });
    },
  };
}

test("space preflight refuses before sending and scrolls the German error into view", async () => {
  const ui = await page({ available: 5 });
  assert.match(
    ui.document.getElementById("space").textContent,
    /^Noch frei: .* GB$/,
  );
  await ui.submit(6);
  assert.equal(ui.uploads.length, 0);
  assert.equal(ui.locks.length, 0);
  assert.equal(ui.status.textContent, spaceError);
  assert.equal(ui.status.scrolled, true);
  assert.equal(ui.document.getElementById("video-file").disabled, false);
});

test("non-JSON 5xx uploads request caregiver help and release the screen lock", async () => {
  for (const status of [500, 502, 503, 504, 507, 599]) {
    const ui = await page();
    await ui.submit();
    assert.equal(ui.uploads[0].sent.size, 10);
    assert.equal(ui.locks[0].released, false);
    ui.uploads[0].status = status;
    ui.uploads[0].responseText = "<html>synthetic offline page</html>";
    ui.uploads[0].onload();
    assert.equal(ui.status.textContent, serverError);
    assert.equal(ui.status.scrolled, true);
    assert.equal(ui.locks[0].releases, 1);
    assert.equal(ui.document.listeners.has("visibilitychange"), false);
  }
});

test("non-JSON uploads outside 5xx retain the German unreadable-response error", async () => {
  for (const status of [201, 400]) {
    const ui = await page();
    await ui.submit();
    ui.uploads[0].status = status;
    ui.uploads[0].responseText = "synthetic non-JSON";
    ui.uploads[0].onload();
    assert.equal(ui.status.textContent, unreadable);
  }
});

test("JSON 503 uploads preserve the app's German message", async () => {
  const error =
    "Speichern oder Lesen ist gerade nicht möglich. Bitte die Betreuung verständigen.";
  const ui = await page();
  await ui.submit();
  ui.uploads[0].status = 503;
  ui.uploads[0].responseText = JSON.stringify({ error });
  ui.uploads[0].onload();
  assert.equal(ui.status.textContent, error);
  assert.equal(ui.locks[0].releases, 1);
});

test("server 507 errors preserve the German storage message and release the lock", async () => {
  const ui = await page();
  await ui.submit();
  ui.uploads[0].status = 507;
  ui.uploads[0].responseText = JSON.stringify({ error: spaceError });
  ui.uploads[0].onload();
  assert.equal(ui.status.textContent, spaceError);
  assert.equal(ui.locks[0].releases, 1);
});

test("successful uploads open the edit form and release the screen lock", async () => {
  const ui = await page();
  await ui.submit();
  ui.uploads[0].status = 201;
  ui.uploads[0].responseText = JSON.stringify({
    filename: "Beispiel.mp4",
    title: "Beispiel",
    description: "",
  });
  ui.uploads[0].onload();
  assert.equal(ui.document.getElementById("title").value, "Beispiel");
  assert.match(ui.status.textContent, /Video wurde hinzugefügt/);
  assert.equal(ui.locks[0].releases, 1);
});

test("wake locks are reacquired after returning to the page and released on reset", async () => {
  const ui = await page();
  await ui.submit();
  ui.locks[0].released = true;
  ui.document.listeners.get("visibilitychange")();
  await new Promise(setImmediate);
  assert.equal(ui.locks.length, 2);
  ui.uploads[0].onerror();
  assert.equal(ui.locks[1].releases, 1);
  assert.match(ui.status.textContent, /Übertragung wurde unterbrochen/);
  assert.equal(ui.document.getElementById("video-file").disabled, false);
});

test("uploads still work when screen wake locks are denied or unsupported", async () => {
  for (const wake of ["denied", "unsupported"]) {
    const ui = await page({ wake });
    await ui.submit();
    assert.equal(ui.uploads[0].sent.size, 10);
    ui.uploads[0].onabort();
    assert.match(ui.status.textContent, /Übertragung wurde unterbrochen/);
    assert.equal(ui.locks.length, 0);
  }
});

test("non-JSON listing responses show the existing German error", async () => {
  const ui = await page({ invalidJSON: true });
  assert.equal(ui.status.textContent, unreadable);
  assert.equal(ui.status.scrolled, true);
});

test("non-JSON 5xx listings request caregiver help", async () => {
  for (const responseStatus of [500, 502, 503, 504, 507, 599]) {
    const ui = await page({ invalidJSON: true, responseStatus });
    assert.equal(ui.status.textContent, serverError);
    assert.equal(ui.status.scrolled, true);
  }
});

test("JSON 503 listings preserve the app's German message", async () => {
  const errorMessage =
    "Die Angaben können gerade nicht gelesen werden. Bitte die Betreuung verständigen.";
  const ui = await page({ responseStatus: 503, errorMessage });
  assert.equal(ui.status.textContent, errorMessage);
  assert.equal(ui.status.scrolled, true);
});
