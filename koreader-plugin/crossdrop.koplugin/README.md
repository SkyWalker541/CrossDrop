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
    - **Send A File** — a device-wide file picker (search + multi-select)
      rendered on the dashboard's own widget set; the top row sends. It lists
      ONLY what the reader can open — **EPUB, XTC/XTCH, TXT, BMP**
      (case-insensitive) — so nothing unopenable can be sent. If a compatible
      file is already open it also appears under **Currently open** as a
      tap-to-send row. A **Destination folder** row opens a folder **tree**:
      tap a folder's ▸/▾ to scan its subfolders — they appear indented right
      below it, with every other folder still visible — and tap a folder's
      name for **Select / Create Subfolder / Cancel**. A new subfolder is
      picked right away and is created on the reader when the files are sent.
      Nothing chosen == **CrossDropped Files**, created automatically on the
      first send.
    - **Delete Files** — its own tab, on purpose: deleting is kept apart from
      the send controls. It browses the reader in the same folder **tree**
      (files and folders, expandable, paged), asks
      **"Delete file?"** or **"Delete folder and its contents?"** on a small
      popup before anything dies, then deletes over WebDAV. A folder that
      still holds anything is purged depth-first first (the reader's DELETE
      does not recurse), and the tree refreshes in place.
3. While a file streams, the dashboard shows a **"… please wait"** screen, then
   a toast confirms the file landed. There is deliberately no progress bar:
   the transfer drains into the TCP buffers faster than e-ink can repaint.

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
  tree's root listing). `GET /api/files?path=<folder>` lists the subfolders
  nested inside `<folder>` — the tree scans one level at a time as folders
  are opened, at any nesting depth. Each entry carries `name`, `size`, and
  `isDirectory` (the delete tab's tree lists files too).
- Deleting: `DELETE http://<ip>:<port>/<url-encoded-path>` — **204** on
  success, **409 when the folder is not empty** (this reader's DELETE does
  NOT recurse, so a non-empty folder is purged depth-first by the client:
  list the children, delete files, recurse into folders, then the folder).
  Deleting the folder that is the current send destination resets it to
  **CrossDropped Files**.
- Destination folder: `CrossDropped Files` by default at the card root,
  ensured with WebDAV `MKCOL` (201 = created, 405 = already exists). Nested
  destinations (`Books/Fiction/Shelf`) are created level by level — every
  parent prefix is MKCOL'd in order before the first send into them (a fresh
  deep path returns 201s; 409 means a parent is missing). Verified against
  live firmware (X3, v1.6.0): MKCOL on a fresh path → 201, PUT into it →
  201.
- Transfer: `PUT http://<ip>:<port>/<url-encoded-folder>/<url-encoded-filename>`
  with the raw file bytes in the body and a `Content-Length` header. Success
  is any 2xx. (Alternatively `POST /upload?path=<folder>` with multipart form
  data.)
- Files the reader can open: **EPUB** (2/3), **XTC/XTCH**, **TXT**, **BMP** —
  the Send A File browser only lists these, case-insensitive.