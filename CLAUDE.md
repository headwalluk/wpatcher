# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WPatcher is a single-file Bash tool (`wpatch.sh`) that applies and reverts small source-level patches to WordPress plugins (and, eventually, themes) on a live site. Its intended use is light, defensible changes — disabling telemetry/"call home" requests, reducing AJAX callbacks, improving caching in abandoned plugins. It is explicitly NOT for nullifying/cracking plugins (see the header comment in `wpatch.sh`).

There is no build step, test suite, or linter. The "code" is the one script plus a tree of `.patch` files.

## Commands

```bash
# Run directly from the repo (no install needed); ./wpatch.sh detects it's
# running from a checkout because ./wpatches exists, setting IS_RUNNING_FROM_REPOS=1.
./wpatch.sh -h

# Typical operations against a target WordPress install:
./wpatch.sh -p /var/www/site/htdocs backup      # snapshot active components to local repo first
./wpatch.sh -p /var/www/site/htdocs patch        # apply all applicable patches
./wpatch.sh -p /var/www/site/htdocs unpatch      # revert
./wpatch.sh -p /var/www/site/htdocs -c woocommerce patch   # single component
./wpatch.sh -p /var/www/site/htdocs dump         # print resolved config vars and exit-equivalent (forces verbose)
./wpatch.sh update                               # git-clone upstream, refresh patches + self-update the installed binary
```

Flags: `-v` verbose, `-f` force re-patch, `-m` maintenance mode during patching, `-d <dir>` custom patches dir, `-c <slug>` single component, `-t plugins|themes` (themes are gated off — `IS_THEMES_SUPPORT_ENABLAED` is 0).

Commands are validated against `VALID_COMMANDS=('patch' 'unpatch' 'backup' 'update' 'dump')`.

## How patching works (the core model)

The script never edits files in the live site in place. It moves whole component directories around through a work area, so reverts are clean:

1. **Discovery** — uses `wp-cli` (`wp plugin list` / `wp theme list`) to enumerate *active* components with their versions. For each, it looks for a matching patch at `PATCHES_DIR/<type>/<slug>/<slug>-<version>.patch`. Patches are version-pinned: WooCommerce 9.4.2 only patches if the site runs exactly 9.4.2.
2. **Backup** — before first patching, the pristine component is tarred into the local repo: `WORK_DIR/repos/<type>/<slug>,<version>.tgz`.
3. **Build patched package** — the pristine tgz is extracted to `WORK_DIR/temp`, `patch -p1` applies the diff, and the result is re-tarred to `WORK_DIR/patched/<type>/<slug>,<version>.tgz`. Patched packages are cached and only rebuilt when the `.patch` file is newer (mtime check in `apply_patch`).
4. **Deploy** — `deploy_component_to_site` renames the live dir to `<slug>-temp`, moves the new package into place, and only deletes the backup on success; on any failure it restores the temp backup. This is the rollback safety net.
5. **Unpatch** — deploys the pristine `repos/` tgz back over the live dir.

**Patched-state detection:** a component counts as "already patched" when any top-level `*.php` file contains a line starting with `// START : wpatcher` (`has_component_been_patched`). Every patch in `wpatches/` therefore inserts this marker. If you author a new patch, it MUST add a `// START : wpatcher` marker line or the tool won't recognise the component as patched (and `patch`/`unpatch`/`backup` gating will misbehave).

## Directory layout that matters

- `WORK_DIR` — defaults to `$HOME/.wpatcher`, overridable in config. Holds `repos/` (pristine backups), `patched/` (built packages), `temp/` (scratch, wiped each run).
- `PATCHES_DIR` — the patch definitions. Resolution order: `-d` flag → config file → `$WORK_DIR/wpatches`. When running from the repo checkout, patches live in `./wpatches/`.
- Patch tree convention: `wpatches/{plugins,themes}/<slug>/<slug>-<version>.patch`. Diffs are generated as `diff -ur <slug>/... <slug>-patched/...` so `patch -p1` applies cleanly from inside the extracted component dir.
- `etc/wpatcher.conf` — sample config; real config is sourced from `/etc/wpatcher.conf` (`CONFIG_FILE_NAME`). Setting `PATCHES_DIR` there marks `IS_USING_CUSTOM_PATCHES_DIR=1`, which makes `update` skip overwriting local patches.

## Conventions / gotchas

- Functions return values via the global `__` variable (and sometimes set `IS_*` globals) rather than stdout — callers read `${__}` immediately after the call. Preserve this pattern when adding functions.
- `update_from_upstream` has an unconditional `exit 0` partway through (`wpatch.sh:616`); the code after it is dead. The self-update only overwrites the binary when NOT running from a repo checkout and the binary is writable.
- Requires `patch tar wp tput git` on PATH (`REQUIRED_BINARIES`). Running as root auto-adds `--allow-root` to wp-cli calls.
- The version string is parsed out of the `# Version:` header comment (top 20 lines of `wpatch.sh`) — update that header when releasing, and mirror it in `CHANGELOG.md`.

## Adding a new patch

1. On a test site, copy the pristine component dir to `<slug>` and `<slug>-patched`, edit the latter (wrap your changes with the `// START : wpatcher` ... marker).
2. `diff -ur <slug> <slug>-patched > wpatches/<type>/<slug>/<slug>-<version>.patch`.
3. The version in the filename must exactly match the component's reported version, since discovery is version-pinned.
