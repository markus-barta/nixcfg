(function () {
  "use strict";

  function isCanonicalJoeHost(hostname) {
    var host = String(hostname || "").toLowerCase();
    if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") {
      host = host.slice(1, -1);
    }
    if (
      host === "cs0.barta.cm" || host === "cs0" ||
      host === "hsb1.lan" || host === "hsb1" ||
      host === "localhost" || host === "127.0.0.1" || host === "::1"
    ) {
      return true;
    }
    var parts = host.split(".");
    if (parts.length === 4) {
      var octets = [];
      var i;
      var valid = true;
      for (i = 0; i < 4; i += 1) {
        if (!/^(0|[1-9]\d{0,2})$/.test(parts[i])) {
          valid = false;
          break;
        }
        var n = Number(parts[i]);
        if (n > 255) {
          valid = false;
          break;
        }
        octets.push(n);
      }
      if (valid && octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) {
        return true;
      }
    }
    return host.slice(-7) === ".ts.net" && host.indexOf("hsb1") !== -1;
  }

  var LAYOUT_KEY = "joe-board-layout-v1";
  var DESK_IDS = ["j", "joe", "joel"];
  var DEFAULT_LAYOUT = [
    { id: "hero", x: 0, y: 0, w: 12, h: 2 },
    { id: "desk-j", x: 0, y: 2, w: 4, h: 4 },
    { id: "desk-joe", x: 4, y: 2, w: 4, h: 4 },
    { id: "desk-joel", x: 8, y: 2, w: 4, h: 4 },
    { id: "attribution", x: 0, y: 6, w: 4, h: 3 },
    { id: "history", x: 4, y: 6, w: 8, h: 5 },
    { id: "positions", x: 0, y: 11, w: 12, h: 5 }
  ];
  var COLORS = { j: "#a9c99a", joe: "#96b6c9", joel: "#d4bd7a" };
  var stateCopy = { working: "Working", "sit-out": "Sitting out", stuck: "Stuck" };
  var money = new Intl.NumberFormat("de-AT", { style: "currency", currency: "EUR", minimumFractionDigits: 2 });
  var number = new Intl.NumberFormat("de-AT", { maximumFractionDigits: 4 });
  var dateTime = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "medium", timeZone: "Europe/Vienna" });
  var shortTime = new Intl.DateTimeFormat("de-AT", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", timeZone: "Europe/Vienna" });
  var grid = null;
  var restoringLayout = false;
  var latestSnapshot = null;
  var positionFilter = "all";
  var historyState = { selected: ["j", "joe"], range: "all", points: [], chart: null };

  var gate = document.getElementById("privateGate");
  var dashboard = document.getElementById("dashboard");
  if (!isCanonicalJoeHost(location.hostname)) {
    document.title = "Joe · Private household board";
    document.documentElement.dataset.joeView = "stub";
    gate.hidden = false;
    return;
  }
  document.documentElement.dataset.joeView = "board";
  dashboard.hidden = false;

  function required(condition, message) {
    if (!condition) { throw new Error(message); }
  }

  function finiteOrNull(value, path) {
    required(value === null || Number.isFinite(value), path + " must be a number or null");
  }

  function validate(data) {
    required(data && typeof data === "object", "data must be an object");
    required(data.schema === "inspr.joe.household.v1", "unknown schema");
    required(data.mode === "PAPER", "mode must be PAPER");
    required(data.currency === "EUR", "currency must be EUR");
    required(!Number.isNaN(Date.parse(data.generatedAt)), "generatedAt must be an ISO timestamp");
    required(data.safety && typeof data.safety === "object", "safety is required");
    required(typeof data.safety.halt === "boolean", "safety.halt must be boolean");
    required(["ok", "degraded", "down"].includes(data.safety.gateway && data.safety.gateway.status), "gateway status is invalid");
    required(Number.isFinite(data.safety.staleAfterSeconds) && data.safety.staleAfterSeconds > 0, "staleAfterSeconds is invalid");
    required(Array.isArray(data.desks) && data.desks.length === 3, "exactly three desks are required");
    required(new Set(data.desks.map(function (desk) { return desk.id; })).size === 3, "desk ids must be unique");
    data.desks.forEach(function (desk, index) {
      var path = "desks[" + index + "]";
      required(DESK_IDS.includes(desk.id), path + ".id is invalid");
      required(typeof desk.label === "string" && desk.label.length, path + ".label is required");
      required(["working", "sit-out", "stuck"].includes(desk.state), path + ".state is invalid");
      required(typeof desk.action === "string" && desk.action.length, path + ".action is required");
      required(desk.learning && typeof desk.learning.headline === "string" && typeof desk.learning.detail === "string", path + ".learning is invalid");
      required(desk.money && typeof desk.money === "object", path + ".money is required");
      ["equity", "dayPnl", "totalPnl"].forEach(function (key) { finiteOrNull(desk.money[key], path + ".money." + key); });
      if (Object.prototype.hasOwnProperty.call(desk.money, "openPnl")) { finiteOrNull(desk.money.openPnl, path + ".money.openPnl"); }
      required(Array.isArray(desk.issues), path + ".issues must be an array");
    });
    required(data.totals && typeof data.totals === "object", "totals are required");
    ["equity", "dayPnl", "totalPnl"].forEach(function (key) { finiteOrNull(data.totals[key], "totals." + key); });
    if (Object.prototype.hasOwnProperty.call(data.totals, "openPnl")) { finiteOrNull(data.totals.openPnl, "totals.openPnl"); }
    return data;
  }

  function amount(value, signed) {
    if (!Number.isFinite(value)) { return "—"; }
    var formatted = money.format(Math.abs(value));
    if (!signed || value === 0) { return value < 0 ? "−" + formatted : formatted; }
    return (value > 0 ? "+" : "−") + formatted;
  }

  function tone(value) {
    if (!Number.isFinite(value) || value === 0) { return "neutral"; }
    return value > 0 ? "positive" : "negative";
  }

  function setMoney(node, value, signed) {
    node.textContent = amount(value, signed);
    node.classList.remove("positive", "negative", "neutral");
    node.classList.add(tone(value));
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (text !== undefined) { node.textContent = text; }
    return node;
  }

  function endpoint(metaName, globalName, fallback) {
    var meta = document.querySelector('meta[name="' + metaName + '"]');
    return window[globalName] || (meta && meta.content) || fallback;
  }

  function safeStoredLayout() {
    try {
      var value = JSON.parse(localStorage.getItem(LAYOUT_KEY));
      if (!Array.isArray(value)) { return null; }
      var allowed = new Set(DEFAULT_LAYOUT.map(function (item) { return item.id; }));
      var clean = value.filter(function (item) {
        return item && allowed.has(item.id) && [item.x, item.y, item.w, item.h].every(Number.isFinite) && item.w > 0 && item.h > 0;
      }).map(function (item) {
        return { id: item.id, x: Math.max(0, item.x), y: Math.max(0, item.y), w: Math.min(12, item.w), h: Math.max(2, item.h) };
      });
      return clean.length === DEFAULT_LAYOUT.length ? clean : null;
    } catch (_) {
      return null;
    }
  }

  function saveLayout() {
    if (!grid || restoringLayout) { return; }
    var saved = grid.save(false, false, undefined, 12).map(function (item) {
      return { id: item.id, x: item.x, y: item.y, w: item.w, h: item.h };
    });
    try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(saved)); } catch (_) { /* private browsing may reject storage */ }
  }

  function initGrid() {
    if (!window.GridStack) {
      document.getElementById("joeGrid").classList.add("grid-fallback");
      document.getElementById("resetLayout").disabled = true;
      return;
    }
    grid = window.GridStack.init({
      column: 12,
      columnOpts: { breakpoints: [{ w: 700, c: 1 }], layout: "list" },
      cellHeight: 82,
      margin: 0,
      float: false,
      handle: ".widget-drag",
      resizable: { handles: "e,se,s,sw,w" }
    }, "#joeGrid");
    var stored = safeStoredLayout();
    if (stored) {
      restoringLayout = true;
      grid.load(stored, false);
      restoringLayout = false;
    }
    grid.on("change dragstop resizestop", saveLayout);
    grid.on("resizestop", function () { resizeVisuals(); });
    document.getElementById("resetLayout").addEventListener("click", function () {
      try { localStorage.removeItem(LAYOUT_KEY); } catch (_) { /* storage unavailable */ }
      restoringLayout = true;
      grid.load(DEFAULT_LAYOUT, false);
      restoringLayout = false;
      resizeVisuals();
    });
  }

  function ageInSeconds(iso) {
    var parsed = Date.parse(iso || "");
    return Number.isFinite(parsed) ? Math.max(0, Math.floor((Date.now() - parsed) / 1000)) : null;
  }

  function ageLabel(seconds) {
    if (!Number.isFinite(seconds)) { return "unknown"; }
    if (seconds < 60) { return seconds + "s"; }
    if (seconds < 3600) { return Math.floor(seconds / 60) + "m"; }
    return Math.floor(seconds / 3600) + "h";
  }

  function setSignal(id, valueId, value, signalTone) {
    document.getElementById(id).dataset.tone = signalTone;
    document.getElementById(valueId).textContent = value;
  }

  function openPnl(data) {
    if (Number.isFinite(data.totals.openPnl)) { return data.totals.openPnl; }
    var positions = collectPositions(data);
    if (positions.length && positions.every(function (position) { return Number.isFinite(position.openPnl); })) {
      return positions.reduce(function (sum, position) { return sum + position.openPnl; }, 0);
    }
    var deskValues = data.desks.map(function (desk) { return desk.money.openPnl; });
    return deskValues.every(Number.isFinite) ? deskValues.reduce(function (sum, value) { return sum + value; }, 0) : null;
  }

  function renderDesk(desk, snapshotAge, snapshotStale, gatewayDown) {
    var slot = document.querySelector('[data-desk-slot="' + desk.id + '"]');
    var content = el("div", "desk-content");
    var top = el("div", "desk-top");
    top.appendChild(el("h2", "desk-name", desk.label));
    top.appendChild(el("span", "state state-" + desk.state, stateCopy[desk.state]));
    content.appendChild(top);
    content.appendChild(el("p", "desk-now", desk.action));

    var moneyRow = el("div", "desk-money-row");
    [["Net", desk.money.equity, false], ["Day", desk.money.dayPnl, true], ["Open", desk.money.openPnl, true], ["Trades", Number.isFinite(desk.tradeCount) ? desk.tradeCount : null, false]].forEach(function (item, index) {
      var cell = el("div", "desk-money-cell");
      cell.appendChild(el("span", "label", item[0]));
      var value = el("strong");
      if (index === 3) { value.textContent = Number.isFinite(item[1]) ? number.format(item[1]) : "—"; }
      else { setMoney(value, item[1], item[2]); }
      cell.appendChild(value);
      moneyRow.appendChild(cell);
    });
    content.appendChild(moneyRow);
    var spark = el("div", "spark-wrap");
    var canvas = el("canvas");
    canvas.dataset.spark = desk.id;
    canvas.setAttribute("aria-label", desk.label + " recent equity sparkline");
    spark.appendChild(canvas);
    content.appendChild(spark);

    var learning = el("div", "learning");
    var learningLabel = "Learning · " + desk.learning.status + (desk.learning.iteration === null ? "" : " · pass " + desk.learning.iteration);
    learning.appendChild(el("span", "label", learningLabel));
    learning.appendChild(el("strong", "", desk.learning.headline));
    learning.appendChild(el("p", "", desk.learning.detail));
    content.appendChild(learning);
    if (desk.issues.length) { content.appendChild(el("p", "issues negative", desk.issues.join(" · "))); }

    var footer = el("div", "desk-footer");
    var heartbeatIso = desk.heartbeatAt || desk.updatedAt || null;
    var heartbeatAge = heartbeatIso ? ageInSeconds(heartbeatIso) : snapshotAge;
    var offline = gatewayDown || (heartbeatIso && heartbeatAge > latestSnapshot.safety.staleAfterSeconds);
    var stale = !offline && snapshotStale;
    var heartbeat = el("span", "desk-heartbeat" + (offline ? " offline" : stale ? " stale" : ""), (heartbeatIso ? "Heartbeat " : "Snapshot ") + ageLabel(heartbeatAge) + " ago");
    footer.appendChild(heartbeat);
    if (offline || stale) { footer.appendChild(el("span", "status-badge " + (offline ? "offline" : "stale"), offline ? "Offline" : "Stale")); }
    content.appendChild(footer);
    slot.replaceChildren(content);
  }

  function renderAttribution(desks) {
    var root = document.getElementById("attribution");
    var denominator = desks.reduce(function (sum, desk) { return sum + Math.abs(Number.isFinite(desk.money.dayPnl) ? desk.money.dayPnl : 0); }, 0);
    root.replaceChildren.apply(root, desks.map(function (desk) {
      var pnl = Number.isFinite(desk.money.dayPnl) ? desk.money.dayPnl : 0;
      var percent = denominator ? Math.abs(pnl) / denominator * 100 : 0;
      var row = el("div", "attribution-row");
      row.appendChild(el("strong", "", desk.label));
      var track = el("div", "attribution-track");
      var fill = el("div", "attribution-fill " + tone(pnl));
      fill.style.width = percent + "%";
      track.appendChild(fill);
      row.appendChild(track);
      row.appendChild(el("span", "attribution-value " + tone(pnl), Math.round(percent) + "%"));
      return row;
    }));
  }

  function collectPositions(data) {
    var result = Array.isArray(data.positions) ? data.positions.slice() : [];
    data.desks.forEach(function (desk) {
      if (Array.isArray(desk.positions)) {
        desk.positions.forEach(function (position) { result.push(Object.assign({ desk: desk.id }, position)); });
      }
    });
    return result.map(function (position) {
      return Object.assign({}, position, { desk: position.desk || position.deskId || "?" });
    }).sort(function (a, b) { return String(a.desk).localeCompare(String(b.desk)) || String(a.symbol || "").localeCompare(String(b.symbol || "")); });
  }

  function cell(text, className) {
    return el("td", className || "", text);
  }

  function renderPositions(data) {
    var all = collectPositions(data);
    var positions = positionFilter === "all" ? all : all.filter(function (position) { return position.desk === positionFilter; });
    var body = document.getElementById("positionsBody");
    document.getElementById("positionsSummary").textContent = all.length ? all.length + " open position" + (all.length === 1 ? "" : "s") + " · grouped by desk" : "Snapshot totals are live · position fields not supplied yet";
    if (!positions.length) {
      var row = el("tr");
      row.appendChild(cell(all.length ? "No positions for this desk." : "Position detail is not present in this snapshot. The board will populate this table when the projection adds it.", "empty-cell"));
      row.firstChild.colSpan = 9;
      body.replaceChildren(row);
      return;
    }
    body.replaceChildren.apply(body, positions.map(function (position) {
      var row = el("tr");
      row.dataset.desk = position.desk;
      var quantity = Number.isFinite(position.quantity) ? position.quantity : position.qty;
      var marketValue = Number.isFinite(position.marketValue) ? position.marketValue : (Number.isFinite(quantity) && Number.isFinite(position.mark) ? quantity * position.mark : null);
      row.appendChild(cell(String(position.desk).toUpperCase()));
      row.appendChild(cell(position.symbol || "—"));
      row.appendChild(cell(position.side || (Number.isFinite(quantity) && quantity < 0 ? "Short" : Number.isFinite(quantity) ? "Long" : "—")));
      row.appendChild(cell(Number.isFinite(quantity) ? number.format(quantity) : "—", "number"));
      row.appendChild(cell(amount(position.mark, false), "number"));
      row.appendChild(cell(amount(marketValue, false), "number"));
      row.appendChild(cell(amount(position.dayPnl, true), "number " + tone(position.dayPnl)));
      row.appendChild(cell(amount(position.openPnl, true), "number " + tone(position.openPnl)));
      row.appendChild(cell(position.updatedAt && Number.isFinite(Date.parse(position.updatedAt)) ? shortTime.format(new Date(position.updatedAt)) : "—"));
      return row;
    }));
  }

  function render(data) {
    latestSnapshot = data;
    var snapshotAge = ageInSeconds(data.generatedAt);
    var stale = snapshotAge > data.safety.staleAfterSeconds;
    var gateway = data.safety.gateway;
    var problems = [];
    if (data.safety.halt) { problems.push("HALT is on" + (data.safety.haltReason ? ": " + data.safety.haltReason : ".")); }
    if (gateway.status !== "ok") { problems.push("Gateway is " + gateway.status + (gateway.detail ? ": " + gateway.detail : ".")); }
    if (stale) { problems.push("The snapshot is stale (" + snapshotAge + " seconds old)."); }
    data.desks.forEach(function (desk) { if (desk.state === "stuck") { problems.push(desk.label + " is stuck: " + desk.action); } });

    setMoney(document.getElementById("totalEquity"), data.totals.equity, false);
    setMoney(document.getElementById("totalDay"), data.totals.dayPnl, true);
    setMoney(document.getElementById("totalOpen"), openPnl(data), true);
    var freshValue = document.getElementById("freshValue");
    freshValue.textContent = stale ? "STALE · " + ageLabel(snapshotAge) : "Fresh · " + ageLabel(snapshotAge);
    freshValue.className = stale ? "negative" : "positive";
    setSignal("gatewaySignal", "gatewayValue", gateway.status === "ok" ? "OK · connected" : gateway.status.toUpperCase(), gateway.status === "ok" ? "good" : gateway.status === "degraded" ? "warn" : "bad");
    setSignal("haltSignal", "haltValue", data.safety.halt ? "ON" : "Off", data.safety.halt ? "bad" : "good");
    var alarm = document.getElementById("alarm");
    alarm.hidden = problems.length === 0;
    document.getElementById("alarmText").textContent = problems.join(" ");
    data.desks.forEach(function (desk) { renderDesk(desk, snapshotAge, stale, gateway.status === "down"); });
    renderAttribution(data.desks);
    renderPositions(data);
    document.getElementById("updatedAt").textContent = "Snapshot " + dateTime.format(new Date(data.generatedAt)) + " · refreshes every 15 seconds";
    document.getElementById("sourceLine").textContent = "Source: " + (data.source && data.source.label ? data.source.label : "book.json projection");
    document.documentElement.dataset.joeState = problems.length ? "attention" : "ok";
    drawSparklines();
  }

  function renderFailure(error) {
    setSignal("gatewaySignal", "gatewayValue", "Unknown", "bad");
    setSignal("haltSignal", "haltValue", "Unknown", "bad");
    document.getElementById("freshValue").textContent = "NO DATA";
    document.getElementById("freshValue").className = "negative";
    var alarm = document.getElementById("alarm");
    alarm.hidden = false;
    document.getElementById("alarmText").textContent = "The local snapshot could not be read. " + error.message;
    document.getElementById("updatedAt").textContent = "data.json unavailable";
    document.getElementById("sourceLine").textContent = "Source: unavailable";
    document.documentElement.dataset.joeState = "broken";
  }

  function filterPoints(points, range) {
    if (!points.length || range === "all") { return points.slice(); }
    var last = Date.parse(points[points.length - 1].t);
    var span = range === "1d" ? 864e5 : range === "1w" ? 7 * 864e5 : 30 * 864e5;
    return points.filter(function (point) { return Date.parse(point.t) >= last - span; });
  }

  function seriesBag(point, deskId) {
    return point.desks && point.desks[deskId];
  }

  function destroyHistoryChart() {
    if (historyState.chart) { historyState.chart.destroy(); historyState.chart = null; }
  }

  function showHistoryEmpty(message) {
    destroyHistoryChart();
    var empty = document.getElementById("historyEmpty");
    empty.hidden = false;
    empty.textContent = message;
  }

  function drawHistory() {
    if (!window.Chart) { showHistoryEmpty("The local chart library could not be loaded."); return; }
    var points = filterPoints(historyState.points, historyState.range);
    var datasets = historyState.selected.map(function (deskId) {
      return {
        label: deskId === "j" ? "J" : deskId.charAt(0).toUpperCase() + deskId.slice(1),
        data: points.map(function (point) {
          var bag = seriesBag(point, deskId);
          return bag && Number.isFinite(bag.equity) ? { x: Date.parse(point.t), y: bag.equity } : null;
        }).filter(Boolean),
        borderColor: COLORS[deskId], backgroundColor: COLORS[deskId], borderWidth: 2,
        pointRadius: 0, pointHoverRadius: 4, tension: .2
      };
    }).filter(function (dataset) { return dataset.data.length; });
    if (!datasets.length) { showHistoryEmpty("History will fill as snapshots arrive."); return; }
    document.getElementById("historyEmpty").hidden = true;
    var tickFont = { family: "SFMono-Regular, Consolas, Liberation Mono, Menlo, monospace", size: 10 };
    var config = {
      type: "line",
      data: { datasets: datasets },
      options: {
        responsive: false, maintainAspectRatio: false, animation: false, parsing: false,
        interaction: { mode: "nearest", intersect: false },
        plugins: {
          legend: { display: true, labels: { color: "#aaa79d", boxWidth: 14, boxHeight: 2, font: tickFont } },
          tooltip: { backgroundColor: "rgba(41,42,38,.96)", titleColor: "#eee6d4", bodyColor: "#c9c4b7", borderColor: "#454641", borderWidth: 1, callbacks: {
            title: function (items) { return items.length ? dateTime.format(new Date(items[0].parsed.x)) : ""; },
            label: function (item) { return item.dataset.label + "  " + amount(item.parsed.y, false); }
          } },
          zoom: {
            limits: { x: { minRange: 60 * 1000 } },
            pan: { enabled: true, mode: "x", modifierKey: "shift" },
            zoom: { wheel: { enabled: true }, pinch: { enabled: true }, mode: "x" }
          }
        },
        scales: {
          x: { type: "linear", ticks: { color: "#77766f", maxTicksLimit: 7, font: tickFont, callback: function (value) { return shortTime.format(new Date(value)); } }, grid: { color: "rgba(63,64,59,.45)" } },
          y: { ticks: { color: "#77766f", font: tickFont, callback: function (value) { return amount(value, false); } }, grid: { color: "rgba(63,64,59,.45)" } }
        }
      }
    };
    destroyHistoryChart();
    historyState.chart = new window.Chart(document.getElementById("historyChart").getContext("2d"), config);
    resizeVisuals();
  }

  function drawSpark(canvas, values, color) {
    var rect = canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) { return; }
    var ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(rect.width * ratio);
    canvas.height = Math.round(rect.height * ratio);
    var context = canvas.getContext("2d");
    context.scale(ratio, ratio);
    context.clearRect(0, 0, rect.width, rect.height);
    if (values.length < 2) {
      context.strokeStyle = "#4a4b44"; context.setLineDash([3, 4]); context.beginPath(); context.moveTo(0, rect.height / 2); context.lineTo(rect.width, rect.height / 2); context.stroke();
      return;
    }
    var min = Math.min.apply(Math, values); var max = Math.max.apply(Math, values); var spread = max - min || 1;
    context.strokeStyle = color; context.lineWidth = 1.7; context.setLineDash([]); context.beginPath();
    values.forEach(function (value, index) {
      var x = index / (values.length - 1) * rect.width;
      var y = 5 + (max - value) / spread * (rect.height - 10);
      if (index) { context.lineTo(x, y); } else { context.moveTo(x, y); }
    });
    context.stroke();
  }

  function drawSparklines() {
    document.querySelectorAll("canvas[data-spark]").forEach(function (canvas) {
      var id = canvas.dataset.spark;
      var values = historyState.points.slice(-40).map(function (point) { var bag = seriesBag(point, id); return bag && bag.equity; }).filter(Number.isFinite);
      drawSpark(canvas, values, COLORS[id]);
    });
  }

  function resizeVisuals() {
    window.requestAnimationFrame(function () {
      if (historyState.chart) {
        var wrap = document.querySelector(".history-canvas-wrap");
        historyState.chart.resize(Math.max(1, Math.floor(wrap.clientWidth)), Math.max(1, Math.floor(wrap.clientHeight)));
      }
      drawSparklines();
    });
  }

  function bindControls() {
    document.querySelectorAll("button[data-series]").forEach(function (button) {
      button.addEventListener("click", function () {
        var id = button.dataset.series;
        var index = historyState.selected.indexOf(id);
        if (index >= 0) {
          if (historyState.selected.length === 1) { return; }
          historyState.selected.splice(index, 1);
        } else {
          if (historyState.selected.length === 2) { historyState.selected.shift(); }
          historyState.selected.push(id);
        }
        document.querySelectorAll("button[data-series]").forEach(function (candidate) { candidate.setAttribute("aria-pressed", String(historyState.selected.includes(candidate.dataset.series))); });
        drawHistory();
      });
    });
    document.querySelectorAll("button[data-range]").forEach(function (button) {
      button.addEventListener("click", function () {
        historyState.range = button.dataset.range;
        document.querySelectorAll("button[data-range]").forEach(function (candidate) { candidate.setAttribute("aria-pressed", String(candidate === button)); });
        drawHistory();
      });
    });
    document.getElementById("resetZoom").addEventListener("click", function () { if (historyState.chart && historyState.chart.resetZoom) { historyState.chart.resetZoom(); } });
    document.querySelectorAll("button[data-position-filter]").forEach(function (button) {
      button.addEventListener("click", function () {
        positionFilter = button.dataset.positionFilter;
        document.querySelectorAll("button[data-position-filter]").forEach(function (candidate) { candidate.setAttribute("aria-pressed", String(candidate === button)); });
        if (latestSnapshot) { renderPositions(latestSnapshot); }
      });
    });
    window.addEventListener("resize", resizeVisuals);
  }

  async function refreshHistory() {
    try {
      var response = await fetch(endpoint("joe-history-endpoint", "JOE_HISTORY_URL", "./history.json"), { cache: "no-store", credentials: "same-origin" });
      if (!response.ok) { throw new Error("HTTP " + response.status); }
      var data = await response.json();
      required(data && data.schema === "inspr.joe.household.history.v1", "unknown history schema");
      historyState.points = Array.isArray(data.points) ? data.points : [];
    } catch (_) {
      historyState.points = [];
    }
    drawHistory();
    drawSparklines();
  }

  async function refresh() {
    try {
      var response = await fetch(endpoint("joe-data-endpoint", "JOE_DATA_URL", "./data.json"), { cache: "no-store", credentials: "same-origin" });
      if (!response.ok) { throw new Error("HTTP " + response.status + " for data.json"); }
      render(validate(await response.json()));
    } catch (error) {
      renderFailure(error instanceof Error ? error : new Error(String(error)));
    }
  }

  window.JoeBoard = Object.freeze({
    ingest: function (snapshot) { render(validate(snapshot)); },
    refresh: refresh,
    layoutStorageKey: LAYOUT_KEY
  });
  initGrid();
  bindControls();
  refresh();
  refreshHistory();
  window.setInterval(refresh, 15000);
  window.setInterval(refreshHistory, 30000);
}());
