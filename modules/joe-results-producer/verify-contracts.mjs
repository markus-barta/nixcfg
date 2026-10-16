import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

export function verifyContracts(root = path.dirname(fileURLToPath(import.meta.url))) {
  const lock = JSON.parse(readFileSync(path.join(root, 'contracts.lock.json'), 'utf8'));
  if (lock.revision !== '9550f81b448110bfa8fb3ea8df0956430012d5e1' || lock.repository !== 'https://github.com/markus-barta/joedesk') throw new Error('contract_pin_drift');
  const actual = readdirSync(path.join(root, 'contracts')).sort();
  if (JSON.stringify(actual) !== JSON.stringify(Object.keys(lock.files).sort())) throw new Error('contract_closure_drift');
  for (const [name, expected] of Object.entries(lock.files)) {
    const bytes = readFileSync(path.join(root, 'contracts', name));
    if (bytes.length !== expected.bytes || createHash('sha256').update(bytes).digest('hex') !== expected.sha256) throw new Error('contract_bytes_drift');
  }
  return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) verifyContracts();
