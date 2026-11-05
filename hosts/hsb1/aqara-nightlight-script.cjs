module.exports = function nightlightPage() {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const root = document.documentElement;
  const HUB_HANDLES = { "KI-18FB": "plug", "WZ-594F": "round" };
  const DEFAULT_NIGHTLIGHT = { rgb: "5C0701", bri: 44 };
  const PLACE_IDS = ["nacht", "p2", "p3", "p4", "p5", "p6"];
  const DEFAULT_PLACES = {
    nacht: { id: "nacht", name: "Nachtlicht", ...DEFAULT_NIGHTLIGHT },
    p2: { id: "p2", name: "Warm", rgb: "FF8C28", bri: 40 },
    p3: { id: "p3", name: "Hell", rgb: "FFF4E0", bri: 80 },
    p4: { id: "p4", name: "Rot leise", rgb: "FF2A00", bri: 5 },
  };
  const LEVEL_NAMES = {
    urgent: "Dringend",
    regular: "Regulär",
    open: "Ohne Eile",
    idle: "Ruhe",
    unknown: "Unbekannt",
  };
  let settings = {};
  let configReady = false;
  let configRevision = 0;
  let signalRevision = 0;
  let pendingDelete = null;
  let signal = null;
  let durationMode = "full";
  let autoDurationMode = "short";
  let audioDirty = false;
  let editingPlaces = false;
  let editingRule = null;
  let editingDeskRule = null;
  let ruleDraft = null;
  let ruleSlot = "rgb";
  let sending = null;
  let overlayTimer = null;
  let statusAction = null;
  const lockedControls = new Map();
  let dragPending = null;
  let dragRunning = false;
  let dragTimer = null;
  let lastDrag = -Infinity;
  const lastDragKeys = new Map();
  const placesFor = (label = selected) => presets[HUB_HANDLES[label]] || {};
  const usageFor = () =>
    settings[hub()]?.usage || (hub() === "round" ? "desk" : "nightlight");
  const states = Object.fromEntries(
    Object.keys(HUB_HANDLES).map((label) => [
      label,
      {
        rgb: DEFAULT_NIGHTLIGHT.rgb,
        lastRgb: null,
        bri: DEFAULT_NIGHTLIGHT.bri,
        colorName: "Eigene Farbe",
        lightReady: false,
        lightTouched: false,
        lightIssued: 0,
        lightSequence: 0,
        toneSequence: 0,
        readbackSequence: 0,
        last: null,
        readback: null,
        tone: null,
      },
    ]),
  );
  let selected = "KI-18FB";
  let presets = {};
  let presetsReady = false;
  let presetRevision = 0;
  let sequence = 0;
  let retryCommand = null;
  let undoCommand = null;
  let undoSequence = 0;
  let sheetSnapshot = null;
  let serverRejected = false;
  const presetSequences = {};
  let modeHintTimer = null;
  const state = () => states[selected];
  const hub = () => HUB_HANDLES[selected];
  const percent = (value) => `${value} %`;
  const presetFor = (label = selected) => presets[HUB_HANDLES[label]]?.nacht;
  const sameLight = (a, b) =>
    a && b && a.rgb === b.rgb && Number(a.bri) === Number(b.bri);
  const validPreset = (value) =>
    value &&
    /^[0-9A-F]{6}$/.test(value.rgb) &&
    Number.isInteger(value.bri) &&
    value.bri >= 0 &&
    value.bri <= 100;
  const nonBlack = (rgb) => /^[0-9A-F]{6}$/.test(rgb) && rgb !== "000000";
  function lightColor(rgb, target = selected) {
    return (
      [rgb, states[target].lastRgb, presetFor(target)?.rgb].find(nonBlack) ||
      DEFAULT_NIGHTLIGHT.rgb
    );
  }
  function remember(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (_) {
      /* Private/storage-disabled browsing. */
    }
  }
  try {
    const mode = localStorage.getItem("nightlight-mode");
    const theme = localStorage.getItem("nightlight-theme");
    const savedHub = localStorage.getItem("nightlight-hub");
    if (["kind", "erwachsen"].includes(mode)) root.dataset.mode = mode;
    if (["dark", "light"].includes(theme)) root.dataset.theme = theme;
    if (Object.hasOwn(HUB_HANDLES, savedHub)) selected = savedHub;
  } catch (_) {
    /* First visit remains Kind/Dunkel. */
  }
  function status(kind, message, action = null) {
    statusAction = action;
    $("status").className = `st ${kind}`;
    $("status-text").textContent = message;
    const icon = kind === "bad" ? "warn" : kind === "pend" ? "spin" : "check";
    $("status").querySelector("use").setAttribute("href", `#i-${icon}`);
    $("retry").hidden = action !== "retry" || serverRejected;
    $("reload").hidden = action !== "reload";
    $("undo").hidden =
      statusAction !== "undo" ||
      serverRejected ||
      !undoCommand ||
      undoCommand.label !== selected ||
      root.dataset.mode !== "erwachsen";
  }
  async function request(path, params = {}, progressOwner = null) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(path + "?" + new URLSearchParams(params), {
        method: ["/get", "/presets", "/config", "/signal"].includes(path)
          ? "GET"
          : "POST",
        headers: {
          "X-Nightlight": "1",
          ...(progressOwner === null ? {} : { Accept: "application/x-ndjson" }),
        },
        mode: "same-origin",
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
      });
      // Check HTTP status before JSON: the security response is deliberately HTML.
      if (response.status === 403) {
        const error = new Error("rejected");
        error.rejected = true;
        throw error;
      }
      if (
        response.status === 400 &&
        ["/settings", "/signal-test"].includes(path)
      ) {
        const result = await response.json();
        if (result.ok === false && result.code === "invalid_rule")
          return result;
        throw new Error("unavailable");
      }
      if (!response.ok) throw new Error("unavailable");
      if (
        response.headers
          ?.get("Content-Type")
          ?.startsWith("application/x-ndjson")
      ) {
        const reader = response.body.getReader(),
          decoder = new TextDecoder();
        let buffer = "",
          result = null;
        for (;;) {
          const chunk = await reader.read();
          buffer += decoder.decode(chunk.value || new Uint8Array(), {
            stream: !chunk.done,
          });
          let newline;
          while ((newline = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            if (!line) continue;
            const item = JSON.parse(line);
            if (Number.isInteger(item.progress)) {
              if (sending === progressOwner)
                $("sending-attempt").textContent =
                  `Versuch ${item.progress} von ${item.attempts}`;
            } else result = item;
          }
          if (chunk.done) break;
        }
        if (!result || buffer.trim()) throw new Error("incomplete reply");
        return result;
      }
      return await response.json();
    } catch (error) {
      if (controller.signal.aborted) error.timeout = true;
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
  function rejectServer() {
    serverRejected = true;
    retryCommand = null;
    undoCommand = null;
    status("bad", "Vom Server abgelehnt · Seite neu laden", "reload");
  }
  async function command(path, params, label, options = {}) {
    if (serverRejected) {
      rejectServer();
      return;
    }
    const mine = ++sequence;
    undoCommand = null;
    const target = options.target || selected;
    const tap = !options.drag;
    if (tap) lockSending(mine, label);
    if (tap && ["/set", "/apply"].includes(path)) {
      lastDragKeys.delete(`light:${target}:bri`);
      lastDragKeys.delete(`light:${target}:col`);
    }
    if (tap && ["/tone", "/stop"].includes(path))
      lastDragKeys.delete(`tone:${target}`);

    if (["/set", "/apply"].includes(path)) states[target].lightIssued = mine;
    retryCommand = { path, params: { ...params }, label, options };
    status("pend", `${label} → ${target} · wird gesendet …`);
    try {
      if (tap && dragPromise) await dragPromise;
      const result = await request(path, params, tap ? mine : null);
      // A confirmed late command still happened. Keep its per-hub cache and
      // Undo, while only the newest request owns the status/retry controls.
      if (result.ok) {
        options.success?.(result, target, mine);
        if ((options.undo || options.clearUndo) && mine >= undoSequence) {
          undoSequence = mine;
          undoCommand = options.undo || null;
        }
        render();
      }
      if (mine !== sequence || serverRejected) return;
      if (!result.ok) {
        const message =
          result.code === "hub_unavailable" &&
          ["/set", "/get", "/tone", "/stop", "/apply"].includes(path)
            ? `${target} antwortet nicht (${result.attempts || 4} Versuche)`
            : result.error || "Aktion fehlgeschlagen";
        status("bad", message, "retry");
        return;
      }
      const attempts = Number(result.versuche || 1);
      status(
        attempts > 1 ? "retry" : "ok",
        options.message ||
          `${label} → ${target} · angekommen${attempts > 1 ? ` nach ${attempts} Versuchen` : ""}`,
        options.undo ? "undo" : null,
      );
      render();
    } catch (error) {
      if (error.rejected) {
        rejectServer();
        return;
      }
      if (mine !== sequence || serverRejected) return;
      status(
        "bad",
        error.timeout
          ? `${target} antwortet nicht (Zeitüberschreitung)`
          : "Keine Verbindung zum Nachtlicht-Server",
        "retry",
      );
    } finally {
      if (tap) unlockSending(mine);
      if (!dragRunning && dragPending) scheduleDrag();
    }
  }
  async function refreshReadback(target = selected, mine = sequence) {
    if (serverRejected) return;
    try {
      const result = await request("/get", { hub: HUB_HANDLES[target] });
      if (result.ok) {
        acceptReadback(result, target, mine);
        render();
      }
    } catch (error) {
      if (error.rejected) rejectServer();
      // Approximate readback is optional; retain the action's ACK/status.
    }
  }
  function acceptReadback(result, target, mine) {
    const s = states[target];
    if (mine < s.readbackSequence) return;
    s.readbackSequence = mine;
    s.readback = result;
    if (mine >= s.lightSequence && nonBlack(result.last_rgb))
      s.lastRgb = result.last_rgb;
    if (!s.last && !s.lightTouched) {
      s.rgb = lightColor(result.rgb, target);
      s.bri = result.brightness;
      s.colorName = colorName(s.rgb);
      s.lightReady = true;
    }
  }
  function colorName(rgb) {
    const swatch = [...document.querySelectorAll("[data-color]")].find(
      (b) => b.dataset.color === rgb,
    );
    return swatch?.dataset.colorName || "Eigene Farbe";
  }
  function acceptLight(result, target, label, mine = sequence) {
    const s = states[target];
    if (mine < s.lightSequence) return;
    s.lightSequence = mine;
    if (nonBlack(result.rgb)) s.lastRgb = result.rgb;
    s.last = {
      rgb: result.rgb,
      bri: result.brightness,
      label: label || colorName(result.rgb),
    };
    if (mine >= s.lightIssued) {
      s.rgb = lightColor(s.last.rgb, target);
      s.bri = s.last.bri;
      s.colorName = s.last.label;
      s.lightReady = true;
    }
  }
  function acceptTone(target, tone, mine) {
    const s = states[target];
    if (mine < s.toneSequence) return;
    s.toneSequence = mine;
    s.tone = tone;
  }
  function cachePreset(target, value, mine) {
    if (mine < (presetSequences[target] || 0)) return;
    presetSequences[target] = mine;
    presets[HUB_HANDLES[target]] = Array.isArray(value)
      ? Object.fromEntries(value.map((p) => [p.id, { ...p }]))
      : value;
    presetsReady = true;
  }
  function cacheAllPresets(result, mine) {
    for (const target of Object.keys(HUB_HANDLES))
      cachePreset(target, result.presets[HUB_HANDLES[target]] || {}, mine);
  }
  function sendLight(label = state().colorName, drag = false, draft = null) {
    const s = draft || state();
    const target = s.target || selected;
    const rgb = lightColor(s.rgb, target);
    return command(
      "/set",
      {
        hub: s.target ? HUB_HANDLES[s.target] : hub(),
        rgb,
        bri: s.bri,
      },
      `${label} ${percent(s.bri)}`,
      {
        drag,
        target: s.target || selected,
        success: (result, target, mine) => {
          const desired = {
            rgb: states[target].rgb,
            bri: states[target].bri,
            colorName: states[target].colorName,
          };
          acceptLight(result, target, label, mine);
          if (drag && dragPending) Object.assign(states[target], desired);
        },
      },
    );
  }
  function applyNightlight(id = "nacht") {
    if (typeof id !== "string") id = "nacht";
    const name = placesFor()[id]?.name || DEFAULT_PLACES[id]?.name || "Platz";
    return command("/apply", { hub: hub(), preset: id }, name, {
      success: (result, target, mine) => {
        // /apply reads the authoritative server preset, including saves
        // from HA or another device while this page remained open.
        ++presetRevision;
        cachePreset(
          target,
          {
            ...placesFor(target),
            [id]: { id, name, rgb: result.rgb, bri: result.brightness },
          },
          mine,
        );
        acceptLight(result, target, name, mine);
      },
    });
  }
  function hsv(rgb) {
    const [r, g, b] = rgb.match(/../g).map((v) => parseInt(v, 16) / 255);
    const max = Math.max(r, g, b),
      min = Math.min(r, g, b),
      delta = max - min;
    let h =
      delta === 0
        ? 0
        : max === r
          ? ((g - b) / delta) % 6
          : max === g
            ? (b - r) / delta + 2
            : (r - g) / delta + 4;
    h = (h * 60 + 360) % 360;
    return [h, max === 0 ? 0 : delta / max];
  }
  function shiftHint(rgb, bri, name) {
    if (bri === 0 || bri >= 10 || !name) return null;
    const [before, saturation] = hsv(rgb);
    if (saturation < 0.35) return null;
    let channels = rgb
      .match(/../g)
      .map((v) => Math.round((parseInt(v, 16) * bri) / 100));
    channels = channels.map((v) => (v < 4 ? 0 : v));
    const max = Math.max(...channels);
    if (!max) return null;
    const effective = channels
      .map((v) =>
        Math.round((v * 255) / max)
          .toString(16)
          .padStart(2, "0"),
      )
      .join("");
    const [after] = hsv(effective);
    const delta = Math.abs(after - before);
    if (Math.min(delta, 360 - delta) < 12) return null;
    return {
      rgb: effective,
      text: `Bei ${percent(bri)} wirkt ${name} ${after < 15 || after > 345 ? "fast rot" : "anders"}`,
    };
  }
  function updateSliders() {
    const s = state();
    $("bri").disabled = !s.lightReady;
    $("bri").value = s.lightReady ? s.bri : 0;
    $("bri-track").style.setProperty("--f", s.lightReady ? s.bri / 100 : 0);
    $("bri-value").textContent = !s.lightReady
      ? "—"
      : s.bri === 0
        ? "Aus"
        : percent(s.bri);
    $("bri").setAttribute("aria-valuetext", $("bri-value").textContent);
    $("vol-track").style.setProperty("--f", Number($("vol").value) / 40);
    $("vol-value").textContent = percent($("vol").value);
    $("vol").setAttribute("aria-valuetext", $("vol-value").textContent);
    const hint = s.lightReady && shiftHint(s.rgb, s.bri, s.colorName);
    $("shift-hint").replaceChildren();
    if (hint) {
      const dot = document.createElement("span");
      dot.className = "dot";
      dot.style.setProperty("--c", "#" + hint.rgb);
      $("shift-hint").append(dot, document.createTextNode(hint.text));
    }
  }
  function disableControls() {
    document.querySelectorAll("button, input, select").forEach((control) => {
      if (!lockedControls.has(control))
        lockedControls.set(control, Boolean(control.disabled));
      control.disabled = true;
    });
  }
  function lockSending(mine, label) {
    sending = mine;
    dragPending = null;
    clearTimeout(dragTimer);
    clearTimeout(overlayTimer);
    disableControls();
    $("sending-label").textContent = label;
    $("sending-attempt").textContent = "Versuch 1 von 4";
    overlayTimer = setTimeout(() => {
      if (sending === mine) {
        $("sending-overlay").hidden = false;
        $("sending-overlay").showModal();
      }
    }, 250);
  }
  function unlockSending(mine) {
    if (sending !== mine) return;
    sending = null;
    clearTimeout(overlayTimer);
    $("sending-overlay").close();
    $("sending-overlay").hidden = true;
    for (const [control, disabled] of lockedControls)
      control.disabled = disabled;
    lockedControls.clear();
    render();
  }
  let dragPromise = null;
  function queueLight(control) {
    const s = { ...state(), target: selected };
    s.rgb = lightColor(s.rgb, selected);
    queueDrag({
      control: `light:${selected}:${control}`,
      key: `light:${selected}:${s.rgb}:${s.bri}`,
      run: () => sendLight(s.colorName, true, s),
    });
  }
  function toneParams(target = selected) {
    return {
      hub: HUB_HANDLES[target],
      id: states[target].tone || "10",
      vol: $("vol").value,
      ...(durationMode === "short" ? { ms: $("duration").value } : {}),
    };
  }
  function queueTone() {
    const target = selected,
      params = toneParams(target);
    queueDrag({
      control: `tone:${target}`,
      key: `tone:${target}:${params.id}:${params.vol}:${params.ms}`,
      run: () => command("/tone", params, "Ton", { target, drag: true }),
    });
  }
  function queueDrag(item) {
    if (sending || serverRejected) return;
    if (item.key === lastDragKeys.get(item.control)) {
      if (dragPending?.control === item.control) dragPending = null;
      return;
    }
    dragPending = item;
    scheduleDrag();
  }
  function scheduleDrag() {
    if (dragRunning || !dragPending || sending || serverRejected) return;
    clearTimeout(dragTimer);
    const delay = Math.max(0, 1000 - (Date.now() - lastDrag));
    if (delay) dragTimer = setTimeout(flushDrag, delay);
    else flushDrag();
  }
  async function flushDrag() {
    if (dragRunning || !dragPending || sending || serverRejected) return;
    const item = dragPending;
    dragPending = null;
    dragRunning = true;
    lastDrag = Date.now();
    lastDragKeys.set(item.control, item.key);
    try {
      dragPromise = item.run();
      await dragPromise;
    } finally {
      dragRunning = false;
      dragPromise = null;
      scheduleDrag();
    }
  }
  function renderPlaces() {
    const places = placesFor();
    document.querySelectorAll("[data-preset]").forEach((button) => {
      const p = places[button.dataset.preset];
      button.hidden = !p;
      if (!p) return;
      button.title = p.name;
      button.setAttribute("aria-label", `${p.name} · ${percent(p.bri)}`);
      button
        .querySelectorAll(".pre-n, .pre-nm")
        .forEach((n) => (n.textContent = p.name));
      button
        .querySelectorAll(".pre-v")
        .forEach((n) => (n.textContent = percent(p.bri)));
      button.querySelector(".dot")?.style.setProperty("--c", "#" + p.rgb);
    });
    $("nightlight").title = places.nacht?.name || "Nicht gespeichert";
    $("nightlight")
      .querySelectorAll(".nl-n, .nl-nm")
      .forEach((n) => (n.textContent = places.nacht?.name || "Nachtlicht"));
  }
  function renderSavePlaces() {
    const places = placesFor(sheetSnapshot?.label);
    $("sheet-title").textContent =
      `Speichern als … · ${sheetSnapshot?.label || selected}`;
    $("edit-places").textContent = editingPlaces ? "Fertig" : "Bearbeiten";
    for (const id of PLACE_IDS) {
      const row = $("place-row-" + id),
        p = places[id];
      row.hidden = !p;
      row.classList.toggle("editing", editingPlaces);
      $("rename-" + id).value = p?.name || "";
    }
    document.querySelectorAll("[data-save-place]").forEach((b) => {
      const p = places[b.dataset.savePlace];
      b.querySelector(".pl-name").textContent = p?.name || "";
      b.querySelector(".pl-v").textContent = p ? percent(p.bri) : "";
      b.querySelector(".dot").style.setProperty(
        "--c",
        "#" + (p?.rgb || "000000"),
      );
      b.setAttribute(
        "aria-pressed",
        String(sheetSnapshot?.id === b.dataset.savePlace),
      );
    });
    document
      .querySelectorAll("[data-delete-place]")
      .forEach(
        (b) => (b.hidden = !editingPlaces || b.dataset.deletePlace === "nacht"),
      );
    document
      .querySelectorAll("[data-rename-place]")
      .forEach((b) => (b.hidden = !editingPlaces));
    $("new-place").hidden = Object.keys(places).length >= 6;
  }
  function selectSavePlace(id) {
    if (!sheetSnapshot) return;
    pendingDelete = null;
    $("delete-place-confirm").hidden = true;
    $("place-ha-note").textContent =
      id === "nacht"
        ? "Gilt für die Nachtlicht-Taste hier und die zugehörige HA-Aktion."
        : "Gilt nur für diesen gespeicherten Platz.";
    const standard = DEFAULT_PLACES[id] || DEFAULT_NIGHTLIGHT;
    $("reset-preset").textContent =
      `Auf Standard zurücksetzen (#${standard.rgb} · ${standard.bri} %)`;
    sheetSnapshot.id = id;
    const p = placesFor(sheetSnapshot.label)[id];
    sheetSnapshot.old = validPreset(p) ? { ...p } : null;
    for (const [prefix, value] of [
      ["old", sheetSnapshot.old],
      ["new", sheetSnapshot.next],
    ]) {
      $(prefix + "-preset").textContent = value
        ? `#${value.rgb} · ${percent(value.bri)}`
        : "Nicht gespeichert";
      $(prefix + "-dot").hidden = !value;
      if (value) $(prefix + "-dot").style.setProperty("--c", "#" + value.rgb);
    }
    renderSavePlaces();
  }
  function changePlace(params, label) {
    if (root.dataset.mode !== "erwachsen") return;
    const target = sheetSnapshot?.label || selected;
    ++presetRevision;
    return command("/preset", { hub: HUB_HANDLES[target], ...params }, label, {
      target,
      success: (result, _, mine) => {
        cachePreset(target, result.presets[HUB_HANDLES[target]] || [], mine);
        renderSavePlaces();
      },
    });
  }
  $("edit-places").addEventListener("click", () => {
    editingPlaces = !editingPlaces;
    renderSavePlaces();
  });
  document
    .querySelectorAll("[data-save-place]")
    .forEach((b) =>
      b.addEventListener("click", () => selectSavePlace(b.dataset.savePlace)),
    );
  document.querySelectorAll("[data-rename-place]").forEach((b) =>
    b.addEventListener("click", () => {
      const id = b.dataset.renamePlace,
        name = $("rename-" + id).value.trim();
      if (!name || [...name].length > 16) {
        status("bad", "Name muss 1–16 Zeichen haben");
        return;
      }
      changePlace({ id, name }, "Platz umbenennen");
    }),
  );
  document.querySelectorAll("[data-delete-place]").forEach((b) =>
    b.addEventListener("click", () => {
      if (b.dataset.deletePlace === "nacht") return;
      pendingDelete = b.dataset.deletePlace;
      $("delete-place-label").textContent =
        `${placesFor(sheetSnapshot.label)[pendingDelete]?.name || "Platz"} löschen?`;
      $("delete-place-confirm").hidden = false;
    }),
  );
  $("cancel-place-delete").addEventListener("click", () => {
    pendingDelete = null;
    $("delete-place-confirm").hidden = true;
  });
  $("confirm-place-delete").addEventListener("click", () => {
    const id = pendingDelete;
    pendingDelete = null;
    $("delete-place-confirm").hidden = true;
    if (id) changePlace({ id, delete: 1 }, "Platz löschen");
  });
  $("new-place").addEventListener("click", () =>
    changePlace({ new: 1, ...sheetSnapshot.next }, "Neuer Platz"),
  );
  function ruleName(key) {
    const [level, desk] = key.split(":");
    return (
      LEVEL_NAMES[level] +
      (desk
        ? ` · ${desk === "both" ? "Mehrere Desks" : deskList().find((d) => d.id === desk)?.short || "Desk"}`
        : "")
    );
  }
  const deskList = () => settings[hub()]?.desks || [];
  const make = (tag, cls = "", text = "") => {
    const element = document.createElement(tag);
    element.className = cls;
    element.textContent = text;
    return element;
  };
  function deskDots(container, desks) {
    container.replaceChildren();
    for (const desk of desks) {
      const chip = make("span", "dd");
      const dot = make("span", "dot");
      dot.style.setProperty("--c", "#" + desk.rgb);
      chip.append(dot, document.createTextNode(desk.short));
      container.append(chip);
    }
  }
  function renderDesk() {
    const desk = usageFor() === "desk",
      cfg = settings[hub()];
    $("nightlight-controls").hidden = desk;
    $("desk-controls").hidden = !desk;
    $("usage-text").textContent =
      `Verwendung: ${desk ? "Desk-Signal" : "Nachtlicht"}`;
    $("desk-kind").textContent = `${selected} zeigt den Desk`;
    document.querySelectorAll("[data-usage]").forEach((b) => {
      b.setAttribute("aria-checked", String(b.dataset.usage === usageFor()));
      b.tabIndex = b.dataset.usage === usageFor() ? 0 : -1;
      b.disabled = !configReady || serverRejected;
    });
    renderTabs();
    if (!cfg) return;
    document.querySelectorAll("[data-rule]").forEach((b) => {
      const r = cfg.rules[b.dataset.rule];
      if (!r) return;
      const value = r.bri ? percent(r.bri) : "Aus";
      b.querySelector(".cv").textContent = value;
      b.querySelector(".cwave").classList.toggle(
        "motion-hidden",
        !r.bri || r.mode === "steady",
      );
      b.querySelector(".rule-motion").textContent = r.bri
        ? r.mode === "steady"
          ? "ständig"
          : `${r.mode === "blink" ? "blinkt" : "wechselt"} (${r.takt} s)`
        : "";
      b.querySelector(".dot").style.setProperty("--c", "#" + r.rgb);
      b.querySelector(".dot").hidden = ["urgent", "regular", "open"].includes(
        b.dataset.rule,
      );
      b.setAttribute(
        "aria-label",
        `${ruleName(b.dataset.rule)}: ${value} · ${r.mode === "steady" ? "ständig" : r.mode === "blink" ? "blinkt" : "wechselt"} (${r.takt} s)`,
      );
      deskDots(
        b.querySelector(".rr-dots"),
        r.bri && ["urgent", "regular", "open"].includes(b.dataset.rule)
          ? cfg.desks
          : [],
      );
    });
    $("multiple-settings").hidden = cfg.desks.length < 2;
    $("multiple-own").hidden = cfg.multiple.mode !== "own";
    $("multiple-colors").hidden = cfg.multiple.mode !== "cycle";
    $("multiple-color").value = "#" + cfg.multiple.rgb;
    renderColorPicks("multiple", cfg.multiple.rgb);
    document
      .querySelectorAll("[data-multiple]")
      .forEach((b) =>
        b.setAttribute(
          "aria-pressed",
          String(b.dataset.multiple === cfg.multiple.mode),
        ),
      );
    deskDots($("multiple-colors"), cfg.desks);
    $("auto-sound").setAttribute("aria-checked", String(cfg.auto_sound));
    if (!audioDirty) {
      $("auto-vol").value = cfg.sound_vol ?? 10;
      $("auto-duration").value = cfg.sound_ms ?? 1000;
      $("auto-duration-ms").value = $("auto-duration").value;
      autoDurationMode = cfg.sound_ms === null ? "full" : "short";
    }
    renderAutoDuration();
    const active = signal?.hub === hub() ? signal : null,
      feed = active?.feed;
    const key = active?.key || "unknown",
      r = active?.rule || cfg.rules.unknown;
    $("desk-lit").textContent =
      `Leuchtet: ${ruleName(key)} · ${percent(r.bri)}${r.mode !== "steady" ? ` · ${r.mode === "blink" ? "blinkt" : "wechselt"} (${r.takt} s)` : ""}`;
    $("desk-time").textContent = feed
      ? `Stand ${stamp(feed.updated_at)}`
      : "Stand — · keine aktuellen Daten";
    const canSee = Boolean(
      feed && !["unknown", "idle"].includes(key) && r.bri > 0,
    );
    $("desk-seen").hidden = !canSee;
    $("desk-seen").disabled = !canSee;
    $("no-desks").hidden = cfg.desks.length > 0;
    $("signal-add-desk").hidden = cfg.desks.length > 0;
    $("desk-empty").hidden = cfg.desks.length > 0;
    $("desk-signal-rows").replaceChildren();
    $("desk-list").replaceChildren();
    for (const d of cfg.desks) {
      const row = make("li"),
        dot = make("span", "dot"),
        text = make("span", "dr-m"),
        age = make("span", "dr-w");
      dot.style.setProperty("--c", "#" + d.rgb);
      const counts = feed?.desks[d.id],
        sent = active?.desk_applied?.[d.id];
      const countsText = !counts
        ? "keine Daten"
        : `${counts.open} offen · ${counts.held} warten`;
      text.textContent =
        countsText +
        (sent
          ? ` · zuletzt #${sent.rgb} · ${percent(sent.bri)}`
          : " · noch nichts gesendet");
      age.textContent = sent
        ? `vor ${Math.max(0, Math.floor(Date.now() / 1000 - sent.at))} s`
        : "—";
      row.append(dot, make("span", "kchip", d.short), text, age);
      $("desk-signal-rows").append(row);
      const item = make("li"),
        button = make("button", "dl-row");
      button.type = "button";
      button.setAttribute("aria-label", `${d.short} bearbeiten`);
      const meta = make("span", "dl-m"),
        title = make("span", "dl-1", `${d.short} · ${d.name}`);
      meta.append(
        title,
        make("span", "dl-st", d.url || "Instanz fehlt"),
        make(
          "span",
          "dl-st",
          d.key_set
            ? "Schlüssel gesetzt · keine Daten"
            : "Schlüssel fehlt · neu eintragen",
        ),
      );
      button.append(meta);
      button.addEventListener("click", () => openDesk(d.id));
      item.append(button);
      $("desk-list").append(item);
    }
    renderPreview(active, cfg);
    updateOverflowButton();
  }
  const stamp = (seconds) =>
    new Date(seconds * 1000).toLocaleTimeString("de-AT", {
      hour: "2-digit",
      minute: "2-digit",
      timeZone: "Europe/Vienna",
    });
  const phone =
    typeof matchMedia === "function"
      ? matchMedia("(max-width: 979px)")
      : { matches: false };
  const reducedMotion =
    typeof matchMedia === "function" &&
    matchMedia("(prefers-reduced-motion: reduce)").matches;
  const tabsByHub = {};
  let previewPaused = reducedMotion,
    previewTimer = null,
    previewFrame = 0,
    previewSignature = "";
  let overflowRestore = null;
  let editingDesk = null,
    deskOwn = false,
    deskConfirmation = null,
    deskBusy = false;
  try {
    previewPaused =
      reducedMotion ||
      localStorage.getItem("nightlight-preview-paused") === "1";
    for (const h of Object.values(HUB_HANDLES))
      tabsByHub[h] = localStorage.getItem("nightlight-tab-" + h);
  } catch (_) {
    /* Requested interface preferences; no optional services. */
  }
  function allowedTabs() {
    return usageFor() !== "desk"
      ? ["light", "sounds"]
      : root.dataset.mode === "kind"
        ? []
        : ["signal", "rules", "auto-tone", "desks"];
  }
  function renderTabs() {
    const allowed = allowedTabs();
    if (allowed.length && !allowed.includes(tabsByHub[hub()]))
      tabsByHub[hub()] = allowed[0];
    const current = tabsByHub[hub()];
    $("tabbar").hidden = !phone.matches || !allowed.length;
    $("panel-more").hidden = !phone.matches || !allowed.length;
    document.querySelectorAll("[data-tab]").forEach((b) => {
      b.hidden = !allowed.includes(b.dataset.tab);
      b.setAttribute("aria-selected", String(current === b.dataset.tab));
      b.tabIndex = current === b.dataset.tab ? 0 : -1;
    });
    document.querySelectorAll("[data-panel]").forEach((p) => {
      p.classList.toggle("active-panel", current === p.dataset.panel);
      p.setAttribute("role", phone.matches ? "tabpanel" : "region");
      if (phone.matches)
        p.setAttribute("aria-labelledby", "tab-" + p.dataset.panel);
    });
    $("panel-more").textContent =
      current === "desks" ? "Alle Desks anzeigen" : "Mehr anzeigen";
    updateOverflowButton();
  }
  function updateOverflowButton() {
    $("panel-more").hidden = true;
    if (!phone.matches || !allowedTabs().length) return;
    const panel = $("panel-" + tabsByHub[hub()]);
    if (!panel) return;
    // Measure with the More button absent. On overflow, the sheet holds the
    // actual panel and controls, so there is one bound action per button.
    $("panel-more").hidden =
      panel.clientHeight > 0 && panel.scrollHeight <= panel.clientHeight;
  }
  if (typeof ResizeObserver === "function") {
    const overflowObserver = new ResizeObserver(updateOverflowButton);
    document
      .querySelectorAll("[data-panel]")
      .forEach((panel) => overflowObserver.observe(panel));
  }
  function selectTab(tab) {
    if (!allowedTabs().includes(tab)) return;
    restoreOverflow();
    tabsByHub[hub()] = tab;
    remember("nightlight-tab-" + hub(), tab);
    renderTabs();
  }
  document.querySelectorAll("[data-tab]").forEach((b) => {
    b.addEventListener("click", () => selectTab(b.dataset.tab));
    b.addEventListener("keydown", (event) => {
      const allowed = allowedTabs(),
        index = allowed.indexOf(b.dataset.tab);
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
        return;
      event.preventDefault();
      const next =
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? allowed.length - 1
            : (index + (event.key === "ArrowRight" ? 1 : -1) + allowed.length) %
              allowed.length;
      selectTab(allowed[next]);
      $("tab-" + allowed[next]).focus();
    });
  });
  function restoreOverflow() {
    if (!overflowRestore) return;
    const { panel, parent, next } = overflowRestore;
    parent.insertBefore(panel, next);
    overflowRestore = null;
    $("overflow-sheet").close();
  }
  $("panel-more").addEventListener("click", () => {
    const panel = $("panel-" + tabsByHub[hub()]);
    if (!panel || !allowedTabs().length) return;
    overflowRestore = {
      panel,
      parent: panel.parentNode,
      next: panel.nextSibling,
    };
    $("overflow-body").append(panel);
    $("overflow-sheet").showModal();
  });
  $("overflow-sheet").addEventListener("close", restoreOverflow);
  $("overflow-sheet").addEventListener("cancel", restoreOverflow);
  $("light-info").addEventListener("click", () => $("info-sheet").showModal());
  $("sound-options").addEventListener("click", () => {
    $("sound-sheet-body").append($("sound-duration"));
    $("sound-sheet").showModal();
  });
  document
    .querySelectorAll("[data-close]")
    .forEach((b) =>
      b.addEventListener("click", () => $(b.dataset.close).close()),
    );
  phone.addEventListener?.("change", () => {
    restoreOverflow();
    renderTabs();
    if (
      !phone.matches &&
      $("sound-duration").parentNode === $("sound-sheet-body")
    )
      $("panel-sounds").append($("sound-duration"));
  });
  $("preview-pause").addEventListener("click", () => {
    previewPaused = !previewPaused;
    remember("nightlight-preview-paused", previewPaused ? "1" : "0");
    renderPreview(signal?.hub === hub() ? signal : null, settings[hub()]);
  });
  function renderPreview(active, cfg) {
    clearTimeout(previewTimer);
    if (!cfg) return;
    const applied = active?.applied,
      rule = applied || cfg.rules.unknown;
    const colors = applied?.colors || [];
    const signature = JSON.stringify([hub(), applied]);
    if (signature !== previewSignature) {
      previewSignature = signature;
      previewFrame = Math.max(0, colors.indexOf(rule.rgb));
    }
    const effectiveBri = rule.rule_bri ?? rule.bri;
    const animate =
      applied &&
      (colors.length > 1 || rule.mode !== "steady") &&
      effectiveBri > 0;
    $("lamp-preview").classList.toggle("off", effectiveBri === 0);
    $("lamp-preview").classList.toggle(
      "blink",
      Boolean(animate && !colors.length && rule.mode === "blink"),
    );
    $("lamp-preview").classList.toggle(
      "swap",
      Boolean(animate && !colors.length && rule.mode === "alternate"),
    );
    $("lamp-preview").style.setProperty(
      "--c",
      "#" + (colors.length ? colors[previewFrame % colors.length] : rule.rgb),
    );
    $("lamp-preview").style.setProperty(
      "--c2",
      "#" +
        (rule.rgb === rule.rgb2
          ? rule.rgb1 || rule.rgb
          : rule.rgb2 || rule.rgb),
    );
    $("lamp-preview").style.setProperty(
      "--phase-offset",
      rule.mode === "blink" && rule.bri === 0 && effectiveBri > 0
        ? -Math.max(2, rule.takt) + "s"
        : "0s",
    );
    $("lamp-preview").style.setProperty(
      "--period",
      Math.max(2, rule.takt || 2) * 2 + "s",
    );
    $("lamp-card").classList.toggle("paused", previewPaused);
    $("preview-note").hidden = !previewPaused;
    $("preview-pause").setAttribute("aria-pressed", String(previewPaused));
    $("preview-pause").setAttribute(
      "aria-label",
      previewPaused ? "Vorschau fortsetzen" : "Vorschau anhalten",
    );
    $("preview-pause").textContent = previewPaused ? "▶" : "Ⅱ";
    $("desk-applied").textContent = applied
      ? `Zuletzt gesendet: ${ruleName(applied.key)} · ${percent(applied.bri)} · ${stamp(applied.at)} · ${applied.confirmed ? "bestätigt" : "nicht bestätigt"}`
      : "Zuletzt gesendet: noch kein Befehl · nicht bestätigt";
    if (colors.length > 1 && animate && !previewPaused)
      previewTimer = setTimeout(
        () => {
          previewFrame += 1;
          renderPreview(active, cfg);
        },
        Math.max(2, rule.takt) * 1000,
      );
  }
  document.querySelectorAll("[data-multiple]").forEach((b) =>
    b.addEventListener("click", () => {
      if (root.dataset.mode === "erwachsen")
        saveConfig(
          { multiple_mode: b.dataset.multiple },
          "Mehrere Desks speichern",
        );
    }),
  );
  $("multiple-color").addEventListener("change", () => {
    const rgb = $("multiple-color").value.slice(1).toUpperCase();
    if (root.dataset.mode === "erwachsen" && nonBlack(rgb))
      saveConfig({ multiple_rgb: rgb }, "Eigene Farbe speichern");
  });
  function renderColorPicks(scope, rgb) {
    const buttons = [...document.querySelectorAll(`[data-${scope}-color]`)];
    for (const b of buttons)
      b.setAttribute(
        "aria-pressed",
        String(b.dataset[scope + "Color"] === rgb),
      );
    const own = !buttons.some((b) => b.dataset[scope + "Color"] === rgb);
    $(scope + "-own-color").setAttribute("aria-pressed", String(own));
    $(scope + "-own-dot").classList.toggle("empty", !own);
    $(scope + "-own-dot").style.setProperty("--c", "#" + rgb);
  }
  for (const scope of ["desk", "multiple"]) {
    document.querySelectorAll(`[data-${scope}-color]`).forEach((button) =>
      button.addEventListener("click", () => {
        $(scope + "-color").value = "#" + button.dataset[scope + "Color"];
        renderColorPicks(scope, button.dataset[scope + "Color"]);
        if (scope === "multiple")
          $("multiple-color").dispatchEvent(
            new Event("change", { bubbles: true }),
          );
      }),
    );
    $(scope + "-own-color").addEventListener("click", () => {
      try {
        if ($(scope + "-color").showPicker) $(scope + "-color").showPicker();
        else $(scope + "-color").click();
      } catch (_) {
        $(scope + "-color").click();
      }
    });
  }
  $("desk-color").addEventListener("input", () => {
    const rgb = $("desk-color").value.slice(1).toUpperCase();
    if (nonBlack(rgb)) renderColorPicks("desk", rgb);
  });
  function openDesk(id = null) {
    if (root.dataset.mode !== "erwachsen" || !configReady || deskBusy) return;
    editingDesk = id;
    const desk = deskList().find((d) => d.id === id);
    $("desk-title").textContent = desk
      ? `${desk.short} bearbeiten`
      : "Desk hinzufügen";
    $("desk-short").value = desk?.short || "";
    $("desk-name").value = desk?.name || "";
    $("desk-url").value = desk?.url || "";
    $("desk-color").value = "#" + (desk?.rgb || "18C2B0");
    renderColorPicks("desk", desk?.rgb || "18C2B0");
    $("desk-key").value = "";
    $("desk-key").hidden = Boolean(desk?.key_set);
    $("desk-replace").hidden = !desk?.key_set;
    $("desk-key-state").textContent = desk?.key_set
      ? `Schlüssel gesetzt seit ${new Date(desk.key_set_at * 1000).toLocaleDateString("de-AT")} · zum Ersetzen neu eintragen`
      : "Schlüssel fehlt · neu eintragen";
    deskOwn = desk?.override || false;
    $("desk-remove").hidden = !desk;
    $("desk-error").textContent = "";
    $("desk-confirm").hidden = true;
    deskConfirmation = null;
    renderDeskOverride();
    $("desk-sheet").showModal();
    $("desk-short").focus();
  }
  function renderDeskOverride() {
    $("desk-override").setAttribute("aria-checked", String(deskOwn));
    $("desk-own-rules").hidden = !deskOwn;
    $("desk-own-rules").replaceChildren();
    if (editingDesk)
      for (const level of ["urgent", "regular", "open"]) {
        const rule = deskList().find((d) => d.id === editingDesk).rules[level];
        const motion =
          rule.mode === "steady"
            ? "ständig"
            : `${rule.mode === "blink" ? "blinkt" : "wechselt"} (${rule.takt} s)`;
        const button = make(
          "button",
          "rr",
          `${ruleName(level)} · ${rule.bri ? `${percent(rule.bri)} · ${motion}` : "Aus"}`,
        );
        button.type = "button";
        button.addEventListener("click", () => openRule(level, editingDesk));
        $("desk-own-rules").append(button);
      }
    else if (deskOwn)
      $("desk-own-rules").textContent =
        "Nach dem Speichern lassen sich die eigenen Regeln bearbeiten.";
  }
  $("desk-override").addEventListener("click", () => {
    deskOwn = !deskOwn;
    renderDeskOverride();
  });
  $("desk-replace").addEventListener("click", () => {
    if (root.dataset.mode !== "erwachsen") return;
    $("desk-key").hidden = false;
    $("desk-replace").hidden = true;
    $("desk-key").focus();
  });
  $("add-desk").addEventListener("click", () => openDesk());
  $("signal-add-desk").addEventListener("click", () => {
    selectTab("desks");
    openDesk();
  });
  $("rule-edit-desks").addEventListener("click", () => {
    $("rule-sheet").close();
    selectTab("desks");
  });
  $("desk-sheet").addEventListener("close", () => {
    $("desk-key").value = "";
    deskConfirmation = null;
  });
  $("desk-sheet").addEventListener("cancel", () => {
    $("desk-key").value = "";
    deskConfirmation = null;
  });
  $("desk-confirm-cancel").addEventListener("click", () => {
    $("desk-confirm").hidden = true;
    deskConfirmation = null;
    $("desk-key").value = "";
  });
  function confirmDesk(action) {
    if (root.dataset.mode !== "erwachsen" || deskBusy) return;
    deskConfirmation = action;
    $("desk-confirm-text").textContent =
      action === "remove"
        ? "Desk entfernen? Der Schlüssel wird hier gelöscht. Im Desk bleibt er gültig, bis er dort widerrufen wird."
        : "Schlüssel ersetzen? Der alte Schlüssel wird hier gelöscht. Bitte anschließend im Desk widerrufen.";
    $("desk-confirm").hidden = false;
  }
  $("desk-remove").addEventListener("click", () => confirmDesk("remove"));
  $("desk-save").addEventListener("click", () => {
    if (editingDesk && $("desk-key").value) confirmDesk("replace");
    else performDeskAction(false);
  });
  $("desk-test").addEventListener("click", () => performDeskAction(true));
  $("desk-confirm-ok").addEventListener("click", () => {
    if (deskConfirmation) performDeskAction(false, deskConfirmation);
  });
  async function performDeskAction(test, confirmation = "") {
    if (root.dataset.mode !== "erwachsen" || deskBusy || serverRejected) return;
    const target = hub(),
      label = selected;
    const payload =
      confirmation === "remove"
        ? { hub: target, id: editingDesk, action: "remove", confirm: "remove" }
        : {
            hub: target,
            ...(editingDesk ? { id: editingDesk } : {}),
            short: $("desk-short").value.trim().toUpperCase(),
            name: $("desk-name").value.trim(),
            url: $("desk-url").value.trim(),
            rgb: $("desk-color").value.slice(1).toUpperCase(),
            key: $("desk-key").value,
            override: deskOwn ? "1" : "0",
            confirm: confirmation,
          };
    // Key input stays only in this one request closure: never query strings,
    // retry/undo state, storage, status labels or a saved rule/settings object.
    $("desk-key").value = "";
    deskBusy = true;
    const controller = new AbortController(),
      timer = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(test ? "/desk-test" : "/desk", {
        method: "POST",
        headers: {
          "X-Nightlight": "1",
          "X-Nightlight-Mode": "erwachsen",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
        mode: "same-origin",
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
      });
      if (response.status === 403) {
        rejectServer();
        return;
      }
      const result = await response.json();
      if (result.revoke && target === hub())
        $("revoke-reminder").hidden = false;
      if (!result.ok) {
        $("desk-error").textContent =
          "Dieser Schlüssel darf mehr als Zählungen lesen oder seine Berechtigung konnte nicht geprüft werden. Bitte im Desk einen „Desk signal“-Schlüssel erstellen.";
        return;
      }
      if (test) {
        $("desk-error").textContent =
          "Verbindung geprüft · nur Zählungen. Zum Speichern den Schlüssel erneut eintragen.";
        return;
      }
      ++configRevision;
      settings[target] = result.settings[target];
      configReady = true;
      if (target === hub()) {
        $("desk-sheet").close();
        $("revoke-reminder").hidden = !result.revoke;
        status(
          "ok",
          result.revoke
            ? "Schlüssel geändert · alten Schlüssel im Desk widerrufen"
            : `Desk gespeichert · ${label}`,
        );
        render();
        loadSignal();
      }
    } catch (_) {
      $("desk-error").textContent =
        "Desk konnte nicht geprüft oder gespeichert werden. Schlüssel neu eintragen.";
    } finally {
      payload.key = "";
      clearTimeout(timer);
      deskBusy = false;
      deskConfirmation = null;
      $("desk-confirm").hidden = true;
    }
  }
  $("desk-history").addEventListener("click", () => {
    if (root.dataset.mode !== "erwachsen") return;
    $("history-list").replaceChildren();
    const actions = {
      add: "hinzugefügt",
      save: "gespeichert",
      replace: "Schlüssel ersetzt",
      remove: "entfernt",
    };
    for (const event of [...(settings[hub()]?.history || [])].reverse())
      $("history-list").append(
        make(
          "li",
          "",
          `${event.short} · ${actions[event.action]} · ${new Date(event.at * 1000).toLocaleString("de-AT")}`,
        ),
      );
    $("history-sheet").showModal();
  });
  $("revoke-how").addEventListener("click", () =>
    $("revoke-sheet").showModal(),
  );
  async function loadConfig() {
    const revision = configRevision,
      mine = sequence;
    try {
      const result = await request("/config");
      if (!result.ok)
        throw Object.assign(new Error(), { userMessage: result.error });
      if (revision !== configRevision) return;
      settings = result.settings;
      configReady = true;
      render();
      if (usageFor() === "desk") loadSignal();
    } catch (error) {
      if (error.rejected) rejectServer();
      else if (mine === sequence && !serverRejected) {
        retryCommand = {
          path: "/config",
          params: {},
          label: "Einstellungen laden",
          options: {
            success: (result) => {
              settings = result.settings;
              configReady = true;
              if (usageFor() === "desk") loadSignal();
            },
          },
        };
        status(
          "bad",
          error.userMessage || "Keine Verbindung zum Nachtlicht-Server",
          "retry",
        );
      }
    }
  }
  async function loadSignal() {
    const target = selected,
      revision = ++signalRevision;
    try {
      const result = await request("/signal", { hub: HUB_HANDLES[target] });
      if (revision !== signalRevision) return;
      if (result.ok && target === selected) {
        signal = { ...result, hub: HUB_HANDLES[target] };
        render();
      } else if (!result.ok && target === selected)
        status("bad", result.error || "Desk-Signal nicht verfügbar");
    } catch (error) {
      if (error.rejected) rejectServer();
      else if (target === selected) {
        signal = null;
        render();
      }
    }
  }
  function saveConfig(params, label) {
    ++configRevision;
    const target = selected;
    return command("/settings", { hub: hub(), ...params }, label, {
      target,
      success: (result) => {
        settings[HUB_HANDLES[target]] = result.settings[HUB_HANDLES[target]];
        configReady = true;
        audioDirty = false;
        if (target === selected && usageFor() === "desk") loadSignal();
      },
    });
  }
  document.querySelectorAll("[data-usage]").forEach((b) => {
    b.addEventListener("click", () =>
      saveConfig({ usage: b.dataset.usage }, "Verwendung speichern"),
    );
    b.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
        return;
      event.preventDefault();
      const usage =
        event.key === "Home"
          ? "nightlight"
          : event.key === "End"
            ? "desk"
            : usageFor() === "desk"
              ? "nightlight"
              : "desk";
      const button = [...document.querySelectorAll("[data-usage]")].find(
        (item) => item.dataset.usage === usage,
      );
      if (button.disabled || usage === usageFor()) return;
      button.focus();
      saveConfig({ usage }, "Verwendung speichern");
    });
  });
  $("desk-seen").addEventListener("click", () =>
    command("/seen", { hub: hub() }, "Gesehen", {
      success: (result, target) => {
        ++signalRevision;
        signal = { ...result, hub: HUB_HANDLES[target] };
      },
    }),
  );
  $("auto-sound").addEventListener("click", () =>
    saveConfig(
      { auto_sound: settings[hub()].auto_sound ? 0 : 1 },
      "Automatischer Ton",
    ),
  );
  function renderAutoDuration() {
    $("auto-duration-controls").hidden = autoDurationMode !== "short";
    document
      .querySelectorAll("[data-auto-duration]")
      .forEach((b) =>
        b.setAttribute(
          "aria-pressed",
          String(b.dataset.autoDuration === autoDurationMode),
        ),
      );
    sliderValue("auto-vol", " %");
    sliderValue("auto-duration", " ms");
  }
  document.querySelectorAll("[data-auto-duration]").forEach((b) =>
    b.addEventListener("click", () => {
      audioDirty = true;
      autoDurationMode = b.dataset.autoDuration;
      renderAutoDuration();
    }),
  );
  $("auto-vol").addEventListener("input", () => {
    audioDirty = true;
    renderAutoDuration();
  });
  $("auto-duration").addEventListener("input", () => {
    audioDirty = true;
    $("auto-duration-ms").value = $("auto-duration").value;
    renderAutoDuration();
  });
  $("auto-duration-ms").addEventListener("change", () => {
    const n = Number($("auto-duration-ms").value);
    if (!Number.isInteger(n) || n < 200 || n > 3000) {
      $("auto-duration-ms").value = $("auto-duration").value;
      return;
    }
    audioDirty = true;
    $("auto-duration").value = n;
    renderAutoDuration();
  });
  $("auto-tone-test").addEventListener("click", () =>
    command(
      "/tone",
      {
        hub: hub(),
        id: 10,
        vol: $("auto-vol").value,
        ...(autoDurationMode === "short"
          ? { ms: $("auto-duration").value }
          : {}),
      },
      "Klingel testen",
    ),
  );
  $("auto-tone-save").addEventListener("click", () =>
    saveConfig(
      {
        sound_vol: $("auto-vol").value,
        sound_ms: autoDurationMode === "short" ? $("auto-duration").value : "",
      },
      "Ton speichern",
    ),
  );
  function sliderValue(id, suffix = "") {
    const input = $(id),
      value = Number(input.value),
      low = Number(input.min || input.getAttribute("min")),
      high = Number(input.max || input.getAttribute("max"));
    $(id + "-track").style.setProperty("--f", (value - low) / (high - low));
    $(id + "-value").textContent = String(value) + suffix;
  }
  function renderDuration() {
    $("duration-controls").hidden = durationMode !== "short";
    document
      .querySelectorAll("[data-duration]")
      .forEach((b) =>
        b.setAttribute(
          "aria-pressed",
          String(
            b.dataset.duration ===
              (durationMode === "short" ? "short" : "full"),
          ),
        ),
      );
    sliderValue("duration", " ms");
  }
  document.querySelectorAll("[data-duration]").forEach((b) =>
    b.addEventListener("click", () => {
      durationMode = b.dataset.duration;
      renderDuration();
    }),
  );
  $("duration").addEventListener("input", () => {
    $("duration-ms").value = $("duration").value;
    renderDuration();
  });
  $("duration-ms").addEventListener("change", () => {
    const n = Number($("duration-ms").value);
    if (!Number.isInteger(n) || n < 200 || n > 3000) {
      $("duration-ms").value = $("duration").value;
      return;
    }
    $("duration").value = n;
    renderDuration();
  });
  $("tone-test").addEventListener("click", () => {
    const target = selected,
      params = toneParams();
    command("/tone", params, "Ton testen", {
      success: (_, target, mine) => acceptTone(target, params.id, mine),
    });
  });
  function renderRuleEditor() {
    if (!ruleDraft) return;
    for (const slot of ["rgb", "rgb2"])
      if (!nonBlack(ruleDraft[slot])) ruleDraft[slot] = DEFAULT_NIGHTLIGHT.rgb;
    const fromDesk = ["urgent", "regular", "open"].includes(editingRule);
    $("rule-from-desk").hidden = !fromDesk;
    $("rule-color-controls").hidden =
      fromDesk && ruleDraft.mode !== "alternate";
    if (fromDesk) ruleSlot = "rgb2";
    $("rule-thresholds").hidden = editingRule !== "urgent";
    $("rule-color").value = "#" + ruleDraft[ruleSlot];
    $("rule-bri").value = ruleDraft.bri;
    $("rule-bri").min = editingRule === "unknown" ? 1 : 0;
    $("rule-takt").value = ruleDraft.takt;
    $("rule-takt-row").hidden = ruleDraft.mode === "steady";
    document.querySelectorAll("[data-rule-slot]").forEach((b) => {
      b.hidden =
        fromDesk ||
        (b.dataset.ruleSlot === "rgb2" && ruleDraft.mode !== "alternate");
      b.setAttribute("aria-pressed", String(b.dataset.ruleSlot === ruleSlot));
    });
    document.querySelectorAll("[data-rule-mode]").forEach((b) => {
      b.disabled = editingRule === "unknown" && b.dataset.ruleMode === "blink";
      b.setAttribute(
        "aria-pressed",
        String(b.dataset.ruleMode === ruleDraft.mode),
      );
    });
    document.querySelectorAll("[data-rule-place]").forEach((b) => {
      const p = placesFor()[b.dataset.rulePlace];
      b.hidden = !p;
      b.disabled = !nonBlack(p?.rgb);
      b.textContent = p?.name || "";
    });
    sliderValue("rule-bri", " %");
    sliderValue("rule-takt", " s");
    const other =
      settings[hub()].rules[editingRule === "idle" ? "unknown" : "idle"];
    const distance = Math.sqrt(
      ruleDraft.rgb
        .match(/../g)
        .reduce(
          (n, v, i) =>
            n +
            (parseInt(v, 16) -
              parseInt(other.rgb.slice(i * 2, i * 2 + 2), 16)) **
              2,
          0,
        ),
    );
    $("rule-warning").textContent =
      ["idle", "unknown"].includes(editingRule) &&
      Math.abs(ruleDraft.bri - other.bri) < 5 &&
      distance < 90
        ? "Ruhe und Unbekannt sind zu ähnlich. Bitte deutlicher unterscheiden."
        : "";
  }
  function openRule(key, deskId = null) {
    if (root.dataset.mode !== "erwachsen" || !settings[hub()]) return;
    editingRule = key;
    editingDeskRule = deskId;
    const desk = deskList().find((d) => d.id === deskId);
    ruleDraft = { ...(desk ? desk.rules[key] : settings[hub()].rules[key]) };
    if (["urgent", "regular", "open"].includes(key))
      ruleDraft.rgb = (desk || deskList()[0])?.rgb || "8FA3B0";
    ruleSlot = "rgb";
    $("rule-title").textContent =
      ruleName(key) + (desk ? ` · ${desk.short}` : "");
    $("threshold-list").replaceChildren();
    for (const d of deskList()) {
      const label = make("label", "threshold-row", `${d.short} Dringend nach `),
        input = make("input");
      input.type = "number";
      input.min = "1";
      input.max = "48";
      input.value = settings[hub()].thresholds[d.id];
      input.setAttribute("aria-label", `${d.short} Dringend nach Stunden`);
      input.dataset.thresholdDesk = d.id;
      label.append(input, document.createTextNode(" h Warten"));
      $("threshold-list").append(label);
    }
    renderRuleEditor();
    $("rule-sheet").showModal();
    $("rule-cancel").focus();
  }
  document
    .querySelectorAll("[data-rule]")
    .forEach((b) =>
      b.addEventListener("click", () => openRule(b.dataset.rule)),
    );
  document.querySelectorAll("[data-rule-mode]").forEach((b) =>
    b.addEventListener("click", () => {
      ruleDraft.mode = b.dataset.ruleMode;
      ruleSlot = "rgb";
      renderRuleEditor();
    }),
  );
  document.querySelectorAll("[data-rule-slot]").forEach((b) =>
    b.addEventListener("click", () => {
      ruleSlot = b.dataset.ruleSlot;
      renderRuleEditor();
    }),
  );
  document.querySelectorAll("[data-rule-color]").forEach((b) =>
    b.addEventListener("click", () => {
      ruleDraft[ruleSlot] = b.dataset.ruleColor;
      renderRuleEditor();
    }),
  );
  document.querySelectorAll("[data-rule-place]").forEach((b) =>
    b.addEventListener("click", () => {
      if (!nonBlack(placesFor()[b.dataset.rulePlace]?.rgb)) return;
      ruleDraft[ruleSlot] = placesFor()[b.dataset.rulePlace].rgb;
      renderRuleEditor();
    }),
  );
  $("rule-color").addEventListener("input", () => {
    const rgb = $("rule-color").value.slice(1).toUpperCase();
    if (!nonBlack(rgb)) {
      renderRuleEditor();
      $("rule-warning").textContent = "Bitte eine Farbe außer Schwarz wählen.";
      return;
    }
    ruleDraft[ruleSlot] = rgb;
    renderRuleEditor();
  });
  $("rule-bri").addEventListener("input", () => {
    ruleDraft.bri = Number($("rule-bri").value);
    renderRuleEditor();
  });
  $("rule-takt").addEventListener("input", () => {
    ruleDraft.takt = Number($("rule-takt").value);
    renderRuleEditor();
  });
  $("rule-cancel").addEventListener("click", () => $("rule-sheet").close());
  function ruleColorsReady() {
    if (ruleDraft.bri > 0 && ![ruleDraft.rgb, ruleDraft.rgb2].every(nonBlack)) {
      $("rule-warning").textContent =
        "Bei Helligkeit über 0 % darf keine der beiden Farben Schwarz sein.";
      return false;
    }
    return true;
  }
  $("rule-save").addEventListener("click", () => {
    if (!ruleColorsReady()) return;
    $("rule-sheet").close();
    saveConfig(
      {
        rule: editingRule,
        ...ruleDraft,
        ...(editingDeskRule ? { desk: editingDeskRule } : {}),
        ...Object.fromEntries(
          [...$("threshold-list").querySelectorAll("input")].map((input) => [
            "threshold_" + input.dataset.thresholdDesk,
            input.value,
          ]),
        ),
      },
      "Signal-Regel speichern",
    );
  });
  $("rule-test").addEventListener("click", () => {
    if (!ruleColorsReady()) return;
    $("rule-sheet").close();
    command(
      "/signal-test",
      {
        hub: hub(),
        rule: editingRule,
        ...ruleDraft,
        ...(editingDeskRule ? { desk: editingDeskRule } : {}),
      },
      "Signal testen (10 s)",
    );
  });
  // The native input keeps keyboard steps. Pointer hit-testing covers the
  // entire row, including the end icons and value, with a 40 px thumb.
  document.querySelectorAll("[data-slider-row]").forEach((row) => {
    const input = row.querySelector('input[type="range"]');
    let active = false;
    const move = (event) => {
      if (!active || sending || input.disabled) return;
      const box = input.getBoundingClientRect(),
        low = Number(input.min),
        high = Number(input.max),
        step = Number(input.step) || 1;
      const ratio = Math.max(
        0,
        Math.min(
          1,
          (event.clientX - box.left - 20) / Math.max(1, box.width - 40),
        ),
      );
      input.value = String(
        Math.max(
          low,
          Math.min(
            high,
            low + Math.round((ratio * (high - low)) / step) * step,
          ),
        ),
      );
      input.dispatchEvent(new Event("input", { bubbles: true }));
    };
    row.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || input.disabled || sending) return;
      event.preventDefault();
      active = true;
      row.setPointerCapture?.(event.pointerId);
      move(event);
    });
    row.addEventListener("pointermove", move);
    const end = (event) => {
      if (!active) return;
      if (event.type !== "pointercancel") move(event);
      active = false;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    };
    row.addEventListener("pointerup", end);
    row.addEventListener("pointercancel", end);
  });
  renderDuration();

  function renderMode() {
    const kind = root.dataset.mode === "kind";
    $("mode").setAttribute(
      "aria-label",
      kind
        ? "Ansicht: Kind · zum Wechseln 1 Sekunde gedrückt halten"
        : "Ansicht: Erwachsen · zu Kind wechseln",
    );
    clearTimeout(modeHintTimer);
    $("mode-hint").textContent = "";
    if (kind) {
      $("alarm-list").hidden = true;
      $("loud-toggle").setAttribute("aria-expanded", "false");
      for (const id of [
        "desk-sheet",
        "history-sheet",
        "rule-sheet",
        "loud-sheet",
      ])
        $(id).close();
      $("desk-key").value = "";
      restoreOverflow();
    }
  }
  function render() {
    const s = state(),
      saved = presetFor() || DEFAULT_NIGHTLIGHT;
    document.querySelectorAll("[data-hub]").forEach((b) => {
      b.setAttribute("aria-checked", String(b.dataset.hub === selected));
      b.tabIndex = b.dataset.hub === selected ? 0 : -1;
    });
    $("nightlight")
      .closest(".hero")
      .style.setProperty("--nl-c", "#" + saved.rgb);
    $("nightlight")
      .querySelectorAll(".nl-v")
      .forEach((e) => (e.textContent = percent(saved.bri)));
    $("nightlight")
      .querySelector(".dot")
      .style.setProperty("--c", "#" + saved.rgb);
    $("nightlight").setAttribute(
      "aria-pressed",
      String(Boolean(s.last && sameLight(s, saved))),
    );
    $("off").setAttribute(
      "aria-pressed",
      String(Boolean(s.last && s.bri === 0)),
    );
    document
      .querySelectorAll("[data-preset]")
      .forEach((b) =>
        b.setAttribute(
          "aria-pressed",
          String(
            Boolean(s.last && sameLight(s, placesFor()[b.dataset.preset])),
          ),
        ),
      );
    document
      .querySelectorAll("[data-color]")
      .forEach((b) =>
        b.setAttribute(
          "aria-pressed",
          String(Boolean(s.last && s.rgb === b.dataset.color)),
        ),
      );
    $("col").value = "#" + s.rgb.toLowerCase();
    const own = ![...document.querySelectorAll("[data-color]")].some(
      (b) => b.dataset.color === s.rgb,
    );
    $("own-color").setAttribute(
      "aria-pressed",
      String(Boolean(s.last && own && s.colorName !== "Nachtlicht")),
    );
    $("own-color")
      .querySelectorAll(".c, .drop")
      .forEach((e) => e.style.setProperty("--c", "#" + s.rgb));
    $("own-color").querySelector(".c").classList.remove("empty");
    const drop = $("own-color").querySelector(".d-empty");
    if (drop) drop.setAttribute("class", "d-fill");
    $("last-light").textContent = s.last
      ? `Zuletzt: ${s.last.label} · ${percent(s.last.bri)}`
      : "Zuletzt: noch kein Befehl";
    const rb = s.readback;
    $("readback").textContent = rb
      ? `Hub meldet ≈ ${percent(rb.brightness)} · Raum: ${rb.illumination} lx`
      : "Hub meldet ≈ — · Raum: — lx · Lesen";
    $("readback").title = rb
      ? `≈ #${rb.rgb} · Rücklesen hinkt oft hinterher. Zum Aktualisieren tippen.`
      : "Status lesen";
    $("save-nightlight").hidden =
      root.dataset.mode !== "erwachsen" || !presetsReady || !s.lightReady;
    document
      .querySelectorAll("[data-t]")
      .forEach((b) =>
        b.setAttribute("aria-pressed", String(s.tone === b.dataset.t)),
      );
    $("stop").classList.toggle("on", s.tone !== null);
    $("undo").hidden =
      statusAction !== "undo" ||
      serverRejected ||
      !undoCommand ||
      undoCommand.label !== selected ||
      root.dataset.mode !== "erwachsen";
    const readIcon = document.querySelector(".hubsays .hspic use");
    readIcon.setAttribute(
      "href",
      selected === "KI-18FB" ? "#p-teddy" : "#p-sofa",
    );
    updateSliders();
    renderPlaces();
    renderDesk();
    if (sending) disableControls();
  }
  function selectHub(label) {
    if (!Object.hasOwn(HUB_HANDLES, label) || selected === label) return;
    restoreOverflow();
    for (const id of [
      "desk-sheet",
      "rule-sheet",
      "history-sheet",
      "loud-sheet",
      "doorbell-sheet",
    ])
      $(id).close();
    $("desk-key").value = "";
    selected = label;
    audioDirty = false;
    remember("nightlight-hub", selected);
    ++sequence;
    retryCommand = null;
    $("save-sheet").close();
    if (serverRejected) rejectServer();
    else status("", `Bereit · ${selected}`);
    render();
    if (usageFor() === "desk") loadSignal();
    else refreshReadback();
  }
  document.querySelectorAll("[data-hub]").forEach((button) => {
    button.addEventListener("click", () => selectHub(button.dataset.hub));
    button.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
        return;
      event.preventDefault();
      const label =
        event.key === "Home"
          ? "KI-18FB"
          : event.key === "End"
            ? "WZ-594F"
            : selected === "KI-18FB"
              ? "WZ-594F"
              : "KI-18FB";
      selectHub(label);
      document.querySelector(`[data-hub="${label}"]`).focus();
    });
  });
  function holdToActivate(button, needsHold, activate, hint, endHint) {
    let timer = null,
      done = false,
      active = false;
    const cancel = () => {
      clearTimeout(timer);
      timer = null;
      active = false;
      button.classList.remove("holding");
      endHint?.();
    };
    const start = () => {
      if (sending || active || !needsHold()) return;
      active = true;
      done = false;
      button.classList.add("holding");
      hint?.(true);
      timer = setTimeout(() => {
        timer = null;
        if (sending) {
          cancel();
          return;
        }
        done = true;
        button.classList.remove("holding");
        endHint?.();
        activate();
      }, 1000);
    };
    button.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      if (needsHold()) {
        button.setPointerCapture?.(event.pointerId);
        start();
      }
    });
    button.addEventListener("pointerup", cancel);
    button.addEventListener("pointercancel", () => {
      cancel();
      done = false;
    });
    button.addEventListener("pointerleave", cancel);
    button.addEventListener("blur", cancel);
    button.addEventListener("contextmenu", (event) => event.preventDefault());
    button.addEventListener("keydown", (event) => {
      if (![" ", "Enter"].includes(event.key) || event.repeat) return;
      if (needsHold()) {
        event.preventDefault();
        start();
      }
    });
    button.addEventListener("keyup", (event) => {
      if (![" ", "Enter"].includes(event.key)) return;
      if (active || done) {
        event.preventDefault();
        cancel();
        done = false;
      }
    });
    button.addEventListener("click", () => {
      if (done) {
        done = false;
        return;
      }
      if (needsHold()) {
        hint?.(false);
        return;
      }
      activate();
    });
  }
  holdToActivate(
    $("mode"),
    () => root.dataset.mode === "kind",
    () => {
      root.dataset.mode = root.dataset.mode === "kind" ? "erwachsen" : "kind";
      remember("nightlight-mode", root.dataset.mode);
      renderMode();
      render();
    },
    (holding) => {
      clearTimeout(modeHintTimer);
      $("mode-hint").textContent = "Zum Wechseln 1 Sekunde gedrückt halten";
      if (!holding)
        modeHintTimer = setTimeout(() => {
          $("mode-hint").textContent = "";
        }, 2500);
    },
    () => {
      $("mode-hint").textContent = "";
    },
  );
  $("theme").addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    remember("nightlight-theme", root.dataset.theme);
  });
  holdToActivate(
    $("loud-toggle"),
    () => root.dataset.mode === "kind" && $("alarm-list").hidden,
    () => {
      const open = $("alarm-list").hidden;
      $("alarm-list").hidden = !open;
      $("loud-toggle").setAttribute("aria-expanded", String(open));
      $("loud-toggle")
        .querySelector(".lk use")
        .setAttribute("href", open ? "#i-unlock" : "#i-lock");
      if (open) $("loud-sheet").showModal();
      else $("loud-sheet").close();
    },
    () => ($("loud-hint").textContent = "Zum Öffnen 1 Sekunde gedrückt halten"),
  );
  document.querySelectorAll("[data-disclosure]").forEach((button) =>
    button.addEventListener("click", () => {
      const list = $(button.dataset.disclosure);
      if (
        button.dataset.disclosure === "tones-group-2" &&
        root.dataset.mode === "kind" &&
        phone.matches
      ) {
        $("doorbell-sheet-body").append(list);
        list.hidden = false;
        $("doorbell-sheet").showModal();
        return;
      }
      list.hidden = !list.hidden;
      button.setAttribute("aria-expanded", String(!list.hidden));
    }),
  );
  function brightnessInput() {
    if (sending) return;
    state().lightTouched = state().lightReady = true;
    state().bri = Number($("bri").value);
    state().rgb = lightColor(state().rgb);
    updateSliders();
    queueLight("bri");
  }
  $("bri").addEventListener("input", brightnessInput);
  $("bri").addEventListener("change", brightnessInput);
  $("vol").addEventListener("input", () => {
    updateSliders();
    if (state().tone !== null) queueTone();
  });
  $("vol").addEventListener("change", () => {
    updateSliders();
    if (state().tone !== null) queueTone();
  });
  $("nightlight").addEventListener("click", applyNightlight);
  $("goodnight").addEventListener("click", applyNightlight);
  $("off").addEventListener("click", () => {
    state().lightTouched = state().lightReady = true;
    state().bri = 0;
    render();
    sendLight("Aus");
  });
  document.querySelectorAll("[data-preset]").forEach((button) =>
    button.addEventListener("click", () => {
      applyNightlight(button.dataset.preset);
    }),
  );
  document.querySelectorAll("[data-color]").forEach((button) =>
    button.addEventListener("click", () => {
      Object.assign(state(), {
        rgb: button.dataset.color,
        colorName: button.dataset.colorName,
      });
      state().lightTouched = state().lightReady = true;
      render();
      sendLight();
    }),
  );
  $("own-color").addEventListener("click", () => {
    try {
      if ($("col").showPicker) $("col").showPicker();
      else $("col").click();
    } catch (_) {
      $("col").click();
    }
  });
  function ownColorInput() {
    if (sending) return;
    state().lightTouched = state().lightReady = true;
    state().rgb = lightColor($("col").value.slice(1).toUpperCase());
    state().colorName = colorName(state().rgb);
    updateSliders();
    queueLight("col");
  }
  $("col").addEventListener("input", ownColorInput);
  $("col").addEventListener("change", ownColorInput);
  document.querySelectorAll("[data-t]").forEach((button) =>
    button.addEventListener("click", () =>
      command(
        "/tone",
        {
          hub: hub(),
          id: button.dataset.t,
          vol: $("vol").value,
          ...(durationMode === "short" ? { ms: $("duration").value } : {}),
        },
        button.title,
        {
          success: (_, target, mine) =>
            acceptTone(target, button.dataset.t, mine),
        },
      ),
    ),
  );
  $("stop").addEventListener("click", () =>
    command("/stop", { hub: hub() }, "Stopp", {
      success: (_, target, mine) => acceptTone(target, null, mine),
    }),
  );
  $("loud-stop").addEventListener("click", () => $("stop").click());
  $("loud-sheet").addEventListener("close", () => {
    $("alarm-list").hidden = true;
    $("loud-toggle").setAttribute("aria-expanded", "false");
  });
  $("doorbell-sheet").addEventListener("close", () => {
    $("doorbell-toggle").closest(".grp").append($("tones-group-2"));
    $("tones-group-2").hidden = false;
  });
  $("readback").addEventListener("click", () =>
    command("/get", { hub: hub() }, "Status lesen", {
      success: acceptReadback,
    }),
  );
  $("retry").addEventListener("click", () => {
    if (retryCommand) {
      const c = retryCommand;
      command(c.path, c.params, c.label, c.options);
    }
  });
  $("reload").addEventListener("click", () => location.reload());
  $("save-nightlight").addEventListener("click", () => {
    if (
      root.dataset.mode !== "erwachsen" ||
      !presetsReady ||
      !state().lightReady
    )
      return;
    sheetSnapshot = {
      label: selected,
      id: "nacht",
      old: validPreset(presetFor()) ? { ...presetFor() } : null,
      next: { rgb: state().rgb, bri: state().bri },
    };
    editingPlaces = false;
    renderSavePlaces();
    selectSavePlace("nacht");
    $("save-sheet").showModal();
    $("cancel-save").focus();
  });
  $("cancel-save").addEventListener("click", () => $("save-sheet").close());
  function persistPreset(snapshot, reset = false, undo = false) {
    if (
      !snapshot ||
      !Object.hasOwn(HUB_HANDLES, snapshot.label) ||
      (!reset && !validPreset(snapshot.next))
    )
      return;
    const target = snapshot.label;
    const params = {
      hub: HUB_HANDLES[target],
      id: snapshot.id || "nacht",
      ...snapshot.next,
    };
    if (reset) {
      delete params.rgb;
      delete params.bri;
      params.reset = 1;
    }
    ++presetRevision;
    return command(
      "/preset",
      params,
      undo ? "Platz wiederherstellen" : "Platz speichern",
      {
        target,
        success: (result, target, mine) => {
          cachePreset(target, result.presets[HUB_HANDLES[target]] || {}, mine);
        },
        message: `${placesFor(target)[snapshot.id || "nacht"]?.name || "Nachtlicht"} ${undo ? "wiederhergestellt" : "gespeichert"} · ${target}`,
        undo:
          undo || !validPreset(snapshot.old)
            ? null
            : {
                label: target,
                id: snapshot.id || "nacht",
                next: snapshot.old,
              },
        clearUndo: undo || !validPreset(snapshot.old),
      },
    );
  }
  $("confirm-save").addEventListener("click", () => {
    $("save-sheet").close();
    if (sheetSnapshot) persistPreset(sheetSnapshot);
  });
  $("reset-preset").addEventListener("click", () => {
    $("save-sheet").close();
    if (sheetSnapshot) persistPreset(sheetSnapshot, true);
  });
  $("undo").addEventListener("click", () => {
    if (undoCommand && root.dataset.mode === "erwachsen")
      persistPreset(undoCommand, false, true);
  });
  async function loadPresets() {
    const revision = presetRevision,
      mine = sequence;
    try {
      const result = await request("/presets");
      if (revision !== presetRevision) return;
      if (!result.ok) {
        const error = new Error("presets");
        error.userMessage = result.error;
        throw error;
      }
      cacheAllPresets(result, mine);
      render();
    } catch (error) {
      if (error.rejected) {
        rejectServer();
        return;
      }
      if (mine !== sequence || serverRejected) return;
      retryCommand = {
        path: "/presets",
        params: {},
        label: "Nachtlicht laden",
        options: {
          success: (result, _, mine) => {
            cacheAllPresets(result, mine);
            refreshReadback();
          },
        },
      };
      status(
        "bad",
        error.userMessage || "Keine Verbindung zum Nachtlicht-Server",
        "retry",
      );
    }
  }
  renderMode();
  status("", `Bereit · ${selected}`);
  render();
  loadPresets();
  loadConfig();
  refreshReadback();
  function refreshSignalLater() {
    setTimeout(async () => {
      if (
        usageFor() === "desk" &&
        !sending &&
        !deskBusy &&
        root.dataset.mode === "erwachsen"
      )
        await loadSignal();
      refreshSignalLater();
    }, 30000);
  }
  refreshSignalLater();
  // OPS-496: block pinch zoom (iOS ignores user-scalable=no).
  ["gesturestart", "gesturechange"].forEach((t) =>
    document.addEventListener(t, (event) => event.preventDefault(), {
      passive: false,
    }),
  );
};
