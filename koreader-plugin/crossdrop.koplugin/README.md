# CrossDrop (KOReader plugin)

A KOReader plugin that hands the **currently open book** to your **CrossDrop**
reader over your local network — no USB cable, no webserver on the Kindle. It
talks only to the reader's built-in web server (port 80) — no custom firmware
required.

## How it works

1. On the reader, open **File Transfer → Join Network**. That connects the
   reader to your Wi-Fi and makes it ready to receive — the reader's screen
   **shows its IP address** on that screen.
2. On the device with the book (Kindle / Android / etc.), open the book in
   KOReader, then open **Tools** in the main reader menu → **CrossDrop**. This
   opens a full-screen, Storefront-style dashboard with three tabs:
   - **Connections** — the two ways to reach the reader, each with its own
     stored IP:
     - **WiFi** — set it once via **Set WiFi IP...** to the address shown on
       the reader's **Join Network** screen.
     - **HotSpot** — for the reader's **Create Hotspot** mode, already filled
       with **192.168.4.1** (nothing to type).
   - Tap a connection to check it; CrossDrop shows whether it's reachable.
   - **Send** — tap the book shown under "Now open" to stream it across. No
     destination to pick: **every book lands in the `CrossDropped Files`
     folder at the root of the reader's card**, created automatically on
     first send.
   - **History** — logs every successful send (connection, IP, size, time,
     most recent first); tap an entry to send again.
3. While sending, KOReader shows a live **CrossDrop progress dialog**: a
   percentage bar (bytes streamed / total), transfer speed and ETA, repainting
   the e-ink screen on every chunk. On completion a CrossDrop toast confirms
   and the book lands in `CrossDropped Files` on the reader's SD card.

There is no automatic discovery and no folder selection: you enter the
reader's WiFi IP once, and CrossDrop remembers it. If only the reader's
hotspot is available, the fixed **192.168.4.1** slot is already there — no
typing needed.

## Requirements

- **Reader:** a **CrossPoint *beta* build with SD plugin support** (the "SD
  Plugins Beta" track, e.g. the Xteink X3/X4 beta builds). CrossPoint's
  stable builds don't include the plugin platform. The plugin talks to the
  reader's standard web server on port 80, so all that's needed on the reader
  is **File Transfer** — open **File Transfer → Join Network**: the reader
  joins your Wi-Fi, shows its IP, and is ready to receive (or create its own
  hotspot and join that from the sender).
- **KOReader:** any recent build (the plugin uses LuaSocket, which KOReader
  bundles).
- **Optional companion:** the **CrossDrop CrossPoint plugin** (folder
  `crossdrop/` on the reader's SD card under `/plugins/`) adds a
  **Settings → System → Plugins → CrossDrop** screen rendered natively on the
  e-ink display. It does **not** handle transfers — it's the step-by-step
  setup guide that tells you how to install this KOReader plugin and pair the
  two sides. Sending works without it on any File Transfer build.

## Install

Copy this folder into KOReader's plugins directory, then restart KOReader:

```sh
cp -r crossdrop.koplugin /path/to/koreader/plugins/
# e.g. on a Kindle with KOReader installed at /mnt/us/koreader:
#   cp -r ./*.koplugin /mnt/us/koreader/plugins/
```

## Troubleshooting

- **Connection shows "Offline"** — open the reader's Join Network screen,
  note the IP, and fix it via **Connections → Set WiFi IP...**. The reader
  must still be on **File Transfer → Join Network** and on the same network.
- **Send fails** — confirm the WiFi IP matches the Join Network screen and
  both devices are on the same network (or the sender joined the reader's
  hotspot). Use **Send → Check device...** to test connectivity first.
- **Reader on its own hotspot** — join that network from the sender; the
  **HotSpot** connection is already set to **192.168.4.1**.
- **New router IP** — the router's DHCP may give the reader a new address;
  just update **Connections → Set WiFi IP...**.

## Protocol (for other clients)

- The reader's web server listens on port **80**. Its IP + status are available
  at `GET /api/status`.
- Destination folder: `CrossDropped Files` at the card root, ensured with
  WebDAV `MKCOL /CrossDropped%20Files` (405 = already exists). CrossPoint's
  own firmware may also auto-create it on PUT.
- Transfer: `PUT http://<ip>:<port>/CrossDropped%20Files/<url-encoded-filename>`
  with the raw file bytes in the body and a `Content-Length` header. Success
  is any 2xx. (Alternatively `POST /upload?path=<folder>` with multipart form
  data.)