// Shared Ink views for the one-shot report and the interactive menu.
import React, {useEffect, useState} from 'react';
import {Box, Text} from 'ink';
import {clean} from './terminal-text.mjs';
import {Banner} from './banner.mjs';

export const h = React.createElement;
export const style = {noColor: process.env.NO_COLOR !== undefined || process.env.TERM === 'dumb'};
export const text = (value, props = {}) => h(Text, props, clean(value));
export const tone = color => style.noColor ? {} : {color};
export const dim = () => ({dimColor: !style.noColor});

// Decimal units, matching the native report (ByteCountFormatter, .file).
export function bytes(n) {
  if (n < 1000) return `${n} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = n / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  // Whole kilobytes, one decimal above that, as ByteCountFormatter prints.
  return `${unit === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

export const count = (n, noun) => `${n} ${noun}${n === 1 ? '' : 's'}`;

export const frame = (...rows) => h(Box, {
  flexDirection: 'column',
  borderStyle: 'round',
  ...(style.noColor ? {} : {borderColor: 'blueBright'}),
  paddingX: 2,
  paddingY: 1,
  marginX: 1,
}, ...rows);

export const rule = () => text('────────────────────────────────', tone('blueBright'));

export const heading = () => [
  h(Banner, {color: !style.noColor}),
  text('Universal Binary Thinner', dim()),
  rule(),
];

const spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

export function Spinner({label}) {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => setTick(value => value + 1), 80);
    return () => clearInterval(timer);
  }, []);
  return h(Box, {marginX: 1},
    text(`${spinnerFrames[tick % spinnerFrames.length]} `, tone('cyan')),
    text(label, {wrap: 'truncate-middle'}));
}

export const progressLabel = (progress, idle = 'Finding apps…') => progress
  ? `Scanning ${progress.app} (${progress.index}/${progress.total})`
  : idle;

export function appStatus(app) {
  return app.skip ? 'SKIP' : app.issues.length ? 'CHECK' : app.eligibleFiles ? 'ELIGIBLE' : 'NO CHANGE';
}

// Summaries use stable reason codes; raw diagnostics remain in details and JSON.
const appSkipSummaries = {
  protectedLocation: "Protected location. This app cannot be changed.",
  excluded: "Excluded by your settings.",
  containsExclusion: "Contains an excluded item. The whole app was left unchanged.",
  bundleMetadata: "App information could not be verified. This app was left unchanged.",
  scriptOnly: "Script-based app. There is no executable to thin.",
  rosettaFlagged: "Set to open using Rosetta. Intel support was kept.",
  rosettaInconclusive: "Rosetta settings could not be checked. Intel support was kept.",
  noNativeMainExecutable: "The main executable has no standard Apple Silicon version. Intel support was kept.",
  intelArchitecturePriority: "This app does not prefer standard Apple Silicon execution. It was left unchanged.",
  intelOnlyCode: "Contains components that require Intel support. This app was left unchanged.",
  skipListed: "On your skip list.",
  skipListUnreadable: "Your skip list could not be read. Check access to the skip list file.",
  signatureInvalid: "Signature check failed. This app was left unchanged.",
  notOnAllowList: "Not on your allow list.",
  allowListUnreadable: "Your allow list could not be read. Check access to the allow list file.",
  masApp: "Mac App Store app. Left unchanged by default.",
  embedsSystemExtension: "Includes a system extension, as VPN and security software does. Left unchanged by default.",
};

export function appSkipMessage(reason, {verbose = false} = {}) {
  return verbose ? reason.detail : appSkipSummaries[reason.code] ?? reason.detail;
}

