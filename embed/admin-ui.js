'use strict';

// fez admin-ui. Only accessible through nginx with an admin cert.
// Lists and creates shares, and watches enroll-queue's bus to
// trust new certs.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');

const PORT = Number(process.env.PORT || 8000);
const BIND = process.env.BIND || '0.0.0.0';
const CONF_DIR = process.env.FEZ_DIR || '/etc/fez';
const USERS_DIR = path.join(CONF_DIR, 'users');
const CLIENT_CERTS = path.join(CONF_DIR, 'client-certs.pem');
const DATA_DIR = process.env.TM_DATA_DIR || '/tm';
const INSTALLER = process.env.FEZ_INSTALLER || '/app/install.sh';
const ENROLL_QUEUE = process.env.ENROLL_QUEUE || 'http://enroll-queue:8001';
const ENROLL_FILE = process.env.ENROLL_FILE || path.join(CONF_DIR, 'enrollments.json');
const ENROLL_TTL_MS = 14 * 24 * 60 * 60 * 1000;
const DOCKER_LOGS = process.env.DOCKER_LOG_DIR || '/var/lib/docker/containers';
const LOG_TAIL = 1024 * 1024;
// Off in tests, where there is no nginx or Samba to signal.
const SIGNAL_PROCESSES = process.env.SIGNAL_PROCESSES !== '0';
const SIGNAL_DIR = process.env.FEZ_SIGNALS || '/signals';

// Matches ADMIN_LABEL in install.sh; only used for the instructions below.
const ADMIN_LABEL = 'com.fezbackup.admin';

const USER_PATTERN = /^[a-z0-9][a-z0-9-]{0,30}$/;
const QUOTA_PATTERN = /^[0-9]{1,6} ?[GTM]$/i;

/** Shown once after a share is created, so the admin can copy the details. */
let lastInvite = null;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ------------------------------------------------------------- the shares ---

function readShares() {
  let files = [];
  try {
    files = fs.readdirSync(USERS_DIR).filter((f) => f.endsWith('.conf'));
  } catch {
    return [];
  }

  return files.map((file) => {
    const body = fs.readFileSync(path.join(USERS_DIR, file), 'utf8');
    const field = (name) => {
      const m = body.match(new RegExp('^' + name + '=(.*)$', 'm'));
      return m ? m[1].trim() : '';
    };
    return {
      name: field('SHARE_NAME') || path.basename(file, '.conf'),
      user: field('TM_USERNAME'),
      uid: field('TM_UID'),
      quota: field('VOLUME_SIZE_LIMIT'),
      // Kept so a replacement invitation can hand back the share password.
      password: field('PASSWORD'),
    };
  });
}

function nextUid(shares) {
  let uid = 1000;
  for (const share of shares) {
    const value = Number(share.uid);
    if (Number.isFinite(value) && value >= uid) uid = value + 1;
  }
  return uid;
}

// du is cheap enough here and avoids walking the tree in this process.
function diskUsage(share) {
  return new Promise((resolve) => {
    execFile('du', ['-sk', path.join(DATA_DIR, share)], { timeout: 20_000 },
      (err, stdout) => {
        if (err) return resolve(null);
        const kb = Number(String(stdout).split(/\s+/)[0]);
        resolve(Number.isFinite(kb) ? kb : null);
      });
  });
}

function humanSize(kb) {
  if (kb === null) return 'unknown';
  const units = [['T', 1024 ** 3], ['G', 1024 ** 2], ['M', 1024], ['K', 1]];
  for (const [suffix, size] of units) {
    if (kb >= size) return (kb / size).toFixed(kb >= size * 10 ? 0 : 1) + suffix;
  }
  return '0K';
}

