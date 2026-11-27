"use strict";
// hsb9 Fernsehaufnahmen (OPS-729, OPS-739). Plain DOM calls only, never
// markup strings: titles and descriptions can only ever become text nodes.
// No external requests: icons are inline SVG built here, fonts are local.

const BASE = "/fernsehen/";
// Shared with HostDash on the same origin (HOSTD-80): identical semantics.
const LANG_KEY = "hostdash.lang";
const PROGRESS_KEY = "hsb9-media.progress";
const SORT_KEY = "hsb9-media.sort";
const LANGUAGES = ["de", "en"];
const LOCALES = { de: "de-AT", en: "en-GB" };
const AUTONYMS = { de: "Deutsch", en: "English" };
const SVG_NS = "http://www.w3.org/2000/svg";
const WATCHED_RATIO = 0.95;
const SAVE_INTERVAL_MS = 5000;
const RESUME_MIN_SECONDS = 10;
const PROGRESS_LIMIT = 300;
const CONTINUE_LIMIT = 3;
const THUMB_WIDTH = 960;
const THUMB_HEIGHT = 540;
const THUMB_QUALITY = 0.82;
const THUMB_TIMEOUT_MS = 20000;
const VIDEO_PATTERN = /\.(mp4|m4v|mov)$/i;
const SORTS = ["added", "title", "recorded"];
const TONES = 6;

const STRINGS = {
  de: {
    "app.title": "Fernsehaufnahmen",
    skip: "Zu den Aufnahmen springen",
    "nav.home": "Startseite",
    "nav.homeLabel": "Zurück zur Startseite",
    "lang.group": "Sprache",
    "header.count": { one: "{n} Aufnahme", other: "{n} Aufnahmen" },
    "header.free": "Noch frei: {size}",
    add: "Video hinzufügen",
    "view.label": "Ansicht",
    "view.all": "Alle",
    "view.trash": "Papierkorb",
    "search.label": "Aufnahmen durchsuchen",
    "search.placeholder": "Aufnahmen durchsuchen",
    "search.clear": "Suche löschen",
    "sort.label": "Sortieren",
    "sort.added": "Zuletzt hinzugefügt",
    "sort.title": "Titel (A–Z)",
    "sort.recorded": "Aufnahmedatum",
    "section.continue": "Weiterschauen",
    "section.all": "Alle Aufnahmen",
    "section.trash": "Papierkorb",
    "section.results": { one: "{n} Treffer", other: "{n} Treffer" },
    "trash.note":
      "Gelöschte Aufnahmen bleiben hier, bis die Betreuung den Papierkorb leert. Mit „Wiederherstellen“ holen Sie eine Aufnahme zurück.",
    "card.play": "„{title}“ ansehen",
    "card.edit": "Bearbeiten",
    "card.delete": "Löschen",
    "card.restore": "Wiederherstellen",
    "card.editLabel": "„{title}“ bearbeiten",
    "card.deleteLabel": "„{title}“ löschen",
    "card.restoreLabel": "„{title}“ wiederherstellen",
    "card.watched": "Gesehen",
    "card.left": "Noch {time}",
    "card.added": "Hinzugefügt am {date}",
    "duration.min": "{n} Min.",
    "duration.h": "{h} Std.",
    "duration.hmin": "{h} Std. {m} Min.",
    "player.label": "Wiedergabe",
    "player.close": "Schließen",
    "player.resumeNote": "Sie haben bei {time} aufgehört.",
    "player.resume": "Weiter ab {time}",
    "player.restart": "Von vorne",
    "player.error":
      "Diese Aufnahme kann hier nicht abgespielt werden. Bitte die Betreuung verständigen.",
    "player.missing": "Diese Aufnahme wurde nicht gefunden.",
    "edit.heading": "Aufnahme bearbeiten",
    "edit.headingNew": "Neues Video benennen",
    "edit.introNew":
      "Das Video ist gespeichert. Geben Sie ihm einen Titel, unter dem Sie es wiederfinden.",
    "edit.title": "Titel",
    "edit.description": "Beschreibung",
    "edit.save": "Speichern",
    "edit.cancel": "Abbrechen",
    "edit.saving": "Wird gespeichert …",
    "confirm.heading": "In den Papierkorb legen?",
    "confirm.text":
      "„{title}“ kommt in den Papierkorb. Sie können die Aufnahme dort jederzeit wiederherstellen.",
    "confirm.ok": "In den Papierkorb",
    "confirm.cancel": "Abbrechen",
    "toast.trashed": "In den Papierkorb gelegt",
    "toast.undo": "Rückgängig",
    "toast.restored": "Die Aufnahme ist wieder da.",
    "toast.restoredTrash":
      "Wiederhergestellt. Sie finden die Aufnahme jetzt unter „Alle“.",
    "toast.saved": "Die Angaben wurden gespeichert.",
    "toast.added": "Das Video wurde hinzugefügt.",
    "toast.dismiss": "Hinweis schließen",
    "upload.heading": "Video wird übertragen",
    "upload.checking": "Freier Platz wird geprüft …",
    "upload.keepOpen":
      "Bitte diese Seite geöffnet lassen, bis die Übertragung fertig ist.",
    "upload.speed": "{speed} MB/s",
    "upload.remaining": "noch etwa {time}",
    "upload.almost": "noch weniger als 1 Min.",
    "upload.saving":
      "Die Übertragung ist vollständig. Das Video wird gespeichert …",
    "upload.cancel": "Abbrechen",
    "upload.cancelLabel": "Übertragung abbrechen",
    "upload.cancelled": "Die Übertragung wurde abgebrochen.",
    "upload.interrupted":
      "Die Übertragung wurde unterbrochen. Bitte erneut versuchen.",
    "upload.wrongType":
      "Bitte eine Datei mit der Endung .mp4, .m4v oder .mov auswählen.",
    "upload.busy":
      "Es wird gerade schon ein Video übertragen. Bitte warten, bis es fertig ist.",
    "upload.failed": "Das Video konnte nicht gespeichert werden.",
    "upload.progress": "Fortschritt der Übertragung",
    "drop.title": "Video hinzufügen",
    "drop.hint": "Datei auswählen oder hierher ziehen",
    "drop.here": "Video hier ablegen",
    "empty.library": "Noch keine Aufnahmen",
    "empty.libraryText": "Fügen Sie ein Video hinzu – es erscheint dann hier.",
    "empty.trash": "Der Papierkorb ist leer.",
    "empty.trashText":
      "Gelöschte Aufnahmen erscheinen hier, bis die Betreuung sie endgültig entfernt.",
    "empty.search": "Nichts gefunden",
    "empty.searchText": "Keine Aufnahme passt zu „{query}“.",
    "load.loading": "Die Aufnahmen werden geladen …",
    "load.failed": "Die Aufnahmen konnten nicht geladen werden.",
    "load.retry": "Erneut versuchen",
    "error.generic": "Das hat leider nicht geklappt. Bitte erneut versuchen.",
    "error.network": "Die Verbindung ist unterbrochen. Bitte erneut versuchen.",
    "error.unreadable":
      "Die Antwort konnte nicht gelesen werden. Bitte erneut versuchen.",
    "error.server":
      "Die Aufnahmen sind gerade nicht erreichbar. Bitte in einem Moment erneut versuchen. Wenn es so bleibt, bitte die Betreuung verständigen.",
    "error.invalid_name":
      "Bitte eine Videodatei mit gültigem Namen wählen (.mp4, .m4v oder .mov).",
    "error.unsupported_type":
      "Bitte eine Videodatei wählen (.mp4, .m4v oder .mov).",
    "error.insufficient_space":
      "Auf dem Gerät ist nicht genug Platz für dieses Video. Bitte die Betreuung verständigen.",
    "error.metadata_unreadable":
      "Die Angaben können gerade nicht gelesen werden. Bitte die Betreuung verständigen.",
    "error.invalid_text": "Bitte Text mit höchstens {limit} Zeichen eingeben.",
    "error.not_found": "Diese Aufnahme wurde nicht gefunden.",
    "error.invalid_edit": "Bitte Titel oder Beschreibung eingeben.",
    "error.title_required": "Bitte einen Titel eingeben.",
    "error.name_conflict":
      "Eine Aufnahme mit diesem Dateinamen ist schon vorhanden. Bitte die Betreuung verständigen.",
    "error.empty_file": "Die Datei ist leer.",
    "error.transfer_interrupted":
      "Die Übertragung wurde unterbrochen. Bitte erneut versuchen.",
    "error.invalid_thumbnail": "Das Vorschaubild ist kein JPEG-Bild.",
    "error.thumbnail_too_large": "Das Vorschaubild ist zu groß.",
    "error.length_required":
      "Die Länge der Übertragung fehlt oder ist ungültig.",
    "error.too_large": "Die Eingabe ist zu lang.",
    "error.request_refused": "Bitte die Seite neu öffnen und erneut versuchen.",
    "error.page_not_found": "Diese Seite wurde nicht gefunden.",
    "error.invalid_json": "Die Eingabe konnte nicht gelesen werden.",
    "error.invalid_input": "Die Eingabe ist ungültig.",
    "error.storage_unavailable":
      "Speichern oder Lesen ist gerade nicht möglich. Bitte die Betreuung verständigen.",
  },
  en: {
    "app.title": "TV recordings",
    skip: "Skip to the recordings",
    "nav.home": "Home",
    "nav.homeLabel": "Back to the start page",
    "lang.group": "Language",
    "header.count": { one: "{n} recording", other: "{n} recordings" },
    "header.free": "Space left: {size}",
    add: "Add video",
    "view.label": "View",
    "view.all": "All",
    "view.trash": "Trash",
    "search.label": "Search recordings",
    "search.placeholder": "Search recordings",
    "search.clear": "Clear search",
    "sort.label": "Sort",
    "sort.added": "Recently added",
    "sort.title": "Title (A–Z)",
    "sort.recorded": "Recording date",
    "section.continue": "Continue watching",
    "section.all": "All recordings",
    "section.trash": "Trash",
    "section.results": { one: "{n} result", other: "{n} results" },
    "trash.note":
      "Deleted recordings stay here until your helper empties the trash. Use “Restore” to bring one back.",
    "card.play": "Watch “{title}”",
    "card.edit": "Edit",
    "card.delete": "Delete",
    "card.restore": "Restore",
    "card.editLabel": "Edit “{title}”",
    "card.deleteLabel": "Delete “{title}”",
    "card.restoreLabel": "Restore “{title}”",
    "card.watched": "Watched",
    "card.left": "{time} left",
    "card.added": "Added {date}",
    "duration.min": "{n} min",
    "duration.h": "{h} h",
    "duration.hmin": "{h} h {m} min",
    "player.label": "Player",
    "player.close": "Close",
    "player.resumeNote": "You stopped at {time}.",
    "player.resume": "Resume at {time}",
    "player.restart": "Start over",
    "player.error":
      "This recording can't be played here. Please contact your helper.",
    "player.missing": "This recording was not found.",
    "edit.heading": "Edit recording",
    "edit.headingNew": "Name the new video",
    "edit.introNew":
      "The video is saved. Give it a title you will recognise later.",
    "edit.title": "Title",
    "edit.description": "Description",
    "edit.save": "Save",
    "edit.cancel": "Cancel",
    "edit.saving": "Saving …",
    "confirm.heading": "Move to the trash?",
    "confirm.text":
      "“{title}” will be moved to the trash. You can restore it from there at any time.",
    "confirm.ok": "Move to trash",
    "confirm.cancel": "Cancel",
    "toast.trashed": "Moved to the trash",
    "toast.undo": "Undo",
    "toast.restored": "The recording is back.",
    "toast.restoredTrash": "Restored. You will find it under “All” again.",
    "toast.saved": "Your changes were saved.",
    "toast.added": "The video was added.",
    "toast.dismiss": "Dismiss",
    "upload.heading": "Uploading video",
    "upload.checking": "Checking free space …",
    "upload.keepOpen":
      "Please keep this page open until the upload has finished.",
    "upload.speed": "{speed} MB/s",
    "upload.remaining": "about {time} left",
    "upload.almost": "less than a minute left",
    "upload.saving": "Upload complete. Saving the video …",
    "upload.cancel": "Cancel",
    "upload.cancelLabel": "Cancel the upload",
    "upload.cancelled": "The upload was cancelled.",
    "upload.interrupted": "The upload was interrupted. Please try again.",
    "upload.wrongType": "Please choose a file ending in .mp4, .m4v or .mov.",
    "upload.busy":
      "A video is already uploading. Please wait until it has finished.",
    "upload.failed": "The video could not be saved.",
    "upload.progress": "Upload progress",
    "drop.title": "Add video",
    "drop.hint": "Choose a file or drag it here",
    "drop.here": "Drop the video here",
    "empty.library": "No recordings yet",
    "empty.libraryText": "Add a video and it will appear here.",
    "empty.trash": "The trash is empty.",
    "empty.trashText":
      "Deleted recordings appear here until your helper removes them for good.",
    "empty.search": "Nothing found",
    "empty.searchText": "No recording matches “{query}”.",
    "load.loading": "Loading the recordings …",
    "load.failed": "The recordings could not be loaded.",
    "load.retry": "Try again",
    "error.generic": "Sorry, that didn't work. Please try again.",
    "error.network": "The connection was lost. Please try again.",
    "error.unreadable": "The response could not be read. Please try again.",
    "error.server":
      "The recordings are not available right now. Please try again in a moment. If it stays like this, please contact your helper.",
    "error.invalid_name":
      "Please choose a video file with a valid name (.mp4, .m4v or .mov).",
    "error.unsupported_type":
      "Please choose a video file (.mp4, .m4v or .mov).",
    "error.insufficient_space":
      "There is not enough space on the device for this video. Please contact your helper.",
    "error.metadata_unreadable":
      "The details can't be read right now. Please contact your helper.",
    "error.invalid_text": "Please enter at most {limit} characters.",
    "error.not_found": "This recording was not found.",
    "error.invalid_edit": "Please enter a title or a description.",
    "error.title_required": "Please enter a title.",
    "error.name_conflict":
      "A recording with this file name already exists. Please contact your helper.",
    "error.empty_file": "The file is empty.",
    "error.transfer_interrupted":
      "The transfer was interrupted. Please try again.",
    "error.invalid_thumbnail": "The preview image is not a JPEG image.",
    "error.thumbnail_too_large": "The preview image is too large.",
    "error.length_required": "The transfer length is missing or invalid.",
    "error.too_large": "The input is too long.",
    "error.request_refused": "Please reload the page and try again.",
    "error.page_not_found": "This page was not found.",
    "error.invalid_json": "The input could not be read.",
    "error.invalid_input": "The input is invalid.",
    "error.storage_unavailable":
      "Saving or reading is not possible right now. Please contact your helper.",
  },
};