export function scanView(report, {verbose = false} = {}) {
  const rows = heading();
  rows.push(text('◇  DRY RUN · No files changed', dim()));
  rows.push(text(report.root));
  const totals = report.totals;
  rows.push(h(Box, {marginTop: 1, marginBottom: 1, flexDirection: 'column'},
    text(`${bytes(totals.removableBytes)} estimated removable`, {bold: true, ...tone('green')}),
    text(`${count(totals.apps, 'app')} · ${count(totals.universalFiles, 'universal file')} · ${totals.eligibleFiles} eligible · ${totals.skippedApps} skipped`),
    text('Logical bytes removed, not physical disk space freed.', dim())));
  rows.push(text(`Rosetta: ${report.rosetta.installed ? 'installed' : 'not installed'} · preferences for ${report.rosetta.preferencesUser}`));
  if (report.rosetta.problem) rows.push(text(report.rosetta.problem, tone('yellow')));
  for (const app of report.apps) {
    const status = appStatus(app);
    const icon = status === 'ELIGIBLE' ? '✓' : status === 'NO CHANGE' ? '○' : '⚠';
    rows.push(h(Box, {marginTop: 1, flexDirection: 'column'},
      text(`${icon}  [${status}] ${app.path}`, {bold: true, ...tone(status === 'ELIGIBLE' ? 'green' : 'yellow')}),
      text(`   ${app.skip ? appSkipMessage(app.skip, {verbose}) : `${app.eligibleFiles} / ${app.universalFiles} files eligible · ${bytes(app.removableBytes)} removable`}`)));
    for (const issue of app.issues) rows.push(text(`   ${issue.path}: ${issue.problem}`, tone('yellow')));
    if (verbose) {
      if (app.bundleIdentifier) rows.push(text(`   ${app.bundleIdentifier}`, dim()));
      for (const path of app.intelOnlyCode ?? []) rows.push(text(`   INTEL-ONLY ${path}`, tone('yellow')));
      for (const file of app.files) {
        rows.push(text(`   ${file.eligible ? 'ELIGIBLE' : 'SKIP    '} ${file.path}: ${file.skip?.detail ?? `remove ${(file.removing ?? []).join(', ')}, ${bytes(file.savedBytes)}`}`));
      }
    }
  }
  if (!report.apps.length) rows.push(text('No apps found in the searched paths.'));
  for (const path of report.skippedPaths) rows.push(text(`Not searched: ${path.path || report.root} — ${path.reason.detail}`));
  for (const path of report.missingExclusions) rows.push(text(`Excluded path not found: ${path}`, tone('yellow')));
  const allow = report.allowList;
  if (allow?.problem) rows.push(text(`Your allow list could not be read, so every app was refused: ${allow.problem}`, tone('yellow')));
  else if (allow) rows.push(text(`Allow list: only its ${allow.entries} ${allow.entries === 1 ? 'entry' : 'entries'} can be thinned.`, tone('cyan')));
  for (const path of allow?.missingPaths ?? []) rows.push(text(`Allow list path not found, so it allows nothing: ${path}`, tone('yellow')));
  const intelPlugins = report.plugins?.intelOnly ?? [];
  if (intelPlugins.length) {
    rows.push(text(`${count(intelPlugins.length, 'Intel-only audio plugin')} found. An app that hosts them can no longer load them once thinned; add such apps to the skip list.`, tone('yellow')));
    for (const path of intelPlugins) rows.push(text(`   ${path}`, tone('yellow')));
  }
  for (const path of report.plugins?.uninspected ?? []) rows.push(text(`Could not inspect plugin (may be Intel-only): ${path}`, tone('yellow')));
  for (const issue of report.issues) rows.push(text(`${issue.path || report.root}: ${issue.problem}`, tone('yellow')));
  const pending = report.pendingOperations;
  if (pending.operations.length || pending.problems.length) {
    rows.push(text('RECOVERY · Unlocked snapshot; may be out of date. Keep all backups.', {bold: true, ...tone('yellow')}));
    for (const op of pending.operations) rows.push(text(`${op.bundlePath}: ${op.state} — ${op.journalPath}`));
    for (const problem of pending.problems) rows.push(text(problem, tone('yellow')));
  }
  if (report.backups?.sets?.length) {
    rows.push(text(`Retained backups: ${count(report.backups.sets.length, 'backup set')} · ${bytes(sum(report.backups.sets, 'retainedBytes'))} kept · ${bytes(sum(report.backups.sets, 'removedBytes'))} removed by thinning`));
  }
  rows.push(h(Box, {marginTop: 1}, text(report.complete
    ? `✓  Scan complete.${verbose ? '' : ' Use App details or --verbose for technical details.'}`
    : '⚠  Scan incomplete. Review the issues above.', tone(report.complete ? 'green' : 'yellow'))));
  return footer(rows, report);
}

const sum = (items, key) => items.reduce((total, item) => total + (item[key] ?? 0), 0);

const outcomeLabels = {
  committed: 'Done',
  skipped: 'Skipped',
  nothingToDo: 'Nothing to do',
  refused: 'Refused',
  rolledBack: 'Rolled back',
  recoveryPending: 'Recovery pending',
  recoveryFailed: 'Recovery failed',
  superseded: 'Superseded',
};

export function mutationView(report) {
  const rows = [text(`${report.command} · ${report.problems?.length ? 'unavailable' : 'result'}`, {bold: true, ...tone('yellow')})];
  for (const app of report.apps ?? []) {
    const good = ['committed', 'nothingToDo', 'skipped', 'superseded'].includes(app.outcome);
    rows.push(h(Box, {marginTop: 1, flexDirection: 'column'},
      text(`${good ? '✓' : '⚠'}  ${outcomeLabels[app.outcome] ?? app.outcome} · ${app.path}`, {bold: true, ...tone(good ? 'green' : 'yellow')}),
      text(`   ${app.reason}`)));
    const restore = app.restore;
    if (restore) {
      for (const path of restore.restored) rows.push(text(`   Restored: ${path}`));
      for (const path of restore.alreadyOriginal) rows.push(text(`   Already original: ${path}`, dim()));
      for (const note of restore.notes) rows.push(text(`   Note: ${note}`, dim()));
    }
    const release = app.release;
    if (release) {
      const verb = release.dryRun ? 'Would delete' : 'Deleted';
      for (const path of release.released) rows.push(text(`   ${verb}: ${path}`));
      if (release.released.length) rows.push(text(`   ${verb} ${bytes(release.releasedBytes)} of backups (logical size)`));
      for (const note of release.notes) rows.push(text(`   Note: ${note}`, dim()));
    }
  }
  for (const problem of [...new Set(report.problems ?? [])]) rows.push(h(Box, {marginTop: 1}, text(problem, tone('yellow'))));
  return frame(...rows);
}

export function messageView(lines, color) {
  return frame(...lines.map(line => text(line, color ? tone(color) : {})));
}

function footer(rows, report) {
  rows.push(rule());
  rows.push(text(`ⓘ  thinnercore${report.tool?.version ? `  ·  ${report.tool.version}` : ''}`, dim()));
  return frame(...rows);
}
