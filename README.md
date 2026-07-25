# WPatcher

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.4.0-green.svg)](CHANGELOG.md)
[![Made with Bash](https://img.shields.io/badge/made%20with-Bash-1f425f.svg)](wpatch.sh)
[![Requires wp-cli](https://img.shields.io/badge/requires-wp--cli-blueviolet.svg)](https://wp-cli.org/)

A tool for applying and reverting small source-level patches to WordPress plugins and themes.

It was born out of a need to apply light patches to plugins — usually to limit outgoing HTTP API calls that drag down performance for site owners and their clients. It's also handy when you have abandoned plugins across a hosting estate and want to maintain simple fixes without forking them into full projects.

WPatcher is designed for **temporary, defensible fixes** — disabling telemetry, reducing AJAX chatter, improving caching — typically held in place until a plugin developer ships a proper fix. It is **not** for nullifying or cracking plugins.

## How it works, in one breath

WPatcher uses [wp-cli](https://wp-cli.org/) to find the active plugins/themes on a site, looks for a version-matched `.patch` file for each, and swaps the live component directory for a patched copy — keeping the pristine original so it can cleanly revert at any time.

## Quick start

```bash
# Install to /usr/local/bin/wpatch
source <(curl -s https://raw.githubusercontent.com/headwalluk/wpatcher/refs/heads/main/install-wpatcher.sh)

# Pull the latest patch definitions
wpatch update

# Back up a site's components, then patch
wpatch -p /var/www/example.com/htdocs backup
wpatch -p /var/www/example.com/htdocs -m patch
```

See **[docs/installation.md](docs/installation.md)** for the full setup, including prerequisites.

## Documentation

Pick the guide that matches what you're doing:

- **[Installation](docs/installation.md)** — install the tool and its prerequisites, for self-hosters running one or a few sites.
- **[Configuration](docs/configuration.md)** — `/etc/wpatcher.conf`, work directories, and pointing WPatcher at your own patch collection.
- **[Commands reference](docs/commands-reference.md)** — every command and flag (`patch`, `unpatch`, `backup`, `list`, `update`, `dump`).
- **[Fleet operations](docs/fleet-operations.md)** — running WPatcher unattended across many sites from overnight tooling (the 300+ site use case).
- **[Patching WooCommerce](docs/patching-woocommerce.md)** — for store owners and web designers who want to debloat and speed up WooCommerce.
- **[Authoring patches](docs/authoring-patches.md)** — for developers writing and maintaining their own patch definitions.

## Recommended patches

The most successful real-world patch set we run is **[woocommerce-debloat](https://github.com/headwalluk/woocommerce-debloat)** — a maintained collection that strips telemetry and unnecessary callbacks from WooCommerce. See [Patching WooCommerce](docs/patching-woocommerce.md) for how to use it with WPatcher.

## License

[MIT](LICENSE) © headwalluk
