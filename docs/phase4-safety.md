# Phase 4 safety regression fixes (2026-10-03)

The writer now rechecks the original SHA-256 and file identity immediately
before replacement, after process inspection. Copying metadata uses open
file descriptors and compares owner, group, mode, flags, the extended ACL,
and every extended attribute except `com.apple.provenance`, which macOS sets
from the writing process and cannot be reproduced (the exemption recorded
in `CLAUDE.md`, "Write path"). Any other mismatch refuses the replacement.

Journal directory-open/flush errors propagate to the caller. Writer flush
errors trigger recovery through the retained backup; restore flush errors
leave a pending outcome. A retry after the last restore swap re-flushes the
parent directories and verifies the app even when every file already holds
its original bytes. No failed flush is reported as a successful commit.

Restore and rollback refuse incomplete process visibility before mutation
and before each swap. Apply resolves unfinished operations under the same
app lock, after checking user policy and before creating another staging
area. A pending or failed recovery stops apply; a clean rollback is reported
without immediately re-thinning the app.

`Phase4SafetyTests` launches a separate XCTest process and exits it abruptly
at 51 writer, restore, and rollback boundaries. Per-file boundaries cover all
three eligible fixture files, including exits between rename and journal
update. The parent reopens the journals, recovers, verifies code signatures,
checks retained backups, and restores the original hashes. Additional tests
cover same-identity byte changes, incomplete process visibility, unresolved
pending operations, and injected directory-flush failures.

`MetadataDurabilityTests` covers copying and checking actual ACLs and binary
xattrs, detecting their removal, and propagating journal directory-flush
errors. These are process-interruption tests, not physical power-loss tests.
Automated tests use generated fixtures only.

The CLI release gate remains closed. Phase 0 permission attribution,
provenance/Gatekeeper limits, supported OS coverage, and the other recorded
release requirements still apply.

## Phase 4 completion (2026-10-04)

**Mixed-privilege runs are refused.** A staging directory belongs to the user
whose run made it. Apply, recover, restore, and release refuse a set another
user's run made, before writing anything to it, and name the command to rerun
with or without `sudo` (`StagingOwner`). A directory both could write was
rejected: a root run would then trust files an unprivileged user can change.

**Releasing backups.** `ReleaseOperation` is the one explicit way backups are
deleted, gated like apply and restore. It holds the app lock and each set's
lock, refuses while any thinning, recovery, or restore is unfinished or a
record cannot be read, and checks every set before deleting any. Each set is
renamed to `.thinner-released-<UUID>`, and that rename is flushed, before it
is deleted; if the flush fails the set is renamed back. A deletion cut short
is finished by the next release. The result warns that afterwards only a
reinstall brings back the Intel slice.

**Retained bytes.** Scan JSON schema 3 adds `backups`: each backup set with
its retained bytes and the bytes thinning removed that are still removed,
plus totals. Both are logical sizes.

**Tests.** `PreflightFailureTests` covers an Intel or translated host, low
disk space, permission denial after earlier files were replaced, mixed
privilege levels, a dry run while another process holds the app, and the
retained-bytes report. `ReleaseTests` covers release.
