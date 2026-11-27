"""Run here with python3 -B -m unittest -v. Only synthetic recordings are used."""

import ast
import concurrent.futures
import errno
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
import unicodedata

import app


def filesystem(free=100 * 1024 ** 3, total=500 * 1024 ** 3):
    return SimpleNamespace(f_bavail=free, f_blocks=total, f_frsize=1)


# Smallest byte pattern the thumbnail check accepts: SOI marker ... EOI marker.
JPEG = b"\xff\xd8\xff\xe0" + b"synthetic thumbnail" + b"\xff\xd9"


class LibraryTests(unittest.TestCase):
    def setUp(self):
        # Tests must not depend on workstation free space or operator overrides.
        usage = mock.patch.object(app.os, "statvfs", return_value=filesystem())
        self.usage = usage.start()
        self.addCleanup(usage.stop)
        environment = mock.patch.dict(app.os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        app.os.environ.pop("MEDIA_RESERVE_BYTES", None)
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

    def test_free_space_reserve_default_and_override(self):
        self.assertEqual(self.library.space(), {"free_bytes": 100 * 1024 ** 3,
                                               "reserve_bytes": 50 * 1024 ** 3})
        self.usage.return_value = filesystem(total=100 * 1024 ** 3)
        self.assertEqual(self.library.space()["reserve_bytes"], 20 * 1024 ** 3)
        with mock.patch.dict(app.os.environ, {"MEDIA_RESERVE_BYTES": "12345"}):
            self.assertEqual(app.Library(self.directory).space()["reserve_bytes"], 12345)
        with mock.patch.dict(app.os.environ, {"MEDIA_RESERVE_BYTES": "-1"}):
            with self.assertRaises(ValueError):
                app.Library(self.directory)

    def test_insufficient_space_refuses_before_temp_creation_or_streaming(self):
        self.usage.return_value = filesystem(free=50 * 1024 ** 3)
        stream = mock.Mock()
        with mock.patch.object(app.tempfile, "mkstemp") as create, mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaises(app.Problem) as caught:
                self.library.upload("Beispielaufnahme 2.mp4", stream, 1)
        self.assertEqual(caught.exception.status, 507)
        self.assertEqual(caught.exception.message, app.SPACE_ERROR)
        create.assert_not_called()
        stream.read.assert_not_called()
        self.assertEqual(len(log.getvalue().splitlines()), 1)
        self.assertNotIn("Beispielaufnahme", log.getvalue())
        self.assertEqual(list(self.directory.glob(".upload-*")), [])

    def test_space_drop_during_stream_aborts_and_removes_temp(self):
        reserve = 50 * 1024 ** 3
        self.usage.side_effect = [filesystem(free=reserve + 8), filesystem(free=reserve + 8),
                                  filesystem(free=reserve + 3)]
        with mock.patch.object(app, "CHUNK_SIZE", 4), mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaises(app.Problem) as caught:
                self.library.upload("Beispielaufnahme 2.mp4", io.BytesIO(b"12345678"), 8)
        self.assertEqual(caught.exception.status, 507)
        self.assertEqual(len(log.getvalue().splitlines()), 1)
        self.assertFalse((self.directory / "Beispielaufnahme 2.mp4").exists())
        self.assertEqual(list(self.directory.glob(".upload-*")), [])
        self.assertFalse(self.library.metadata.exists())

    def test_enospc_during_write_returns_507_and_removes_temp(self):
        class FullDisk(io.BufferedWriter):
            def write(self, _data):
                raise OSError(errno.ENOSPC, "synthetic disk full")
        def full_disk(descriptor, _mode):
            return FullDisk(io.FileIO(descriptor, "wb"))
        with mock.patch.object(app.os, "fdopen", side_effect=full_disk), mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaises(app.Problem) as caught:
                self.library.upload("Beispielaufnahme 2.mp4", io.BytesIO(b"data"), 4)
        self.assertEqual(caught.exception.status, 507)
        self.assertEqual(len(log.getvalue().splitlines()), 1)
        self.assertEqual(list(self.directory.glob(".upload-*")), [])
        self.assertFalse((self.directory / "Beispielaufnahme 2.mp4").exists())

    def test_enospc_creating_temp_returns_507(self):
        with mock.patch.object(app.tempfile, "mkstemp", side_effect=OSError(errno.ENOSPC, "synthetic")), mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaises(app.Problem) as caught:
                self.library.upload("Beispielaufnahme 2.mp4", io.BytesIO(b"data"), 4)
        self.assertEqual(caught.exception.status, 507)
        self.assertEqual(len(log.getvalue().splitlines()), 1)
        self.assertEqual(list(self.directory.glob(".upload-*")), [])

    def test_mid_stream_connection_reset_removes_temp(self):
        stream = mock.Mock()
        stream.read.side_effect = [b"1234", ConnectionResetError("synthetic reset")]
        with mock.patch.object(app, "CHUNK_SIZE", 4), self.assertRaises(ConnectionResetError):
            self.library.upload("Beispielaufnahme 2.mp4", stream, 8)
        self.assertEqual(stream.read.call_count, 2)
        self.assertEqual(list(self.directory.glob(".upload-*")), [])
        self.assertFalse((self.directory / "Beispielaufnahme 2.mp4").exists())
        self.assertFalse(self.library.metadata.exists())

    def test_startup_cleans_only_regular_app_temporaries(self):
        for name in (".upload-abandoned", ".metadata-abandoned", ".staging-admin-1"):
            (self.directory / name).write_bytes(b"synthetic")
        outside = Path(self.temporary.name) / "outside"
        outside.write_bytes(b"preserved")
        (self.directory / ".upload-link").symlink_to(outside)
        (self.directory / ".metadata-directory").mkdir()
        (self.library.trash / ".upload-preserved").write_bytes(b"preserved")
        self.library.save({self.name: {"title": "Beispielaufnahme 1"}})
        app.Library(self.directory)
        self.assertFalse((self.directory / ".upload-abandoned").exists())
        self.assertFalse((self.directory / ".metadata-abandoned").exists())
        self.assertTrue((self.directory / ".staging-admin-1").is_file())
        self.assertTrue((self.directory / ".upload-link").is_symlink())
        self.assertTrue((self.directory / ".metadata-directory").is_dir())
        self.assertTrue((self.library.trash / ".upload-preserved").is_file())
        self.assertEqual(outside.read_bytes(), b"preserved")
        self.assertEqual(len(self.library.listing()), 1)
        self.assertEqual(self.library.load()[self.name]["title"], "Beispielaufnahme 1")

    def test_upload_sanitizer_and_original_title(self):
        for original, expected in ((" .Beispiel..aufnahme.mp4 ", "Beispiel.aufnahme.mp4"),
                                   ("... Beispielaufnahme.MOV", "Beispielaufnahme.MOV"),
                                   (". \u00a0.Beispielaufnahme.mp4", "Beispielaufnahme.mp4"),
                                   ("a...b.m4v", "a.b.m4v"),
                                   ("Folge 3..mp4", "Folge 3.mp4"),
                                   ("Fortsetzung folgt....mp4", "Fortsetzung folgt.mp4"),
                                   ("Tatort. .mp4", "Tatort.mp4"),
                                   ("ü" * 87 + "a.Fortsetzung.mp4", "ü" * 87 + "a.mp4"),
                                   ("ü" * 200 + ".mp4", "ü" * 88 + ".mp4")):
            with self.subTest(original=original):
                self.assertEqual(app.upload_filename(original), expected)
        for original in ("...mp4", "....mp4"):
            with self.subTest(original=original):
                generated = app.upload_filename(original)
                self.assertRegex(generated, r"^[a-f0-9]{32}\.mp4$")
        original = " .Beispiel..aufnahme.mp4"
        uploaded = self.library.upload(original, io.BytesIO(b"a"), 1)
        self.assertEqual(uploaded["filename"], "Beispiel.aufnahme.mp4")
        self.assertEqual(uploaded["title"], " .Beispiel..aufnahme".strip())
        underscored = self.library.upload("Beispiel_Aufnahme.mp4", io.BytesIO(b"a"), 1)
        self.assertEqual(underscored["title"], "Beispiel_Aufnahme")
        # A title also remains within the metadata limit after a long-name upload.
        long = self.library.upload("ü" * 250 + ".mp4", io.BytesIO(b"a"), 1)
        self.assertEqual(len(long["title"]), 200)
        self.library.load()

    def test_nfc_nfd_upload_collisions_never_overwrite(self):
        nfc = "Übung.mp4"
        nfd = unicodedata.normalize("NFD", nfc)
        first = self.library.upload(nfd, io.BytesIO(b"a"), 1)
        second = self.library.upload(nfc, io.BytesIO(b"b"), 1)
        self.assertEqual(first["filename"], nfc)
        self.assertNotEqual(first["filename"], second["filename"])
        self.assertEqual((self.directory / nfc).read_bytes(), b"a")
        # Existing files installed over SSH may still have decomposed names.
        seeded = unicodedata.normalize("NFD", "Übung 2.mp4")
        (self.library.trash / seeded).write_bytes(b"original")
        third = self.library.upload("Übung 2.mp4", io.BytesIO(b"c"), 1)
        self.assertNotEqual(third["filename"], "Übung 2.mp4")
        self.assertEqual((self.library.trash / seeded).read_bytes(), b"original")

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

    def test_data_directories_are_created_0750_or_narrower(self):
        # The service runs with umask 0027; a fallback mkdir never widens 0750.
        for mask, expected in ((0o027, 0o750), (0o022, 0o750), (0o000, 0o750), (0o077, 0o700)):
            directory = Path(self.temporary.name) / f"umask-{mask:03o}"
            previous = app.os.umask(mask)
            try:
                library = app.Library(directory)
            finally:
                app.os.umask(previous)
            for path in (library.trash, library.thumbs):
                with self.subTest(umask=oct(mask), path=path.name):
                    self.assertTrue(path.is_dir())
                    self.assertEqual(path.stat().st_mode & 0o777, expected)
        # Directories the host already created (tmpfiles) keep their mode.
        existing = Path(self.temporary.name) / "existing"
        (existing / ".thumbs").mkdir(parents=True, mode=0o700)
        (existing / ".thumbs").chmod(0o700)
        app.Library(existing)
        self.assertEqual((existing / ".thumbs").stat().st_mode & 0o777, 0o700)

    def test_thumb_url_only_for_regular_sidecar_files(self):
        self.assertTrue(self.library.thumbs.is_dir())
        entry, = self.library.listing()
        self.assertNotIn("thumb_url", entry)
        thumb = self.library.thumbs / (self.name + ".jpg")
        thumb.write_bytes(JPEG)
        entry, = self.library.listing()
        prefix = "/fernsehen/thumb/" + quote(self.name + ".jpg", safe="") + "?v="
        self.assertTrue(entry["thumb_url"].startswith(prefix), entry["thumb_url"])
        self.assertEqual(entry["thumb_url"][len(prefix):], str(thumb.lstat().st_mtime_ns))
        # Trash and restore keep the sidecar thumbnail.
        self.assertIn("thumb_url", self.library.move(self.name))
        self.assertIn("thumb_url", self.library.listing(True)[0])
        self.library.move(self.name, restore=True)
        self.assertTrue(thumb.is_file())
        self.assertIn("thumb_url", self.library.listing()[0])

    def test_symlinked_or_directory_thumbs_are_ignored(self):
        outside = Path(self.temporary.name) / "outside.jpg"
        outside.write_bytes(JPEG)
        (self.library.thumbs / (self.name + ".jpg")).symlink_to(outside)
        self.assertNotIn("thumb_url", self.library.listing()[0])
        second = "Beispielaufnahme 2.mp4"
        (self.directory / second).write_bytes(b"synthetic")
        (self.library.thumbs / (second + ".jpg")).mkdir()
        self.assertTrue(all("thumb_url" not in entry for entry in self.library.listing()))

    def test_thumbs_directory_symlink_is_refused(self):
        other = Path(self.temporary.name) / "other"
        other.mkdir()
        (other / ".trash").mkdir()
        (other / ".thumbs").symlink_to(Path(self.temporary.name))
        with self.assertRaises(ValueError):
            app.Library(other)

    def test_put_thumbnail_validation(self):
        for data, status, code in ((b"not a jpeg", 400, "invalid_thumbnail"),
                                   (b"\xff\xd8\xff\xe0 truncated", 400, "invalid_thumbnail"),
                                   (b"\x89PNG\r\n\xff\xd9", 400, "invalid_thumbnail"),
                                   (b"", 400, "invalid_thumbnail"),
                                   (b"\xff\xd8\xff" + b"a" * app.THUMB_MAX_BYTES + b"\xff\xd9", 413,
                                    "thumbnail_too_large")):
            with self.subTest(data=data[:12]), self.assertRaises(app.Problem) as caught:
                self.library.put_thumbnail(self.name, data)
            self.assertEqual((caught.exception.status, caught.exception.code), (status, code))
        with self.assertRaises(app.Problem) as caught:
            self.library.put_thumbnail("Fehlt.mp4", JPEG)
        self.assertEqual((caught.exception.status, caught.exception.code), (404, "not_found"))
        self.library.move(self.name)
        with self.assertRaises(app.Problem) as caught:
            self.library.put_thumbnail(self.name, JPEG)
        self.assertEqual((caught.exception.status, caught.exception.code), (404, "not_found"))
        with self.assertRaises(app.Problem) as caught:
            self.library.put_thumbnail("../Beispiel.mp4", JPEG)
        self.assertEqual(caught.exception.code, "invalid_name")
        self.assertEqual(list(self.library.thumbs.iterdir()), [])

    def test_put_thumbnail_is_atomic_with_mode_0640(self):
        entry = self.library.put_thumbnail(self.name, JPEG)
        thumb = self.library.thumbs / (self.name + ".jpg")
        self.assertEqual(thumb.read_bytes(), JPEG)
        self.assertEqual(thumb.stat().st_mode & 0o7777, 0o640)
        self.assertIn("thumb_url", entry)
        with mock.patch.object(app.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                self.library.put_thumbnail(self.name, JPEG[:-2] + b"new\xff\xd9")
        self.assertEqual(thumb.read_bytes(), JPEG)
        self.assertEqual(list(self.library.thumbs.glob(".thumb-*")), [])
        replacement = JPEG[:-2] + b"replacement\xff\xd9"
        self.library.put_thumbnail(self.name, replacement)
        self.assertEqual(thumb.read_bytes(), replacement)
        # A symlink at the target is replaced as an entry, never written through.
        outside = Path(self.temporary.name) / "outside.jpg"
        outside.write_bytes(b"preserved")
        thumb.unlink()
        thumb.symlink_to(outside)
        self.library.put_thumbnail(self.name, JPEG)
        self.assertFalse(thumb.is_symlink())
        self.assertEqual(outside.read_bytes(), b"preserved")

    def test_put_thumbnail_respects_the_free_space_reserve(self):
        reserve = 50 * 1024 ** 3
        thumb = self.library.thumbs / (self.name + ".jpg")
        # Exactly enough room above the reserve: stored.
        self.usage.return_value = filesystem(free=reserve + len(JPEG))
        self.library.put_thumbnail(self.name, JPEG)
        self.assertEqual(thumb.read_bytes(), JPEG)
        # One byte short: refused before any temporary file exists. A
        # replacement needs room for a full copy, even if it is the same size.
        replacement = JPEG[:-2] + b"new\xff\xd9"
        for free in (reserve + len(replacement) - 1, reserve, 0):
            self.usage.return_value = filesystem(free=free)
            with self.subTest(free=free), mock.patch.object(app.tempfile, "mkstemp") as create, \
                    mock.patch("sys.stderr", new_callable=io.StringIO) as log:
                with self.assertRaises(app.Problem) as caught:
                    self.library.put_thumbnail(self.name, replacement)
                create.assert_not_called()
            self.assertEqual((caught.exception.status, caught.exception.code), (507, "insufficient_space"))
            self.assertEqual(caught.exception.message, app.THUMB_SPACE_ERROR)
            self.assertEqual(len(log.getvalue().splitlines()), 1)
            self.assertNotIn("Beispielaufnahme", log.getvalue())
            self.assertEqual(thumb.read_bytes(), JPEG, "the existing thumbnail stays")
            self.assertEqual(list(self.library.thumbs.glob(".thumb-*")), [])
        # The same boundary applies to a first thumbnail, and an operator
        # override of the reserve is honoured.
        second = "Beispielaufnahme 2.mp4"
        (self.directory / second).write_bytes(b"synthetic")
        self.usage.return_value = filesystem(free=reserve + len(JPEG) - 1)
        with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(app.Problem):
            self.library.put_thumbnail(second, JPEG)
        self.assertFalse((self.library.thumbs / (second + ".jpg")).exists())
        with mock.patch.dict(app.os.environ, {"MEDIA_RESERVE_BYTES": "0"}):
            relaxed = app.Library(self.directory)
        self.usage.return_value = filesystem(free=len(JPEG))
        self.assertIn("thumb_url", relaxed.put_thumbnail(second, JPEG))

    def test_put_thumbnail_disk_full_returns_507(self):
        with mock.patch.object(app.tempfile, "mkstemp", side_effect=OSError(errno.ENOSPC, "synthetic")):
            with self.assertRaises(app.Problem) as caught:
                self.library.put_thumbnail(self.name, JPEG)
        self.assertEqual((caught.exception.status, caught.exception.code), (507, "insufficient_space"))

    def test_startup_cleans_only_regular_thumbnail_temporaries(self):
        thumbs = self.library.thumbs
        (thumbs / ".thumb-abandoned").write_bytes(b"synthetic")
        (thumbs / ".staging-admin-1.jpg").write_bytes(b"synthetic")
        outside = Path(self.temporary.name) / "outside"
        outside.write_bytes(b"preserved")
        (thumbs / ".thumb-link").symlink_to(outside)
        (thumbs / ".thumb-directory").mkdir()
        (thumbs / (self.name + ".jpg")).write_bytes(JPEG)
        app.Library(self.directory)
        self.assertFalse((thumbs / ".thumb-abandoned").exists())
        self.assertTrue((thumbs / ".staging-admin-1.jpg").is_file())
        self.assertTrue((thumbs / ".thumb-link").is_symlink())
        self.assertTrue((thumbs / ".thumb-directory").is_dir())
        self.assertEqual((thumbs / (self.name + ".jpg")).read_bytes(), JPEG)
        self.assertEqual(outside.read_bytes(), b"preserved")

    def test_upload_removes_stale_thumbnail_for_its_final_name(self):
        name = "Beispielaufnahme 3.mp4"
        stale = self.library.thumbs / (name + ".jpg")
        stale.write_bytes(JPEG)
        outside = Path(self.temporary.name) / "outside.jpg"
        outside.write_bytes(b"preserved")
        linked = self.library.thumbs / ("Beispielaufnahme 4.mp4" + ".jpg")
        linked.symlink_to(outside)
        kept = self.library.thumbs / (self.name + ".jpg")
        kept.write_bytes(JPEG)
        entry = self.library.upload(name, io.BytesIO(b"new"), 3)
        self.assertEqual(entry["filename"], name)
        self.assertNotIn("thumb_url", entry)
        self.assertFalse(stale.exists())
        self.library.upload("Beispielaufnahme 4.mp4", io.BytesIO(b"new"), 3)
        self.assertFalse(linked.is_symlink())
        self.assertEqual(outside.read_bytes(), b"preserved")
        # A duplicate upload gets a new name and leaves the original's thumbnail alone.
        duplicate = self.library.upload(self.name, io.BytesIO(b"dup"), 3)
        self.assertNotEqual(duplicate["filename"], self.name)
        self.assertEqual(kept.read_bytes(), JPEG)

    def test_problems_carry_stable_codes(self):
        cases = (
            (lambda: app.filename("../x.mp4"), 400, "invalid_name"),
            (lambda: app.upload_filename("a/b.mp4"), 400, "invalid_name"),
            (lambda: app.upload_filename("Beispiel.txt"), 400, "unsupported_type"),
            (lambda: app.text_field("x" * 201, 200), 400, "invalid_text"),
            (lambda: self.library.require("Fehlt.mp4"), 404, "not_found"),
            (lambda: self.library.edit(self.name, {}), 400, "invalid_edit"),
            (lambda: self.library.edit(self.name, {"title": " "}), 400, "title_required"),
            (lambda: self.library.upload("Beispiel.mp4", io.BytesIO(), 0), 400, "empty_file"),
            (lambda: self.library.upload("Beispiel.mp4", io.BytesIO(b"a"), 2), 400, "transfer_interrupted"),
            (lambda: self.library.put_thumbnail(self.name, b"x"), 400, "invalid_thumbnail"),
        )
        for call, status, code in cases:
            with self.subTest(code=code), self.assertRaises(app.Problem) as caught:
                call()
            self.assertEqual((caught.exception.status, caught.exception.code), (status, code))
            self.assertEqual(caught.exception.body()["code"], code)
            self.assertTrue(caught.exception.body()["error"])
        with self.assertRaises(app.Problem) as caught:
            app.text_field("x" * 201, 200)
        self.assertEqual(caught.exception.body()["limit"], 200)
        self.library.move(self.name)
        (self.directory / self.name).write_bytes(b"conflict")
        with self.assertRaises(app.Problem) as caught:
            self.library.move(self.name, restore=True)
        self.assertEqual(caught.exception.code, "name_conflict")
        self.library.metadata.write_text("{broken")
        with self.assertRaises(app.Problem) as caught:
            self.library.load()
        self.assertEqual((caught.exception.status, caught.exception.code), (503, "metadata_unreadable"))
        self.usage.return_value = filesystem(free=0)
        with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(app.Problem) as caught:
            self.library.upload("Beispiel.mp4", io.BytesIO(b"a"), 1)
        self.assertEqual((caught.exception.status, caught.exception.code), (507, "insufficient_space"))

    def test_every_problem_construction_names_a_snake_case_code(self):
        tree = ast.parse(Path(app.__file__).read_text(encoding="utf-8"))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == "Problem"]
        self.assertGreater(len(calls), 20)
        for call in calls:
            with self.subTest(line=call.lineno):
                self.assertGreaterEqual(len(call.args), 3)
                code = call.args[2]
                if isinstance(code, ast.Constant):
                    self.assertRegex(code.value, r"^[a-z]+(?:_[a-z]+)*$")
                else:
                    self.assertIsInstance(code, ast.Name)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        environment = mock.patch.dict(app.os.environ)
        environment.start()
        cls.addClassCleanup(environment.stop)
        app.os.environ.pop("MEDIA_RESERVE_BYTES", None)
        cls.usage = mock.patch.object(app.os, "statvfs", return_value=filesystem())
        cls.usage.start()
        cls.addClassCleanup(cls.usage.stop)
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
        for name in ("%2e%2e%2fBeispiel.mp4", "sub%2FBeispiel.mp4",
                     "sub%5CBeispiel.mp4", "Beispiel%00.mp4", "Beispiel%FF.mp4", "Beispiel.txt"):
            with self.subTest(name=name):
                self.assertEqual(self.call("PUT", "api/videos/" + name, b"a", self.mutation_headers())[0], 400)

    def test_http_upload_sanitizes_but_other_routes_remain_strict(self):
        name = quote(" .HTTP Beispiel..aufnahme.mp4")
        status, _, body = self.call("PUT", "api/videos/" + name, b"a", self.mutation_headers())
        self.assertEqual(status, 201)
        self.assertEqual(json.loads(body)["filename"], "HTTP Beispiel.aufnahme.mp4")
        for path, method in (("api/videos/", "PATCH"), ("api/videos/", "DELETE"), ("api/restore/", "POST")):
            for invalid in (name, "%2Ehidden.mp4", "Beispiel..mp4",
                            quote("Folge 3..mp4"), quote("Fortsetzung folgt....mp4"),
                            "....mp4"):
                self.assertEqual(self.call(method, path + invalid, b"{}", self.mutation_headers())[0], 400)

    def test_http_space_info_and_507(self):
        with mock.patch.object(app.os, "statvfs", return_value=filesystem(free=0)), mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            status, _, body = self.call("GET")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["free_bytes"], 0)
            self.assertEqual(json.loads(body)["reserve_bytes"], 50 * 1024 ** 3)
            status, _, body = self.call("PUT", "api/videos/Platz.mp4", b"a", self.mutation_headers())
        self.assertEqual(status, 507)
        self.assertEqual(json.loads(body)["error"], app.SPACE_ERROR)
        self.assertEqual(len(log.getvalue().splitlines()), 1)

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

    def test_put_thumbnail_over_http(self):
        library = self.server.library
        name = "HTTP Vorschau.mp4"
        (Path(library.directory) / name).write_bytes(b"synthetic")
        self.addCleanup(lambda: (Path(library.directory) / name).unlink(missing_ok=True))
        self.addCleanup(lambda: library.thumbnail(name).unlink(missing_ok=True))
        path = "api/videos/" + quote(name) + "/thumb"
        headers = {**self.mutation_headers(), "Content-Type": "image/jpeg"}
        for bad in ({}, {"X-Media-Request": "1"}, {"Origin": "http://" + self.host},
                    {**self.mutation_headers(), "Sec-Fetch-Site": "cross-site"}):
            status, _, body = self.call("PUT", path, JPEG, bad)
            self.assertEqual((status, json.loads(body)["code"]), (403, "request_refused"))
        status, _, body = self.call("PUT", "api/videos/" + quote("Fehlt.mp4") + "/thumb", JPEG, headers)
        self.assertEqual((status, json.loads(body)["code"]), (404, "not_found"))
        status, _, body = self.call("PUT", path, b"not a jpeg", headers)
        self.assertEqual((status, json.loads(body)["code"]), (400, "invalid_thumbnail"))
        status, _, body = self.call("PUT", path, b"\xff" * (app.THUMB_MAX_BYTES + 1), headers)
        self.assertEqual((status, json.loads(body)["code"]), (413, "thumbnail_too_large"))
        for other in ("PATCH", "DELETE", "POST"):
            status, _, body = self.call(other, path, JPEG, headers)
            self.assertEqual((status, json.loads(body)["code"]), (404, "page_not_found"))
        for invalid in ("%2e%2e%2fBeispiel.mp4/thumb", "a/b.mp4/thumb", "sub%2FBeispiel.mp4/thumb"):
            status, _, _ = self.call("PUT", "api/videos/" + invalid, JPEG, headers)
            self.assertIn(status, {400, 404})
        self.assertFalse(library.thumbnail(name).exists())
        status, _, body = self.call("PUT", path, JPEG, headers)
        self.assertEqual(status, 200)
        self.assertIn("/fernsehen/thumb/" + quote(name + ".jpg", safe="") + "?v=", json.loads(body)["thumb_url"])
        self.assertEqual(library.thumbnail(name).read_bytes(), JPEG)
        status, _, body = self.call("DELETE", "api/videos/" + quote(name), headers=self.mutation_headers())
        self.assertEqual(status, 200)
        status, _, body = self.call("PUT", path, JPEG, headers)
        self.assertEqual((status, json.loads(body)["code"]), (404, "not_found"))
        self.call("POST", "api/restore/" + quote(name), headers=self.mutation_headers())

    def test_http_problem_responses_carry_codes(self):
        cases = (
            (("GET", "nichts"), 404, "page_not_found"),
            (("PATCH", "api/videos/Fehlt.mp4", b"{}", self.mutation_headers()), 400, "invalid_edit"),
            (("PATCH", "api/videos/Fehlt.mp4", b'{"title":"x"}', self.mutation_headers()), 404, "not_found"),
            (("PATCH", "api/videos/Beispiel.mp4", b"{broken", self.mutation_headers()), 400, "invalid_json"),
            (("PATCH", "api/videos/Beispiel.mp4", b"a" * 20001, self.mutation_headers()), 413, "too_large"),
            (("PUT", "api/videos/Beispiel.txt", b"a", self.mutation_headers()), 400, "unsupported_type"),
            (("PUT", "api/videos/Beispiel.mp4", b"", self.mutation_headers()), 400, "empty_file"),
            (("PUT", "api/videos/%2e%2e%2fBeispiel.mp4", b"a", self.mutation_headers()), 400, "invalid_name"),
            (("PUT", "api/videos/Beispiel%FF.mp4", b"a", self.mutation_headers()), 400, "invalid_input"),
            (("POST", "api/restore/Fehlt.mp4", b"", self.mutation_headers()), 404, "not_found"),
            (("DELETE", "api/videos/Beispiel.mp4", b"", {}), 403, "request_refused"),
            (("POST", "api/unbekannt", b"", self.mutation_headers()), 404, "page_not_found"),
        )
        for args, status, code in cases:
            with self.subTest(args=args[:2]):
                got, headers, body = self.call(*args)
                self.assertEqual(got, status)
                result = json.loads(body)
                self.assertEqual(result["code"], code)
                self.assertTrue(result["error"])
                self.assertIn("media-src 'self' blob:", headers["Content-Security-Policy"])
        headers = {**self.mutation_headers(), "Transfer-Encoding": "chunked"}
        status, _, body = self.call("PUT", "api/videos/Beispiel.mp4", b"0\r\n\r\n", headers)
        self.assertEqual((status, json.loads(body)["code"]), (411, "length_required"))
        with mock.patch.object(app.Library, "listing", side_effect=OSError("synthetic")):
            status, _, body = self.call("GET")
        self.assertEqual((status, json.loads(body)["code"]), (503, "storage_unavailable"))
        with mock.patch.object(app.Library, "listing", side_effect=app.Problem(503, app.METADATA_ERROR, "metadata_unreadable")):
            status, _, body = self.call("GET")
        self.assertEqual((status, json.loads(body)["code"]), (503, "metadata_unreadable"))

    def test_csp_allows_blob_media_only(self):
        _, headers, _ = self.call("GET", "")
        policy = headers["Content-Security-Policy"]
        self.assertIn("media-src 'self' blob:;", policy)
        self.assertEqual(policy.count("blob:"), 1)
        self.assertNotIn("unsafe-inline", policy)
        self.assertNotIn("unsafe-eval", policy)
        self.assertIn("script-src 'self';", policy)
        self.assertIn("style-src 'self';", policy)

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
        for path in ("metadata.json", ".trash/Beispiel.mp4", "../app.py", "video/Beispiel.mp4",
                     ".thumbs/Beispiel.mp4.jpg", "thumb/Beispiel.mp4.jpg"):
            self.assertEqual(self.call("GET", path)[0], 404)


if __name__ == "__main__":
    unittest.main()
