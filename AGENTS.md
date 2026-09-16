# CrossDrop — repo guide

This repository hosts a **single plugin** — the CrossDrop KOReader sender
plugin. It is not a firmware fork and builds no reader image.

## Layout

- `koreader-plugin/crossdrop.koplugin/` — the KOReader sender plugin.
- `koreader-plugin/test/harness_crossdrop.lua` — pure-Lua smoke test.
- `scripts/build-zips.sh` — builds `releases/CrossDrop-Plugin.zip`.
- `.github/workflows/build.yml` — `luajit -bl` each Lua file, run the harness,
  build the zip.

## Dev workflow

- **Verification:** run `luajit koreader-plugin/test/harness_crossdrop.lua`
  (pure-Lua smoke test of the koplugin against stubs — no device needed).
  Also `luajit -bl` any changed Lua file to syntax-check.
- **The koplugin must keep loading lazily:** plugin modules (main.lua and the
  `crossdrop_*` siblings) must not `require` KOReader widgets at module load;
  widgets load via the `getWidgets()`/sibling-module pattern already in
  `main.lua`. The harness guards this.
- **Destination folder:** the Send A Book tab lists the reader's folders
  (`GET /api/files`, raw-socket fetch) or takes a typed name; nothing chosen ==
  `CrossDropped Files` (`DEFAULT_FOLDER` in `main.lua`). The chosen folder is
  MKCOL-created on the reader before each PUT (`ensureFolder`). Verified
  against live firmware (X3, v1.6.0): MKCOL on a fresh path → 201, PUT into
  it → 201, DELETE file then folder → 204/204.
  The reader streams `/api/files` with `Transfer-Encoding: chunked` in tiny
  chunks, and this build's `socket.http` truncates multi-line bodies to their
  first line — `listFolders` uses a raw-socket GET (`rawBody`) that splits
  headers, dechunks, and decodes the body within a socketutil time budget.

## Non-negotiables

- No secrets, no tokens.
- Don't commit or push unless asked.

## UI patterns: always confirm against storefront / core first

Before shipping any widget/UI change, **verify the exact pattern exists and
works on the target device** — check the installed storefront plugin
(`/Volumes/Kindle/koreader/plugins/storefront.koplugin/`) or KOReader core
on the device (`/Volumes/Kindle/koreader/frontend/…`). If neither storefront
nor core does it that way, don't invent it — find the closest proven pattern
and use that instead.

Hard-won device lessons (KPW5SE, KOReader 2026.07.2):
- **`custom_title_bar` NEVER rendered on this device** (v1.3.9–1.3.13): the
  picker's own TitleBar (left ✕ / right ✓ icons) was silently ignored by the
  BookList/Menu chain — the user only ever saw Menu's BUILT-IN title bar
  (centered title, ✕ top-right, subtitle = folder path), and no ✓ icon ever
  appeared. Don't pass `custom_title_bar` to FileChooser; use Menu's own bar.
- **The user-visible send action is the first row** of the picker's own
  dashboard-style list. The picker (crossdrop_picker.lua) does NOT use the
  built-in file browser at all: it scans the device for book files
  (bookshelf.koplugin's walk pattern — recursive lfs.dir, dot-entry skip,
  .sdr skip, EXCLUDED_DIRS, SUPPORTED_EXT filter), caches the result per
  open, and renders rows on the dashboard's widget set. Rows are the only
  picker element proven to render and tap on this device.
- **Research-backed patterns** (storefront catalog + installed plugins):
  localsend.koplugin (311★) picks files with core `PathChooser`
  (FileChooser subclass, Menu's own bar, `close_callback` on its ✕) —
  the built-in list itself does render/tap fine on this device; only
  custom chrome (custom_title_bar, icon slots) ever failed.
  bookshelf.koplugin (854★) scans libraries with a plain recursive
  lfs walk. When in doubt, check how those two do it.
- **File rows dim but lose hand-edited `text`** across navigations
  (`getListItem` regenerates `item.text` from the filename per folder
  change) — `item.dim` survives a rebuild, the ✓ prefix does not. Treat dim
  as the selection indicator; don't rely on edited row text persisting.
- Menu's built-in title-bar ✕ closes via the `close_callback` option
  (FileManager uses it) — wire exit-to-dashboard there.
- ConfirmBox/ButtonDialog buttons (`ok_text`, `ok_callback`) are proven —
  storefront uses the same mechanism for labeled buttons.
- Anything that closes its container must set `allow_flash = false`
  (storefront's rule), or KOReader crashes on the destroyed widget.
- Never pass a `selected` option to Menu-derived widgets (FocusManager owns
  that field — the 1.3.9 crash); the picker set is named `picked`.
- **WiFi only** — the reader's hotspot mode was dropped (never worked
  reliably); `configuredTargets()` returns exactly one `wifi` target whose
  `ip` is `""` until the user sets it (probe answers "not set").