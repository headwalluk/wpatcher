# Fleet operations

This guide is for running WPatcher unattended across many WordPress sites — the scenario it was built for. The reference deployment runs it nightly against 300+ sites as part of routine WordPress maintenance.

## The model

On a fleet, the recurring task is simple: after each site's plugins are updated overnight, run `patch` against it. WPatcher only acts on components that (a) are active, (b) have a version-matched patch, and (c) aren't already patched — so running it on every site, every night, is safe and idempotent. Sites with nothing to patch finish in moments.

```bash
/usr/local/bin/wpatch /var/www/example.com/web patch
```

## Recommended setup

### 1. Shared, system-wide directories

Configure `/etc/wpatcher.conf` so every cron run shares one work directory and one patch collection:

```bash
WORK_DIR=/var/local/wpatcher/
PATCHES_DIR=/opt/headwall-isp/wpatches/
```

A shared `WORK_DIR` means pristine backups (`repos/`) and built patched packages (`patched/`) are computed once and reused across all sites running the same component version — a patched package for WooCommerce 9.4.2 is built the first time it's seen and reused everywhere after. Make sure the accounts that run the cron job can read/write `WORK_DIR`. See [Configuration](configuration.md).

### 2. Sync your patch collection across the fleet

Keep your patch collection (e.g. `/opt/headwall-isp/wpatches/`) in version control or rsync it to every node, so all servers patch identically. Because `PATCHES_DIR` is set to a custom location, `wpatch update` will **not** overwrite it — your curated patches are safe. You can still use `wpatch update` to self-update the `wpatch` binary if you installed it via the upstream installer.

### 3. Order of operations in your nightly job

For each site, the safe sequence is:

```bash
wpatch -p "$SITE_ROOT" backup   # capture pristine copies (no-op once captured)
# ... your normal plugin/theme updates run here ...
wpatch -p "$SITE_ROOT" patch    # re-apply patches against the new versions
```

Run `backup` before updates so you always have a clean copy of each version in `repos/`. After an update bumps a component's version, `patch` looks for a patch file matching the *new* version — so when you bump a plugin, remember to ship a patch for its new version too (see below).

## Patches are version-pinned — plan for plugin updates

A patch named `woocommerce-9.4.2.patch` applies **only** to WooCommerce 9.4.2. The night a site updates to 9.4.3, that patch silently stops applying until you add `woocommerce-9.4.3.patch`. This is deliberate (it prevents stale diffs being forced into changed code), but it means your patch collection needs maintenance in step with plugin releases.

Practical tactics:

- Track which versions you have patches for, and watch for plugin releases that outrun your collection.
- After a major plugin update lands across the fleet, regenerate and test the patch for the new version before the next maintenance window (see [Authoring patches](authoring-patches.md)).
- Treat a missing patch as "temporarily unpatched," which is usually fine for the temporary-fix use case — the site simply runs vanilla until you catch up.

## Maintenance mode

When you call `patch` manually you'll often want `-m` to flip the site into maintenance mode during the swap. In overnight tooling the site is frequently *already* in maintenance mode for the wider update run — in that case **omit `-m`**, since WPatcher would otherwise take the site out of maintenance mode when it finishes, before your outer job is done.

## Running as root

Fleet cron jobs typically run as root. WPatcher detects this and automatically adds `--allow-root` to its wp-cli calls, so no extra configuration is needed.

## Reverting at scale

`unpatch` restores from the pristine copies in `repos/`. As long as your shared `WORK_DIR` is intact, you can revert any site — or scripted across the whole fleet — at any time:

```bash
wpatch -p "$SITE_ROOT" unpatch
```

Guard `WORK_DIR/repos/` accordingly: it holds the only clean backups of patched components.
