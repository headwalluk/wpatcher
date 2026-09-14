# Project Tracker

**Version:** 0.0.0 (pre-alpha — design phase)
**Last Updated:** 2026-09-14
**Current Phase:** M0 — Designing `wpatch-ng` (remote-repo architecture). Nothing built yet.
**Overall Progress:** ~5% (decisions locked, architecture drafting)

---

## Overview

Two tools live in this repo:

1. **`wpatch.sh`** — the current, stable Bash tool. Patches plugins from a single local (rsync-synced) patches directory, version-pinned, one patch per plugin+version, full-restore unpatch. **In production on 300+ sites across 10+ servers.** Treat as reliable — do not refactor without cause.
2. **`wpatch-ng`** — the new tool being designed here. Pulls patches from **multiple remote repositories** with per-subscriber **priorities**, stacks all applicable patches for a plugin+version highest-priority-first, tolerates lower-priority patches failing to apply (reported as warnings, not errors), and records **per-site provenance** of what was applied.

`wpatch.sh` stays untouched and keeps running the fleet during `wpatch-ng` development; sites migrate over when the new tool is proven.

`wpatch.sh` work is tracked separately under the **S-series** milestones below; `wpatch-ng` work stays on the **M-series**. The two do not block each other.

**Language:** Go (single static binary, easy to push to ~10 servers, robust JSON/HTTP/state). _May reconsider PHP or Bash mid-build if Go proves a poor fit._

**Detailed design:** [`10-wpatch-ng-architecture.md`](10-wpatch-ng-architecture.md)

**Snagging list:** [`20-snagging-list.md`](20-snagging-list.md) — small known rough edges we've consciously left, with the reasoning. Correctness-affecting items go in Technical Debt below instead.

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
- [x] Fixed the `-c` single-component filter, broken since v0.1.0 (2026-07-25).
- [x] **S1** — `list` command + `--format=csv`, shipped as `wpatch.sh` 1.4.0 (2026-07-25, commit `a58addc`).
- [x] **S3** — `-V | --version` flag, shipped as `wpatch.sh` 1.5.0 (2026-09-14).

---

## Milestones — stable track (`wpatch.sh`)

### S1 — Repository visibility (`list` command) ✅ (complete — 2026-07-25, commit `a58addc`)
Read-only insight into what the local repository is holding. No change to patch/unpatch/backup behaviour. Exit criteria: `list` works with no site and no `PATCHES_DIR`, counts reconcile against the filesystem, and docs/changelog are updated.

- [x] Fix `-c` component filter (`wpatch.sh:811` compared against unassigned `PLUGIN_SLUG`)
- [x] Register `list` in `VALID_COMMANDS`; add `OUTPUT_FORMAT` + `VALID_OUTPUT_FORMATS` globals
- [x] Add `IS_COMPONENT_TYPE_EXPLICIT` so `list` can iterate both types unless `-t` is given
- [x] Parse `--format=csv` / `--format csv`; validate against `VALID_OUTPUT_FORMATS`
- [x] Route the two banner lines through `show_banner_line()` (stderr when csv)
- [x] Implement `list_repository_components()` + `format_bytes_as_human()`
- [x] Dispatch `list` above the `PATCHES_DIR` check and `fail_if_bad_wp_root`
- [x] Exit `1` when `-c <slug>` matches nothing; exit `0` on a genuinely empty store
- [x] Usage text, `docs/commands-reference.md`, `docs/fleet-operations.md`, `README.md`
- [x] Bump to `1.4.0` in the `# Version:` header + `CHANGELOG.md`
- [x] Verify against the real 136-backup work dir (136/136 rows, 64/64 slugs reconciled)
- [x] Add `--format=json` (single document with totals + components; booleans not 1/0)
- [x] Validate package filenames against `[A-Za-z0-9._-]` before reporting them
- [x] Normalise the trailing slash on `PATCHES_DIR` (config was the only unnormalised source)

