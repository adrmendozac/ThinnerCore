// Opens the interactive menu. This file asks questions and displays results;
// Swift checks each app and makes the changes after the user confirms.
// Keep finished reports in terminal history and redraw only the current prompt.
import React, {useState, useSyncExternalStore} from 'react';
import {Box, Static, render, useInput, useWindowSize} from 'ink';
import {existsSync} from 'node:fs';
import {writeFile} from 'node:fs/promises';
import {homedir} from 'node:os';
import {basename, join, resolve} from 'node:path';
import {parseResult, runEngine} from './engine.mjs';
import {
  Spinner, appStatus, bytes, count, dim, frame, h, heading, messageView, mutationView,
  progressLabel, scanView, style, text, tone,
} from './ui.mjs';

const QUIT = Symbol('quit');
class Quit extends Error {}
class Cancelled extends Error {}
class Interrupted extends Error {}

// Keep track of the current question and results already shown.

function createStore() {
  let state = {screen: null, history: []};
  let nextId = 0;
  const listeners = new Set();
  const set = patch => { state = {...state, ...patch}; listeners.forEach(listener => listener()); };
  return {
    get: () => state,
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    log: element => set({history: [...state.history, element]}),
    clear: () => set({screen: null}),
    busy: (label, onCancel) => set({screen: {type: 'busy', id: 'busy', label, onCancel}}),
    async ask(screen) {
      const answer = await new Promise(done => set({screen: {...screen, id: nextId++, resolve: done}}));
      set({screen: null});
      if (answer === QUIT) throw new Quit();
      return answer;
    },
  };
}

function App({store}) {
  const state = useSyncExternalStore(store.subscribe, store.get);
  const screen = state.screen;
  const view = !screen ? null
    : screen.type === 'select' ? h(Select, {key: screen.id, screen})
    : screen.type === 'multi' ? h(MultiSelect, {key: screen.id, screen})
    : screen.type === 'input' ? h(Input, {key: screen.id, screen})
    : screen.type === 'confirm' ? h(Confirm, {key: screen.id, screen})
    : h(Busy, {key: 'busy', screen});
  return h(Box, {flexDirection: 'column'},
    h(Static, {items: state.history}, (item, key) => h(Box, {key}, item)),
    view);
}

// Draw menus, questions, and progress indicators.

const isQuit = (input, key) => key.ctrl && input === 'c';

function Busy({screen}) {
  useInput((input, key) => { if (isQuit(input, key)) screen.onCancel?.(); });
  return h(Spinner, {label: screen.label});
}

// Show the selected item and nearby options that fit in the terminal.
function windowed(items, cursor, rows, reserved) {
  const size = Math.max(3, rows - reserved);
  if (items.length <= size) return {start: 0, shown: items};
  const start = Math.min(Math.max(0, cursor - Math.floor(size / 2)), items.length - size);
  return {start, shown: items.slice(start, start + size)};
}

function listRows(items, cursor, start, render) {
  return items.map((item, offset) => {
    const index = start + offset;
    const active = index === cursor;
    return h(Box, {key: index},
      text(active ? '› ' : '  ', tone('cyan')),
      render(item, active));
  });
}

function itemLine(item, active) {
  const label = `${item.key ? `${item.key}. ` : ''}${item.label}`;
  // Keep the option name readable. Shorten its description when space is tight.
  return h(Box, {flexGrow: 1},
    h(Box, {flexShrink: 0}, text(label, {bold: active, ...(item.disabled ? dim() : {})})),
    item.hint ? h(Box, {flexShrink: 1}, text(`  ${item.hint}`, {wrap: 'truncate-middle', ...dim()})) : null);
}

