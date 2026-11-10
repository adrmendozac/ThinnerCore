#!/usr/bin/env node
// With no arguments in a terminal: the interactive menu (bin/menu.mjs).
// `thinnercore menu [PATH]` opens it on another folder.
// Otherwise a one-shot command: the engine runs with --json and the report is
// rendered with Ink. --json, help, version, --apply, release --apply, and
// redirected output pass straight through to the engine, so its own
// confirmation prompt and plain output are used.
import {Box, Static, render} from 'ink';
import {spawn} from 'node:child_process';
import {diagnosticLines, clean} from './terminal-text.mjs';
import {findEngine, runEngine} from './engine.mjs';
import {Spinner, frame, h, mutationView, progressLabel, scanView, style, text, tone} from './ui.mjs';

const args = process.argv.slice(2);
const engine = await findEngine();
if (!engine) {
  process.stderr.write('thinnercore: build the Swift engine first with swift build -c release.\n');
  process.exit(1);
}

const interactive = process.stdin.isTTY && process.stdout.isTTY;
if (interactive && (args.length === 0 || args[0] === 'menu')) {
  const {runMenu} = await import('./menu.mjs');
  await runMenu(engine, args[1] ?? '/Applications');
} else {
  await oneShot();
}

async function oneShot() {
  const delimiter = args.indexOf('--');
  const options = delimiter < 0 ? args : args.slice(0, delimiter);
  if (options.includes('never') || options.includes('--color=never')) style.noColor = true;
  const passthrough = !process.stdout.isTTY
    || options.some(arg => ['--json', '--help', '-h', '--version', 'help', '--apply'].includes(arg))
    || ['skip', 'allow'].includes(options.find(arg => !arg.startsWith('-')));
  if (passthrough) {
    const child = spawn(engine, args, {stdio: 'inherit'});
    child.on('error', error => { process.stderr.write(`thinnercore: ${clean(error.message)}\n`); process.exitCode = 1; });
    child.on('close', (code, signal) => { process.exitCode = signal ? 130 : code ?? 1; });
    return;
  }
  const childArgs = delimiter < 0 ? [...args, '--json'] : [...args.slice(0, delimiter), '--json', ...args.slice(delimiter)];
  const verbose = options.includes('--verbose') || options.includes('-v');
  // Only a dry-run scan reports progress; other commands show a plain spinner.
  const scanning = !['restore', 'recover', 'release'].includes(options.find(arg => !arg.startsWith('-')));

  // The only live (redrawn) region is one spinner line. The finished report is
  // written once through <Static> into normal scrollback, because Ink cannot
  // redraw a frame taller than the window.
  const live = progress => h(Spinner, {label: progressLabel(progress, scanning ? 'Finding apps…' : 'Working…')});
  const ui = render(live(null), {exitOnCtrlC: false});
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.on('SIGINT', interrupt);
  const result = await runEngine(engine, childArgs, {onProgress: progress => ui.rerender(live(progress)), signal: controller.signal});
  process.removeListener('SIGINT', interrupt);

  let view;
  let code = result.code;
  try {
    const report = JSON.parse(result.output);
    view = report.dryRun ? scanView(report, {verbose}) : report.command ? mutationView(report) : frame(text(result.output));
  } catch {
    view = frame(...diagnosticLines(result.errors || result.output || 'No report returned.').map(line => text(line, tone('yellow'))));
    if (code === 0) code = 1;
  }
  ui.rerender(h(Static, {items: [view]}, (item, key) => h(Box, {key}, item)));
  ui.unmount();
  process.exitCode = result.signal ? 130 : code;
}
