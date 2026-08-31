import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = process.argv[2];
if (!source) throw new Error("usage: hostdash-status-bindings.mjs HOSTDASH_SOURCE");

const result = {};
for (const host of ["csb0", "csb1", "hsb8", "hsb9"]) {
  const sandbox = { window: {} };
  const configPath = path.join(source, "hosts", host, "config.js");
  vm.runInNewContext(fs.readFileSync(configPath, "utf8"), sandbox, {
    filename: configPath,
  });

  const services = sandbox.window.HOSTDASH_CONFIG?.services;
  if (!Array.isArray(services)) throw new Error(`${host}: services are missing`);

  result[host] = {
    bindings: Object.fromEntries(
      services.flatMap((service) => {
        const binding = Object.fromEntries(
          ["container", "unit", "extra"]
            .filter((key) => typeof service[key] === "string" && service[key].length > 0)
            .map((key) => [key, service[key]]),
        );
        return Object.keys(binding).length ? [[service.name, binding]] : [];
      }),
    ),
    unbound: services
      .filter((service) => !service.container && !service.unit && !service.extra)
      .map((service) => service.name),
  };
}

process.stdout.write(`${JSON.stringify(result)}\n`);
