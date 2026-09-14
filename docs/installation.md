# Installation

This guide is for self-hosters running WPatcher on one or a few WordPress sites. If you manage a large estate, also read [Fleet operations](fleet-operations.md).

## Prerequisites

WPatcher is a Bash script that shells out to a handful of standard tools. It checks for these on startup and refuses to run if any are missing:

| Binary  | Provided by (Debian/Ubuntu)        | Used for |
|---------|------------------------------------|----------|
| `wp`    | [wp-cli](https://wp-cli.org/)      | Listing active plugins/themes and their versions |
| `patch` | `patch`                            | Applying the diffs |
| `tar`   | `tar`                              | Packaging pristine and patched components |
| `git`   | `git`                              | `wpatch update` (cloning the upstream repo) |
| `tput`  | `ncurses-bin`                      | Coloured terminal output |

Install the OS packages:

```bash
# Debian / Ubuntu / Mint / etc.
sudo apt install patch tar git ncurses-bin wget
```

Make sure [wp-cli](https://wp-cli.org/) is installed and working (`wp --info`). WPatcher relies on it to read each site's active components.

## Install the tool

The installer downloads `wpatch.sh`, makes it executable, and moves it to `/usr/local/bin/wpatch`:

```bash
source <(curl -s https://raw.githubusercontent.com/headwalluk/wpatcher/refs/heads/main/install-wpatcher.sh)
```

The move into `/usr/local/bin` uses `sudo`, so you'll be prompted for your password.

Confirm it works:

```bash
wpatch --version
wpatch -h
```

## Create the work directory

WPatcher keeps its working files in a work directory — `~/.wpatcher` by default — and expects that top-level directory to already exist (it creates the sub-directories inside it, but not the work dir itself). Create it once:

```bash
mkdir -p ~/.wpatcher
```

If you'd rather use a system-wide location, set `WORK_DIR` in `/etc/wpatcher.conf` and create that directory instead — see [Configuration](configuration.md).

## Get the patch definitions

A fresh install has no patches. Pull the bundled collection from upstream:

```bash
wpatch update
```

This clones the upstream repository and copies its `wpatches/` tree into your work directory (`~/.wpatcher/wpatches/` by default). Running `update` again later refreshes both the patches **and** the installed `wpatch` binary.

> If you maintain your own patch collection, you'll point WPatcher at it instead — see [Configuration](configuration.md). When a custom patches directory is configured, `update` leaves your patches untouched.

## First run

Always back up a site's components before patching. The backup stores pristine copies that `unpatch` later restores from:

```bash
# Snapshot the site's active plugins/themes into your local repository
wpatch -p /var/www/example.com/htdocs backup

# Apply every applicable patch (-m puts the site in maintenance mode first)
wpatch -p /var/www/example.com/htdocs -m patch
```

`-p` (or `--path`) is the WordPress document root — the directory containing `wp-config.php`. If you omit it, WPatcher assumes the current directory.

To undo everything:

```bash
wpatch -p /var/www/example.com/htdocs unpatch
```

See the [Commands reference](commands-reference.md) for the full list of commands and flags.

## Where things are stored

WPatcher keeps its working files under `~/.wpatcher/` by default:

- `repos/` — pristine (unpatched) copies of components, used to revert.
- `patched/` — built patched packages, cached and reused.
- `temp/` — scratch space, wiped on every run.
- `wpatches/` — the patch definitions (unless you use a custom location).

If you ever delete `~/.wpatcher/`, look inside `repos/` first — it holds the only clean backups of any components you've patched. See [Configuration](configuration.md) to relocate this directory.
