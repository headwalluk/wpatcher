# wpatch-ng — Architecture (design draft)

**Status:** Draft for review · 2026-05-28
**Tracker:** [`00-project-tracker.md`](00-project-tracker.md)

This is the working design for the remote-repository version of WPatcher. It's a living doc — sections marked **PROPOSED** need a yes/no/redirect before they're frozen; sections under **Locked** are settled.

---

## 1. The shift, in one paragraph

`wpatch.sh` patches from **one** local directory, **one** patch per plugin+version, with a boolean "is it patched?" check and a full-restore unpatch. `wpatch-ng` patches from **many** remote repositories the hoster subscribes to, each with a **priority**; for a given plugin+version it may apply **several** stacked patches; it records **exactly which** patches were applied (and from where); and it accepts that high-priority patches can shift line numbers enough that lower-priority patches no longer apply — that's a **warning**, not a failure.

---

## 2. Locked decisions

- New tool `wpatch-ng`; `wpatch.sh` stays as the stable fallback.
- Go implementation (single static binary for ~10 servers).
- Pluggable transport: git **and** HTTP static-index repos.
- Applied-state recorded in the live PHP (self-invalidates on plugin update). Not under `wp-content` as a discoverable file; not solely in `WORK_DIR`.
- Repo **priority is assigned by the subscriber**, not declared by the repo.
- **Marker = single ledger block in the plugin's main entry file** (§4.1), not per-hunk markers. Patches stay plain diffs.
- **Revert = full-unpatch only in v1** (§7.1): restore pristine, drop ledger; "remove one patch" = rebuild from pristine with it deselected. Selective reverse-patch deferred.
- **Pristine = local snapshots in `WORK_DIR`** (§7.2), captured before first patch; wordpress.org re-fetch is a later fallback.
- **Themes deferred** (§7.3): plugins first. When revisited, scope to **parent / non-child themes only** — child-theme slugs (`astra-child`, `kadence-child`) are non-unique across the fleet and can't be safely version-pinned.

---

## 3. Core model

### 3.1 Three kinds of data, kept separate

| Data | Authoritative? | Where | Regenerable? |
|------|----------------|-------|--------------|
| **Applied state** (what patches are on a site right now) | ✅ source of truth | Marker in the live plugin PHP | No — but self-heals (see §5) |
| **Pristine bytes** (clean copy to build from / revert to) | cache | `WORK_DIR` snapshot, keyed by slug+version+sha | Yes (re-snapshot or re-fetch) |
| **Available patches** (what *could* be applied) | cache | `WORK_DIR` materialised repos + manifests | Yes (re-fetch from sources) |

The key discipline: **only the marker is authoritative for "what is applied."** Everything in `WORK_DIR` is a cache that can be rebuilt. This is what lets a WP-admin plugin update silently and correctly reset a plugin to "unpatched" — it wipes the marker, and `WORK_DIR` being stale doesn't matter because it's never trusted for applied-state.

### 3.2 End-to-end patch flow (per plugin)

```
wp-cli: active plugins + versions
        │
        ▼
for each plugin+version:
  read marker in live PHP  ──► current applied set (repo/patch/sha list)
  gather applicable patches from all subscribed repos, sorted by priority
        │
        ▼
  diff desired-set vs applied-set:
     already-applied & unchanged  → skip (idempotent)
     stale (sha changed)          → rebuild
     new                          → apply
        │
        ▼
  build: extract pristine → apply patches high-priority-first
     each apply ok      → include, record outcome=applied
     each apply fails   → skip that patch, record outcome=warning(reason)
        │
        ▼
  deploy patched tree to site (atomic dir swap, temp-backup rollback as today)
  write/refresh the marker ledger with the applied set
```

---

## 4. The marker / state ledger

### 4.1 LOCKED — a single ledger block, not per-hunk markers

