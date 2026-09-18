# CrossDrop — repo guide

This repository hosts a **single plugin** — the CrossDrop KOReader plugin: a
three-tab dashboard (Connections / Send A File / Delete Files) that sends
files to Xteink/CrossPoint e-ink readers over Wi-Fi (the reader's File
Transfer / WebDAV server). It is not a firmware fork and builds no reader
image.

## Layout

- `koreader-plugin/crossdrop.koplugin/` — the KOReader plugin.
- `koreader-plugin/test/harness_crossdrop.lua` — pure-Lua smoke test
  (harness against stubs — no device needed).
- `screenshots/` — on-device screenshots shown in the README.
- `scripts/build-zip.sh` — builds `releases/CrossDrop-Plugin.zip`.
- `.github/workflows/build.yml` — `luajit -bl` each Lua file, run the harness,
  build the zip on every push/PR.

## Dev workflow

- **Verification:** run `luajit koreader-plugin/test/harness_crossdrop.lua`.
  Also `luajit -bl` any changed Lua file to syntax-check.
- **The koplugin must keep loading lazily:** plugin modules (main.lua and the
  `crossdrop_*` siblings) must not `require` KOReader widgets at module load.
  The harness guards this.
- **Releases are ADDITIVE** (the Storefront way): ship each version as a NEW
  GitHub release with `CrossDrop-Plugin.zip` attached (built by
  `scripts/build-zip.sh`; the zip carries `crossdrop.koplugin/` at its root
  with `_meta.lua`). Never delete old releases — Storefront's Versions tab
  shows the full release history, its update tracking compares the
  installed version against the latest release, and the catalog builder
  reads up to 10 releases per repo. The repo carries the `koreader-plugin`
  topic — the Storefront catalog builder discovers it by that topic and
  installs from the release zip, so never ship a release without the zip.

## The system (as shipped)

- **File list = CrossPoint list.** The Send A File scan lists ONLY
  `epub / xtc / xtch / txt / bmp` (case-insensitive; real devices carry
  ".EPUB"). `isCrossPointFile` (main.lua) is the same list for the
  "Currently open" row. KOReader reads much more (mobi/pdf/fb2/…) — those
  never list, so nothing unopenable can be sent.
- **Trees.** The destination picker and the delete browser share one system:
  `new_node` trees, ▸/▾ inline expansion (fetch once via
  `GET /api/files?path=`, cached), boxless rows with hairline separators,
  paged rendering (rows-per-page measured from a real row), tiny centered
  confirmation popups (ConfirmBox recipe: fullscreen CenterContainer +
  small bordered frame + region-localized show/close), and a back chevron
  top-left (`left_icon = "chevron.left"`). ✕ appears ONLY on the home
  dashboard — it is the only thing that leaves the plugin.
- **Reader protocol facts** (device-verified, X3 firmware v1.6.0):
  - `GET /api/files` streams chunked and this KOReader's `socket.http`
    truncates multi-line bodies — `rawBody` does a raw-socket GET, splits
    headers, dechunks, and decodes within a socketutil budget.
  - Nested folders need every parent: MKCOL each `/`-prefix in order
    (201 = created, 405 = exists, 409 = a parent is missing).
  - **DELETE does NOT recurse** — a non-empty folder answers 409. The
    delete tab purges depth-first (fresh listings, files, then folders)
    and only then deletes the folder. Deletes are bounded to a 5s timeout
    and paint a "Deleting…" notice first (the paint-progress-then-block
    rule — every blocking call does this).
  - Deleting the current destination (or its parent) resets the
    destination to `CrossDropped Files`.
- **E-ink refresh discipline (the panel's own rules):**
  - In-place updates use `"ui"` — flashless AND never promoted. A bare
    `"partial"` is promoted to a flashing FULL every 6th refresh
    (`FULL_REFRESH_COUNT`), which reads as "random" flashing.
  - `"full"` only at real state transitions (opening the send flow's
    first file, done/failed) — those also reset the promotion counter.
  - Small popups refresh ONLY their box region (the third arg to
    `UIManager:show`/`close`).
  - Close→work chains defer with `UIManager:nextTick` (running them inside
    the tap handler froze the panel once).

## Non-negotiables

- No secrets, no tokens.
- Don't commit or push unless asked.

## UI patterns: always confirm against storefront / core first

Before shipping any widget/UI change, **verify the exact pattern exists and
works on the target device** — check the installed storefront plugin
(`/Volumes/Kindle/koreader/plugins/storefront.koplugin/`) or KOReader core
on the device (`/Volumes/Kindle/koreader/frontend/…`). If neither storefront
nor core does it that way, don't invent it.

Hard-won device lessons (KPW5SE, KOReader 2026.07.2):

- The dashboard's own widget set (Button rows on a full-screen white card,
  TitleBar) is the only chrome proven to render and take taps here. The
  built-in FileChooser/Menu chain is not used at all.
- **`HorizontalGroup` accepts only `top`/`center`/`bottom` (nil == top) and
  `VerticalGroup` only `left`/`center`/`right`** — anything else makes the
  widget log one line and paint NOTHING (the entire tree was invisible once
  from a stray `align = "left"` on a HorizontalGroup). The harness stub
  errors on invalid aligns; keep it that way.
- **`menu_style` on a Button force-sets `align = "left"`** in
  `Button:init()` — set the look explicitly (font face/size, `padding_h`,
  `align`, `text_font_bold`) instead of relying on it when centering matters.
- FrameContainer with no child crashes the panel — the harness errors on it.
- `Font:getFace("<name>")` without a size crashes for faces with no default
  in the sizemap — the harness mirrors this; stick to the known-safe faces.
- Anything that closes its container must set `allow_flash = false`
  (storefront's rule), or KOReader crashes on the destroyed widget.
- Never pass a `selected` option to Menu-derived widgets (FocusManager owns
  that field); the picker's picked set is named `picked`.
- `UIManager:replace` does not exist in this KOReader build — re-init the
  same widget in place instead.
- **WiFi only** — `configuredTargets()` returns exactly one `wifi` target
  whose `ip` is `""` until the user sets it (probe answers "not set").
