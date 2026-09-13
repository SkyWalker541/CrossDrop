# CrossDrop — repo guide

This repository is a set of **plugins only** — one for CrossPoint readers and
one for KOReader. It is not a firmware fork.

## Layout

- `crosspoint-plugin/crossdrop/` — native CrossPoint plugin (setup guide).
  Ships with `device.json`, `manifest.json`, `README.md`. Install by copying
  this folder to the reader SD as `/plugins/crossdrop/`.
- `koreader-plugin/crossdrop.koplugin/` — KOReader sender plugin.
- `hosted/crossdrop/guide-1.json` — the live on-device list (a single
  "Download instructions (TXT)" item), fetched by the reader from
  `raw.githubusercontent.com` (see `device.json` → `browse.url`).
- `hosted/crossdrop/instructions.txt` — the whole setup guide in one TXT
  file; tapping the catalog item downloads it into the fixed
  `CrossDropped Files` folder (`device.json` → `download`).
- `scripts/build-zips.sh` — builds `releases/CrossDrop-SD-Plugin.zip` and
  `releases/CrossDrop-Plugin.zip`.
- `.github/workflows/build.yml` — validate JSON, `luajit -bl` each Lua file,
  run the harness, build zips.

## Dev workflow

- **Verification:** run `luajit koreader-plugin/test/harness_crossdrop.lua`
  (pure-Lua smoke test of the koplugin against stubs — no device needed).
  Also `luajit -bl` any changed Lua file to syntax-check.
- **The koplugin must keep loading lazily:** plugin modules (main.lua and the
  `crossdrop_*` siblings) must not `require` KOReader widgets at module load;
  widgets load via the `getWidgets()`/sibling-module pattern already in
  `main.lua`. The harness guards this.
- **Guide contract:** `device.json` boots a catalog screen from
  `browse.url`. The catalog lists one item ("Download instructions (TXT)");
  the step text lives in `hosted/crossdrop/instructions.txt`, downloaded on
  tap via `device.json` → `download` into the fixed `CrossDropped Files`
  folder at the card root. If the guide outgrows a page, split as before with
  ≤ `page_size` items per page file (`guide-1.json`, then `guide-2.json`,
  …). Firmware caps: `device.json` < 8 KB, `page_size` ≤ 16, browse response
  ≤ 1 MB.
- **Fixed destination:** the koplugin has NO folder picker. Every book (and
  the downloaded guide) goes to `/CrossDropped Files` on the reader
  (`DEFAULT_FOLDER` in `main.lua`, `dest_dir` in `device.json`). Keep both
  names in sync; auto-create on the reader via MKCOL before each PUT.
- **Plugin list row:** title "CrossDrop" with a short one-line description
  ("Tap to download setup instructions (TXT file).") in `manifest.json`/
  `device.json`.

## Non-negotiables

- CrossPoint **beta** firmware (SD Plugins track) is required for the reader
  side; keep that stated in the READMEs and guide.
- No secrets, no tokens, no hosting outside this repo for the guide.
- Don't commit or push unless asked.

## UI patterns: always confirm against storefront / core first

Before shipping any widget/UI change, **verify the exact pattern exists and
works on the target device** — check the installed storefront plugin
(`/Volumes/Kindle/koreader/plugins/storefront.koplugin/`) or KOReader core
on the device (`/Volumes/Kindle/koreader/frontend/…`). If neither storefront
nor core does it that way, don't invent it — find the closest proven pattern
and use that instead. (Lesson: a hand-rolled text Button appended into the
TitleBar OverlapGroup post-init painted over the ✕ and never received taps
on-device — 1.3.11, reverted in 1.3.12 to the FileManager-style
`right_icon` + `setRightIcon` swap.)

Proven patterns used by this plugin:
- TitleBar icon slots (`left_icon`/`right_icon` + `*_tap_callback`,
  `allow_flash = false`) — FileManager's select mode does the
  `setRightIcon("plus" ↔ "check")` swap on this exact build.
- ConfirmBox/ButtonDialog buttons (`ok_text`, `ok_callback`) — storefront
  uses the same mechanism for labeled buttons.
- Anything that closes its container must set `allow_flash = false`
  (storefront's rule), or KOReader crashes on the destroyed widget.
- Never pass a `selected` option to Menu-derived widgets (FocusManager
  owns that field — the 1.3.9 crash); the picker set is named `picked`.