Rather than wrapping every patched hunk (which forces patch authors to hand-write provenance they can't know — sha, timestamp), `wpatch-ng` maintains **one ledger block** that it injects/updates in the plugin's **main entry PHP file** (e.g. `woocommerce.php`). Patches themselves stay as plain unified diffs.

```php
/* WPATCHER-NG-STATE v1
{"comp":"woocommerce","compVersion":"9.4.2","tool":"wpatch-ng/0.1.0","patches":[
  {"repo":"headwall","id":"wc-disable-telemetry","patchVersion":"1.2.0","sha256":"3f1a…","priority":10,"appliedAt":"2026-05-28T02:14:33Z"},
  {"repo":"johndoe","id":"wc-cart-ajax-trim","patchVersion":"0.3.1","sha256":"9c0b…","priority":50,"appliedAt":"2026-05-28T02:14:34Z"}
]}
WPATCHER-NG-STATE */
```

Why the main entry file: WordPress plugin updates replace the **entire** plugin directory, so the main file (and the ledger) is always overwritten on update → state self-invalidates. The ledger records every stacked patch, including provenance the diff can't carry. Reading state = find one block, parse one JSON object. Writing state = rewrite one block.

**Trade-offs to weigh:**
- A single block is easy to read/write/parse and survives partial patches; but it asserts "applied" without proving each patch's hunks are physically present. For the fleet model (we control the patches) that's an acceptable simplification for v1.
- Per-hunk markers would be physically grounded but ugly, author-burdensome, and hard to keep in sync.
- Alternative placement: a dedicated innocuous file inside the plugin dir (still wiped on update). Rejected for now — a file that only exists when patched is itself a weak fingerprint; folding into the main file is quieter.

### 4.2 Legacy migration

Sites patched by `wpatch.sh` carry a bare `// START : wpatcher` line. `wpatch-ng` must detect it and treat the component as "patched by legacy tool, provenance unknown" — surface it, don't blindly stack on top. Cleanest path: `unpatch` with `wpatch.sh` (or restore pristine) before `wpatch-ng` adopts the site.

---

## 5. Why state-in-PHP beats the alternatives (the load-bearing insight)

- **A file in `wp-content`** (`.wpatcher/state.json`) is a predictable path an attacker can probe to fingerprint the tooling/patches. Rejected.
- **Central store in `WORK_DIR`** can't observe a plugin updated from the WP admin. After such an update the store would still claim "patched" while the live code is freshly vanilla — exactly the desync that causes double-applies and broken reverts.
- **State embedded in the patched code** is destroyed by the very act that should reset it (the plugin update overwrites the files). The record can't outlive the thing it describes. That's the property we want.

---

## 6. Repositories, transport, manifests

### 6.1 Transport interface (PROPOSED)

```
Source interface:
  Materialise(cacheDir) → localPath, error   // fetch/refresh into WORK_DIR cache
  Manifest() → Manifest, error                // parsed index of available patches
  Fetch(patchRef) → bytes, error              // retrieve one patch file, verify checksum
```

Implementations:
- **GitSource** — clone/pull a git repo (how `wpatch.sh update` works today). Easy authoring + history; needs `git` on clients.
- **HttpSource** — a static JSON manifest + patch files over HTTPS. CDN/cache-friendly; no git needed; most literally "web-based."

### 6.2 Manifest schema (PROPOSED, transport-agnostic)

A repo publishes an index keyed by component + version:

```json
{
  "schema": 1,
  "repo": "headwall",
  "components": {
    "plugins/woocommerce": {
      "9.4.2": [
        {
          "id": "wc-disable-telemetry",
          "patchVersion": "1.2.0",
          "file": "plugins/woocommerce/wc-disable-telemetry-9.4.2.patch",
          "sha256": "3f1a…",
          "summary": "Stop WooCommerce phoning home for usage-notice rules",
          "strip": 1
        }
      ]
    }
  }
}
```

Notes:
- `id` is stable across versions so the same logical patch can be tracked as the plugin updates.
- No priority field — priority is the subscriber's call (§6.3).
- `sha256` drives both integrity checking and the stale-vs-current decision in §3.2.
- Still **version-pinned** per component version, same as today.

### 6.3 Subscriber config (PROPOSED)

```toml
work_dir = "/var/local/wpatcher"

[[repo]]
name = "headwall"
priority = 10            # lower number = higher priority, applied first
source = { type = "git", url = "https://github.com/headwalluk/woocommerce-debloat.git" }

[[repo]]
name = "johndoe"
priority = 50
source = { type = "http", url = "https://patches.johndoe.dev/index.json" }
enabled = true
```

---

## 7. Apply / warning / revert semantics

- **Apply order:** ascending priority number (highest priority first), each patch applied onto the result of the previous, starting from pristine.
- **Failure = warning:** a patch that won't apply (line drift from earlier patches, or genuine conflict) is skipped, recorded with `outcome: warning` + reason, and the run continues. Non-zero overall exit only on *hard* errors (can't reach pristine, can't deploy), not on skipped low-priority patches.
- **Idempotency:** re-running compares desired set (by repo+id+sha) against the ledger; unchanged patches are skipped, changed/new ones trigger a rebuild.

### 7.1 Revert (LOCKED — v1)

- **v1: full unpatch only.** Restore the pristine snapshot for that slug+version, remove the ledger. Simple and matches `wpatch.sh`. To "remove one patch," you re-run patch with that patch deselected — the tree is rebuilt from pristine with the remaining set.
- **Selective reverse-patch** (revert one patch in place, leave the rest) is a stretch goal and may be impractical once patches have stacked and shifted each other's line numbers. Deferred.

### 7.2 Pristine source (LOCKED — v1)

Keep local pristine snapshots in `WORK_DIR` (as `wpatch.sh` does), captured before first patch, keyed by slug+version+sha. Reliable and offline; works for abandoned/custom plugins that aren't on wordpress.org. **Later** (not v1): add a fallback that re-fetches a hosted plugin via `wp plugin install --version=X --force` when no local snapshot exists.

### 7.3 Themes (LOCKED — deferred)

Plugins first; themes added once the model is proven (they share the component model, so retrofitting is cheap). **When revisited, scope to parent / non-child themes only.** Child themes across the fleet use generic slugs like `astra-child` / `kadence-child` rather than site-unique ones — a patch keyed by slug+version would mis-target the wrong site's child theme, so child themes are out of scope for safe patching. Parent themes (`astra`, `kadence`, …) have proper unique slugs + versions and are candidates.

---

## 8. Open decisions

Resolved 2026-05-28: marker placement (single ledger, §4.1), revert model (full-unpatch v1, §7.1), pristine source (local snapshots, §7.2), themes (deferred, §7.3).

Remaining:

1. **Subscriber config format** — draft uses **TOML** (§6.3). Low-stakes; could be YAML or JSON. Defaulting to TOML unless you'd prefer otherwise.
2. **Ledger placement when the main file isn't obvious** — most plugins have a clear main entry file (matching the plugin header), but edge cases (mu-plugins, single-file plugins, unusual headers) need a deterministic rule for *which* file gets the ledger. Resolve during M2.

---

## 9. Deliberately out of scope (for now)

- Selective per-patch reverse-revert.
- A registry/discovery service for repos (subscribers add repo URLs manually).
- Signing/trust beyond per-file checksums (sha256 in the manifest). PGP-signed manifests could come later.
- GUI / web dashboard.
