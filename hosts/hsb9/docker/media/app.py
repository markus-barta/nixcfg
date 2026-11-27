#!/usr/bin/env python3
"""LAN recording library. One process; all metadata transactions share a lock."""

from __future__ import annotations

import datetime as dt
import errno
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit
import unicodedata
import uuid

PREFIX = "/fernsehen/"
CHUNK_SIZE = 1024 * 1024
EXTENSIONS = {".mp4", ".m4v", ".mov"}
STATIC = Path(__file__).parent
DATA_DIR = Path("/data")
MIN_RESERVE_BYTES = 20 * 1024 ** 3
THUMB_MAX_BYTES = 1024 * 1024
SPACE_ERROR = "Auf dem Gerät ist nicht genug Platz für dieses Video. Bitte die Betreuung verständigen."
THUMB_SPACE_ERROR = "Für das Vorschaubild ist nicht genug Platz."
NAME_ERROR = "Bitte eine Videodatei mit gültigem Namen wählen (.mp4, .m4v oder .mov)."
METADATA_ERROR = "Die Angaben können gerade nicht gelesen werden. Bitte die Betreuung verständigen."


class Problem(Exception):
    """An expected failure. `code` is a stable snake_case key the UI localises;
    `message` stays the German fallback text."""

    def __init__(self, status, message, code, **details):
        self.status, self.message, self.code, self.details = status, message, code, details

    def body(self):
        return {"error": self.message, "code": self.code, **self.details}


def filename(value):
    if (not isinstance(value, str) or not value or value.startswith(".")
            or value != value.strip()
            or ".." in value or any(c in value for c in "/\\")
            or any(unicodedata.category(c).startswith("C") for c in value)
            or len(value.encode("utf-8")) > 180
            or Path(value).suffix.lower() not in EXTENSIONS):
        raise Problem(400, NAME_ERROR, "invalid_name")
    return value


def upload_filename(value):
    """Clean browser filenames; path separators and control characters stay forbidden."""
    if (not isinstance(value, str) or any(c in value for c in "/\\")
            or any(unicodedata.category(c).startswith("C") for c in value)):
        raise Problem(400, NAME_ERROR, "invalid_name")
    normalized = unicodedata.normalize("NFC", value).strip()
    stem, dot, extension = normalized.rpartition(".")
    suffix = dot + extension
    if suffix.lower() not in EXTENSIONS:
        raise Problem(400, "Bitte eine Videodatei wählen (.mp4, .m4v oder .mov).", "unsupported_type")
    while ".." in stem:
        stem = stem.replace("..", ".")
    stem = stem.strip().rstrip(". ")
    while stem and (stem[0] == "." or stem[0].isspace()):
        stem = stem[1:]
    stem = stem.encode("utf-8")[:180 - len(suffix.encode("utf-8"))].decode("utf-8", errors="ignore")
    stem = stem.rstrip(". ")
    return filename((stem or uuid.uuid4().hex) + suffix)


def regular(path):
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except FileNotFoundError:
        return False


def regular_mtime(path):
    """Modification time of a regular file, never following a symlink; else None."""
    try:
        status = path.lstat()
    except FileNotFoundError:
        return None
    return status.st_mtime_ns if stat.S_ISREG(status.st_mode) else None


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def text_field(value, maximum):
    if (not isinstance(value, str) or len(value) > maximum
            or any(unicodedata.category(c).startswith("C") and c not in "\n\r\t" for c in value)):
        raise Problem(400, f"Bitte Text mit höchstens {maximum} Zeichen eingeben.", "invalid_text", limit=maximum)
    return value.strip()


