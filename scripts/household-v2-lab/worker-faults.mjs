// Loaded only by the lab's lock-holding worker, never copied into the image.
import fs from "node:fs";
const original = fs.fsyncSync;
fs.fsyncSync = (...args) => {
  const flag = "/run/joe-household-v2/lab-fault";
  if (fs.existsSync(flag)) {
    const fault = fs.readFileSync(flag, "utf8");
    fs.unlinkSync(flag); // This lab's own one-shot request, never production state.
    if (fault === "hang") Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
    if (fault === "oom") {
      const held = [];
      // Touch physical pages; do not rely on V8 heap exhaustion or lazy allocation.
      for (;;) held.push(Buffer.alloc(8 * 1024 * 1024, 0xa5));
    }
  }
  return original(...args);
};