function createShare(name, quota) {
  const shares = readShares();
  if (shares.some((s) => s.name === name)) {
    throw new Error(`share "${name}" already exists`);
  }

  const dir = path.join(DATA_DIR, name);
  let owner = null;
  try {
    const st = fs.statSync(dir);
    // Reusing a name keeps the old uid, or the backups inside are unreadable.
    if (st.isDirectory() && st.uid >= 1000) owner = st.uid;
  } catch {
    // nothing there yet
  }

  const uid = owner === null ? nextUid(shares) : owner;
  const password = crypto.randomBytes(8).toString('hex');

  // Same format the installer writes for the first share.
  const conf = [
    `TM_USERNAME=${name}`,
    `TM_GROUPNAME=${name}`,
    `PASSWORD=${password}`,
    `SHARE_NAME=${name}`,
    `TM_UID=${uid}`,
    `TM_GID=${uid}`,
    `VOLUME_SIZE_LIMIT=${quota || ''}`,
    '',
  ].join('\n');

  fs.writeFileSync(path.join(USERS_DIR, `${name}.conf`), conf, { mode: 0o600 });

  if (owner === null) {
    // Created 0700, not widened then narrowed, so there is no open window.
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    try {
      // chmod while root still owns it, so no CAP_FOWNER is needed.
      fs.chmodSync(dir, 0o700);
      fs.chownSync(dir, uid, uid);
    } catch (err) {
      // Worth knowing about: without this the share is readable by other shares.
      log('WARNING: could not set ownership on', dir, err.message);
    }
  } else {
    log('reusing', dir, 'and its uid', uid);
  }

  log('created share', name, 'uid', uid);
  // smb.conf and the Samba users are only built at boot, so the container has
  // to be restarted entirely.
  poke('samba');
  return { name, uid, password };
}

// --------------------------------------------------------- enroll-queue -----

// Separate digests: the stored id must not also be the encryption key.
function idOf(code) {
  return crypto.createHash('sha256').update('fez-id:' + code).digest('hex');
}

function keyOf(code) {
  return crypto.createHash('sha256').update('fez-key:' + code).digest();
}

// Only a holder of the code can read the password back out.
function sealPassword(code, password) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', keyOf(code), iv);
  const body = Buffer.concat([c.update(String(password), 'utf8'), c.final()]);
  return [iv.toString('hex'), c.getAuthTag().toString('hex'), body.toString('hex')].join('.');
}

// Pending invitations. Only the hash is kept, so a code cannot be read back.
function readEnrollments() {
  try {
    const list = JSON.parse(fs.readFileSync(ENROLL_FILE, 'utf8'));
    return Array.isArray(list) ? list.filter((e) => e && typeof e.hash === 'string') : [];
  } catch {
    return [];
  }
}

// In place: a single file bind mount would not survive a rename.
function writeEnrollments(list) {
  const now = Date.now();
  fs.writeFileSync(
    ENROLL_FILE,
    JSON.stringify(list.filter((e) => !e.expires || e.expires > now), null, 1) + '\n',
  );
}

// ------------------------------------------------------- trusting a Mac -----

// A "#fez user=alice added=2026-09-10" line is kept above each cert
const ANNOTATION = /^#fez\s+(.*)$/;

function annotate(user, added) {
  return `#fez user=${user} added=${added || new Date().toISOString().slice(0, 10)}\n`;
}

// Pairs each cert with the annotation above it. Ones without are still
// returned, so a hand-edited bundle shows up rather than vanishing.
function readTrustedCerts() {
  let text;
  try {
    text = fs.readFileSync(CLIENT_CERTS, 'utf8');
  } catch {
    return [];
  }

  const out = [];
  let pending = null;
  let block = null;

  for (const line of text.split('\n')) {
    if (block === null) {
      const note = line.match(ANNOTATION);
      if (note) {
        const fields = {};
        for (const pair of note[1].trim().split(/\s+/)) {
          const [k, v] = pair.split('=');
          if (k) fields[k] = v || '';
        }
        pending = fields;
        continue;
      }
      if (line.startsWith('-----BEGIN CERTIFICATE-----')) block = [line];
      continue;
    }

    block.push(line);
    if (!line.startsWith('-----END CERTIFICATE-----')) continue;

    const pem = block.join('\n') + '\n';
    block = null;
    const owner = pending;
    pending = null;

    try {
      const cert = new crypto.X509Certificate(pem);
      out.push({
        pem,
        user: (owner && owner.user) || null,
        added: (owner && owner.added) || null,
        fingerprint: cert.fingerprint256,
        sha1: cert.fingerprint.replace(/:/g, '').toLowerCase(),
        expires: cert.validTo,
      });
    } catch {
      log('ignoring an unparseable block in the trusted bundle');
    }
  }

  return out;
}