// Lucide-style 24px stroke icons as path data (circles/rects as paths).
const ICONS = {
  house: [
    "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8",
    "M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
  ],
  plus: ["M5 12h14", "M12 5v14"],
  search: ["M3 11a8 8 0 1 0 16 0a8 8 0 1 0-16 0", "m21 21-4.3-4.3"],
  x: ["M18 6 6 18", "m6 6 12 12"],
  pencil: [
    "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z",
    "m15 5 4 4",
  ],
  trash: [
    "M3 6h18",
    "M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6",
    "M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2",
    "M10 11v6",
    "M14 11v6",
  ],
  restore: [
    "M3 3h18a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z",
    "M4 8v11a2 2 0 0 0 2 2h2",
    "M20 8v11a2 2 0 0 1-2 2h-2",
    "m9 15 3-3 3 3",
    "M12 12v9",
  ],
  rotate: ["M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", "M3 3v5h5"],
  history: [
    "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8",
    "M3 3v5h5",
    "M12 7v5l4 2",
  ],
  play: [
    "M4.65 4.6v14.8a1.2 1.2 0 0 0 1.8 1.04l12.3-7.4a1.2 1.2 0 0 0 0-2.08L6.45 3.56A1.2 1.2 0 0 0 4.65 4.6z",
  ],
  tv: [
    "m17 2-5 5-5-5",
    "M4 7h16a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2z",
  ],
  check: ["M20 6 9 17l-5-5"],
  checkCircle: ["M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0", "m9 12 2 2 4-4"],
  alert: ["M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0", "M12 8v4", "M12 16h.01"],
  upload: [
    "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4",
    "m17 8-5-5-5 5",
    "M12 3v12",
  ],
  sort: ["m21 16-4 4-4-4", "M17 20V4", "m3 8 4-4 4 4", "M7 4v16"],
  chevron: ["m6 9 6 6 6-6"],
  grid: [
    "M4 3h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z",
    "M15 3h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-5a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z",
    "M15 14h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-5a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1z",
    "M4 14h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1z",
  ],
};

// Small line illustrations for empty and error states.
const ART = {
  tv: [
    ["path", "art-shadow", "M30 110h100"],
    ["rect", "art-body", 22, 28, 116, 76, 16],
    ["rect", "art-screen", 32, 38, 78, 56, 9],
    ["path", "art-line", "M64 28 50 10M96 28l14-18"],
    ["path", "art-dot", "M50 10h.01M110 10h.01"],
    ["path", "art-accent", "M63 54v20l17-10z"],
    ["path", "art-line", "M124 50h.01M124 64h.01M118 82h12"],
    ["path", "art-spark", "M146 22v10M141 27h10M14 60v8M10 64h8"],
  ],
  trash: [
    ["path", "art-shadow", "M40 110h80"],
    ["rect", "art-body", 46, 34, 68, 72, 12],
    ["path", "art-line", "M38 34h84M66 34v-8a6 6 0 0 1 6-6h16a6 6 0 0 1 6 6v8"],
    ["path", "art-line", "M68 52v36M80 52v36M92 52v36"],
    ["path", "art-spark", "M134 30v10M129 35h10M24 70v8M20 74h8"],
  ],
  search: [
    ["path", "art-shadow", "M36 110h88"],
    ["circle", "art-body", 72, 58, 34],
    ["circle", "art-screen", 72, 58, 24],
    ["path", "art-line", "m97 83 24 24"],
    [
      "path",
      "art-accent-line",
      "M62 50c2-7 9-10 15-7 7 3 7 12 0 15-3 1-5 3-5 7M72 72h.01",
    ],
    ["path", "art-spark", "M136 26v10M131 31h10"],
  ],
  alert: [
    ["path", "art-shadow", "M36 110h88"],
    ["circle", "art-body", 80, 60, 40],
    ["path", "art-accent-line", "M80 40v26M80 80h.01"],
    ["path", "art-spark", "M136 24v10M131 29h10M22 54v8M18 58h8"],
  ],
};

const state = {
  lang: "de",
  view: "all",
  videos: [],
  trash: [],
  loading: true,
  loadError: "",
  query: "",
  sort: "added",
  space: null,
  progress: {},
  playing: null,
  upload: null,
};
let ui = {};
let pushedPlayer = false;
let lastSave = 0;
let pendingSeek = null;
let confirmResolve = null;
let confirmVideo = null;
let editVideo = null;
let editFresh = false;
// Bumped by every openEdit(): a save that answers after its dialog closed or a
// newer edit opened must not touch the dialog that is showing now.
let editSession = 0;
let dragDepth = 0;

// ---------------------------------------------------------------- language

function translate(lang, key, vars = {}) {
  const table = STRINGS[lang] || STRINGS.de;
  let entry = key in table ? table[key] : STRINGS.de[key];
  if (entry === undefined) return key;
  if (typeof entry === "object") {
    const rule = new Intl.PluralRules(LOCALES[lang] || LOCALES.de).select(
      Number(vars.n) || 0,
    );
    entry = entry[rule] || entry.other;
  }
  return entry.replace(/\{(\w+)\}/g, (match, name) =>
    name in vars ? String(vars[name]) : match,
  );
}
function t(key, vars) {
  return translate(state.lang, key, vars);
}
function hasString(key) {
  return key in (STRINGS[state.lang] || {});
}
// Default: the first navigator language whose primary subtag is supported.
function browserLanguage(nav) {
  const listed =
    nav && nav.languages && nav.languages.length
      ? Array.from(nav.languages)
      : [nav && nav.language];
  for (const tag of listed) {
    const primary = String(tag || "")
      .split("-")[0]
      .toLowerCase();
    if (LANGUAGES.includes(primary)) return primary;
  }
  return "en";
}
function storedLanguage(store) {
  try {
    const value = store ? store.getItem(LANG_KEY) : null;
    return LANGUAGES.includes(value) ? value : null;
  } catch (_) {
    return null;
  }
}
function resolveLanguage(nav, store) {
  return storedLanguage(store) || browserLanguage(nav);
}
function locale() {
  return LOCALES[state.lang];
}

