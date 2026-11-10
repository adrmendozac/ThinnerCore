# thinnercore CLI

The command is `thinnercore`. The terminal interface uses Ink and React;
the native Swift executable supplies the scan report and safety checks.

The prebuilt native executable does not require Xcode or Command Line Tools.
It removes architecture slices in-process and uses macOS's built-in `codesign`
for verification. Mutation is still gated in this development version.

Building from source and generating test fixtures require Apple's developer
tools. The test suite uses Swift Testing; use an Xcode toolchain if your
Command Line Tools cannot load its macros. The Ink interface additionally
requires Node.js and the dependencies below.

Build the native executable, install the frontend's dependencies from the
lockfile, then run the frontend from this checkout:

```sh
swift build -c release
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

In a terminal, scan results are rendered with Ink. While scanning, a single
live line shows a spinner and `Scanning <app> (12/140)`; the finished report
is then printed once into normal scrollback. The frontend gets progress by
setting `THINNERCORE_PROGRESS=json`, which makes the engine write one JSON line
per app to stderr (`{"progress":{"app":…,"index":…,"total":…}}`); stdout is
unchanged. `--json`, help, version,
and redirected output pass directly through to Swift. `--verbose` includes
file decisions and full technical diagnostics. Default scan reports show short skip
reasons; App details in the menu and `--verbose` show the original diagnostics,
including signature-verification output. JSON retains full details. `NO_COLOR`, `TERM=dumb`, and `--color never` suppress colors.
Apply, restore, and recover retain the existing release refusals.

The native CLI also works directly without Node:

```sh
.build/release/thinnercore scan --json
```

## Interactive menu

`npm start` (or `thinnercore`) with no arguments, in a terminal, opens a menu
instead of scanning straight away. `thinnercore menu PATH` opens it on another
folder. With any arguments, or when stdin or stdout is not a terminal, the
command runs once as before, so scripts are unaffected.

| Key | Item | What it does |
|---|---|---|
| 1 | Scan all applications | Dry-run report of `/Applications` |
| 2 | Select applications to thin… | Tick eligible apps, review, confirm, thin |
| 3 | Search for updated apps… | Apps this tool thinned (they have backups, not restored) that are universal again, usually after an update; offers to thin them again |
| 4 | Scan a folder or app… | Dry-run report of any path |
| 5 | App details… | One app's file-by-file decisions |
| 6 | Restore an app… | `restore`, after a y/N confirmation |
| 7 | Recover interrupted operations… | `recover`, after a y/N confirmation |
| 8 | Backups… | Retained backups by app; release one app's backups |
| 9 | Skip list… | View, add (from the scan or typed), remove entries |
| a | Allow list… | Same editor for the allow list: thin only the apps you choose |
| e | Export report as JSON… | Saves the scan report to a file |
| q | Exit | |

Arrows move, Enter selects, Esc goes back, Ctrl+C quits (or cancels a running
step). Long lists scroll and app pickers filter as you type. Results are
printed into scrollback; only the current question is redrawn.

Nothing changes without a confirmation: thinning lists every app with its
estimated savings and the backup cost and asks `[y/N]` (only `y` accepts);
releasing backups requires typing the app's name. The menu then calls the
engine with `--yes`. Every check still runs again in the engine, and the
release gate still refuses thinning, restore, and recovery in this build.

## Confirmation and `--yes`

`scan --apply` and `release --apply` ask before changing anything when stdin
and stderr are terminals: thinning shows the apps and estimated bytes and asks
`[y/N]`; releasing backups asks you to type the app's name. The prompt goes to
stderr, so `--json` output stays clean. `--yes` skips it, and so does running
without a terminal (the `--apply` flag is the consent there). No prompt is
shown while the release gate is closed, since nothing would change. The Ink
frontend passes `--apply` commands straight through so this prompt is used.

## Skip list

Apps on the skip list are never thinned, with the standing of `--exclude`.
The list is `~/Library/Application Support/thinnercore/skip-list.txt`: one
absolute path (excluded like `--exclude`) or bundle identifier (skipped
wherever the app is) per line; `#` starts a comment.

