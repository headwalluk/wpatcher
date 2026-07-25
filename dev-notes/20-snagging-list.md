# Snagging list

Small, known, non-urgent items. Nothing here is a bug that affects correctness in normal use —
these are tidy-ups and rough edges we've consciously chosen to leave. Anything that *does* affect
correctness belongs in the tracker's Technical Debt section instead.

Format: each item states what it is, why it was left, and what "done" would look like.

---

## `wpatch.sh`

### S-1. Normalise the trailing slash on `WP_ROOT`

**What.** `PATCHES_DIR` and `WORK_DIR` both get their trailing slash stripped in
`configure_and_create_directories`, and `-d` arrives pre-normalised via `realpath`. `WP_ROOT` does
not. Passing `-p /var/www/example.com/htdocs/` therefore builds internal paths like
`/var/www/example.com/htdocs//wp-content/plugins/woocommerce`.

**Why it was left (2026-07-25).** Entirely cosmetic — every use appends its own `/` and POSIX
collapses the double, and `wp --path=` is indifferent. Unlike `PATCHES_DIR` it never appears in
`list` output, so nothing user-facing is inconsistent. It's site-facing path construction on a
tool running across 300+ sites, and the risk/reward of touching it for tidiness alone didn't
justify it on the day.

**Done looks like.** One line beside the existing `PATCHES_DIR` strip:

```bash
if [ -n "${WP_ROOT}" ]; then
  WP_ROOT="${WP_ROOT%/}"
fi
```

Then re-verify the deploy path specifically — `deploy_component_to_site` builds
`<WP_ROOT>/wp-content/<type>/<slug>` and `<slug>-temp` and moves directories between them, so
that's where a path change would bite. Test `patch`, `unpatch` and the temp-backup rollback with
both `-p /path` and `-p /path/`.

### S-2. `dump` falls through to the site scan

`dump` prints the resolved configuration, then carries on into the component scan and finishes
with "There are no components to dump", because it isn't handled in the apply loop. Harmless and
long-standing, but the trailing message is noise. Either dispatch `dump` early (like `update` and
`list`) or give it a real branch in the loop.

### S-3. `-h` no longer prints the version banner

Deliberate consequence of moving the banner after `parse_command_line` in 1.4.0 so `--format=csv`
and `--format=json` could keep stdout clean. Noted in the changelog. If the banner on `-h` is
wanted back, `show_usage_then_exit` can print it itself.

---

## Patch collection

### S-4. Repo examples have a version gap for WooCommerce

`wpatches/plugins/woocommerce/` holds 9.3.3–10.3.4 plus 10.8.0–10.9.4. The 10.4–10.7 range is
missing because production (`/opt/headwall-isp/wpatches/`) has been pruned to recent versions and
the repo was last topped up at 10.3.4. Not a problem — patches are version-pinned, so a missing
version simply means no patch for it — but worth knowing the examples aren't a contiguous run.

### S-5. No pruning story for the patch collection

Separate from repository pruning (tracker S2, which is about `repos/`/`patched/` tarballs). The
patch collection itself only grows, and old versions stay applicable to nobody once the fleet has
moved on. Decide whether `wpatch.sh` should ever prune patches, or whether that's purely a
`wpatch-ng` manifest concern.

---

## Docs

### S-6. `docs/` has no page for `list`-driven housekeeping

`list` is documented in `commands-reference.md` and used in `fleet-operations.md`, but there's no
"how do I decide what to prune" narrative. Worth writing once tracker S2 exists and there's an
actual prune command to point at — writing it before then would document a workflow that has no
tooling behind it.
