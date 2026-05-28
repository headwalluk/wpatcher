# Project Tracker

**Version:** 0.0.0 (pre-alpha — design phase)
**Last Updated:** 2026-05-28
**Current Phase:** M0 — Designing `wpatch-ng` (remote-repo architecture). Nothing built yet.
**Overall Progress:** ~5% (decisions locked, architecture drafting)

---

## Overview

Two tools live in this repo:

1. **`wpatch.sh`** — the current, stable Bash tool. Patches plugins from a single local (rsync-synced) patches directory, version-pinned, one patch per plugin+version, full-restore unpatch. **In production on 300+ sites across 10+ servers.** Treat as reliable — do not refactor without cause.
2. **`wpatch-ng`** — the new tool being designed here. Pulls patches from **multiple remote repositories** with per-subscriber **priorities**, stacks all applicable patches for a plugin+version highest-priority-first, tolerates lower-priority patches failing to apply (reported as warnings, not errors), and records **per-site provenance** of what was applied.

`wpatch.sh` stays untouched and keeps running the fleet during `wpatch-ng` development; sites migrate over when the new tool is proven.

**Language:** Go (single static binary, easy to push to ~10 servers, robust JSON/HTTP/state). _May reconsider PHP or Bash mid-build if Go proves a poor fit._

**Detailed design:** [`10-wpatch-ng-architecture.md`](10-wpatch-ng-architecture.md)

---

## Locked decisions (2026-05-28)

- **New codebase** `wpatch-ng`, not an in-place evolution of `wpatch.sh`.
- **Go** as the implementation language (revisit if it fights us).
- **Pluggable transport** — support both git repos and HTTP static-index repos behind one interface.
- **State lives in the live PHP**, as a rich marker carrying a JSON provenance snippet — NOT a file under `wp-content` (probe/attack surface) and NOT solely in `WORK_DIR` (can't detect a WP-admin plugin update that should reset state). The marker self-invalidates when the plugin is updated, which is the desired behaviour.
- **Marker = single ledger block** in the plugin's main entry PHP file (not per-hunk markers); patches stay plain diffs and `wpatch-ng` manages the block.
- **Revert = full-unpatch only in v1** (restore pristine + drop ledger); remove-one-patch = rebuild from pristine with it deselected. Selective reverse-patch deferred.
- **Pristine = local snapshots in `WORK_DIR`**; wordpress.org re-fetch is a later fallback, not v1.
- **Themes deferred**; when revisited, **parent/non-child themes only** (child-theme slugs like `astra-child` collide across the fleet and can't be safely version-pinned).

Remaining open (low-stakes): subscriber config format (defaulting TOML); deterministic rule for which file holds the ledger in edge-case plugins (resolve in M2). See [`10-wpatch-ng-architecture.md`](10-wpatch-ng-architecture.md) §8.

---

## Active TODO Items

### In progress
- [ ] **M0 — Architecture design.** [`10-wpatch-ng-architecture.md`](10-wpatch-ng-architecture.md) drafted; core decisions locked. Remaining before M0 exit: freeze the exact marker JSON schema + manifest JSON schema as versioned `schema: 1` definitions, and pick the config format (defaulting TOML).

### Next session (queued)
- [ ] Freeze marker + manifest schemas (M0 exit criteria), then stand up the Go scaffold (M1).

### Done
- [x] Drafted the architecture doc and locked marker placement, revert model, pristine source, and themes scope (2026-05-28).
- [x] Chose architecture direction: new `wpatch-ng`, Go, pluggable transport, state-in-PHP (2026-05-28).
- [x] Slimmed README + added audience docs (shipped on `main`, commit `3097a44`).

---

## Milestones

### M0 — Architecture & schema design 🔧 (in progress)
Design only, no code. Exit criteria: confirmed revert model, frozen **marker/state schema**, frozen **repo manifest schema**, defined **transport interface** and **subscriber config** shape. Captured in [`10-wpatch-ng-architecture.md`](10-wpatch-ng-architecture.md).

### M1 — Go scaffold + single-source parity
Prove the new codebase can do what `wpatch.sh` already does, before adding new capability.
- Go project skeleton, build/release setup.
- Subscriber config loader (list of repos + priorities + work dir).
- wp-cli discovery of active plugins + versions.
- Local pristine snapshot/backup (WORK_DIR cache).
- Apply / unpatch a single patch from one local source. Behaviour parity with `wpatch.sh`.

### M2 — Rich PHP marker + state model
- Define and implement the JSON-in-comment provenance marker (see architecture doc).
- Write on successful apply; parse to determine current state; idempotent re-runs.
- Replace the boolean `// START : wpatcher` detection with structured state.
- Verify self-invalidation: simulate a WP-admin plugin update, confirm state resets cleanly.

### M3 — Pluggable transport + manifest
- `Source` interface; HTTP static-index implementation; git implementation.
- Repo manifest schema (plugin slug + version → patch entries with id, url, checksum, description).
- Local materialisation/cache of remote repos; checksum verification.

### M4 — Multi-repo priority apply + warning model
- Subscribe to N repos with client-assigned priorities.
- Gather all applicable patches for each plugin+version; apply highest-priority-first onto the pristine tree.
- Lower-priority patch failing to apply (line drift) → **warning**, continue; record per-patch outcome.
- Each successful patch recorded in the marker ledger.

### M5 — Revert
- Full unpatch (restore pristine snapshot) — the v1 baseline.
- Selective per-patch revert via reverse-patching — stretch goal, may be infeasible with stacking.

### M6 — Fleet integration
- Drop-in for the overnight maintenance job; maintenance-mode flag; root/`--allow-root` behaviour.
- Machine-readable run summary (what patched, what warned, what skipped) for fleet logging.

### M7 — Documentation
- End-user docs in `docs/` (subscribing to repos, priorities, migrating from `wpatch.sh`).
- **Repo-author guide**: how to publish a patch repository + the manifest format.

---

## Technical Debt

- **`wpatch.sh` dead code** — unconditional `exit 0` in `update_from_upstream` (`wpatch.sh:616`) leaves code after it unreachable. Left in deliberately (diagnostic remnant); revisit only if `wpatch.sh` is ever refactored. Do not touch during `wpatch-ng` work.
- **Themes unsupported** in `wpatch.sh` (`IS_THEMES_SUPPORT_ENABLAED=0`). Decide whether `wpatch-ng` supports themes from the start (same component model) or defers.
- **Migration**: sites already patched by `wpatch.sh` carry plain `// START : wpatcher` markers. `wpatch-ng` needs to recognise these (treat as "patched by legacy tool, provenance unknown") so it doesn't double-apply.

---

## Notes for Development

- Priorities are a **subscriber-side** choice (the hoster ranks the repos they trust), NOT declared inside a repo's manifest. A repo just publishes patches; the consumer decides where it sits.
- WORK_DIR holds **regenerable** byte caches (pristine snapshots, built packages, materialised repos). The PHP marker is the **authoritative** record of what's applied. The two are complementary, not redundant.
- Keep `wpatch-ng` runnable unattended (cron, root) and quiet-by-default with a verbose mode, matching how the fleet already calls `wpatch.sh`.
