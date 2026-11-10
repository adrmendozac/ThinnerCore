import assert from 'node:assert/strict';
import test from 'node:test';
import {cp, mkdtemp, mkdir, writeFile, chmod, symlink, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

test('terminal launcher forwards allow and skip commands without adding JSON', async () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const dir = await mkdtemp(join(tmpdir(), 'thinner-launcher-'));
  try {
    await cp(join(root, 'bin'), join(dir, 'bin'), {recursive: true});
    await symlink(join(root, 'node_modules'), join(dir, 'node_modules'));
    await mkdir(join(dir, '.build/release'), {recursive: true});
    const engine = join(dir, '.build/release/thinnercore');
    await writeFile(engine, `#!${process.execPath}\nconsole.log(JSON.stringify(process.argv.slice(2)));\n`);
    await chmod(engine, 0o755);
    // Exercise the real terminal-only routing branch without opening a UI.
    const preload = 'data:text/javascript,' + encodeURIComponent('process.stdout.isTTY = true; process.stdin.isTTY = false;');
    for (const command of ['allow', 'skip']) {
      for (const action of ['add', 'remove', 'list']) {
        const args = [command, action, ...(action === 'list' ? [] : ['com.example.fixture'])];
        const child = spawnSync(process.execPath, ['--import', preload, join(dir, 'bin/thinnercore.mjs'), ...args], {encoding: 'utf8'});
        assert.equal(child.status, 0, child.stderr);
        assert.deepEqual(JSON.parse(child.stdout), args);
      }
    }
  } finally { await rm(dir, {recursive: true, force: true}); }
});
