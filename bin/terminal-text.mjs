// Keep untrusted app paths and diagnostics from controlling the terminal.
export function clean(value) {
  return String(value)
    .replace(/\u001b(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001b]*(?:\u0007|\u001b\\))?/g, '')
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, character =>
      character === '\n' || character === '\t' ? character : '');
}

export function diagnosticLines(value) {
  return clean(value).split(/\r?\n/).filter(Boolean);
}
