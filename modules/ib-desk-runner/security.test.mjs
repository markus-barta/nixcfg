import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import {
  confinedPath,
  githubRepositoryUrl,
  validatedIssueNumber,
  validatedRepository,
} from "./security.mjs";

test("confined paths stay beneath their fixed root", () => {
  assert.equal(confinedPath("/state", "/state/ledger.json"), path.resolve("/state/ledger.json"));
  assert.equal(confinedPath("/state", "/state/nested/ledger.json"), path.resolve("/state/nested/ledger.json"));
  assert.throws(() => confinedPath("/state", "/state"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "/state/../etc/passwd"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "/state-backup/ledger.json"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "ledger.json"), /must be beneath/);
});

test("repository validation accepts only the allowlisted strict slug", () => {
  assert.equal(validatedRepository("markus-barta/oc-workspace-shared"), "markus-barta/oc-workspace-shared");
  assert.throws(() => validatedRepository("other/repository"), /not allowed/);
  assert.throws(() => validatedRepository("markus-barta/oc-workspace-shared/../other"), /not allowed/);
  assert.throws(() => validatedRepository("https://api.example.test/owner/repo"), /not allowed/);
});

test("GitHub URLs retain the constant API origin and encoded validated segments", () => {
  assert.equal(validatedIssueNumber(42), 42);
  assert.throws(() => validatedIssueNumber(0), /invalid/);
  assert.throws(() => validatedIssueNumber("42"), /invalid/);
  assert.throws(() => validatedIssueNumber("1/comments"), /invalid/);
  const url = githubRepositoryUrl("markus-barta/oc-workspace-shared", "issues", validatedIssueNumber(42), "comments");
  assert.equal(url.origin, "https://api.github.com");
  assert.equal(url.pathname, "/repos/markus-barta/oc-workspace-shared/issues/42/comments");
});
