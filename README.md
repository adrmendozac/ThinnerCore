# thinnercore

Most Mac apps ship as Universal Binaries: every executable inside them carries
two copies of its code, one for Apple Silicon and one for Intel. On an Apple
Silicon Mac the Intel copy is never used. It just takes up disk space.

thinnercore is a command-line tool that finds that unused Intel code and
tells you how much space it takes. Removing it safely, with backups and a
way to undo, is built and tested but still switched off while its last
safety checks are finished (see [Status](#status)).

It is free and open source under the MIT license.

## Install

You need an Apple Silicon Mac running macOS 13 or later, and
[Homebrew](https://brew.sh).

```sh
brew install adrmendozac/tap/thinnercore
```

Homebrew builds thinnercore from source on your Mac, which takes about a
minute and needs Xcode or the Command Line Tools.

## Use

Scan your Applications folder:

```sh
thinnercore scan
```

A scan is always a dry run. It only reads, and nothing on disk changes. For
each app it reports how many universal files it found, how many could be
thinned, the estimated space, and the reason for anything it would leave
alone.

A few more things you can do:

```sh
thinnercore scan ~/Applications        # scan another folder, or a single app
thinnercore scan --verbose             # show the decision for every file
thinnercore scan --json                # machine-readable report
thinnercore scan --exclude /Applications/Xcode.app

thinnercore skip add com.example.App   # never thin this app
thinnercore allow add com.example.App  # thin only the apps you list
```

Run `thinnercore --help` for everything, or read [docs/cli.md](docs/cli.md).

## Features

**Available today**

- **Whole-app scan.** It looks at every executable in an app, including
  frameworks, helper apps, plugins and libraries, not only the main one.
- **Honest estimates.** Sizes are calculated from the actual Intel code in
  each file, and reported as estimates rather than promised free space.
- **Clear reasons.** Every skipped app and file comes with a plain
  explanation, for example that an app is set to open using Rosetta, contains
  Intel-only components, or has a signature that does not verify.
- **Skip list.** Apps you list are never touched, on every run.
- **Allow list.** If you list apps here, only those can ever be thinned.
- **Careful defaults.** Mac App Store apps and apps with system extensions,
  such as VPNs and security tools, are left alone by default. Intel-only
  audio plugins are flagged, since the apps that host them need Rosetta.
- **JSON output** with a stable format, for scripts.

**Built and tested, switched off until release**

- **Thinning that keeps apps signed.** Only files whose code signatures
  survive are changed. Apps are never re-signed, so they stay the developer's
  original, notarized apps.
- **Backups of every changed file**, kept until you choose to release them.
- **Restore.** One command puts an app's original files back.
- **Verification and automatic rollback.** Each app is checked with Apple's
  own signature verification before and after. If anything fails, the change
  is undone.
- **Crash recovery.** Every step is recorded first, so an interrupted run can
  be finished or undone.
- **Never touches a running app** or anything in a protected system location.

## Good to know

- An app update brings the Intel code back. Run thinnercore again afterwards.
- A thinned app can no longer run under Rosetta. Apps you run that way, for
  example to load Intel-only plugins, belong on the skip list. Apps already
  set to "Open using Rosetta" are skipped automatically.
- Space is reclaimed only when an app's backups are released, and macOS may
  take a while to show it as free.

## Status

Version 0.1.0 is the read-only scan. Thinning, restore, recovery and backup
release are implemented and covered by more than 300 tests on generated test
apps, but they stay off until research on macOS permissions and older macOS
versions is complete. Until then, `--apply`, `restore`, `recover` and
`release --apply` report that modification is unavailable and change nothing.

## Build from source

```sh
git clone https://github.com/adrmendozac/ThinnerCore.git
cd ThinnerCore
swift build -c release
.build/release/thinnercore scan
```

Run the tests with `swift test`. They only ever use generated test apps,
never your installed ones.

The repository also includes an interactive terminal menu. It needs Node 22
or later:

```sh
npm ci
npm start
```

## Open source

thinnercore is open source under the [MIT license](LICENSE). You can read
exactly what it does, build it yourself, and use or change it freely. Bug
reports and pull requests are welcome on
[GitHub](https://github.com/adrmendozac/ThinnerCore/issues).
