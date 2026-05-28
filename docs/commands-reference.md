# Commands reference

```
wpatch [-vhfm] [-p <WP_ROOT>] [-d <PATCHES_DIR>] [-c <COMPONENT_SLUG>] <COMMAND>
```

If `WP_ROOT` is not given, WPatcher assumes WordPress is installed in the current directory. `WP_ROOT` is the document root — the folder containing `wp-config.php`.

## Commands

| Command   | What it does |
|-----------|--------------|
| `backup`  | Snapshots each active, **unpatched** component into the local repository (`repos/`). These pristine copies are what `unpatch` restores from, so run this before you ever patch. |
| `patch`   | For each active component with a version-matched patch, builds a patched package (if not already cached) and deploys it to the site. Skips components that are already patched unless `-f` is given. |
| `unpatch` | Restores the pristine version of any patched component from the local repository. |
| `update`  | Clones the upstream repo, refreshes the default patch collection (unless a custom `PATCHES_DIR` is configured), and self-updates the installed `wpatch` binary. |
| `dump`    | Prints the resolved internal configuration (paths, work dirs, the command). Implies verbose. Useful for debugging path/config issues. |

Only one command may be given per invocation.

## Flags

| Flag | Long form | Meaning |
|------|-----------|---------|
| `-h` | `--help` | Show usage and exit. |
| `-v` | `--verbose` | More output, including the resolved patch list. |
| `-f` | `--force` | Re-patch a component even if it's already patched. |
| `-m` | `--maintenance` | Put the site into WordPress maintenance mode before patching, and take it out afterwards. |
| `-p` | `--path` | The WordPress document root (`WP_ROOT`). |
| `-d` |  | Use a custom patches directory (overrides config and the default). |
| `-c` | `--component` | Operate on a single component by slug (e.g. `woocommerce`). |
| `-t` | `--type` | Component type: `plugins` (default) or `themes`. **Themes are not yet implemented** and will error. |

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
```

## When does a patch get applied?

For each **active** plugin on the site, WPatcher builds the expected patch path:

```
<PATCHES_DIR>/plugins/<slug>/<slug>-<version>.patch
```

The match is **version-pinned**: a patch named `woocommerce-9.4.2.patch` is only ever applied to WooCommerce 9.4.2. When the plugin updates, you need a patch file for the new version (this is by design — it stops a patch built for old code being force-fed into changed code). A component is detected as "already patched" by a `// START : wpatcher` marker that every patch inserts.

See [Authoring patches](authoring-patches.md) for how that all fits together, and [Configuration](configuration.md) for how `PATCHES_DIR` is resolved.