function Select({screen}) {
  const {rows} = useWindowSize();
  const [cursor, setCursor] = useState(0);
  const [filter, setFilter] = useState('');
  const needle = filter.toLowerCase();
  const items = needle
    ? screen.items.filter(item => `${item.label} ${item.hint ?? ''}`.toLowerCase().includes(needle))
    : screen.items;
  const at = Math.min(cursor, Math.max(0, items.length - 1));
  const pick = item => { if (item && !item.disabled) screen.resolve(item.value); };

  useInput((input, key) => {
    if (isQuit(input, key)) return screen.resolve(QUIT);
    if (key.escape) return filter ? setFilter('') : screen.resolve(null);
    if (key.upArrow) return setCursor(Math.max(0, at - 1));
    if (key.downArrow) return setCursor(Math.min(items.length - 1, at + 1));
    if (key.pageUp) return setCursor(Math.max(0, at - 10));
    if (key.pageDown) return setCursor(Math.min(items.length - 1, at + 10));
    if (key.return) return pick(items[at]);
    if (screen.filterable) {
      if (key.backspace || key.delete) { setFilter(value => value.slice(0, -1)); setCursor(0); }
      else if (input && !key.ctrl && !key.meta && input >= ' ') { setFilter(value => value + input); setCursor(0); }
      return;
    }
    const shortcut = screen.items.find(item => item.key && item.key === input);
    if (shortcut) pick(shortcut);
  });

  const reserved = 6 + (screen.filterable ? 1 : 0) + (screen.lines?.length ?? 0);
  const {start, shown} = windowed(items, at, rows, reserved);
  return h(Box, {flexDirection: 'column', marginX: 1, marginTop: 1},
    text(screen.title, {bold: true}),
    ...(screen.lines ?? []).map(line => text(line, dim())),
    screen.filterable ? text(filter ? `Filter: ${filter}▏` : 'Type to filter', dim()) : null,
    start > 0 ? text(`  ↑ ${start} more`, dim()) : null,
    ...listRows(shown, at, start, itemLine),
    start + shown.length < items.length ? text(`  ↓ ${items.length - start - shown.length} more`, dim()) : null,
    items.length === 0 ? text('  No matches', dim()) : null,
    text(screen.help ?? `↑↓ move · enter select${screen.filterable ? '' : ' · number shortcut'} · esc back · ctrl+c quit`, dim()));
}

function MultiSelect({screen}) {
  const {rows} = useWindowSize();
  const [cursor, setCursor] = useState(0);
  const [chosen, setChosen] = useState(() => new Set(screen.preselected ?? []));
  const items = screen.items;
  const toggle = value => setChosen(previous => {
    const next = new Set(previous);
    if (next.has(value)) next.delete(value); else next.add(value);
    return next;
  });

  useInput((input, key) => {
    if (isQuit(input, key)) return screen.resolve(QUIT);
    if (key.escape) return screen.resolve(null);
    if (key.upArrow) return setCursor(Math.max(0, cursor - 1));
    if (key.downArrow) return setCursor(Math.min(items.length - 1, cursor + 1));
    if (key.pageUp) return setCursor(Math.max(0, cursor - 10));
    if (key.pageDown) return setCursor(Math.min(items.length - 1, cursor + 10));
    if (input === ' ') return toggle(items[cursor].value);
    if (input === 'a') return setChosen(chosen.size === items.length ? new Set() : new Set(items.map(item => item.value)));
    // Enter with nothing ticked takes the highlighted item; a confirmation
    // always follows before anything changes.
    if (key.return) {
      const picked = items.filter(item => chosen.has(item.value)).map(item => item.value);
      return screen.resolve(picked.length ? picked : [items[cursor].value]);
    }
  });

  const selected = items.filter(item => chosen.has(item.value));
  const reserved = 7 + (screen.lines?.length ?? 0);
  const {start, shown} = windowed(items, cursor, rows, reserved);
  return h(Box, {flexDirection: 'column', marginX: 1, marginTop: 1},
    text(screen.title, {bold: true}),
    ...(screen.lines ?? []).map(line => text(line, dim())),
    start > 0 ? text(`  ↑ ${start} more`, dim()) : null,
    ...listRows(shown, cursor, start, (item, active) => h(Box, {flexGrow: 1},
      text(chosen.has(item.value) ? '[x] ' : '[ ] ', tone(chosen.has(item.value) ? 'green' : undefined)),
      itemLine(item, active))),
    start + shown.length < items.length ? text(`  ↓ ${items.length - start - shown.length} more`, dim()) : null,
    text(screen.summary ? screen.summary(selected) : `${selected.length} selected`, tone('cyan')),
    text('↑↓ move · space toggle · a all/none · enter continue · esc back', dim()));
}