function certificateAlreadyTrusted(pem) {
  const incoming = new crypto.X509Certificate(pem).fingerprint256;
  return readTrustedCerts().some((c) => c.fingerprint === incoming);
}

// Rewrites the bundle without that cert (in-place since bind-mounted)
function revokeCertificate(fingerprint) {
  const kept = [];
  let removed = null;

  for (const entry of readTrustedCerts()) {
    if (entry.fingerprint === fingerprint) {
      removed = entry;
      continue;
    }
    kept.push((entry.user ? annotate(entry.user, entry.added) : '') + entry.pem);
  }

  if (!removed) throw new Error('that certificate is no longer in the bundle');

  fs.writeFileSync(CLIENT_CERTS, kept.join(''));
  try {
    fs.chmodSync(CLIENT_CERTS, 0o644);
  } catch {}
  log('revoked certificate', removed.sha1, 'for', removed.user || 'unattributed');
  return removed;
}

// Each container watches its own fifo, so no signal crosses a boundary.
// Non-blocking: with nothing reading, the open fails at once instead of hanging.
function poke(name) {
  if (!SIGNAL_PROCESSES) return null;
  let fd;
  try {
    fd = fs.openSync(path.join(SIGNAL_DIR, name),
      fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
  } catch (err) {
    log('could not signal', name + ':', err.code || err.message);
    return err.code === 'ENXIO' ? `nothing is watching the ${name} fifo` : err.message;
  }
  try {
    fs.writeSync(fd, 'go\n');
    log('poked', name);
  } finally {
    fs.closeSync(fd);
  }
  return null;
}

// Opening without writing delivers nothing, so this only reports liveness.
function listening(name) {
  if (!SIGNAL_PROCESSES) return true;
  try {
    fs.closeSync(fs.openSync(path.join(SIGNAL_DIR, name),
      fs.constants.O_WRONLY | fs.constants.O_NONBLOCK));
    return true;
  } catch {
    return false;
  }
}

// Which container holds each log, by the hostname compose gave it.
const LOG_SOURCES = {
  nginx: 'tls',
  samba: 'timemachine',
  'enroll-queue': 'enroll-queue',
  'admin-ui': 'admin-ui',
};

// Ids change on every recreate, so resolve by hostname from docker's own dir.
function containerIdFor(hostname) {
  let best = null;
  let newest = -1;
  let ids = [];
  try {
    ids = fs.readdirSync(DOCKER_LOGS);
  } catch {
    return null;
  }
  for (const id of ids) {
    if (!/^[0-9a-f]{64}$/.test(id)) continue;
    try {
      const host = fs.readFileSync(path.join(DOCKER_LOGS, id, 'hostname'), 'utf8');
      if (host.trim() !== hostname) continue;
      // A replaced but unremoved container leaves a stale dir; newest wins.
      const when = fs.statSync(path.join(DOCKER_LOGS, id, `${id}-json.log`)).mtimeMs;
      if (when > newest) {
        newest = when;
        best = id;
      }
    } catch {
      // dirs linger for containers we cannot read; skip them
    }
  }
  return best;
}

// Tail of the live log; a line that will not parse is printed as it is.
function tailLog(id) {
  const fd = fs.openSync(path.join(DOCKER_LOGS, id, `${id}-json.log`), 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const from = Math.max(0, size - LOG_TAIL);
    const buf = Buffer.alloc(size - from);
    fs.readSync(fd, buf, 0, buf.length, from);
    const lines = buf.toString('utf8').split('\n');
    if (from > 0) lines.shift();
    return lines.map((line) => {
      if (!line) return '';
      try {
        const entry = JSON.parse(line);
        return typeof entry.log === 'string' ? entry.log : `${line}\n`;
      } catch {
        return `${line}\n`;
      }
    }).join('');
  } finally {
    fs.closeSync(fd);
  }
}

function applyEnrollment(event) {
  let cert;
  try {
    cert = new crypto.X509Certificate(event.cert);
  } catch {
    log('ignoring enrollment with an unparseable certificate');
    return;
  }

  if (!USER_PATTERN.test(event.user || '')) {
    log('ignoring enrollment with a suspicious user name');
    return;
  }

  const invite = readEnrollments().find((e) => e.hash === idOf(event.code || ''));
  if (!invite) {
    log('ignoring enrollment: no outstanding invitation for that code');
    return;
  }
  if (invite.user !== event.user) {
    log('ignoring enrollment: code belongs to', invite.user, 'not', event.user);
    return;
  }

  if (certificateAlreadyTrusted(event.cert)) {
    log('certificate for', event.user, 'is already trusted');
  } else {
    fs.appendFileSync(CLIENT_CERTS, annotate(event.user) + cert.toString().trim() + '\n');
    try {
      fs.chmodSync(CLIENT_CERTS, 0o644);
    } catch {}
    log('trusted certificate for', event.user,
        cert.fingerprint.replace(/:/g, '').toLowerCase());
  }

  // Spending it here, not in enroll-queue, is what makes a code single use.
  writeEnrollments(readEnrollments().filter((e) => e.hash !== invite.hash));

  reloadNginx();
}

function reloadNginx() {
  poke('nginx');
}

function listenToBus() {
  const url = new URL('/bus', ENROLL_QUEUE);
  const req = http.request(
    { method: 'GET', hostname: url.hostname, port: url.port, path: '/bus' },
    (res) => {
      log('bus connected');
      let buffer = '';
      res.on('data', (chunk) => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, index).trim();
          buffer = buffer.slice(index + 1);
          if (!line) continue;
          try {
            const event = JSON.parse(line);
            if (event.type === 'enroll') applyEnrollment(event);
          } catch (err) {
            log('bad bus event:', err.message);
          }
        }
      });
      res.on('end', () => {
        log('bus closed, reconnecting');
        setTimeout(listenToBus, 2000);
      });
    },
  );
  req.on('error', (err) => {
    log('bus error:', err.message);
    setTimeout(listenToBus, 2000);
  });
  req.end();
}

