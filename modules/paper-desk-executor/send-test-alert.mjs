import path from "node:path";
import { pathToFileURL } from "node:url";
import { postLocalMessage } from "./local-mailbox-client.mjs";

export async function sendTestAlert(socketPath, post = postLocalMessage) {
  await post(socketPath, "[TEST] JOED-43 capture alert path check");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  sendTestAlert(process.env.PAPER_DESK_MAILBOX_SOCKET).then(
    () => console.log("JOED-43 test alert delivered"),
    () => { console.error("JOED-43 test alert failed"); process.exitCode = 1; },
  );
}
