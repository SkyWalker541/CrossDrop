-- CrossDrop picker: the "Send A Book" browser, built on the SAME widget
-- architecture as the CrossDrop dashboard (crossdrop_home.lua) — the only
-- widget set proven to render and take taps on this device: rows are
-- Buttons (menu-style), everything sits on the full-screen white card, and
-- the header is the TitleBar whose ✕ the user already uses on the dashboard.
-- The old FileChooser/Menu-based picker was removed in 1.3.15: none of its
-- chrome (custom_title_bar, right-icon slots, synthetic genItemTable rows)
-- ever rendered on this build.
--
-- Every page shows, top to bottom:
--   [Send to Xteink — send N book(s) now]   the action row, always row #1
--   [Up one level]                           unless at the SD root
--   [folder rows][book rows of this page]
--   [Previous page][Next page]
--
-- Picked books get a light-gray row background plus a "picked" hint line
-- (no reliance on icon glyphs, which never rendered here). The picked set
-- lives on the dialog and survives folder changes and paging. Tapping the
-- action row opens the confirm dialog whose OK button is the labeled
-- "Send to Xteink" button; the transfer then runs inside the open
-- dashboard (plugin:sendBooks with plugin.home as the repaint sink).

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

local function dirname(path)
    return (path:match("^(.*)/[^/]+$")) or "/"
end

local function file_size(path)
    if lfs_ok and lfs and lfs.attributes then
        return lfs.attributes(path, "size") or 0
    end
    return 0
end

-- Book filter: KOReader's own registry when available (the same hasProvider
-- the old FileChooser filter used), else a safe extension fallback (used by
-- the test harness, where the registry is not loadable).
local dr_ok, DocumentRegistry = pcall(require, "document/documentregistry")
local BOOK_EXTENSIONS = {
    epub = true, mobi = true, pdf = true, azw = true, azw3 = true,
    djvu = true, fb2 = true, cbz = true, txt = true, rtf = true,
    htm = true, html = true, xhtml = true,
}
local function is_book(path)
    if dr_ok and DocumentRegistry and DocumentRegistry.hasProvider then
        return DocumentRegistry:hasProvider(path) == true
    end
    local ext = path:match("%.(%w+)$")
    return ext ~= nil and BOOK_EXTENSIONS[ext:lower()] == true
end

local PickerDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    path = nil,       -- the folder being browsed
    picked = nil,     -- full path -> true (survives navigation and paging)
    page = 1,
    rows_per_page = 12,
}

-- ─────────────────── pure, testable logic ──────────────────────

-- Scan one folder: sorted subfolders + sorted book files. Unreadable or
-- missing folders simply yield empty lists (the UI shows a hint row).
function PickerDialog:listFolder(path)
    local dirs, files = {}, {}
    if lfs_ok and lfs and lfs.dir then
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if ok then
            for f in iter, dir_obj do
                if f ~= "." and f ~= ".." and not f:match("^%._") then
                    local full = path .. "/" .. f
                    local attr = lfs.attributes(full) or {}
                    if attr.mode == "directory" then
                        dirs[#dirs + 1] = { name = f, path = full }
                    elseif attr.mode == "file" and is_book(full) then
                        files[#files + 1] = { name = f, path = full, size = attr.size or 0 }
                    end
                end
            end
        end
    end
    table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    return dirs, files
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
-- showTab recipe: re-init the same widget, then a "full" refresh).
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

function PickerDialog:gotoFolder(path)
    self.path = path
    self.page = 1
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

    -- THE send button: always the first row of every page.
    table.insert(vg, self:row(self:sendRowText(), {
        bold = true,
        background = Blitbuffer.COLOR_WHITE,
        callback = function() self:confirmAndSend() end,
    }))

    if self.path and self.path ~= "/" then
        table.insert(vg, self:row(_("Up one level"), {
            callback = function() self:gotoFolder(dirname(self.path)) end,
        }))
    end

    local dirs, files = self:listFolder(self.path)
    local listing = {}
    for _, d in ipairs(dirs) do listing[#listing + 1] = d end
    for _, f in ipairs(files) do listing[#listing + 1] = f end

    local rpp = self.rows_per_page
    local max_page = math.max(1, math.ceil(#listing / rpp))
    if self.page > max_page then self.page = max_page end
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#listing, self.page * rpp)

    if #listing == 0 then
        table.insert(vg, TextBoxWidget:new{
            text = _("No books or folders found here. Use \"Up one level\" to look elsewhere."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end

    for i = lo, hi do
        local e = listing[i]
        if e.size then -- a book file
            local picked = self.picked[e.path] == true
            local size_str = string.format("%.1f MB", (e.size or file_size(e.path)) / 1048576)
            local text = (picked and "\226\156\147 " or "") .. e.name .. "\n" ..
                size_str .. (picked and _("  \226\128\148 picked, tap to un-pick")
                    or _("  \226\128\148 tap to pick"))
            table.insert(vg, self:row(text, {
                background = picked and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                callback = function() self:toggle(e.path) end,
            }))
        else -- a subfolder
            table.insert(vg, self:row(e.name .. "/\n" .. _("folder \226\128\148 tap to browse"), {
                callback = function() self:gotoFolder(e.path) end,
            }))
        end
    end

    if self.page > 1 then
        table.insert(vg, self:row(string.format(_("Previous page (page %d of %d)"),
            self.page - 1, max_page), {
            callback = function() self:gotoPage(self.page - 1) end,
        }))
    end
    if hi < #listing then
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

    -- Start at KOReader's home folder (the same start the old picker used),
    -- falling back to the process directory and then the Kindle SD root.
    if not self.path or self.path == "" then
        local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
        if ok and fmu and fmu.getHomeFolder then
            self.path = fmu.getHomeFolder()
        end
        if not self.path or self.path == "" then
            self.path = (lfs_ok and lfs and lfs.currentdir and lfs.currentdir()) or "/mnt/us"
        end
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