// ------------------------------------------------------------------- ui -----

const LOGO = `<svg class="logo" viewBox="0 0 24 24" fill="none" stroke-width="1.7"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path class="cloud"
  d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/><circle class="clock" cx="11.5"
  cy="14.4" r="3.2"/><path class="clock" d="M11.5 12.8v1.6l1.4.9"/></svg>`;

const STYLE = `
:root {
  --bg:#ffffff; --panel:#f6f7f9; --ink:#1f2933; --bright:#0b1f33;
  --muted:#5a6673; --line:#d3d9e0; --accent:#0b3d6b; --gold:#8a6a1f;
  --warn:#8a2f2f;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
.wrap { max-width:64rem; margin:0 auto; padding:0 1.75rem 3rem; }

header { padding:2.5rem 0 1.75rem; margin-bottom:2rem;
  border-bottom:3px double var(--accent); }
h1 { font-size:1.95rem; font-weight:700; margin:0; color:var(--accent);
  letter-spacing:-.01em; }
.logo { width:1em; height:1em; vertical-align:-.12em; margin-right:.4rem; }
.logo .cloud { stroke:var(--accent); stroke-width:1.6; }
.logo .clock { stroke:var(--gold); stroke-width:1.6; }

h2 { font-size:.82rem; font-weight:700; color:var(--accent);
  text-transform:uppercase; letter-spacing:.09em;
  margin:2.5rem 0 .9rem; padding-bottom:.45rem;
  border-bottom:1px solid var(--line); }
h3 { font-size:1rem; font-weight:700; color:var(--bright); margin:0 0 .4rem; }
p { margin:0 0 .9rem; }
a { color:var(--accent); text-decoration:underline; text-underline-offset:2px; }
strong { color:var(--bright); font-weight:700; }
code { font-family:var(--mono); font-size:.88em; color:var(--bright);
  background:var(--panel); padding:.05em .3em; border:1px solid var(--line); }
pre { background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--accent); padding:.9rem 1.1rem; overflow-x:auto;
  margin:0 0 1.1rem; font:.82rem/1.6 var(--mono); color:var(--bright); }

table { border-collapse:collapse; width:100%; margin:0 0 1.2rem; font-size:.9rem; }
th, td { text-align:left; padding:.55rem .7rem; border:1px solid var(--line); }
th { background:var(--accent); color:#fff; font-weight:700; font-size:.72rem;
  text-transform:uppercase; letter-spacing:.07em; }
tbody tr:nth-child(even) { background:var(--panel); }
td:first-child { font-weight:700; color:var(--bright); white-space:nowrap; }
td:last-child { white-space:nowrap; }
td.fp { font-family:var(--mono); font-size:.76rem; font-weight:400;
  color:var(--muted); }

form { background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--gold); padding:1.1rem 1.2rem; }
label { display:block; margin:.7rem 0 .25rem; color:var(--muted); font-size:.72rem;
  text-transform:uppercase; letter-spacing:.07em; font-weight:700; }
label.check { display:flex; align-items:center; gap:.5rem; margin-top:1rem;
  text-transform:none; letter-spacing:0; font-weight:400; font-size:.9rem;
  color:var(--ink); }
label.check input { width:auto; }
input { font:inherit; background:var(--bg); color:var(--ink);
  border:1px solid var(--line); padding:.45rem .55rem; width:100%; max-width:22rem; }
input:focus { outline:2px solid var(--accent); outline-offset:-1px; }
button { font:inherit; margin-top:1.1rem; background:var(--accent); color:#fff;
  border:0; padding:.55rem 1.2rem; cursor:pointer; font-weight:700;
  font-size:.74rem; text-transform:uppercase; letter-spacing:.08em; }
button:hover { background:var(--bright); }

.banner { position:relative; background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--gold); padding:1rem 1.2rem; margin:0 0 1.4rem; }
.banner h3 { margin:0 2rem .45rem 0; color:var(--accent); }
.banner .close { position:absolute; top:.5rem; right:.85rem; line-height:1;
  font-size:1.35rem; color:var(--muted); text-decoration:none; }
.banner .close:hover { color:var(--accent); }
.err { border-left-color:var(--warn); }
.err h3 { color:var(--warn); }
.muted { color:var(--muted); font-size:.86rem; }

/* The per row action sits in a table cell, so it must not carry the panel
   styling the add form has. */
form.inline { display:inline; background:none; border:0; padding:0; margin:0 .6rem 0 0; }
button.linkish { font:inherit; font-size:.86rem; margin:0; padding:0; background:none;
  border:0; color:var(--accent); cursor:pointer; font-weight:400;
  text-transform:none; letter-spacing:0; text-decoration:underline;
  text-underline-offset:2px; }
button.linkish:hover { background:none; color:var(--bright); }
button.linkish.danger { color:var(--warn); }
button.linkish.danger:hover { color:#5e1f1f; }
`;

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function page(body) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fez admin</title><style>${STYLE}</style></head><body><div class="wrap">
<header><h1>${LOGO}fez admin</h1></header>
${body}
</div></body></html>`;
}

async function renderHome(error) {
  const shares = readShares();
  const usage = await Promise.all(shares.map((s) => diskUsage(s.name)));

  // No code column: only its hash is stored, so it is shown once and not again.
  let pendingRows = '';
  const waiting = readEnrollments();
  if (waiting.length) {
    pendingRows = `<h2>waiting to enroll</h2><table>
      <tr><th>share</th><th>expires</th><th></th></tr>${waiting.map((e) => `<tr>
        <td>${escapeHtml(e.user)}</td>
        <td>${new Date(e.expires).toISOString().slice(0, 10)}</td>
        <td><form method="POST" action="/cancel" class="inline">
          <input type="hidden" name="hash" value="${escapeHtml(e.hash)}">
          <button type="submit" class="linkish danger">cancel</button>
        </form></td></tr>`).join('')}</table>`;
  }

  const trusted = readTrustedCerts();
  const rows = shares.map((share, i) => `<tr>
      <td>${escapeHtml(share.name)}</td>
      <td>${escapeHtml(share.user)}</td>
      <td>${escapeHtml(share.uid)}</td>
      <td>${escapeHtml(share.quota || 'none')}</td>
      <td>${humanSize(usage[i])}</td>
      <td><form method="POST" action="/invite" class="inline">
        <input type="hidden" name="name" value="${escapeHtml(share.name)}">
        <button type="submit" class="linkish">new invitation</button>
      </form>
      <form method="POST" action="/password" class="inline">
        <input type="hidden" name="name" value="${escapeHtml(share.name)}">
        <button type="submit" class="linkish">show password</button>
      </form></td>
    </tr>`).join('');

  // Grouped by owner, so revoking a lost Mac means finding the person.
  const certSection = trusted.length ? `<h2>allowed clients</h2><table>
    <tr><th>name</th><th>added</th><th>expires</th><th>fingerprint</th><th></th></tr>
    ${trusted.map((c) => `<tr>
      <td>${c.user ? escapeHtml(c.user) : '<span class="muted">unattributed</span>'}</td>
      <td>${c.added ? escapeHtml(c.added) : '<span class="muted">unknown</span>'}</td>
      <td>${escapeHtml(new Date(c.expires).toISOString().slice(0, 10))}</td>
      <td class="fp">${escapeHtml(c.sha1)}</td>
      <td><form method="POST" action="/revoke" class="inline">
        <input type="hidden" name="fingerprint" value="${escapeHtml(c.fingerprint)}">
        <button type="submit" class="linkish danger">revoke</button>
      </form></td>
    </tr>`).join('')}</table>`
    : '';

  let banner = '';
  if (lastInvite) {
    const who = escapeHtml(lastInvite.name);
    const heading = lastInvite.kind === 'password' ? `password for ${who}`
      : lastInvite.kind === 'replacement' ? `replacement invitation for ${who}`
      : lastInvite.code ? `send this to ${who}`
      : `created ${who}`;
    const note = lastInvite.kind === 'replacement'
      ? `<p class="muted">Remember to revoke any old client certificates under <strong>allowed clients</strong>.</p>`
      : '';
    const body = lastInvite.code
      ? `<pre>Share password: ${escapeHtml(lastInvite.password)}
