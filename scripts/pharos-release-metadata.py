#!/usr/bin/env python3
"""Validate and order Pharos legacy/calendar release metadata."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


LOCAL_SCHEMA = "inspr.pharos.fleet-release.v2"
RELEASE_SET_SCHEMA = "inspr.pharos.release-set.v1"
CALENDAR_SCHEME = "inspr-calendar-v1"
LEGACY_SCHEME = "legacy"
STABLE_CHANNEL = "stable"
PHAROS_IMAGE = "ghcr.io/inspr-at/pharos/pharosd"
MAX_METADATA_BYTES = 64 * 1024

LOCAL_FIELDS = (
    "schema",
    "version_scheme",
    "version",
    "release_channel",
    "release_sequence",
    "migration_anchor",
    "source_commit",
    "tag",
    "image",
    "digest",
    "reference",
    "legacy_rollback",
)
LOCAL_KEYS = set(LOCAL_FIELDS)
RELEASE_SET_KEYS = LOCAL_KEYS | {
    "schema_version",
    "cargo_version",
    "source_lock_digest",
    "sha_reference",
    "artifacts",
    "attestations",
}
ANCHOR_KEYS = {
    "last_legacy_version",
    "last_legacy_release_sequence",
    "first_calendar_version",
    "first_calendar_release_sequence",
}
CALENDAR_RE = re.compile(
    r"^(?P<year>[0-9]{2})\.(?P<month>0[1-9]|1[0-2])\."
    r"(?P<day>0[1-9]|[12][0-9]|3[01])\."
    r"(?P<hour>[01][0-9]|2[0-3])\.(?P<minute>[0-5][0-9])\."
    r"(?P<second>[0-5][0-9])$"
)
LEGACY_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SPDX_FILENAME = "pharos.spdx.json"
LEGACY_ROLLBACK = {
    "version_scheme": LEGACY_SCHEME,
    "version": "0.2.0",
    "release_channel": STABLE_CHANNEL,
    "release_sequence": 0,
    "source_commit": "5c8bd1fbd2271a5c157ca239ec2d98b66b201e19",
    "tag": "v0.2.0",
    "image": PHAROS_IMAGE,
    "digest": "sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b",
    "reference": (
        "ghcr.io/inspr-at/pharos/pharosd:0.2.0@"
        "sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b"
    ),
}


class MetadataError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MetadataError("duplicate_key")
        result[key] = value
    return result


def load_document(path: Path) -> dict[str, Any]:
    try:
        if (
            path.is_symlink()
            or not path.is_file()
            or path.stat().st_size > MAX_METADATA_BYTES
        ):
            raise MetadataError("unsafe_file")
        value = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MetadataError("invalid_json") from error
    if not isinstance(value, dict):
        raise MetadataError("not_object")
    return value


def calendar_coordinate(value: str) -> tuple[int, int, int, int, int, int]:
    match = CALENDAR_RE.fullmatch(value)
    if match is None:
        raise MetadataError("invalid_calendar_version")
    fields = tuple(
        int(match.group(name))
        for name in ("year", "month", "day", "hour", "minute", "second")
    )
    try:
        dt.datetime(2000 + fields[0], *fields[1:], tzinfo=dt.timezone.utc)
    except ValueError as error:
        raise MetadataError("invalid_calendar_date") from error
    return fields


def require_exact_keys(value: dict[str, Any], expected: set[str], reason: str) -> None:
    if set(value) != expected:
        raise MetadataError(reason)


def require_positive_int(value: Any, reason: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise MetadataError(reason)
    return value


def validate_document(document: dict[str, Any], schema: str) -> dict[str, Any]:
    expected_keys = LOCAL_KEYS if schema == LOCAL_SCHEMA else RELEASE_SET_KEYS
    require_exact_keys(document, expected_keys, "unexpected_top_level_fields")
    if document.get("schema") != schema:
        raise MetadataError("schema_mismatch")
    if document.get("release_channel") != STABLE_CHANNEL:
        raise MetadataError("unsupported_release_channel")
    if document.get("image") != PHAROS_IMAGE:
        raise MetadataError("unexpected_image")

    scheme = document.get("version_scheme")
    version = document.get("version")
    sequence = require_positive_int(
        document.get("release_sequence"), "invalid_release_sequence", allow_zero=True
    )
    if scheme not in {LEGACY_SCHEME, CALENDAR_SCHEME} or not isinstance(version, str):
        raise MetadataError("unsupported_version_scheme")
    if document.get("legacy_rollback") != LEGACY_ROLLBACK:
        raise MetadataError("legacy_rollback_mismatch")
    if schema == RELEASE_SET_SCHEMA and scheme != CALENDAR_SCHEME:
        raise MetadataError("release_set_must_be_calendar")

    anchor = document.get("migration_anchor")
    if not isinstance(anchor, dict):
        raise MetadataError("invalid_migration_anchor")
    require_exact_keys(anchor, ANCHOR_KEYS, "unexpected_migration_anchor_fields")
    last_legacy = anchor.get("last_legacy_version")
    last_legacy_sequence = require_positive_int(
        anchor.get("last_legacy_release_sequence"),
        "invalid_last_legacy_sequence",
        allow_zero=True,
    )
    first_calendar = anchor.get("first_calendar_version")
    first_calendar_sequence = require_positive_int(
        anchor.get("first_calendar_release_sequence"), "invalid_first_calendar_sequence"
    )
    if not isinstance(last_legacy, str) or LEGACY_RE.fullmatch(last_legacy) is None:
        raise MetadataError("invalid_last_legacy_version")
    if (
        last_legacy != "0.2.0"
        or last_legacy_sequence != 0
        or first_calendar_sequence != 1
    ):
        raise MetadataError("migration_anchor_mismatch")
    if first_calendar_sequence != last_legacy_sequence + 1:
        raise MetadataError("noncontiguous_migration_sequence")

    if scheme == LEGACY_SCHEME:
        if version != last_legacy or sequence != last_legacy_sequence:
            raise MetadataError("legacy_outside_anchor")
        if any(document.get(key) != value for key, value in LEGACY_ROLLBACK.items()):
            raise MetadataError("legacy_root_identity_mismatch")
        if first_calendar is not None:
            calendar_coordinate(first_calendar)
    else:
        coordinate = calendar_coordinate(version)
        if not isinstance(first_calendar, str):
            raise MetadataError("missing_first_calendar_version")
        first_coordinate = calendar_coordinate(first_calendar)
        if sequence < first_calendar_sequence or coordinate < first_coordinate:
            raise MetadataError("calendar_before_anchor")
        if (sequence == first_calendar_sequence) != (coordinate == first_coordinate):
            raise MetadataError("calendar_anchor_mismatch")

    if schema == RELEASE_SET_SCHEMA:
        if document.get("schema_version") != 1:
            raise MetadataError("unsupported_schema_version")
        cargo_version = document.get("cargo_version")
        year, month, day, hour, minute, second = coordinate
        expected_cargo_version = (
            f"{2000 + year}.{month * 100 + day}.{hour * 10000 + minute * 100 + second}"
        )
        if cargo_version != expected_cargo_version:
            raise MetadataError("cargo_version_mismatch")
        source_lock_digest = document.get("source_lock_digest")
        if (
            not isinstance(source_lock_digest, str)
            or DIGEST_RE.fullmatch(source_lock_digest) is None
        ):
            raise MetadataError("invalid_source_lock_digest")

    source_commit = document.get("source_commit")
    digest = document.get("digest")
    if not isinstance(source_commit, str) or COMMIT_RE.fullmatch(source_commit) is None:
        raise MetadataError("invalid_source_commit")
    if not isinstance(digest, str) or DIGEST_RE.fullmatch(digest) is None:
        raise MetadataError("invalid_digest")
    if document.get("tag") != f"v{version}":
        raise MetadataError("tag_version_mismatch")
    expected_reference = f"{PHAROS_IMAGE}:{version}@{digest}"
    if document.get("reference") != expected_reference:
        raise MetadataError("reference_mismatch")
    if schema == RELEASE_SET_SCHEMA:
        expected_sha_reference = f"{PHAROS_IMAGE}:sha-{source_commit}@{digest}"
        if document.get("sha_reference") != expected_sha_reference:
            raise MetadataError("sha_reference_mismatch")
        validate_supply_chain(document)
    return document


def validate_supply_chain(document: dict[str, Any]) -> None:
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 3:
        raise MetadataError("invalid_artifacts")
    expected_coordinates = (
        {
            "class": "oci-index",
            "version_reference": document["reference"],
            "source_reference": document["sha_reference"],
        },
        {"class": "oci-image", "platform": "linux/amd64"},
        {"class": "spdx-sbom", "filename": SPDX_FILENAME},
    )
    for index, expected_coordinate in enumerate(expected_coordinates):
        artifact = artifacts[index]
        if not isinstance(artifact, dict):
            raise MetadataError("invalid_artifact")
        require_exact_keys(
            artifact, {"coordinate", "digest"}, "unexpected_artifact_fields"
        )
        if artifact.get("coordinate") != expected_coordinate:
            raise MetadataError("artifact_coordinate_mismatch")
        artifact_digest = artifact.get("digest")
        if (
            not isinstance(artifact_digest, str)
            or DIGEST_RE.fullmatch(artifact_digest) is None
        ):
            raise MetadataError("invalid_artifact_digest")
    if artifacts[0]["digest"] != document["digest"]:
        raise MetadataError("oci_index_digest_mismatch")

    attestations = document.get("attestations")
    if not isinstance(attestations, dict):
        raise MetadataError("invalid_attestations")
    require_exact_keys(
        attestations,
        {"signature", "provenance", "sbom"},
        "unexpected_attestation_fields",
    )
    signature = attestations["signature"]
    if not isinstance(signature, dict):
        raise MetadataError("invalid_signature_attestation")
    require_exact_keys(
        signature, {"coordinate", "digest"}, "unexpected_signature_fields"
    )
    signature_digest = signature.get("digest")
    if (
        not isinstance(signature_digest, str)
        or DIGEST_RE.fullmatch(signature_digest) is None
    ):
        raise MetadataError("invalid_signature_digest")
    digest_hex = document["digest"].removeprefix("sha256:")
    expected_signature_coordinate = (
        f"{document['image']}:sha256-{digest_hex}.sig@{signature_digest}"
    )
    if signature.get("coordinate") != expected_signature_coordinate:
        raise MetadataError("signature_coordinate_mismatch")

    predicate_types = {
        "provenance": "https://slsa.dev/provenance/v1",
        "sbom": "https://spdx.dev/Document",
    }
    manifest_digest: str | None = None
    for name, predicate_type in predicate_types.items():
        attestation = attestations[name]
        if not isinstance(attestation, dict):
            raise MetadataError("invalid_attestation")
        require_exact_keys(
            attestation,
            {"coordinate", "manifest_digest", "layer_digest", "predicate_type"},
            "unexpected_attestation_fields",
        )
        current_manifest = attestation.get("manifest_digest")
        layer_digest = attestation.get("layer_digest")
        if (
            not isinstance(current_manifest, str)
            or DIGEST_RE.fullmatch(current_manifest) is None
            or not isinstance(layer_digest, str)
            or DIGEST_RE.fullmatch(layer_digest) is None
        ):
            raise MetadataError("invalid_attestation_digest")
        if attestation.get("coordinate") != f"{document['image']}@{current_manifest}":
            raise MetadataError("attestation_coordinate_mismatch")
        if attestation.get("predicate_type") != predicate_type:
            raise MetadataError("predicate_type_mismatch")
        if manifest_digest is not None and current_manifest != manifest_digest:
            raise MetadataError("attestation_manifest_mismatch")
        manifest_digest = current_manifest


def anchors_match(active: dict[str, Any], candidate: dict[str, Any]) -> bool:
    old = active["migration_anchor"]
    new = candidate["migration_anchor"]
    return (
        old["last_legacy_version"] == new["last_legacy_version"]
        and old["last_legacy_release_sequence"] == new["last_legacy_release_sequence"]
        and old["first_calendar_release_sequence"]
        == new["first_calendar_release_sequence"]
    )


def same_release(left: dict[str, Any], right: dict[str, Any]) -> bool:
    comparable = LOCAL_KEYS - {"schema"}
    return all(left[key] == right[key] for key in comparable)


def validate_transition(active: dict[str, Any], candidate: dict[str, Any]) -> None:
    if active["release_channel"] != candidate["release_channel"] or not anchors_match(
        active, candidate
    ):
        raise MetadataError("migration_anchor_changed")
    if candidate["release_sequence"] < active["release_sequence"]:
        raise MetadataError("release_sequence_rollback")
    if candidate["release_sequence"] == active["release_sequence"]:
        if not same_release(active, candidate):
            raise MetadataError("release_sequence_collision")
        return
    if candidate["version_scheme"] != CALENDAR_SCHEME:
        raise MetadataError("post_anchor_legacy_release")
    if active["version_scheme"] == CALENDAR_SCHEME:
        old_anchor = active["migration_anchor"]["first_calendar_version"]
        if candidate["migration_anchor"]["first_calendar_version"] != old_anchor:
            raise MetadataError("first_calendar_anchor_changed")
        if calendar_coordinate(candidate["version"]) <= calendar_coordinate(
            active["version"]
        ):
            raise MetadataError("calendar_version_not_increasing")
    else:
        first = candidate["migration_anchor"]["first_calendar_version"]
        if first is None:
            raise MetadataError("missing_first_calendar_version")
        active_first = active["migration_anchor"]["first_calendar_version"]
        if active_first is not None and first != active_first:
            raise MetadataError("first_calendar_anchor_changed")


def as_local(candidate: dict[str, Any]) -> dict[str, Any]:
    result = {key: candidate[key] for key in LOCAL_FIELDS}
    result["schema"] = LOCAL_SCHEMA
    return result


def write_document(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode if path.exists() else 0o100644
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent, text=True
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, mode & 0o777)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def command_validate(args: argparse.Namespace) -> None:
    document = load_document(args.file)
    schema = (
        document.get("schema")
        if args.kind == "auto"
        else (LOCAL_SCHEMA if args.kind == "local" else RELEASE_SET_SCHEMA)
    )
    if schema not in {LOCAL_SCHEMA, RELEASE_SET_SCHEMA}:
        raise MetadataError("schema_mismatch")
    validate_document(document, schema)


def command_transition(args: argparse.Namespace) -> None:
    active = validate_document(load_document(args.active), LOCAL_SCHEMA)
    candidate = validate_document(load_document(args.candidate), RELEASE_SET_SCHEMA)
    validate_transition(active, candidate)
    write_document(args.output, as_local(candidate))


def command_matches(args: argparse.Namespace) -> None:
    active = validate_document(load_document(args.active), LOCAL_SCHEMA)
    candidate_document = load_document(args.candidate)
    candidate_schema = candidate_document.get("schema")
    if candidate_schema not in {LOCAL_SCHEMA, RELEASE_SET_SCHEMA}:
        raise MetadataError("schema_mismatch")
    candidate = validate_document(candidate_document, candidate_schema)
    if not same_release(active, candidate):
        raise MetadataError("release_set_local_mismatch")


def command_rollback(args: argparse.Namespace) -> None:
    active = validate_document(load_document(args.active), LOCAL_SCHEMA)
    rollback = active["legacy_rollback"]
    if active["version_scheme"] != CALENDAR_SCHEME or args.tag != rollback["tag"]:
        raise MetadataError("rollback_target_mismatch")
    result = dict(active)
    for key, value in rollback.items():
        result[key] = value
    write_document(args.output, result)


def command_select(args: argparse.Namespace) -> None:
    active = validate_document(load_document(args.active), LOCAL_SCHEMA)
    candidates = [
        validate_document(load_document(path), RELEASE_SET_SCHEMA)
        for path in args.candidates
    ]
    by_sequence: dict[int, dict[str, Any]] = {}
    for candidate in candidates:
        if candidate["release_channel"] != active[
            "release_channel"
        ] or not anchors_match(active, candidate):
            raise MetadataError("migration_anchor_changed")
        if candidate["release_sequence"] < active["release_sequence"]:
            if candidate["version_scheme"] == LEGACY_SCHEME:
                continue
            if active["version_scheme"] != CALENDAR_SCHEME:
                raise MetadataError("release_sequence_rollback")
            if (
                candidate["migration_anchor"]["first_calendar_version"]
                != active["migration_anchor"]["first_calendar_version"]
            ):
                raise MetadataError("first_calendar_anchor_changed")
            if calendar_coordinate(candidate["version"]) >= calendar_coordinate(
                active["version"]
            ):
                raise MetadataError("historical_calendar_order_mismatch")
            continue
        validate_transition(active, candidate)
        sequence = candidate["release_sequence"]
        previous = by_sequence.get(sequence)
        if previous is not None and not same_release(previous, candidate):
            raise MetadataError("release_sequence_collision")
        by_sequence[sequence] = candidate
    if not by_sequence:
        raise MetadataError("active_release_set_not_found")
    previous_coordinate: tuple[int, int, int, int, int, int] | None = None
    for sequence in sorted(by_sequence):
        release = by_sequence[sequence]
        if release["version_scheme"] != CALENDAR_SCHEME:
            continue
        coordinate = calendar_coordinate(release["version"])
        if previous_coordinate is not None and coordinate <= previous_coordinate:
            raise MetadataError("calendar_sequence_order_mismatch")
        previous_coordinate = coordinate
    selected = by_sequence[max(by_sequence)]
    write_document(args.output, selected)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate")
    validate.add_argument(
        "--kind", choices=("local", "release-set", "auto"), required=True
    )
    validate.add_argument("file", type=Path)
    validate.set_defaults(handler=command_validate)

    transition = commands.add_parser("transition")
    transition.add_argument("--active", type=Path, required=True)
    transition.add_argument("--candidate", type=Path, required=True)
    transition.add_argument("--output", type=Path, required=True)
    transition.set_defaults(handler=command_transition)

    matches = commands.add_parser("matches")
    matches.add_argument("--active", type=Path, required=True)
    matches.add_argument("--candidate", type=Path, required=True)
    matches.set_defaults(handler=command_matches)

    rollback = commands.add_parser("rollback")
    rollback.add_argument("--active", type=Path, required=True)
    rollback.add_argument("--tag", required=True)
    rollback.add_argument("--output", type=Path, required=True)
    rollback.set_defaults(handler=command_rollback)

    select = commands.add_parser("select")
    select.add_argument("--active", type=Path, required=True)
    select.add_argument("--output", type=Path, required=True)
    select.add_argument("candidates", type=Path, nargs="*")
    select.set_defaults(handler=command_select)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except MetadataError as error:
        print(f"pharos_release_metadata=failed reason={error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
