# Phase 4 safety regression fixes (2026-10-03)

The writer now rechecks the original SHA-256 and file identity immediately
before replacement, after process inspection. Copying metadata uses open
file descriptors and compares owner, group, mode, flags, the extended ACL,
and every extended attribute. No provenance exemption is made: a mismatch
refuses the replacement.

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
