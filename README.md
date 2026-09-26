<p align="center">
  <img src="logo.png" width="160" alt="CrossDrop" />
</p>

# CrossDrop

Send books from **KOReader** to your **Xteink (CrossPoint)** e-ink reader over
Wi-Fi — no cable, no cloud.

📦 **Also available in the Storefront plugin** — open Tools → Storefront, search "CrossDrop", and tap Install. No manual file copying needed.

## What it does

- A full-screen CrossDrop dashboard (**Connections** / **Send A File** /
  **Collections** / **Delete Files**) inside KOReader's Tools menu.
- **Send A File** scans your device and lists only what the reader can
  actually open — **EPUB, XTC/XTCH, TXT, and BMP** (case-insensitive): search
  and multi-pick from the list, or send the file you're currently reading.
- **Collections** tab: create named collections, add/remove books, send a
  whole collection at once.
- **Delete Files** is its own tab on purpose: deleting never lives among the
  send controls. It browses the reader as the same folder tree (files and
  folders), asks **"Delete file?"** / **"Delete folder and its contents?"**
  first, then removes it — a folder that still holds anything is purged
  depth-first first (the reader's WebDAV DELETE does not recurse), and the
  tree refreshes in place.
- **Instructions** page: step-by-step setup guide accessible from the
  Connections tab, with a back button to return.
- **visibleTextOffset sync**: precise read-position restore on the reader
  using the same ParagraphStreamer logic as CrossPoint's KoSync (spine +
  visibleTextOffset in progress.bin).
- A "… please wait" screen while a file streams, and a toast when it lands.
  There's deliberately no progress bar: the transfer drains faster than
  e-ink can repaint.

## Screenshots

### The four tabs of the dashboard:

| **Connections** — set the reader's IP, check it reads Reachable | **Send A File** — pick files and the destination folder |
|:---:|:---:|
| <img src="koreader-plugin/crossdrop.koplugin/assets/Connections Tab.png" width="320" alt="The Connections tab: WiFi row, Set WiFi IP, Stored Devices, Instructions button" /> | <img src="koreader-plugin/crossdrop.koplugin/assets/Send A File Tab.png" width="320" alt="The Send A File tab: file list, search, destination folder row" /> |

| **Collections** — create, manage, and send collections | **Delete Files** — its own screen, away from the send controls |
|:---:|:---:|
| <img src="koreader-plugin/crossdrop.koplugin/assets/Collections Tab.png" width="320" alt="The Collections tab: create, view, edit, send collections" /> | <img src="koreader-plugin/crossdrop.koplugin/assets/Delete Files Tab.png" width="320" alt="The Delete Files tab: folder tree, files inline, paged" /> |

## Setup

1. On the reader: open **File Transfer → Join Network** — it shows its IP
   address.
2. On your device, copy `crossdrop.koplugin/` into KOReader's `plugins/`
   folder and restart KOReader — or install straight from **Storefront**
   (search "CrossDrop").
3. Open **Tools → CrossDrop → Connections → Set WiFi IP…** and enter the
   reader's IP. Tap the **WiFi** row to check it reads **Reachable**.
4. Use the **Send A File** tab to pick files and choose a destination folder.

## What's new in 2.0.0

- **Instructions page** — dedicated guide with scrollable text and back button
- **visibleTextOffset sync** — precise read-position restore using the same
  ParagraphStreamer logic as CrossPoint's KoSync
- **4-tab dashboard** — Connections, Send A File, Collections, Delete Files
- **Collections tab** — create, manage, and send named collections
- **Row label update**: "Set WiFi IP (may change)" clarifies dynamic vs fixed IP
- **Guide text updated** — Steps 4 & 7 distinguish dynamic IP vs router-fixed Stored Devices
- **Scrollable Instructions page** — no more overflow on small screens
- **Widget dedup** — shared `crossdrop_widgets.lua` for separator/caption/menuRow
- **Deduped position sync** — single `maybeSyncPosition()` method
- **Lua scoping fix** — `visibleModule()` declared before use
- All 470 tests pass, byte-identical deployments

## Build & test

```sh
./scripts/build-zip.sh             # → releases/CrossDrop-Plugin.zip
luajit koreader-plugin/test/harness_crossdrop.lua
```

See `AGENTS.md` for repo conventions. GitHub Actions checks the Lua, runs the
harness, and builds the zip on each push/PR.