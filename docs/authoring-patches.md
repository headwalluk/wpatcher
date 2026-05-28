# Authoring patches

This guide is for developers who want to write and maintain their own WPatcher patch definitions.

## How WPatcher uses your patch

Understanding the flow makes the conventions obvious. When you run `patch`, WPatcher:

1. Uses wp-cli to list the site's **active** components and their versions.
2. For each one, looks for `<PATCHES_DIR>/<type>/<slug>/<slug>-<version>.patch`.
3. Tars the pristine component into `repos/`, extracts it to a temp dir, runs `patch -p1 -i <your.patch>`, and re-tars the result into `patched/`.
4. Swaps the live component directory for the patched copy (keeping the pristine one for `unpatch`).

So a patch is just a unified diff that applies cleanly with `patch -p1` from inside the component's own directory, plus one required marker.

## File layout and naming

```
<PATCHES_DIR>/
  plugins/
    <slug>/
      <slug>-<version>.patch
  themes/
    <slug>/
      <slug>-<version>.patch
```

- `<slug>` is the component's directory name under `wp-content/plugins` (or `themes`) — the same name wp-cli reports.
- `<version>` must match the installed version **exactly**. WPatcher is version-pinned: `woocommerce-9.4.2.patch` only ever applies to WooCommerce 9.4.2. This is deliberate — it stops a diff built against old source being forced into changed code.
- One file per version. When the plugin updates, add a new file for the new version.

> Themes follow the same layout, but theme patching is currently disabled in the tool and will error if requested with `-t themes`.

## The required `// START : wpatcher` marker

WPatcher decides whether a component is "already patched" by grepping the component's top-level `*.php` files for a line beginning with:

```php
// START : wpatcher
```

**Every patch must add at least one such marker line in a top-level PHP file of the component.** Without it:

- `patch` may re-apply your patch on top of an already-patched install.
- `unpatch` won't recognise the component as patched and will skip it.
- `backup` may snapshot an already-patched component as if it were pristine.

A minimal example — note the marker right where your change starts:

```diff
--- woocommerce/includes/admin/helper/class-wc-helper.php
+++ woocommerce-patched/includes/admin/helper/class-wc-helper.php
@@ -1580,6 +1580,8 @@
 	public static function get_product_usage_notice_rules() {
+        // START : wpatcher
+        return []; // Stop calling home when we don't need to.
 		$cache_key = '_woocommerce_helper_product_usage_notice_rules';
```

Keep changes small, reversible, and commented so the next person (or future you) knows why the change exists.

## Generating a patch

Work from a pristine copy of the exact version you're targeting.

```bash
# 1. Get two copies of the unpatched component at the target version.
cp -r woocommerce woocommerce-patched

# 2. Edit the *-patched copy. Wrap your changes with a // START : wpatcher marker.
$EDITOR woocommerce-patched/includes/...

# 3. Produce a -p1-style unified diff. Note the paths: <slug>/... vs <slug>-patched/...
diff -ur woocommerce woocommerce-patched > woocommerce-<version>.patch

# 4. File it under your patches dir.
mkdir -p <PATCHES_DIR>/plugins/woocommerce
mv woocommerce-<version>.patch <PATCHES_DIR>/plugins/woocommerce/
```

The `diff -ur woocommerce woocommerce-patched` form is what makes `patch -p1` apply correctly, because WPatcher runs `patch` from inside the extracted `woocommerce/` directory.

## Testing a patch

```bash
# Apply just your component, in maintenance mode, on a test site.
wpatch -d <PATCHES_DIR> -p /var/www/test.example/htdocs -m -c woocommerce patch

# Confirm the marker landed and the site behaves.
# Then revert to confirm a clean rollback.
wpatch -d <PATCHES_DIR> -p /var/www/test.example/htdocs -c woocommerce unpatch
```

### Re-testing after editing a patch

WPatcher **caches** the built patched package in `patched/`. After you edit a `.patch` file, force a rebuild and re-deploy:

```bash
wpatch -d <PATCHES_DIR> -p /var/www/test.example/htdocs -f -c woocommerce patch
```

WPatcher also rebuilds automatically when the `.patch` file is newer than the cached package, but `-f` is the reliable way to be sure during development.

## Maintaining patches over time

Because patches are version-pinned, a patch's useful life ends when the plugin updates. For each plugin you patch:

- Watch upstream releases; when a new version ships, build and test a patch for it.
- Remember these are meant as **temporary** fixes — once the plugin developer ships a proper fix, retire your patch rather than carrying it forever.
- Keep your collection in version control and, on a fleet, synced to every node (see [Fleet operations](fleet-operations.md)).
