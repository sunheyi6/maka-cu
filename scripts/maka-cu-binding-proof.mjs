#!/usr/bin/env node
// Does the frame binding actually bind?
//
// A unit test can be deleted and stay green; this cannot. It drives the real
// executor against a real window and asks the three questions that decide
// whether the binding is a mechanism or a decoration:
//
//   1. a correct token + correct digest dispatches
//   2. the SAME snapshot, used twice, is refused  (single-use)
//   3. a corrupted digest is refused              (the digest is actually read)
//
// and, throughout, that driving a background window does not steal the user's
// foreground — the invariant the whole executor exists to keep.
//
// Read-only with respect to permissions: `permissions.check` does not prompt.
// The target is the CUA Lab fixture, whose Reset button exists to be pressed.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Resolved from this repository rather than hardcoded, so the script works
// from any checkout. `swift build -c release` produces it.
const BINARY = new URL('../.build/release/OpenComputerUse', import.meta.url).pathname;
const TARGET_NAME = process.argv[2] ?? 'Codex CUA Lab';
const imageDir = mkdtempSync(join(tmpdir(), 'maka-cu-binding-'));

const child = spawn(BINARY, ['host'], { stdio: ['pipe', 'pipe', 'pipe'] });
let nextId = 1;
const pending = new Map();
let buffered = '';
const stderrLines = [];

child.stdout.on('data', (chunk) => {
  buffered += chunk.toString('utf8');
  let index;
  while ((index = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, index).trim();
    buffered = buffered.slice(index + 1);
    if (!line) continue;
    try {
      const message = JSON.parse(line);
      const waiter = pending.get(message.id);
      if (waiter) {
        pending.delete(message.id);
        waiter(message);
      }
    } catch {
      /* non-JSON on stdout is a protocol violation; the first-light probe reports it */
    }
  }
});
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

function frontmost() {
  try {
    return execFileSync(
      'osascript',
      [
        '-e',
        'tell application "System Events" to get unix id of first process whose frontmost is true',
      ],
      { encoding: 'utf8', timeout: 5000 },
    ).trim();
  } catch {
    return 'unavailable';
  }
}

let failures = 0;
const check = (label, pass, detail) => {
  if (!pass) failures += 1;
  console.log(`[${pass ? 'PASS' : 'FAIL'}] ${label}${detail ? ` — ${detail}` : ''}`);
};
const refusalOf = (message) => {
  const result = message.result ?? {};
  if (message.error) return `rpc:${message.error.code}`;
  if (result.ok === false) return result.error?.code ?? 'unknown';
  return null;
};

const SESSION = 'binding-proof';

