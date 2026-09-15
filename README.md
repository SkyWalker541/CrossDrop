# CrossDrop

A **KOReader plugin** that sends books from **KOReader** to a **CrossPoint**
e-ink reader (Xteink X3/X4) over your Wi-Fi network — no USB cable, no cloud.

This repository is **not a firmware fork** and does not build a reader image.
It contains one plugin: `koreader-plugin/crossdrop.koplugin/` — the sender
side. **Tools** (main reader menu) → **CrossDrop** on any KOReader device
(Kindle, Android, …) opens a full-screen, Storefront-style dashboard
(Connections / Send A Book). Send any ebook, or the currently open book, over
Wi-Fi; every book lands in the reader's fixed **`CrossDropped Files`** folder,
which the plugin creates automatically on first send (WebDAV MKCOL), so there
is nothing to configure.

## Requirements

- **Reader:** any CrossPoint build with **File Transfer** (WebDAV on port 80).
  From the reader, open **File Transfer → Join Network** — it shows its IP
  address and is ready to receive.
- **KOReader:** any recent build (LuaSocket is bundled).

## Layout

```
README.md                this file
AGENTS.md                contributor / agent instructions
LICENSE
koreader-plugin/         KOReader sender-side plugin
  crossdrop.koplugin/        ← copy this folder into KOReader's plugins/
  test/harness_crossdrop.lua        pure-Lua smoke test (no device needed)
scripts/
  build-zips.sh           builds CrossDrop-Plugin.zip into releases/
releases/                built zip (gitignored; attach to GitHub Releases)
```

## Install

Copy the `crossdrop.koplugin/` folder into the KOReader device's
`koreader/plugins/`, restart KOReader, then open **Tools** in the main reader
menu → **CrossDrop** → **Connections → Set WiFi IP…**, type the reader's IP
(shown on the reader's **File Transfer → Join Network** screen), and use the
**Send A Book** tab to send. Books land in `CrossDropped Files` on the
reader's card.

## Build & test

```sh
./scripts/build-zips.sh            # → releases/CrossDrop-Plugin.zip
luajit koreader-plugin/test/harness_crossdrop.lua   # smoke-test the plugin
```

GitHub Actions syntax-checks the Lua, runs the harness, and builds the zip on
every push/PR.

## Notes and limits

- CrossDrop is **not a firmware fork** and builds no reader image. The plugin
  talks directly to the reader's built-in **File Transfer** (WebDAV MKCOL +
  PUT) on port 80, so nothing about transfers passes through GitHub.
- The setup guide lives **inside the app** (Connections tab) — there is no
  companion plugin on the reader side.