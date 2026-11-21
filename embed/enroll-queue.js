'use strict';
// fez enroll-queue. Lets a new Mac hand over its cert without ssh access.
// Port 8000 is internet facing via nginx and trades a code for an enrollment;
// 8001 streams events to admin-ui, which owns the pending invitations.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');

const PUBLIC_PORT = Number(process.env.PUBLIC_PORT || 8000);
const PRIVILEGED_PORT = Number(process.env.PRIVILEGED_PORT || 8001);
const BIND = process.env.BIND || '0.0.0.0';

// A certificate is ~1-2 KB. Anything much larger is not a certificate.
const MAX_BODY = 16 * 1024;
const MAX_BACKLOG = 1000;
const CODE_PATTERN = /^[a-f0-9]{32}$/;
const ENROLL_FILE = process.env.ENROLL_FILE || '/etc/fez/enrollments.json';

let cache = { mtime: -1, byHash: new Map() }; // stat-time cache of ENROLL_FILE
const listeners = new Set(); // admin-ui connections

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function json(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': payload.length,
    'cache-control': 'no-store',
  });
  res.end(payload);
}

// Reads a request body, refusing anything oversized rather than buffering it.
function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// Separate digests: the stored id must not also be the encryption key.
function idOf(code) {
  return crypto.createHash('sha256').update('fez-id:' + code).digest('hex');
}

function keyOf(code) {
  return crypto.createHash('sha256').update('fez-key:' + code).digest();
}

function openPassword(code, sealed) {
  const [iv, tag, body] = String(sealed || '').split('.');
  const d = crypto.createDecipheriv('aes-256-gcm', keyOf(code), Buffer.from(iv, 'hex'));
  d.setAuthTag(Buffer.from(tag, 'hex'));
  return Buffer.concat([d.update(Buffer.from(body, 'hex')), d.final()]).toString('utf8');
}

// admin-ui owns the file and stores only hashes and share passwords encrypted
// with the hash.
function pendingByHash() {
  let stat;
  try {
    stat = fs.statSync(ENROLL_FILE);
  } catch {
    return new Map();
  }
  if (stat.mtimeMs === cache.mtime) return cache.byHash;

  const byHash = new Map();
  try {
    for (const entry of JSON.parse(fs.readFileSync(ENROLL_FILE, 'utf8'))) {
      if (entry && typeof entry.hash === 'string') byHash.set(entry.hash, entry);
    }
  } catch (err) {
    log('cannot read', ENROLL_FILE + ':', err.message);
    return cache.byHash;
  }
  cache = { mtime: stat.mtimeMs, byHash };
  return byHash;
}

// Held in case admin-ui has disconnected, so the share is still added.
const backlog = [];

// Send event to connected admin-ui container.
function publish(event) {
  const line = JSON.stringify(event) + '\n';
  if (!listeners.size) {
    backlog.push(line);
    if (backlog.length > MAX_BACKLOG) backlog.shift();
    log('nobody on the bus, holding', backlog.length, 'event(s)');
    return;
  }
  for (const res of listeners) {
    try {
      res.write(line);
    } catch { // tried to write to closed listener
      listeners.delete(res);
    }
  }
}

// ---------------------------------------------------------------- public ----

// This server listens on the public internet and implements 1 route:
// POST /enroll/<code>
const publicServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const match = url.pathname.match(/^\/enroll\/([^/]+)$/);

  if (req.method !== 'PUT' || !match) {
    json(res, 404, { error: 'not found' });
    return;
  }

  const code = match[1];
  if (!CODE_PATTERN.test(code)) {
    json(res, 404, { error: 'unknown code' });
    return;
  }

  const entry = pendingByHash().get(idOf(code));
  if (!entry || (entry.expires && entry.expires <= Date.now())) {
    json(res, 404, { error: 'unknown code' });
    return;
  }

  let cert;
  try {
    cert = await readBody(req);
  } catch {
    json(res, 413, { error: 'certificate too large' });
    return;
  }

  // Parsed, not pattern matched, so junk can't reach the trusted bundle.
  let parsed;
  try {
    parsed = new crypto.X509Certificate(cert);
  } catch {
    json(res, 400, { error: 'not a certificate' });
    return;
  }

  // Before publishing: a failure here must not spend the invitation.
  let password;
  try {
    password = openPassword(code, entry.sealed);
  } catch (err) {
    log('cannot unseal password for', entry.user + ':', err.message);
    json(res, 500, { error: 'could not unseal the share password' });
    return;
  }

  // The code in the clear proves a client presented it; admin-ui spends it.
  publish({
    type: 'enroll',
    user: entry.user,
    code,
    cert: parsed.toString(),
    fingerprint: parsed.fingerprint256,
  });
  log('enrolled', entry.user, parsed.fingerprint256);

  json(res, 200, { user: entry.user, password });
});

// ----------------------------------------------------------- privileged ----

// This server listens on a private port that only admin-ui can connect
// to and listen for events on.
const privilegedServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (req.method === 'GET' && url.pathname === '/bus') {
    res.writeHead(200, {
      'content-type': 'application/x-ndjson',
      'cache-control': 'no-store',
      connection: 'keep-alive',
    });
    listeners.add(res);
    log('bus listener attached, now', listeners.size);
    while (backlog.length) res.write(backlog.shift());
    req.on('close', () => {
      listeners.delete(res);
      log('bus listener gone, now', listeners.size);
    });
    return;
  }

  json(res, 404, { error: 'not found' });
});

// Don't let a slow client hold a connection open forever.
for (const server of [publicServer, privilegedServer]) {
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
}

// The bus is long lived, so it opts out of the request timeout.
privilegedServer.requestTimeout = 0;

publicServer.listen(PUBLIC_PORT, BIND, () =>
  log('public port', PUBLIC_PORT, '(enroll only)'));
privilegedServer.listen(PRIVILEGED_PORT, BIND, () =>
  log('privileged port', PRIVILEGED_PORT));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    log('shutting down');
    publicServer.close();
    privilegedServer.close();
    process.exit(0);
  });
}
