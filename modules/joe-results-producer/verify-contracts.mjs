import { readFileSync, readdirSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const REVISION = 'b323c0a57c1440690f85ae35e4e53ade25739b74';
const SET_SHA256 = '2c85a6efca259e352b879f4d6efd514755ab1d99a0b15149fb1a155b77c1aa7d';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

function filesBelow(root, prefix = '') {
  if (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink()) throw new Error('contract_regular_files_required');
  return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    if (entry.isSymbolicLink() || (!entry.isFile() && !entry.isDirectory())) throw new Error('contract_regular_files_required');
    const name = prefix + entry.name;
    return entry.isDirectory() ? filesBelow(path.join(root, entry.name), `${name}/`) : [name];
  });
}

export function verifyContracts(root = path.dirname(fileURLToPath(import.meta.url))) {
  const lock = JSON.parse(readFileSync(path.join(root, 'contracts.lock.json'), 'utf8'));
  if (lock.revision !== REVISION || lock.manifest_revision !== 3 || lock.repository !== 'https://github.com/markus-barta/joedesk') throw new Error('contract_pin_drift');
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
  if (JSON.parse(readFileSync(path.join(root, 'contracts/manifest.json'), 'utf8')).revision !== 3) throw new Error('contract_pin_drift');
  return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) verifyContracts();
