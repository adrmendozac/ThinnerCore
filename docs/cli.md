# thinnercore CLI

The command is `thinnercore`. The terminal interface uses Ink and React;
the native Swift executable supplies the scan report and safety checks.

Build the native executable, install the frontend's dependencies from the
lockfile, then run the frontend from this checkout:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release
npm ci
npm start -- scan
```

With no path, scan reads `/Applications`. To scan one app, pass its actual path in quotes.

The npm `bin` entry is named `thinnercore`. You can use `npm link` to make
that command available on your PATH during local development. Node 22 or
newer is required for the Ink interface.

The frontend uses `.build/release/thinnercore`, falling back to
`.build/debug/thinnercore` if no release executable exists. Rebuild release
after changing Swift sources to update the frontend's engine.

In a terminal, scan results are rendered with Ink. `--json`, help, version,
and redirected output pass directly through to Swift. `--verbose` includes
file decisions. `NO_COLOR`, `TERM=dumb`, and `--color never` suppress colors.
Apply, restore, and recover retain the existing release refusals.

The native CLI also works directly without Node:

```sh
.build/release/thinnercore scan --json
```
