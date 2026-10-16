#!/usr/bin/env node
// db621bf smoke: private legacy probes plus authenticated public version/data.
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { docker, runningImage } from "./joedesk-docker.mjs";
const hash = (b) => createHash("sha256").update(b).digest("hex");
export function expectedBackup(backup, readFile = fs.readFileSync) {
  const manifest = JSON.parse(
    readFile(path.join(backup, "backup-manifest.json")),
  );
  if (
    manifest.schema !== "joedesk.data-backup.v1" ||
    manifest.boardSchema !== "v1" ||
    !Array.isArray(manifest.files)
  )
    throw new Error("verified_v1_backup_required");
  const expected = {};
  for (const f of manifest.files) {
    if (
      ![
        "data.json",
        "history.json",
        "fleet-config.json",
        "fleet-config-actions.json",
      ].includes(f.name)
    )
      throw new Error("backup_file_invalid");
    const bytes = readFile(path.join(backup, f.name));
    if (bytes.length !== f.size || hash(bytes) !== f.sha256)
      throw new Error("backup_digest_mismatch");
    expected[f.name] = f.sha256;
  }
  if (!expected["data.json"] || !expected["history.json"])
    throw new Error("legacy_data_and_history_required");
  return expected;
}
function publicRead(base, route, cookieJar) {
  const args = [
    "--silent",
    "--max-time",
    "10",
    "--max-filesize",
    "16777216",
    "--write-out",
    "\n%{http_code}",
    "--header",
    "Accept: application/json",
  ];
  if (cookieJar) args.push("--cookie", cookieJar);
  let output;
  try {
    output = execFileSync("curl", [...args, new URL(route, base).href], {
      maxBuffer: 17 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    throw new Error("legacy_public_transport_failed");
  }
  const split = output.lastIndexOf(10);
  return {
    status: Number(output.subarray(split + 1).toString()),
    body: output.subarray(0, split),
  };
}
// db621bf's Dockerfile copies package.json and public, but NOT release.json.
// Keep this function self-contained: the exact same check runs inside Docker
// and against that immutable source's actual COPY closure in T101.
export async function checkLegacyFiles(readFile, probe, digest, expected) {
  const pkg = JSON.parse(readFile("/app/package.json"));
  if (
    pkg.name !== "joedesk" ||
    pkg.version !== "26.09.21.12.00" ||
    pkg.type !== "module"
  )
    throw new Error("legacy_package_mismatch");
  for (const route of ["/healthz", "/readyz"]) {
    const response = await probe(route),
      body = await response.json();
    if (
      response.status !== 200 ||
      body.ok !== true ||
      body.service !== "joe-board" ||
      body.hasData !== true
    )
      throw new Error("legacy_probe_failed");
  }
  for (const [name, hash] of Object.entries(expected))
    if (digest(readFile("/var/lib/joe-board/" + name)) !== hash)
      throw new Error("legacy_restored_bytes_mismatch");
  return digest(readFile("/app/public/joe/joe-version.js"));
}
export async function legacySmoke({
  container,
  image,
  backup,
  base,
  cookieJar,
  readBackupFile = fs.readFileSync,
}) {
  const url = new URL(base);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    url.pathname !== "/joe/" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  )
    throw new Error("legacy_base_invalid");
  if (
    !/^sha256:[0-9a-f]{64}$/.test(image) ||
    (await runningImage(container)) !== image
  )
    throw new Error("previous_image_mismatch");
  const cookies = fs.lstatSync(cookieJar);
  if (!cookies.isFile() || cookies.isSymbolicLink() || cookies.mode & 0o077)
    throw new Error("private_cookie_jar_required");
  const expected = expectedBackup(backup, readBackupFile);
  const script = `
    import fs from 'node:fs'; import {createHash} from 'node:crypto';
    const expected=JSON.parse(fs.readFileSync(0,'utf8'));
    const hash=b=>createHash('sha256').update(b).digest('hex');
    const probe=route=>fetch('http://127.0.0.1:8080'+route,{redirect:'manual',signal:AbortSignal.timeout(10000)});
    console.log(await (${checkLegacyFiles.toString()})(fs.readFileSync,probe,hash,expected));
  `;
  const versionHash = docker(
    ["exec", "-i", container, "node", "--input-type=module", "-e", script],
    { input: JSON.stringify(expected) },
  );
  const anonymous = publicRead(base, "data.json");
  if (![301, 302, 303, 307, 308, 401, 403].includes(anonymous.status))
    throw new Error("legacy_public_read_exposed");
  const version = publicRead(base, "joe-version.js", cookieJar);
  if (version.status !== 200 || hash(version.body) !== versionHash)
    throw new Error("legacy_authenticated_version_failed");
  for (const name of ["data.json", "history.json", "fleet-config.json"]) {
    const response = publicRead(base, name, cookieJar);
    if (
      response.status !== 200 ||
      (name !== "fleet-config.json" &&
        expected[name] &&
        hash(response.body) !== expected[name])
    )
      throw new Error("legacy_authenticated_data_failed");
    const body = JSON.parse(response.body);
    if (
      name === "fleet-config.json" &&
      expected[name] &&
      !isDeepStrictEqual(
        body,
        JSON.parse(readBackupFile(path.join(backup, name))),
      )
    )
      throw new Error("legacy_config_mismatch");
    const schemas = {
      "data.json": "inspr.joe.household.v1",
      "history.json": "inspr.joe.household.history.v1",
      "fleet-config.json": "inspr.joe.fleet-config.v1",
    };
    if (body.schema !== schemas[name])
      throw new Error("legacy_schema_mismatch");
  }
  return {
    ok: true,
    image: "exact-previous",
    backup: "v1-byte-verified",
    privateProbes: "passed",
    authenticatedVersionData: "passed",
  };
}
if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  try {
    const values = process.argv.slice(2),
      options = {};
    for (let i = 0; i < values.length; i += 2) {
      const key = {
        "--container": "container",
        "--image": "image",
        "--backup": "backup",
        "--base": "base",
        "--cookie-jar": "cookieJar",
      }[values[i]];
      if (!key || !values[i + 1]) throw new Error("usage");
      options[key] = values[i + 1];
    }
    console.log(JSON.stringify(await legacySmoke(options)));
  } catch (error) {
    console.error(
      "legacy_smoke_failed: " +
        (/^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "preflight_or_io_error"),
    );
    process.exitCode = 1;
  }
}