function Input({screen}) {
  const [value, setValue] = useState(screen.initial ?? '');
  useInput((input, key) => {
    if (isQuit(input, key)) return screen.resolve(QUIT);
    if (key.escape) return screen.resolve(null);
    if (key.return) return screen.resolve(value);
    if (key.backspace || key.delete) return setValue(previous => previous.slice(0, -1));
    if (input && !key.ctrl && !key.meta) setValue(previous => previous + input.replace(/[\r\n]/g, ''));
  });
  return h(Box, {flexDirection: 'column', marginX: 1, marginTop: 1},
    text(screen.title, {bold: true}),
    ...(screen.lines ?? []).map(line => text(line, dim())),
    h(Box, null, text('› ', tone('cyan')), text(`${value}▏`)),
    text(screen.help ?? 'enter confirm · esc back', dim()));
}

// Y confirms. Enter, N, and Escape cancel.
function Confirm({screen}) {
  useInput((input, key) => {
    if (isQuit(input, key)) return screen.resolve(QUIT);
    if (input === 'y' || input === 'Y') return screen.resolve(true);
    if (input === 'n' || input === 'N' || key.escape || key.return) return screen.resolve(false);
  });
  return h(Box, {flexDirection: 'column', marginX: 1, marginTop: 1, borderStyle: 'round', paddingX: 1,
    ...(screen.danger && !style.noColor ? {borderColor: 'yellow'} : {})},
    ...screen.lines.map(line => typeof line === 'string' ? text(line) : text(line.text, line.props)),
    h(Box, {marginTop: 1}, text(`${screen.question} `, {bold: true}), text('[y/N]', tone('cyan'))));
}

// Start the menu and handle the user’s choices.

export async function runMenu(engine, defaultRoot) {
  const store = createStore();
  const instance = render(h(App, {store}), {exitOnCtrlC: false});
  const menu = new Menu(engine, resolve(expandHome(defaultRoot)), store);
  try {
    await menu.run();
  } catch (error) {
    if (!(error instanceof Quit)) throw error;
  } finally {
    store.clear();
    instance.unmount();
  }
}

const expandHome = path => path === '~' ? homedir() : path.startsWith('~/') ? join(homedir(), path.slice(2)) : path;

