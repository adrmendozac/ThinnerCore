# Phase 0 — research log

Evidence for the M2 feasibility gates in `PLAN.md`. Each entry records what
was measured, where, and what is still unknown. Nothing here was run against
real installed apps.

| Gate (PLAN.md Phase 0) | Status |
|---|---|
| Seal-class rule, end to end | **Passed**; automated as a repeatable check |
| App Management grant across rebuilds | **Signing half measured**; permission half needs a VM run |
| Backup storage | **Measured**; policy proposed, awaiting approval |
| Running-process detection | **Method chosen and tested**; root visibility needs a VM run |
| Gatekeeper and notarization | **Passed on macOS 27 for one notarized third-party app**; limits recorded |
| Rosetta signals | **Measured**; scanner fixed to read the macOS 27 key |
| Mixed-architecture and update policy | Open; a policy decision, not a measurement |

---

## Seal-class rule, end to end — passed (2026-09-29)

**Check:** `Tests/ThinnerCoreTests/SealRuleEndToEndTests.swift`, part of
`swift test`.

For each fixture app (`Signed.app`, `Nested.app`, `Electron.app`), every
universal file whose decision depends on the seal chain is thinned alone, in a
fresh throwaway copy, with `lipo -remove <each Intel arch>`. Then:

- `codesign --verify --deep --strict --all-architectures` on the copy must pass
  **exactly when** `BundleClassifier` called the file eligible;
- an eligible file must shrink to the predicted size (`size - savedBytes`);
- an eligible `MH_EXECUTE` file must still run and exit 0.

**Result:** codesign agreed with the classifier on all 22 files (Signed 4,
Nested 4, Electron 14): every `cdhash`-sealed file and main executable still
verifies; every `hash2`-sealed file (`addon.node`, `Plugin.bundle`,
Electron Framework's `Libraries/*.dylib`, `native.node`, Squirrel's `ShipIt`)
fails with "a sealed resource is missing or invalid". The check was confirmed
to be live by inverting its assertion: all 22 files then fail.

**Limits:** fixtures are signed ad hoc, without the hardened runtime, library
validation, or notarization; executables are run directly, not through
LaunchServices; dylibs are verified but not loaded. Launching thinned apps
with a Developer ID signature and hardened runtime, and Gatekeeper
(`spctl --assess`) on a notarized app, remain open.

---

## App Management grant across rebuilds — partial (2026-09-29)

PLAN.md asks: *does the grant follow the binary's signing identity across
rebuilds, or does an ad-hoc signed dev build get re-prompted every time?*

### Measured on the development Mac

macOS 27.0.1 (26A434), Apple Silicon. No code-signing identities installed
(`security find-identity -v -p codesigning` → 0), so no Developer ID or Apple
Development comparison was possible.

The `thinner` CLI as built by SwiftPM is signed ad hoc, and its designated
requirement is its own code hash:

```
Signature=adhoc   TeamIdentifier=not set
designated => cdhash H"f4e526a881ad03ab76fbde634fd1bc3bdbe384c5"
```

Rebuilding a throwaway copy of the package:

| Build | Identifier | CDHash |
|---|---|---|
| build 1 | `thinner-5555494487f5…` | `8585e5f5…` |
| rebuild, no source change | same | same |
| rebuild, one-line change | `thinner-555549442bab…` | `0c529701…` |
| change reverted | same as build 1 | same as build 1 |

