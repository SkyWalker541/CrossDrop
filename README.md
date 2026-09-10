# CrossDrop

A **set of two plugins** that send the book you're reading from **KOReader** to
a **CrossPoint** e‑ink reader (Xteink X3/X4) over your Wi‑Fi network — no USB
cable, no cloud.

This repository is **not a firmware fork** and does not build a reader image.
It contains exactly two plugins:

| Plugin | Where it lives | What it does |
|---|---|---|
| **KOReader plugin** | `koreader-plugin/crossdrop.koplugin/` | The sender side. **Tools** (main reader menu) → **CrossDrop** opens a full-screen Storefront-style dashboard (Connections / Send / History) on any KOReader device (Kindle, Android, …). Sends the currently open book over Wi-Fi; every book lands in the reader's fixed **`CrossDropped Files`** folder — nothing to configure. |
| **CrossPoint plugin** | `crosspoint-plugin/crossdrop/` | The reader side. A **native setup guide** shown under **Settings → System → Plugins → CrossDrop**, rendered on the e‑ink screen. It pulls its steps live from this repo (`hosted/crossdrop/guide-1.json`), and tapping its single item downloads the whole guide to `CrossDropped Files`. |

## Requirements — CrossPoint beta firmware

The CrossPoint plugin **requires an official CrossPoint *beta* build with SD
plugin support** — the "SD Plugins Beta" track (for example the beta builds
for the Xteink X3/X4; support first landed on the beta track). It will **not
load on CrossPoint stable/non‑beta builds**, which don't include the plugin
platform. The reader also needs its built-in **File Transfer**
(WebDAV on port 80) which plugin-enabled briefs all have.

The KOReader side needs any recent KOReader build (LuaSocket is bundled).

## Layout

```
README.md                this file (what these plugins are)
AGENTS.md                contributor / agent instructions
LICENSE
hosted/                  GitHub-hosted live content
  crossdrop/guide-1.json     the on-device guide steps (pulled by the reader)
crosspoint-plugin/       CrossPoint reader-side plugin
  crossdrop/                 ← copy this folder to the reader's SD card
    device.json              native screen + GitHub URL of the guide
    manifest.json            plugin metadata (Settings → System → Plugins row)
    README.md
koreader-plugin/         KOReader sender-side plugin
  crossdrop.koplugin/        ← copy this folder into KOReader's plugins/
  test/harness_crossdrop.lua        pure-Lua smoke test (no device needed)
scripts/
  build-zips.sh           builds the two installable zips into releases/
releases/                built zips (gitignored; attach to GitHub Releases)
```

## Install

**On the reader (CrossPoint):** copy the `crossdrop/` folder to the SD card as
`/plugins/crossdrop/` (or `/.crosspoint/plugins/crossdrop/`), reboot, then open
**Settings → System → Plugins → CrossDrop**. Opening it downloads the guide
from `hosted/crossdrop/guide-1.json` — the reader must be online for the
guide to load (File Transfer itself works offline).

**On the sender (KOReader):** copy the `crossdrop.koplugin/` folder into the
KOReader device's `koreader/plugins/`, restart KOReader, open **Tools** in the
main reader menu → **CrossDrop** → **Connections → Set WiFi IP...**, type the reader's IP (shown
on the reader's **File Transfer → Join Network** screen), then go to the
**Send** tab and tap the book. It lands in `CrossDropped Files` on the
reader's card.

## Updating the on-device guide

Edit `hosted/crossdrop/guide-1.json` and push to `main`. Readers pull the new
steps the next time the plugin is opened — no reinstall.

## Build & test

```sh
./scripts/build-zips.sh            # → releases/CrossDrop-SD-Plugin.zip, CrossDrop-Plugin.zip
luajit koreader-plugin/test/harness_crossdrop.lua   # smoke-test the KOReader plugin
```

GitHub Actions validates the JSON, syntax-checks the Lua, runs the harness,
and builds both zips on every push/PR.

## Notes and limits

- The reader-side plugin is **native** (`device.json`): there is deliberately
  no `plugin.js`, so it never shows a browser/web-only screen.
- The guide is a static, pre-paginated catalog (≤ the `page_size` items from
  `device.json` per page). Add more pages as `guide-2.json`, `guide-3.json`,
  … so the pager resolves.
- Transfers go directly device-to-device (WebDAV PUT). Nothing about the
  actual book transfer goes through this repository or GitHub.