try {
  await call('host.hello', {
    protocol: 'maka.cu/2',
    hostPid: process.pid,
    imageDir,
    allowGlobalPointer: false,
  });
  const perms = (await call('permissions.check', {})).result ?? {};
  if (!perms.accessibility) {
    console.log('Accessibility not granted for this process; stopping before anything else.');
    process.exit(2);
  }
  await call('session.begin', { session: SESSION, captureScope: 'window' });

  const apps = (await call('apps.list', { session: SESSION })).result?.apps ?? [];
  const target = apps.find((a) => a.name === TARGET_NAME);
  if (!target) {
    console.log(`fixture "${TARGET_NAME}" is not running; launch it and re-run.`);
    process.exit(2);
  }

  const beforePid = frontmost();
  console.log(`frontmost before: pid ${beforePid} (target is pid ${target.pid})`);
  check(
    'the target is NOT frontmost, so this is a background test',
    String(beforePid) !== String(target.pid),
    `frontmost=${beforePid} target=${target.pid}`,
  );

  const observe = async (tag) => {
    const message = await call('observe', {
      session: SESSION,
      target: { kind: 'app', app: target.appId },
      includeImage: false,
    });
    const snapshot = message.result?.snapshot;
    if (!snapshot) throw new Error(`${tag}: observe failed — ${JSON.stringify(message).slice(0, 300)}`);
    return snapshot;
  };
  const pressable = (snapshot) =>
    // Deliberately NOT "CUA Lab Reset". Measured on 2026-07-29 against the same
    // executor, the same action and the same code path: Primary Button and Diff
    // Probe leave the foreground alone, Reset raises the fixture. The fixture's
    // Reset handler activates its own app, so pressing it would fail the
    // foreground invariant for a reason that has nothing to do with the
    // executor — and did, on the first run of this script.
    snapshot.elements.find((e) => e.label === 'CUA Lab Primary Button') ??
    snapshot.elements.find((e) => e.role === 'AXButton' && e.label !== 'CUA Lab Reset');

  // ── 1. a correct token and digest dispatches ──────────────────────────────
  const first = await observe('first');
  const button = pressable(first);
  check('the fixture exposes a pressable element', Boolean(button), button?.label ?? 'none');

  const good = await call('dispatch.element', {
    session: SESSION,
    snapshotId: first.snapshotId,
    toolCallId: 'proof-1',
    elementToken: button.token,
    expectElementDigest: button.digest,
    action: { kind: 'click', button: 'left', count: 1 },
  });
  const goodResult = good.result ?? {};
  check(
    'a correct token and digest dispatches',
    goodResult.ok === true && goodResult.outcome === 'ok',
    `outcome=${goodResult.outcome} path=${goodResult.path} tier=${goodResult.tier} ${refusalOf(good) ?? ''}`,
  );

  // ── 2. the same snapshot, used twice ──────────────────────────────────────
  const replay = await call('dispatch.element', {
    session: SESSION,
    snapshotId: first.snapshotId,
    toolCallId: 'proof-2',
    elementToken: button.token,
    expectElementDigest: button.digest,
    action: { kind: 'click', button: 'left', count: 1 },
  });
  check(
    'a spent snapshot is refused',
    replay.result?.ok === false || Boolean(replay.error),
    refusalOf(replay) ?? 'IT WENT THROUGH — the snapshot is not single-use',
  );

  // ── 3. a corrupted digest ─────────────────────────────────────────────────
  // The token is real and current; only the digest is wrong. If this dispatches,
  // the digest is being carried but never compared.
  const fresh = await observe('fresh');
  const freshButton = pressable(fresh);
  const corrupted = `${String(freshButton.digest).slice(0, -4)}0000`;
  const tampered = await call('dispatch.element', {
    session: SESSION,
    snapshotId: fresh.snapshotId,
    toolCallId: 'proof-3',
    elementToken: freshButton.token,
    expectElementDigest: corrupted,
    action: { kind: 'click', button: 'left', count: 1 },
  });
  check(
    'a corrupted digest is refused',
    tampered.result?.ok === false || Boolean(tampered.error),
    refusalOf(tampered) ?? 'IT WENT THROUGH — the digest is decoration',
  );

  // ── 4. an unknown token ───────────────────────────────────────────────────
  const bogus = await observe('bogus');
  const unknown = await call('dispatch.element', {
    session: SESSION,
    snapshotId: bogus.snapshotId,
    toolCallId: 'proof-4',
    elementToken: 'el_not_a_real_token',
    expectElementDigest: pressable(bogus).digest,
    action: { kind: 'click', button: 'left', count: 1 },
  });
  check(
    'an unknown token is refused',
    unknown.result?.ok === false || Boolean(unknown.error),
    refusalOf(unknown) ?? 'IT WENT THROUGH',
  );

  // ── the invariant that outranks all of them ───────────────────────────────
  const afterPid = frontmost();
  check(
    'driving a background window did not steal the foreground',
    String(afterPid) === String(beforePid),
    `${beforePid} → ${afterPid}`,
  );

  await call('session.end', { session: SESSION });
} catch (error) {
  failures += 1;
  console.log(`\n[ERROR] ${error.message}`);
} finally {
  child.stdin.end();
  child.kill('SIGTERM');
  rmSync(imageDir, { recursive: true, force: true });
}

if (stderrLines.length > 0) console.log(`\nstderr:\n  ${stderrLines.join('\n  ').slice(0, 700)}`);
console.log(failures === 0 ? '\nBINDING PROVEN' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
