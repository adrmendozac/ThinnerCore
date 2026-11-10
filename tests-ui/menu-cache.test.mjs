import assert from 'node:assert/strict';
import test from 'node:test';
import {chmod, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Menu, ago, appReport} from '../bin/menu.mjs';

// A stand-in for the Swift engine: records each call, prints a tiny report.
async function fakeEngine() {
  const dir = await mkdtemp(join(tmpdir(), 'menu-cache-'));
  const log = join(dir, 'calls');
  const engine = join(dir, 'engine');
  await writeFile(engine, `#!/bin/sh\necho "$*" >> '${log}'\nprintf '{"dryRun":true,"root":"%s","apps":[]}' "$2"\n`);
  await chmod(engine, 0o755);
  const calls = async () => (await readFile(log, 'utf8').catch(() => '')).split('\n').filter(Boolean);
  return {dir, engine, calls};
}

const quietStore = {busy() {}, clear() {}, log() {}};

test('a scan is reused across menu items, per folder, until something changes', async () => {
  const {dir, engine, calls} = await fakeEngine();
  try {
    const menu = new Menu(engine, '/Applications', quietStore);
    await menu.scan('/Applications', {fresh: true});   // "Scan all applications"
    await menu.scan();                                  // "Select applications to thin"
    await menu.scan();                                  // "App details"
    assert.equal((await calls()).length, 1, 'picking after a scan does not scan again');

    await menu.scan('/Users/me/Apps', {fresh: true});   // "Scan a folder or app"
    await menu.scan();                                  // back to /Applications
    assert.deepEqual(await calls(), ['scan /Applications --json', 'scan /Users/me/Apps --json'],
      'another folder does not evict the first');

    menu.cache.clear();                                 // what thinning, restore, … do
    await menu.scan();
    assert.equal((await calls()).length, 3, 'a change forgets every scan');

    await menu.scan('/Applications', {fresh: true});
    assert.equal((await calls()).length, 4, '"Scan all applications" always refreshes');
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test('the menu says how old a kept scan is', () => {
  const now = Date.UTC(2026, 10, 9, 12, 0);
  assert.equal(ago(now - 20_000, now), 'just now');
  assert.equal(ago(now - 12 * 60_000, now), '12 min ago');
  assert.equal(ago(now - 125 * 60_000, now), '2 h ago');
});

test('app details are built from the folder scan', () => {
  const app = {path: 'A.app', skip: null, issues: [], files: [{path: 'x', eligible: true}], universalFiles: 3, eligibleFiles: 1, removableBytes: 10};
  const report = {
    root: '/Applications', apps: [app, {path: 'B.app'}], complete: false, issues: [{path: 'other', problem: 'p'}],
    skippedPaths: [{path: 'X'}], missingExclusions: ['/gone'],
    pendingOperations: {operations: [{bundlePath: '/Applications/A.app'}, {bundlePath: '/Applications/B.app'}], problems: []},
    backups: {sets: [{bundlePath: '/Applications/B.app'}]},
  };
  const one = appReport(report, app, '/Applications/A.app');
  assert.equal(one.root, '/Applications/A.app');
  assert.deepEqual(one.apps, [app]);
  assert.deepEqual(one.totals, {apps: 1, skippedApps: 0, universalFiles: 3, eligibleFiles: 1, removableBytes: 10, issues: 0});
  assert.equal(one.complete, true);
  assert.deepEqual(one.issues, []);
  assert.deepEqual(one.pendingOperations.operations, [{bundlePath: '/Applications/A.app'}]);
  assert.deepEqual(one.backups.sets, []);
});

test('the allow list is edited through the engine, like the skip list', async () => {
  const {dir, engine, calls} = await fakeEngine();
  try {
    // The fake prints a report; for `allow list --json` the menu only needs entries and a path.
    await writeFile(engine, `#!/bin/sh\necho "$*" >> '${join(dir, 'calls')}'\ncase "$1 $2" in\n  "allow list") printf '{"path":"/tmp/allow-list.txt","entries":[]}' ;;\n  *) echo "Added $3" ;;\nesac\n`);
    const answers = [{add: 'text'}, 'com.example.a', null];
    const logged = [];
    const store = {busy() {}, clear() {}, log: item => logged.push(item), ask: async () => answers.shift()};
    const menu = new Menu(engine, '/Applications', store);
    menu.cache.set('/Applications', {report: {}, at: Date.now()});
    await menu.allowList();
    assert.deepEqual(await calls(), ['allow list --json', 'allow add com.example.a', 'allow list --json']);
    assert.equal(menu.cache.size, 0, 'editing the list forgets kept scans');
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});
