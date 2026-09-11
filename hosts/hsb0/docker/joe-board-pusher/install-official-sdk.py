#!/usr/bin/env python3
"""Install the official IB SDK into an isolated venv from a hash-only lock."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.request
import venv
import zipfile
from pathlib import Path, PurePosixPath


LOCK_SCHEMA = "inspr.ib.official-sdk-lock.v1"
MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SDK_LICENSE_DECLARATION = 'license="IB API Non-Commercial License or the IB API Commercial License"'
CANONICAL_METADATA_PATCH = {
    "path": "setup.py",
    "expected": 'install_requires=["protobuf==5.29.5"]',
    "replacement": 'install_requires=["protobuf==5.29.6"]',
    "scope": "dependency-metadata-only",
    "reason": "CVE-2026-0994",
    "upstreamRelease": "https://github.com/protocolbuffers/protobuf/releases/tag/v29.6",
    "compatibilityReference": "https://protobuf.dev/support/cross-version-runtime-guarantee/",
}


def load_lock(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema") != LOCK_SCHEMA:
        raise ValueError("unsupported SDK lock schema")
    sdk = value.get("officialSdk")
    dependencies = value.get("dependencies")
    metadata_patch = value.get("dependencyMetadataPatch")
    if not isinstance(sdk, dict) or not isinstance(dependencies, list) or not dependencies:
        raise ValueError("SDK lock is incomplete")
    for item in [sdk, *dependencies]:
        if not isinstance(item, dict) or not str(item.get("url", "")).startswith("https://"):
            raise ValueError("every locked artifact requires an HTTPS URL")
        if not SHA256_RE.fullmatch(str(item.get("sha256", ""))):
            raise ValueError("every locked artifact requires a lowercase SHA-256")
    if sdk.get("name") != "ibapi" or sdk.get("version") != "10.45.1":
        raise ValueError("official SDK identity does not match the supported reader")
    if metadata_patch != CANONICAL_METADATA_PATCH:
        raise ValueError("SDK dependency metadata patch is not canonical")
    names = [(item.get("kind"), item.get("name"), item.get("version")) for item in dependencies]
    if names != [("runtime", "protobuf", "5.29.6"), ("build", "setuptools", "83.0.0")]:
        raise ValueError("locked dependency set is not canonical")
    return value


def download(item: dict, directory: Path) -> Path:
    target = directory / PurePosixPath(item["url"]).name
    digest = hashlib.sha256()
    total = 0
    request = urllib.request.Request(item["url"], headers={"User-Agent": "inspr-official-sdk-installer/1"})
    with urllib.request.urlopen(request, timeout=60) as response, target.open("xb") as handle:
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_DOWNLOAD_BYTES:
                raise ValueError("locked artifact exceeds download limit")
            digest.update(chunk)
            handle.write(chunk)
    if digest.hexdigest() != item["sha256"]:
        raise ValueError(f"SHA-256 mismatch for {item['name']}")
    return target


def safe_extract_sdk(archive: Path, destination: Path, source_path: str) -> Path:
    prefix = PurePosixPath(source_path)
    with zipfile.ZipFile(archive) as zipped:
        selected = []
        for info in zipped.infolist():
            member = PurePosixPath(info.filename)
            if member.is_absolute() or ".." in member.parts:
                raise ValueError("official SDK archive contains an unsafe path")
            if info.external_attr >> 28 == 0xA:
                raise ValueError("official SDK archive contains a symlink")
            if member == prefix or prefix in member.parents:
                selected.append(info)
        if not selected:
            raise ValueError("official SDK source path is absent from archive")
        zipped.extractall(destination, members=selected)
    source = destination.joinpath(*prefix.parts)
    if not (source / "setup.py").is_file() or not (source / "ibapi" / "__init__.py").is_file():
        raise ValueError("official SDK Python source is incomplete")
    return source


def patch_dependency_metadata(source: Path, patch: dict) -> Path:
    """Apply the recorded one-line setup.py dependency metadata correction."""
    if patch != CANONICAL_METADATA_PATCH:
        raise ValueError("refusing an unrecognized SDK metadata patch")
    setup_path = source / patch["path"]
    original = setup_path.read_text(encoding="utf-8")
    expected = patch["expected"]
    replacement = patch["replacement"]
    if original.count(expected) != 1:
        raise ValueError("official SDK setup.py does not contain exactly one expected dependency declaration")
    if replacement in original:
        raise ValueError("official SDK setup.py already contains the patched dependency declaration")
    if SDK_LICENSE_DECLARATION not in original:
        raise ValueError("official SDK setup.py license declaration is absent")
    patched = original.replace(expected, replacement, 1)
    if patched.count(replacement) != 1 or SDK_LICENSE_DECLARATION not in patched:
        raise ValueError("SDK dependency metadata patch did not preserve expected metadata")
    setup_path.write_text(patched, encoding="utf-8")
    return setup_path


SDK_VERIFY_SCRIPT = r"""
from importlib import import_module
from importlib.metadata import version
import pkgutil

