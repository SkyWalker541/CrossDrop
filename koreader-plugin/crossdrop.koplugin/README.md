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
   KOReader, then use the **gear menu (main reader menu) → CrossDrop**:
   - **CrossDrop home...** — the full-screen dashboard with **Devices**,
     **Send** and **History** tabs.
   - **Device IP...** — type the reader's IP (from the Join Network screen).
     Saved for next time.
   - **CrossDrop hotspot (192.168.4.1)** — one tap when the Kindle is joined to
     the reader's **own hotspot** (AP mode); saves the address and immediately
     tests the connection.
   - **Send current book** — streams the open book to the saved device.
   - **Destination folder...** — browse the reader's folders over the network
     and pick where the book goes (default `/Books`). You can also create a new
     folder from that screen.
   - **Check device...** — asks the reader `GET /api/status` and shows its
     model, version, mode and IP as a connection test.
   - **Sent books...** — logs every successful send (reader, destination
     folder, size, time, most recent first). Clear it from that screen.
   - **Saved devices** — every address used is listed here for one-tap sending.
     **Long-press** a saved address to forget it, or use **Delete all stored
     devices** to clear the list.
3. While sending, KOReader shows a live **CrossDrop progress dialog**: a
   percentage bar (bytes streamed / total), transfer speed and ETA, repainting
   the e-ink screen on every chunk. On completion a CrossDrop toast confirms and
   the book lands in the chosen folder on the reader's SD card. If the folder
   did not exist, CrossDrop creates it automatically (`MKCOL`) — no manual setup
   on the reader.

There is no automatic discovery: you enter the reader's IP once (from the Join
Network / hotspot screen), and CrossDrop remembers it. When the reader is its
own hotspot it is always at **192.168.4.1**, so the dedicated **CrossDrop
hotspot** entry needs nothing typed at all.

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

- **"No device configured"** — open the reader's Join Network screen, note the
  IP, and enter it via **CrossDrop → Device IP...**.
- **"Send failed"** — confirm the IP/port in Device IP... matches the address
  on the reader's screen, and that the reader is still on **File Transfer →
  Join Network** and on the same network. Use **CrossDrop → Check device...** to
  test connectivity first. On the reader's **hotspot**, pick **CrossDrop
  hotspot (192.168.4.1)** — the Kindle must be connected to that hotspot.
- **Folder can't be listed** — the folder picker falls back gracefully: you can
  still pick the path, and the send step creates it via `MKCOL` if it's missing.
- **Stale saved address** — if the reader gets a new IP (router DHCP),
  long-press the old address in CrossDrop to forget it and enter the new one.

## Protocol (for other clients)

- The reader's web server listens on port **80**. Its IP + status are available
  at `GET /api/status`; folder contents at `GET /api/files?path=<path>`.
- Destination folder: ensured with WebDAV `MKCOL /<folder>` (405 = already
  exists) — or by CrossDrop's own firmware which auto-creates it on PUT.
- Transfer: `PUT http://<ip>:<port>/<folder>/<url-encoded-filename>` with the
  raw file bytes in the body and a `Content-Length` header. Success is any 2xx.
  (Alternatively `POST /upload?path=<folder>` with multipart form data.)