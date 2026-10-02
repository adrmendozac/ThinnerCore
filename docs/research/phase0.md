# Phase 0 — research log

Evidence for the M2 feasibility gates in `PLAN.md`. Each entry records what
was measured, where, and what is still unknown. Nothing here was run against
real installed apps.

| Gate (PLAN.md Phase 0) | Status |
|---|---|
| Seal-class rule, end to end | **Passed**; automated as a repeatable check |
| App Management grant across rebuilds | **Signing half measured**; permission half needs a VM run |

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