import ibapi
import ibapi.protobuf
from ibapi.protobuf.ExecutionFilter_pb2 import ExecutionFilter
from ibapi.protobuf.ExecutionRequest_pb2 import ExecutionRequest

assert version("ibapi") == "10.45.1"
assert version("protobuf") == "5.29.6"
assert ibapi.__version__ == "10.45.1"

modules = sorted(module.name for module in pkgutil.iter_modules(ibapi.protobuf.__path__))
assert modules, "official SDK contains no protobuf modules"
for module in modules:
    import_module(f"ibapi.protobuf.{module}")

request = ExecutionRequest(
    reqId=9400,
    executionFilter=ExecutionFilter(acctCode="DU000000", specificDates=[20260910]),
)
encoded = request.SerializeToString()
decoded = ExecutionRequest()
decoded.ParseFromString(encoded)
assert decoded.reqId == 9400
assert decoded.executionFilter.acctCode == "DU000000"
assert list(decoded.executionFilter.specificDates) == [20260910]
"""


def install(lock_path: Path, target: Path) -> None:
    lock = load_lock(lock_path)
    if target.exists():
        raise ValueError("target venv already exists")
    with tempfile.TemporaryDirectory(prefix="official-ibapi-") as temporary_name:
        temporary = Path(temporary_name)
        archive = download(lock["officialSdk"], temporary)
        wheels = [download(item, temporary) for item in lock["dependencies"]]
        source = safe_extract_sdk(archive, temporary / "source", lock["officialSdk"]["sourcePath"])
        patch_dependency_metadata(source, lock["dependencyMetadataPatch"])
        venv.EnvBuilder(with_pip=True, clear=False, symlinks=True).create(target)
        python = target / "bin" / "python"
        requirements = temporary / "requirements.lock"
        requirements.write_text(
            "".join(
                f"{item['name']}=={item['version']} --hash=sha256:{item['sha256']}\n"
                for item in lock["dependencies"]
            ),
            encoding="utf-8",
        )
        subprocess.run(
            [str(python), "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir",
             "--no-deps", "--only-binary=:all:", "--require-hashes", "--no-index",
             "--find-links", str(temporary), "-r", str(requirements)],
            check=True,
        )
        subprocess.run(
            [str(python), "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir",
             "--no-deps", "--no-build-isolation", "--no-index", str(source)],
            check=True,
        )
        expected_wheels = {wheel.name for wheel in wheels}
        if len(expected_wheels) != len(lock["dependencies"]):
            raise ValueError("locked dependency filenames are not unique")
        subprocess.run([str(python), "-m", "pip", "check"], check=True)
        subprocess.run([str(python), "-I", "-c", SDK_VERIFY_SCRIPT], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    args = parser.parse_args()
    old_umask = os.umask(0o022)
    try:
        install(args.lock.resolve(), args.target.resolve())
    finally:
        os.umask(old_umask)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
