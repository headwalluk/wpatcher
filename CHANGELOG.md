# Change log

All notable changes to this project will be documented in this file.

## [Unreleased]

...

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

