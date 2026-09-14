# Commands reference

```
wpatch [-vhfmV] [-p <WP_ROOT>] [-d <PATCHES_DIR>] [-c <COMPONENT_SLUG>] <COMMAND>
```

If `WP_ROOT` is not given, WPatcher assumes WordPress is installed in the current directory. `WP_ROOT` is the document root — the folder containing `wp-config.php`.

## Commands

| Command   | What it does |
|-----------|--------------|
| `backup`  | Snapshots each active, **unpatched** component into the local repository (`repos/`). These pristine copies are what `unpatch` restores from, so run this before you ever patch. |
| `patch`   | For each active component with a version-matched patch, builds a patched package (if not already cached) and deploys it to the site. Skips components that are already patched unless `-f` is given. |
| `unpatch` | Restores the pristine version of any patched component from the local repository. |
| `update`  | Clones the upstream repo, refreshes the default patch collection (unless a custom `PATCHES_DIR` is configured), and self-updates the installed `wpatch` binary. |
| `list`    | Lists what's held in the local repository (`repos/`) — one row per slug and version, with size, whether a patch exists for that exact version, and whether a patched package has been built. Read-only: needs no site, so `-p` is not required. |
| `dump`    | Prints the resolved internal configuration (paths, work dirs, the command). Implies verbose. Useful for debugging path/config issues. |

Only one command may be given per invocation.

## Flags

| Flag | Long form | Meaning |
|------|-----------|---------|
| `-h` | `--help` | Show usage and exit. |
| `-V` | `--version` | Print `WPatcher <version>` and exit `0`. Needs no command, site or work directory. |
| `-v` | `--verbose` | More output, including the resolved patch list. |
| `-f` | `--force` | Re-patch a component even if it's already patched. |
| `-m` | `--maintenance` | Put the site into WordPress maintenance mode before patching, and take it out afterwards. |
| `-p` | `--path` | The WordPress document root (`WP_ROOT`). |
| `-d` |  | Use a custom patches directory (overrides config and the default). |
| `-c` | `--component` | Operate on a single component by slug (e.g. `woocommerce`). |
| `-t` | `--type` | Component type: `plugins` (default) or `themes`. **Themes are not yet implemented** and will error (except under `list`, which just shows nothing). |
|      | `--format` | Output format for `list`: `table` (default), `csv` or `json`. Accepts `--format=csv` or `--format csv`. |

`WP_ROOT` can also be supplied as an environment variable instead of `-p`:

```bash
WP_ROOT=/var/www/example.com/htdocs wpatch patch
```

## Examples

```bash
# Back up all active components first
wpatch -p /var/www/example.com/htdocs backup

# Patch everything that has an applicable patch (maintenance mode on)
wpatch -p /var/www/example.com/htdocs -m patch

# Patch just WooCommerce
wpatch -p /var/www/example.com/htdocs -c woocommerce patch

# Force a re-patch (e.g. after editing the .patch file)
wpatch -p /var/www/example.com/htdocs -f -c woocommerce patch

# Revert everything
wpatch -p /var/www/example.com/htdocs unpatch

# Revert a single component
wpatch -p /var/www/example.com/htdocs -c woocommerce unpatch

# Use your own patch collection
wpatch -d /opt/my-wp-patches/ -p /var/www/example.com/htdocs patch

# Inspect resolved configuration without touching a site
wpatch -p /var/www/example.com/htdocs dump

# See what's in the local repository (no site needed)
wpatch list

# Just one component's backups
wpatch list -c woocommerce

# Machine-readable, for scripting
wpatch list --format=csv
wpatch list --format=json
```

## Reading `list` output

```
$ wpatch list -c woocommerce
TYPE     SLUG          VERSION     SIZE  PATCH  BUILT
plugins  woocommerce   9.4.2      12.7M  no     yes
plugins  woocommerce   10.9.3     16.2M  yes    yes
plugins  woocommerce   10.9.4     16.2M  yes    yes

48 backups, 1 slug, 698.0M
```

| Column  | Meaning |
|---------|---------|
| `SIZE`  | Size of the pristine backup tarball in `repos/`. |
| `PATCH` | A `.patch` file exists in the **currently resolved** `PATCHES_DIR` for that exact version. `no` here just means you have a backup with no patch to apply to it — which is normal for versions you've since moved past. |
| `BUILT` | A patched package is already cached in `patched/`, so `patch` won't need to rebuild it. |

Versions sort naturally rather than alphabetically, so `9.4.2` appears before `10.9.4`.

## Machine-readable output

Both `csv` and `json` send the banner lines to stderr, so stdout pipes cleanly.

### CSV

Columns are `type,slug,version,bytes,patch,built`, with `bytes` as a raw integer and
`patch`/`built` as `1`/`0`.

```bash
# Total bytes held in the local repository
wpatch list --format=csv | tail -n +2 | cut -d, -f4 | paste -sd+ | bc
```

### JSON

`--format=json` emits a single document with the totals alongside the components, so you don't
have to re-derive them:

```json
{
  "wpatcher_version": "1.4.0",
  "repository_dir": "/var/local/wpatcher/repos",
  "patches_dir": "/opt/headwall-isp/wpatches/",
  "totals": { "backups": 136, "slugs": 64, "bytes": 942443092 },
  "components": [
    { "type": "plugins", "slug": "woocommerce", "version": "10.9.4", "bytes": 16465920, "patch": true, "built": true }
  ]
}
```

`bytes` is a number and `patch`/`built` are real booleans, so `jq` filters read naturally:

```bash
# Backups you're holding with no patch to apply - prune candidates
wpatch list --format=json | jq -r '.components[] | select(.patch == false) | "\(.slug) \(.version)"'

# Total held, in MB
wpatch list --format=json | jq '.totals.bytes / 1048576 | floor'

# Every version of one plugin, newest last
wpatch list --format=json -c woocommerce | jq -r '.components[].version'
```

A `json` run always emits a complete, parseable document — including when there's nothing to
report — so you can pipe it into `jq` unconditionally without guarding for empty input.

## Exit codes and rejected packages

`list` exits `1` if you pass `-c <slug>` and nothing in the repository matches it, so it can be
used as a check in scripts. (In `json` mode it still prints a valid document with an empty
`components` array first.)

Package filenames are expected to be `<slug>,<version>.tgz` with both parts limited to
`A-Z a-z 0-9 . _ -`, which is what WordPress slugs and version strings always are. A file that
looks like a package but falls outside that set is skipped with a warning on stderr rather than
being quoted into your CSV or JSON. Files that clearly aren't packages at all — anything without
a comma — are ignored silently unless you pass `-v`.

## When does a patch get applied?

For each **active** plugin on the site, WPatcher builds the expected patch path:

```
<PATCHES_DIR>/plugins/<slug>/<slug>-<version>.patch
```

The match is **version-pinned**: a patch named `woocommerce-9.4.2.patch` is only ever applied to WooCommerce 9.4.2. When the plugin updates, you need a patch file for the new version (this is by design — it stops a patch built for old code being force-fed into changed code). A component is detected as "already patched" by a `// START : wpatcher` marker that every patch inserts.

See [Authoring patches](authoring-patches.md) for how that all fits together, and [Configuration](configuration.md) for how `PATCHES_DIR` is resolved.
