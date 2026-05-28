# Patching WooCommerce

This guide is for store owners and web designers who want a faster, quieter WooCommerce. WooCommerce ships a lot of telemetry, "phone home" calls, and admin AJAX chatter that can drag down performance — especially on shared hosting or for clients with modest servers. WPatcher lets you trim that without forking the plugin or losing the changes on the next update.

> **Scope:** these are light, reversible source patches. They don't crack or relicense anything — they disable optional tracking and reduce unnecessary background work. You can revert at any time with `unpatch`.

## The ready-made patch set

You don't have to write these patches yourself. The maintained collection we run in production is:

**[woocommerce-debloat](https://github.com/headwalluk/woocommerce-debloat)**

It contains version-matched patches that, among other things:

- Stop WooCommerce calling home for product-usage notice rules.
- Disable the in-browser tracking scripts (with a small stub so dependent scripts don't error).
- Reduce assorted admin-side callbacks.

Each patch is pinned to a specific WooCommerce version (e.g. `woocommerce-9.4.2.patch`), so it only applies to the exact version it was built for.

## Using it with WPatcher

1. **Install WPatcher** if you haven't — see [Installation](installation.md).

2. **Get the patches.** Clone the debloat collection somewhere WPatcher can read, laid out as `<dir>/plugins/woocommerce/woocommerce-<version>.patch`:

   ```bash
   git clone https://github.com/headwalluk/woocommerce-debloat.git /opt/woocommerce-debloat
   ```

   Point WPatcher at it either per-command with `-d`, or permanently via `PATCHES_DIR` in `/etc/wpatcher.conf` (see [Configuration](configuration.md)).

3. **Check your WooCommerce version** so you know there's a matching patch:

   ```bash
   wp --path=/var/www/example.com/htdocs plugin get woocommerce --field=version
   ```

   If the collection doesn't yet have a patch for that exact version, WPatcher will simply skip it — nothing breaks, WooCommerce just runs vanilla.

4. **Back up, then patch:**

   ```bash
   wpatch -d /opt/woocommerce-debloat -p /var/www/example.com/htdocs backup
   wpatch -d /opt/woocommerce-debloat -p /var/www/example.com/htdocs -m -c woocommerce patch
   ```

   `-m` flips the site into maintenance mode during the swap; `-c woocommerce` limits the run to WooCommerce.

5. **Verify**, and revert instantly if you're not happy:

   ```bash
   wpatch -d /opt/woocommerce-debloat -p /var/www/example.com/htdocs -c woocommerce unpatch
   ```

## What to expect on the next WooCommerce update

Patches are tied to a specific version. When WooCommerce updates, the old patch stops applying and your store reverts to stock behaviour until a patch exists for the new version. Two ways to stay current:

- Pull the latest [woocommerce-debloat](https://github.com/headwalluk/woocommerce-debloat) and re-run `patch` after updates.
- Or maintain your own version — see [Authoring patches](authoring-patches.md) if you want to add or adjust changes for a particular client.

## Designers maintaining several client sites

If you look after multiple WooCommerce sites, keep one copy of the patch collection and apply it to each site with `-d` (or set `PATCHES_DIR` once in config). For genuinely large estates and overnight automation, see [Fleet operations](fleet-operations.md).