// How long ago a scan ran, for the menu hints.
export function ago(at, now = Date.now()) {
  const minutes = Math.floor((now - at) / 60_000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours} h ago`;
}

const mainItems = (root, scannedAt) => [
  {key: '1', value: 'scanAll', label: scannedAt ? 'Scan all applications again' : 'Scan all applications',
    hint: scannedAt ? `check ${root} without changing anything · last scanned ${ago(scannedAt)}` : `check ${root} without changing anything`},
  {key: '2', value: 'select', label: 'Select applications to thin…',
    hint: scannedAt ? `from the scan ${ago(scannedAt)}` : 'choose apps and review before changing them'},
  {key: '3', value: 'updates', label: 'Search for updated apps…', hint: 'see whether Intel code has returned'},
  {key: '4', value: 'folder', label: 'Scan a folder or app…'},
  {key: '5', value: 'details', label: 'App details…', hint: 'see what can change and why files were skipped'},
  {key: '6', value: 'restore', label: 'Restore an app…', hint: 'bring back original files from a backup'},
  {key: '7', value: 'recover', label: 'Recover interrupted operations…'},
  {key: '8', value: 'backups', label: 'Backups…', hint: 'review saved originals or delete backups'},
  {key: '9', value: 'skipList', label: 'Skip list…', hint: 'choose apps to always leave unchanged'},
  {key: 'a', value: 'allowList', label: 'Allow list…', hint: 'thin only the apps you choose'},
  {key: 'e', value: 'export', label: 'Export report as JSON…', hint: 'export full details as a JSON file'},
  {key: 'q', value: 'exit', label: 'Exit'},
];

export class Menu {
  constructor(engine, root, store) {
    this.engine = engine;
    this.root = root;
    this.ui = store;
    // Scan reports by folder, for the whole session (see scan()).
    this.cache = new Map();
  }

  async run() {
    this.ui.log(frame(...heading()));
    for (;;) {
      const choice = await this.ui.ask({type: 'select', title: 'What would you like to do?',
        items: mainItems(this.root, this.cache.get(this.root)?.at)});
      if (choice === null || choice === 'exit') return;
      try {
        await this[choice]();
      } catch (error) {
        if (error instanceof Quit) throw error;
        if (error instanceof Cancelled) this.ui.log(messageView(['Cancelled. Nothing changed.'], 'yellow'));
        else this.ui.log(messageView(String(error.message ?? error).split('\n'), 'yellow'));
      }
    }
  }

  // Run Swift commands and collect their results.

  async engineRun(args, label) {
    const controller = new AbortController();
    const cancel = () => controller.abort();
    this.ui.busy(label, cancel);
    const mutating = ['restore', 'recover'].includes(args[0]) || args.includes('--apply')
      || (['skip', 'allow'].includes(args[0]) && ['add', 'remove'].includes(args[1]));
    try {
      const result = await runEngine(this.engine, args, {
        signal: controller.signal,
        onProgress: progress => this.ui.busy(progressLabel(progress), cancel),
      });
      if (result.signal) {
        const guidance = args[0] === 'release'
          ? 'Some backups may already have been deleted. Review Backups and retry the release to finish.'
          : ['skip', 'allow'].includes(args[0])
            ? 'The list may have changed. Read it again before retrying.'
            : 'Files may have changed. Keep all backups, quit the affected app, and run recovery before continuing.';
        throw new Interrupted(mutating ? `Operation interrupted. ${guidance}` : 'Scan interrupted. No app files were changed.');
      }
      return result;
    } finally {
      this.ui.clear();
      // An interrupted command may already have changed files or settings.
      if (mutating) this.cache.clear();
    }
  }

  // A scan is kept for the rest of the session, one per folder, so moving
  // between menu items never scans again. It only feeds the pickers and the
  // views: the engine rechecks everything under the app's lock before any
  // change, so an old scan can never authorize one. Thinning, restoring,
  // recovering, releasing backups, and editing the skip list forget every
  // scan; "Scan all applications" refreshes, and the menu shows each scan's age.
  async scan(path = this.root, {fresh = false} = {}) {
    const cached = this.cache.get(path);
    if (!fresh && cached) return cached.report;
    const result = await this.engineRun(['scan', path, '--json'], 'Finding apps…');
    const report = parseResult(result);
    this.cache.set(path, {report, output: result.output, at: Date.now()});
    return report;
  }

  // "Scanned 3 min ago", for screens built from a kept scan.
  scannedLine(path = this.root) {
    const at = this.cache.get(path)?.at;
    return at ? [`From the scan ${ago(at)}. Choose "Scan all applications" to refresh it.`] : [];
  }

  appPath(report, app) {
    return report.root.endsWith('.app') && basename(report.root) === app.path ? report.root : join(report.root, app.path);
  }

  thinnable(report) {
    return report.apps.filter(app => !app.skip && app.issues.length === 0 && app.eligibleFiles > 0);
  }

  // Handle each menu option.

  async scanAll() {
    this.ui.log(scanView(await this.scan(this.root, {fresh: true})));
  }

  async select() {
    const report = await this.scan();
    const apps = this.thinnable(report);
    if (!apps.length) {
      this.ui.log(messageView([`No apps in ${report.root} can be thinned right now.`, 'Choose "Scan all applications" to see why each app is skipped.']));
      return;
    }
    const picked = await this.ui.ask({
      type: 'multi',
      title: `Select applications to thin (${count(apps.length, 'eligible app')})`,
      lines: this.scannedLine(),
      items: apps.map(app => ({value: app.path, label: app.path, hint: `${bytes(app.removableBytes)} · ${count(app.eligibleFiles, 'file')}`})),
      summary: chosen => `${chosen.length} selected · ${bytes(sumBytes(apps, chosen))} estimated removable`,
    });
    if (!picked?.length) return;
    await this.thin(report, apps.filter(app => picked.includes(app.path)));
  }

  async updates() {
    const report = await this.scan(this.root, {fresh: true});
    const thinnedBefore = new Set((report.backups?.sets ?? []).filter(set => !set.restoreState).map(set => set.bundlePath));
    const apps = this.thinnable(report).filter(app => thinnedBefore.has(this.appPath(report, app)));
    if (!apps.length) {
      this.ui.log(messageView([thinnedBefore.size
        ? `None of the ${count(thinnedBefore.size, 'app')} thinned earlier has become universal again.`
        : `No apps under ${report.root} have been thinned by this tool yet.`]));
      return;
    }
    const picked = await this.ui.ask({
      type: 'multi',
      title: `${count(apps.length, 'app')} thinned earlier became universal again (usually an app update)`,
      items: apps.map(app => ({value: app.path, label: app.path, hint: `${bytes(app.removableBytes)} removable again`})),
      preselected: apps.map(app => app.path),
      summary: chosen => `${chosen.length} selected · ${bytes(sumBytes(apps, chosen))} estimated removable`,
    });
    if (!picked?.length) return;
    await this.thin(report, apps.filter(app => picked.includes(app.path)));
  }

  // Explain the changes, ask for confirmation, then process each app.
  async thin(report, apps) {
    const total = apps.reduce((sum, app) => sum + app.removableBytes, 0);
    const confirmed = await this.ui.ask({
      type: 'confirm',
      danger: true,
      lines: [
        {text: `About to thin ${count(apps.length, 'app')}:`, props: {bold: true}},
        ...apps.map(app => `  ${app.path}  ${bytes(app.removableBytes)}`),
        '',
        `Estimated ${bytes(total)} removable (logical size, not guaranteed free space).`,
        'Backups of the original files are kept, so disk usage first grows by about the',
        'same amount until you release them under Backups. Quit these apps first:',
        'every check runs again, and a running app is refused.',
      ],
      question: `Thin ${count(apps.length, 'app')}?`,
    });
    if (!confirmed) throw new Cancelled();

    const results = [];
    const problems = new Set();
    for (const [index, app] of apps.entries()) {
      let stopReason;
      try {
        const result = await this.engineRun(['scan', this.appPath(report, app), '--apply', '--yes', '--json'],
          `Thinning ${app.path} (${index + 1}/${apps.length})…`);
        const mutation = parseResult(result);
        if (!Array.isArray(mutation.apps) || !Array.isArray(mutation.problems)) {
          throw new Error('The engine returned an incomplete report.');
        }
        results.push(...mutation.apps);
        mutation.problems.forEach(problem => problems.add(problem));
        if ([3, 4].includes(result.code) || mutation.apps.some(item =>
          ['recoveryPending', 'recoveryFailed'].includes(item.outcome))) {
          stopReason = 'Not attempted: resolve the unfinished operation first. Keep all backups.';
        } else if (mutation.problems.some(problem => problem.startsWith('Modification is unavailable'))) {
          stopReason = 'Not attempted: modification is unavailable in this build.';
        }
      } catch (error) {
        // Preserve earlier results. Without a complete report, we cannot claim
        // that the current app was untouched or safely rolled back.
        const reason = error instanceof Interrupted ? error.message
          : `Operation stopped: ${error.message ?? error}. Files may have changed. Keep all backups and run recovery before continuing.`;
        results.push({path: this.appPath(report, app), outcome: 'recoveryPending', reason});
        stopReason = 'Not attempted after an interrupted or unconfirmed operation.';
      }
      if (stopReason) {
        for (const rest of apps.slice(index + 1)) {
          results.push({path: this.appPath(report, rest), outcome: 'refused', reason: stopReason});
        }
        break;
      }
    }
    this.cache.clear();
    this.ui.log(mutationView({command: 'thin', apps: results, problems: [...problems]}));
  }

  async folder() {
    const path = await this.ui.ask({type: 'input', title: 'Folder or app to scan', initial: '~/', lines: ['Scan only. No files will be changed.']});
    if (!path?.trim()) return;
    const target = resolve(expandHome(path.trim()));
    this.ui.log(scanView(await this.scan(target, {fresh: true})));
  }

  async details() {
    const report = await this.scan();
    if (!report.apps.length) { this.ui.log(messageView([`No apps found in ${report.root}.`])); return; }
    const choice = await this.ui.ask({
      type: 'select', filterable: true, title: 'Which app?', lines: this.scannedLine(),
      items: report.apps.map(app => ({value: app.path, label: app.path, hint: appStatus(app).toLowerCase()})),
    });
    if (choice === null) return;
    // The kept scan already holds every file's decision: no second scan.
    const app = report.apps.find(candidate => candidate.path === choice);
    this.ui.log(scanView(appReport(report, app, this.appPath(report, app)), {verbose: true}));
  }

  async restore() {
    const report = await this.scan();
    const backedUp = [...new Set((report.backups?.sets ?? []).map(set => set.bundlePath))];
    const choice = await this.ui.ask({
      type: 'select', title: 'Restore which app?',
      lines: backedUp.length ? [] : [`No backups found beside apps in ${report.root}.`],
      items: [
        ...backedUp.map(path => ({value: path, label: basename(path), hint: path})),
        {value: '', label: 'Type a path…'},
      ],
    });
    if (choice === null) return;
    let path = choice;
    if (!path) {
      const typed = await this.ui.ask({type: 'input', title: 'App to restore', initial: '/Applications/'});
      if (!typed?.trim()) return;
      path = resolve(expandHome(typed.trim()));
    }
    const confirmed = await this.ui.ask({
      type: 'confirm',
      lines: [
        {text: `Restore ${basename(path)}?`, props: {bold: true}},
        'Puts the original universal files back from this tool\'s backups.',
        'The backups are kept. Quit the app first.',
      ],
      question: 'Restore?',
    });
    if (!confirmed) throw new Cancelled();
    const result = await this.engineRun(['restore', path, '--json'], `Restoring ${basename(path)}…`);
    this.cache.clear();
    this.ui.log(mutationView(parseResult(result)));
  }

  async recover() {
    const confirmed = await this.ui.ask({
      type: 'confirm',
      lines: [
        {text: `Recover interrupted operations under ${this.root}?`, props: {bold: true}},
        'Finishes or undoes thinning or restoring that stopped part-way, from its journal.',
        'All backups are kept.',
      ],
      question: 'Recover?',
    });
    if (!confirmed) throw new Cancelled();
    const result = await this.engineRun(['recover', this.root, '--json'], 'Recovering…');
    this.cache.clear();
    this.ui.log(mutationView(parseResult(result)));
  }

  async backups() {
    const report = await this.scan();
    const sets = report.backups?.sets ?? [];
    if (!sets.length) { this.ui.log(messageView([`No retained backups beside apps in ${report.root}.`])); return; }
    const byApp = new Map();
    for (const set of sets) {
      const entry = byApp.get(set.bundlePath) ?? {kept: 0, removed: 0, sets: 0};
      entry.kept += set.retainedBytes; entry.removed += set.removedBytes; entry.sets += 1;
      byApp.set(set.bundlePath, entry);
    }
    const kept = sets.reduce((sum, set) => sum + set.retainedBytes, 0);
    const choice = await this.ui.ask({
      type: 'select', title: 'Retained backups',
      lines: [`${bytes(kept)} kept in ${count(sets.length, 'backup set')}. Choose an app to review and release (delete) its backups.`],
      items: [...byApp].map(([path, entry]) => ({
        value: path, label: basename(path), hint: `${bytes(entry.kept)} kept · ${bytes(entry.removed)} removed · ${count(entry.sets, 'set')}`,
      })),
    });
    if (choice === null) return;

    const preview = parseResult(await this.engineRun(['release', choice, '--json'], 'Checking backups…'));
    this.ui.log(mutationView(preview));
    const details = preview.apps?.[0]?.release;
    if (!details?.released?.length || preview.apps[0].outcome !== 'nothingToDo') return;

    // Deleting backups cannot be undone: the user types the app's name.
    const name = basename(choice).replace(/\.app$/i, '');
    const typed = await this.ui.ask({
      type: 'input', title: `Type ${name} to delete ${bytes(details.releasedBytes)} of backups`,
      lines: [
        'Afterwards only reinstalling the app, while its vendor still ships a universal build,',
        'brings back its Intel code. This cannot be undone.',
      ],
      help: 'enter confirm · esc cancel',
    });
    if (typed?.trim() !== name) throw new Cancelled();
    const result = await this.engineRun(['release', choice, '--apply', '--yes', '--json'], 'Deleting backups…');
    this.cache.clear();
    this.ui.log(mutationView(parseResult(result)));
  }

  async skipList() { await this.editList(lists.skip); }
  async allowList() { await this.editList(lists.allow); }

  // The skip list and the allow list share one editor: same file format,
  // same engine commands under different names.
  async editList(kind) {
    for (;;) {
      const list = parseResult(await this.engineRun([kind.command, 'list', '--json'], `Reading the ${kind.noun}…`));
      const choice = await this.ui.ask({
        type: 'select', title: `${kind.title} · ${list.entries.length} ${list.entries.length === 1 ? 'entry' : 'entries'}`,
        lines: [list.path, ...(list.entries.length ? [] : kind.whenEmpty ?? [])],
        items: [
          {value: {add: 'app'}, label: 'Add an app from the scan…'},
          {value: {add: 'text'}, label: kind.addText},
          ...list.entries.map(entry => ({value: {remove: entry}, label: `Remove ${entry}`})),
          {value: null, label: 'Back'},
        ],
        help: '↑↓ move · enter select · esc back',
      });
      if (!choice) return;
      if (choice.remove) {
        const confirmed = await this.ui.ask({type: 'confirm', lines: [`Remove ${choice.remove} from the ${kind.noun}?`, kind.afterRemove], question: 'Remove?'});
        if (confirmed) await this.listCommand(kind, ['remove', choice.remove]);
        continue;
      }
      let entry;
      if (choice.add === 'app') {
        const report = await this.scan();
        const picked = await this.ui.ask({
          type: 'select', filterable: true, title: kind.pickTitle,
          items: report.apps.map(app => ({value: app.path, label: app.path, hint: app.bundleIdentifier ?? ''})),
        });
        if (picked === null) continue;
        const app = report.apps.find(candidate => candidate.path === picked);
        // The app's ID follows it if the user moves it.
        entry = app.bundleIdentifier ?? this.appPath(report, app);
      } else {
        const typed = await this.ui.ask({type: 'input', title: 'Path or bundle identifier', lines: [kind.example]});
        if (!typed?.trim()) continue;
        entry = typed.trim().startsWith('~') ? expandHome(typed.trim()) : typed.trim();
      }
      await this.listCommand(kind, ['add', entry]);
    }
  }

  async listCommand(kind, args) {
    const result = await this.engineRun([kind.command, ...args], `Updating the ${kind.noun}…`);
    this.cache.clear();
    const message = (result.output || result.errors).trim().split('\n');
    this.ui.log(messageView(message, result.code === 0 ? 'green' : 'yellow'));
  }

  async export() {
    const date = new Date().toISOString().slice(0, 10);
    const path = await this.ui.ask({type: 'input', title: 'Save the scan report as', initial: `~/thinnercore-report-${date}.json`});
    if (!path?.trim()) return;
    const target = resolve(expandHome(path.trim()));
    if (existsSync(target)) {
      const overwrite = await this.ui.ask({type: 'confirm', lines: [`${target} already exists.`], question: 'Replace it?'});
      if (!overwrite) throw new Cancelled();
    }
    await this.scan();
    await writeFile(target, this.cache.get(this.root).output);
    this.ui.log(messageView([`Saved the report for ${this.root} to ${target}`], 'green'));
  }
}

export const lists = {
  skip: {
    command: 'skip', noun: 'skip list', title: 'Skip list',
    addText: 'Add a path or bundle identifier…', pickTitle: 'Never thin which app?',
    afterRemove: 'The app will be checked for eligibility on the next scan.',
    example: 'For example /Applications/Example.app or com.example.app',
  },
  allow: {
    command: 'allow', noun: 'allow list', title: 'Allow list',
    addText: 'Add a folder, path, or bundle identifier…', pickTitle: 'Allow which app to be thinned?',
    afterRemove: 'If the list becomes empty, every app can be thinned again.',
    example: 'For example /Applications/Example.app, a folder such as /Applications/Utilities, or com.example.app',
    whenEmpty: ['Empty: every app can be thinned. Add apps here to thin only those; the skip list still wins.'],
  },
};

const sumBytes = (apps, chosen) => apps.filter(app => chosen.some(item => item.value === app.path))
  .reduce((sum, app) => sum + app.removableBytes, 0);

// One app's part of a folder scan, as a report of its own, so its details
// come from the scan already made.
export function appReport(report, app, path) {
  const mine = item => item.bundlePath === path;
  return {
    ...report,
    root: path,
    apps: [app],
    totals: {
      apps: 1, skippedApps: app.skip ? 1 : 0, universalFiles: app.universalFiles,
      eligibleFiles: app.eligibleFiles, removableBytes: app.removableBytes, issues: app.issues.length,
    },
    skippedPaths: [], missingExclusions: [], issues: [],
    pendingOperations: {...report.pendingOperations, operations: (report.pendingOperations?.operations ?? []).filter(mine)},
    backups: {...report.backups, sets: (report.backups?.sets ?? []).filter(mine)},
    complete: app.issues.length === 0,
  };
}
