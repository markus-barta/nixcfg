// Small local-engine helpers. Never inspect/dump container configuration or env.
import { execFileSync } from "node:child_process";
import http from "node:http";
export function docker(args, options = {}) {
  try {
    return execFileSync("docker", args, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
      ...options,
    }).trim();
  } catch {
    throw new Error("local_docker_command_failed");
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
