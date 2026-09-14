# Change log

All notable changes to this project will be documented in this file.

## [Unreleased]

...

## [1.5.0] - 2026-09-14

Added `-V | --version`, which prints `WPatcher <version>` and exits `0`. It's handled while the command line is parsed, so it needs no command, no site, and no work directory — handy for checking which version each server in a fleet is running:

```bash
wpatch --version
```

## [1.4.0] - 2026-07-25

Added a `list` command that shows what's held in the local repository, so you can see your backups without picking through `WORK_DIR` by hand. It's read-only and needs no site, so it runs fine without `-p` and without a valid WordPress installation.

```
wpatch list
wpatch list -c woocommerce
wpatch list --format=csv
```

Each row is one backup — component type, slug, version, size, whether a `.patch` exists for that exact version, and whether a patched package has already been built. Rows sort by slug then by natural version order, so `9.4.2` comes before `10.9.4`. A summary of totals is printed at the end.

Added `--format [table|csv|json]` for scripting. `csv` emits `type,slug,version,bytes,patch,built`. `json` emits a single document carrying the totals alongside the components, with `bytes` as a number and `patch`/`built` as real booleans, so `jq` filters read naturally:

```bash
wpatch list --format=json | jq -r '.components[] | select(.patch == false) | "\(.slug) \(.version)"'
```

In both machine-readable modes the banner lines go to stderr so stdout stays clean to pipe. A `json` run always emits a complete, parseable document, even when there's nothing to report, so it can be piped into `jq` without guarding for empty input.

Package filenames are now validated before being reported. `<slug>,<version>.tgz` is expected to use only `A-Za-z0-9._-`, which is what WordPress slugs and versions always are; anything else is skipped with a warning on stderr rather than being quoted into output. This also fixed a size-reporting bug found while testing — a package name containing a space used to word-split during the directory scan, which knocked the sizes out of step with the packages they belonged to and reported the wrong size against every subsequent row.

Fixed the `-c | --component` filter, which never worked. It compared the requested slug against an unset `PLUGIN_SLUG` variable instead of `COMPONENT_SLUG`, so passing `-c` to `patch`, `unpatch` or `backup` silently matched nothing and the tool reported "There are no components to ...". This bug had been present since 0.1.0.

`PATCHES_DIR` now has any trailing slash stripped, so it's reported consistently with the `WORK_DIR`-derived paths and with `-d` (which `realpath` already normalised). Previously a `PATCHES_DIR=/opt/.../wpatches/` in `/etc/wpatcher.conf` was carried through verbatim, giving resolved paths like `wpatches//plugins/...`. Harmless — every use appends its own `/` and POSIX collapses the double — but untidy in `dump`, verbose output and the new JSON.

The `WPatcher :: <version> :: <url>` banner now prints *after* the command line is parsed (it has to know the output format first). As a result it no longer appears above usage/help output.

Added WooCommerce patches for the current release line, each verified to apply cleanly against a pristine copy of its own version:

 * woocommerce 10.8.0
 * woocommerce 10.8.1
 * woocommerce 10.9.0
 * woocommerce 10.9.1
 * woocommerce 10.9.3
 * woocommerce 10.9.4

## 2025-11-03

Added a bunch of WooCommerce patches to disable telemetry and reduce ajax callbacks.

## [1.3.0] - 2024-11-13

Added the -m | --maintenance switch so the tool will put the site into maintenance mode before patching. If you're calling the tool from a script, your site might already be in maintenance mode so you don't need to pass this switch. But if you call the tool manually from the command-line, it's advisable to pass this switch into wpatcher.

## [1.2.0] - 2024-11-13

More robust checking for plugins that have already been patched, by slightly loosening the grep for "// START : wpatcher" in a PHP file.

Added some new patches:

 * woocommerce 9.4.1
 * broken-link-checker 2.4.1
 * multiple-packages-for-woocommerce 1.1.1

## [1.0.0] - 2024-09-29

Initial release, with the following commands working:

patch, unpatch, backup, update

