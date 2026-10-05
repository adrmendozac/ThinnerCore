# Phase 5 development interface

The CLI accepts `thinnercore PATH --apply [--json] [--exclude PATH ...]`.
It runs fresh scan policy, the host check, and bundle process inspection.
Incomplete process visibility refuses the app. Modification remains disabled
in both the CLI and public library while Phases 0, 4, and 6 are incomplete.
There is no environment variable or force flag that enables it.

An internal, fixture-tested batch coordinator is ready for the later release
gate: it reuses the audited per-app writer, preserves user exclusions, blocks
new writes when a pending or unreadable journal is found, and maps commit,
rollback, and recovery outcomes to the stable report codes. A writer error is
judged by what is on disk: an unfinished or unreadable journal for that app
means recovery pending and stops the batch; no journal means nothing was
written, so it is a refusal and the batch continues. Invalid or unreadable app
metadata is a refusal, while an explicit policy skip remains a successful
skip. The coordinator has no public entry point; the CLI still cannot modify
apps.

`thinnercore restore APP --json` and `thinnercore recover PATH --json` reserve the
command/report interfaces; they do not yet restore or recover files.

Mutation JSON schema 1 reports per-app outcomes and run-level problems.
Exit codes are 0 for success/policy skips, 1 for refusal/clean rollback,
2 for invalid arguments, 3 for pending recovery, and 4 for failed recovery.
The greatest outcome code wins. A refusal for one app does not imply that
other apps in a future enabled batch have been rolled back. This build's
release refusal ensures apply returns at least 1.

Scan JSON schema 2 adds `pendingOperations`: operations, problems, and
searched directories. Schema 3 adds `backups`: retained backup bytes beside
the bytes thinning removed, per backup set and in total. The snapshot reads
UUID-named staging directories beside the scan root and discovered apps,
without locking or changing them.
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
