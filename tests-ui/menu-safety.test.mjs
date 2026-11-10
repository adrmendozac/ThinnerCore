import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, writeFile, chmod, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {renderToString} from 'ink';
import {Menu} from '../bin/menu.mjs';

const apps = ['one/A.app', 'two/B.app', 'three/C.app'].map(path => ({path, removableBytes: 10}));
const report = {root: '/fixtures'};
const response = (path, outcome, code = 0) => ({code, output: JSON.stringify({command: 'apply', apps: [{path, outcome, reason: outcome}], problems: []})});
function setup(engine = 'unused') {
  const output = [];
  const store = {ask: async () => true, busy() {}, clear() {}, log: view => output.push(renderToString(view, {columns: 200}))};
  const menu = new Menu(engine, '/fixtures', store);
  menu.cache.set('/fixtures', {});
  return {menu, store, output};
}

for (const [outcome, code] of [['recoveryPending', 0], ['recoveryFailed', 0], ['refused', 3], ['refused', 4]]) {
  test(`batch stops on ${outcome}, exit ${code}, preserving earlier results`, async () => {
    const {menu, output} = setup();
    const calls = [];
    menu.engineRun = async args => {
      calls.push(args[1]);
      return response(args[1], calls.length === 1 ? 'committed' : outcome, calls.length === 1 ? 0 : code);
    };
    await menu.thin(report, apps);
    assert.deepEqual(calls, ['/fixtures/one/A.app', '/fixtures/two/B.app']);
    assert.match(output.join('\n'), /Done.*one\/A.app/);
    assert.match(output.join('\n'), /Not attempted: resolve the unfinished operation/);
    assert.equal(menu.cache.size, 0);
  });
}

test('invalid engine output stops the batch and keeps earlier results', async () => {
  const {menu, output} = setup();
  let calls = 0;
  menu.engineRun = async args => ++calls === 1 ? response(args[1], 'committed') : {code: 1, output: 'truncated'};
  await menu.thin(report, apps);
  assert.equal(calls, 2);
  assert.match(output.join('\n'), /Done.*one\/A.app/);
  assert.match(output.join('\n'), /Recovery pending/);
  assert.doesNotMatch(output.join('\n'), /Nothing changed/);
});

async function interruptingEngine() {
  const dir = await mkdtemp(join(tmpdir(), 'menu-safety-'));
  const engine = join(dir, 'engine.mjs');
  await writeFile(engine, `#!${process.execPath}\nconst path = process.argv[3];
if (path.endsWith('A.app')) console.log(JSON.stringify({apps:[{path,outcome:'committed',reason:'Verified'}],problems:[]}));
else process.kill(process.pid, 'SIGINT');\n`);
  await chmod(engine, 0o755);
  return {dir, engine};
}

test('a signalled child preserves batch results and invalidates cached scans', async () => {
  const {dir, engine} = await interruptingEngine();
  try {
    const {menu, output} = setup(engine);
    await menu.thin(report, apps);
    const text = output.join('\n');
    assert.match(text, /Done.*one\/A.app/);
    assert.match(text, /Operation interrupted/);
    assert.match(text, /Files may have changed/);
    assert.match(text, /Not attempted after an interrupted/);
    assert.doesNotMatch(text, /Nothing changed/);
    assert.equal(menu.cache.size, 0);
  } finally { await rm(dir, {recursive: true, force: true}); }
});

for (const args of [['restore', '/fixtures/B.app'], ['recover', '/fixtures'], ['release', '/fixtures/B.app', '--apply']]) {
  test(`${args[0]} interruption clears caches and provides accurate guidance`, async () => {
    const {dir, engine} = await interruptingEngine();
    try {
      const {menu} = setup(engine);
      await assert.rejects(menu.engineRun(args, 'Working'), error => {
        assert.match(error.message, /Operation interrupted/);
        assert.match(error.message, args[0] === 'release' ? /backups may already have been deleted/ : /run recovery/);
        assert.doesNotMatch(error.message, /Nothing changed/);
        return true;
      });
      assert.equal(menu.cache.size, 0);
    } finally { await rm(dir, {recursive: true, force: true}); }
  });
}

test('declining confirmation still reports no changes and starts no engine', async () => {
  const {menu, store, output} = setup();
  const answers = ['select', false, 'exit'];
  store.ask = async () => answers.shift();
  menu.select = () => menu.thin(report, apps);
  menu.engineRun = async () => assert.fail('must not start an operation');
  await menu.run();
  assert.match(output.join('\n'), /Cancelled. Nothing changed./);
});
