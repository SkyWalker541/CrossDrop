# CrossDrop — repo guide

This repository is a set of **plugins only** — one for CrossPoint readers and
one for KOReader. It is not a firmware fork.

## Layout

- `crosspoint-plugin/crossdrop/` — native CrossPoint plugin (setup guide).
  Ships with `device.json`, `manifest.json`, `README.md`. Install by copying
  this folder to the reader SD as `/plugins/crossdrop/`.
- `koreader-plugin/crossdrop.koplugin/` — KOReader sender plugin.
- `hosted/crossdrop/guide-1.json` — the live on-device guide, fetched by the
  reader from `raw.githubusercontent.com` (see `device.json` → `browse.url`).
- `hosted/crossdrop/steps/{id}.txt` — per-step text files; tapping a step
  downloads its file to `/Books` (`device.json` → `download`). Keep one txt
  per item id in `guide-1.json`.
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
  `browse.url`. List rows are one-line short titles (`title` only — no
  `subtitle`/`author` clutter); the step's full text goes in
  `hosted/crossdrop/steps/{id}.txt`, downloaded on tap via `device.json` →
  `download` (`{id}` → `CrossDrop-<id>.txt` in `/Books`). Keep one txt per
  item id in the per-page JSON. Paging is URL-driven: keep ≤ `page_size`
  items per page file (`guide-1.json`, then `guide-2.json`, …). Firmware
  caps: `device.json` < 8 KB, `page_size` ≤ 16, browse response ≤ 1 MB.
- **Plugin list row:** keep the Plugins-menu title just "CrossDrop" —
  no long description in `manifest.json`/`device.json`.

## Non-negotiables

- CrossPoint **beta** firmware (SD Plugins track) is required for the reader
  side; keep that stated in the READMEs and guide.
- No secrets, no tokens, no hosting outside this repo for the guide.
- Don't commit or push unless asked.