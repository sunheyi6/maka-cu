#!/usr/bin/env node
// First light for the maka-cu host protocol: talk to the executor directly,
// with no TypeScript backend in between, so a failure is unambiguously the
// executor's rather than the client's.
//
// Read-only. `permissions.check` is the only permission touch and it does not
// prompt, so this cannot create a TCC grant for a bare node process — the trap
// this repository has hit before.
//
//   node scripts/maka-cu-first-light.mjs "Codex CUA Lab"
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const BINARY = '/Users/haoqing/Documents/Github/maka-cu/.build/release/OpenComputerUse';
const TARGET = process.argv[2] ?? 'Codex CUA Lab';
const imageDir = mkdtempSync(join(tmpdir(), 'maka-cu-first-light-'));

const child = spawn(BINARY, ['host'], { stdio: ['pipe', 'pipe', 'pipe'] });
let nextId = 1;
const pending = new Map();
let buffered = '';

child.stdout.on('data', (chunk) => {
  buffered += chunk.toString('utf8');
  let index;
  while ((index = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, index).trim();
    buffered = buffered.slice(index + 1);
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      console.log(`  [stdout non-JSON] ${line.slice(0, 160)}`);
      continue;
    }
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      waiter(message);
    }
  }
});
const stderrLines = [];
child.stderr.on('data', (c) => stderrLines.push(c.toString('utf8').trim()));

function call(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out`));
    }, 30_000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
}

let failures = 0;
function check(label, pass, detail) {
  if (!pass) failures += 1;
  console.log(`[${pass ? 'PASS' : 'FAIL'}] ${label}${detail ? ` — ${detail}` : ''}`);
}

function summarize(message) {
  if (message.error) return `rpc error ${message.error.code} ${message.error.message ?? ''}`;
  const result = message.result ?? {};
  if (result.ok === false) return `refused ${result.error?.code}: ${result.error?.message ?? ''}`;
  return 'ok';
}

try {
  // ── handshake ─────────────────────────────────────────────────────────────
  const hello = await call('host.hello', {
    protocol: 'maka.cu/2',
    hostPid: process.pid,
    imageDir,
    allowGlobalPointer: false,
  });
  check('handshake accepted', !hello.error && hello.result?.ok !== false, summarize(hello));
  if (hello.error) {
    console.log(JSON.stringify(hello.error, null, 2));
    process.exit(1);
  }
  console.log(`  executor: ${JSON.stringify(hello.result).slice(0, 220)}`);

  // ── permissions, non-prompting ────────────────────────────────────────────
  const perms = await call('permissions.check', {});
  console.log(`  permissions: ${JSON.stringify(perms.result ?? perms.error)}`);

  // ── session ───────────────────────────────────────────────────────────────
  const begun = await call('session.begin', { session: 'first-light', captureScope: 'window' });
  check('session.begin', !begun.error && begun.result?.ok !== false, summarize(begun));

  // ── discovery ─────────────────────────────────────────────────────────────
  const apps = await call('apps.list', { session: 'first-light' });
  const appList = apps.result?.apps ?? [];
  check('apps.list returns apps', appList.length > 0, `${appList.length} apps`);
  const target = appList.find(
    (a) => a.appId === TARGET || a.name === TARGET || a.appId?.includes(TARGET),
  );
  console.log(`  target lookup "${TARGET}" → ${target ? JSON.stringify(target) : 'NOT FOUND'}`);
  if (!target) {
    console.log(`  available: ${appList.map((a) => `${a.name}=${a.appId}`).slice(0, 8).join(', ')}`);
  }

  const windows = await call('window.list', { session: 'first-light' });
  const windowList = windows.result?.windows ?? [];
  check('window.list returns windows', windowList.length > 0, `${windowList.length} windows`);

  // ── the real question: does observe produce a bound snapshot ──────────────
  if (target) {
    const observed = await call('observe', {
      session: 'first-light',
      // §5.2: the field is `app` and its value is an appId. The two spellings
      // are deliberate — one namespace, and a tagged union so "app or window"
      // cannot be read as "app and window", which is how a compliant model was
      // once made to fail against a harness that required both.
      target: { kind: 'app', app: target.appId },
      includeImage: false,
    });
    const snapshot = observed.result?.snapshot;
    check('observe returns a snapshot', Boolean(snapshot), summarize(observed));
    if (snapshot) {
      const elements = snapshot.elements ?? [];
      console.log(`  snapshotId=${snapshot.snapshotId}`);
      console.log(`  window="${snapshot.target?.title ?? ''}" appId=${snapshot.target?.appId}`);
      console.log(`  elements=${elements.length}`);
      const withToken = elements.filter((e) => typeof e.token === 'string' && e.token.length > 0);
      check(
        'every element carries a binding token',
        withToken.length === elements.length,
        `${withToken.length}/${elements.length}`,
      );
      const withDigest = elements.filter((e) => typeof e.digest === 'string');
      check(
        'every element carries a digest',
        withDigest.length === elements.length,
        `${withDigest.length}/${elements.length}`,
      );
      for (const element of elements.slice(0, 6)) {
        console.log(
          `    ${element.role}${element.label ? ` "${element.label}"` : ''}` +
            `${element.value !== undefined ? ` =${JSON.stringify(element.value)}` : ''}` +
            ` token=${String(element.token).slice(0, 12)}…`,
        );
      }
      if (elements.length > 6) console.log(`    … ${elements.length - 6} more`);
    } else {
      console.log(JSON.stringify(observed).slice(0, 800));
    }
  }

  await call('session.end', { session: 'first-light' });
} catch (error) {
  failures += 1;
  console.log(`\n[ERROR] ${error.message}`);
} finally {
  child.stdin.end();
  child.kill('SIGTERM');
  rmSync(imageDir, { recursive: true, force: true });
}

if (stderrLines.length > 0) {
  console.log(`\nstderr:\n  ${stderrLines.join('\n  ').slice(0, 900)}`);
}
console.log(failures === 0 ? '\nFIRST LIGHT OK' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
