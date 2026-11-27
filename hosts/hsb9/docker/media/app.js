"use strict";
const base = "/fernsehen/";
const content = document.getElementById("content");
const statusLine = document.getElementById("status");
const params = new URLSearchParams(location.search);
const inTrash = params.get("trash") === "1";
const spaceError =
  "Auf dem Gerät ist nicht genug Platz für dieses Video. Bitte die Betreuung verständigen.";
let videos = [];
let freeBytes = 0;
let reserveBytes = 0;

function unreadableResponse(status) {
  return status >= 500 && status < 600
    ? "Die Aufnahmen sind gerade nicht erreichbar. Bitte die Betreuung verständigen."
    : "Die Antwort konnte nicht gelesen werden. Bitte erneut versuchen.";
}
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function message(text, error = false) {
  statusLine.textContent = text;
  statusLine.className = error ? "error" : "";
  statusLine.setAttribute("role", error ? "alert" : "status");
  if (error) statusLine.scrollIntoView({ block: "nearest" });
}
function updateSpace(result) {
  freeBytes = result.free_bytes;
  reserveBytes = result.reserve_bytes;
  const available = Math.max(0, freeBytes - reserveBytes);
  document.getElementById("space").textContent =
    `Noch frei: ${new Intl.NumberFormat("de-DE", { maximumFractionDigits: 1 }).format(available / 1e9)} GB`;
}
function link(text, href, className = "button") {
  const node = element("a", text, className);
  node.href = href;
  return node;
}
function action(text, handler, className = "") {
  const node = element("button", text, className);
  node.type = "button";
  node.addEventListener("click", async () => {
    node.disabled = true;
    try {
      await handler();
    } catch (error) {
      message(error.message, true);
    } finally {
      node.disabled = false;
    }
  });
  return node;
}
async function request(path, method = "GET", body) {
  const headers = {};
  if (method !== "GET") headers["X-Media-Request"] = "1";
  if (body !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(base + "api/" + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (_) {
    throw new Error("Die Verbindung ist unterbrochen. Bitte erneut versuchen.");
  }
  let result;
  try {
    result = await response.json();
  } catch (_) {
    throw new Error(unreadableResponse(response.status));
  }
  if (!response.ok)
    throw new Error(
      result.error || "Das hat leider nicht geklappt. Bitte erneut versuchen.",
    );
  return result;
}
function details(video) {
  const parts = [video.channel];
  if (video.recorded) {
    const [year, month, day] = video.recorded.split("-");
    parts.push(`${day}.${month}.${year}`);
  }
  if (video.duration_min !== null) parts.push(`${video.duration_min} Minuten`);
  return element("p", parts.filter(Boolean).join(" · "), "details");
}
function editForm(video) {
  content.replaceChildren();
  content.append(element("h2", "Aufnahme bearbeiten"));
  const form = element("form");
  const title = element("input");
  title.id = "title";
  title.name = "title";
  title.value = video.title;
  title.maxLength = 200;
  title.required = true;
  const description = element("textarea");
  description.id = "description";
  description.name = "description";
  description.value = video.description;
  description.maxLength = 4000;
  const titleLabel = element("label", "Titel");
  titleLabel.htmlFor = title.id;
  const descriptionLabel = element("label", "Beschreibung");
  descriptionLabel.htmlFor = description.id;
  const save = element("button", "Speichern");
  save.type = "submit";
  const actions = element("div", undefined, "actions");
  actions.append(save, link("Abbrechen", base, "button secondary"));
  form.append(titleLabel, title, descriptionLabel, description, actions);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    save.disabled = true;
    message("Die Angaben werden gespeichert …");
    try {
      const updated = await request(
        "videos/" + encodeURIComponent(video.filename),
        "PATCH",
        { title: title.value, description: description.value },
      );
      videos = videos.map((item) =>
        item.filename === updated.filename ? updated : item,
      );
      history.replaceState(
        null,
        "",
        base + "?watch=" + encodeURIComponent(updated.filename),
      );
      showPlayer(updated);
      message("Die Angaben wurden gespeichert.");
    } catch (error) {
      message(error.message, true);
    } finally {
      save.disabled = false;
    }
  });
  content.append(form);
  title.focus();
}
async function moveVideo(video, restore) {
  if (
    !restore &&
    !window.confirm(
      `„${video.title}“ in den Papierkorb verschieben?\nSie können die Aufnahme später wiederherstellen.`,
    )
  )
    return;
  const encoded = encodeURIComponent(video.filename);
  await request(
    restore ? "restore/" + encoded : "videos/" + encoded,
    restore ? "POST" : "DELETE",
  );
  videos = videos.filter((item) => item.filename !== video.filename);
  history.replaceState(null, "", base + (inTrash ? "?trash=1" : ""));
  showList();
  message(
    restore
      ? "Die Aufnahme wurde wiederhergestellt. Sie finden sie unter Alle Aufnahmen."
      : "Die Aufnahme ist jetzt im Papierkorb.",
  );
  document.getElementById("main").focus();
}
function controls(video) {
  const actions = element("div", undefined, "actions");
  if (inTrash)
    actions.append(action("Wiederherstellen", () => moveVideo(video, true)));
  else
    actions.append(
      action(
        "Bearbeiten",
        () => {
          editForm(video);
          message("");
        },
        "secondary",
      ),
      action("Löschen", () => moveVideo(video, false), "danger"),
    );
  return actions;
}
function showList() {
  content.replaceChildren();
  content.append(element("h2", inTrash ? "Papierkorb" : "Alle Aufnahmen"));
  if (inTrash)
    content.append(
      element(
        "p",
        "Hier bleiben gelöschte Aufnahmen erhalten. Mit Wiederherstellen holen Sie eine Aufnahme zurück.",
      ),
    );
  if (!videos.length) {
    content.append(
      element(
        "p",
        inTrash
          ? "Der Papierkorb ist leer."
          : "Es sind noch keine Aufnahmen vorhanden.",
      ),
    );
    return;
  }
  const cards = element("div", undefined, "cards");
  videos.forEach((video) => {
    const card = element("article");
    const heading = element("h2");
    if (inTrash) heading.textContent = video.title;
    else
      heading.append(
        link(
          video.title,
          base + "?watch=" + encodeURIComponent(video.filename),
          "",
        ),
      );
    card.append(
      heading,
      details(video),
      element("p", video.description, "description short"),
    );
    if (!inTrash)
      card.append(
        link("Ansehen", base + "?watch=" + encodeURIComponent(video.filename)),
      );
    card.append(controls(video));
    cards.append(card);
  });
  content.append(cards);
}
function showPlayer(video) {
  content.replaceChildren();
  const player = element("section", undefined, "player");
  player.append(element("h2", video.title), details(video));
  const media = element("video");
  media.controls = true;
  media.preload = "metadata";
  media.playsInline = true;
  media.src = video.video_url;
  media.addEventListener("error", () =>
    message(
      "Diese Aufnahme kann hier nicht abgespielt werden. Bitte die Betreuung verständigen.",
      true,
    ),
  );
  player.append(
    media,
    element("p", video.description, "description"),
    controls(video),
  );
  content.append(player);
}
function uploadForm() {
  content.replaceChildren();
  content.append(
    element("h2", "Video hinzufügen"),
    element(
      "p",
      "Wählen Sie eine Videodatei aus. Lassen Sie diese Seite bis zum Ende der Übertragung geöffnet.",
    ),
  );
  const form = element("form");
  const label = element("label", "Videodatei auswählen");
  label.htmlFor = "video-file";
  const input = element("input");
  input.type = "file";
  input.id = "video-file";
  input.accept = ".mp4,.m4v,.mov";
  input.required = true;
  const progress = element("progress");
  progress.max = 100;
  progress.value = 0;
  progress.hidden = true;
  progress.setAttribute("aria-label", "Fortschritt der Übertragung");
  const progressText = element("p");
  progressText.setAttribute("aria-live", "polite");
  const submit = element("button", "Video übertragen");
  submit.type = "submit";
  form.append(label, input, progress, progressText, submit);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const file = input.files[0];
    if (!file || !/\.(mp4|m4v|mov)$/i.test(file.name)) {
      message(
        "Bitte eine Datei mit der Endung .mp4, .m4v oder .mov auswählen.",
        true,
      );
      return;
    }
    submit.disabled = true;
    input.disabled = true;
    try {
      updateSpace(await request("videos"));
      if (file.size > Math.max(0, freeBytes - reserveBytes))
        throw new Error(spaceError);
    } catch (error) {
      submit.disabled = false;
      input.disabled = false;
      message(error.message, true);
      return;
    }
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", base + "api/videos/" + encodeURIComponent(file.name));
    xhr.setRequestHeader("X-Media-Request", "1");
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    progress.hidden = false;
    message("Das Video wird übertragen …");
    const beforeLeave = (event) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", beforeLeave);
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        progress.value = Math.round((event.loaded / event.total) * 100);
        progressText.textContent = `${progress.value} % übertragen`;
        if (event.loaded === event.total)
          progressText.textContent =
            "Die Übertragung ist vollständig. Das Video wird gespeichert …";
      }
    };
    let finished = false;
    let wakeLock;
    let requestingWakeLock = false;
    const keepAwake = async () => {
      if (
        finished ||
        requestingWakeLock ||
        (wakeLock && !wakeLock.released) ||
        !navigator.wakeLock ||
        document.visibilityState !== "visible"
      )
        return;
      requestingWakeLock = true;
      try {
        const lock = await navigator.wakeLock.request("screen");
        if (finished) await lock.release();
        else wakeLock = lock;
      } catch (_) {
        // Uploads still work when screen wake locks are unavailable or denied.
      } finally {
        requestingWakeLock = false;
      }
    };
    const onVisible = () => {
      if (!wakeLock || wakeLock.released) void keepAwake();
    };
    document.addEventListener("visibilitychange", onVisible);
    const finish = () => {
      finished = true;
      submit.disabled = false;
      input.disabled = false;
      window.removeEventListener("beforeunload", beforeLeave);
      document.removeEventListener("visibilitychange", onVisible);
      if (wakeLock) void wakeLock.release().catch(() => {});
    };
    xhr.onload = () => {
      finish();
      try {
        const result = JSON.parse(xhr.responseText);
        if (xhr.status !== 201)
          throw new Error(
            result.error || "Das Video konnte nicht gespeichert werden.",
          );
        videos.push(result);
        void request("videos")
          .then(updateSpace)
          .catch(() => {});
        history.replaceState(null, "", base);
        editForm(result);
        message(
          "Das Video wurde hinzugefügt. Sie können jetzt Titel und Beschreibung ändern.",
        );
      } catch (error) {
        message(
          error instanceof SyntaxError
            ? unreadableResponse(xhr.status)
            : error.message,
          true,
        );
      }
    };
    xhr.onerror = xhr.onabort = () => {
      finish();
      message(
        "Die Übertragung wurde unterbrochen. Bitte erneut versuchen.",
        true,
      );
    };
    await keepAwake();
    try {
      xhr.send(file);
    } catch (_) {
      xhr.onerror();
    }
  });
  content.append(form);
}
async function start() {
  document
    .getElementById(
      inTrash ? "trash-link" : params.has("add") ? "add-link" : "list-link",
    )
    .setAttribute("aria-current", "page");
  try {
    const result = await request("videos" + (inTrash ? "?trash=1" : ""));
    videos = result.videos;
    updateSpace(result);
    if (params.has("add")) uploadForm();
    else if (params.has("watch") && !inTrash) {
      const video = videos.find(
        (item) => item.filename === params.get("watch"),
      );
      if (!video)
        throw new Error(
          "Diese Aufnahme wurde nicht gefunden. Bitte Alle Aufnahmen öffnen.",
        );
      showPlayer(video);
    } else showList();
    message("");
  } catch (error) {
    message(error.message, true);
    content.append(
      action("Erneut versuchen", () => {
        content.replaceChildren();
        return start();
      }),
    );
  }
}
start();