def metadata_fields(record):
    """Validate seeded data too: never overwrite an unreadable metadata file."""
    if not isinstance(record, dict) or set(record) - {
        "title", "description", "channel", "recorded", "duration_min", "added"
    }:
        raise ValueError("Invalid metadata fields")
    for key, limit in (("title", 200), ("description", 4000), ("channel", 120)):
        if key in record:
            text_field(record[key], limit)
    recorded = record.get("recorded", "")
    if recorded:
        if not isinstance(recorded, str) or dt.date.fromisoformat(recorded).isoformat() != recorded:
            raise ValueError("Invalid recording date")
    elif not isinstance(recorded, str):
        raise ValueError("Invalid recording date")
    duration = record.get("duration_min")
    if duration is not None and (isinstance(duration, bool) or not isinstance(duration, (int, float))
                                 or not math.isfinite(duration) or not 0 <= duration <= 100000):
        raise ValueError("Invalid duration")
    if "added" in record:
        value = record["added"]
        if not isinstance(value, str) or len(value) > 40 or dt.datetime.fromisoformat(value).tzinfo is None:
            raise ValueError("Invalid added timestamp")


class Library:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.trash = self.directory / ".trash"
        self.thumbs = self.directory / ".thumbs"
        # The host declares these paths and their ownership; refuse symlinks.
        if any(path.is_symlink() for path in (self.directory, self.trash, self.thumbs)):
            raise ValueError("Data directories must not be symlinks")
        # tmpfiles normally creates both (0750); the process umask (0027) keeps
        # a fallback mkdir at 0750 or narrower, never wider.
        self.trash.mkdir(mode=0o750, parents=True, exist_ok=True)
        self.thumbs.mkdir(mode=0o750, exist_ok=True)
        self.lock = threading.RLock()
        self.metadata = self.directory / "metadata.json"
        override = os.environ.get("MEDIA_RESERVE_BYTES")
        self.reserve_bytes = None if override is None else int(override)
        if self.reserve_bytes is not None and self.reserve_bytes < 0:
            raise ValueError("MEDIA_RESERVE_BYTES must be a non-negative integer")
        # This process is the sole writer. Never follow symlinks or touch admin
        # staging files; only abandoned regular app temporaries are ours.
        for path in self.directory.iterdir():
            if path.name.startswith((".upload-", ".metadata-")) and regular(path):
                path.unlink()
        for path in self.thumbs.iterdir():
            if path.name.startswith(".thumb-") and regular(path):
                path.unlink()

    def space(self):
        usage = os.statvfs(self.directory)
        total = usage.f_blocks * usage.f_frsize
        reserve = (max(MIN_RESERVE_BYTES, (total + 9) // 10)
                   if self.reserve_bytes is None else self.reserve_bytes)
        return {"free_bytes": usage.f_bavail * usage.f_frsize, "reserve_bytes": reserve}

    def disk_full(self):
        print("hsb9-media: upload refused (insufficient disk space)", file=sys.stderr, flush=True)
        raise Problem(507, SPACE_ERROR, "insufficient_space")

    def fits(self, size):
        """True when `size` more bytes leave the free-space reserve untouched."""
        space = self.space()
        return size <= space["free_bytes"] - space["reserve_bytes"]

    def require_upload_space(self, remaining):
        if not self.fits(remaining):
            self.disk_full()

    def load(self):
        if not self.metadata.exists() and not self.metadata.is_symlink():
            return {}
        if not regular(self.metadata):
            raise Problem(503, METADATA_ERROR, "metadata_unreadable")
        try:
            with self.metadata.open(encoding="utf-8") as stream:
                records = json.load(stream)
            if not isinstance(records, dict):
                raise ValueError("Invalid metadata")
            for name, record in records.items():
                filename(name)
                metadata_fields(record)
            return records
        except (ValueError, TypeError, Problem):
            raise Problem(503, METADATA_ERROR, "metadata_unreadable") from None

    def save(self, records):
        descriptor, name = tempfile.mkstemp(prefix=".metadata-", dir=self.directory)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                os.fchmod(stream.fileno(), 0o640)
                json.dump(records, stream, ensure_ascii=False, allow_nan=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.metadata)
            sync_directory(self.directory)
        finally:
            temporary.unlink(missing_ok=True)

    def entry(self, name, records, trashed=False):
        path = (self.trash if trashed else self.directory) / name
        added = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat()
        result = {"title": Path(name).stem.replace("_", " "), "description": "", "channel": "",
                  "recorded": "", "duration_min": None, "added": added}
        result.update(records.get(name, {}))
        if not result["title"].strip():
            result["title"] = Path(name).stem.replace("_", " ")
        entry = {**result, "filename": name, "trash": trashed,
                 "video_url": PREFIX + "video/" + quote(name, safe="")}
        # Sidecar thumbnails survive trash/restore; nginx serves them read-only.
        modified = regular_mtime(self.thumbnail(name))
        if modified is not None:
            entry["thumb_url"] = PREFIX + "thumb/" + quote(name + ".jpg", safe="") + f"?v={modified}"
        return entry

    def thumbnail(self, name):
        return self.thumbs / (filename(name) + ".jpg")

    def require(self, name, trashed=False):
        filename(name)
        path = (self.trash if trashed else self.directory) / name
        if not regular(path):
            raise Problem(404, "Diese Aufnahme wurde nicht gefunden.", "not_found")
        return path

    def listing(self, trashed=False):
        with self.lock:
            records = self.load()
            entries = []
            for path in (self.trash if trashed else self.directory).iterdir():
                try:
                    filename(path.name)
                except Problem:
                    continue
                if regular(path):
                    entries.append(self.entry(path.name, records, trashed))
            return sorted(entries, key=lambda item: (item["title"].casefold(), item["filename"]))

    def edit(self, name, fields):
        if not isinstance(fields, dict) or not fields or set(fields) - {"title", "description"}:
            raise Problem(400, "Bitte Titel oder Beschreibung eingeben.", "invalid_edit")
        changes = {key: text_field(value, 200 if key == "title" else 4000)
                   for key, value in fields.items()}
        if "title" in changes and not changes["title"]:
            raise Problem(400, "Bitte einen Titel eingeben.", "title_required")
        with self.lock:
            self.require(name)
            records = self.load()
            entry = self.entry(name, records)
            records[name] = {key: entry[key] for key in (
                "title", "description", "channel", "recorded", "duration_min", "added")}
            records[name].update(changes)
            self.save(records)
            return self.entry(name, records)

    def move(self, name, restore=False):
        with self.lock:
            source = self.require(name, trashed=restore)
            target = (self.directory if restore else self.trash) / name
            if target.exists() or target.is_symlink():
                raise Problem(409, "Eine Aufnahme mit diesem Dateinamen ist schon vorhanden. Bitte die Betreuung verständigen.",
                              "name_conflict")
            records = self.load()
            if name not in records:
                entry = self.entry(name, records, trashed=restore)
                records[name] = {key: entry[key] for key in (
                    "title", "description", "channel", "recorded", "duration_min", "added")}
                self.save(records)
            source.rename(target)
            sync_directory(self.directory)
            sync_directory(self.trash)
            return self.entry(name, records, trashed=not restore)

    def upload(self, name, stream, length):
        original_name = name
        name = upload_filename(name)
        if length <= 0:
            raise Problem(400, "Die Datei ist leer.", "empty_file")
        temporary = None
        try:
            self.require_upload_space(length)
            descriptor, temporary_name = tempfile.mkstemp(prefix=".upload-", dir=self.directory)
            temporary = Path(temporary_name)
            with os.fdopen(descriptor, "wb") as destination:
                os.fchmod(destination.fileno(), 0o640)
                remaining = length
                while remaining:
                    chunk = stream.read(min(CHUNK_SIZE, remaining))
                    if not chunk:
                        raise Problem(400, "Die Übertragung wurde unterbrochen. Bitte erneut versuchen.",
                                      "transfer_interrupted")
                    # Check every bounded chunk, including changes from concurrent
                    # uploads and other services using this filesystem.
                    self.require_upload_space(remaining)
                    destination.write(chunk)
                    remaining -= len(chunk)
                destination.flush()
                os.fsync(destination.fileno())
            self.require_upload_space(0)
            with self.lock:
                records = self.load()
                reserved = {unicodedata.normalize("NFC", item) for item in records}
                for directory in (self.directory, self.trash):
                    reserved.update(unicodedata.normalize("NFC", path.name) for path in directory.iterdir())
                candidate = name
                while (candidate in reserved or os.path.lexists(self.directory / candidate)
                       or os.path.lexists(self.trash / candidate)):
                    stem = Path(name).stem
                    suffix = f"-{uuid.uuid4().hex[:8]}{Path(name).suffix}"
                    while len((stem + suffix).encode("utf-8")) > 180:
                        stem = stem[:-1]
                    candidate = stem + suffix
                    filename(candidate)
                title = Path(original_name).stem.strip()[:200] or "Aufnahme"
                records[candidate] = {"title": title, "description": "",
                                      "channel": "", "recorded": "", "duration_min": None,
                                      "added": dt.datetime.now(dt.timezone.utc).isoformat()}
                # Save first: a crash may leave an unused metadata key, never an
                # exposed partial upload. link() publishes without overwriting.
                self.save(records)
                # A thumbnail left behind by an administrative purge must not
                # decorate the new recording. Unlinking never follows a symlink.
                stale = self.thumbs / (candidate + ".jpg")
                if stale.is_symlink() or regular(stale):
                    stale.unlink()
                    sync_directory(self.thumbs)
                os.link(temporary, self.directory / candidate)
                sync_directory(self.directory)
                return self.entry(candidate, records)
        except OSError as error:
            if error.errno in {errno.ENOSPC, errno.EDQUOT}:
                self.disk_full()
            raise
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def put_thumbnail(self, name, data):
        """Atomically store a browser-captured JPEG for an active recording."""
        if len(data) > THUMB_MAX_BYTES:
            raise Problem(413, "Das Vorschaubild ist zu groß.", "thumbnail_too_large")
        if len(data) < 6 or not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
            raise Problem(400, "Das Vorschaubild ist kein JPEG-Bild.", "invalid_thumbnail")
        with self.lock:
            self.require(name)
            target = self.thumbnail(name)
            # Sidecars share the recordings' filesystem and its reserve. A
            # replacement briefly needs room for a full temporary copy next to
            # the old file, so require the whole size, not the difference.
            if not self.fits(len(data)):
                print("hsb9-media: thumbnail refused (insufficient disk space)", file=sys.stderr, flush=True)
                raise Problem(507, THUMB_SPACE_ERROR, "insufficient_space")
            temporary = None
            try:
                descriptor, temporary_name = tempfile.mkstemp(prefix=".thumb-", dir=self.thumbs)
                temporary = Path(temporary_name)
                with os.fdopen(descriptor, "wb") as stream:
                    os.fchmod(stream.fileno(), 0o640)
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                # rename() replaces the directory entry; it never follows a symlink.
                os.replace(temporary, target)
                sync_directory(self.thumbs)
            except OSError as error:
                if error.errno in {errno.ENOSPC, errno.EDQUOT}:
                    raise Problem(507, THUMB_SPACE_ERROR, "insufficient_space") from None
                raise
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
            return self.entry(name, self.load())


class Handler(BaseHTTPRequestHandler):
    server_version = "RecordingLibrary"

    def log_message(self, *_args):
        pass  # Request URLs contain private filenames; do not log them.

    def setup(self):
        super().setup()
        self.connection.settimeout(3600)

    def respond(self, status, body, content_type="application/json; charset=utf-8"):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        # blob: media only: the upload page reads the chosen local file to capture a thumbnail.
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; "
                         "media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; "
                         "form-action 'self'")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def content_length(self, maximum=None, code="too_large", message="Die Eingabe ist zu lang."):
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
            raise Problem(411, "Die Länge der Übertragung fehlt oder ist ungültig.", "length_required")
        length = int(lengths[0])
        if maximum is not None and length > maximum:
            raise Problem(413, message, code)
        return length

    def read_body(self, length):
        body = self.rfile.read(length)
        if len(body) != length:
            raise Problem(400, "Die Übertragung wurde unterbrochen.", "transfer_interrupted")
        return body

    def mutate_guard(self):
        host = self.headers.get("Host", "")
        if (not host or self.headers.get("Origin") != "http://" + host
                or self.headers.get("X-Media-Request") != "1"
                or self.headers.get("Sec-Fetch-Site", "same-origin") != "same-origin"):
            raise Problem(403, "Bitte die Seite neu öffnen und erneut versuchen.", "request_refused")

    def dispatch(self):
        library = self.server.library
        request = urlsplit(self.path)
        path = request.path
        if self.command in {"GET", "HEAD"}:
            if path == PREFIX + "api/videos":
                self.respond(200, {"videos": library.listing(request.query == "trash=1"), **library.space()})
            elif path == PREFIX + "healthz":
                self.respond(200, {"ok": True})
            elif path in {PREFIX, PREFIX + "app.js", PREFIX + "app.css"}:
                asset, kind = {PREFIX: ("index.html", "text/html; charset=utf-8"),
                               PREFIX + "app.js": ("app.js", "text/javascript; charset=utf-8"),
                               PREFIX + "app.css": ("app.css", "text/css; charset=utf-8")}[path]
                self.respond(200, (STATIC / asset).read_bytes(), kind)
            else:
                raise Problem(404, "Diese Seite wurde nicht gefunden.", "page_not_found")
            return
        self.mutate_guard()
        if path.startswith(PREFIX + "api/videos/"):
            rest = path[len(PREFIX + "api/videos/"):]
            if rest.endswith("/thumb"):
                encoded = rest[:-len("/thumb")]
                if self.command != "PUT" or "/" in encoded:
                    raise Problem(404, "Diese Seite wurde nicht gefunden.", "page_not_found")
                name = filename(unquote(encoded, errors="strict"))
                length = self.content_length(THUMB_MAX_BYTES, "thumbnail_too_large", "Das Vorschaubild ist zu groß.")
                self.respond(200, library.put_thumbnail(name, self.read_body(length)))
                return
            name = unquote(rest, errors="strict")
            if self.command == "PUT":
                self.respond(201, library.upload(name, self.rfile, self.content_length()))
                return
            filename(name)
            if self.command == "PATCH":
                body = self.read_body(self.content_length(20000))
                try:
                    fields = json.loads(body)
                except (ValueError, UnicodeError):
                    raise Problem(400, "Die Eingabe konnte nicht gelesen werden.", "invalid_json") from None
                self.respond(200, library.edit(name, fields))
                return
            if self.command == "DELETE":
                self.respond(200, library.move(name))
                return
        if self.command == "POST" and path.startswith(PREFIX + "api/restore/"):
            name = filename(unquote(path[len(PREFIX + "api/restore/"):], errors="strict"))
            self.respond(200, library.move(name, restore=True))
            return
        raise Problem(404, "Diese Seite wurde nicht gefunden.", "page_not_found")

    def handle_request(self):
        try:
            self.dispatch()
        except Problem as error:
            self.respond(error.status, error.body())
        except (ValueError, UnicodeError):
            self.respond(400, Problem(400, "Die Eingabe ist ungültig.", "invalid_input").body())
        except (TimeoutError, ConnectionError):
            self.close_connection = True
        except OSError:
            self.respond(503, Problem(503, "Speichern oder Lesen ist gerade nicht möglich. Bitte die Betreuung verständigen.",
                                      "storage_unavailable").body())

    do_GET = do_HEAD = do_PUT = do_PATCH = do_DELETE = do_POST = handle_request


def make_server(directory, address=("0.0.0.0", 8080)):
    server = ThreadingHTTPServer(address, Handler)
    server.library = Library(directory)
    return server


if __name__ == "__main__":
    os.umask(0o027)
    with make_server(DATA_DIR) as httpd:
        httpd.serve_forever()
