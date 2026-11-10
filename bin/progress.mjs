// Scan progress from the engine: one JSON line on stderr per app, written
// when THINNERCORE_PROGRESS=json (see ProgressLine in Sources/thinner/Thinner.swift).
// Anything else on stderr is a diagnostic and is kept for display.

export function parseProgress(line) {
  if (!line.startsWith('{"progress"')) return null;
  try {
    const {progress} = JSON.parse(line);
    return typeof progress?.app === 'string' && Number.isInteger(progress.index) && Number.isInteger(progress.total)
      ? progress : null;
  } catch { return null; }
}

// Splits a stderr stream into lines, sending progress to onProgress and
// everything else to onDiagnostic. Call flush() at end of stream.
export function stderrSplitter(onProgress, onDiagnostic) {
  let pending = '';
  const line = text => {
    const progress = parseProgress(text);
    if (progress) onProgress(progress);
    else onDiagnostic(text + '\n');
  };
  return {
    write(chunk) {
      const lines = (pending + chunk).split('\n');
      pending = lines.pop();
      lines.forEach(line);
    },
    flush() {
      if (pending) onDiagnostic(pending);
      pending = '';
    },
  };
}
