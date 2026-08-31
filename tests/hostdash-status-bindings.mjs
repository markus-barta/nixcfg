import fs from "node:fs";

const MAX_CONFIG_BYTES = 1024 * 1024;
const MAX_NESTING_DEPTH = 32;
const ASSIGNMENT = "window.HOSTDASH_CONFIG = ";
const source = fs.readFileSync(0, "utf8");

function fail(reason) {
  throw new Error(`static HostDash config rejected: ${reason}`);
}

if (Buffer.byteLength(source, "utf8") > MAX_CONFIG_BYTES)
  fail("oversized input");

const text = source.trim();
if (!text.startsWith(ASSIGNMENT)) fail("unexpected assignment");

let position = ASSIGNMENT.length;

function skipSpace() {
  while (position < text.length && /\s/.test(text[position])) position += 1;
}

function parseString() {
  const start = position;
  position += 1;
  let escaped = false;
  for (; position < text.length; position += 1) {
    const character = text[position];
    if (!escaped && character === '"') {
      position += 1;
      try {
        return JSON.parse(text.slice(start, position));
      } catch {
        fail("invalid JSON string");
      }
    }
    if (!escaped && character === "\\") {
      escaped = true;
    } else {
      escaped = false;
    }
  }
  fail("unterminated string");
}

function parseIdentifier() {
  const identifier = text
    .slice(position)
    .match(/^[A-Za-z_$][A-Za-z0-9_$]*/)?.[0];
  if (!identifier) fail("non-static property key");
  position += identifier.length;
  return identifier;
}

function parseObject(depth) {
  if (depth > MAX_NESTING_DEPTH) fail("excessive nesting");
  const result = new Map();
  position += 1;
  skipSpace();
  if (text[position] === "}") {
    position += 1;
    return result;
  }

  while (position < text.length) {
    const key = parseIdentifier();
    if (result.has(key)) fail("duplicate property key");
    skipSpace();
    if (text[position] !== ":") fail("property separator is missing");
    position += 1;
    result.set(key, parseValue(depth + 1));
    skipSpace();
    if (text[position] === "}") {
      position += 1;
      return result;
    }
    if (text[position] !== ",") fail("property delimiter is missing");
    position += 1;
    skipSpace();
    if (text[position] === "}") {
      position += 1;
      return result;
    }
  }
  fail("object is not closed");
}

function parseArray(depth) {
  if (depth > MAX_NESTING_DEPTH) fail("excessive nesting");
  const result = [];
  position += 1;
  skipSpace();
  if (text[position] === "]") {
    position += 1;
    return result;
  }

  while (position < text.length) {
    result.push(parseValue(depth + 1));
    skipSpace();
    if (text[position] === "]") {
      position += 1;
      return result;
    }
    if (text[position] !== ",") fail("array delimiter is missing");
    position += 1;
    skipSpace();
    if (text[position] === "]") {
      position += 1;
      return result;
    }
  }
  fail("array is not closed");
}

function parseValue(depth) {
  skipSpace();
  if (text[position] === '"') return parseString();
  if (text[position] === "{") return parseObject(depth);
  if (text[position] === "[") return parseArray(depth);

  const tail = text.slice(position);
  for (const [literal, value] of [
    ["true", true],
    ["false", false],
    ["null", null],
  ]) {
    if (tail.startsWith(literal)) {
      position += literal.length;
      return value;
    }
  }

  const number = tail.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
  if (number) {
    position += number[0].length;
    const value = Number(number[0]);
    if (!Number.isFinite(value)) fail("non-finite number");
    return value;
  }
  fail("non-literal property value");
}

const config = parseValue(0);
skipSpace();
if (text[position] !== ";") fail("assignment terminator is missing");
position += 1;
skipSpace();
if (position !== text.length) fail("unexpected trailing statement");
if (!(config instanceof Map)) {
  fail("configuration must be an object literal");
}
const services = config.get("services");
if (!Array.isArray(services) || services.length === 0)
  fail("services are missing");

const bindings = [];
const unbound = [];
const serviceNames = new Set();
for (const service of services) {
  if (!(service instanceof Map)) fail("service must be an object literal");

  const serviceName = service.get("name");
  if (typeof serviceName !== "string" || serviceName.length === 0)
    fail("invalid service name");
  if (serviceNames.has(serviceName)) fail("duplicate service name");
  serviceNames.add(serviceName);

  const runtimeBindings = [];
  for (const binding of [
    {
      kind: "container",
      present: service.has("container"),
      target: service.get("container"),
    },
    { kind: "unit", present: service.has("unit"), target: service.get("unit") },
    {
      kind: "extra",
      present: service.has("extra"),
      target: service.get("extra"),
    },
  ]) {
    if (!binding.present) continue;
    if (typeof binding.target !== "string" || binding.target.length === 0) {
      fail("invalid runtime binding");
    }
    runtimeBindings.push(binding);
  }
  if (runtimeBindings.length > 1) fail("ambiguous runtime binding");
  if (runtimeBindings.length === 0) {
    unbound.push(serviceName);
    continue;
  }

  const runtime = runtimeBindings[0];
  if (runtime.kind === "container") {
    bindings.push({ name: serviceName, container: runtime.target });
  } else if (runtime.kind === "unit") {
    bindings.push({ name: serviceName, unit: runtime.target });
  } else {
    bindings.push({ name: serviceName, extra: runtime.target });
  }
}

process.stdout.write(`${JSON.stringify({ bindings, unbound })}\n`);
