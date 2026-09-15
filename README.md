# CrossDrop

Send books from **KOReader** to your **Xteink (CrossPoint)** e-ink reader over
Wi-Fi — no cable, no cloud.

## What it does

- A full-screen CrossDrop dashboard (**Connections** / **Send A Book**) inside
  KOReader's Tools menu.
- Send any ebook, or the book you're currently reading.
- Books land in the reader's `CrossDropped Files` folder, created automatically
  on the first send (WebDAV MKCOL).

## Setup

1. On the reader: open **File Transfer → Join Network** — it shows its IP
   address.
2. On your device, copy `crossdrop.koplugin/` into KOReader's `plugins/`
   folder and restart KOReader.
3. Open **Tools → CrossDrop → Connections → Set WiFi IP…** and enter the
   reader's IP.
4. Use the **Send A Book** tab to send.

## Build & test

```sh
./scripts/build-zips.sh            # → releases/CrossDrop-Plugin.zip
luajit koreader-plugin/test/harness_crossdrop.lua
```

See `AGENTS.md` for repo conventions. GitHub Actions checks the Lua, runs the
harness, and builds the zip on each push/PR.