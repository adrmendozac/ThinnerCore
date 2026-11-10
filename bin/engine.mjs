// Locating and running the Swift engine. Every safety decision is the
// engine's; this module only spawns it and collects its output.
import {spawn} from 'node:child_process';
import {access} from 'node:fs/promises';
import {constants} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {stderrSplitter} from './progress.mjs';

export async function findEngine() {
  for (const candidate of ['../.build/release/thinnercore', '../.build/debug/thinnercore']) {
    const path = fileURLToPath(new URL(candidate, import.meta.url));
    try { await access(path, constants.X_OK); return path; } catch {}
  }
  return null;
}

// Runs the engine with stdin closed, so it can never wait for input that the
// UI owns. Commands that change the disk must already carry --yes, given only
// after the UI's own confirmation. Resolves {code, signal, output, errors}.
export function runEngine(engine, args, {onProgress = () => {}, signal} = {}) {
  return new Promise(resolve => {
    const child = spawn(engine, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {...process.env, THINNERCORE_PROGRESS: 'json'},
    });
    let output = '';
    let errors = '';
    const stderr = stderrSplitter(onProgress, text => { errors += text; });
    child.stdout.setEncoding('utf8').on('data', chunk => { output += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => stderr.write(chunk));
    const abort = () => child.kill('SIGINT');
    signal?.addEventListener('abort', abort, {once: true});
    child.on('error', error => {
      signal?.removeEventListener('abort', abort);
      resolve({code: 1, signal: null, output, errors: errors + error.message});
    });
    child.on('close', (code, killed) => {
      signal?.removeEventListener('abort', abort);
      stderr.flush();
      resolve({code: code ?? 1, signal: killed, output, errors});
    });
  });
}

// Parses an engine JSON result; throws with the engine's own diagnostics.
export function parseResult(result) {
  try { return JSON.parse(result.output); }
  catch { throw new Error((result.errors || result.output || 'The engine returned no report.').trim()); }
}