// -------------------------------------------------------------- formatting

function formatDecimal(value, digits) {
  return new Intl.NumberFormat(locale(), {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}
function formatSize(bytes) {
  return `${formatDecimal(Math.max(0, bytes) / 1e9, 1)} GB`;
}
function formatPercent(fraction) {
  return new Intl.NumberFormat(locale(), {
    style: "percent",
    maximumFractionDigits: 0,
  }).format(fraction);
}
function formatMinutes(minutes) {
  const total = Math.max(1, Math.round(minutes));
  if (total < 60) return t("duration.min", { n: total });
  const hours = Math.floor(total / 60);
  const rest = total % 60;
  return rest
    ? t("duration.hmin", { h: hours, m: rest })
    : t("duration.h", { h: hours });
}
function formatClock(seconds) {
  const whole = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const pad = (value) => String(value).padStart(2, "0");
  return hours
    ? `${hours}:${pad(minutes)}:${pad(whole % 60)}`
    : `${minutes}:${pad(whole % 60)}`;
}
function formatDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
  const date = match
    ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
    : new Date(value);
  if (!value || Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(locale(), {
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(date);
}
function videoMinutes(video) {
  if (Number.isFinite(video.duration_min) && video.duration_min > 0)
    return video.duration_min;
  const entry = state.progress[video.filename];
  return entry && entry.d ? entry.d / 60 : null;
}

// ---------------------------------------------------------------- progress

// { [filename]: { t, d, at, watched } }: t = seconds, d = duration seconds,
// at = epoch ms. Watched entries drop t. Anything malformed is ignored.
function readProgress(store) {
  let raw;
  try {
    raw = JSON.parse((store && store.getItem(PROGRESS_KEY)) || "{}");
  } catch (_) {
    return {};
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const result = {};
  for (const [name, item] of Object.entries(raw)) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const entry = {};
    if (Number.isFinite(item.t) && item.t >= 0) entry.t = item.t;
    if (Number.isFinite(item.d) && item.d > 0) entry.d = item.d;
    if (Number.isFinite(item.at)) entry.at = item.at;
    if (item.watched === true) entry.watched = true;
    if (entry.t !== undefined || entry.watched) result[name] = entry;
  }
  return result;
}
function nextProgress(store, name, time, duration, now, ended = false) {
  const previous = store[name] || {};
  const total =
    Number.isFinite(duration) && duration > 0 ? duration : previous.d;
  const result = { ...store };
  const entry = { at: now };
  if (total) entry.d = total;
  if (ended || (total && time / total >= WATCHED_RATIO)) entry.watched = true;
  else {
    entry.t = Math.max(0, Math.round(time * 10) / 10);
    if (previous.watched) entry.watched = true;
  }
  result[name] = entry;
  const names = Object.keys(result);
  if (names.length > PROGRESS_LIMIT) {
    names.sort((a, b) => (result[b].at || 0) - (result[a].at || 0));
    for (const old of names.slice(PROGRESS_LIMIT)) delete result[old];
  }
  return result;
}
function writeProgress(store, progress) {
  try {
    store.setItem(PROGRESS_KEY, JSON.stringify(progress));
  } catch (_) {
    // Private browsing or a full quota: resume is a convenience only.
  }
}
function progressState(video) {
  const entry = state.progress[video.filename];
  if (!entry) return { fraction: null, watched: false, seconds: 0 };
  const total = entry.d || (videoMinutes(video) || 0) * 60;
  const partial =
    entry.t !== undefined && entry.t >= RESUME_MIN_SECONDS && total > 0;
  return {
    fraction: partial ? Math.min(1, entry.t / total) : null,
    watched: Boolean(entry.watched) && !partial,
    seconds: partial ? entry.t : 0,
    left: partial ? Math.max(0, total - entry.t) : 0,
  };
}

// ------------------------------------------------------------------ errors

class ApiError extends Error {
  constructor(message, status, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
// The server sends a stable `code` plus a German `error`; prefer our
// localized text for the code and fall back to the server's message.
function problemText(result) {
  if (result && typeof result === "object") {
    const key = typeof result.code === "string" ? "error." + result.code : "";
    if (key && hasString(key))
      return t(key, { limit: result.limit === undefined ? "" : result.limit });
    if (typeof result.error === "string" && result.error) return result.error;
  }
  return t("error.generic");
}
function unreadableResponse(status) {
  return status >= 500 && status < 600
    ? t("error.server")
    : t("error.unreadable");
}
async function request(path, options = {}) {
  const method = options.method || "GET";
  const headers = {};
  let body;
  if (method !== "GET") headers["X-Media-Request"] = "1";
  if (options.raw !== undefined) {
    body = options.raw;
    headers["Content-Type"] = options.type;
  } else if (options.json !== undefined) {
    body = JSON.stringify(options.json);
    headers["Content-Type"] = "application/json";
  }
  let response;
  try {
    response = await fetch(BASE + "api/" + path, { method, headers, body });
  } catch (_) {
    throw new ApiError(t("error.network"), 0);
  }
  let result;
  try {
    result = await response.json();
  } catch (_) {
    throw new ApiError(unreadableResponse(response.status), response.status);
  }
  if (!response.ok)
    throw new ApiError(
      problemText(result),
      response.status,
      result && result.code,
    );
  return result;
}

// --------------------------------------------------------------------- DOM

function h(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (key === "hidden" || key === "disabled" || key === "value")
      node[key] = value;
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of [children].flat())
    if (child !== null && child !== undefined && child !== false)
      node.append(child);
  return node;
}
function svg(tag, attributes) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attributes))
    node.setAttribute(key, String(value));
  return node;
}
function icon(name, extra = "") {
  const node = svg("svg", {
    viewBox: "0 0 24 24",
    "aria-hidden": "true",
    focusable: "false",
    class: ("icon icon-" + name + " " + extra).trim(),
  });
  for (const d of ICONS[name]) node.append(svg("path", { d }));
  return node;
}
function art(name) {
  const node = svg("svg", {
    viewBox: "0 0 160 120",
    "aria-hidden": "true",
    focusable: "false",
    class: "art",
  });
  for (const [tag, className, ...values] of ART[name]) {
    if (tag === "path")
      node.append(svg("path", { class: className, d: values[0] }));
    else if (tag === "circle")
      node.append(
        svg("circle", {
          class: className,
          cx: values[0],
          cy: values[1],
          r: values[2],
        }),
      );
    else
      node.append(
        svg("rect", {
          class: className,
          x: values[0],
          y: values[1],
          width: values[2],
          height: values[3],
          rx: values[4],
        }),
      );
  }
  return node;
}
function button(label, iconName, className, onClick, extra = {}) {
  return h(
    "button",
    { type: "button", class: "btn " + className, onclick: onClick, ...extra },
    [
      iconName ? icon(iconName) : null,
      h("span", { class: "btn-label", text: label }),
    ],
  );
}
function iconButton(iconName, label, className, onClick) {
  return h(
    "button",
    {
      type: "button",
      class: "icon-btn " + className,
      "aria-label": label,
      title: label,
      onclick: onClick,
    },
    [icon(iconName)],
  );
}
// Run an async action once at a time; failures become a friendly toast.
function guarded(node, action) {
  return async (event) => {
    if (event && event.preventDefault) event.preventDefault();
    if (node.disabled) return;
    node.disabled = true;
    try {
      await action();
    } catch (error) {
      toast(error.message || t("error.generic"), { error: true });
    } finally {
      node.disabled = false;
    }
  };
}
function setDialogOpen(dialog) {
  // Re-opening an open dialog (e.g. switching recordings) keeps the element
  // that opened it, so focus returns there rather than into the dialog.
  if (dialog.open) return;
  dialog.returnFocus = document.activeElement || null;
  dialog.showModal();
}
// Browsers deliver a dialog's "close" event as a queued task. If the dialog
// was opened again before it arrives, the event is stale and must not tear
// down what is showing now.
function onDialogClosed(dialog, handler) {
  dialog.addEventListener("close", () => {
    if (!dialog.open) handler();
  });
}
function closeDialog(dialog) {
  if (dialog.open) dialog.close();
  const target = dialog.returnFocus;
  dialog.returnFocus = null;
  if (target && target.isConnected !== false && target.focus) target.focus();
  else if (ui.libraryTitle && ui.libraryTitle.focus) ui.libraryTitle.focus();
}

// ----------------------------------------------------------------- posters

// FNV-1a: a stable tone per title, so a recording keeps its colours.
function paletteIndex(seed) {
  let hash = 0x811c9dc5;
  for (const char of String(seed || "")) {
    hash ^= char.codePointAt(0);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash % TONES;
}
function fallbackPoster(video) {
  return h(
    "div",
    {
      class: `poster-fallback tone-${paletteIndex(video.title || video.filename)}`,
      "data-fallback": "true",
    },
    [
      icon("tv", "poster-glyph"),
      h("p", { class: "poster-fallback-title", text: video.title }),
    ],
  );
}
function poster(video, { chips = true, play = true } = {}) {
  const progress = progressState(video);
  const node = h("div", { class: "poster" });
  if (video.thumb_url) {
    const image = h("img", {
      class: "poster-image",
      src: video.thumb_url,
      alt: "",
      loading: "lazy",
      decoding: "async",
    });
    image.addEventListener("error", () => {
      image.replaceWith(fallbackPoster(video));
    });
    node.append(image);
  } else node.append(fallbackPoster(video));
  node.append(h("span", { class: "poster-shade", "aria-hidden": "true" }));
  if (chips && video.channel)
    node.append(
      h("span", { class: "chip chip-channel" }, [
        h("span", { class: "chip-text", text: video.channel }),
      ]),
    );
  const minutes = videoMinutes(video);
  if (chips && minutes)
    node.append(
      h("span", { class: "chip chip-duration", text: formatMinutes(minutes) }),
    );
  if (progress.watched && !video.trash)
    node.append(
      h("span", { class: "chip chip-watched" }, [
        icon("check"),
        h("span", { text: t("card.watched") }),
      ]),
    );
  if (play && !video.trash)
    node.append(
      h("span", { class: "poster-play", "aria-hidden": "true" }, [
        icon("play", "icon-fill"),
      ]),
    );
  if (progress.fraction !== null && !video.trash) {
    const bar = h("span", { class: "poster-progress-fill" });
    bar.style.setProperty("--p", String(progress.fraction));
    node.append(h("span", { class: "poster-progress" }, [bar]));
  }
  return node;
}

// -------------------------------------------------------------- rendering

function playHref(video) {
  return "#play=" + encodeURIComponent(video.filename);
}
function metaLine(video) {
  const parts = [];
  const minutes = videoMinutes(video);
  if (video.recorded) parts.push(formatDate(video.recorded));
  else if (video.added) {
    const date = formatDate(video.added);
    if (date) parts.push(t("card.added", { date }));
  }
  if (minutes) parts.push(formatMinutes(minutes));
  return parts.filter(Boolean).join(" · ");
}
function card(video) {
  const trashed = Boolean(video.trash);
  const article = h("article", {
    class: "card" + (trashed ? " is-trashed" : ""),
    "data-filename": video.filename,
  });
  const title = trashed
    ? h("span", { class: "card-title-text", text: video.title })
    : h(
        "a",
        {
          class: "card-link",
          href: playHref(video),
          onclick: (event) => {
            event.preventDefault();
            openPlayer(video);
          },
        },
        [h("span", { class: "card-title-text", text: video.title })],
      );
  const body = h("div", { class: "card-body" }, [
    h("h3", { class: "card-title" }, [title]),
  ]);
  const meta = metaLine(video);
  if (meta) body.append(h("p", { class: "card-meta", text: meta }));
  if (video.description)
    body.append(h("p", { class: "card-desc", text: video.description }));
  const actions = h("div", { class: "card-actions" });
  if (trashed) {
    const restore = button(
      t("card.restore"),
      "restore",
      "btn-secondary",
      null,
      {
        "aria-label": t("card.restoreLabel", { title: video.title }),
      },
    );
    restore.addEventListener(
      "click",
      guarded(restore, () => restoreVideo(video, false)),
    );
    actions.append(restore);
  } else {
    const edit = button(t("card.edit"), "pencil", "btn-ghost", () =>
      openEdit(video),
    );
    edit.setAttribute(
      "aria-label",
      t("card.editLabel", { title: video.title }),
    );
    const remove = button(
      t("card.delete"),
      "trash",
      "btn-ghost is-danger",
      null,
      {
        "aria-label": t("card.deleteLabel", { title: video.title }),
      },
    );
    remove.addEventListener(
      "click",
      guarded(remove, () => trashVideo(video)),
    );
    actions.append(edit, remove);
  }
  body.append(actions);
  article.append(h("div", { class: "card-media" }, [poster(video)]), body);
  return article;
}
function addTile() {
  const tile = h(
    "button",
    { type: "button", class: "add-tile", onclick: () => ui.fileInput.click() },
    [
      h("span", { class: "add-tile-frame" }, [
        h("span", { class: "add-tile-plus" }, [icon("plus")]),
        h("span", { class: "add-tile-title", text: t("drop.title") }),
        h("span", { class: "add-tile-hint", text: t("drop.hint") }),
      ]),
    ],
  );
  tile.disabled = Boolean(state.upload);
  dropTarget(tile);
  return tile;
}
function emptyState(artName, title, text, actions = [], extra = {}) {
  return h(
    "div",
    { class: "empty" + (extra.className ? " " + extra.className : "") },
    [
      art(artName),
      h("h3", { class: "empty-title", text: title }),
      text
        ? h("p", { class: "empty-text", id: extra.id, role: extra.role, text })
        : null,
      actions.length ? h("div", { class: "empty-actions" }, actions) : null,
    ],
  );
}
function skeleton() {
  const grid = h("div", { class: "grid", "aria-hidden": "true" });
  for (let index = 0; index < 6; index++)
    grid.append(
      h("div", { class: "card skeleton" }, [
        h("div", { class: "poster sk" }),
        h("div", { class: "sk-line sk" }),
        h("div", { class: "sk-line sk short" }),
      ]),
    );
  return h("div", { class: "loading" }, [
    h("p", {
      class: "visually-hidden",
      role: "status",
      text: t("load.loading"),
    }),
    grid,
  ]);
}
function fold(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLocaleLowerCase();
}
function matches(video, query) {
  const words = fold(query).split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const haystack = fold(
    [video.title, video.channel, video.description].join("\n"),
  );
  return words.every((word) => haystack.includes(word));
}
function sortVideos(list) {
  const collator = new Intl.Collator(locale(), {
    sensitivity: "base",
    numeric: true,
  });
  const byTitle = (a, b) =>
    collator.compare(a.title, b.title) ||
    collator.compare(a.filename, b.filename);
  const sorted = [...list];
  if (state.sort === "title") return sorted.sort(byTitle);
  if (state.sort === "recorded")
    return sorted.sort(
      (a, b) =>
        (b.recorded || "").localeCompare(a.recorded || "") || byTitle(a, b),
    );
  return sorted.sort(
    (a, b) =>
      (Date.parse(b.added) || 0) - (Date.parse(a.added) || 0) || byTitle(a, b),
  );
}
function available() {
  return state.space
    ? Math.max(0, state.space.free_bytes - state.space.reserve_bytes)
    : 0;
}
function updateSpace(result) {
  state.space = {
    free_bytes: Number(result.free_bytes) || 0,
    reserve_bytes: Number(result.reserve_bytes) || 0,
  };
}

function render() {
  renderHeader();
  renderToolbar();
  renderUpload();
  renderContinue();
  renderLibrary();
}
function renderHeader() {
  const ready = !state.loading && !state.loadError;
  ui.count.textContent = ready
    ? t("header.count", { n: state.videos.length })
    : "";
  ui.count.hidden = !ready;
  ui.space.textContent = state.space
    ? t("header.free", { size: formatSize(available()) })
    : "";
  ui.space.hidden = !state.space;
  ui.subSeparator.hidden = !(ready && state.space);
  ui.addButton.disabled = Boolean(state.upload);
}
function renderToolbar() {
  for (const [view, node, count] of [
    ["all", ui.viewAll, state.videos.length],
    ["trash", ui.viewTrash, state.trash.length],
  ]) {
    node.setAttribute("aria-pressed", String(state.view === view));
    node.countNode.textContent = state.loading ? "" : String(count);
    node.countNode.hidden = state.loading || (view === "trash" && !count);
  }
  ui.clearSearch.hidden = !state.query;
  if (ui.search.value !== state.query) ui.search.value = state.query;
  ui.sort.value = state.sort;
}
function renderContinue() {
  const items =
    state.view === "all" && !state.query && !state.loading
      ? state.videos
          .map((video) => ({ video, progress: progressState(video) }))
          .filter((item) => item.progress.fraction !== null)
          .sort(
            (a, b) =>
              (state.progress[b.video.filename].at || 0) -
              (state.progress[a.video.filename].at || 0),
          )
          .slice(0, CONTINUE_LIMIT)
      : [];
  ui.continueSection.hidden = !items.length;
  ui.continueList.replaceChildren(
    ...items.map(({ video, progress }) => {
      const thumbnail = poster(video, { chips: false, play: false });
      thumbnail.append(
        h("span", { class: "resume-go", "aria-hidden": "true" }, [
          icon("play", "icon-fill"),
        ]),
      );
      return h(
        "a",
        {
          class: "resume-tile",
          href: playHref(video),
          onclick: (event) => {
            event.preventDefault();
            openPlayer(video, { resume: true });
          },
        },
        [
          thumbnail,
          h("span", { class: "resume-text" }, [
            h("span", { class: "resume-title", text: video.title }),
            h("span", {
              class: "resume-left",
              text: t("card.left", {
                time: formatMinutes(Math.ceil(progress.left / 60)),
              }),
            }),
          ]),
        ],
      );
    }),
  );
}
function renderLibrary() {
  const trash = state.view === "trash";
  const source = trash ? state.trash : state.videos;
  const searching = Boolean(state.query.trim());
  const list = sortVideos(
    source.filter((video) => matches(video, state.query)),
  );
  ui.libraryTitle.textContent = trash ? t("section.trash") : t("section.all");
  ui.resultCount.hidden = !searching || state.loading;
  ui.resultCount.textContent = t("section.results", { n: list.length });
  ui.trashNote.hidden = !trash || state.loading || Boolean(state.loadError);
  let content;
  if (state.loading) content = skeleton();
  else if (state.loadError) {
    const retry = button(t("load.retry"), "rotate", "btn-primary", null);
    retry.addEventListener(
      "click",
      guarded(retry, () => load()),
    );
    content = emptyState("alert", t("load.failed"), state.loadError, [retry], {
      className: "is-error",
      id: "load-error",
      role: "alert",
    });
  } else if (!source.length)
    content = trash
      ? emptyState("trash", t("empty.trash"), t("empty.trashText"))
      : dropTarget(
          emptyState("tv", t("empty.library"), t("empty.libraryText"), [
            button(t("add"), "plus", "btn-primary", () => ui.fileInput.click()),
          ]),
        );
  else if (!list.length)
    content = emptyState(
      "search",
      t("empty.search"),
      t("empty.searchText", { query: state.query.trim() }),
      [
        button(t("search.clear"), "x", "btn-secondary", () => {
          setQuery("");
          ui.search.focus();
        }),
      ],
    );
  else {
    content = h("div", { class: "grid" }, list.map(card));
    if (!trash && !searching) content.append(addTile());
  }
  ui.libraryBody.replaceChildren(content);
}
function renderUpload() {
  const upload = state.upload;
  ui.addButton.disabled = Boolean(upload);
  if (!upload) {
    ui.uploadSlot.replaceChildren();
    ui.uploadSlot.hidden = true;
    ui.uploadRefs = null;
    return;
  }
  const fill = h("span", { class: "track-fill" });
  const track = h(
    "span",
    {
      class: "track",
      role: "progressbar",
      "aria-label": t("upload.progress"),
      "aria-valuemin": "0",
      "aria-valuemax": "100",
    },
    [fill],
  );
  const percent = h("span", { class: "upload-percent" });
  const meta = h("p", { class: "upload-meta" });
  const cancel = button(
    t("upload.cancel"),
    "x",
    "btn-quiet upload-cancel",
    () => {
      if (state.upload && state.upload.xhr) {
        state.upload.cancelled = true;
        state.upload.xhr.abort();
      }
    },
  );
  cancel.setAttribute("aria-label", t("upload.cancelLabel"));
  ui.uploadRefs = { fill, track, percent, meta, cancel };
  ui.uploadSlot.hidden = false;
  ui.uploadSlot.replaceChildren(
    h(
      "section",
      { class: "upload-card", "aria-labelledby": "upload-heading" },
      [
        h("span", { class: "upload-icon" }, [icon("upload")]),
        h("div", { class: "upload-main" }, [
          h("h2", {
            class: "upload-heading",
            id: "upload-heading",
            text: t("upload.heading"),
          }),
          h("div", { class: "upload-top" }, [
            h("p", { class: "upload-name", text: upload.name }),
            percent,
          ]),
          track,
          meta,
          h("p", { class: "upload-note", text: t("upload.keepOpen") }),
        ]),
        cancel,
      ],
    ),
  );
  updateUploadProgress();
}
function updateUploadProgress() {
  const upload = state.upload;
  const refs = ui.uploadRefs;
  if (!upload || !refs) return;
  const fraction = upload.total ? Math.min(1, upload.loaded / upload.total) : 0;
  refs.fill.style.setProperty("--p", String(fraction));
  refs.track.setAttribute("aria-valuenow", String(Math.round(fraction * 100)));
  refs.percent.textContent = formatPercent(fraction);
  refs.cancel.disabled = upload.phase !== "sending";
  if (upload.phase === "check") refs.meta.textContent = t("upload.checking");
  else if (upload.phase === "saving")
    refs.meta.textContent = t("upload.saving");
  else {
    const parts = [];
    if (upload.speed > 0) {
      parts.push(
        t("upload.speed", { speed: formatDecimal(upload.speed / 1e6, 1) }),
      );
      const seconds = (upload.total - upload.loaded) / upload.speed;
      parts.push(
        seconds < 60
          ? t("upload.almost")
          : t("upload.remaining", {
              time: formatMinutes(Math.ceil(seconds / 60)),
            }),
      );
    }
    refs.meta.textContent = parts.join(" · ");
  }
}

// ------------------------------------------------------------------ toasts

function toast(message, { action, error = false } = {}) {
  const node = h("div", {
    class: "toast" + (error ? " is-error" : ""),
    role: error ? "alert" : "status",
  });
  let timer = null;
  const dismiss = () => {
    if (timer !== null) window.clearTimeout(timer);
    node.remove();
    if (!ui.toasts.children.length && ui.toasts.hidePopover)
      try {
        ui.toasts.hidePopover();
      } catch (_) {
        // Already hidden.
      }
  };
  node.append(
    icon(error ? "alert" : "checkCircle", "toast-icon"),
    h("p", { class: "toast-text", text: message }),
  );
  if (action) {
    const run = h("button", { type: "button", class: "toast-action" }, [
      icon("history"),
      h("span", { text: action.label }),
    ]);
    run.addEventListener(
      "click",
      guarded(run, async () => {
        dismiss();
        await action.run();
      }),
    );
    node.append(run);
  }
  node.append(iconButton("x", t("toast.dismiss"), "toast-close", dismiss));
  while (ui.toasts.children.length >= 3) ui.toasts.children[0].remove();
  ui.toasts.append(node);
  // Re-show the popover so toasts stay above an open dialog (top layer).
  if (ui.toasts.showPopover)
    try {
      if (ui.toasts.hidePopover && ui.toasts.matches(":popover-open"))
        ui.toasts.hidePopover();
      ui.toasts.showPopover();
    } catch (_) {
      // Older browsers show the fixed container without the top layer.
    }
  timer = window.setTimeout(dismiss, action ? 10000 : error ? 15000 : 6000);
  return node;
}

// ----------------------------------------------------------------- actions

function replaceIn(list, entry) {
  return list.map((item) => (item.filename === entry.filename ? entry : item));
}
async function trashVideo(video) {
  if (!(await confirmTrash(video))) return;
  const result = await request("videos/" + encodeURIComponent(video.filename), {
    method: "DELETE",
  });
  state.videos = state.videos.filter(
    (item) => item.filename !== video.filename,
  );
  state.trash = [
    result,
    ...state.trash.filter((item) => item.filename !== result.filename),
  ];
  if (state.playing === video.filename) closePlayer();
  render();
  const focused = document.activeElement;
  if (!focused || focused === document.body || focused.isConnected === false)
    ui.libraryTitle.focus();
  toast(t("toast.trashed"), {
    action: { label: t("toast.undo"), run: () => restoreVideo(result, true) },
  });
}
async function restoreVideo(video, undo) {
  const result = await request(
    "restore/" + encodeURIComponent(video.filename),
    {
      method: "POST",
    },
  );
  state.trash = state.trash.filter((item) => item.filename !== video.filename);
  state.videos = [
    result,
    ...state.videos.filter((item) => item.filename !== result.filename),
  ];
  render();
  toast(undo ? t("toast.restored") : t("toast.restoredTrash"));
}
function confirmTrash(video) {
  if (confirmResolve) confirmResolve(false);
  confirmVideo = video;
  localizeConfirm();
  return new Promise((resolve) => {
    confirmResolve = resolve;
    setDialogOpen(ui.confirm);
    ui.confirmCancel.focus();
  });
}
function settleConfirm(value) {
  const resolve = confirmResolve;
  confirmResolve = null;
  confirmVideo = null;
  closeDialog(ui.confirm);
  if (resolve) resolve(value);
}
function openEdit(video, fresh = false) {
  editSession++;
  editVideo = video;
  editFresh = fresh;
  // An older save may still be pending; this edit starts ready to save.
  ui.editSave.disabled = false;
  localizeEdit();
  ui.editTitle.value = video.title;
  ui.editDescription.value = video.description || "";
  ui.editError.hidden = true;
  ui.editError.textContent = "";
  setDialogOpen(ui.edit);
  ui.editTitle.focus();
}
async function saveEdit(event) {
  if (event && event.preventDefault) event.preventDefault();
  const video = editVideo;
  if (!video || ui.editSave.disabled) return;
  const session = editSession;
  const sameSession = () => session === editSession;
  // Still this save's dialog: same edit session and not closed meanwhile.
  const showing = () => sameSession() && ui.edit.open;
  ui.editSave.disabled = true;
  ui.editSaveLabel.textContent = t("edit.saving");
  ui.editError.hidden = true;
  try {
    const updated = await request(
      "videos/" + encodeURIComponent(video.filename),
      {
        method: "PATCH",
        json: {
          title: ui.editTitle.value,
          description: ui.editDescription.value,
        },
      },
    );
    const current = state.videos.find(
      (item) => item.filename === updated.filename,
    );
    // Keep a thumbnail captured while the dialog was open.
    if (current && current.thumb_url && !updated.thumb_url)
      updated.thumb_url = current.thumb_url;
    state.videos = replaceIn(state.videos, updated);
    if (showing()) {
      editVideo = null;
      closeDialog(ui.edit);
    }
    if (state.playing === updated.filename) fillPlayer(updated);
    render();
    toast(t("toast.saved"));
  } catch (error) {
    if (showing()) {
      ui.editError.textContent = error.message;
      ui.editError.hidden = false;
    } else toast(error.message || t("error.generic"), { error: true });
  } finally {
    if (sameSession()) {
      ui.editSave.disabled = false;
      ui.editSaveLabel.textContent = t("edit.save");
    }
  }
}

// ------------------------------------------------------------------ player

function currentPlaying() {
  return state.videos.find((item) => item.filename === state.playing);
}
function fillPlayer(video) {
  ui.playerTitle.textContent = video.title;
  ui.playerMeta.textContent = [video.channel, metaLine(video)]
    .filter(Boolean)
    .join(" · ");
  ui.playerDescription.textContent = video.description || "";
  ui.playerDescription.hidden = !video.description;
  document.title = `${video.title} · ${t("app.title")}`;
}
function seekTo(seconds) {
  const video = ui.video;
  if (video.readyState >= 1) {
    try {
      video.currentTime = seconds;
    } catch (_) {
      pendingSeek = seconds;
    }
  } else pendingSeek = seconds;
}
function playVideo() {
  try {
    const started = ui.video.play && ui.video.play();
    if (started && started.catch) started.catch(() => {});
  } catch (_) {
    // Autoplay refused: the native controls remain available.
  }
}
function showResume(seconds) {
  ui.resumeSeconds = seconds;
  localizeResume();
  ui.resume.hidden = false;
}
function hideResume() {
  ui.resume.hidden = true;
  ui.resumeSeconds = 0;
}
function openPlayer(video, { resume = false, push = true } = {}) {
  if (state.playing === video.filename && ui.player.open) return;
  // Switching recordings keeps the dialog open: closing and re-opening it
  // would queue a "close" event that arrives after the new recording.
  if (state.playing) {
    stopPlayback();
    render();
  }
  state.playing = video.filename;
  fillPlayer(video);
  ui.playerError.hidden = true;
  pendingSeek = null;
  lastSave = Date.now();
  if (ui.video.getAttribute("src") !== video.video_url)
    ui.video.src = video.video_url;
  const progress = progressState(video);
  setDialogOpen(ui.player);
  if (push) {
    history.pushState({ play: video.filename }, "", playHref(video));
    pushedPlayer = true;
  } else pushedPlayer = false;
  if (progress.seconds && !resume) {
    showResume(progress.seconds);
    seekTo(progress.seconds);
    ui.resumeButton.focus();
  } else {
    hideResume();
    if (progress.seconds) seekTo(progress.seconds);
    playVideo();
    ui.playerClose.focus();
  }
}
// Where the viewer is. Until the metadata has loaded and a requested seek is
// applied, currentTime still reads 0: report the pending seek instead (the
// saved resume point, or 0 after an explicit "Von vorne"). Null means
// unknown, e.g. a slow or failed load with nothing to resume.
function playbackPosition() {
  const video = ui.video;
  if (pendingSeek !== null) return pendingSeek;
  return Number(video.readyState) >= 1 ? Number(video.currentTime) || 0 : null;
}
function saveProgress(ended) {
  const name = state.playing;
  if (!name) return;
  const video = ui.video;
  const position = playbackPosition();
  if (position === null && !ended) return;
  const time = position || 0;
  const duration = Number(video.duration);
  if (!ended && time < 5 && !state.progress[name]) return;
  state.progress = nextProgress(
    readProgress(storage()),
    name,
    time,
    Number.isFinite(duration) && duration > 0 ? duration : undefined,
    Date.now(),
    ended,
  );
  writeProgress(storage(), state.progress);
}
// Save where the viewer is and unload the video; the dialog stays as it is.
function stopPlayback() {
  saveProgress(false);
  state.playing = null;
  pendingSeek = null;
  hideResume();
  try {
    if (ui.video.pause) ui.video.pause();
  } catch (_) {
    // Nothing to pause.
  }
  ui.video.removeAttribute("src");
  if (ui.video.load) ui.video.load();
}
function closePlayer({ fromHistory = false } = {}) {
  if (!state.playing) return;
  stopPlayback();
  closeDialog(ui.player);
  document.title = t("app.title");
  if (!fromHistory) {
    if (pushedPlayer && history.state && history.state.play) history.back();
    else history.replaceState(null, "", location.pathname + location.search);
  }
  pushedPlayer = false;
  render();
}
function hashFilename() {
  const match = /^#play=(.+)$/.exec(location.hash || "");
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch (_) {
    return null;
  }
}
function syncFromLocation() {
  const view =
    new URLSearchParams(location.search).get("trash") === "1" ? "trash" : "all";
  if (view !== state.view) {
    state.view = view;
    render();
  }
  const name = hashFilename();
  if (!name) {
    if (state.playing) closePlayer({ fromHistory: true });
    return;
  }
  if (name === state.playing) return;
  const video = state.videos.find((item) => item.filename === name);
  if (video) openPlayer(video, { push: false });
  else if (!state.loading) {
    history.replaceState(null, "", location.pathname + location.search);
    toast(t("player.missing"), { error: true });
  }
}
function setView(view) {
  if (view === state.view) return;
  state.view = view;
  history.pushState(null, "", BASE + (view === "trash" ? "?trash=1" : ""));
  render();
}
function setQuery(value) {
  state.query = value;
  renderToolbar();
  renderContinue();
  renderLibrary();
}

// ------------------------------------------------------------------ upload

function dropTarget(node) {
  node.addEventListener("dragover", (event) => {
    event.preventDefault();
    node.classList.add("is-over");
  });
  node.addEventListener("dragleave", () => node.classList.remove("is-over"));
  node.addEventListener("drop", (event) => {
    event.preventDefault();
    event.stopPropagation();
    node.classList.remove("is-over");
    hideDropOverlay();
    const files = event.dataTransfer && event.dataTransfer.files;
    if (files && files.length) void startUpload(files[0]);
  });
  return node;
}
function hasFiles(event) {
  const types = event.dataTransfer && event.dataTransfer.types;
  return Boolean(types && Array.from(types).includes("Files"));
}
function hideDropOverlay() {
  dragDepth = 0;
  ui.dropOverlay.hidden = true;
}
function waitFor(target, type, timeout) {
  return new Promise((resolve, reject) => {
    const done = (error) => {
      window.clearTimeout(timer);
      target.removeEventListener(type, onEvent);
      target.removeEventListener("error", onError);
      if (error) reject(error);
      else resolve();
    };
    const onEvent = () => done();
    const onError = () => done(new Error("media error"));
    const timer = window.setTimeout(() => done(new Error("timeout")), timeout);
    target.addEventListener(type, onEvent);
    target.addEventListener("error", onError);
  });
}
// Centre crop that fills the target: the source rectangle to draw.
function coverCrop(
  sourceWidth,
  sourceHeight,
  width = THUMB_WIDTH,
  height = THUMB_HEIGHT,
) {
  const scale = Math.max(width / sourceWidth, height / sourceHeight);
  const cropWidth = width / scale;
  const cropHeight = height / scale;
  return {
    x: (sourceWidth - cropWidth) / 2,
    y: (sourceHeight - cropHeight) / 2,
    width: cropWidth,
    height: cropHeight,
  };
}
// An object URL for a chosen local file. It is checked before it reaches a
// media element: only our own blob: scheme, and no markup characters or
// whitespace (a browser-made object URL never contains any).
function localObjectUrl(file) {
  const url = URL.createObjectURL(file);
  if (!url.startsWith("blob:")) {
    URL.revokeObjectURL(url);
    throw new Error("not an object URL");
  }
  if (/["'`<>&\s]/.test(url)) {
    URL.revokeObjectURL(url);
    throw new Error("unexpected characters in object URL");
  }
  return url;
}
// Reads the LOCAL file (blob: URL, allowed by media-src) — nothing is
// downloaded again. Any failure simply leaves the designed fallback poster.
async function captureThumbnail(file) {
  const url = localObjectUrl(file);
  const video = document.createElement("video");
  try {
    video.muted = true;
    video.playsInline = true;
    video.preload = "auto";
    const loaded = waitFor(video, "loadedmetadata", THUMB_TIMEOUT_MS);
    video.src = url;
    await loaded;
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    const seeked = waitFor(video, "seeked", THUMB_TIMEOUT_MS);
    video.currentTime = Math.min(duration * 0.1, 120);
    await seeked;
    if (!video.videoWidth || !video.videoHeight) throw new Error("no frame");
    const canvas = document.createElement("canvas");
    canvas.width = THUMB_WIDTH;
    canvas.height = THUMB_HEIGHT;
    const crop = coverCrop(video.videoWidth, video.videoHeight);
    canvas
      .getContext("2d")
      .drawImage(
        video,
        crop.x,
        crop.y,
        crop.width,
        crop.height,
        0,
        0,
        THUMB_WIDTH,
        THUMB_HEIGHT,
      );
    return await new Promise((resolve, reject) =>
      canvas.toBlob(
        (blob) => (blob ? resolve(blob) : reject(new Error("no image"))),
        "image/jpeg",
        THUMB_QUALITY,
      ),
    );
  } finally {
    video.removeAttribute("src");
    if (video.load) video.load();
    URL.revokeObjectURL(url);
  }
}
async function storeThumbnail(file, entry, capture = captureThumbnail) {
  try {
    const blob = await capture(file);
    const updated = await request(
      "videos/" + encodeURIComponent(entry.filename) + "/thumb",
      { method: "PUT", raw: blob, type: "image/jpeg" },
    );
    if (!updated.thumb_url) return false;
    state.videos = state.videos.map((item) =>
      item.filename === updated.filename
        ? { ...item, thumb_url: updated.thumb_url }
        : item,
    );
    renderContinue();
    renderLibrary();
    return true;
  } catch (_) {
    return false; // Non-fatal: the fallback poster stays.
  }
}
async function startUpload(file) {
  if (!file) return;
  if (state.upload) {
    toast(t("upload.busy"), { error: true });
    return;
  }
  if (!VIDEO_PATTERN.test(file.name || "")) {
    toast(t("upload.wrongType"), { error: true });
    return;
  }
  state.upload = {
    name: file.name,
    total: file.size,
    loaded: 0,
    speed: 0,
    phase: "check",
    cancelled: false,
    xhr: null,
  };
  renderHeader();
  renderUpload();
  renderLibrary();
  try {
    updateSpace(await request("videos"));
    renderHeader();
    if (file.size > available()) throw new Error(t("error.insufficient_space"));
  } catch (error) {
    state.upload = null;
    render();
    toast(error.message, { error: true });
    return;
  }
  const upload = state.upload;
  const xhr = new XMLHttpRequest();
  upload.xhr = xhr;
  upload.phase = "sending";
  upload.lastTime = Date.now();
  upload.lastLoaded = 0;
  xhr.open("PUT", BASE + "api/videos/" + encodeURIComponent(file.name));
  xhr.setRequestHeader("X-Media-Request", "1");
  xhr.setRequestHeader("Content-Type", "application/octet-stream");
  updateUploadProgress();
  const beforeLeave = (event) => {
    event.preventDefault();
    event.returnValue = "";
  };
  window.addEventListener("beforeunload", beforeLeave);
  xhr.upload.onprogress = (event) => {
    if (!event.lengthComputable) return;
    const now = Date.now();
    const seconds = (now - upload.lastTime) / 1000;
    if (seconds >= 0.5) {
      const rate = (event.loaded - upload.lastLoaded) / seconds;
      upload.speed = upload.speed ? upload.speed * 0.7 + rate * 0.3 : rate;
      upload.lastTime = now;
      upload.lastLoaded = event.loaded;
    }
    upload.loaded = event.loaded;
    upload.total = event.total;
    if (event.loaded === event.total) upload.phase = "saving";
    updateUploadProgress();
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
    state.upload = null;
    window.removeEventListener("beforeunload", beforeLeave);
    document.removeEventListener("visibilitychange", onVisible);
    if (wakeLock) void wakeLock.release().catch(() => {});
  };
  xhr.onload = () => {
    finish();
    let result;
    try {
      result = JSON.parse(xhr.responseText);
    } catch (_) {
      render();
      toast(unreadableResponse(xhr.status), { error: true });
      return;
    }
    if (xhr.status !== 201 || !result || typeof result !== "object") {
      render();
      toast(
        result && (result.code || result.error)
          ? problemText(result)
          : t("upload.failed"),
        {
          error: true,
        },
      );
      return;
    }
    state.videos = [
      result,
      ...state.videos.filter((item) => item.filename !== result.filename),
    ];
    if (state.view !== "all") setView("all");
    if (state.query) state.query = "";
    render();
    void request("videos")
      .then((listing) => {
        updateSpace(listing);
        renderHeader();
      })
      .catch(() => {});
    // Never replace an edit in progress (its draft); the new card is in the
    // library and can be named from there.
    if (!ui.edit.open) openEdit(result, true);
    toast(t("toast.added"));
    void storeThumbnail(file, result);
  };
  xhr.onerror = xhr.onabort = () => {
    const cancelled = upload.cancelled;
    finish();
    render();
    toast(cancelled ? t("upload.cancelled") : t("upload.interrupted"), {
      error: !cancelled,
    });
  };
  await keepAwake();
  try {
    xhr.send(file);
  } catch (_) {
    xhr.onerror();
  }
}

// ------------------------------------------------------------- localizing

function localizeResume() {
  const time = formatClock(ui.resumeSeconds || 0);
  ui.resumeNote.textContent = t("player.resumeNote", { time });
  ui.resumeButtonLabel.textContent = t("player.resume", { time });
  ui.restartButtonLabel.textContent = t("player.restart");
}
function localizeEdit() {
  ui.editHeading.textContent = editFresh
    ? t("edit.headingNew")
    : t("edit.heading");
  ui.editIntro.textContent = t("edit.introNew");
  ui.editIntro.hidden = !editFresh;
  ui.editTitleLabel.textContent = t("edit.title");
  ui.editDescriptionLabel.textContent = t("edit.description");
  ui.editCancelLabel.textContent = t("edit.cancel");
  ui.editSaveLabel.textContent = ui.editSave.disabled
    ? t("edit.saving")
    : t("edit.save");
  ui.editClose.setAttribute("aria-label", t("player.close"));
  ui.editClose.setAttribute("title", t("player.close"));
}
function localizeConfirm() {
  ui.confirmHeading.textContent = t("confirm.heading");
  ui.confirmText.textContent = confirmVideo
    ? t("confirm.text", { title: confirmVideo.title })
    : "";
  ui.confirmOkLabel.textContent = t("confirm.ok");
  ui.confirmCancelLabel.textContent = t("confirm.cancel");
}
function localize() {
  document.documentElement.lang = state.lang;
  const playing = state.playing && currentPlaying();
  document.title = playing
    ? `${playing.title} · ${t("app.title")}`
    : t("app.title");
  ui.skip.textContent = t("skip");
  ui.homeLabel.textContent = t("nav.home");
  ui.home.setAttribute("aria-label", t("nav.homeLabel"));
  ui.langGroup.setAttribute("aria-label", t("lang.group"));
  for (const lang of LANGUAGES)
    ui.langButtons[lang].setAttribute(
      "aria-pressed",
      String(lang === state.lang),
    );
  ui.pageTitle.textContent = t("app.title");
  ui.addButtonLabel.textContent = t("add");
  ui.viewGroup.setAttribute("aria-label", t("view.label"));
  ui.viewAll.labelNode.textContent = t("view.all");
  ui.viewTrash.labelNode.textContent = t("view.trash");
  ui.searchLabel.textContent = t("search.label");
  ui.search.setAttribute("placeholder", t("search.placeholder"));
  ui.clearSearch.setAttribute("aria-label", t("search.clear"));
  ui.clearSearch.setAttribute("title", t("search.clear"));
  ui.sortLabel.textContent = t("sort.label");
  for (const key of SORTS) ui.sortOptions[key].textContent = t("sort." + key);
  ui.continueTitle.textContent = t("section.continue");
  ui.trashNote.textContent = t("trash.note");
  ui.dropText.textContent = t("drop.here");
  ui.player.setAttribute("aria-label", t("player.label"));
  ui.playerClose.setAttribute("aria-label", t("player.close"));
  ui.playerClose.setAttribute("title", t("player.close"));
  ui.playerKicker.textContent = t("app.title");
  ui.playerEditLabel.textContent = t("card.edit");
  ui.playerDeleteLabel.textContent = t("card.delete");
  ui.playerCloseLabel.textContent = t("player.close");
  ui.playerError.textContent = t("player.error");
  localizeResume();
  localizeEdit();
  localizeConfirm();
  if (playing) fillPlayer(playing);
}
function setLanguage(lang, persist) {
  if (!LANGUAGES.includes(lang)) return;
  if (persist)
    try {
      storage().setItem(LANG_KEY, lang);
    } catch (_) {
      // Storage unavailable: the switch still applies to this page.
    }
  state.lang = lang;
  localize();
  render();
}
function storage() {
  try {
    return window.localStorage || null;
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------- shell

function buildShell(root) {
  ui = {};
  ui.skip = h("a", { class: "skip-link", href: "#library" });
  ui.homeLabel = h("span", { class: "home-text" });
  ui.home = h("a", { class: "home-link", href: "/" }, [
    h("span", { class: "home-icon" }, [icon("house")]),
    ui.homeLabel,
  ]);
  ui.langButtons = {};
  ui.langGroup = h("div", { class: "lang-switch", role: "group" });
  for (const lang of LANGUAGES) {
    const node = h("button", {
      type: "button",
      class: "lang-option",
      lang,
      "aria-label": AUTONYMS[lang],
      text: lang.toUpperCase(),
      onclick: () => setLanguage(lang, true),
    });
    ui.langButtons[lang] = node;
    ui.langGroup.append(node);
  }
  const topbar = h("header", { class: "topbar" }, [
    h("div", { class: "topbar-inner" }, [ui.home, ui.langGroup]),
  ]);

  ui.pageTitle = h("h1", { class: "page-title", id: "page-title" });
  ui.count = h("span", { class: "hero-count" });
  ui.subSeparator = h("span", { class: "hero-sep", "aria-hidden": "true" });
  ui.space = h("span", { class: "hero-space", id: "space" });
  ui.addButtonLabel = h("span", { class: "btn-label" });
  ui.addButton = h(
    "button",
    {
      type: "button",
      class: "btn btn-primary btn-large",
      id: "add-button",
      onclick: () => ui.fileInput.click(),
    },
    [h("span", { class: "btn-plus" }, [icon("plus")]), ui.addButtonLabel],
  );
  const hero = h(
    "section",
    { class: "hero", "aria-labelledby": "page-title" },
    [
      h("div", { class: "hero-text" }, [
        ui.pageTitle,
        h("p", { class: "hero-sub" }, [ui.count, ui.subSeparator, ui.space]),
      ]),
      ui.addButton,
    ],
  );
  ui.uploadSlot = h("div", { class: "upload-slot", hidden: true });

  const viewButton = (view, iconName) => {
    const labelNode = h("span", { class: "segment-label" });
    const countNode = h("span", { class: "segment-count" });
    const node = h(
      "button",
      { type: "button", class: "segment", onclick: () => setView(view) },
      [icon(iconName), labelNode, countNode],
    );
    node.labelNode = labelNode;
    node.countNode = countNode;
    return node;
  };
  ui.viewAll = viewButton("all", "grid");
  ui.viewTrash = viewButton("trash", "trash");
  ui.viewGroup = h("div", { class: "segmented", role: "group" }, [
    ui.viewAll,
    ui.viewTrash,
  ]);
  ui.searchLabel = h("label", { class: "visually-hidden", for: "search" });
  ui.search = h("input", {
    type: "search",
    id: "search",
    class: "search-input",
    autocomplete: "off",
    spellcheck: "false",
    enterkeyhint: "search",
    oninput: (event) => setQuery(event.target.value),
    onkeydown: (event) => {
      if (event.key === "Escape" && state.query) {
        event.preventDefault();
        setQuery("");
      }
    },
  });
  ui.clearSearch = iconButton("x", "", "search-clear", () => {
    setQuery("");
    ui.search.focus();
  });
  ui.sortLabel = h("label", { class: "visually-hidden", for: "sort" });
  ui.sortOptions = {};
  ui.sort = h("select", {
    id: "sort",
    class: "sort-select",
    onchange: (event) => {
      state.sort = SORTS.includes(event.target.value)
        ? event.target.value
        : "added";
      try {
        storage().setItem(SORT_KEY, state.sort);
      } catch (_) {
        // Sorting still applies to this visit.
      }
      renderLibrary();
    },
  });
  for (const key of SORTS) {
    ui.sortOptions[key] = h("option", { value: key });
    ui.sort.append(ui.sortOptions[key]);
  }
  const toolbar = h("div", { class: "toolbar" }, [
    ui.viewGroup,
    h("div", { class: "search" }, [
      ui.searchLabel,
      icon("search", "search-icon"),
      ui.search,
      ui.clearSearch,
    ]),
    h("div", { class: "sort" }, [
      ui.sortLabel,
      icon("sort", "sort-icon"),
      ui.sort,
      icon("chevron", "sort-chevron"),
    ]),
  ]);

  ui.continueTitle = h("span");
  ui.continueList = h("div", { class: "resume-grid" });
  ui.continueSection = h(
    "section",
    { class: "section", "aria-labelledby": "continue-title", hidden: true },
    [
      h("div", { class: "section-head" }, [
        h("h2", { class: "section-title", id: "continue-title" }, [
          icon("history"),
          ui.continueTitle,
        ]),
      ]),
      ui.continueList,
    ],
  );
  ui.libraryTitle = h("h2", {
    class: "section-title",
    id: "library-title",
    tabindex: "-1",
  });
  ui.resultCount = h("span", { class: "section-count", hidden: true });
  ui.trashNote = h("p", { class: "trash-note", hidden: true });
  ui.libraryBody = h("div", { class: "library-body" });
  const library = h(
    "section",
    { class: "section", id: "library", "aria-labelledby": "library-title" },
    [
      h("div", { class: "section-head" }, [ui.libraryTitle, ui.resultCount]),
      ui.trashNote,
      ui.libraryBody,
    ],
  );
  const main = h("main", { class: "page", id: "main" }, [
    hero,
    ui.uploadSlot,
    toolbar,
    ui.continueSection,
    library,
  ]);

  ui.toasts = h("div", {
    class: "toasts",
    popover: "manual",
    "aria-live": "polite",
  });
  ui.fileInput = h("input", {
    type: "file",
    id: "video-file",
    class: "visually-hidden",
    accept: ".mp4,.m4v,.mov,video/mp4,video/quicktime",
    tabindex: "-1",
    "aria-hidden": "true",
    onchange: () => {
      const file = ui.fileInput.files && ui.fileInput.files[0];
      ui.fileInput.value = "";
      void startUpload(file);
    },
  });
  ui.dropText = h("span", { class: "drop-text" });
  ui.dropOverlay = h("div", { class: "drop-overlay", hidden: true }, [
    h("div", { class: "drop-frame" }, [
      h("span", { class: "drop-icon" }, [icon("upload")]),
      ui.dropText,
    ]),
  ]);

  buildPlayer();
  buildEdit();
  buildConfirm();
  root.replaceChildren(
    ui.skip,
    topbar,
    main,
    ui.player,
    ui.edit,
    ui.confirm,
    ui.fileInput,
    ui.dropOverlay,
    ui.toasts,
  );
}
function buildPlayer() {
  ui.video = h("video", {
    class: "player-video",
    controls: true,
    playsinline: true,
    preload: "metadata",
  });
  ui.video.addEventListener("loadedmetadata", () => {
    if (pendingSeek !== null) {
      const seconds = pendingSeek;
      pendingSeek = null;
      try {
        ui.video.currentTime = seconds;
      } catch (_) {
        // Unseekable stream: playback starts from the beginning.
      }
    }
  });
  ui.video.addEventListener("timeupdate", () => {
    if (Date.now() - lastSave >= SAVE_INTERVAL_MS) {
      lastSave = Date.now();
      saveProgress(false);
    }
  });
  ui.video.addEventListener("play", hideResume);
  ui.video.addEventListener("pause", () => saveProgress(false));
  ui.video.addEventListener("ended", () => saveProgress(true));
  ui.video.addEventListener("error", () => {
    if (state.playing && ui.video.getAttribute("src"))
      ui.playerError.hidden = false;
  });
  ui.resumeNote = h("p", { class: "resume-note" });
  ui.resumeButtonLabel = h("span", { class: "btn-label" });
  ui.restartButtonLabel = h("span", { class: "btn-label" });
  ui.resumeButton = h(
    "button",
    {
      type: "button",
      class: "btn btn-primary btn-large",
      onclick: () => {
        const seconds = ui.resumeSeconds;
        hideResume();
        seekTo(seconds);
        playVideo();
      },
    },
    [icon("play", "icon-fill"), ui.resumeButtonLabel],
  );
  ui.restartButton = h(
    "button",
    {
      type: "button",
      class: "btn btn-light btn-large",
      onclick: () => {
        hideResume();
        seekTo(0);
        playVideo();
      },
    },
    [icon("rotate"), ui.restartButtonLabel],
  );
  ui.resume = h("div", { class: "resume", hidden: true }, [
    h("div", { class: "resume-card" }, [
      ui.resumeNote,
      h("div", { class: "resume-actions" }, [
        ui.resumeButton,
        ui.restartButton,
      ]),
    ]),
  ]);
  ui.playerKicker = h("span");
  ui.playerClose = iconButton("x", "", "player-close", () => closePlayer());
  ui.playerTitle = h("h2", { class: "player-title", id: "player-title" });
  ui.playerMeta = h("p", { class: "player-meta" });
  ui.playerDescription = h("p", { class: "player-desc" });
  ui.playerError = h("p", {
    class: "player-error",
    role: "alert",
    hidden: true,
  });
  ui.playerEditLabel = h("span", { class: "btn-label" });
  ui.playerDeleteLabel = h("span", { class: "btn-label" });
  ui.playerCloseLabel = h("span", { class: "btn-label" });
  const playerEdit = h(
    "button",
    {
      type: "button",
      class: "btn btn-light",
      onclick: () => {
        const video = currentPlaying();
        if (video) openEdit(video);
      },
    },
    [icon("pencil"), ui.playerEditLabel],
  );
  const playerDelete = h(
    "button",
    { type: "button", class: "btn btn-light is-danger" },
    [icon("trash"), ui.playerDeleteLabel],
  );
  playerDelete.addEventListener(
    "click",
    guarded(playerDelete, async () => {
      const video = currentPlaying();
      if (video) await trashVideo(video);
    }),
  );
  const playerDone = h(
    "button",
    {
      type: "button",
      class: "btn btn-solid-light",
      onclick: () => closePlayer(),
    },
    [icon("x"), ui.playerCloseLabel],
  );
  ui.player = h(
    "dialog",
    { class: "player", "aria-labelledby": "player-title" },
    [
      h("div", { class: "player-shell" }, [
        h("div", { class: "player-bar" }, [
          h("span", { class: "player-kicker" }, [icon("tv"), ui.playerKicker]),
          ui.playerClose,
        ]),
        h("div", { class: "player-stage-wrap" }, [
          h("div", { class: "player-stage" }, [ui.video]),
          ui.resume,
        ]),
        ui.playerError,
        h("div", { class: "player-info" }, [
          h("div", { class: "player-head" }, [ui.playerTitle, ui.playerMeta]),
          h("div", { class: "player-actions" }, [
            playerEdit,
            playerDelete,
            playerDone,
          ]),
          ui.playerDescription,
        ]),
      ]),
    ],
  );
  ui.player.addEventListener("cancel", (event) => {
    event.preventDefault();
    closePlayer();
  });
  onDialogClosed(ui.player, () => {
    if (state.playing) closePlayer();
  });
}
function buildEdit() {
  ui.editHeading = h("h2", { class: "sheet-title", id: "edit-heading" });
  ui.editIntro = h("p", { class: "sheet-intro", hidden: true });
  ui.editClose = iconButton("x", "", "sheet-close", () => closeDialog(ui.edit));
  ui.editTitleLabel = h("label", { for: "edit-title" });
  ui.editTitle = h("input", {
    id: "edit-title",
    name: "title",
    type: "text",
    maxlength: "200",
    required: true,
    autocomplete: "off",
  });
  ui.editDescriptionLabel = h("label", { for: "edit-description" });
  ui.editDescription = h("textarea", {
    id: "edit-description",
    name: "description",
    maxlength: "4000",
    rows: "6",
  });
  ui.editError = h("p", { class: "form-error", role: "alert", hidden: true });
  ui.editCancelLabel = h("span", { class: "btn-label" });
  ui.editSaveLabel = h("span", { class: "btn-label" });
  ui.editSave = h("button", { type: "submit", class: "btn btn-primary" }, [
    icon("check"),
    ui.editSaveLabel,
  ]);
  ui.editForm = h(
    "form",
    { class: "sheet-body", id: "edit-form", onsubmit: saveEdit },
    [
      h("div", { class: "sheet-head" }, [ui.editHeading, ui.editClose]),
      ui.editIntro,
      h("div", { class: "field" }, [ui.editTitleLabel, ui.editTitle]),
      h("div", { class: "field" }, [
        ui.editDescriptionLabel,
        ui.editDescription,
      ]),
      ui.editError,
      h("div", { class: "sheet-actions" }, [
        h(
          "button",
          {
            type: "button",
            class: "btn btn-quiet",
            onclick: () => closeDialog(ui.edit),
          },
          [ui.editCancelLabel],
        ),
        ui.editSave,
      ]),
    ],
  );
  ui.edit = h("dialog", { class: "sheet", "aria-labelledby": "edit-heading" }, [
    ui.editForm,
  ]);
  onDialogClosed(ui.edit, () => {
    editVideo = null;
  });
}
function buildConfirm() {
  ui.confirmHeading = h("h2", { class: "sheet-title", id: "confirm-heading" });
  ui.confirmText = h("p", { class: "sheet-text", id: "confirm-text" });
  ui.confirmOkLabel = h("span", { class: "btn-label" });
  ui.confirmCancelLabel = h("span", { class: "btn-label" });
  ui.confirmCancel = h(
    "button",
    {
      type: "button",
      class: "btn btn-quiet",
      onclick: () => settleConfirm(false),
    },
    [ui.confirmCancelLabel],
  );
  ui.confirmOk = h(
    "button",
    {
      type: "button",
      class: "btn btn-primary",
      onclick: () => settleConfirm(true),
    },
    [icon("trash"), ui.confirmOkLabel],
  );
  ui.confirm = h(
    "dialog",
    {
      class: "sheet sheet-small",
      role: "alertdialog",
      "aria-labelledby": "confirm-heading",
      "aria-describedby": "confirm-text",
    },
    [
      h("div", { class: "sheet-body confirm-body" }, [
        h("span", { class: "confirm-icon" }, [icon("trash")]),
        ui.confirmHeading,
        ui.confirmText,
        h("div", { class: "sheet-actions" }, [ui.confirmCancel, ui.confirmOk]),
      ]),
    ],
  );
  onDialogClosed(ui.confirm, () => {
    if (confirmResolve) settleConfirm(false);
  });
}

// -------------------------------------------------------------------- boot

async function load() {
  state.loading = true;
  state.loadError = "";
  render();
  try {
    const [active, trashed] = await Promise.all([
      request("videos"),
      request("videos?trash=1"),
    ]);
    state.videos = Array.isArray(active.videos) ? active.videos : [];
    state.trash = Array.isArray(trashed.videos) ? trashed.videos : [];
    updateSpace(active);
  } catch (error) {
    state.loadError = error.message || t("error.generic");
  }
  state.loading = false;
  render();
  if (!state.loadError) syncFromLocation();
}
function bindWindow() {
  window.addEventListener("storage", (event) => {
    if (event.key === LANG_KEY || event.key === null) {
      const lang = resolveLanguage(navigator, storage());
      if (lang !== state.lang) setLanguage(lang, false);
    }
    if (event.key === PROGRESS_KEY || event.key === null) {
      state.progress = readProgress(storage());
      if (!state.playing) {
        renderContinue();
        renderLibrary();
      }
    }
  });
  window.addEventListener("popstate", syncFromLocation);
  window.addEventListener("hashchange", syncFromLocation);
  // Never let a dropped file replace the page; route it to the uploader.
  window.addEventListener("dragenter", (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    dragDepth++;
    if (!ui.player.open && !ui.edit.open && !ui.confirm.open)
      ui.dropOverlay.hidden = false;
  });
  window.addEventListener("dragover", (event) => {
    if (hasFiles(event)) event.preventDefault();
  });
  window.addEventListener("dragleave", (event) => {
    if (!hasFiles(event)) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (!dragDepth) ui.dropOverlay.hidden = true;
  });
  window.addEventListener("drop", (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    const wasOpen = !ui.dropOverlay.hidden;
    hideDropOverlay();
    const files = event.dataTransfer.files;
    if (wasOpen && files && files.length) void startUpload(files[0]);
  });
}
function start() {
  const root = document.getElementById("app");
  buildShell(root);
  state.lang = resolveLanguage(navigator, storage());
  state.progress = readProgress(storage());
  try {
    const sort = storage() && storage().getItem(SORT_KEY);
    if (SORTS.includes(sort)) state.sort = sort;
  } catch (_) {
    // Default sort.
  }
  const params = new URLSearchParams(location.search);
  state.view = params.get("trash") === "1" ? "trash" : "all";
  // Links from the first version: ?watch=<file> becomes the #play= hash.
  if (params.has("watch")) {
    history.replaceState(
      null,
      "",
      BASE + "#play=" + encodeURIComponent(params.get("watch")),
    );
  }
  localize();
  bindWindow();
  const loaded = load();
  if (params.has("add")) ui.addButton.focus();
  return loaded;
}

if (typeof module === "object" && module.exports) {
  module.exports = {
    STRINGS,
    LANG_KEY,
    PROGRESS_KEY,
    translate,
    browserLanguage,
    storedLanguage,
    resolveLanguage,
    readProgress,
    nextProgress,
    writeProgress,
    paletteIndex,
    coverCrop,
    localObjectUrl,
    formatClock,
    storeThumbnail,
    startUpload,
    state,
    start,
    setLanguage,
    problemText: (result, lang = "de") => {
      const previous = state.lang;
      state.lang = lang;
      try {
        return problemText(result);
      } finally {
        state.lang = previous;
      }
    },
  };
} else start();
