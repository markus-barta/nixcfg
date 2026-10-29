"""OPS-327 shared offline fixtures; never imported by the installed GC."""

from __future__ import annotations

import ast
import json
import os
import socket
import threading
import time
import types
from pathlib import Path

PHASE_FIRST_S = 18
PHASE_LAST_S = 45
STREAM_GAP_S = 9
STREAM_BYTES = 3


# These are protocol values, never filesystem paths. Every Load of a named
# exception must be the Engine-path argument at the specified call site.
NON_FILESYSTEM_NAMES = {"PRUNE_PATH": ("destructive_call", 2)}
HTTP_LITERALS = {"/containers/json?all=1": ("get_json", 1),
                 "/images/json": ("get_json", 1), "/images/": ("destructive_call", 2)}
# A slash inside a reference/diagnostic label is not an absolute filesystem
# path. Exact expressions keep a newly introduced open('/') from inheriting it.
SLASH_EXPRESSIONS = {"rest.rfind('/')", "rest.partition('/')", "'/' not in path",
                     "f'{domain}/{path}'", "f'{stack}/{name}'"}


def execute_source(source):
    # Trusted, copied GC source only. __name__ prevents the CLI entry point.
    module = types.ModuleType("gc_fixture")
    exec(compile(source.replace("@DECLARED_REFS@", "[]"), "docker-image-gc.py", "exec"), module.__dict__)
    return module


def absolute_path(value):
    return isinstance(value, (str, bytes, os.PathLike)) and os.path.isabs(os.fspath(value))


def contains_path(value):
    if absolute_path(value):
        return True
    return isinstance(value, (list, tuple, set, frozenset)) and any(contains_path(item) for item in value)


def path_constants(source, module=None):
    """Inventory executed globals, then reject unowned absolute source literals.

    Derived constants are independent keys: the fixture must override each one.
    Module-level if/try, computed expressions and aliases need no AST evaluator.
    Imports/definitions must remain free of filesystem I/O, as in production.
    """
    module = execute_source(source) if module is None else module
    found = {name for name, value in vars(module).items() if contains_path(value)}
    tree = ast.parse(source)
    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}

    def call_argument(node, rule):
        call = parents.get(node)
        return (isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                and call.func.id == rule[0] and len(call.args) > rule[1] and call.args[rule[1]] is node)

    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id in NON_FILESYSTEM_NAMES:
            if not call_argument(node, NON_FILESYSTEM_NAMES[node.id]):
                raise ValueError(f"non-filesystem name used outside Engine path: {node.id}")
    found -= NON_FILESYSTEM_NAMES.keys()

    for node in ast.walk(tree):
        if not isinstance(node, ast.Constant) or not absolute_path(node.value):
            continue
        lineage, ancestor = [], node
        while ancestor in parents:
            ancestor = parents[ancestor]
            lineage.append(ancestor)
        # Only module-scope assignments own path literals. A local path, even
        # with the same spelling as a global, must not evade the inventory.
        owner = next((item for item in lineage if isinstance(item, (ast.Assign, ast.AnnAssign))), None)
        if owner is not None and not any(isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda))
                                         for item in lineage):
            targets = owner.targets if isinstance(owner, ast.Assign) else [owner.target]
            names = {part.id for target in targets for part in ast.walk(target) if isinstance(part, ast.Name)}
            if names & found:
                continue
            if names == {"PRUNE_PATH"} and node.value == "/build/prune?":
                continue
        expression = parents[node]
        if node.value == "/" and ast.unparse(expression) in SLASH_EXPRESSIONS:
            continue
        # A DELETE f-string's absolute prefix belongs to its complete Engine
        # argument, not to an arbitrary use of the same prefix elsewhere.
        argument = expression if isinstance(expression, ast.JoinedStr) else node
        if node.value in HTTP_LITERALS and call_argument(argument, HTTP_LITERALS[node.value]):
            continue
        raise ValueError(f"uninventoried absolute path at line {node.lineno}: {node.value!r}")
    return found


def check_path_contract(source, paths, module=None):
    expected = path_constants(source, module)
    if set(paths) != expected:
        raise ValueError(f"path keys: missing={sorted(expected - set(paths))}, extra={sorted(set(paths) - expected)}")


def check_socket(path):
    # A missing fixture override must never fall back to the source's host
    # Docker socket, including when the source is a connect-bypass mutant.
    socket_path = Path(path).resolve()
    if socket_path in {Path("/var/run/docker.sock").resolve(), Path("/run/docker.sock").resolve()}:
        raise ValueError("offline fixture cannot use a host Docker socket")


def load(source, paths):
    check_socket(paths["SOCKET_PATH"])
    module = execute_source(source)
    check_path_contract(source, paths, module)
    for key, value in paths.items():
        setattr(module, key, value)
    return module


def image(n, tags=(), digests=()):
    return {"Id": f"sha256:{n:064x}", "Created": 1, "Size": 10,
            "RepoTags": list(tags), "RepoDigests": list(digests)}