```sh
thinnercore skip                         # list entries (also: skip list --json)
thinnercore skip add com.example.App     # or a path to an app
thinnercore skip remove com.example.App
```

`scan --skip-list FILE` and `skip … --skip-list FILE` use another file. A list
that exists but cannot be read (a symlink, not a regular file, over 1 MiB, or
not UTF-8) refuses every app with `skipListUnreadable`, and `add`/`remove`
fail rather than rewrite it. Edit the list without sudo; runs under sudo read
the invoking user's list. Report skip codes: `skipListed`, `skipListUnreadable`.

## Allow list

When the allow list has any entry, only the apps it names can be thinned;
every other app is skipped with `notOnAllowList`. Empty or missing, it has
no effect. It only narrows what is thinned: a listed app still passes every
check, and the skip list and `--exclude` win over it. Use it to keep batch
runs, and later automatic re-thinning after updates, to apps you chose.

The list is `~/Library/Application Support/thinnercore/allow-list.txt`, in the
skip list's format: an absolute path allows that app, or every app below that
folder (matched by identity, so symlinks work); anything else is a bundle
identifier, allowed wherever the app is.

```sh
thinnercore allow                        # list entries (also: allow list --json)
thinnercore allow add com.example.App    # or an app or folder path
thinnercore allow remove com.example.App
```

`scan --allow-list FILE` and `allow … --allow-list FILE` use another file. An
unreadable list refuses every app with `allowListUnreadable`, never "every
app allowed". Scan reports carry an `allowList` object (path, number of
entries, any problem, and path entries that name nothing) whenever a list is
in force; the text report prints it. Edit it without sudo; runs under sudo
read the invoking user's list.

## Restore

```sh
.build/release/thinnercore restore "/path/to/Example.app"
.build/release/thinnercore restore "/path/to/Example.app" --json
```

Restore is wired to the library, but **the release gate remains closed**.
This build only reports the refusal and any pending-journal diagnostics;
it does not restore files. M2 thinning and M3 restore must ship together.
There is no force flag or environment variable to bypass the gate.

Once released, restore will validate the app identity and backup integrity,
refuse changed apps or files, and restore originals through the audited write
path. Quit every process using the bundle before restoring. Backups remain
in their staging directories after success; restore never consumes them.

If a restore stops part-way, retain all backups, resolve the reported cause,
and run the same command again. It recognizes files already restored by hash.
A verification failure requires manual attention: keep backups and temporary
files, and do not manually copy old backups into an updated app. Restoration
cannot reproduce the original `com.apple.provenance` xattr; restored files
carry the tool's tag. Every other required metadata value is checked.

| Exit | Meaning |
|---|---|
| 0 | Restored successfully, or nothing to restore |
| 1 | Refused |
| 2 | Invalid arguments |
| 3 | Recovery pending; resolve the cause before retrying |
| 4 | Recovery failed; manual attention required |

JSON uses mutation report schema 1. `command` is `restore`; each `apps` entry
has `path`, `outcome`, and `reason`. Successful restoration uses `committed`,
and a repeated completed restore uses `nothingToDo`. Other outcomes are
`refused`, `recoveryPending`, and `recoveryFailed`. The process exit status
is authoritative; it is not a separate JSON field.

Restore results include an additive optional `apps[].restore` object:

- `restored`: bundle-relative paths restored during this run.
- `alreadyOriginal`: bundle-relative paths already holding original bytes.
- `backupLocations`: staging directories whose backups were used.
- `notes`: additional recovery or metadata information.

Gated diagnostic reports omit that object because no restore was attempted.
Text output shows the same details and escapes terminal control characters.

Fixture integration tests cover restore outcomes through the reporting adapter,
including retries, changed apps, damaged backups, running processes, partial
restoration, and failed verification. Executable tests cover text/JSON parity,
exit codes, arguments, help, and read-only gate behavior with fixture journals.
Actual successful mutation through the public executable remains a release-gate
validation step; the tests add no public bypass.

M2/M3 activation requirements are tracked in [the mutation release checklist](mutation-release.md).
