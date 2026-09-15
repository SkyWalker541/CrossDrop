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
-- Every page shows, top to bottom:
--   [Send to Xteink — send N book(s) now]   the action row, always row #1
--   [N books found]                        a small header line
--   [book rows of this page]
--   [Previous page][Next page]
--
-- Picked books get a light-gray row background plus a "picked" hint line
-- (no reliance on icon glyphs, which never rendered here). The picked set
-- lives on the dialog and survives paging. Tapping the action row opens the
-- confirm dialog whose OK button is the labeled "Send to Xteink" button;
-- the transfer then runs inside the open dashboard
-- (plugin:sendBooks with plugin.home as the repaint sink).

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Book extensions (bookshelf.koplugin's SUPPORTED_EXT pattern: ebooks,
-- documents, comics — but not images/archives, which the native listers
-- would happily hand us).
local SUPPORTED_EXT = {
    epub = true, epub3 = true, fb2 = true, fb3 = true, mobi = true,
    azw = true, azw3 = true, prc = true, pdb = true,
    pdf = true, djvu = true, djv = true, doc = true, docx = true,
    rtf = true, odt = true, txt = true, md = true,
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
    plugin = nil,
    books = nil,      -- the scan result, cached for the dialog's lifetime
    picked = nil,     -- full path -> true (survives paging)
    page = 1,
    rows_per_page = 12,
    scan_root = nil,  -- override for tests
}

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
-- every file with a book extension. Returns a flat, name-sorted list of
-- {name, path, size}. Unreadable or missing roots simply yield an empty list.
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
                        if ext and SUPPORTED_EXT[ext:lower()] then
                            out[#out + 1] = { name = entry, path = fp, size = attr.size or 0 }
                        end
                    end
                end
            end
        end
    end
    walk(root, 0)
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function PickerDialog:pickedCount()
    local n = 0
    for _ in pairs(self.picked or {}) do n = n + 1 end
    return n
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
    local names = {}
    for i = 1, math.min(3, #paths) do
        names[#names + 1] = "  " .. (paths[i]:match("([^/]+)$") or paths[i])
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

-- Menu-style Button row (the dashboard's row widget), with optional
-- background/bold overrides for the action row and picked rows. Built
-- manually rather than via menu_style so text_font_bold stays controllable
-- (menu_style clobbers it).
function PickerDialog:row(text, opts)
    opts = opts or {}
    return Button:new{
        text = text,
        width = self.row_w,
        align = "left",
        bordersize = 0,
        padding_h = Size.padding.large,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        text_font_bold = opts.bold == true,
        background = opts.background,
        callback = opts.callback,
    }
end

function PickerDialog:buildContent()
    local vg = VerticalGroup:new{ align = "left" }
    local books = self.books or {}

    -- THE send button: always the first row of every page.
    table.insert(vg, self:row(self:sendRowText(), {
        bold = true,
        background = Blitbuffer.COLOR_WHITE,
        callback = function() self:confirmAndSend() end,
    }))

    table.insert(vg, self:row(string.format(_("%d book(s) found on this device"), #books), {}))

    local rpp = self.rows_per_page
    local max_page = math.max(1, math.ceil(#books / rpp))
    if self.page > max_page then self.page = max_page end
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#books, self.page * rpp)

    if #books == 0 then
        table.insert(vg, TextBoxWidget:new{
            text = _("No books found on this device."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end

    for i = lo, hi do
        local e = books[i]
        local picked = self.picked[e.path] == true
        local size_str = string.format("%.1f MB", (e.size or 0) / 1048576)
        local text = (picked and "\226\156\147 " or "") .. e.name .. "\n" ..
            size_str .. (picked and _("  \226\128\148 picked, tap to un-pick")
                or _("  \226\128\148 tap to pick"))
        table.insert(vg, self:row(text, {
            background = picked and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            callback = function() self:toggle(e.path) end,
        }))
    end

    if self.page > 1 then
        table.insert(vg, self:row(string.format(_("Previous page (page %d of %d)"),
            self.page - 1, max_page), {
            callback = function() self:gotoPage(self.page - 1) end,
        }))
    end
    if hi < #books then
        table.insert(vg, self:row(string.format(_("Next page (page %d of %d)"),
            self.page + 1, max_page), {
            callback = function() self:gotoPage(self.page + 1) end,
        }))
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
    end
    self.picked = self.picked or {}

    -- The dashboard's exact TitleBar config — the ✕ top-right the user
    -- already sees and uses on the dashboard, on this very device.
    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Send A Book"),
        subtitle = _("Tap books to pick them \226\128\148 the top row sends"),
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