def fixture(root, **overrides):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    paths = {"STORE_DIR": str(root / "store"), "PROFILES_DIR": str(root / "profiles"),
             "KEEP_DIR": str(root / "keep.d"), "CURRENT_SYSTEM": str(root / "current"),
             "BOOTED_SYSTEM": str(root / "booted"), "INSTANCE_LOCK": str(root / "instance.lock"),
             "SWITCH_LOCK": str(root / "switch.lock"), "PROC": "/proc", "PROC_LOCKS": "/proc/locks",
             "SOCKET_PATH": str(root / "engine.sock"),
             "LOCK_PATHS": tuple(str(root / f"compose-{n}.lock") for n in range(3))}
    paths.update(overrides)
    for key in ("STORE_DIR", "PROFILES_DIR", "KEEP_DIR"):
        Path(paths[key]).mkdir(parents=True, exist_ok=True)
    for key in ("INSTANCE_LOCK", "SWITCH_LOCK", "SOCKET_PATH"):
        Path(paths[key]).parent.mkdir(parents=True, exist_ok=True)
    for path in paths["LOCK_PATHS"]:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).touch()
    aeon = "ghcr.io/inspr-at/aeon"
    live = f"{aeon}@sha256:{100:064x}"
    previous = f"{aeon}@sha256:{101:064x}"
    images = [image(1, [f"{aeon}:live"], [live]), image(2, [f"{aeon}:previous"], [previous])]
    images += [image(n) for n in range(10, 16)]
    containers = [{"Id": "live", "ImageID": images[0]["Id"], "Image": f"{aeon}:live", "State": "running"}]
    system = Path(paths["STORE_DIR"]) / ("0" * 32 + "-nixos-system-fixture")
    spec = system / "etc/compose/csb1/docker-compose.yml"
    spec.parent.mkdir(parents=True, exist_ok=True)
    spec.write_text(json.dumps({"services": {"live": {"image": live}}}))
    for path in [Path(paths["PROFILES_DIR"]) / "system-1-link", Path(paths["CURRENT_SYSTEM"]), Path(paths["BOOTED_SYSTEM"])]:
        if not path.is_symlink():
            path.symlink_to(system)
    Path(paths["KEEP_DIR"], "aeon-live.refs").write_text(live + "\n")
    Path(paths["KEEP_DIR"], "aeon-previous.refs").write_text(previous + "\n")
    return paths, images, containers, spec


def fragments(phase, body):
    status = b"HTTP/1.1 200 OK\r\n"
    length = f"Content-Length: {len(body)}\r\n\r\n".encode()
    chunked = b"Transfer-Encoding: chunked\r\n\r\n"
    size = f"{len(body):x}\r\n".encode()
    if phase == "status":
        return b"", b"HTTP/1.1 ", b"200 OK\r\n" + length + body
    if phase == "header":
        return status, b"Content-Len", length[len(b"Content-Len"):] + body
    if phase == "chunk-size":
        return status + chunked, size[:1], size[1:] + body + b"\r\n0\r\n\r\n"
    if phase == "chunk-data":
        return status + chunked + size, body[:1], body[1:] + b"\r\n0\r\n\r\n"
    if phase == "body":
        return status + length, body[:1], body[1:]
    raise ValueError(phase)


class Engine:
    """Real AF_UNIX HTTP server, independent connection thread per request.

    delay can be a list (per destructive call) or a scalar. phase uses two
    fragments at 18 and 45 seconds. Each gap stays below a plain 30-second
    timeout even with 1 second of scheduling delay; the first fragment is
    safely before the absolute deadline. stop interrupts timers on cleanup.
    """

    def __init__(self, path, images=(), containers=(), *, delay=0, phase=None, scale=1, on_request=None):
        self.path, self.images, self.containers = path, list(images), list(containers)
        self.delay, self.phase, self.scale = delay, phase, scale
        self.on_request = on_request
        self.stop = threading.Event()
        self.sent = threading.Event()
        self.calls = []
        self.destructive = []
        self.threads = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.server.bind(path)
            self.server.listen(16)
            self.server.settimeout(0.1)
        except BaseException:
            self.server.close()
            raise
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(target=self.answer, args=(conn,), daemon=True)
            self.threads.append(thread)
            thread.start()

    def answer(self, conn):
        with conn:
            conn.settimeout(2)
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    part = conn.recv(65536)
                    if not part:
                        return
                    data += part
                method, path, _ = data.split(b"\r\n", 1)[0].decode().split()
                self.calls.append((method, path, time.monotonic()))
                if self.on_request:
                    self.on_request(method, path)
                if method == "GET":
                    body = json.dumps(self.containers if path.startswith("/containers/") else self.images).encode()
                else:
                    index = len(self.destructive)
                    self.destructive.append((method, path, time.monotonic()))
                    self.sent.set()
                    body = b'{"SpaceReclaimed":0,"CachesDeleted":[]}' if method == "POST" else b"[]"
                    if self.phase == "stream":
                        stream = b" " * 60 + body
                        conn.sendall(f"HTTP/1.1 200 OK\r\nContent-Length: {len(stream)}\r\n\r\n".encode())
                        # Send at 9, 18 and 27 s, then stay silent. A fresh
                        # per-receive timeout waits until ~57 s; the absolute
                        # deadline ends at ~30 s, independent of byte alignment.
                        for byte in stream[:STREAM_BYTES]:
                            if self.stop.wait(STREAM_GAP_S * self.scale):
                                return
                            conn.sendall(bytes([byte]))
                        self.stop.wait(600 * self.scale)
                        return
                    if self.phase:
                        pre, first, last = fragments(self.phase, body)
                        conn.sendall(pre)
                        if self.stop.wait(PHASE_FIRST_S * self.scale):
                            return
                        conn.sendall(first)
                        if self.stop.wait((PHASE_LAST_S - PHASE_FIRST_S) * self.scale):
                            return
                        conn.sendall(last)
                        return
                    delay = self.delay[min(index, len(self.delay) - 1)] if isinstance(self.delay, list) else self.delay
                    if self.stop.wait(delay * self.scale):
                        return
                    if method == "DELETE":
                        image_id = path.split("/images/", 1)[1].split("?", 1)[0]
                        self.images[:] = [i for i in self.images if i["Id"] != image_id]
                conn.sendall(f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
            except OSError:
                pass

    def close(self):
        self.stop.set()
        self.server.close()
        self.thread.join(2)
        for thread in self.threads:
            thread.join(2)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
