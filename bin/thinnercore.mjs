#!/usr/bin/env node
import {spawn} from 'node:child_process';
import {access} from 'node:fs/promises';
import {constants} from 'node:fs';
import {fileURLToPath} from 'node:url';
import React from 'react';
import {Box, Text, render} from 'ink';
import {clean, diagnosticLines} from './terminal-text.mjs';
import {Banner} from './banner.mjs';

const args = process.argv.slice(2);
const candidates = ['../.build/release/thinnercore', '../.build/debug/thinnercore'];
let engine;
for (const candidate of candidates) {
  const path = fileURLToPath(new URL(candidate, import.meta.url));
  try { await access(path, constants.X_OK); engine = path; break; } catch {}
}
if (!engine) {
  process.stderr.write('thinnercore: build the Swift engine first with swift build -c release.\n');
  process.exit(1);
}

const delimiter = args.indexOf('--');
const options = delimiter < 0 ? args : args.slice(0, delimiter);
const passthrough = !process.stdout.isTTY || options.some(arg => ['--json', '--help', '-h', '--version', 'help'].includes(arg));
const childArgs = passthrough ? args : delimiter < 0 ? [...args, '--json'] : [...args.slice(0, delimiter), '--json', ...args.slice(delimiter)];
const child = spawn(engine, childArgs, {stdio: passthrough ? 'inherit' : ['inherit', 'pipe', 'pipe']});
let output = '';
let errors = '';
let spawnFailed = false;
child.stdout?.setEncoding('utf8').on('data', chunk => { output += chunk; });
child.stderr?.setEncoding('utf8').on('data', chunk => { errors += chunk; });
const h = React.createElement;
const text = (value, props = {}) => h(Text, props, clean(value));
const noColor = process.env.NO_COLOR !== undefined || process.env.TERM === 'dumb' || options.includes('never') || options.includes('--color=never');
const tone = color => noColor ? {} : {color};
const frame = (...rows) => h(Box, {
  flexDirection: 'column',
  borderStyle: 'round',
  ...(noColor ? {} : {borderColor: 'blueBright'}),
  paddingX: 2,
  paddingY: 1,
  marginX: 1,
}, ...rows);
const heading = () => [
  h(Banner, {color: !noColor}),
  text('Universal Binary Thinner', {dimColor: !noColor}),
  text('────────────────────────────────', tone('blueBright')),
];
const ui = passthrough ? null : render(frame(...heading(), text('◌  Reading app bundles…', {dimColor: !noColor})), {exitOnCtrlC: false});
const interrupt = () => { child.kill('SIGINT'); };
process.on('SIGINT', interrupt);

function reportView(report) {
  const rows = heading();
  if (!report.dryRun) {
    rows.push(text(`${report.command} · ${report.problems?.length ? 'unavailable' : 'result'}`, tone('yellow')));
    for (const app of report.apps ?? []) rows.push(text(`${app.path}: ${app.outcome} — ${app.reason}`));
    for (const problem of report.problems ?? []) rows.push(text(problem, tone('yellow')));
  } else {
    rows.push(text('◇  DRY RUN · No files changed', {dimColor: !noColor}));
    rows.push(text(report.root));
    const totals = report.totals;
    const mb = (totals.removableBytes / 1048576).toFixed(2);
    rows.push(h(Box, {marginTop: 1, marginBottom: 1, flexDirection: 'column'},
      text(`${mb} MiB estimated removable`, {bold: true, ...tone('green')}),
      text(`${totals.apps} apps · ${totals.universalFiles} universal files · ${totals.eligibleFiles} eligible · ${totals.skippedApps} apps skipped`),
      text('Logical bytes removed, not physical disk space freed.', {dimColor: !noColor})));
    rows.push(text(`Rosetta: ${report.rosetta.installed ? 'installed' : 'not installed'} · preferences for ${report.rosetta.preferencesUser}`));
    if (report.rosetta.problem) rows.push(text(report.rosetta.problem, tone('yellow')));
    for (const app of report.apps) {
      const status = app.skip ? 'SKIP' : app.issues.length ? 'CHECK' : app.eligibleFiles ? 'ELIGIBLE' : 'NO CHANGE';
      const icon = status === 'ELIGIBLE' ? '✓' : status === 'NO CHANGE' ? '○' : '⚠';
      rows.push(h(Box, {marginTop: 1, flexDirection: 'column'},
        text(`${icon}  [${status}] ${app.path}`, {bold: true, ...tone(status === 'ELIGIBLE' ? 'green' : 'yellow')}),
        text(app.skip?.detail ?? `${app.eligibleFiles} / ${app.universalFiles} files eligible · ${(app.removableBytes / 1048576).toFixed(2)} MiB removable`)));
      for (const issue of app.issues) rows.push(text(`  ${issue.path}: ${issue.problem}`, tone('yellow')));
      if (options.includes('--verbose') || options.includes('-v')) {
        for (const file of app.files) rows.push(text(`  ${file.eligible ? 'ELIGIBLE' : 'SKIP'} ${file.path}: ${file.skip?.detail ?? `${file.savedBytes} bytes removable`}`));
      }
    }
    if (!report.apps.length) rows.push(text('No apps found in the searched paths.'));
    for (const path of report.skippedPaths) rows.push(text(`Not searched: ${path.path || report.root} — ${path.reason.detail}`));
    for (const path of report.missingExclusions) rows.push(text(`Excluded path not found: ${path}`, tone('yellow')));
    for (const issue of report.issues) rows.push(text(`${issue.path || report.root}: ${issue.problem}`, tone('yellow')));
    const pending = report.pendingOperations;
    if (pending.operations.length || pending.problems.length) {
      rows.push(text('RECOVERY · Unlocked snapshot; may be out of date. Keep all backups.', {bold: true, ...tone('yellow')}));
      for (const op of pending.operations) rows.push(text(`${op.bundlePath}: ${op.state} — ${op.journalPath}`));
      for (const problem of pending.problems) rows.push(text(problem, tone('yellow')));
    }
    rows.push(h(Box, {marginTop: 1}, text(report.complete ? '✓  Scan complete. Use --verbose for file decisions.' : '⚠  Scan incomplete. Review the issues above.', tone(report.complete ? 'green' : 'yellow'))));
  }
  rows.push(text('────────────────────────────────', tone('blueBright')));
  rows.push(text(`ⓘ  ThinnerCore${report.tool?.version ? `  ·  ${report.tool.version}` : ''}`, {dimColor: !noColor}));
  return frame(...rows);
}

child.on('error', error => {
  spawnFailed = true;
  ui?.unmount();
  process.stderr.write(`thinnercore: ${clean(error.message)}\n`);
  process.exitCode = 1;
});
child.on('close', (code, signal) => {
  process.removeListener('SIGINT', interrupt);
  if (spawnFailed) return;
  if (ui) {
    try { ui.rerender(reportView(JSON.parse(output))); }
    catch {
      ui.rerender(frame(...diagnosticLines(errors || output || 'No report returned.').map((line, key) => h(Text, {key, ...tone('yellow')}, line))));
      if (code === 0) code = 1;
    }
    ui.unmount();
  }
  process.exitCode = signal ? 130 : code ?? 1;
});
