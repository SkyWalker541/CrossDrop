-- CrossDrop picker: the "Send A Book" screen, built on the SAME widget
-- architecture as the CrossDrop dashboard (crossdrop_home.lua) — the only
-- widget set proven to render and take taps on this device: rows are
-- Buttons (menu-style), everything sits on the full-screen white card, and
-- the header is the TitleBar whose ✕ the user already uses on the dashboard.
--
-- Instead of wrapping KOReader's built-in file browser (which never worked
-- here — see AGENTS.md), the picker SCANS the device for book files the way
-- bookshelf.koplugin (854★, the storefront's most popular home screen) does:
-- one recursive walk with an extension filter, skipping hidden entries,
-- .sdr sidecar dirs and app/system directories. The result is a flat,
-- alphabetical "every book on this device" list — pick any of them without
-- navigating folders.
--
-- Screen layout (one cohesive style: every row the same font, every button a
-- framed box, hairline separators between rows, every interactive thing a
-- proper button):
--
--   TitleBar: "Send A Book" + "N books — tap to pick; the top row sends"
--   [Send to Xteink — send N book(s) now]  (dark button: THE action)
--   ─────────────
--   [Search books…]                       (opens a keyword-search popup)
--   Search "treis" — 4 results            (only while a filter is active)
--   [Clear search]                        (only while a filter is active)
--   ─────────────
--   [book row]  ───────────── [book row] ───────────── …
--   ─────────────
--   Page X of Y                       (caption, not a control)
--   [Previous page] [Next page]        (only the ones that apply)
--
-- Picked books get a light-gray row background plus a "picked" hint line
-- (no reliance on icon glyphs, which never rendered here). The picked set
-- lives on the dialog and survives paging. Tapping the action row opens the
-- confirm dialog whose OK button is the labeled "Send to Xteink" button;
-- the transfer then runs inside the open dashboard
-- (plugin:sendBooks with plugin.home as the repaint sink).
--
-- Rows show REAL book titles, not the (often horrendous) filenames that
-- side-loaders produce. Titles are resolved cheapest-first:
--   1. KOReader's own metadata cache (coverbrowser's BookInfoManager,
--      bookinfo_cache.sqlite3) — one indexed sqlite query, covers every book
--      KOReader has ever browsed/extracted, EPUB titles included.
--   2. our durable on-disk titles_cache.lua, filled by (4) in past sessions;
--   3. cheap raw reads at scan time: the MOBI/AZW/AZW3/PRC "full name" record
--      (record 0 of the PalmDB) and the FB2 <book-title> element;
--   4. lazy per-page upgrade via DocumentRegistry for EPUBs that failed 1-3
--      (one Document open per frame, so the UI keeps breathing);
--   5. a cleaned-up filename (underscores/hyphens to spaces, side-loader junk
--      tokens like "Anna's Archive" / isbn13 / 32-hex thumbprints dropped).
-- The search below matches the DISPLAYED title as well as the raw filename.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")
local logger = require("logger")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Where this module lives on disk: used for the durable title cache next to
-- the plugin. Derived from the source path (works on device and in tests);
-- KOReader's loader also stamps .path on the plugin module, but never on our
-- instances, so we prefer the file's own location.
local PLUGIN_DIR
do
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        PLUGIN_DIR = src:sub(2):match("^(.*)/[^/]+$")
    end
end

-- Book extensions (bookshelf.koplugin's SUPPORTED_EXT pattern, minus the
-- plain-text/markup forms: on a real device .txt/.md are almost always
-- system files — logs, notes, readmes — not books).
local SUPPORTED_EXT = {
    epub = true, epub3 = true, fb2 = true, fb3 = true, mobi = true,
    azw = true, azw3 = true, prc = true, pdb = true,
    pdf = true, djvu = true, djv = true, doc = true, docx = true,
    rtf = true, odt = true,
    cbz = true, cbr = true, cbt = true,
}

-- Directory names never descended into: the KOReader install itself and the
-- Kindle system/content dirs hold no sendable books (and walking them is
-- slow on device storage). Hidden entries (leading ".") are skipped by the
-- walk, which also kills macOS AppleDouble "._book.epub" companions.
local EXCLUDED_DIRS = {
    koreader = true, extensions = true, mrpackages = true,
    system = true, audible = true, fonts = true, voice = true,
    screenshots = true, wallpapers = true, kmc = true, libkh = true,
    -- pseudo-filesystems (in case the walk ever starts at "/")
    proc = true, sys = true, dev = true, run = true, tmp = true,
    ["lost+found"] = true,
}

local PickerDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    -- covers_fullscreen is the storefront browser's flag: it tells
    -- UIManager the dialog is a dominant full-screen layer, so repaints
    -- start here and everything below (the dashboard) is not painted over
    -- it. Without it, the picker can appear to open BEHIND the dashboard.
    covers_fullscreen = true,
    plugin = nil,
    books = nil,       -- the scan result, cached for the dialog's lifetime
    query = nil,       -- active search filter (lowercased), nil = no filter
    picked = nil,      -- full path -> true (survives paging)
    title_cache = {},  -- path -> real title, from past lazy upgrades
    title_failed = {}, -- path -> true: never retried this session
    title_cache_file = nil,
    title_cache_dirty = nil,
    page = 1,
    rows_per_page = 10,
    scan_root = nil,   -- override for tests
}

-- Extension groups: names a book by raw reads (cheap), and EPUBs that need
-- the Document provider for a real title (done lazily, page by page).
local MOBI_EXTS = { mobi = true, azw = true, azw3 = true, prc = true }
local FB2_EXTS = { fb2 = true, fb3 = true }
local EPUB_EXTS = { epub = true, epub3 = true }

-- ─────────────────── pure, testable logic ──────────────────────

-- Where to scan: the Kindle user partition, else KOReader's home folder,
-- else the filesystem root (the walk's EXCLUDED_DIRS make that survivable).
function PickerDialog.scanRoot()
    local ok, dev = pcall(function() return Device end)
    if ok and dev and dev.isKindle and dev:isKindle() then
        return "/mnt/us"
    end
    local ok_fmu, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    if ok_fmu and fmu and fmu.getHomeFolder then
        local home = fmu.getHomeFolder()
        if home and home ~= "" then return home end
    end
    return "/"
end

-- One recursive walk over the scan root (bookshelf.koplugin's walkBooks
-- pattern): skip dot entries, EXCLUDED_DIRS and .sdr sidecar dirs; collect
-- every file with a book extension. Returns a flat, title-sorted list of
-- {name, path, ext, title, size}. Unreadable or missing roots simply yield
-- an empty list. Each entry gets its best-known title via :titleFor (see
-- the header comment for the resolution ladder; `real` is set when the
-- title came from metadata, and cleared for EPUBs still awaiting the lazy
-- Document upgrade).
function PickerDialog:scanAllBooks(root)
    root = root or self.scan_root or PickerDialog.scanRoot()
    local out = {}
    if not (lfs_ok and lfs and lfs.dir and lfs.attributes) then
        return out
    end
    local MAX_DEPTH = 8
    local function walk(dir, depth)
        if depth > MAX_DEPTH then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok or type(iter) ~= "function" then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "."
                and not EXCLUDED_DIRS[entry] then
                local fp = dir .. "/" .. entry
                local attr = lfs.attributes(fp)
                if type(attr) == "table" then
                    if attr.mode == "directory" then
                        if entry:sub(-4) ~= ".sdr" then
                            walk(fp, depth + 1)
                        end
                    elseif attr.mode == "file" then
                        local ext = entry:match("%.([^.]+)$")
                        ext = ext and ext:lower() or nil
                        if ext and SUPPORTED_EXT[ext] then
                            local b = { name = entry, path = fp, ext = ext, size = attr.size or 0 }
                            self:titleFor(b)
                            out[#out + 1] = b
                        end
                    end
                end
            end
        end
    end
    walk(root, 0)
    table.sort(out, function(a, b)
        local ta, tb = a.title or a.name, b.title or b.name
        return ta:lower() < tb:lower()
    end)
    return out
end

-- ─────────────────── real titles, cheapest-first ─────────────────────

-- Fallback: a filename made readable. Conservative — it only strips what
-- side-loaders stamp on: separators, underscores, and the junk tokens
-- retailers add (archive names, isbn13, 32-hex thumbprints). Interior
-- punctuation ("sci-fi", digits) is kept. If nothing survives, the raw
-- filename (minus extension) wins.
function PickerDialog:cleanTitle(name)
    local t = name:match("^(.*)%.[^.]+$") or name
    t = t:gsub("_", " ")
    t = t:gsub("%s+", " ")
    -- Anna's Archive (straight or curly apostrophe) + tails
    local APOSTROPHES = "'" .. string.char(226, 128, 152, 226, 128, 153)
    t = t:gsub("Anna[" .. APOSTROPHES .. "]s Archive", " ")
    t = t:gsub("%s+[Oo]ptimized%s*", " ")
    t = t:gsub("[Ii][Ss][Bb][Nn]13[%s%-]*%d%d%d%d%d%d%d%d%d?%d?%d?%s*", " ")
    t = t:gsub(
        "%s+[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]"
        .. "[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]%s*",
        " ")
    t = t:gsub("%s%-+%s*", " ")
    -- left-over double-extension dots ("sci-fi.novel.epub" -> "sci-fi novel")
    t = t:gsub("[%.]+", " ")
    t = t:gsub("%s+", " ")
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    if t == "" then
        return name:match("^(.*)%.[^.]+$") or name
    end
    return t
end

-- Whatever a parser scraped out of a file gets normalized here; returns nil
-- when there is nothing usable (so callers fall through to the next tier).
function PickerDialog:sanitizeTitle(t)
    if not t or t == "" then return nil end
    t = tostring(t)
    t = t:gsub("%c", "")
    t = t:gsub("%s+", " ")
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    if #t > 200 then t = t:sub(1, 200) end
    if t == "" then return nil end
    return t
end

-- First raw bytes of a file: used by the cheap binary/XML parsers below,
-- and only there (this is a couple of small reads per mobi/fb2 — nothing
-- like opening a book).
function PickerDialog:readFirstBytes(path, n)
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, data = pcall(f.read, f, n)
    f:close()
    if ok and data then return data end
    return nil
end

local function be32(s, i) -- uint32, big-endian, at 1-based byte index i
    return s:byte(i) * 16777216
        + s:byte(i + 1) * 65536
        + s:byte(i + 2) * 256
        + s:byte(i + 3)
end

-- Palm Database identifiers that carry the MOBI header in record 0.
local MOBI_MAGICS = { BOOKMOBI = true, ["TEXtREAd"] = true, ["TEXtOReB"] = true, ["TEXtRTF"] = true }

-- The MOBI/PalmDoc "full name": record 0 of the PalmDB holds the MOBI header
-- whose 0x54/0x58 fields are the offset/length (relative to record 0, NOT
-- the file) of the clean book title. The MobileRead-verified layout:
--   76(2) record count, 78(4) record 0 data offset,
--   84(4) full name offset, 88(4) full name length.
function PickerDialog:mobiTitle(path)
    local data = self:readFirstBytes(path, 8192)
    if not data or #data < 96 then return nil end
    local rec0 = be32(data, 79)
    if not rec0 or rec0 < 24 or rec0 + 120 > #data then return nil end
    if not MOBI_MAGICS[data:sub(rec0 + 1, rec0 + 8)] then return nil end
    local fn_off = be32(data, rec0 + 85)
    local fn_len = be32(data, rec0 + 89)
    if fn_len == 0 or fn_len > 2048 then return nil end
    if rec0 + fn_off + fn_len > #data + 1 then return nil end
    return self:sanitizeTitle(data:sub(rec0 + fn_off + 1, rec0 + fn_off + fn_len))
end

-- FB2/FB3 are plain XML (at least as a single .fb2/.fb3 file): the title is
-- the <book-title> element. Namespace/entities handled loosely.
function PickerDialog:fb2Title(path)
    local data = self:readFirstBytes(path, 65536)
    if not data then return nil end
    local t = data:match("<book%-title[^>]*>(.-)</book%-title>")
    if not t then return nil end
    t = t:gsub("<[^>]+>", " ")
    t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#39;", "'")
    return self:sanitizeTitle(t)
end

-- Tier 1: KOReader's own metadata cache. coverbrowser's BookInfoManager
-- maintains bookinfo_cache.sqlite3 (real titles for every book KOReader has
-- browsed/extracted — EPUB titles included). One indexed prepared query,
-- same order of cost as the scan's lfs.attributes calls. Guarded: on a
-- device without coverbrowser, or in the test harness, this is a no-op.
function PickerDialog:koreaderMetaTitle(path)
    if PickerDialog.bim == nil then
        local ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
        PickerDialog.bim = ok and bim or false
        if PickerDialog.bim and PickerDialog.bim.init then
            pcall(PickerDialog.bim.init, PickerDialog.bim)
        end
    end
    local bim = PickerDialog.bim
    if not bim or not bim.getDocProps then return nil end
    local ok, props = pcall(bim.getDocProps, bim, path)
    if ok and props and props.title and props.title ~= "" then
        return self:sanitizeTitle(props.title)
    end
    return nil
end

-- Resolve the best-known title for one scan entry, cheapest tier first
-- (see the header comment). `b.real` is true when the title came from real
-- metadata; EPUBs that found nothing keep a cleaned fallback with real=nil,
-- so the lazy per-page Document upgrade (upgradeVisibleTitles) gets a turn.
function PickerDialog:titleFor(b)
    local ext = b.ext
    local title, real
    if not ext then
        -- no extension: filename is all we have
    elseif MOBI_EXTS[ext] then
        title, real = self:mobiTitle(b.path), true
    elseif FB2_EXTS[ext] then
        title, real = self:fb2Title(b.path), true
    elseif EPUB_EXTS[ext] then
        -- bind first since it is free and instant
        title = self.title_cache[b.path] or self:koreaderMetaTitle(b.path)
        real = title and true or nil
    end
    if title then
        b.title = title
        b.real = real and true or nil
    else
        b.title = self:cleanTitle(b.name)
        b.real = nil
    end
end

-- Durable cache (tier 2): titles discovered by the lazy upgrade are kept in
-- a Lua file next to the plugin, so the next session starts a page already
-- holding real titles. Plain <path>=<title> lines, %q-quoted and read back
-- with load(); a sub-par read just yields an empty cache.
function PickerDialog:loadTitleCache()
    if not self.title_cache_file then return end
    local f = io.open(self.title_cache_file, "r")
    if not f then return end
    local src = f:read("*a")
    f:close()
    local chunk = src and load(src, "crossdrop_titles_cache")
    if chunk then
        local ok, t = pcall(chunk)
        if ok and type(t) == "table" then
            self.title_cache = t
        end
    end
end

function PickerDialog:saveTitleCache()
    if not self.title_cache_file or not self.title_cache_dirty then return end
    local f = io.open(self.title_cache_file, "w")
    if not f then return end
    local lines = {}
    for p, t in pairs(self.title_cache) do
        lines[#lines + 1] = string.format("  [%q] = %q,\n", p, t)
    end
    f:write("-- CrossDrop real-title cache, written as titles are discovered.\nreturn {\n")
    f:write(table.concat(lines))
    f:write("}\n")
    f:close()
    self.title_cache_dirty = nil
end

-- Tier 4, the lazy upgrade: the EPUBs on the CURRENT page that still have
-- only a cleaned-filename title get a real title from the Document provider.
-- One Document open per frame (UIManager:nextTick) so the UI never stalls,
-- and every finished title is cached on disk for next session. Failures are
-- black-listed for this session. DocumentRegistry does not exist in the
-- harness, so it is a no-op there.
function PickerDialog:upgradeVisibleTitles()
    if self._upgrading or not self.books then return end
    local books = self:visibleBooks()
    local lo = (self.page - 1) * self.rows_per_page + 1
    local hi = math.min(#books, self.page * self.rows_per_page)
    local todo = {}
    for i = lo, hi do
        local b = books[i]
        if b and not b.real and EPUB_EXTS[b.ext] and not self.title_failed[b.path] then
            local known = self.title_cache[b.path] or self:koreaderMetaTitle(b.path)
            if known then
                b.title, b.real = known, true
            else
                todo[#todo + 1] = b
            end
        end
    end
    if #todo == 0 then return end
    local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_reg and DocumentRegistry and DocumentRegistry.openDocument) then return end
    self._upgrading = true
    local picker = self
    local i = 1
    local step
    step = function()
        if picker._closed then
            picker._upgrading = nil
            return
        end
        local b = todo[i]
        if b then
            local ok, title = pcall(function()
                local doc = DocumentRegistry:openDocument(b.path)
                local props = doc and doc.getProps and doc:getProps()
                if doc and doc.close then pcall(doc.close, doc) end
                if DocumentRegistry.closeDocument then
                    pcall(DocumentRegistry.closeDocument, DocumentRegistry, b.path)
                end
                return props and props.title
            end)
            if ok and title then
                title = picker:sanitizeTitle(title)
            end
            if title then
                b.title = title
                b.real = true
                picker.title_cache[b.path] = title
                picker.title_cache_dirty = true
            else
                picker.title_failed[b.path] = true
            end
        end
        i = i + 1
        if i <= #todo then
            UIManager:nextTick(step)
        else
            picker._upgrading = nil
            if picker.title_cache_dirty then picker:saveTitleCache() end
            if not picker._closed then
                picker:init()
                UIManager:setDirty(picker, "full")
            end
        end
    end
    UIManager:nextTick(step)
end

function PickerDialog:pickedCount()
    local n = 0
    for _ in pairs(self.picked or {}) do n = n + 1 end
    return n
end

-- The pageable list is the scan filtered by the active search: an
-- always-case-insensitive substring match on the DISPLAYED title AND the raw
-- filename (plain find, no pattern magic, so "(" or "." in a query can't
-- blow up). The picked set is untouched by filtering — a picked book stays
-- picked when you search.
function PickerDialog:visibleBooks()
    local books = self.books or {}
    local q = self.query
    if not q or q == "" then
        return books
    end
    q = q:lower() -- defensive: callers store it lowercased, this keeps it safe
    local out = {}
    for _, b in ipairs(books) do
        if b.title and b.title:lower():find(q, 1, true)
            or (b.name and b.name:lower():find(q, 1, true)) then
            out[#out + 1] = b
        end
    end
    return out
end

-- The Search button: a modal keyword popup (the same InputDialog recipe the
-- dashboard's editIp uses — modal=true is REQUIRED so it stacks above this
-- full-screen picker). Saves the (trimmed, lowercased) query or clears it.
function PickerDialog:showSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local picker = self
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search books"),
        input = self.query or "",
        input_hint = _("Keyword \226\128\148 matches any part of a title or file name"),
        type = "text",
        modal = true,
        buttons = {
            {
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local text = search_dialog:getInputText() or ""
                        local q = text:match("^%s*(.-)%s*$") or ""
                        q = q:lower()
                        picker.query = (q == "") and nil or q
                        picker.page = 1
                        UIManager:close(search_dialog)
                        picker:init()
                        UIManager:setDirty(picker, "full")
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(search_dialog)
end

function PickerDialog:clearSearch()
    self.query = nil
    self.page = 1
    self:init()
    UIManager:setDirty(self, "full")
end

-- The action row text: the send button the user asked for, always visible,
-- carrying the running count so it doubles as the selection readout.
function PickerDialog:sendRowText()
    local n = self:pickedCount()
    if n > 0 then
        return string.format(_("Send to Xteink  \226\128\162  send %d book(s) now"), n)
    end
    return _("Send to Xteink  \226\128\162  pick books below")
end

-- The action: confirm dialog whose OK button is the labeled
-- "Send to Xteink" button (core ConfirmBox buttons — proven), then the
-- whole batch streams inside the open dashboard. With nothing picked it is
-- a gentle hint, never a send.
function PickerDialog:confirmAndSend()
    local paths = {}
    for p in pairs(self.picked or {}) do paths[#paths + 1] = p end
    if #paths == 0 then
        UIManager:show(Notification:new{
            text = _("Tap books below to pick them \226\128\148 then this row sends them."),
            timeout = 4,
        })
        return
    end
    table.sort(paths)
    local titles = {}
    for _, b in ipairs(self.books or {}) do
        titles[b.path] = b.title or b.name
    end
    local names = {}
    for i = 1, math.min(3, #paths) do
        names[#names + 1] = "  " .. (titles[paths[i]] or (paths[i]:match("([^/]+)$") or paths[i]))
    end
    if #paths > 3 then
        names[#names + 1] = string.format("  \226\128\166  %d more", #paths - 3)
    end
    local picker = self
    local plugin = self.plugin
    local confirm
    confirm = ConfirmBox:new{
        text = string.format(_("Send %d book(s) to the reader?"), #paths)
            .. "\n" .. table.concat(names, "\n"),
        ok_text = _("Send to Xteink"),
        ok_callback = function()
            UIManager:close(confirm)
            UIManager:close(picker, "ui")
            local paths_now = {}
            for _, p in ipairs(paths) do paths_now[#paths_now + 1] = p end
            UIManager:nextTick(function()
                plugin:sendBooks(paths_now, plugin.home)
            end)
        end,
        cancel_callback = function()
            UIManager:close(confirm)
        end,
    }
    UIManager:show(confirm)
end

-- ────────────────────── interactions ─────────────────────────────

-- Toggle one book in the picked set and repaint in place (the dashboard's
-- showTab recipe: re-init the same widget, then a "full" refresh). The scan
-- is cached on self, so this never rescans.
function PickerDialog:toggle(path)
    self.picked = self.picked or {}
    if self.picked[path] then
        self.picked[path] = nil
    else
        self.picked[path] = true
    end
    self:init()
    UIManager:setDirty(self, "full")
end

function PickerDialog:gotoPage(n)
    self.page = math.max(1, n)
    self:init()
    UIManager:setDirty(self, "full")
end

-- Exiting (the TitleBar ✕, the one the user already uses on the dashboard)
-- always lands back on the CrossDrop dashboard: if Home is still open it is
-- repainted; if it was closed meanwhile, it is reopened.
function PickerDialog:close()
    self._closed = true
    UIManager:close(self, "ui")
    local plugin = self.plugin
    if plugin then
        if plugin.home then
            UIManager:setDirty(plugin.home, "ui")
            UIManager:forceRePaint()
        else
            plugin:openHome()
        end
    end
end

-- ────────────────────── rendering ─────────────────────────────

-- Menu-style Button row (the dashboard's row widget): one consistent font
-- everywhere (smallinfofont 22, the same as the dashboard's rows). Built
-- manually rather than via menu_style so bold and colors stay controllable
-- (menu_style clobbers them). avoid_text_truncation is OFF on purpose: with
-- it on, Button shrinks the font (down to a 2-line TextBoxWidget) for any
-- title too wide for the row, so long and short titles rendered at visibly
-- different sizes. Off, every row keeps font 22 and a too-long title is
-- truncated instead. Every row is a framed box (a real border).
function PickerDialog:row(text, opts)
    opts = opts or {}
    return Button:new{
        text = text,
        width = self.row_w,
        align = "left",
        bordersize = Size.border.button,
        avoid_text_truncation = false,
        padding_h = Size.padding.large,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        text_font_bold = opts.bold == true,
        background = opts.background,
        text_font_color = opts.text_color,
        callback = opts.callback,
    }
end

-- The hairline between rows: a thin gray line with a little air around it,
-- so the list reads as discrete rows instead of one dense block.
function PickerDialog:separator()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return VerticalGroup:new{
        VerticalSpan:new{ width = sc(2) },
        LineWidget:new{
            dimen = Geom:new{ w = self.row_w, h = Size.line.thick },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        VerticalSpan:new{ width = sc(2) },
    }
end

-- A small caption (plain text, same face as the rows — not a button).
function PickerDialog:caption(text)
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

function PickerDialog:buildContent()
    local vg = VerticalGroup:new{ align = "left" }
    local books = self:visibleBooks()
    local sc = function(v) return Device.screen:scaleBySize(v) end

    -- THE send button: always the first row of every page, dark and bold so
    -- it reads as THE primary control (storefront's ok-button styling).
    table.insert(vg, self:row(self:sendRowText(), {
        bold = true,
        background = Blitbuffer.COLOR_DARK_GRAY,
        text_color = Blitbuffer.COLOR_WHITE,
        callback = function() self:confirmAndSend() end,
    }))

    local rpp = self.rows_per_page
    local max_page = math.max(1, math.ceil(#books / rpp))
    if self.page > max_page then self.page = max_page end
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#books, self.page * rpp)

    table.insert(vg, self:separator())

    -- Search: the button is always there; the active filter is spelled out in
    -- a caption ("the field that shows the current search filter") with a
    -- Clear button right under it.
    table.insert(vg, self:row(_("Search books\226\128\166"), {
        callback = function() self:showSearchDialog() end,
    }))
    if self.query then
        table.insert(vg, self:separator())
        local results = #books
        local label = (results == 1) and _("result") or _("results")
        table.insert(vg, self:caption(string.format(_("Search \226\128\156%s\226\128\157 \226\128\148 %d %s"),
            self.query, results, label)))
        table.insert(vg, self:row(_("Clear search"), {
            callback = function() self:clearSearch() end,
        }))
    end
    table.insert(vg, self:separator())

    if #books == 0 then
        if self.query then
            table.insert(vg, self:caption(_("No books match this search.")))
        else
            table.insert(vg, self:caption(_("No books found on this device.")))
        end
    end

    for i = lo, hi do
        local e = books[i]
        local picked = self.picked[e.path] == true
        local size_str = string.format("%.1f MB", (e.size or 0) / 1048576)
        local text = e.title .. "\n" ..
            size_str .. (picked and _("  \226\128\148 picked, tap to un-pick")
                or _("  \226\128\148 tap to pick"))
        table.insert(vg, self:row(text, {
            background = picked and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            callback = function() self:toggle(e.path) end,
        }))
        if i < hi then
            table.insert(vg, self:separator())
        end
    end

    -- Paging: a plain caption for the page number (never a control), then
    -- the actual Previous/Next buttons — only the ones that apply.
    if #books > 0 then
        table.insert(vg, self:separator())
        table.insert(vg, self:caption(string.format(_("Page %d of %d"),
            self.page, max_page)))
        table.insert(vg, VerticalSpan:new{ width = sc(2) })
        if self.page > 1 then
            table.insert(vg, self:row(_("Previous page"), {
                callback = function() self:gotoPage(self.page - 1) end,
            }))
        end
        if hi < #books then
            table.insert(vg, self:row(_("Next page"), {
                callback = function() self:gotoPage(self.page + 1) end,
            }))
        end
    end

    return vg
end

function PickerDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    self._closed = false
    -- The durable real-title cache lives next to the plugin (derived from
    -- this file's own path); in tests the file simply doesn't exist yet, and
    -- reads/writes are gated by the lazy-upgrade flow that cannot run there.
    if not self.title_cache_file then
        local dir = (self.plugin and self.plugin.path) or PLUGIN_DIR
        if dir then
            self.title_cache_file = dir .. "/titles_cache.lua"
        end
    end
    if self.title_cache_file and not self._cache_loaded then
        self:loadTitleCache()
        self._cache_loaded = true
    end

    -- Scan ONCE per dialog lifetime (the walk is a real directory read on
    -- slow device storage): paint a notice first so it never reads as a
    -- freeze (the dashboard's check() recipe), then cache the result —
    -- toggles and pages re-init from the cache, never from disk.
    if not self.books then
        local scanning = Notification:new{
            text = _("Scanning for books\226\128\166"),
            timeout = 0,
        }
        UIManager:show(scanning)
        UIManager:forceRePaint()
        self.books = self:scanAllBooks()
        UIManager:close(scanning)
        logger.info("crossdrop: device scan found ", #self.books, " book(s)")
    end
    self.picked = self.picked or {}

    -- After the first paint, give the current page's titles one lazy shot at
    -- becoming real (Document opens, one per frame). No-ops until the frame
    -- ticks, and no-ops altogether when there is nothing left to upgrade.
    UIManager:nextTick(function()
        if not self._closed then self:upgradeVisibleTitles() end
    end)

    -- Belt-and-suspenders: instance-level modal (never rely on class
    -- inheritance for the field UIManager's stacking depends on).
    self.modal = true

    -- The dashboard's exact TitleBar config — the ✕ top-right the user
    -- already sees and uses on the dashboard, on this very device. The
    -- subtitle carries the book count (static for the dialog's lifetime).
    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Send A Book"),
        subtitle = string.format(_("%d book(s) on this device \226\128\148 tap to pick; the top row sends"),
            #self.books),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            self:close()
        end,
        show_parent = self,
    }

    local content = self:buildContent()

    -- The dashboard's full-screen white card (see crossdrop_home:init for
    -- why both dimen AND width/height are needed).
    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            content,
            VerticalSpan:new{ width = sc(8) },
        },
    }
    self.frame = frame
    self[1] = frame

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function PickerDialog:onBack()
    self:close()
    return true
end

return PickerDialog
