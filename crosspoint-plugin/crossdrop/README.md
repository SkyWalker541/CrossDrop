# CrossDrop (native guide plugin)

Send books to this reader from the **CrossDrop KOReader plugin** over your
Wi-Fi network, no cable needed. This reader already receives books over the
network (File Transfer); this CrossPoint plugin is a **native, on-device
setup guide** for the sender side.

It appears under **Settings → System → Plugins → CrossDrop**, rendered
directly on the e-ink screen as a step-by-step catalog (no browser, no web
view).

## Requirements

This plugin **requires a CrossPoint *beta* build with SD plugin support** —
the "SD Plugins Beta" track (e.g. the Xteink X3/X4 beta builds) that ships the
plugin platform. It does **not** load on CrossPoint stable/non-beta builds.
The reader's built-in **File Transfer** is what actually receives books; this
plugin only explains how to set up the sender side.

## How the guide is served

The guide's steps live in this repository's
`hosted/crossdrop/guide-1.json` and are hosted on GitHub. When
you open the plugin on the reader, its `device.json` fetches that file from:

```
https://raw.githubusercontent.com/SkyWalker541/CrossDrop/main/hosted/crossdrop/guide-1.json
```

Because the content is pulled live from the repo, **editing or fixing the
guide is a one-line change**: update `hosted/crossdrop/guide-1.json` and push
to `main`. Every reader that opens the plugin then sees the new steps — no
reinstall, no new card content needed. (Readers must be online to load it;
previous steps work offline since File Transfer itself is built in.)

**Tapping a step** downloads that step's full text (`hosted/crossdrop/steps/
{id}.txt`, one per step, same list layout) into `/Books` as
`CrossDrop-<id>.txt`, so a step can be kept or reread from the library. The
catalog itself stays on-screen; the steps are short on purpose.

## Files

## Files

- `crossdrop/device.json` — declares the native on-device screen and the
  GitHub URL of the guide catalog. This is what goes on the SD card.
- `crossdrop/manifest.json` — plugin metadata used for the Settings → System
  → Plugins row and version tracking.
- `crossdrop/README.md` — this file (store metadata).
- `hosted/crossdrop/guide-1.json` — the live guide steps, served to the
  reader from GitHub (`raw.githubusercontent.com`). Not installed to the card.
- `hosted/crossdrop/steps/{id}.txt` — per-step text files, downloaded to
  `/Books` when an item is tapped (wired in `device.json` → `download`).

## Install

Copy the `crossdrop/` folder to the reader's SD card as
`/plugins/crossdrop/` (or `/.crosspoint/plugins/crossdrop/`), then reboot the
reader. Open the plugin from **Settings → System → Plugins → CrossDrop**.

## Guide outline

1. Install the KOReader plugin on the sending device.
2. Main menu → **File Transfer → Join Network** on this reader — the address
   shown there is what you type into KOReader.
3. In KOReader: **CrossDrop → Device IP...** — enter that address.
4. **CrossDrop → Send current book** (optional **Destination folder...**).
5. The book lands on this SD card and appears in the reader's library.
6. No router? **File Transfer → Create Hotspot** and use
   **CrossDrop → CrossDrop hotspot (192.168.4.1)**.