./install.sh --server ${escapeHtml(lastInvite.server)} --enroll ${escapeHtml(lastInvite.code)}</pre>
      <p><a href="/install.sh" download>download install.sh</a> and send it with
      the line above.</p>
      ${note}
      <p class="muted">The code works only once, and expires on
      ${new Date(lastInvite.expiresAt).toISOString().slice(0, 10)}. Send the code
      and the script securely to the user.`
      : lastInvite.kind === 'password'
      ? `<pre>Share password: ${escapeHtml(lastInvite.password)}</pre>
      <p class="muted">Type this into Finder when mounting the share.`
      : `<pre>Share password: ${escapeHtml(lastInvite.password)}</pre>
      <p class="muted">No enroll code was generated, so only an existing client can
      connect to this share. Use <strong>new invitation</strong> on its row when you are
      ready to hand it out.`;
    banner = `<div class="banner">
      <a class="close" href="/?dismiss=1" title="dismiss" aria-label="dismiss">&times;</a>
      <h3>${heading}</h3>
      ${body}</p></div>`;
  }

  const errorBox = error
    ? `<div class="banner err"><h3>that did not work</h3><p>${escapeHtml(error)}</p></div>`
    : '';

  // A dead watcher means reloads silently stop, so say so up front.
  const asleep = ['nginx', 'samba'].filter((n) => !listening(n));
  const watchers = asleep.length
    ? `<div class="banner err"><h3>reloads are not getting through</h3>
       <p>Nothing is watching ${escapeHtml(asleep.join(' or '))}, so changes made
       here will not reach ${asleep.length > 1 ? 'those containers' : 'that container'}.</p></div>`
    : '';

  return page(`${banner}${errorBox}${watchers}
