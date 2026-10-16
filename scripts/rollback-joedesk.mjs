#!/usr/bin/env node
// OPS-354 operator command. No SSH, automatic approvals or ad-hoc overrides.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { spawnSync, execFileSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { pathToFileURL, fileURLToPath } from "node:url";
import { docker } from "./joedesk-docker.mjs";
import { legacySmoke } from "./joedesk-legacy-smoke.mjs";
export const setDigest = (value) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex");
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const q = (value) => "'" + String(value).replaceAll("'", "'\\''") + "'";
const git = (...args) =>
  execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
export function verifyPreviousRuntimeSource(
  previous,
  revision = "HEAD",
  runGit = git,
) {
  for (const name of ["pusher", "executor"]) {
    const pin = previous[name];
    const tree = (rev) => runGit("rev-parse", rev + ":" + pin.source_path);
    if (tree(pin.nixcfg_rev) !== pin.source_tree)
      throw new Error("recorded_runtime_source_mismatch");
    if (name === "pusher") {
      // Compare complete trees: additions after the pin matter too.
      if (tree(revision) !== pin.source_tree)
        throw new Error("previous_runtime_source_mismatch");
    } else {
      // The executor module's Nix wiring can change while its runtime is pinned.
      const files = (rev) =>
        runGit("ls-tree", "-r", "--name-only", rev, "--", pin.source_path)
          .split("\n")
          .filter((file) => file.endsWith(".mjs"))
          .sort();
      const before = files(pin.nixcfg_rev),
        after = files(revision);
      if (
        !before.length ||
        JSON.stringify(before) !== JSON.stringify(after) ||
        runGit("diff", "--name-only", pin.nixcfg_rev, revision, "--", ...before)
      )
        throw new Error("previous_runtime_source_mismatch");
    }
  }
}
export function verifyRollbackTarget(
  record,
  previous,
  runGit = git,
  revision = record.rollback_nixcfg_rev,
) {
  try {
    if (
      runGit("rev-parse", record.rollback_nixcfg_rev + "^{commit}") !==
      record.rollback_nixcfg_rev
    )
      throw new Error("revision");
    runGit("merge-base", "--is-ancestor", "HEAD", record.rollback_nixcfg_rev);
    runGit(
      "merge-base",
      "--is-ancestor",
      record.rollback_nixcfg_rev,
      "FETCH_HEAD",
    );
  } catch {
    throw new Error("rollback_commit_not_fetched_fast_forward");
  }
  const selected = JSON.parse(
    runGit("show", revision + ":hosts/csb0/joedesk-release.json"),
  );
  const lock = JSON.parse(runGit("show", revision + ":flake.lock"));
  if (
    selected.active !== "previous" ||
    setDigest(selected.sets[selected.active]) !== record.previous_set_sha256 ||
    lock.nodes.joedesk.locked.rev !== previous.board.rev
  )
    throw new Error("reviewed_previous_pins_not_selected");
  verifyPreviousRuntimeSource(previous, revision, runGit);
}
export function rollbackPlan(record, release) {
  const previous = release.sets.previous;
  if (
    previous.board.data_schema !== "v1" ||
    previous.board.rev !== "db621bf7f00a4c609b0930ef7d5020f3c8935ee9" ||
    record.previous_set_sha256 !== setDigest(previous)
  )
    throw new Error("previous_release_record_mismatch");
  for (const key of ["rollback_nixcfg_rev"])
    if (!/^[0-9a-f]{40}$/.test(record[key] || ""))
      throw new Error("reviewed_rollback_commit_required");
  for (const key of ["board_image_id", "pusher_image_id"])
    if (!/^sha256:[0-9a-f]{64}$/.test(record[key] || ""))
      throw new Error("retained_image_required");
  for (const key of ["backup_manifest_sha256"])
    if (!/^[0-9a-f]{64}$/.test(record[key] || ""))
      throw new Error("verified_backup_record_required");
  for (const key of ["csb0_generation", "hsb0_generation"])
    if (!Number.isSafeInteger(record[key]) || record[key] < 1)
      throw new Error("retained_generations_required");
  for (const key of [
    "v1_backup",
    "prepare_source",
    "cookie_jar",
    "hsb0_checkout",
  ])
    if (!path.isAbsolute(record[key] || "") || /[\r\n]/.test(record[key]))
      throw new Error("absolute_private_paths_required");
  const hsbCompose =
    "sudo docker compose -p docker -f /etc/compose/hsb0/docker-compose.yml --project-directory hosts/hsb0/docker";
  return {
    previous,
    crossStop: [
      "cd " + q(record.hsb0_checkout),
      // Resolve and verify the exact reviewed target BEFORE stopping writers.
      'test -z "$(git status --porcelain --untracked-files=no)"',
      "git fetch origin main",
      "git merge-base --is-ancestor HEAD " + q(record.rollback_nixcfg_rev),
      "git merge-base --is-ancestor " +
        q(record.rollback_nixcfg_rev) +
        " FETCH_HEAD",
      "node --input-type=module -e " +
        q(
          "import {verifyRollbackTarget} from './scripts/rollback-joedesk.mjs'; verifyRollbackTarget(" +
            JSON.stringify({
              rollback_nixcfg_rev: record.rollback_nixcfg_rev,
              previous_set_sha256: record.previous_set_sha256,
            }) +
            "," +
            JSON.stringify(previous) +
            ");",
        ),
      "sudo systemctl stop compose-hsb0-update.timer compose-hsb0-update.service compose-hsb0.service",
      hsbCompose + " stop joe-board-pusher paper-desk-executor",
      hsbCompose +
        " ps --status running -q joe-board-pusher paper-desk-executor",
    ],
    crossSwitch: [
      "cd " + q(record.hsb0_checkout),
      "git merge --ff-only " + q(record.rollback_nixcfg_rev),
      'test "$(git rev-parse HEAD)" = ' + q(record.rollback_nixcfg_rev),
      "node --input-type=module -e " +
        q(
          "import {verifyPreviousRuntimeSource} from './scripts/rollback-joedesk.mjs'; verifyPreviousRuntimeSource(" +
            JSON.stringify(previous) +
            ");",
        ),
      "python3 tests/T100-joedesk-release.py",
      'test "$(docker image ls --no-trunc --quiet ' +
        q(previous.pusher.image) +
        ')" = ' +
        q(record.pusher_image_id),
      "test -e /nix/var/nix/profiles/system-" +
        record.hsb0_generation +
        "-link",
      "just switch",
      // Both services share this exact retained runtime. The executor application
      // source must also be restored from its declared nixcfg source revision.
      hsbCompose + " ps --status running joe-board-pusher paper-desk-executor",
      "sudo systemctl start compose-hsb0-update.timer",
    ],
  };
}
async function main() {
  if (os.hostname().toLowerCase().split(".")[0] !== "csb0")
    throw new Error("rollback_requires_csb0");
  if (!process.stdin.isTTY || !process.stdout.isTTY)
    throw new Error("interactive_operator_required");
  const values = process.argv.slice(2);
  if (values.length !== 0 && (values.length !== 2 || values[0] !== "--record"))
    throw new Error("usage");
  const recordPath = values[1] || "/var/lib/joedesk-rollback/record.json";
  const stat = fs.lstatSync(recordPath);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.mode & 0o077 ||
    ![0, process.getuid()].includes(stat.uid)
  )
    throw new Error("private_operator_record_required");
  const record = JSON.parse(fs.readFileSync(recordPath));
  const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  process.chdir(repo);
  const release = JSON.parse(
    fs.readFileSync("hosts/csb0/joedesk-release.json"),
  );
  const plan = rollbackPlan(record, release);
  const manifest = fs.readFileSync(
    path.join(record.v1_backup, "backup-manifest.json"),
  );
  if (
    sha(manifest) !== record.backup_manifest_sha256 ||
    JSON.parse(manifest).boardSchema !== "v1"
  )
    throw new Error("v1_backup_record_mismatch");
  if (
    !record.prepare_source.startsWith("/nix/store/") ||
    !fs.existsSync(path.join(record.prepare_source, "scripts/prepare-data.mjs"))
  )
    throw new Error("retained_immutable_prepare_source_required");
  if (
    !fs.existsSync(
      "/nix/var/nix/profiles/system-" + record.csb0_generation + "-link",
    )
  )
    throw new Error("retained_generation_missing");
  if (
    docker([
      "image",
      "ls",
      "--no-trunc",
      "--quiet",
      plan.previous.board.image,
    ]) !== record.board_image_id
  )
    throw new Error("retained_board_image_missing");
  if (git("status", "--porcelain", "--untracked-files=no"))
    throw new Error("clean_reviewed_checkout_required");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  async function confirm(text) {
    if (!/^y$/i.test((await rl.question(text + " [y/N] ")).trim()))
      throw new Error("operator_declined");
  }
  async function step(text, command, args) {
    await confirm(text);
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0)
      throw new Error("operator_step_failed_writers_remain_stopped");
  }
  try {
    await step(
      "Fetch the reviewed rollback target before stopping any writer",
      "git",
      ["fetch", "origin", "main"],
    );
    verifyRollbackTarget(record, plan.previous);
    console.log(
      "On hsb0, run these commands individually; the final ps must print no IDs:\n" +
        plan.crossStop.join("\n"),
    );
    await confirm(
      "hsb0 pusher/executor and every other writer/editor are stopped; reconciliation and update jobs are paused",
    );
    await step("Pause csb0 reconciliation and update jobs", "sudo", [
      "systemctl",
      "stop",
      "compose-csb0-update.timer",
      "compose-csb0-update.service",
      "compose-csb0.service",
    ]);
    await step("Stop the csb0 board", "sudo", [
      "docker",
      "compose",
      "-p",
      "csb0",
      "-f",
      "/etc/compose/csb0/docker-compose.yml",
      "stop",
      "joe-board",
    ]);
    await step(
      "Fast-forward to the separately reviewed rollback commit",
      "git",
      ["merge", "--ff-only", record.rollback_nixcfg_rev],
    );
    if (git("rev-parse", "HEAD") !== record.rollback_nixcfg_rev)
      throw new Error("rollback_commit_mismatch");
    verifyRollbackTarget(record, plan.previous, git, "HEAD");
    await step(
      "Verify and restore v1 into a NEW sibling, normalize uid/gid and swap while stopped",
      "sudo",
      [
        process.execPath,
        "scripts/joedesk-data-swap.mjs",
        "rollback",
        "--source",
        record.prepare_source,
        "--backup",
        record.v1_backup,
        "--gid",
        "1000",
        "--writers-stopped",
      ],
    );
    await step(
      "Switch through the normal declarative NixOS/Compose path",
      "just",
      ["switch"],
    );
    const container = docker([
      "compose",
      "-p",
      "csb0",
      "-f",
      "/etc/compose/csb0/docker-compose.yml",
      "ps",
      "-q",
      "joe-board",
    ]);
    await confirm(
      "Run exact previous-image private probes and authenticated legacy version/data smoke before restarting writers",
    );
    console.log(
      JSON.stringify(
        await legacySmoke({
          container,
          image: record.board_image_id,
          backup: record.v1_backup,
          base: "https://cs0.barta.cm/joe/",
          cookieJar: record.cookie_jar,
        }),
      ),
    );
    console.log(
      "On hsb0, run these commands individually after confirming the reviewed source pins:\n" +
        plan.crossSwitch.join("\n"),
    );
    await confirm(
      "hsb0 switched the same compatible pins, both services are healthy and reconciliation is verified",
    );
    await step("Resume csb0 update timer", "sudo", [
      "systemctl",
      "start",
      "compose-csb0-update.timer",
    ]);
    console.log(
      JSON.stringify({
        ok: true,
        rollback: "compatible-v1",
        data: "verified-backup",
        smoke: "legacy",
        crossHost: "operator-confirmed",
      }),
    );
  } finally {
    rl.close();
  }
}
if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  try {
    await main();
  } catch (error) {
    console.error(
      "joedesk_rollback_failed: " +
        (/^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "preflight_or_io_error"),
    );
    process.exitCode = 1;
  }
}