- Builds are reproducible: identical sources give an identical identity.
- Any code change gives a new cdhash **and** a new identifier (derived from the
  binary's UUID; `55554944` is ASCII "UUID").
- The build location is part of the identity: the same sources gave
  `f4e526…` in the repository and `8585e5…` in the copy.

The probe (`scripts/phase0/build-probe.sh`) shows the same with clang's
linker signature: variant 1 builds twice to `ee7b15a3…`, variant 2 to
`622ab435…`, each with a `cdhash`-only designated requirement.

### What follows, to be confirmed in a VM

TCC stores a grant with the client's code requirement at the time of the
grant. Two cases, and the VM run must say which one macOS uses:

1. **The grant is attributed to the CLI itself.** An ad-hoc CLI's requirement
   names one exact cdhash, so every code change, and every build from another
   checkout path, would be a new client needing a new grant. A certificate
   signature with a fixed identifier gives a requirement of the form
   `identifier "…" and certificate …`, which should survive rebuilds.
2. **The grant is attributed to the responsible process**, typically the
   terminal app. Then CLI rebuilds do not matter at all, but the grant covers
   every program started from that terminal: a security consideration for the
   user documentation.

This gate cannot be closed by reasoning; PLAN.md forbids declaring Developer
ID a prerequisite without testing.

### VM procedure

Run in a disposable macOS VM (e.g. Apple's Virtualization framework via UTM
or Tart), one per supported macOS version (13, 14, 15, 26, 27), taking a
snapshot before starting. The probe writes into the target app, so never run
it outside such a VM.

**Setup**

1. Copy the repository into the VM. Build the fixtures
   (`scripts/make-fixtures.sh`) and probes:
   ```sh
   scripts/phase0/build-probe.sh 1 "" .build/phase0/v1
   scripts/phase0/build-probe.sh 2 "" .build/phase0/v2
   ```
2. Target app. First try a fixture: `ditto .build/fixtures/bundles/Signed.app /Applications/Signed.app`.
   If the first probe run below is `ALLOWED` with no prompt, fixtures are not
   protected by App Management; install any notarized app in the VM instead
   and use that as the target. Record which.
3. Optional stable identity: in Keychain Access, Certificate Assistant →
   Create a Certificate…, type *Code Signing*, name `Thinner Probe`. Then:
   ```sh
   scripts/phase0/build-probe.sh 1 "Thinner Probe" .build/phase0/s1
   scripts/phase0/build-probe.sh 2 "Thinner Probe" .build/phase0/s2
   ```

**Runs** (record every result in the table below)

| # | Action | Answers |
|---|---|---|
| 1 | From Terminal: `.build/phase0/v1/app-management-probe --yes-modify /Applications/<Target>.app` | Is the target protected? What prompt or notification appears, naming which app? |
| 2 | Open System Settings → Privacy & Security → App Management. | Which entry appeared: Terminal, the probe, or nothing? |
| 3 | Grant whatever is listed; repeat run 1. | Does the grant take effect? |
| 4 | Run the **v2** probe (new cdhash) the same way. | Does the grant survive a rebuild? |
| 5 | Repeat run 1 from a different terminal app (e.g. iTerm2). | Does attribution follow the terminal? |
| 6 | `sudo` the v1 probe. | Does root bypass App Management? (CLAUDE.md: do not assume it does.) |
| 7 | Run the v1 probe from a launchd agent or over `ssh` (no terminal app). | Who is attributed without a GUI terminal? |
| 8 | If step 3 set up a certificate: repeat runs 1–4 with the `s1`/`s2` probes. | Does a certificate identity survive rebuilds where ad hoc does not? |
| 9 | Make the target unwritable for the user (`chmod`), run the v1 probe. | Confirm EACCES (permissions) is distinguishable from EPERM (policy). |

Between runs, reset the permission with
`tccutil reset SystemPolicyAppBundles` (believed to be App Management's
service name; confirm it clears the System Settings entry) and remove the
target and re-copy it if a run left it modified.

**Record**

| macOS | Target (fixture / notarized) | Run | Launched from | Probe signature | Result + errno | Prompt / notification text | App Management entry |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Close the gate in PLAN.md when every supported macOS version has a row set,
or narrow the supported versions.

---

## Backup storage — measured (2026-10-03)

**Check:** `scripts/phase0/backup-storage.sh [SLICE_MIB]`. It works only on
disk images it creates and removes. macOS 27.0.1, Apple Silicon.

One universal file with 64 MiB of signed data per slice, taken through the
write path on an APFS image. Each row is the change in volume free space;
negative means space used.

| Step | Free space |
|---|---|
| `clonefile` backup into staging | 0.0 MiB |
| `lipo -remove` into staging | −64.5 MiB |
| `rename(2)` over the original | 0.0 MiB |
| **Net while the backup is retained** | **−64.5 MiB** |
| Release the backup | +128.5 MiB |
| Net after release | +64.0 MiB |

- **Thinning with a retained backup uses more space, not less.** The clone
  is free, but `lipo` writes the arm64 slice as new data at a new offset, and
  the backup keeps every original block alive. Usage grows by the thinned
  size of every file until its backup is released.
- **The Intel slice is reclaimed only on release.** The saving equals the
  removed slice, as the estimator predicts, but it appears only then.
- **Peak need** for an operation is the sum of the thinned sizes of its files,
  because every backup is kept until the user releases it.
- **Unsupported volumes.** `clonefile` fails with `ENOTSUP` (45) on HFS+ and
  ExFAT, and with `EXDEV` (18) across volumes.
- **One volume serves the usual locations.** `/Applications`,
  `/Library/Application Support`, `~/Library`, and `/private/tmp` share one
  device ID on the Data volume, so one staging area can clone from all of
  them.

Not adopted: a writer that kept the arm64 slice at its original offset could
share its blocks with the backup and avoid most of the cost. `lipo -remove`
moves the slice, and the Write-path decision in `CLAUDE.md` fixes `lipo` as
the writer.

**Proposed policy** (for approval; recorded in `PLAN.md`):

1. *Location.* Staging and backups live on the app's own volume, outside
   every bundle. On the Data volume one directory serves `/Applications` and
   `~/Applications`; elsewhere, a `.thinner` directory at the volume root.
2. *Retention.* Backups are kept until the user releases them for a named
   app. Release is an explicit command, never automatic, and says that
   afterwards only a reinstall restores the Intel slice.
3. *Reporting.* Report logical bytes removed and retained backup bytes side
   by side, so the user sees that space comes back on release.
4. *Free space.* Before an app, require free space of at least the sum of its
   thinned sizes plus a fixed reserve so the volume never fills. Proposed
   reserve: 2 GiB.
5. *No clone support.* `ENOTSUP` skips the app with a named reason; never fall
   back to a full copy.

---

## Running-process detection — method chosen (2026-10-03)

**Check:** `scripts/phase0/process-detection.sh`, using
`scripts/phase0/process-probe.c` and `scripts/phase0/holder.c`. It builds a
disposable bundle and keeps its files in use from four processes.

**Method.** For every process, read its executable path
(`proc_pidpath`), its file-backed memory regions
(`PROC_PIDREGIONPATHINFO2`), and its open files (`PROC_PIDLISTFDS` with
`PROC_PIDFDVNODEPATHINFO`). Match each file against the bundle both by path
and by device and inode number of every regular file in the bundle. Also
treat the mount points of `nullfs` mounts of the bundle as extra paths, which
is how App Translocation runs an app from another location.

**Results.** The probe found all four processes:

| Process | Found by |
|---|---|
| Executable inside the bundle | executable and mapped regions |
| Outside host that `dlopen`s a bundle dylib, like a hosted extension | mapped regions, by path |
| Outside process holding a bundle file open | open file, by path |
| Bundle executable run through a hard link outside the bundle | executable and mapped regions, by identity only |

- **Identity matching is required.** For hard-linked files the kernel
  reported one cached path for both running processes, including the one
  started from inside the bundle. Path matching alone missed both.
- **An unprivileged run cannot see everything.** Of 804 processes, the
  executable path was readable for 802. Regions and open files were readable
  for 545 and denied for 258, every one owned by another user, such as root
  or a system account. An unprivileged run therefore cannot rule out bundle
  code mapped into a root or system process.
- **`lsof` is no substitute.** It found the same processes but reports one
  name per vnode, and is a text interface to parse.

**Replacing a mapped dylib under a live process.** A process `dlopen`ed a
universal dylib with 32 MiB of signed constant data, the file was replaced,
and then the process read every page of that data.

| Replacement | Outcome |
|---|---|
| `rename(2)` of a thinned copy over it | Survived, read correct data |
| Overwritten in place with the thinned file | Survived, read correct data |
| Truncated in place to 0 bytes | Survived, read correct data |

`rename(2)` is safe by construction: the old inode stays alive while it is
mapped, and the backup holds it too. The `SIGBUS` that `CLAUDE.md` cites for
in-place replacement was **not reproduced** here. The pages may simply have
stayed resident after the copy wrote them; evicting them needs `purge`, which
needs root. Main executables, hardened runtime, and memory pressure were not
tested. The hard rule is unchanged: it also covers helpers that launch during
an operation and states nobody has tested.

**Proposed policy.** Use this method in Phase 4, before preflight and again
immediately before each swap. Decide visibility together with the App
Management VM run. If `--apply` needs root anyway, detection runs as root.
If it does not, an unprivileged run must refuse any app whose code could be
loaded by another user's process, unless root visibility is otherwise
established.

**VM runs to add** (same VM as App Management):

- `sudo` the probe and record whether every process's regions and open files
  become readable.
- Download and open a quarantined app without moving it, so that it is
  translocated. Run the probe on its original path, and record the `nullfs`
  mount and whether the matches name the translocated paths.

---

## Gatekeeper and notarization — passed for one app (2026-10-03)

The development Mac has no code-signing identities, so it cannot produce a
Developer ID signed, notarized fixture. Instead, the gate was measured on a
notarized third-party app the owner downloaded fresh for this purpose, never
installed or opened. See "Measured with a downloaded notarized app" below.

**Measured anyway: `com.apple.provenance` cannot be reproduced.** macOS tags
every file a process creates with the provenance of its responsible app.
Measured with a copy of one installed app's executable in a scratch
directory; the installed app was only read.

- `cp`, `cp -p`, `ditto`, `clonefile`, and `copyfile` with
  `COPYFILE_XATTR` all gave the copy this session's tag, not the source's.
- Overwriting a clone in place, and renaming a new file over a clone, did the
  same.
- `xattr -d` and `xattr -w` on the tag returned success but changed nothing.
- Of 29 installed apps checked, 10 carried a tag on their main executable and
  19 had none.

Consequences for the writer:

1. Every thinned file carries the tool's tag, including files whose original
   had none. A strict metadata read-back therefore fails on every file.
   *Resolved 2026-10-03:* the read-back exempts `com.apple.provenance` only
   (`MetadataCopier.unreproducibleXattrs`; decision in `CLAUDE.md`).
2. The `clonefile` backup also carries the tool's tag, so restore cannot bring
   back the original tag either.
3. Whether a changed tag matters to Gatekeeper, App Management, or launch is
   exactly what this gate must measure.

**Procedure** (disposable VM, Developer ID required):

1. Re-sign the `Signed.app` fixture with a Developer ID Application identity
   and the hardened runtime, then notarize and staple it with `notarytool`.
2. Serve it to the VM so it arrives quarantined, for example from a local web
   server opened in Safari. Move it to `/Applications`, launch it once, and
   quit.
3. Run `scripts/phase0/gatekeeper-check.sh --yes-modify
   /Applications/Signed.app Contents/MacOS/Signed`, which thins in place the
   way the writer would and reports codesign, `spctl`, and provenance before
   and after.
4. Launch it with `open`, then record any dialog and the `syspolicyd` log.
   Repeat after a reboot, since some assessments are cached.
5. Repeat with a thinned framework, and with an app whose files had no tag.

The script's mechanics were smoke-tested on a scratch copy of the ad-hoc
fixture. Gatekeeper rejected it before and after, as expected for an
unnotarized app.

---

## Rosetta signals — measured (2026-10-03)

Measured on the development Mac (macOS 27.0.1, build 26A434) after the owner
installed macOS Rosetta: `arch -x86_64 /usr/bin/true` succeeds and
`oah/libRosettaRuntime` exists. Repeatable with
`scripts/phase0/rosetta-check.sh`, which builds universal, ad-hoc signed probe
apps (`arch-probe.c`) that record the slice they run as and
`sysctl.proc_translated`. Only those probe apps were launched or modified.

### Signal 3: `LSArchitecturePriority` listing x86_64 first

Launched through LaunchServices (`open -n`), three runs each, same results
every time:

| App | Slices | `codesign --verify --deep --strict --all-architectures` | Ran as |
|---|---|---|---|
| Probe, no priority key | x86_64, arm64 | valid | arm64, not translated |
| Priority, `(x86_64, arm64)` | x86_64, arm64 | valid | **x86_64, translated** |
| Priority, thinned as the writer would | arm64 | valid | arm64, not translated |

- The thinned copy launches, which was the question the gate asked.
- **CLAUDE.md is wrong about the universal app.** Its Known behaviors note
  says entries naming the removed slice "simply stop matching". In fact,
  macOS honors an x86_64-first priority on Apple Silicon and runs the app
  under Rosetta, so thinning moves it from Rosetta to native. A vendor that
  orders Intel first is presumably relying on Rosetta.
- `open -W` fails with "kevent() failed: No such process" when the probe
  exits before open starts waiting; the script polls the probe's log instead.

#### arm64-first and unmatched priorities (2026-10-03)

`scripts/phase0/rosetta-check.sh priority <DIR>`, one run, same method:

| App | Slices | codesign | Ran as |
|---|---|---|---|
| PriorityArm, `(arm64, x86_64)` | x86_64, arm64 | valid | arm64, not translated |
| PriorityArm, thinned | arm64 | valid | arm64, not translated |
| PriorityE, `(arm64e, x86_64)` | x86_64, arm64 | valid | **x86_64, translated** |
| PriorityE, thinned | arm64 | valid | arm64, not translated |

- **arm64 first is compatible with thinning,** as CLAUDE.md said: the
  universal app already runs arm64, and the thinned copy runs the same way.
- **LaunchServices picks the first listed architecture the executable
  contains, not the first listed.** `arm64e` names no slice here, so
  `x86_64` wins and the universal app runs under Rosetta. The scanner
  checked only the first entry, so it would have thinned this app and
  forced it native. It now resolves the list against the main executable's
  slices and skips unless the result is the ordinary `arm64` slice. A list
  naming none of the slices is unmeasured, so it skips too. Regression test:
  `priorityIsResolvedAgainstTheExecutablesSlices`.
- Not measured: an executable that has an `arm64e` slice listed first, and
  case variants of the names (the scanner matches exactly, so a variant
  skips).

### Signal 2: the "Open using Rosetta" flag

The owner ticked Open using Rosetta on `Probe.app` in Finder's Get Info.
Diffing the preferences file against a copy saved beforehand:

```
"Architectures(arm64)" => {
  "dev.thinner.probe.rosetta" => [
    0 => {length = 1040, bytes = 0x626f6f6b…}   // bookmark data
    1 => "x86_64"
  ]
}
```

- **The key is `Architectures(arm64)`, not `LSArchitecturesForX86_64`.** No
  `LSArchitecturesForX86_64` key exists in the file. The `(arm64)` suffix
  presumably names the host architecture; unverified.
- Each entry is keyed by bundle ID and holds an array: bookmark data, then
  the architecture to run. The bookmark resolves to the exact copy that was
  flagged (`…/rosetta/Probe.app`, not stale). **The flag is per copy:** a
  `ditto` copy of the flagged app, same bundle ID, ran as arm64 untranslated
  while the original ran translated (two runs each). Matching by bundle ID
  alone, as the scanner does, therefore over-skips other copies, which is the
  safe direction.
- The relaunched probe ran as x86_64, translated: the flag takes effect
  through `open`.
- **The scanner misses the flag.** `thinner scan` on the probe folder
  reported "0 apps set to Open using Rosetta" and `Probe.app` as eligible.
  `RosettaFlags` reads only `LSArchitecturesForX86_64`; a missing key reads
  as "no flags", not as inconclusive. A Rosetta flag has the standing of a
  user exclusion, so this must be fixed before M2. The array value itself
  would already be recognized as flagged, because it contains `"x86_64"`.
- **Fixed 2026-10-03.** `RosettaFlags` now reads `Architectures(…)` keys and
  the legacy name, and combines them. Regression test
  `macOS27RosettaFlagIsRead` uses the observed shape. Rescanned, the probe
  folder reports "1 app set to Open using Rosetta" and skips `Probe.app` and
  its copy.

**Still open:** which macOS versions use which key (13–26 need a VM or
another Mac); and whether unticking the box removes the entry or leaves
another value.

### Measured with a downloaded notarized app (2026-10-03)

macOS 27.0.1 (26A434), development Mac. Subject: Rectangle 2.0.2
(`com.knollsoft.Rectangle`), downloaded by the owner in Chrome as
`Rectangle2.0.2.dmg` and dragged out to `~/Downloads/Rectangle.app`, never
opened. Neither it nor the disk image was modified. No Rectangle data existed
in `~/Library` beforehand.

Read-only checks on the download:

- `spctl --assess --type execute`: accepted, `source=Notarized Developer ID`,
  team `XSYZ3E4B7D`; `stapler validate` succeeds; hardened runtime.
- Six universal Mach-O files: the main executable and, in
  `Sparkle.framework/Versions/B`, `Sparkle`, `Autoupdate`, `Updater.app`, and
  the `Downloader` and `Installer` XPC services.
- `thinner scan` on the mounted image skips it as a protected location (read
  only). On a scratch copy, all six files are eligible, 3.1 MB estimated.

Procedure: two `ditto` copies into the scratchpad, `thin/` and `control/`.
`gatekeeper-check.sh` thinned all six files in `thin/` the way the writer
does (`lipo -remove x86_64` into staging, `rename(2)` over). The thinned copy
was launched first, so no earlier approval of the control could influence it.

| Copy | Slices | `codesign --verify --deep --strict --all-architectures` | `spctl` | `syspolicy_check distribution` | First launch (`open`) | Ran as |
|---|---|---|---|---|---|---|
| thin | arm64 only, all six | valid | accepted, Notarized Developer ID | passed | normal "downloaded from the Internet" prompt; Open; worked normally | ARM64, thinned `Sparkle` mapped |
| control | universal | valid | accepted, Notarized Developer ID | (not run) | same prompt; Open; worked normally | ARM64 |

- Size on disk: 10,092 KB → 7,036 KB.
- Quarantine went from `0181` to `01c1` on Open in both copies (the
  user-approved bit), so Gatekeeper recorded an ordinary approval.
- Thinning did not change Gatekeeper's verdict, the prompt, or the launch.

**Limits:**

- One app, one macOS version, on the development Mac rather than a clean VM.
- The copies were made by this session, so both carry this session's
  `com.apple.provenance` tag (`…6B8A7B01615A5C06`), not the download's
  (`…C515A9569627793D`). The control therefore matches the thinned copy in
  provenance, and the effect of a changed tag alone is not isolated. It was
  accepted in both cases.
- `ditto` kept the quarantine flags and event ID but dropped the agent name
  and timestamp (`0181;00000000;;…` versus the original `0181;6ac1bbc2;Chrome;…`).
- Launched from a scratch directory, not `/Applications`, and not
  translocated: flag `0x0100` (do not translocate) was set when the app was
  dragged out of the image.
- Sparkle's update path, which runs the thinned `Autoupdate` and XPC
  services, was not exercised.

**Cleanup:** both copies deleted and unregistered from LaunchServices, the
image detached, and `com.knollsoft.Rectangle` preferences (created by these
launches) deleted. The owner's download and disk image were left as they
were.

### Quarantine through `copyfile` (2026-10-03)

Read-only on the Rectangle download: `fcopyfile` with `COPYFILE_XATTR` from
its main executable to a scratch file rewrote the timestamp field of
`com.apple.quarantine` (`0181;6ac1bbc2;Chrome;…` became `0181;6ac1d6d…`),
and gave the copy this session's `com.apple.provenance`. Writing the
quarantine value back with `xattr -w` (`fsetxattr`) reproduced it byte for
byte; writing provenance changed nothing, as before. With both strict
comparisons, the writer would have refused every file of any downloaded app.
`MetadataCopier` now sets every xattr again explicitly and exempts only
provenance. Rerun against the download, the copy matched with quarantine
equal and provenance differing. Regression tests: `copiesQuarantineExactly`,
`provenanceIsTheOnlyExemptXattr`.

## AppLock between root and a user — passed (2026-10-03)

**Check:** `sudo scripts/phase0/lock-contention.sh <DIR>`, run by the owner
in a terminal, since it needs the sudo password. It takes the lock the way
`AppLock` does, `flock(2)` with `LOCK_EX | LOCK_NB` on the bundle directory
opened read-only, using two empty `.app` directories it creates and deletes.
*Amended 2026-10-03:* the script now keeps its work directory root-owned,
gives each process its own marker directory, and refuses a `DIR` that the
user, or anyone but root, can write unless it is sticky (use
`/private/tmp`). The first version gave the user the work directory, so the
user could swap `RootOwned.app` for a symlink before root ran `chmod 755` on
it. Rerun with the hardened script against `/private/tmp` on the same
macOS build: all four cases passed again, with the same results as below,
and the work directory was removed afterwards.

**Results** on macOS 27.0.1 (26A434). Each case checks that the contender
sees the lock as busy while it is held and acquires it once it is released:

| App directory | Holder | Contender | Result |
|---|---|---|---|
| Owned by the user | user | root | busy, then acquired |
| Owned by the user | root | user | busy, then acquired |
| Owned by root, mode 755 (user can only read) | user | root | busy, then acquired |
| Owned by root, mode 755 (user can only read) | root | user | busy, then acquired |

Root gets no exemption from `flock`, and a user who can only read a
root-owned app, as in `/Applications`, can still take and hold its lock. A
root process and a user process never change the same app at once.

**Limits.** It checks the locking primitive with `perl`, not the `thinner`
binary itself. It also doesn't cover locks across machines (network
volumes), which the backup rules already exclude because staging must be
on the same APFS volume as the app.
