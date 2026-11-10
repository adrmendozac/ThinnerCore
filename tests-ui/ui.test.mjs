import assert from 'node:assert/strict';
import test from 'node:test';
import {renderToString} from 'ink';
import {appSkipMessage, scanView, bytes, count} from '../bin/ui.mjs';

test('sizes match the native report (decimal, whole KB)', () => {
  assert.equal(bytes(999), '999 bytes');
  assert.equal(bytes(81920), '82 KB');
  assert.equal(bytes(983040), '983 KB');
  assert.equal(bytes(1228800), '1.2 MB');
  assert.equal(bytes(5.4e9), '5.4 GB');
});

test('counts pluralize', () => {
  assert.equal(count(1, 'app'), '1 app');
  assert.equal(count(3, 'app'), '3 apps');
});


test('scan summaries keep signature diagnostics in the details view', () => {
  const detail = 'fails code signature verification: resource fork, Finder information, or similar detritus not allowed; In subcomponent: /fixtures/Example.app/Contents/Helpers/loader';
  const skip = {code: 'signatureInvalid', detail};
  const report = {
    root: '/fixtures',
    totals: {apps: 1, universalFiles: 1, eligibleFiles: 0, skippedApps: 1, removableBytes: 0},
    rosetta: {installed: false, preferencesUser: 'test'},
    apps: [{path: 'Example.app', skip, issues: [], files: [], eligibleFiles: 0, universalFiles: 1, removableBytes: 0}],
    skippedPaths: [], missingExclusions: [], issues: [],
    pendingOperations: {operations: [], problems: []}, complete: true,
  };
  const normal = renderToString(scanView(report), {columns: 200});
  const verbose = renderToString(scanView(report, {verbose: true}), {columns: 240});
  assert.match(normal, /Signature check failed. This app was left unchanged./);
  assert.doesNotMatch(normal, /resource fork|subcomponent|Contents\/Helpers/);
  assert.match(normal, /App details or --verbose/);
  assert.match(verbose, /resource fork, Finder information/);
  assert.match(verbose, /Contents\/Helpers\/loader/);
  assert.equal(report.apps[0].skip.detail, detail);
});

test('unknown skip reasons remain visible instead of being discarded', () => {
  const reason = {code: 'futureReason', detail: 'An important new reason'};
  assert.equal(appSkipMessage(reason), reason.detail);
});

test('advisory skips have short summaries and plugin warnings are shown', () => {
  assert.equal(appSkipMessage({code: 'masApp', detail: 'long'}), 'Mac App Store app. Left unchanged by default.');
  assert.match(appSkipMessage({code: 'embedsSystemExtension', detail: 'long'}), /system extension/);
  const report = {
    root: '/fixtures',
    totals: {apps: 0, universalFiles: 0, eligibleFiles: 0, skippedApps: 0, removableBytes: 0},
    rosetta: {installed: false, preferencesUser: 'test'},
    apps: [], skippedPaths: [], missingExclusions: [], issues: [],
    plugins: {intelOnly: ['/Library/Audio/Plug-Ins/Components/Old.component'], uninspected: []},
    pendingOperations: {operations: [], problems: []}, complete: true,
  };
  const out = renderToString(scanView(report), {columns: 240});
  assert.match(out, /1 Intel-only audio plugin found/);
  assert.match(out, /Old\.component/);
});

test('an allow list in force is shown', () => {
  const report = {
    root: '/fixtures',
    totals: {apps: 0, universalFiles: 0, eligibleFiles: 0, skippedApps: 0, removableBytes: 0},
    rosetta: {installed: false, preferencesUser: 'test'},
    apps: [], skippedPaths: [], missingExclusions: [], issues: [],
    allowList: {path: '/tmp/allow-list.txt', entries: 2, missingPaths: ['/gone.app']},
    pendingOperations: {operations: [], problems: []}, complete: true,
  };
  const out = renderToString(scanView(report), {columns: 240});
  assert.match(out, /Allow list: only its 2 entries can be thinned/);
  assert.match(out, /allows nothing: \/gone\.app/);
  assert.equal(appSkipMessage({code: 'notOnAllowList', detail: 'long'}), 'Not on your allow list.');
});
