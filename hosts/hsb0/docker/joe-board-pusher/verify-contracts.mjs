import { readFileSync, readdirSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const REVISION = '36fecfeb7e56400db3076304d150e9eeb2beb05b';
const SET_SHA256 = 'c266b39e33e6e15be491263b0ca3575598dd264da3e1a9f6d5a147fc9f1bd49b';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

function filesBelow(root, prefix = '') {
  if (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink()) throw new Error('contract_regular_files_required');
  return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    if (entry.isSymbolicLink() || (!entry.isFile() && !entry.isDirectory())) throw new Error('contract_regular_files_required');
    const name = prefix + entry.name;
    return entry.isDirectory() ? filesBelow(path.join(root, entry.name), `${name}/`) : [name];
  });
}

export function verify() {
  const root = path.dirname(fileURLToPath(import.meta.url));
  const lock = JSON.parse(readFileSync(path.join(root, 'contracts.lock.json'), 'utf8'));
  if (lock.revision !== REVISION || lock.manifest_revision !== 11 || lock.repository !== 'https://github.com/markus-barta/joedesk') throw new Error('contract_pin_drift');
  if (lock.contract_set_sha256 !== SET_SHA256) throw new Error('contract_set_drift');
  const actual = filesBelow(path.join(root, 'contracts')).sort();
  if (JSON.stringify(actual) !== JSON.stringify(Object.keys(lock.files).sort())) throw new Error('contract_closure_drift');
  const entries = actual.map(name => {
    const expected = lock.files[name];
    const bytes = readFileSync(path.join(root, 'contracts', name));
    const sha256 = sha(bytes);
    if (bytes.length !== expected.bytes || sha256 !== expected.sha256) throw new Error('contract_bytes_drift');
    return { path: `contracts/${name}`, size: bytes.length, sha256 };
  });
  // JoeDesk scripts/check-release.mjs:63-66 hashes the compact JSON array
  // of sorted closure entries, retaining this path/size/sha256 property order.
  if (sha(Buffer.from(JSON.stringify(entries))) !== SET_SHA256) throw new Error('contract_set_drift');
  if (JSON.parse(readFileSync(path.join(root, 'contracts/manifest.json'), 'utf8')).revision !== 11) throw new Error('contract_pin_drift');
  return true;
}
