import assert from 'node:assert/strict';
import test from 'node:test';
import {clean, diagnosticLines} from '../bin/terminal-text.mjs';

test('terminal diagnostics cannot inject escape sequences', () => {
  assert.equal(clean('bad\u001b[2J path'), 'bad path');
  assert.deepEqual(diagnosticLines('first\nsecond\n'), ['first', 'second']);
});
