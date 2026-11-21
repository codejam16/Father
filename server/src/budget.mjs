import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { APIError } from './contract.mjs';

export class Budget {
  constructor(path, limit) {
    this.path = path;
    this.limit = limit;
    this.used = 0;
    if (existsSync(path)) {
      const value = JSON.parse(readFileSync(path, 'utf8'));
      if (!Number.isSafeInteger(value.used) || value.used < 0) throw new Error('Invalid request allowance file; refusing to reset it.');
      this.used = value.used;
    }
  }

  reserve() {
    if (this.used >= this.limit) throw new APIError(429, 'request_allowance_exhausted', 'The configured live-request allowance is exhausted.');
    mkdirSync(dirname(this.path), { recursive: true });
    // Reserve before contacting the provider. One server process must own this file.
    writeFileSync(`${this.path}.tmp`, JSON.stringify({ used: this.used + 1 }), { mode: 0o600 });
    renameSync(`${this.path}.tmp`, this.path);
    this.used += 1;
  }
}
