# CrossDrop (KOReader plugin)

A KOReader plugin that hands books to your **CrossDrop** reader over your local
network — no USB cable, no webserver on the Kindle. Pick any ebook with
KOReader's file browser (or send the currently open one) and it streams across
to the reader's own web server (port 80) — no custom firmware required.

## How it works

1. On the reader, open **File Transfer → Join Network**. That connects the
   reader to your Wi-Fi and makes it ready to receive — the reader's screen
   **shows its IP address** on that screen.
2. On the device with the book (Kindle / Android / etc.), open **Tools** in
    the main reader menu → **CrossDrop**. This opens a full-screen,
    Storefront-style dashboard with two tabs:
    - **Connections** — the two ways to reach the reader, each with its own
      stored IP:
      - **WiFi** — set it once via **Set WiFi IP...** to the address shown on
        the reader's **Join Network** screen.
      - **HotSpot** — for the reader's **Create Hotspot** mode, already filled
        with **192.168.4.1** (nothing to type).
    - Tap a connection to check it; CrossDrop shows whether it's reachable.
    - **Send** — tap **Send A Book...** to browse the filesystem with
      KOReader's own file browser and pick any ebook to send (no need to have
      it open first). If a book is already open it also appears here with a
      tap-to-send row. No destination to pick: **every book lands in the
      `CrossDropped Files` folder at the root of the reader's card**, created
      automatically on first send.
3. While sending, KOReader shows a live **CrossDrop progress dialog**: a
   percentage bar (bytes streamed / total), transfer speed and ETA, repainting
   the e-ink screen on every chunk. On completion a CrossDrop toast confirms
   and the book lands in `CrossDropped Files` on the reader's SD card.

There is no automatic discovery and no folder selection: you enter the
reader's WiFi IP once, and CrossDrop remembers it. If only the reader's
hotspot is available, the fixed **192.168.4.1** slot is already there — no
typing needed.

## Requirements

- **Reader:** any CrossPoint build with **File Transfer** (WebDAV on port 80).
  From the reader, open **File Transfer → Join Network**: the reader joins your
  Wi-Fi, shows its IP, and is ready to receive (or create its own hotspot and
  join that from the sender).
- **KOReader:** any recent build (the plugin uses LuaSocket, which KOReader
  bundles).

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
  WebDAV `MKCOL /CrossDropped%20Files` (201 = created, 405 = already exists).
  Verified against live firmware (X3, v1.6.0): MKCOL on a fresh path → 201,
  PUT into it → 201.
- Transfer: `PUT http://<ip>:<port>/CrossDropped%20Files/<url-encoded-filename>`
  with the raw file bytes in the body and a `Content-Length` header. Success
  is any 2xx. (Alternatively `POST /upload?path=<folder>` with multipart form
  data.)