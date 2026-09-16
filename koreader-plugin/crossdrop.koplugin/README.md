# CrossDrop (KOReader plugin)

A KOReader plugin that hands books to your **Xteink** reader over your local
network — no cable, no cloud. It talks to the reader's built-in web server
(port 80) via WebDAV, so no custom firmware is required.

## How it works

1. On the reader, open **File Transfer → Join Network**. The reader joins your
   Wi-Fi and shows its IP address on that screen.
2. On the device with the books (Kindle / Android / etc.), open **Tools →
   CrossDrop**. This opens a full-screen, Storefront-style dashboard with two
   tabs:
   - **Connections** — the reader's WiFi address. Set it once with
     **Set WiFi IP…**, then tap the **WiFi** row to check the connection (it
     reads **Reachable** when the reader is answering).
   - **Send A Book** — a device-wide book picker (search + multi-select)
     rendered on the dashboard's own widget set; the top row sends. If a book
     is already open it also appears under **Currently open** as a tap-to-send
     row. A **Destination folder** row picks where books land: choose from the
     reader's folders or type a name. Nothing chosen == **CrossDropped Files**,
     created automatically on the first send.
3. While a book streams, the dashboard shows a **"… please wait"** screen, then
   a toast confirms the book landed. There is deliberately no progress bar:
   the transfer drains into the TCP buffers faster than e-ink can repaint.

Wi-Fi is the only connection mode. The reader's "Create Hotspot" mode was
dropped — it never worked reliably.

## Requirements

- **Reader:** an Xteink/CrossPoint build with **File Transfer** (WebDAV on
  port 80). Open **File Transfer → Join Network**: the reader joins your Wi-Fi,
  shows its IP, and is ready to receive.
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

- **WiFi row reads "Offline"** — open the reader's **File Transfer → Join
  Network** screen, note the IP, and fix it via **Connections → Set WiFi IP…**.
  The reader must still be on that screen and both devices on the same network.
- **Send fails** — confirm the WiFi IP matches the Join Network screen and
  both devices are on the same Wi-Fi, then try again. Failures show the
  reason on the Send tab.
- **New router IP** — DHCP may give the reader a new address; just update
  **Connections → Set WiFi IP…**.

## Protocol (for other clients)

- The reader's web server listens on port **80**.
- `GET /api/status` — device info + connection test.
- `GET /api/files` — JSON list of folders on the reader (the destination
  picker's source).
- Destination folder: `CrossDropped Files` by default at the card root,
  ensured with WebDAV `MKCOL` (201 = created, 405 = already exists). Verified
  against live firmware (X3, v1.6.0): MKCOL on a fresh path → 201, PUT into
  it → 201.
- Transfer: `PUT http://<ip>:<port>/<url-encoded-folder>/<url-encoded-filename>`
  with the raw file bytes in the body and a `Content-Length` header. Success
  is any 2xx. (Alternatively `POST /upload?path=<folder>` with multipart form
  data.)