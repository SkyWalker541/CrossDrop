<p align="center">
  <img src="logo.png" width="160" alt="CrossDrop" />
</p>

# CrossDrop

Send books from **KOReader** to your **Xteink (CrossPoint)** e-ink reader over
Wi-Fi — no cable, no cloud.

## What it does

- A full-screen CrossDrop dashboard (**Connections** / **Send A Book**) inside
  KOReader's Tools menu.
- **Send A Book** scans your device for books: search and multi-pick from the
  list, or send the book you're currently reading.
- Books land in a **destination folder** on the reader. The destination picker
  is a folder **tree**: tap a folder's ▸/▾ to scan its subfolders — they appear
  indented right below it, and every other folder stays visible; tap a folder's
  name for **Select / Create Subfolder / Cancel**. A new subfolder is picked
  right away and is created on the reader when the books are sent (WebDAV
  MKCOL, at any nesting depth). Nothing chosen = the **CrossDropped Files**
  default, created automatically on the first send.
- A "… please wait" screen while a book streams, and a toast when it lands.
  There's deliberately no progress bar: the transfer drains faster than
  e-ink can repaint.

## Setup

1. On the reader: open **File Transfer → Join Network** — it shows its IP
   address.
2. On your device, copy `crossdrop.koplugin/` into KOReader's `plugins/`
   folder and restart KOReader.
3. Open **Tools → CrossDrop → Connections → Set WiFi IP…** and enter the
   reader's IP. Tap the **WiFi** row to check it reads **Reachable**.
4. Use the **Send A Book** tab to pick books and choose a destination folder.

## Build & test

```sh
./scripts/build-zips.sh            # → releases/CrossDrop-Plugin.zip
luajit koreader-plugin/test/harness_crossdrop.lua
```

See `AGENTS.md` for repo conventions. GitHub Actions checks the Lua, runs the
harness, and builds the zip on each push/PR.