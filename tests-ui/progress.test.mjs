import assert from 'node:assert/strict';
import test from 'node:test';
import {parseProgress, stderrSplitter} from '../bin/progress.mjs';

test('progress lines parse; anything else is not progress', () => {
  assert.deepEqual(parseProgress('{"progress":{"app":"A.app","index":2,"total":5}}'),
    {app: 'A.app', index: 2, total: 5});
  assert.equal(parseProgress('{"progress":{"app":"A.app","index":"2","total":5}}'), null);
  assert.equal(parseProgress('{"progress":'), null);
  assert.equal(parseProgress('Error: cannot scan /x'), null);
});

test('stderr split across chunks keeps progress and diagnostics apart', () => {
  const progress = [];
  let diagnostics = '';
  const split = stderrSplitter(p => progress.push(p.index), text => { diagnostics += text; });
  split.write('{"progress":{"app":"A.app","in');
  split.write('dex":1,"total":2}}\nWARNING: dev build\n{"progress":{"app":"B.app","index":2,"total":2}}\ntrailing');
  split.flush();
  assert.deepEqual(progress, [1, 2]);
  assert.equal(diagnostics, 'WARNING: dev build\ntrailing');
});
