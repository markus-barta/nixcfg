"""Run here with python3 -B -m unittest -v. Only synthetic recordings are used."""

import concurrent.futures
import http.client
import io
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import quote

import app


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "data"
        self.library = app.Library(self.directory)
        self.name = "Beispielaufnahme 1.mp4"
        (self.directory / self.name).write_bytes(b"synthetic recording")

    def test_missing_metadata_defaults_and_unicode(self):
        entry, = self.library.listing()
        self.assertEqual(entry["title"], "Beispielaufnahme 1")
        self.assertEqual(entry["description"], "")
        self.assertIsNone(entry["duration_min"])
        self.assertFalse(self.library.metadata.exists())
        self.assertEqual(app.filename("Übung 日本語.m4v"), "Übung 日本語.m4v")
        self.assertEqual(app.filename("Beispielaufnahme.MOV"), "Beispielaufnahme.MOV")

    def test_seeded_metadata_and_edit_preserve_fields(self):
        record = {"title": "Beispielaufnahme 1", "description": "Beispieltext",
                  "channel": "Beispielsender", "recorded": "2026-01-02",
                  "duration_min": 42, "added": "2026-01-03T12:00:00Z"}
        self.library.save({self.name: record})
        entry = self.library.edit(self.name, {"title": "Neuer Beispieltitel", "description": "Neue Beschreibung"})
        self.assertEqual(entry["title"], "Neuer Beispieltitel")
        for field in ("channel", "recorded", "duration_min", "added"):
            self.assertEqual(entry[field], record[field])
        self.assertEqual(self.library.metadata.stat().st_mode & 0o7777, 0o640)

    def test_trash_and_restore_retain_metadata(self):
        self.library.edit(self.name, {"description": "Beispieltext"})
        old = self.library.metadata.read_bytes()
        deleted = self.library.move(self.name)
        self.assertTrue(deleted["trash"])
        self.assertEqual(self.library.listing(), [])
        self.assertEqual(self.library.listing(True)[0]["description"], "Beispieltext")
        self.library.move(self.name, restore=True)
        self.assertEqual(self.library.metadata.read_bytes(), old)
        self.assertEqual((self.directory / self.name).read_bytes(), b"synthetic recording")

    def test_trash_without_metadata_creates_and_keeps_defaults(self):
        before = self.library.listing()[0]
        self.library.move(self.name)
        self.assertIn(self.name, self.library.load())
        self.library.move(self.name, restore=True)
        self.assertEqual(self.library.listing()[0], before)

    def test_restore_conflict_never_overwrites(self):
        self.library.move(self.name)
        (self.directory / self.name).write_bytes(b"another recording")
        with self.assertRaises(app.Problem) as caught:
            self.library.move(self.name, restore=True)
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual((self.directory / self.name).read_bytes(), b"another recording")
        self.assertTrue((self.library.trash / self.name).exists())

    def test_streamed_upload_is_bounded_and_hidden_until_complete(self):
        library = self.library
        test = self
        class GeneratedStream:
            remaining = app.CHUNK_SIZE * 3 + 97
            def read(self, size):
                test.assertGreater(size, 0)
                test.assertLessEqual(size, app.CHUNK_SIZE)
                test.assertFalse((library.directory / "Beispielaufnahme 2.mp4").exists())
                test.assertTrue(list(library.directory.glob(".upload-*")))
                amount = min(size, self.remaining)
                self.remaining -= amount
                return b"a" * amount
        length = GeneratedStream.remaining
        entry = self.library.upload("Beispielaufnahme 2.mp4", GeneratedStream(), length)
        self.assertEqual((self.directory / entry["filename"]).stat().st_size, length)
        self.assertEqual((self.directory / entry["filename"]).stat().st_mode & 0o7777, 0o640)
        self.assertEqual(list(self.directory.glob(".upload-*")), [])

    def test_duplicate_upload_reserves_active_trash_and_retained_metadata_names(self):
        self.library.move(self.name)
        entry = self.library.upload(self.name, io.BytesIO(b"new"), 3)
        self.assertNotEqual(entry["filename"], self.name)
        self.assertEqual((self.library.trash / self.name).read_bytes(), b"synthetic recording")
        duplicate = self.library.upload(entry["filename"], io.BytesIO(b"again"), 5)
        self.assertNotEqual(duplicate["filename"], entry["filename"])
        self.library.move(self.name, restore=True)
        self.assertEqual(len(self.library.listing()), 3)

    def test_truncated_and_failed_upload_leaves_no_visible_file(self):
        for stream in (io.BytesIO(b"short"), io.BytesIO()):
            with self.assertRaises(app.Problem):
                self.library.upload("Beispielaufnahme 2.mov", stream, 10)
        self.assertEqual(len(self.library.listing()), 1)
        self.assertEqual(list(self.directory.glob(".upload-*")), [])
        with self.assertRaises(app.Problem):
            self.library.upload("Beispielaufnahme 2.mp4", io.BytesIO(), 0)

    def test_maximum_length_unicode_duplicate_stays_within_filename_limit(self):
        name = "ü" * 88 + ".mp4"
        self.assertEqual(len(name.encode("utf-8")), 180)
        first = self.library.upload(name, io.BytesIO(b"a"), 1)
        second = self.library.upload(name, io.BytesIO(b"b"), 1)
        self.assertNotEqual(first["filename"], second["filename"])
        self.assertLessEqual(len(second["filename"].encode("utf-8")), 180)

    def test_reject_invalid_names_and_paths(self):
        for name in ("../Beispiel.mp4", ".hidden.mp4", "sub/Beispiel.mp4", "sub\\Beispiel.mp4",
                     "Beispiel.mp4\n", " Beispiel.mp4", "Beispiel..mp4", "Beispiel.mp3",
                     "Beispiel\x00.mp4", "Beispiel\u202e.mp4", "a" * 181 + ".mp4", ""):
            with self.subTest(name=name), self.assertRaises(app.Problem):
                app.filename(name)

    def test_no_symlinks_listed_or_modified(self):
        outside = Path(self.temporary.name) / "outside.mp4"
        outside.write_bytes(b"outside")
        name = "Beispielaufnahme 2.mp4"
        (self.directory / name).symlink_to(outside)
        self.assertEqual(len(self.library.listing()), 1)
        with self.assertRaises(app.Problem):
            self.library.edit(name, {"title": "Beispiel"})
        with self.assertRaises(app.Problem):
            self.library.move(name)
        self.assertEqual(outside.read_bytes(), b"outside")

    def test_length_limits_and_invalid_fields(self):
        for fields in ({"title": "x" * 201}, {"description": "x" * 4001}, {"title": " "},
                       {"title": []}, {"title": "bad\x00"}, {"channel": "Beispiel"}, [], {}):
            with self.subTest(fields=fields), self.assertRaises(app.Problem):
                self.library.edit(self.name, fields)

    def test_atomic_write_failure_preserves_metadata(self):
        self.library.edit(self.name, {"title": "Beispiel"})
        original = self.library.metadata.read_bytes()
        with mock.patch.object(app.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                self.library.edit(self.name, {"title": "Änderung"})
        self.assertEqual(self.library.metadata.read_bytes(), original)
        self.assertEqual(list(self.directory.glob(".metadata-*")), [])

    def test_concurrent_edits_merge_fields_and_readers_never_see_partial_json(self):
        self.library.edit(self.name, {"title": "Beispiel"})
        stop = threading.Event()
        errors = []
        def read_json():
            while not stop.is_set():
                try:
                    json.loads(self.library.metadata.read_text())
                except Exception as error:
                    errors.append(error)
        reader = threading.Thread(target=read_json)
        reader.start()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                futures = [executor.submit(self.library.edit, self.name, {
                    "title" if number % 2 else "description": "Beispiel " + str(number)
                }) for number in range(40)]
                for future in futures:
                    future.result()
        finally:
            stop.set()
            reader.join()
        self.assertEqual(errors, [])
        record = self.library.load()[self.name]
        self.assertTrue(record["title"].startswith("Beispiel "))
        self.assertTrue(record["description"].startswith("Beispiel "))

    def test_corrupt_metadata_fails_closed(self):
        for data in ("{broken", "[]", '{"Beispiel.mp4":{"title":12}}',
                     '{"../Beispiel.mp4":{}}', '{"Beispiel.mp4":{"duration_min":NaN}}'):
            self.library.metadata.write_text(data)
            with self.subTest(data=data), self.assertRaises(app.Problem):
                self.library.edit(self.name, {"title": "Beispiel"})
            self.assertEqual(self.library.metadata.read_text(), data)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.server = SimpleNamespace(library=app.Library(cls.temporary.name))
        cls.host = "localhost:8080"

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def raw_request(self, payload):
        # Run the real HTTP parser/handler over an in-memory socket. This works
        # in macOS sandboxes which refuse bind(), without skipping HTTP checks.
        class Socket:
            def __init__(self):
                self.output = bytearray()
            def makefile(self, *_args):
                return io.BytesIO(payload)
            def sendall(self, data):
                self.output.extend(data)
            def settimeout(self, _timeout):
                pass
        sock = Socket()
        app.Handler(sock, ("127.0.0.1", 12345), self.server)
        response_socket = SimpleNamespace(makefile=lambda *_args: io.BytesIO(sock.output))
        return response_socket

    def call(self, method, path="api/videos", body=None, headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        body = body or b""
        headers = {"Host": self.host, "Content-Length": str(len(body)), **(headers or {})}
        payload = f"{method} {app.PREFIX + path} HTTP/1.1\r\n"
        payload += "".join(f"{key}: {value}\r\n" for key, value in headers.items())
        response = http.client.HTTPResponse(self.raw_request(payload.encode("ascii") + b"\r\n" + body), method=method)
        response.begin()
        return response.status, dict(response.getheaders()), response.read()

    def mutation_headers(self):
        return {"Origin": "http://" + self.host, "X-Media-Request": "1"}

    def test_http_crud_and_streamed_put(self):
        name = quote("HTTP Beispielaufnahme.mp4")
        headers = self.mutation_headers()
        status, _, body = self.call("PUT", "api/videos/" + name, b"synthetic", headers)
        self.assertEqual(status, 201)
        record = json.loads(body)
        status, _, _ = self.call("PATCH", "api/videos/" + name, json.dumps({"title": "Beispielaufnahme 1"}), headers)
        self.assertEqual(status, 200)
        status, _, body = self.call("GET")
        self.assertEqual(status, 200)
        self.assertIn(record["filename"], [v["filename"] for v in json.loads(body)["videos"]])
        self.assertEqual(self.call("DELETE", "api/videos/" + name, headers=headers)[0], 200)
        _, _, body = self.call("GET", "api/videos?trash=1")
        self.assertIn(record["filename"], [v["filename"] for v in json.loads(body)["videos"]])
        self.assertEqual(self.call("POST", "api/restore/" + name, headers=headers)[0], 200)

    def test_guard_rejects_missing_cross_origin_null_and_cross_site_requests(self):
        for headers in ({}, {"X-Media-Request": "1"}, {"Origin": "http://" + self.host},
                        {"Origin": "http://example.invalid", "X-Media-Request": "1"},
                        {"Origin": "null", "X-Media-Request": "1"},
                        {**self.mutation_headers(), "Sec-Fetch-Site": "cross-site"}):
            for method in ("PUT", "PATCH", "DELETE", "POST"):
                with self.subTest(headers=headers, method=method):
                    self.assertEqual(self.call(method, "api/videos/Beispiel.mp4", b"a", headers)[0], 403)

    def test_encoded_traversal_and_bad_names(self):
        for name in ("%2e%2e%2fBeispiel.mp4", "%2Ehidden.mp4", "sub%2FBeispiel.mp4",
                     "sub%5CBeispiel.mp4", "Beispiel%00.mp4", "Beispiel%FF.mp4", "Beispiel.txt"):
            with self.subTest(name=name):
                self.assertEqual(self.call("PUT", "api/videos/" + name, b"a", self.mutation_headers())[0], 400)

    def test_invalid_json_and_oversized_edit(self):
        self.assertEqual(self.call("PATCH", "api/videos/Beispiel.mp4", b"{broken", self.mutation_headers())[0], 400)
        self.assertEqual(self.call("PATCH", "api/videos/Beispiel.mp4", b"a" * 20001, self.mutation_headers())[0], 413)

    def test_chunked_or_ambiguous_lengths_rejected(self):
        headers = {**self.mutation_headers(), "Transfer-Encoding": "chunked"}
        self.assertEqual(self.call("PUT", "api/videos/Beispiel.mp4", b"0\r\n\r\n", headers)[0], 411)
        payload = ("PUT /fernsehen/api/videos/Beispiel.mp4 HTTP/1.1\r\n"
                   f"Host: {self.host}\r\nOrigin: http://{self.host}\r\nX-Media-Request: 1\r\n"
                   "Content-Length: 1\r\nContent-Length: 2\r\n\r\naa").encode("ascii")
        response = http.client.HTTPResponse(self.raw_request(payload))
        response.begin()
        self.assertEqual(response.status, 411)
        response.read()

    def test_assets_head_and_private_files_not_served(self):
        for asset in ("", "app.js", "app.css", "healthz"):
            status, headers, body = self.call("GET", asset)
            self.assertEqual(status, 200)
            self.assertGreater(len(body), 0)
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        status, _, body = self.call("HEAD", "")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        for path in ("metadata.json", ".trash/Beispiel.mp4", "../app.py", "video/Beispiel.mp4"):
            self.assertEqual(self.call("GET", path)[0], 404)


if __name__ == "__main__":
    unittest.main()
