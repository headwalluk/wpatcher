# Configuration

WPatcher works with zero configuration, using sensible per-user defaults. A config file is only needed when you want a system-wide work directory or your own patch collection — which is the common setup for anyone running more than a couple of sites.

## The config file

On startup WPatcher reads `/etc/wpatcher.conf` if it exists. It's a plain Bash file that's `source`d into the script, so it sets shell variables:

```bash
##
# /etc/wpatcher.conf
#

# Use a system-wide location instead of ${HOME}/.wpatcher for working files.
# All users that run wpatch need read/write access to this.
WORK_DIR=/var/local/wpatcher/

# Point WPatcher at your own collection of patches.
PATCHES_DIR=/opt/wordpress-patches/
```

A sample lives at [`etc/wpatcher.conf`](../etc/wpatcher.conf) in the repository.

## Settings

### `WORK_DIR`

Where WPatcher keeps its working files. Defaults to `${HOME}/.wpatcher`.

The directory **must already exist** and be writable — WPatcher won't create the top-level work dir for you (it does create the sub-directories inside it). Underneath it you'll find:

- `repos/` — pristine component backups (your only clean copies — treat as precious).
- `patched/` — cached patched packages.
- `temp/` — scratch, wiped each run.

Using a shared `WORK_DIR` is useful on a fleet so backups and built packages are reused across users and cron jobs. Make sure every account that runs `wpatch` can read and write it.

### `PATCHES_DIR`

Where WPatcher looks for `.patch` files. It is resolved in this order:

1. The `-d <dir>` command-line flag (highest priority).
2. `PATCHES_DIR` in `/etc/wpatcher.conf`.
3. `${WORK_DIR}/wpatches` — the default, populated by `wpatch update`.

Setting `PATCHES_DIR` via the config file or `-d` marks the collection as **custom**. The practical effect: `wpatch update` will **not** overwrite a custom patches directory (it only refreshes the default `${WORK_DIR}/wpatches`). This lets you run your own curated patch set without `update` clobbering it — while still letting `update` self-update the `wpatch` binary.

## Patch collection layout

Whatever directory `PATCHES_DIR` points to, it must follow this structure:

```
<PATCHES_DIR>/
  plugins/
    woocommerce/
      woocommerce-9.4.2.patch
      woocommerce-9.4.3.patch
    my-plugin/
      my-plugin-1.0.0.patch
  themes/
    astra/
      astra-4.8.0.patch
```

The filename encodes the component version and must match it exactly — see [Authoring patches](authoring-patches.md). Themes follow the same layout but theme patching is not yet enabled in the tool.

## Running as root

When run as root (e.g. from system cron), WPatcher automatically passes `--allow-root` to every wp-cli call, so you don't need to configure that yourself.