<h2>shares</h2>
${shares.length
    ? `<table><tr><th>share</th><th>user</th><th>uid</th><th>quota</th><th>used</th><th></th></tr>${rows}</table>`
    : '<p class="muted">no shares yet</p>'}
${certSection}
${pendingRows}
<h2>add a share</h2>
<form method="POST" action="/users">
  <label for="name">name (lowercase letters, digits and dashes)</label>
  <input id="name" name="name" required pattern="[a-z0-9][a-z0-9-]*" autocomplete="off">
  <label for="quota">quota, optional (for example 500 G, or 1 T)</label>
  <input id="quota" name="quota" placeholder="leave empty for no limit" autocomplete="off">
  <label class="check"><input type="checkbox" name="invite" value="1" checked>
    generate enroll code</label>
  <button type="submit">add share</button>
</form>

<h2>view logs</h2>
<p class="muted">
${Object.keys(LOG_SOURCES).map((n) => `<a href="/logs/${n}">${n}</a>`).join(' &middot; ')}</p>

<h2>disable admin interface</h2>
<p class="muted">To disable the local admin interface on <code>http://127.0.0.2:8443</code>:</p>
<pre>sudo launchctl bootout system/${ADMIN_LABEL}
sudo launchctl disable system/${ADMIN_LABEL}</pre>
`);
}

// Gets a code and remembers it for the banner.
// invite is null when the admin asked for a share without a code.
// kind is 'new', 'replacement' or 'password', and decides what the banner says.
function announce(name, password, invite, kind) {
  lastInvite = {
    name,
    password,
    kind,
    code: invite ? invite.enrollcode : null,
    expiresAt: invite ? invite.expiresAt : null,
    server: process.env.SERVER_ADDRESS || '<server address>',
  };
}

function issueInvite(name, password, replacement) {
  const code = crypto.randomBytes(16).toString('hex');
  const expiresAt = Date.now() + ENROLL_TTL_MS;
  // One outstanding invitation per share; a new one supersedes the old.
  const list = readEnrollments().filter((e) => e.user !== name);
  list.push({ hash: idOf(code), user: name, sealed: sealPassword(code, password), expires: expiresAt });
  writeEnrollments(list);
  announce(name, password, { enrollcode: code, expiresAt },
    replacement ? 'replacement' : 'new');
  log(replacement ? 'replacement invitation for' : 'invitation for', name);
}

function parseForm(body) {
  const out = {};
  for (const pair of body.split('&')) {
    if (!pair) continue;
    const [k, v = ''] = pair.split('=');
    out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' '));
  }
  return out;
}

// No DNS rebinding.
const LOOPBACK_HOST = /^(127\.\d{1,3}\.\d{1,3}\.\d{1,3}|localhost|\[::1\]|::1)$/;

function hostAllowed(req) {
  const raw = req.headers.host || '';
  // Strip the port, leaving bracketed IPv6 literals intact.
  const host = raw.startsWith('[') ? raw.replace(/\](:\d+)?$/, ']') : raw.replace(/:\d+$/, '');
  return LOOPBACK_HOST.test(host);
}

// CSRF: posting here blind is enough to create shares or revoke a Mac. Browsers
// always send Origin cross-origin, so a mismatch is a no. Missing means curl.
function originAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  try {
    return LOOPBACK_HOST.test(new URL(origin).hostname);
  } catch {
    return false;
  }
}

const POSTS = {
  '/revoke': (form) => {
    const fp = (form.fingerprint || '').trim();
    if (!/^[A-F0-9]{2}(:[A-F0-9]{2}){31}$/.test(fp)) throw new Error('that is not a fingerprint');
    revokeCertificate(fp);
    if (SIGNAL_PROCESSES) reloadNginx();
  },

  '/cancel': async (form) => {
    const hash = (form.hash || '').trim();
    if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error('that is not an invitation');
    const list = readEnrollments();
    if (!list.some((e) => e.hash === hash)) throw new Error('that invitation is already gone');
    writeEnrollments(list.filter((e) => e.hash !== hash));
    log('cancelled invitation for', list.find((e) => e.hash === hash).user);
  },

  // Reads a share password back out, for when someone has lost theirs.
  '/password': (form) => {
    const name = (form.name || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('that is not a share name');
    const share = readShares().find((s) => s.name === name);
    if (!share) throw new Error(`there is no share called "${name}"`);
    if (!share.password) throw new Error(`no PASSWORD= in ${name}.conf`);
    announce(name, share.password, null, 'password');
  },

  '/invite': async (form) => {
    const name = (form.name || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('that is not a share name');
    const share = readShares().find((s) => s.name === name);
    if (!share) throw new Error(`there is no share called "${name}"`);
    if (!share.password) throw new Error(`no PASSWORD= in ${name}.conf, so there is nothing to send`);
    await issueInvite(name, share.password, true);
  },

  '/users': async (form) => {
    const name = (form.name || '').trim();
    const quota = (form.quota || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('name is lowercase letters, digits and dashes');
    if (quota && !QUOTA_PATTERN.test(quota)) throw new Error('quota looks like "500 G" or "1 T", or empty');
    const share = createShare(name, quota);
    // Checkboxes only submit when ticked, so absence means they unticked it.
    if (form.invite) await issueInvite(name, share.password, false);
    else announce(name, share.password, null, 'new');
  },
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const send = (status, type, body) => {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(body);
  };
  const page = async (status, error) => send(status, 'text/html; charset=utf-8', await renderHome(error));

  if (!hostAllowed(req)) {
    log('refused host', JSON.stringify(req.headers.host || ''));
    return send(403, 'text/plain', 'reach this page at 127.0.0.2, not by name\n');
  }
  if (req.method !== 'GET' && !originAllowed(req)) {
    log('refused cross origin request from', JSON.stringify(req.headers.origin || ''));
    return send(403, 'text/plain', 'cross origin requests are not accepted\n');
  }

  try {
    if (req.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('dismiss')) lastInvite = null;
      return page(200, null);
    }

    // The copy the installer left on the server, so the admin can send both
    // halves: the script and the line to run it with.
    if (req.method === 'GET' && url.pathname === '/install.sh') {
      let body;
      try {
        body = fs.readFileSync(INSTALLER);
      } catch {
        return send(404, 'text/plain', 'no installer on this server\n');
      }
      if (!body.length) return send(404, 'text/plain', 'the installer copy is empty\n');
      res.writeHead(200, {
        'content-type': 'text/x-shellscript',
        'content-disposition': 'attachment; filename="install.sh"',
        'content-length': body.length,
        'cache-control': 'no-store',
      });
      return res.end(body);
    }

    if (req.method === 'GET' && url.pathname.startsWith('/logs/')) {
      const name = url.pathname.slice('/logs/'.length);
      if (!Object.prototype.hasOwnProperty.call(LOG_SOURCES, name)) {
        return send(404, 'text/plain', 'no such log\n');
      }
      const id = containerIdFor(LOG_SOURCES[name]);
      if (!id) return send(503, 'text/plain', `no running ${name} container found\n`);
      try {
        return send(200, 'text/plain; charset=utf-8', tailLog(id) || '(the log is empty)\n');
      } catch (err) {
        return send(503, 'text/plain', `could not read the ${name} log: ${err.message}\n`);
      }
    }

    const handler = req.method === 'POST' ? POSTS[url.pathname] : null;
    if (handler) {
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 8192) { req.destroy(); return; }
      }
      try {
        await handler(parseForm(body));
      } catch (err) {
        return page(400, err.message);
      }
      res.writeHead(303, { location: '/' });
      return res.end();
    }

    send(404, 'text/plain', 'not found\n');
  } catch (err) {
    log('request failed:', err.message);
    send(500, 'text/plain', 'internal error\n');
  }
});

server.headersTimeout = 15_000;
server.listen(PORT, BIND, () => log('admin ui on', BIND + ':' + PORT));
listenToBus();

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { log('shutting down'); server.close(); process.exit(0); });
}
