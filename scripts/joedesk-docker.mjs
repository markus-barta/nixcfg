// Small local-engine helpers. Never inspect/dump container configuration or env.
import { execFileSync } from "node:child_process";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
export function docker(args, options = {}, execute = execFileSync) {
  try {
    return execute("docker", args, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
      ...options,
    }).trim();
  } catch (error) {
    const command = /^[a-z]+$/.test(args[0]) ? args[0] : "unknown";
    const status = Number.isInteger(error.status)
      ? error.status
      : "unavailable";
    throw new Error(`local_docker_command_failed_${command}_exit_${status}`);
  }
}
export function resolveLocalDockerSocket({ context, host, inspect }) {
  // Docker documents DOCKER_CONTEXT as taking precedence over DOCKER_HOST.
  // Inspect only that one endpoint field, never a container's configuration.
  const endpoint = context ? inspect() : host || inspect();
  if (!endpoint.startsWith("unix://"))
    throw new Error("local_unix_docker_required");
  return endpoint.slice("unix://".length);
}
export function localDockerSocket() {
  return resolveLocalDockerSocket({
    context: process.env.DOCKER_CONTEXT,
    host: process.env.DOCKER_HOST,
    inspect: () =>
      docker(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]),
  });
}
export function requireLabDocker(
  root,
  command = docker,
  socket = localDockerSocket,
) {
  socket();
  // A local Unix socket may itself forward to a production engine.
  const engine = command(["info", "--format", "{{.Name}}"]);
  if (!engine || /^(csb|hsb|agm)/i.test(engine))
    throw new Error("fleet_docker_is_not_a_lab");
  const marker = randomUUID();
  fs.writeFileSync(path.join(root, "docker-visibility-marker"), marker, {
    flag: "wx",
    mode: 0o644,
  });
  try {
    const result = command([
      "run",
      "--rm",
      "--network",
      "none",
      "-v",
      root + ":/lab:ro",
      "--entrypoint",
      "node",
      "node:22-alpine",
      "--input-type=module",
      "-e",
      "import fs from 'node:fs'; process.stdout.write(fs.readFileSync('/lab/docker-visibility-marker','utf8'));",
    ]);
    if (result !== marker) throw new Error("marker_mismatch");
  } catch {
    throw new Error("lab_root_not_visible_to_docker");
  }
}
export async function runningImage(container) {
  // The LIST endpoint has ImageID and no resolved environment. Do not use the
  // inspect endpoint, even with output filtering.
  const socketPath = localDockerSocket();
  const records = await new Promise((resolve, reject) => {
    const req = http.get(
      { socketPath, path: "/containers/json", timeout: 10000 },
      (res) => {
        const chunks = [];
        let length = 0;
        res.on("data", (c) => {
          length += c.length;
          if (length > 8 * 1024 * 1024)
            req.destroy(new Error("docker_list_size"));
          else chunks.push(c);
        });
        res.on("end", () => {
          try {
            if (res.statusCode !== 200) throw new Error("docker_list_failed");
            resolve(JSON.parse(Buffer.concat(chunks)));
          } catch (e) {
            reject(e);
          }
        });
      },
    );
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("docker_list_timeout")));
  });
  const found = records.filter(
    (r) => r.Id === container || r.Names?.includes("/" + container),
  );
  if (found.length !== 1 || found[0].State !== "running")
    throw new Error("exact_running_container_required");
  return found[0].ImageID;
}