Notes from the build:
- `PATCH` tracks the **resolved** `PATCHES_DIR`, not the repo's `wpatches/`. On the main box that's `/opt/headwall-isp/wpatches/`, which only carries recent versions — so most older backups correctly read `PATCH=no`.
- Repository is bigger than expected: **136 backups / 64 slugs / 899 MB**, with WooCommerce alone at 48 versions and 732 MB. Strengthens the case for S2 pruning.
- **JSON is safe without a hand-rolled escaper because the input is constrained.** `bytes` is an integer from `stat`, `patch`/`built` are booleans, `type` is a literal, and `slug`/`version` are validated against `[A-Za-z0-9._-]` (verified: all 136 real entries use only `[a-z0-9.-]`). `escape_json_string()` exists but only guards the two configured paths. Keep the validation if the JSON output is ever extended — it's what makes the emitter correct by construction rather than by luck.
- **Path normalisation now happens in one place** (`configure_and_create_directories`). `WORK_DIR` was already stripped there, and `-d` arrives pre-normalised via `realpath`; the config file was the only source that carried a trailing slash through. `WP_ROOT` is deliberately left alone — a trailing slash there is equally harmless, and the site-facing paths aren't worth touching on a 300+ site tool for cosmetics. Revisit only if it ever surfaces in output.
- **Bug caught by the hostile-filename fixture:** the directory scan used `NAMES=($(ls ...))`, so a package name containing a space word-split into two entries. `stat` then failed on both and returned fewer sizes than names, silently desyncing the parallel size array — every subsequent row reported another package's size (a 3 MB package showed as 1 KB). Now uses `readarray`, validates before stat'ing, and hard-fails on a length mismatch. Worth remembering that this class of bug is invisible on clean data: the real repository never triggered it.

### S3 — `--version` flag ✅ (complete — 2026-09-14)
There was no way to ask an installed `wpatch` its version short of running a command and reading the banner — awkward for checking which version each server in the fleet is on. Exit criteria: `wpatch --version` prints the version and exits `0` with no site, no config, no work dir and no command.

- [x] Handle `-V | --version` in `parse_command_line`, exiting before command validation
- [x] Usage text, `docs/commands-reference.md`, `docs/installation.md`
- [x] Bump to `1.5.0` in the `# Version:` header, `README.md` badge and `CHANGELOG.md`
- [x] Verify: bare `--version`, `-V`, alongside a command, and with a missing `WORK_DIR`

Notes from the build:
- `-V`, not `-v` — `-v` was already `--verbose`.
- **`--version` wins over everything else on the line**, including an invalid command (`wpatch --version bogus` exits `0`). It exits the moment the parser reaches it, the same way `-h` does, so nothing after it is validated. Deliberate: a version probe across the fleet should never fail because of other arguments.
- `load_configuration` still runs before parsing, so `/etc/wpatcher.conf` is sourced first. Harmless — it's variable assignments only — and a missing config or missing `WORK_DIR` was verified not to affect the output.

### S2 — Candidates (not started)
- Prune old backups/built packages (900 MB + 849 MB and growing; WooCommerce alone has 48 versions).
- Consistent bad-slug handling: `-c <typo>` on `patch`/`unpatch`/`backup` still exits `0` with "There are no components to ..." — `list` fixes this only for itself.

---

## Milestones — `wpatch-ng`

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
- **Silent no-op on a bad `-c` slug** — `patch`/`unpatch`/`backup` print the generic "There are no components to ..." and exit `0` when the requested slug doesn't match an active component. `list` (S1) exits `1` in that case; the site-facing commands should be brought into line (S2).
- **Repository growth is unmanaged** — `repos/` and `patched/` only ever grow (1.7 GB on the main box). `list` (S1) makes this visible; pruning is S2.
- **Migration**: sites already patched by `wpatch.sh` carry plain `// START : wpatcher` markers. `wpatch-ng` needs to recognise these (treat as "patched by legacy tool, provenance unknown") so it doesn't double-apply.

---

## Notes for Development

- Priorities are a **subscriber-side** choice (the hoster ranks the repos they trust), NOT declared inside a repo's manifest. A repo just publishes patches; the consumer decides where it sits.
- WORK_DIR holds **regenerable** byte caches (pristine snapshots, built packages, materialised repos). The PHP marker is the **authoritative** record of what's applied. The two are complementary, not redundant.
- Keep `wpatch-ng` runnable unattended (cron, root) and quiet-by-default with a verbose mode, matching how the fleet already calls `wpatch.sh`.
