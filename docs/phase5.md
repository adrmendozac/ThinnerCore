# Phase 5 development interface

The CLI accepts `thinner PATH --apply [--json] [--exclude PATH ...]`.
It runs fresh scan policy, the host check, and bundle process inspection.
Incomplete process visibility refuses the app. Modification remains disabled
in both the CLI and public library while Phases 0, 4, and 6 are incomplete.
There is no environment variable or force flag that enables it.

`thinner restore APP --json` and `thinner recover PATH --json` reserve the
command/report interfaces; they do not yet restore or recover files.

Mutation JSON schema 1 reports per-app outcomes and run-level problems.
Exit codes are 0 for success/policy skips, 1 for refusal/clean rollback,
2 for invalid arguments, 3 for pending recovery, and 4 for failed recovery.
The greatest outcome code wins. A refusal for one app does not imply that
other apps in a future enabled batch have been rolled back. This build's
release refusal ensures apply returns at least 1.

Scan JSON schema 2 adds `pendingOperations`: operations, problems, and
searched directories. The snapshot reads UUID-named staging directories
beside the scan root and discovered apps, without locking or changing them.
It is not a global restore index. It can become stale during another run.
An unreadable, malformed, unsafe, or unsupported journal makes the scan
incomplete (exit 1); a readable pending operation alone does not. A mutation
request reports pending/failed operations with exit 3/4.

Filesystem permission diagnostics preserve the OS error and suggest checking
ownership, ACLs, flags, or Privacy & Security as appropriate. An EPERM error
alone does not prove App Management denial, identify the responsible process,
or establish that sudo will help. Phase 0 attribution research is still needed.

Before enabling mutation, finish the audited writer, shared journal discovery
and locking, identity validation, restart recovery, and restore tests; resolve
the Phase 0 permission, provenance/Gatekeeper, and compatibility gates.
