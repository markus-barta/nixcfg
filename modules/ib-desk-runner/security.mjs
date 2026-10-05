import path from "node:path";

const ALLOWED_REPOSITORY = "markus-barta/oc-workspace-shared";
const REPOSITORY_SLUG = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})$/;

export function confinedPath(root, candidate, label = "path") {
  if (typeof candidate !== "string" || candidate.length === 0 || candidate.includes("\0")) {
    throw new Error(`${label} is invalid`);
  }
  const resolvedRoot = path.resolve(root);
  const resolvedPath = path.resolve(candidate);
  const relative = path.relative(resolvedRoot, resolvedPath);
  if (!resolvedPath.startsWith(`${resolvedRoot}${path.sep}`)
      || relative === "" || relative === ".." || relative.startsWith(`..${path.sep}`)
      || path.isAbsolute(relative)) {
    throw new Error(`${label} must be beneath ${resolvedRoot}`);
  }
  return resolvedPath;
}

export function validatedRepository(candidate) {
  if (typeof candidate !== "string" || !REPOSITORY_SLUG.test(candidate)
      || candidate !== ALLOWED_REPOSITORY) {
    throw new Error("GitHub repository is not allowed");
  }
  return ALLOWED_REPOSITORY;
}

export function validatedIssueNumber(candidate) {
  if (!Number.isSafeInteger(candidate) || candidate <= 0) {
    throw new Error("GitHub issue number is invalid");
  }
  return candidate;
}

export function githubRepositoryUrl(repository, ...segments) {
  const [owner, name] = validatedRepository(repository).split("/");
  const pathname = ["repos", owner, name, ...segments]
    .map((segment) => encodeURIComponent(String(segment)))
    .join("/");
  return new URL(pathname, "https://api.github.com/");
}
