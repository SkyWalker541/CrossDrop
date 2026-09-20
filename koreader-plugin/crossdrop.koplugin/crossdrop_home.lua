-- CrossDrop Home: the plugin's app-style dashboard (the "Storefront" look).
-- A Storefront-style brand lockup (logo + name top-left, ✕ to leave), an
-- underlined tab bar (Connections / Send A File / Delete), rich rows
-- with live status dots and short hints, tap-to-act. The white card covers
-- the whole screen so nothing shows behind it. Loaded lazily from main.lua,
-- so all widget requires happen when the dashboard opens, never at plugin
-- load. Reachability is checked on demand (it is a blocking probe) and
-- remembered on the plugin instance across tab switches.
--
-- Every send happens INSIDE this dashboard: beginSendBatch hands the picked
-- files to plugin:sendBooks with this Home as the repaint sink, whose
-- onConnecting/onConnected/onBeginFile/onProgress/onDone callbacks rebuild the
-- Send tab in place (the same forceRePaint recipe the standalone progress
-- dialog and Storefront use). The dashboard never closes during a transfer,
-- and "Send more files…"/"Try again" keep going from the same window.
--
-- E-INK REPAINT RULE (the issue that hid the whole flow on the device):
-- when one of these callbacks flips the send STATE (connecting / sending a
-- file / done / failed) it does a full refresh — bare forceRePaint() partials
-- over a whole-screen white card were being swallowed by the panel, so the
-- transfer ran to completion with the screen still showing the old tab.
-- Not every transition flashes though: the "Connecting…" hint and MID-batch
-- file starts repaint WITHOUT a flash (repaintSoft, "partial") — a reachable
-- target answers the probe in milliseconds so its full flash would be wasted,
-- and mid-batch the screen is already showing Sending. Only the first file
-- start and the final done/failed boundary do the flashing full refresh
-- (repaintNow), and if an early partial happens to be swallowed the next full
-- always lands, so a soft repaint can never leave a stale screen.
-- There is no per-chunk repaint at all now: the "Sending…" view is a plain
-- waiting screen (the transfer drains faster than e-ink can repaint),
--
-- Uses only the plugin API exported from main.lua:
--   configuredTargets() -> {kind, ip, port, folder}[]  (WiFi only)
--   resolveTarget()     -> the WiFi target
--   probeTarget(target) -> (ok, info?); "down" statuses are cheap (3s timeout)
--   sendCurrentBook()   -> probes WiFi and streams to it
--   chooseAndSend()     -> the multi-select book picker (the send row sends)
--   editIp(kind)        -> input dialog for the WiFi IP
--   statusDialog(), currentBookPath()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")
local logger = require("logger")

-- The file picker renders INSIDE this dashboard (the Send tab's browser) but
-- lives in its own module. Loaded lazily — requiring Home must never pull
-- the picker's widget code at plugin load time (the Harness guards that).
local picker_mod
local function pickerModule()
    picker_mod = picker_mod or require("crossdrop_picker")
    return picker_mod
end

-- This file's own plugin directory (icon.png lives beside it). The on-device
-- PluginLoader sets plugin.path on the module; this mirrors how the picker
-- finds titles_cache.lua so the logo also resolves when running without it.
local LUA_PLUGIN_DIR
do
    local src = debug.getinfo(1, "S").source
    if src and src:sub(1, 1) == "@" then
        LUA_PLUGIN_DIR = src:sub(2):match("^(.*)/[^/]+$")
    end
end

-- ────────────────────── small presentation helpers ──────────────────────

local function file_size(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        return lfs.attributes(path, "size") or 0
    end
    return 0
end

local function ip_str(t)
    local ip = t and t.ip or "?"
    if t and t.port and t.port ~= 80 then ip = ip .. ":" .. tostring(t.port) end
    return ip
end

local function folder_str(t)
    local folder = t and t.folder and t.folder ~= "" and t.folder or "/CrossDropped Files"
    return folder
end

-- Display name of a folder path: "/CrossDropped Files" → "CrossDropped Files".
local function folder_basename(path)
    local base = tostring(path or ""):match("([^/]+)/*$")
    return (base and base ~= "") and base or "CrossDropped Files"
end

local function status_word(reach)
    if reach == "ok" then return _("Reachable \226\151\128") end    -- ●
    if reach == "down" then return _("Offline \226\151\138") end    -- ○
    return _("Not checked")
end

-- ─────────────────────────────── the widget ──────────────────────────────

-- Forward declarations: FolderMenuDialog and DeleteDialog are defined further
-- down, but earlier-defined methods (showFolderMenu, openDeleteTree) build
-- them — without this they would resolve as globals (plugin-namespace
-- pollution on the device, where every plugin shares _G).
local FolderMenuDialog, DeleteDialog

local HomeDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tab = "send",
    -- In-dashboard send state machine (see renderSend dispatch).
    send_state = "idle",  -- "idle" | "connecting" | "sending" | "done" | "failed"
    send_paths = nil,     -- full list passed to beginSendBatch
    send_target = nil,    -- {kind,ip,port,folder} of the resolved connection
    send_index = 0,       -- 1-based: current file number within the batch
    send_total = 0,       -- total files in the batch
    send_path = nil,      -- path of the file currently being sent
    send_filename = nil,  -- basename of send_path (for display)
    send_file_list = {},  -- basenames of files sent so far
    send_widgets = nil,   -- reserved: the progress bar was removed (e-ink), onProgress is inert
    fail_reason = nil,    -- text shown on "failed"
    -- Everything below the tab bar happens INSIDE this dashboard: the file
    -- picker and the two trees render into the tab content region instead of
    -- stacked full-screen dialogs (see the buildTabContent dispatch). The
    -- browser objects keep their state (picked files, tree pages, search
    -- filter) for the whole Home lifetime; these screen fields only say which
    -- browser, if any, the active tab is showing. nil == that tab's landing.
    send_screen = nil,    -- "files" (picker) | "destination" (folder tree)
    delete_screen = nil,  -- "tree" (delete tree)
    send_picker = nil,    -- PickerDialog parked on the Send tab
    dest_browser = nil,   -- DestinationDialog parked on the Send tab
    delete_browser = nil, -- DeleteDialog parked on the Delete tab
    content_h = nil,      -- height of the tab content region (measured at init)
}

function HomeDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- Storefront-style sizing: every dimension is derived from the device via
    -- scaleBySize, and no text widget is allowed to auto-size past the card
    -- (every TextBoxWidget/row gets an explicit width). The white card covers
    -- the WHOLE screen (frame.dimen = sw x sh) so no other app shows behind
    -- it, while still never spilling past the edges on any device.
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    -- The tab content region's height: the card's inner height minus the
    -- MEASURED brand header, tab bar and the three breathing spans. The
    -- inline browsers (file picker, destination tree, delete tree) and the
    -- send flow use this as their budget, so their pagers and footers strap
    -- to the bottom of the tab region exactly like they used to strap to the
    -- bottom of a full-screen card.
    local header_vg = self:buildHeader(inner_w, sc)
    local tabbar_vg = self:buildTabBar(inner_w)
    local gh = function(w)
        local s = w.getSize and w:getSize()
        return (s and s.h) or 0
    end
    self.content_h = math.max(sc(120),
        math.floor((sh - pad * 2) - gh(header_vg) - sc(8) - gh(tabbar_vg) - sc(20) - sc(8)))

    local content = self:buildTabContent(self.tab, inner_w, self.content_h)

    -- A full-screen white frame (not a centered content-sized card): the
    -- whole screen paints white on top of whatever UI sits behind it. Both
    -- `dimen` AND `width`/`height` are required — FrameContainer:paintTo paints
    -- its background at container_width/height (= self.width/self.height or the
    -- content size), NOT at dimen. Without width/height the frame only painted
    -- over its content bounds and a strip of the UI below showed at the bottom.
    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            header_vg,
            VerticalSpan:new{ width = sc(8) },
            tabbar_vg,
            VerticalSpan:new{ width = sc(20) },
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

function HomeDialog:onBack()
    -- Back inside a browser leaves it for this tab's landing (state stays
    -- cached on the browser objects). Only a back on a landing closes the
    -- whole dashboard — the ✕ on the header does the same. Everything is a
    -- flashless "ui" repaint: this is an in-place state change, never a
    -- flicker-worthy transition. It delegates to the browser's own leave()
    -- so its _closed flag flips too (the picker uses it to gate its deferred
    -- title upgrade).
    if self.send_screen == "files" then
        if self.send_picker then self.send_picker:leave() end
    elseif self.send_screen == "destination" then
        if self.dest_browser then self.dest_browser:leave() end
    elseif self.delete_screen then
        if self.delete_browser then self.delete_browser:leave() end
    else
        UIManager:close(self)
    end
    return true
end

-- The Storefront-style brand lockup: the plugin logo (icon.png beside this
-- file) as a small 24px glyph with "CrossDrop" to its right, all the way in
-- the top-left corner of the title row, with the ✕ that leaves the plugin on
-- the far right (the dashboard's only ✕). A hairline rules the bottom of the
-- row in place of TitleBar's bottom line. No image on disk, no logo and no
-- dead gap — a stripped install just gets the title, and self.logo_shown
-- mirrors that for tests/Send-more flow.
function HomeDialog:buildHeader(inner_w, sc)
    local theme = require("crossdrop_theme")
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local logo
    if ok and lfs and lfs.attributes then
        local dir = (self.plugin and self.plugin.path) or LUA_PLUGIN_DIR
        -- The lockup glyph is the logo BLACKENED and hardened on white BEFORE
        -- scaling: icon.png is a near-black mark on white whose anti-aliased
        -- edges lighten when the 360px master is squeezed to 24px (it read as
        -- grey next to the wordmark). assets/logo-black.png is the same mark
        -- re-thresholded to pure black/white, so the small glyph stays black.
        -- If a designer ships a dedicated monochrome asset later, this is the
        -- file to replace.
        local dir_assets = dir and (dir .. "/assets")
        local black = dir_assets and (dir_assets .. "/logo-black.png") or nil
        local icon = nil
        if black and lfs.attributes(black, "mode") == "file" then
            icon = black
        elseif dir then
            local plain = dir .. "/icon.png"
            if lfs.attributes(plain, "mode") == "file" then
                icon = plain
            end
        end
        if icon then
            logo = ImageWidget:new{
                file = icon,
                width = sc(24),
                height = sc(24),
                -- opaque-on-white glyph: bake it flat like a core icon (no
                -- alpha path, nothing to blend, nothing to grey out).
                is_icon = true,
            }
        end
    end
    self.logo_shown = logo ~= nil

    local title_label = TextWidget:new{
        text = _("CrossDrop"),
        face = Font:getFace("smallinfofont", theme.title_font_size or 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local logo_w = 0
    if logo and type(logo.getSize) == "function" then
        local s = logo:getSize()
        logo_w = s and s.w or sc(24)
    end
    local title_w = 0
    if type(title_label.getSize) == "function" then
        local s = title_label:getSize()
        title_w = s and s.w or 0
    end

    -- The ✕ that leaves the plugin. This EXACTLY follows the two recipes that
    -- work on the device: core TitleBar's right-hand ✕ and Storefront's close
    -- button — an IconButton with width/height = the glyph size, padding
    -- adding the tap zone, polished off with allow_flash = false (the rule for
    -- any control that closes the container holding it). A bare Button here
    -- once left a stuck grey highlight instead of closing.
    local close_btn = IconButton:new{
        icon = "close",
        width = sc(24),
        height = sc(24),
        padding = sc(12),
        bordersize = 0,
        background = nil,
        allow_flash = false,
        show_parent = self,
        callback = function()
            UIManager:close(self)
        end,
    }

    local elems = {}
    if logo then
        elems[#elems + 1] = logo
        elems[#elems + 1] = HorizontalSpan:new{ width = sc(8) }
    end
    elems[#elems + 1] = title_label
    elems[#elems + 1] = HorizontalSpan:new{
        width = math.max(sc(8), inner_w - logo_w - sc(8) - title_w - sc(48) - sc(4)),
    }
    elems[#elems + 1] = close_btn

    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new(elems),
        VerticalSpan:new{ width = sc(6) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.thick },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }
end

function HomeDialog:onCloseWidget()
    if self.plugin then
        self.plugin.home = nil
    end
    return true
end

-- ─────────────────────────────── tab bar ─────────────────────────────────

function HomeDialog:showTab(key)
    -- Re-tapping the ACTIVE tab backs out to that tab's landing (same as the
    -- back chevron inside a browser): the browser hides, its state (picked
    -- files, tree pages, search filter) stays cached on the browser object.
    -- A re-tap while already on a landing is a no-op.
    if self.tab == key then
        local backed = false
        if key == "send" and self.send_screen ~= nil then
            self.send_screen = nil
            backed = true
        elseif key == "delete" and self.delete_screen ~= nil then
            self.delete_screen = nil
            backed = true
        end
        if not backed then return end
        self:init()
        UIManager:setDirty(self, "ui")
        return
    end
    -- NOTE: there is NO UIManager:replace in this KOReader build (it crashed
    -- the plugin on the Kindle). Re-init the SAME widget for its new tab and
    -- repaint it in place instead. "ui" (not "partial"): flashless AND never
    -- promoted — the panel promotes every FULL_REFRESH_COUNT-th bare partial
    -- to a flashing full, which is exactly the "random" flashing the
    -- dashboard used to show.
    self.tab = key
    -- Switching tabs always lands on the target tab's LANDING: any browser
    -- open on the old tab hides, while its state (picked files, tree pages,
    -- search filter) stays cached on the browser object for the next open.
    -- The ✕ on the header is still the only thing that leaves the plugin.
    if key == "delete" then self.delete_screen = nil end
    if key == "send" then self.send_screen = nil end
    self:init()
    UIManager:setDirty(self, "ui")
end

-- The tab bar is Storefront's, with one user-facing divergence: EVERY tab
-- keeps its label visible (active = bold black + full-width underline;
-- inactive = grey), because here "Connections / Send A File / Delete Files"
-- are words, not guessable symbols — icons always sit beside the labels
-- they explain. The plugin SHIPS no glyphs; until assets/* exist the bar
-- falls back to label-only and still reads perfectly. Equal fixed widths
-- keep the bar exactly filling the row (a third long tab once pushed an
-- auto-sized bar off screen); tabs are InputContainers over image/text
-- blocks centered in each window, the same tap recipe as the picker rows.
function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local theme = require("crossdrop_theme")
    local tabs = {
        { key = "connections", label = _("Connections") },
        { key = "send", label = _("Send A File") },
        { key = "delete", label = _("Delete Files") },
    }
    local gaps = sc(6) * (#tabs - 1)
    local btn_w = math.floor((content_w - gaps) / #tabs)
    local tab_font = theme.face_label_size or 18
    local icons = self:tabIconPaths()
    local widgets = {}
    for i, t in ipairs(tabs) do
        if i > 1 then
            widgets[#widgets + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        local active = self.tab == t.key
        local icon = icons and icons[t.key]
        local elems = {}
        if icon then
            elems[#elems + 1] = ImageWidget:new{
                file = active and icon.active or icon.inactive,
                width = sc(22),
                height = sc(22),
                -- is_icon makes ImageWidget bake a transparent PNG onto white
                -- at load time (the core elevated-icon path): no alpha blit,
                -- so a glyph can never paint itself black on this panel.
                is_icon = true,
            }
            elems[#elems + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        elems[#elems + 1] = TextWidget:new{
            text = t.label,
            face = Font:getFace("smallinfofont", tab_font),
            bold = active,
            fgcolor = active and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        local row = HorizontalGroup:new(elems)
        local underline
        if active then
            underline = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = btn_w, h = sc(3) },
            }
        else
            underline = VerticalSpan:new{ width = sc(3) }
        end
        local group = VerticalGroup:new{
            align = "center",
            row,
            VerticalSpan:new{ width = sc(4) },
            underline,
        }
        local gh = type(group.getSize) == "function" and (group:getSize().h or sc(40)) or sc(40)
        local tab_btn = InputContainer:new{
            FrameContainer:new{
                padding_top = sc(4),
                padding_bottom = 0,
                bordersize = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = btn_w, h = gh },
                    group,
                },
            },
        }
        tab_btn.show_parent = self
        tab_btn.isFocusable = function() return true end
        tab_btn.onTap = function()
            self:showTab(t.key)
            return true
        end
        tab_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local d = tab_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        return Geom:new{
                            x = d.x or 0,
                            y = d.y or 0,
                            w = d.w or 0,
                            h = d.h or 0,
                        }
                    end,
                },
            },
        }
        widgets[#widgets + 1] = tab_btn
    end
    return HorizontalGroup:new(widgets)
end

-- Resolve the optional tab glyphs (plugin-local assets/). Storefront's
-- convention, adapted: each tab needs two monochrome variants — the inactive
-- grey glyph (tab-<key>.<ext>) and the active black one (tab-<key>-active.<ext>).
-- Both must exist for a tab's icon to show, which keeps the label fallback
-- above honest. Plain PNGs are the proven-safe render path on this device
-- (icon.png months of uptime); a true vector .svg with the same names is
-- also accepted when one is ever exported. Never throws when assets/ is
-- absent (lfs is stubbed in harness and real on-device).
function HomeDialog:tabIconPaths()
    if self._tab_icon_paths then return self._tab_icon_paths end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs or not lfs.attributes then return nil end
    local has = function(p) return lfs.attributes(p, "mode") == "file" end
    local dir = (self.plugin and self.plugin.path) or LUA_PLUGIN_DIR
    if not dir then return nil end
    local keys = { "connections", "send", "delete" }
    local out = {}
    for _, key in ipairs(keys) do
        local inactive, active
        for _, ext in ipairs({ "png", "svg" }) do
            local base = dir .. "/assets/tab-" .. key
            local inc = base .. "." .. ext
            local act = base .. "-active." .. ext
            if has(inc) and has(act) then
                inactive, active = inc, act
                break
            end
        end
        if inactive and active then
            out[key] = { inactive = inactive, active = active }
        end
    end
    self._tab_icon_paths = next(out) and out or nil
    return self._tab_icon_paths
end

function HomeDialog:row(text, opts)
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = self.row_w,
        callback = opts and opts.callback,
        hold_callback = opts and opts.hold_callback,
    }
end

function HomeDialog:header(text)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        padding_top = sc(6),
        padding_bottom = sc(2),
        bordersize = 0,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont"),
        },
    }
end

-- The Send/Delete tab body. Everything runs BELOW the always-visible brand
-- header + tab bar: the send state machine, the idle landing, or one of the
-- inline browsers (file picker on "files", destination tree on "destination",
-- delete tree on "tree"). Each browser paints itself into a fresh
-- VerticalGroup sized to the tab content region (area_h == self.content_h).
function HomeDialog:buildTabContent(tab, width, area_h)
    self.row_w = width
    if tab == "connections" then
        return self:renderConnections()
    end
    if tab == "delete" then
        if self.delete_screen == "tree" then
            return self:renderDeleteBrowser(area_h)
        end
        return self:renderDelete()
    end
    if self.send_screen == "files" then
        return self:renderFilesBrowser(area_h)
    end
    if self.send_screen == "destination" then
        return self:renderDestinationBrowser(area_h)
    end
    if self.send_state == "connecting" then
        return self:renderSendConnecting()
    end
    if self.send_state == "sending" then
        return self:renderSendWaiting()
    end
    if self.send_state == "done" then
        return self:renderSendDone()
    end
    if self.send_state == "failed" then
        return self:renderSendFailed()
    end
    return self:renderSendIdle()
end

-- ─────────────────── Send tab browsers (inline, below the tabs) ───────────────────
-- The user rule: the brand header and the tab bar NEVER leave the screen.
-- Picking files, choosing the destination and deleting all happen inside the
-- active tab's content region — no stacked full-screen dialogs — and every
-- back/leave/tab-switch returns to the tab's landing with the browser's
-- state (picked files, expanded nodes, page) cached on the browser object.

function HomeDialog:renderFilesBrowser(area_h)
    local vg = VerticalGroup:new{ align = "left" }
    local picker = self.send_picker
    if not picker then
        picker = pickerModule():new{ plugin = self.plugin, home = self }
        self.send_picker = picker
    end
    picker:renderInto(vg, self.row_w, area_h or self.content_h)
    return vg
end

function HomeDialog:renderDestinationBrowser(area_h)
    local vg = VerticalGroup:new{ align = "left" }
    if self.dest_browser then
        self.dest_browser:renderInto(vg, self.row_w, area_h or self.content_h)
    end
    return vg
end

function HomeDialog:renderDeleteBrowser(area_h)
    local vg = VerticalGroup:new{ align = "left" }
    if self.delete_browser then
        self.delete_browser:renderInto(vg, self.row_w, area_h or self.content_h)
    end
    return vg
end

-- Open/leave the inline file browser (chooseAndSend wires into this).
function HomeDialog:openFilesBrowser()
    if not self.send_picker then
        self.send_picker = pickerModule():new{ plugin = self.plugin, home = self }
    end
    self.send_picker._closed = false
    self.tab = "send"
    self.send_screen = "files"
    self:refresh()
end

function HomeDialog:leaveFilesBrowser()
    self.send_screen = nil
    self:refresh()
end

-- ─────────────────────── Connections tab ────────────────────────────────

function HomeDialog:targetFor(kind)
    for _, t in ipairs(self.plugin:configuredTargets() or {}) do
        if t.kind == kind then
            return t
        end
    end
    return nil
end

-- Tap-to-check the WiFi row, gated by ensureWifi (Storefront-style). Where
-- the radio is already up (Android, Cervantes, non-KOReader-managed) ensureWifi
-- is a synchronous fast path and this behaves exactly like the old build; on
-- a KOReader-managed radio (Kobo) the link is brought up BEFORE probing, so a
-- probe can't aim at a dead interface and read a false "Offline".
function HomeDialog:check(kind)
    local target = self:targetFor(kind)
    if not target then return end
    self.plugin:ensureWifi(function()
        self:probeAndShow(kind)
    end, function()
        self:showCheckFailure(kind, _("Wi-Fi could not be turned on"))
    end)
end

-- The probe itself, run with standby held for the whole blocking call
-- (UIManager:preventStandby, pcall-guarded, released afterward): on
-- KOReader-managed radios a power-save suspend would tear the link down
-- mid-probe and read as a false "Offline". The probe retries (3s then 6s)
-- inside main.lua, so this tap still paints a notice first and never looks
-- frozen if the reader answers on a late attempt.
function HomeDialog:probeAndShow(kind)
    local target = self:targetFor(kind)
    if not target then return end
    local checking = Notification:new{
        text = _("Checking WiFi\226\128\166"),
        timeout = 0,
    }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local run_ok, ok, info, err = self.plugin:withStandby(function()
        return self.plugin:probeTarget(self:targetFor(kind))
    end)
    UIManager:close(checking)
    if not run_ok then
        self:showCheckFailure(kind, tostring(ok or "probe aborted"))
        return
    end
    local reach = self.plugin._reach or {}
    reach[kind] = ok and "ok" or "down"
    self.plugin._reach = reach
    if ok then
        local who = info and info.device and tostring(info.device) or "CrossDrop reader"
        local ver = info and info.version and tostring(info.version) or ""
        local text = _("WiFi reachable: ")
            .. who .. (ver ~= "" and ("  v" .. ver) or "")
        UIManager:show(Notification:new{ text = text, timeout = 4 })
    else
        self:showCheckFailure(kind, tostring(err or "network error"))
    end
    self:repaintCheck()
end

-- Shared failure path: same message/popup/repaint as the old inline "down"
-- branch, so a failed check (probe, or Wi-Fi that never came up) updates the
-- status dot and the screen consistently.
function HomeDialog:showCheckFailure(kind, why)
    local text = _("Could not reach WiFi: ") .. why
    UIManager:show(Notification:new{ text = text, timeout = 5 })
    local reach = self.plugin._reach or {}
    reach[kind] = "down"
    self.plugin._reach = reach
    self:repaintCheck()
end

-- Repaint the dashboard in place after a check: "ui" refresh — flashless,
-- never promoted to a flashing full (partials are).
function HomeDialog:repaintCheck()
    UIManager:setDirty(self, "ui")
    self:init()
end

-- Repaint the dashboard in place after a setting change (an IP edit happens
-- under a modal InputDialog, so the re-init must wait until that dialog is off
-- the stack). This is what makes a saved IP show up on the Connections tab
-- without reopening the dashboard. A partial update (no flash): the IP row
-- changed in place under a closed modal.
function HomeDialog:refresh()
    UIManager:nextTick(function()
        self.plugin._reach = {}
        self:init()
        -- "ui": flashless and never promoted to a flashing full (partials are).
        UIManager:setDirty(self, "ui")
    end)
end

function HomeDialog:renderConnections()
    local vg = VerticalGroup:new{ align = "left" }
    local reach = self.plugin._reach or {}

    table.insert(vg,self:header(_("WiFi connection")))
    local wifi = self:targetFor("wifi")
    if wifi then
        table.insert(vg,self:row(
            string.format("WiFi   %s\n%s  \226\128\164  %s", ip_str(wifi),
                _("File Transfer \226\134\146 Join Network"), status_word(reach.wifi)), {
            callback = function() self:check("wifi") end,
        }))
    end
    table.insert(vg,self:row(_("Set WiFi IP\226\128\166"), {
        callback = function() self.plugin:editIp("wifi", function() self:refresh() end) end,
    }))

    -- Setup guide for a first-time reader (the space the WiFi rows need
    -- between the controls and the text). Steps mirror the buttons directly
    -- above, so a new user reads exactly where each action happens. The
    -- version line sits ABOVE the guide: at the guide's tail it ran off the
    -- bottom of the panel. The guide itself uses the smaller info font so
    -- the steps (some wrap to 2-3 lines) fit with room to spare.
    local sc = function(v) return Device.screen:scaleBySize(v) end
    table.insert(vg, VerticalSpan:new{ width = sc(10) })
    table.insert(vg, TextBoxWidget:new{
        text = "CrossDrop " .. tostring((self.plugin and self.plugin.VERSION) or ""),
        face = Font:getFace("smallinfofontbold"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(6) })
    table.insert(vg, TextBoxWidget:new{
        text = _("To receive files, set up your Xteink device like this:\n")
            .. _("1. Put the Xteink and this Kindle on the same Wi-Fi network.\n")
            .. _("2. With CrossPoint running on the Xteink, open File Transfer and tap \"Join WiFi Network\".\n")
            .. _("3. On that screen, the device's IP address is below the QR code.\n")
            .. _("4. Tap \"Set WiFi IP\" to enter that address.\n")
            .. _("5. Then tap the connection row above to check \226\128\148 it should read \"Reachable\" when connected.\n")
            .. _("6. Send from the Send A File tab: pick files from the list, or send the currently open file. Pick the destination folder there too \226\128\148 it defaults to CrossDropped Files on the reader.\n")
            .. _("7. Wi-Fi routers can hand the reader a new address from time to time. If you run into any connection issue, it may be because the IP has changed \226\128\148 check it on the reader's Join Network screen and update it with \"Set WiFi IP\"."),
        face = Font:getFace("xx_smallinfofont"),
        width = self.row_w,
    })

    return vg
end

-- ─────────────────────────── Send tab ───────────────────────────────────

-- Idle: pick files, or send the one that is open (and only shown when it is),
-- plus a Destination folder row that lists the reader's folders or takes a
-- typed-in name (the CrossDropped Files default when nothing is chosen).
function HomeDialog:renderSendIdle()
    local vg = VerticalGroup:new{ align = "left" }
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local book = self.plugin:currentBookPath()

    table.insert(vg,self:header(_("Send one or more files")))
    table.insert(vg,self:row(_("Click Here To Select File(s)"), {
        callback = function() self.plugin:chooseAndSend() end,
    }))

    -- "Currently open" only appears when there IS an open book AND the
    -- reader can open it (the Xteink list: epub/xtc/xtch/txt/bmp — sending
    -- anything else would ship the user a file their device can't open).
    -- Both book sections breathe with a spacer so the Destination folder
    -- block sits clearly apart.
    if book and book ~= "" and self.plugin:isCrossPointFile(book) then
        table.insert(vg, VerticalSpan:new{ width = sc(18) })
        local name = book:match("([^/]+)$") or book
        local size = file_size(book)
        table.insert(vg,self:header(_("Currently open")))
        table.insert(vg,self:row(
            string.format("\226\151\128  %s\n%s  \226\128\164  tap to send", name,
                (size > 0 and string.format(_("%.1f MB"), size / 1048576) or "ebook")), {
            callback = function()
                -- one-tap send (no picker, so no whole-card index): guard the
                -- duplicate before the stream starts
                self.plugin:guardDuplicates({ book }, function()
                    self:beginSendBatch({ book })
                end)
            end,
        }))
    end

    -- Destination folder: shows which reader folder (full nested path) books
    -- land in. Always available (even offline) — picking a listed folder or
    -- typing a new name/path only needs the reader when a send later creates
    -- or uses it.
    table.insert(vg, VerticalSpan:new{ width = sc(18) })
    local target = self.plugin:resolveTarget()
    local dest_raw = folder_str(target)
    local dest_name = tostring(dest_raw):gsub("^/+", ""):gsub("/+$", "")
    if dest_name == "" then dest_name = folder_basename(dest_raw) end
    table.insert(vg, self:header(_("Destination folder")))
    table.insert(vg, self:row(
        string.format("%s\n%s  \226\128\164  tap to choose",
            dest_name, _("folder on the reader")), {
        callback = function() self:chooseDestination() end,
    }))

    return vg
end

-- ─────────────────────── destination folder tree ────────────────────────
-- A full-screen modal (the dashboard's own full-screen look, like the picker:
-- TitleBar + Button rows on a white card — this device renders NO other
-- widget language). The destination picker is a FOLDER TREE, the way a
-- computer file browser works:
--
--   · the card root is listed first;
--   · every folder row carries an expand ▸ (or ▾ when open). Tapping the
--     arrow fetches (GET /api/files?path=) and shows what is nested,
--     indented under it so subfolders read as subfolders;
--   · an open folder with no subfolders shows only
--     "No subfolders found in /X" under it;
--   · tapping the folder NAME opens a small action menu: Select (make it
--     the destination), Create Subfolder… (picks /X/<name> and adds it to
--     the tree), Cancel;
--   · folder rows are BOXLESS (bare text, like the picker's book rows);
--     action menu rows keep their box so actions stay distinct;
--   · when the reader is unreachable the dialog shows ONLY
--     "Device not found. Please check Xteink IP, and confirm that it
--     matches in Connections." — no retry rows, no typed-path fallback.

local TREE_INDENT = 24  -- scaled px of indentation per depth level
local TREE_ARROW_W = 44 -- scaled px of the ▸/▾ expand control (a real tap target)

-- One folder in the tree.
local function new_node(name, path, depth)
    return {
        name = name,
        path = path,                  -- relative, no leading slash ("Books/Fiction")
        depth = depth,                -- 0 == card root
        children = nil,               -- sorted child nodes, or nil until loaded
        expanded = false,             -- showing its children inline?
        pending = false,              -- created this session, not yet on the reader
    }
end

local DestinationDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,     -- CROSSDROP instance (setFolder / listFolders)
    home = nil,       -- the HomeDialog to refresh after a pick
    nodes = nil,      -- root folder tree (a new_node list)
    list_err = nil,   -- reader unreachable → message-only body
    selected = nil,   -- chosen destination (relative path; nil == default)
    page = nil,       -- current page of the (possibly long) visible tree
    rows_per_page = nil,
}

-- Find a node by its path (depth-first search over the whole tree).
function DestinationDialog:findNode(path)
    local function walk(list)
        for _, n in ipairs(list) do
            if n.path == path then return n end
            if n.children then
                local hit = walk(n.children)
                if hit then return hit end
            end
        end
        return nil
    end
    return walk(self.nodes or {})
end

-- Repaint the tree in place, flash-free (the no-flash rule of the dashboard).
-- "ui" (not "partial"): flashless AND never promoted — the panel promotes
-- every FULL_REFRESH_COUNT-th bare partial to a flashing full, which read as
-- "random" flashes while browsing the tree. Inline, the repaint is the
-- dashboard's own refresh — the tree lives inside Home, so the brand header
-- and tabs stay painted while it rebuilds.
function DestinationDialog:repaint()
    if self.home and type(self.home.refresh) == "function" then
        self.home:refresh()
        return
    end
    self:init()
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
end

function DestinationDialog:rebuild()
    self:repaint()
end

-- Choose `path` as the destination and leave the tree (landing + refresh:
-- the Send tab's destination row now shows the chosen folder).
function DestinationDialog:pick(path)
    if self.plugin.setFolder then
        self.plugin:setFolder(path)
    end
    if type(path) == "string" and path ~= "" then
        self.selected = tostring(path):gsub("^/+", ""):gsub("/+$", "")
    end
    self:leave()
end

-- Leave the tree WITHOUT changing the destination (the back chevron and the
-- ✕): back to the Send tab's landing, refreshed so its destination row shows
-- the folder as it stands — including a subfolder created here but not yet
-- on the reader (it materializes when a book is sent).
function DestinationDialog:leave()
    if self.home and type(self.home.refresh) == "function" then
        self.home.send_screen = nil
        self.home:refresh()
        return
    end
    local home = self.home
    UIManager:close(self)
    UIManager:nextTick(function()
        if home and home.refresh then home:refresh() end
    end)
end

-- Tap the ▸/▾ control: expand (fetching children if needed) or collapse.
function DestinationDialog:toggleNode(node)
    if node.expanded then
        node.expanded = false
    else
        self:expandNode(node)
    end
    self:rebuild()
end

-- Open a folder: fetch its children once (GET /api/files?path=), or expand
-- from cache. A just-created (pending) folder opens locally without a fetch.
-- An empty folder still opens — its only content is the
-- "No subfolders found in /X" note.
function DestinationDialog:expandNode(node)
    if node.expanded then return end
    if node.pending then
        node.children = node.children or {}
        node.expanded = true
        self:rebuild()
        return
    end
    if node.children == nil then
        local target = self.plugin:resolveTarget()
        if not target or not target.ip or target.ip == "" then
            self.list_err = true
            self:rebuild()
            return
        end
        local checking = Notification:new{ text = _("Looking up folders\226\128\166"), timeout = 0 }
        UIManager:show(checking)
        UIManager:forceRePaint()
        local ok, folders, err = self.plugin:listFolders(target, node.path)
        UIManager:close(checking)
        if not ok then
            self.list_err = true
            self:rebuild()
            return
        end
        node.children = {}
        for _, name in ipairs(folders) do
            node.children[#node.children + 1] = new_node(name, node.path .. "/" .. name, node.depth + 1)
        end
    end
    node.expanded = true
    self:rebuild()
end

-- The folder NAME tap: the tiny action popup (Select / Create Subfolder /
-- Cancel), built like the picker's send-confirmation ConfirmBox — a small
-- bordered card centered over the tree, not a full page. Shown with a
-- flashless "ui" refresh exactly like that popup; only page-level state
-- transitions (opening the tree, leaving the plugin) warrant the flashing
-- full refresh on this panel.
function DestinationDialog:showFolderMenu(node)
    local popup = FolderMenuDialog:new{
        plugin = self.plugin,
        tree = self,
        node = node,
    }
    -- "ui" refresh of ONLY the popup's box region (the third arg to show):
    -- flashless, never promoted, and no whole-screen sweep for a 3-row card.
    UIManager:show(popup, "ui", popup.region)
    UIManager:forceRePaint()
end

-- Create a new subfolder under `node` (from the folder menu). The name is a
-- single folder name (no slashes — the tree handles nesting). The folder is
-- picked as the destination and added to the tree as a pending child; it
-- exists on the reader once a book is sent to it. The dashboard behind the
-- tree is refreshed too, so its destination row already shows /X/<name> —
-- the folder does not exist yet, but that IS where books will land.
function DestinationDialog:addSubfolder(node, name)
    local full = node.path .. "/" .. name
    if self.plugin.setFolder then
        self.plugin:setFolder(full)
    end
    self.selected = full
    node.children = node.children or {}
    local already = false
    for _, c in ipairs(node.children) do
        if c.name == name then already = true break end
    end
    if not already then
        local child = new_node(name, full, node.depth + 1)
        child.pending = true
        node.children[#node.children + 1] = child
        table.sort(node.children, function(a, b) return a.name < b.name end)
    end
    node.expanded = true
    self:rebuild()
    if self.home and self.home.refresh then
        self.home:refresh()
    end
end

-- INLINE render (the user's rule: everything below the brand + tabs): paint
-- the tree into an existing VerticalGroup bounded by the tab content region.
-- The headers, rows/page-strip and the Default footer are measured against
-- the AREA height exactly like the old full-screen card tallied, so the page
-- controls keep strapping to the bottom edge. Shared by the tab content
-- builder AND the standalone init() below.
function DestinationDialog:renderInto(vg, area_w, area_h)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    if area_w then self.row_w = area_w end
    if area_h then self.content_h = area_h end
    local ph = function(w)
        local s = w.getSize and w:getSize()
        return (s and s.h) or 0
    end

    -- The Default footer is built FIRST and measured, because the page-nav
    -- strip above it must save exactly this much room — it stays visible on
    -- every page as the "reset destination" escape hatch.
    local dest_label = (self.selected and ("/" .. self.selected)) or folder_str(self.plugin:resolveTarget())
    local dest_header = self:foldersHeader(_("Destination: ") .. dest_label)
    local folders_header = self:foldersHeader(_("Folders on the reader"))
    local default_header = self:foldersHeader(_("Default"))
    local default_row = self:plainRow(_("CrossDropped Files (back to the default)"),
        function() self:pick("CrossDropped Files") end)
    self.default_h = ph(default_header) + ph(default_row)

    -- Rows per page MEASURED from one real row PLUS its hairline separator
    -- (the delete browser's probe). The budget is the content height minus
    -- the two headers above the tree, the page-nav strip in its tallest form
    -- (both buttons visible), and the Default footer below it. Setting
    -- self.rows_per_page before init skips the probe (how the tests pin it).
    if not self.rows_per_page then
        local probe = VerticalGroup:new{}
        self:treeRowInto(probe, new_node("sample", "sample", 0), 0)
        table.insert(probe, self:separator())
        local rh = (probe:getSize() and probe:getSize().h) or sc(60)
        local top_h = ph(dest_header) + ph(folders_header)
        local strip = VerticalGroup:new{ align = "left" }
        table.insert(strip, self:separator())
        table.insert(strip, self:caption(string.format(_("Page %d of %d"), 1, 1)))
        table.insert(strip, VerticalSpan:new{ width = sc(2) })
        table.insert(strip, self:menuRow(_("Previous page"), function() end))
        table.insert(strip, self:menuRow(_("Next page"), function() end))
        local strip_h = (strip:getSize() and strip:getSize().h) or sc(150)
        local avail = math.max(1, self.content_h - top_h - strip_h - self.default_h)
        self.rows_per_page = math.max(1, math.floor(avail / math.max(rh, 1)))
    end

    table.insert(vg, dest_header)

    if self.list_err then
        -- The reader is unreachable: ONLY this message, nothing else.
        table.insert(vg, TextBoxWidget:new{
            text = _("Device not found. Please check Xteink IP, and confirm that it matches in Connections."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    else
        table.insert(vg, folders_header)

        -- Paged rendering (the delete browser's recipe): long trees slice
        -- into pages; the page clamps when the tree shortens. The Default
        -- footer stays visible under the tree, bottom-tacked with the
        -- page-nav strip above it.
        local nodes = self.nodes or {}
        if #nodes > 0 then
            self:appendPaged(vg)
        else
            table.insert(vg, TextBoxWidget:new{
                text = _("No folders on the reader."),
                face = Font:getFace("smallinfofont"),
                width = self.row_w,
            })
        end
        table.insert(vg, default_header)
        table.insert(vg, default_row)
    end
end

function DestinationDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    -- Back chevron top-left returns to the dashboard. There is NO ✕ here:
    -- the dashboard is still behind this page, and X is reserved for leaving
    -- the plugin entirely (only the home dashboard carries it).
    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Destination folder"),
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "chevron.left",
        left_icon_tap_callback = function() self:leave() end,
        show_parent = self,
    }

    -- The whole page fills the screen (the delete browser's rule): the tree
    -- rows plus the page-nav strip plus the Default footer below it must
    -- exactly match the card's inner height, so rows are counted from the
    -- measured chrome, not guessed.
    local tb_size = title_bar.getSize and title_bar:getSize()
    self.title_h = (tb_size and tb_size.h) or sc(80)

    local vg = VerticalGroup:new{ align = "left" }
    self:renderInto(vg, inner_w, (sh - pad * 2) - self.title_h - sc(16))

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
            vg,
        },
    }
    self.frame = frame
    self[1] = frame
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- The visible tree flattened into display-order rows: folder rows, plus
-- the "No subfolders found in /X" note rows of empty expanded folders.
function DestinationDialog:visibleRows()
    local rows = {}
    local function walk(nodes, depth)
        for i = 1, #nodes do
            local n = nodes[i]
            rows[#rows + 1] = { node = n, depth = depth }
            if n.expanded then
                local kids = n.children or {}
                if #kids > 0 then
                    walk(kids, depth + 1)
                else
                    rows[#rows + 1] = { note = n, depth = depth }
                end
            end
        end
    end
    walk(self.nodes or {}, 0)
    return rows
end

-- Paged rendering (the picker's device-proven recipe): long trees slice
-- into pages with Previous/Next rows; the page clamps when the tree
-- shortens. The Default section always stays visible under the tree.
-- Paged rendering in the DELETE browser's exact presentation (hairline
-- separators between rows, a caption plus boxed Previous/Next strip) — the
-- two trees now read as the same screen. The strip is strapped to the very
-- bottom of the card: a flexible spacer under the last tree row soaks up
-- whatever the measured rows left over, saving exactly the room the Default
-- footer (measured into self.default_h at init) needs below it.
function DestinationDialog:appendPaged(vg)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local rows = self:visibleRows()
    local rpp = self.rows_per_page
    local max_page = math.max(1, math.ceil(#rows / rpp))
    if (self.page or 1) > max_page then self.page = max_page end
    self.page = math.max(1, self.page or 1)
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#rows, self.page * rpp)
    for i = lo, hi do
        local r = rows[i]
        local indent = math.min(r.depth * sc(TREE_INDENT), sc(140))
        if r.note then
            table.insert(vg, HorizontalGroup:new{
                HorizontalSpan:new{ width = indent + sc(TREE_ARROW_W) + sc(6) },
                TextBoxWidget:new{
                    text = string.format(_("No subfolders found in /%s"), r.note.path),
                    face = Font:getFace("smallinfofont"),
                    width = math.max(self.row_w - indent - sc(TREE_ARROW_W) - sc(6), 1),
                },
            })
        else
            self:treeRowInto(vg, r.node, indent)
        end
        if i < hi then
            table.insert(vg, self:separator())
        end
    end
    -- Page navigation: the delete browser's strip — separator, caption,
    -- boxed rows, only the buttons that apply — bottom-tacked by the
    -- flexible filler, with the Default footer still below it on the card.
    if #rows > rpp then
        local strip = VerticalGroup:new{ align = "left" }
        table.insert(strip, self:separator())
        table.insert(strip, self:caption(string.format(_("Page %d of %d"), self.page, max_page)))
        table.insert(strip, VerticalSpan:new{ width = sc(2) })
        if self.page > 1 then
            table.insert(strip, self:menuRow(_("Previous page"),
                function() self:gotoPage(self.page - 1) end))
        end
        if hi < #rows then
            table.insert(strip, self:menuRow(_("Next page"),
                function() self:gotoPage(self.page + 1) end))
        end
        if self.content_h then
            local busy = (vg.getSize and vg:getSize().h) or 0
            local strip_h = (strip.getSize and strip:getSize().h) or 0
            local filler = math.floor(math.max(0,
                self.content_h - busy - strip_h - (self.default_h or 0)))
            if filler > 0 then
                table.insert(vg, VerticalSpan:new{ width = filler })
            end
        end
        for i = 1, #strip do
            table.insert(vg, strip[i])
        end
    end
end

function DestinationDialog:gotoPage(n)
    self.page = math.max(1, n)
    self:init()
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
end
-- One tree row: the ▸/▾ expand control and the folder name are SEPARATE
-- buttons (separate tap targets), placed after the indentation. Tapping
-- the control opens/closes the folder's sub-tree INLINE (children appear
-- indented under it, other root folders stay visible); tapping the folder
-- NAME opens the tiny Select / Create Subfolder / Cancel popup.
function DestinationDialog:treeRowInto(vg, node, indent)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local is_expanded = node.expanded
    local arrow_text = is_expanded and "\226\150\190" or "\226\150\184" -- ▾ / ▸

    local toggle = Button:new{
        text = arrow_text,
        width = sc(TREE_ARROW_W),
        align = "center",
        bordersize = 0,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        padding_h = 0,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 28, -- bigger glyph than the row text: an easy tap target
        callback = function() self:toggleNode(node) end,
    }

    local name_text = node.name
    if node.path == self.selected then
        name_text = "\226\151\128  " .. name_text .. "   (" .. _("chosen") .. ")"
    end
    local name = Button:new{
        text = name_text,
        width = math.max(self.row_w - indent - sc(TREE_ARROW_W), 1),
        align = "left",
        bordersize = 0,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        padding_h = Size.padding.large,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        callback = function() self:showFolderMenu(node) end,
    }

    table.insert(vg, HorizontalGroup:new{
        HorizontalSpan:new{ width = indent },
        toggle,
        name,
    })
end

-- A plain boxless action row (boxless, to match the tree rows).
function DestinationDialog:plainRow(text, callback)
    return Button:new{
        text = text,
        width = self.row_w,
        align = "left",
        bordersize = 0,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        padding_h = Size.padding.large,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        callback = callback,
    }
end

function DestinationDialog:onBack()
    self:leave()
    return true
end

function DestinationDialog:foldersHeader(text)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        padding_top = sc(6),
        padding_bottom = sc(2),
        bordersize = 0,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont"),
        },
    }
end

-- The delete browser's exact presentation pieces (hairline separators, the
-- page caption, boxed page-nav rows), so the destination tree and the delete
-- tree read as ONE screen (they share the whole tree system).
function DestinationDialog:separator()
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

function DestinationDialog:caption(text)
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

function DestinationDialog:menuRow(text, callback)
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = self.row_w,
        callback = callback,
    }
end

-- ─────────────────────── folder action menu ────────────────────────────
-- Select / Create Subfolder… / Cancel for one tapped folder. Built like the
-- picker's send-confirmation ConfirmBox: a small bordered card, auto-sized
-- to its rows and centered over the tree via a full-screen CenterContainer
-- (the ConfirmBox recipe — this device renders no other popup language).
-- Action rows keep their box so the menu reads as actions, a step apart
-- from the boxless tree rows behind it.

FolderMenuDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,   -- CROSSDROP instance (setFolder)
    tree = nil,     -- the DestinationDialog to apply choices to
    node = nil,     -- the folder being acted on
}

-- Select: like the picker's send-confirmation, the work after the closes is
-- deferred with nextTick — running the close→close→dashboard-repaint chain
-- synchronously inside the tap handler froze the panel once on the device.
-- The close passes the popup's box region: only that hole repaints, not the
-- whole screen.
function FolderMenuDialog:onSelect()
    local tree, node = self.tree, self.node
    UIManager:close(self, "ui", self.region)
    UIManager:nextTick(function()
        if tree and node then tree:pick(node.path) end
    end)
end

function FolderMenuDialog:onCancel()
    UIManager:close(self, "ui", self.region)
end

-- Create a subfolder under this folder: a single-name input dialog. The new
-- folder becomes the destination and is added to the tree as a pending child.
function FolderMenuDialog:onCreate()
    local InputDialog = require("ui/widget/inputdialog")
    local menu = self
    local name_dialog
    name_dialog = InputDialog:new{
        title = _("New subfolder"),
        input = "",
        input_hint = string.format(_("Under /%s \226\128\148 created on the reader when a file is sent"), tostring(menu.node.path)),
        type = "text",
        modal = true,
        buttons = {
            {
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = name_dialog:getInputText() or ""
                        local name = text:match("^%s*(.-)%s*$") or ""
                        if name == "" then
                            UIManager:show(Notification:new{ text = _("Enter a folder name first."), timeout = 3 })
                            return
                        end
                        if name:find("/") then
                            UIManager:show(Notification:new{ text = _("One folder name only \226\128\148 no slashes."), timeout = 3 })
                            return
                        end
                        if name == "." or name == ".." then
                            UIManager:show(Notification:new{ text = _("That is not usable as a folder name."), timeout = 3 })
                            return
                        end
                        UIManager:close(name_dialog)
                        UIManager:close(menu)
                        -- nextTick, like Select: the close→rebuild repaint
                        -- chain must not run inside the tap handler.
                        UIManager:nextTick(function()
                            if menu.tree then menu.tree:addSubfolder(menu.node, name) end
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(name_dialog) end,
                },
            },
        },
    }
    UIManager:show(name_dialog)
end

function FolderMenuDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local pad = Size.padding.default
    -- The ConfirmBox look: the card is a modest share of the screen, sized
    -- to its three rows — nothing like a full page.
    local box_w = math.min(math.floor(sw * 0.6), sw - sc(40))
    local inner_w = box_w - pad * 2

    local vg = VerticalGroup:new{}
    table.insert(vg, VerticalSpan:new{ width = sc(4) })
    table.insert(vg, TextBoxWidget:new{
        text = string.format(_("/%s"), tostring(self.node and self.node.path or "")),
        face = Font:getFace("smallinfofontbold"),
        width = inner_w,
        alignment = "center",
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:menuRow(inner_w, _("Select"), function() self:onSelect() end))
    table.insert(vg, self:menuRow(inner_w, _("Create Subfolder\226\128\166"), function() self:onCreate() end))
    table.insert(vg, self:menuRow(inner_w, _("Cancel"), function() self:onCancel() end))
    table.insert(vg, VerticalSpan:new{ width = sc(4) })

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = pad,
        vg,
    }
    self.frame = frame
    -- Full-screen CenterContainer centers the small card over the tree:
    -- the ConfirmBox recipe (this is how KOReader centers popups).
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        frame,
    }
    self.dimen = Geom:new{ w = sw, h = sh }
    -- The popup's OWN box region (where the CenterContainer places the
    -- frame). UIManager:show/close accept a refresh region — passing this
    -- one refreshes ONLY the box on open and repaints ONLY the box-sized
    -- hole on close, instead of sweeping the whole screen both times.
    local fs = frame:getSize()
    local bw = fs and fs.w or box_w
    local bh = fs and fs.h or sh
    self.region = Geom:new{
        x = math.floor((sw - bw) / 2),
        y = math.floor((sh - bh) / 2),
        w = bw,
        h = bh,
    }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function FolderMenuDialog:menuRow(row_w, text, callback)
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = row_w,
        callback = callback,
    }
end

function FolderMenuDialog:onBack()
    UIManager:close(self, "ui", self.region)
    return true
end

-- Choose the destination: the folder tree opens INSIDE the Send tab (below
-- the brand header and tabs), never as a stacked full-screen dialog. The
-- root listing is one bounded attempt (socketutil); if the reader does not
-- answer, the tree opens with ONLY the "Device not found…" message — nothing
-- to retry or type around. No "Looking up…" notice first: against a
-- reachable reader the listing returns in milliseconds, and the notice's
-- show/close repaint cycle both added a paint to every open and raced the
-- tree's first paint. The browser object is parked on Home so its state
-- (expanded nodes, page) survives leaving; each open re-lists the root.
function HomeDialog:chooseDestination()
    local InfoMessage = require("ui/widget/infomessage")
    local target = self.plugin:resolveTarget()
    if not target or not target.ip or target.ip == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set the WiFi IP on the Connections tab first."),
        })
        return
    end
    local ok, folders = self.plugin:listFolders(target)
    local nodes
    if ok and folders then
        nodes = {}
        for _, name in ipairs(folders) do
            nodes[#nodes + 1] = new_node(name, name, 0)
        end
    end
    if self.dest_browser then
        self.dest_browser.nodes = nodes
        self.dest_browser.list_err = not ok
        self.dest_browser.page = nil
        self.dest_browser.rows_per_page = nil
    else
        self.dest_browser = DestinationDialog:new{
            plugin = self.plugin,
            home = self,
            nodes = nodes,
            list_err = not ok,
        }
    end
    self.tab = "send"
    self.send_screen = "destination"
    self:refresh()
end

-- The Delete Folders/Files tab body: its own screen (never mixed into Send
-- A Book), so a delete can't happen while picking books.
function HomeDialog:renderDelete()
    local vg = VerticalGroup:new{ align = "left" }
    local sc = function(v) return Device.screen:scaleBySize(v) end

    table.insert(vg, self:header(_("Delete on the reader")))
    table.insert(vg, self:row(_("Browse the reader and pick things to delete"), {
        callback = function() self:openDeleteTree() end,
    }))
    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, TextBoxWidget:new{
        text = _("Deleting happens on the reader itself. Folders take everything inside them.")
            .. "\n" .. _("Nothing is deleted until you confirm it on the popup."),
        face = Font:getFace("xx_smallinfofont"),
        width = self.row_w,
    })
    return vg
end

-- Open the delete tree: the destination tree's system, listing FILES too.
-- Inline like everything else — the tree paints into the Delete tab's
-- content region, so the brand header and tabs stay on screen. Same shape
-- as chooseDestination: one flashless "ui" pass, no notice.
function HomeDialog:openDeleteTree()
    local InfoMessage = require("ui/widget/infomessage")
    local target = self.plugin:resolveTarget()
    if not target or not target.ip or target.ip == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set the WiFi IP on the Connections tab first."),
        })
        return
    end
    local ok, entries = self.plugin:listEntries(target)
    local nodes
    if ok and entries then
        nodes = {}
        for _, e in ipairs(entries) do
            local n = new_node(e.name, e.name, 0)
            n.is_file = not e.is_dir
            nodes[#nodes + 1] = n
        end
    end
    if self.delete_browser then
        self.delete_browser.nodes = nodes
        self.delete_browser.list_err = not ok
        self.delete_browser.page = nil
        self.delete_browser.rows_per_page = nil
    else
        self.delete_browser = DeleteDialog:new{
            plugin = self.plugin,
            home = self,
            nodes = nodes,
            list_err = not ok,
        }
    end
    self.tab = "delete"
    self.delete_screen = "tree"
    self:refresh()
end

-- ───────────────────── delete tab (files & folders) ─────────────────────
-- A third tab, SEPARATE from Send A File on purpose: deleting is a
-- destructive act and gets its own screen so it can never happen by
-- accident while picking books. It reuses the destination tree's system
-- (▸/▾ inline expansion, boxless rows, tiny centered popups) but lists FILES
-- as well as folders. Every delete is confirmed first, a popup reports the
-- result, and the tree live-refreshes in place — no separate waiting screen.

-- Global (like FolderMenuDialog): openDeleteTree, defined above, shows it.
DeleteDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,     -- CROSSDROP instance (listEntries / deleteEntry)
    home = nil,       -- the HomeDialog to return to
    nodes = nil,      -- root tree (new_node list; file rows carry is_file)
    list_err = nil,   -- reader unreachable → message-only body
    page = nil,       -- current page of the (possibly long) visible tree
    rows_per_page = nil,
}

function DeleteDialog:findNode(path)
    local function walk(list)
        for _, n in ipairs(list) do
            if n.path == path then return n end
            if n.children then
                local hit = walk(n.children)
                if hit then return hit end
            end
        end
        return nil
    end
    return walk(self.nodes or {})
end

-- Remove `path` (and thus everything under it) from the cached tree.
function DeleteDialog:removeNode(path)
    local function drop_from(list)
        for i = 1, #list do
            if list[i].path == path then
                table.remove(list, i)
                return true
            end
        end
        return false
    end
    if drop_from(self.nodes or {}) then return true end
    local function walk(list)
        for _, n in ipairs(list) do
            if n.children then
                if drop_from(n.children) then return true end
                if walk(n.children) then return true end
            end
        end
        return false
    end
    return walk(self.nodes or {})
end

function DeleteDialog:repaint()
    if self.home and type(self.home.refresh) == "function" then
        self.home:refresh()
        return
    end
    self:init()
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
end

function DeleteDialog:rebuild()
    self:repaint()
end

function DeleteDialog:leave()
    if self.home and type(self.home.refresh) == "function" then
        self.home.delete_screen = nil
        self.home:refresh()
        return
    end
    local home = self.home
    UIManager:close(self)
    UIManager:nextTick(function()
        if home and home.refresh then home:refresh() end
    end)
end

function DeleteDialog:onBack()
    self:leave()
    return true
end

function DeleteDialog:toggleNode(node)
    if node.expanded then
        node.expanded = false
    else
        self:expandNode(node)
    end
    self:rebuild()
end

function DeleteDialog:expandNode(node)
    if node.expanded or node.is_file then return end
    if node.pending then
        node.children = node.children or {}
        node.expanded = true
        self:rebuild()
        return
    end
    if node.children == nil then
        local target = self.plugin:resolveTarget()
        if not target or not target.ip or target.ip == "" then
            self.list_err = true
            self:rebuild()
            return
        end
        local checking = Notification:new{ text = _("Looking up\226\128\166"), timeout = 0 }
        UIManager:show(checking)
        UIManager:forceRePaint()
        local ok, entries = self.plugin:listEntries(target, node.path)
        UIManager:close(checking)
        if not ok then
            self.list_err = true
            self:rebuild()
            return
        end
        node.children = {}
        for _, e in ipairs(entries) do
            local child = new_node(e.name, node.path .. "/" .. e.name, node.depth + 1)
            child.is_file = not e.is_dir
            node.children[#node.children + 1] = child
        end
    end
    node.expanded = true
    self:rebuild()
end

-- The reader's DELETE does NOT recurse (a non-empty folder answers 409 —
-- device-verified), so "Delete folder and its contents" purges depth-first:
-- every child is listed FRESH from the reader (never the stale cache),
-- files deleted, folders purged recursively, then the folder itself.
function DeleteDialog:purgeFolder(target, path)
    local ok, entries = self.plugin:listEntries(target, path)
    if not ok then
        return nil, string.format(_("could not list /%s"), tostring(path))
    end
    for _, e in ipairs(entries) do
        local child = path .. "/" .. e.name
        if e.is_dir then
            local pok, perr = self:purgeFolder(target, child)
            if not pok then return nil, perr end
        else
            local fok, ferr = self.plugin:deleteEntry(target, child)
            if not fok then return nil, ferr end
        end
    end
    return self.plugin:deleteEntry(target, path)
end

-- The confirmed delete: files go with one DELETE; folders try the fast
-- path first (an EMPTY folder dies in one call) and purge depth-first when
-- the reader answers 409 "not empty". Then the tree updates in place — a
-- flashless "ui" repaint of the shortened list, never a full-screen sweep —
-- and a popup reports the result. If the deleted folder WAS the
-- destination, it falls back to the CrossDropped Files default so a later
-- send cannot target a deleted folder.
function DeleteDialog:deleteNode(node)
    local target = self.plugin:resolveTarget()
    if not target or not target.ip or target.ip == "" then
        UIManager:show(Notification:new{ text = _("Set the WiFi IP on the Connections tab first."), timeout = 4 })
        return
    end
    -- "Deleting…" painted BEFORE the blocking DELETE (the dashboard's
    -- paint-progress-then-block rule — check() and expandNode both do this).
    -- Without it, fast follow-up deletes queue multi-second blind blocks and
    -- the plugin reads as frozen.
    local busy = Notification:new{ text = _("Deleting\226\128\166"), timeout = 0 }
    UIManager:show(busy)
    UIManager:forceRePaint()
    local ok, err, code
    if node.is_file then
        ok, err = self.plugin:deleteEntry(target, node.path)
    else
        ok, err, code = self.plugin:deleteEntry(target, node.path)
        if not ok and code == 409 then
            -- Folder still has things inside: purge them, then the folder.
            ok, err = self:purgeFolder(target, node.path)
        end
    end
    UIManager:close(busy)
    if not ok then
        UIManager:show(Notification:new{
            text = _("Could not delete /" .. tostring(node.path) .. ":\n") .. tostring(err or "unknown error"),
            timeout = 5,
        })
        return
    end
    -- A deleted destination (or a deleted parent of it) resets to default.
    local cur = tostring((target and target.folder) or ""):gsub("^/+", ""):gsub("/+$", "")
    local gone = node.path
    local reset_dest = cur == gone or cur:sub(1, #gone + 1) == gone .. "/"
    if reset_dest and self.plugin.setFolder then
        self.plugin:setFolder("CrossDropped Files")
    end
    self:removeNode(gone)
    self:rebuild()
    local text = _("Deleted /" .. tostring(gone))
    if node.is_file ~= true then
        text = text .. _(" and everything inside it")
    end
    if reset_dest then
        text = text .. _("\nDestination reset to CrossDropped Files.")
    end
    UIManager:show(Notification:new{ text = text, timeout = 4 })
end

function DeleteDialog:showDeletePopup(node)
    local popup = DeleteConfirmDialog:new{
        plugin = self.plugin,
        tree = self,
        node = node,
    }
    UIManager:show(popup, "ui", popup.region)
    UIManager:forceRePaint()
end

-- The visible tree flattened into display-order rows: folder/file rows,
-- plus the "Nothing else" note rows of empty expanded folders.
function DeleteDialog:visibleRows()
    local rows = {}
    local function walk(nodes, depth)
        for i = 1, #nodes do
            local n = nodes[i]
            rows[#rows + 1] = { node = n, depth = depth }
            if n.expanded then
                local kids = n.children or {}
                if #kids > 0 then
                    walk(kids, depth + 1)
                else
                    rows[#rows + 1] = { note = n, depth = depth }
                end
            end
        end
    end
    walk(self.nodes or {}, 0)
    return rows
end

-- Paged rendering in the picker's exact presentation (hairline separators
-- between rows, boxed Previous/Next, a plain caption — so the delete
-- browser reads as the SAME app as Send A File). The page CLAMPS to the
-- last page whenever the list shortens (a deletion) — the whole tree
-- repaints with nothing missing and nothing stale.
function DeleteDialog:appendPaged(vg)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local rows = self:visibleRows()
    local rpp = self.rows_per_page
    local max_page = math.max(1, math.ceil(#rows / rpp))
    if (self.page or 1) > max_page then self.page = max_page end
    self.page = math.max(1, self.page or 1)
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#rows, self.page * rpp)
    for i = lo, hi do
        local r = rows[i]
        local indent = math.min(r.depth * sc(TREE_INDENT), sc(140))
        if r.note then
            table.insert(vg, HorizontalGroup:new{
                HorizontalSpan:new{ width = indent + sc(TREE_ARROW_W) + sc(6) },
                TextBoxWidget:new{
                    text = string.format(_("Nothing else in /%s"), r.note.path),
                    face = Font:getFace("smallinfofont"),
                    width = math.max(self.row_w - indent - sc(TREE_ARROW_W) - sc(6), 1),
                },
            })
        else
            self:treeRowInto(vg, r.node, indent)
        end
        if i < hi then
            table.insert(vg, self:separator())
        end
    end
    -- The page-nav strip: the picker's shape — separator, caption, boxed
    -- rows. It is strapped to the VERY BOTTOM of the card: a flexible
    -- spacer under the last tree row soaks up whatever the measured rows
    -- left over, so an always-on-screen pager sits on the bottom edge
    -- (never a dead band above it, and never pushed below the fold).
    if #rows > rpp then
        local strip = VerticalGroup:new{ align = "left" }
        table.insert(strip, self:separator())
        table.insert(strip, self:caption(string.format(_("Page %d of %d"), self.page, max_page)))
        table.insert(strip, VerticalSpan:new{ width = sc(2) })
        if self.page > 1 then
            table.insert(strip, self:menuRow(_("Previous page"),
                function() self:gotoPage(self.page - 1) end))
        end
        if hi < #rows then
            table.insert(strip, self:menuRow(_("Next page"),
                function() self:gotoPage(self.page + 1) end))
        end
        if self.content_h then
            local busy = (vg.getSize and vg:getSize().h) or 0
            local strip_h = (strip.getSize and strip:getSize().h) or 0
            local filler = math.floor(math.max(0, self.content_h - busy - strip_h))
            if filler > 0 then
                table.insert(vg, VerticalSpan:new{ width = filler })
            end
        end
        for i = 1, #strip do
            table.insert(vg, strip[i])
        end
    end
end

-- The picker's exact presentation pieces (crossdrop_picker.lua's recipes),
-- so both browsers share one visual language.
function DeleteDialog:separator()
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

function DeleteDialog:caption(text)
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

function DeleteDialog:menuRow(text, callback)
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = self.row_w,
        callback = callback,
    }
end

function DeleteDialog:gotoPage(n)
    self.page = math.max(1, n)
    self:repaint()
end

-- One tree row: folders carry the ▸/▾ control, files just a spacer in its
-- place (nothing to expand). The NAME always opens the delete confirmation.
function DeleteDialog:treeRowInto(vg, node, indent)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local lead
    if node.is_file then
        lead = HorizontalSpan:new{ width = sc(TREE_ARROW_W) }
    else
        lead = Button:new{
            text = node.expanded and "\226\150\190" or "\226\150\184", -- ▾ / ▸
            width = sc(TREE_ARROW_W),
            align = "center",
            bordersize = 0,
            radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
            padding_h = 0,
            avoid_text_truncation = false,
            text_font_face = "smallinfofont",
            text_font_size = 28,
            callback = function() self:toggleNode(node) end,
        }
    end
    local name = Button:new{
        text = node.name,
        width = math.max(self.row_w - indent - sc(TREE_ARROW_W), 1),
        align = "left",
        bordersize = 0,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        padding_h = Size.padding.large,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        callback = function() self:showDeletePopup(node) end,
    }
    table.insert(vg, HorizontalGroup:new{
        HorizontalSpan:new{ width = indent },
        lead,
        name,
    })
end

-- INLINE render (everything below the brand + tabs): paint the delete tree
-- into an existing VerticalGroup bounded by the tab content region. The old
-- TitleBar's subtitle becomes a plain leading caption ("N item(s) at the
-- root — tap a name to delete"); rows/pager bottom-tack against the AREA
-- height exactly like the old full-screen card. Shared by the tab content
-- builder AND the standalone init() below.
function DeleteDialog:renderInto(vg, area_w, area_h)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    if area_w then self.row_w = area_w end
    if area_h then self.content_h = area_h end

    -- Rows per page MEASURED from one real row PLUS its hairline separator
    -- (the panel's fonts and paddings decide, not a guessed row height — a
    -- guessed count once put the page-nav rows themselves below the fold,
    -- so long folders looked unscrollable). The budget below the tree is
    -- the page-nav strip probed in its TALLEST form (both Previous and Next
    -- visible) plus the leading caption; a shorter strip leaves room the
    -- bottom-tack filler absorbs. Setting self.rows_per_page before init
    -- skips the probe (how the tests pin it).
    if not self.rows_per_page then
        local probe = VerticalGroup:new{}
        self:treeRowInto(probe, new_node("sample", "sample", 0), 0)
        table.insert(probe, self:separator())
        local rh = (probe:getSize() and probe:getSize().h) or sc(60)
        local cap_probe = self:caption("probe")
        local cap_h = (cap_probe.getSize and cap_probe:getSize().h) or sc(30)
        local strip = VerticalGroup:new{ align = "left" }
        table.insert(strip, self:separator())
        table.insert(strip, self:caption(string.format(_("Page %d of %d"), 1, 1)))
        table.insert(strip, VerticalSpan:new{ width = sc(2) })
        table.insert(strip, self:menuRow(_("Previous page"), function() end))
        table.insert(strip, self:menuRow(_("Next page"), function() end))
        local strip_h = (strip:getSize() and strip:getSize().h) or sc(150)
        self.rows_per_page = math.max(1,
            math.floor((self.content_h - cap_h - strip_h) / math.max(rh, 1)))
    end

    if self.list_err then
        table.insert(vg, TextBoxWidget:new{
            text = _("Device not found. Please check Xteink IP, and confirm that it matches in Connections."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
        return
    end
    -- The TitleBar's subtitle lives on as a plain leading caption.
    table.insert(vg, self:caption(string.format(
        _("%d item(s) at the root \226\128\148 tap a name to delete"), #(self.nodes or {}))))
    local nodes = self.nodes or {}
    if #nodes > 0 then
        -- Long lists slice into pages (the picker's recipe); the page
        -- clamps when a deletion shortens the tree.
        self:appendPaged(vg)
    else
        table.insert(vg, TextBoxWidget:new{
            text = _("Nothing on the reader."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end
end

function DeleteDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    -- The picker's TitleBar shape: title + a subtitle line that says what
    -- the page holds and how to act on it.
    local subtitle
    if not self.list_err then
        subtitle = string.format(_("%d item(s) at the root \226\128\148 tap a name to delete"),
            #(self.nodes or {}))
    end
    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Delete Folders/Files"),
        subtitle = subtitle,
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "chevron.left",
        left_icon_tap_callback = function() self:leave() end,
        show_parent = self,
    }

    -- The whole page fills the screen edge to edge: the tree rows plus the
    -- page-nav strip at the bottom must exactly match the card's inner
    -- height, so rows are counted from the measured chrome, not guessed.
    local tb_size = title_bar.getSize and title_bar:getSize()
    self.title_h = (tb_size and tb_size.h) or sc(80)

    local vg = VerticalGroup:new{ align = "left" }
    self:renderInto(vg, inner_w, (sh - pad * 2) - self.title_h - sc(16))

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
            vg,
        },
    }
    self.frame = frame
    self[1] = frame
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- The delete confirmation: a tiny centered popup (the folder menu's exact
-- recipe). Delete / Cancel; deleting a folder says so, and that everything
-- inside goes with it.
DeleteConfirmDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tree = nil,     -- the DeleteDialog to apply the delete to
    node = nil,     -- the file/folder being deleted
}

function DeleteConfirmDialog:onConfirm()
    local tree, node = self.tree, self.node
    UIManager:close(self, "ui", self.region)
    -- nextTick, like every close→work chain on this build: the network
    -- delete and the tree refresh run after the popup's repaint settles.
    UIManager:nextTick(function()
        if tree and node then tree:deleteNode(node) end
    end)
end

function DeleteConfirmDialog:onCancel()
    UIManager:close(self, "ui", self.region)
end

function DeleteConfirmDialog:onBack()
    UIManager:close(self, "ui", self.region)
    return true
end

function DeleteConfirmDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local pad = Size.padding.default
    local box_w = math.min(math.floor(sw * 0.6), sw - sc(40))
    local inner_w = box_w - pad * 2

    -- The question says WHAT dies: a file alone, or a folder and everything
    -- inside it — never a bare path the user has to parse.
    local title
    if self.node and self.node.is_file then
        title = string.format(_("Delete file?\n/%s"), tostring(self.node.path))
    else
        title = string.format(_("Delete folder and its contents?\n/%s"),
            tostring(self.node and self.node.path or ""))
    end
    local vg = VerticalGroup:new{}
    table.insert(vg, VerticalSpan:new{ width = sc(4) })
    table.insert(vg, TextBoxWidget:new{
        text = title,
        face = Font:getFace("smallinfofontbold"),
        width = inner_w,
        alignment = "center",
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:menuRow(inner_w, _("Delete"), function() self:onConfirm() end))
    table.insert(vg, self:menuRow(inner_w, _("Cancel"), function() self:onCancel() end))
    table.insert(vg, VerticalSpan:new{ width = sc(4) })

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = pad,
        vg,
    }
    self.frame = frame
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        frame,
    }
    self.dimen = Geom:new{ w = sw, h = sh }
    local fs = frame:getSize()
    local bw = fs and fs.w or box_w
    local bh = fs and fs.h or sh
    self.region = Geom:new{
        x = math.floor((sw - bw) / 2),
        y = math.floor((sh - bh) / 2),
        w = bw,
        h = bh,
    }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function DeleteConfirmDialog:menuRow(row_w, text, callback)
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = row_w,
        callback = callback,
    }
end

-- ─────────────── in-dashboard send: the progress sink ─────────────────────
-- plugin:sendBooks(paths, self) drives these callbacks synchronously while the
-- connection probes and the chunked PUT run on the UI thread. Each one rebuilds
-- the Send tab in place, so the whole flow is visible inside CrossDrop — the
-- dashboard never closes, and afterwards Send More / Try Again keep
-- controlling the same window. State changes paint via repaintNow (a flashing
-- full refresh) so the panel really shows them; see the header comment.

function HomeDialog:beginSendBatch(paths)
    self.send_state = "connecting"
    self.send_paths = type(paths) == "table" and paths or {}
    self.send_total = #self.send_paths
    self.send_index = 0
    self.send_file_list = {}
    self.send_target = nil
    self.fail_reason = nil
    self.plugin:sendBooks(self.send_paths, self)
end

-- Rebuild this dashboard's frame and repaint it with a flushing FULL refresh
-- (forceRePaint alone enqueues only a partial over the white card, which an
-- e-ink panel can fail to show when the whole screen is repainting).
function HomeDialog:repaintNow()
    self:init()
    UIManager:setDirty(self, "full")
    UIManager:forceRePaint()
end

-- FLASH-FREE variant: rebuilds and repaints in place WITHOUT the
-- full-refresh flash. Used where the change is almost always followed a frame
-- later by a real full transition: the "Connecting…" hint (reachable targets
-- reply in milliseconds) and MID-batch file starts (the screen is already
-- showing Sending). If the panel swallows the partial, the next full always
-- lands, so a soft repaint can never leave a stale screen.
function HomeDialog:repaintSoft()
    self:init()
    UIManager:setDirty(self, "partial")
    UIManager:forceRePaint()
end

function HomeDialog:onConnecting()
    self.send_state = "connecting"
    self:repaintSoft()
end

function HomeDialog:onConnected(target)
    self.send_target = target
end

function HomeDialog:onUnreachable()
    self.send_state = "failed"
    self.fail_reason = self.plugin:noReaderText()
    self:repaintNow()
end

function HomeDialog:onBeginFile(path, target, idx, total)
    self.send_state = "sending"
    self.send_target = target
    self.send_path = path
    self.send_filename = path:match("([^/]+)$") or path
    self.send_index = idx
    self.send_total = total
    self.send_widgets = nil
    -- First file start flashes (the real transition into Sending); MID-batch
    -- file starts only soft-repaint (the screen already shows Sending and a
    -- flash per file would make multi-book batches strobe).
    if idx and idx > 1 then
        self:repaintSoft()
    else
        self:repaintNow()
    end
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("crossdrop: home shows Sending ", idx, "/", total, " ",
        self.send_filename, " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:onProgress(path, pct, sent, total, elapsed)
    local w = self.send_widgets
    if not w then return end
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    w.pct:setText(string.format("%d%%", pct))
    w.fill.dimen.w = math.max(1, math.floor(w.bar_w * pct / 100))

    local meta = {}
    if total and total > 0 then
        meta[#meta + 1] = string.format("%.1f / %.1f MB", sent / 1048576, total / 1048576)
    else
        meta[#meta + 1] = string.format("%.1f MB", sent / 1048576)
    end
    if elapsed and elapsed > 0 then
        local rate = sent / elapsed
        meta[#meta + 1] = string.format("%.2f MB/s", rate / 1048576)
        if total and total > 0 and pct > 0 then
            local remaining = total - sent
            local eta = remaining / math.max(rate, 1)
            meta[#meta + 1] = string.format("ETA %d:%02d", math.floor(eta / 60), math.floor(eta % 60))
        end
    end
    w.meta:setText(table.concat(meta, "  \194\183  "))
    UIManager:forceRePaint()
end

function HomeDialog:onFileSent(path, target)
    self.send_file_list[#self.send_file_list + 1] = path:match("([^/]+)$") or path
end

function HomeDialog:onFileFailed(path, reason)
    self.fail_reason = (path:match("([^/]+)$") or path) .. "\n" .. tostring(reason)
end

function HomeDialog:onDone(all_ok)
    self.send_state = all_ok and "done" or "failed"
    if not all_ok and not self.fail_reason then
        self.fail_reason = _("The transfer did not complete.")
    end
    self:repaintNow()
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("crossdrop: home shows ", self.send_state,
        " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:sendMore()
    self.send_state = "idle"
    self.send_paths = nil
    self.send_file_list = {}
    self:init()
    UIManager:forceRePaint()
    self.plugin:chooseAndSend()
end

function HomeDialog:tryAgain()
    self:beginSendBatch(self.send_paths or {})
end

function HomeDialog:backToIdle()
    self.send_state = "idle"
    self.send_paths = nil
    self.send_target = nil
    self.send_file_list = {}
    self.fail_reason = nil
    self.send_widgets = nil
    self:init()
    UIManager:setDirty(self, "full")
end

-- Connecting: painted BEFORE the blocking 3s probes start (the Storefront
-- "paint progress first, then block" rule), so no reachable state ever reads
-- as a frozen screen.
function HomeDialog:renderSendConnecting()
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Sending")))
    local target = self.send_target
    table.insert(vg, TextBoxWidget:new{
        text = target
            and string.format("Connected     %s\n%s  \226\134\146  %s",
                _("WiFi"),
                ip_str(target), folder_str(target))
            or _("Connecting to CrossDrop \226\128\166"),
        face = Font:getFace("cfont", 18),
        width = self.row_w,
    })
    if not target then
        table.insert(vg, TextBoxWidget:new{
            text = _("Looking for the reader on your network. It answers within seconds."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end
    return vg
end

-- Sending: NO progress bar. socket.http hands the whole file to the TCP
-- buffers in milliseconds, so a bar would sit at 0% then jump straight to
-- done — worse than useless. This paints once at transfer start and the
-- device reply flips the tab to Done; onProgress stays inert.
function HomeDialog:renderSendWaiting()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    local inner_w = self.row_w

    table.insert(vg, self:header(string.format(_("Sending %d of %d"),
        self.send_index, self.send_total)))

    table.insert(vg, TextWidget:new{
        text = tostring(self.send_filename or "?"),
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = inner_w,
    })
    local target = self.send_target
    if target then
        table.insert(vg, TextWidget:new{
            text = string.format("%s  %s  \226\134\146  %s",
                _("WiFi"),
                ip_str(target), folder_str(target)),
            face = Font:getFace("smallinfofont"),
            max_width = inner_w,
        })
    end

    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, TextBoxWidget:new{
        text = _("… please wait\n\nThe reader is writing to its card."),
        face = Font:getFace("smallinfofont"),
        width = inner_w,
    })

    return vg
end

function HomeDialog:renderSendDone()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local names = self.send_file_list or {}
    local lines = {}
    for _, n in ipairs(names) do
        lines[#lines + 1] = "\226\156\147  " .. n
    end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Done")))
    table.insert(vg, TextBoxWidget:new{
        text = string.format(_("Sent %d file(s) to the reader."), #names)
            .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or ""),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Send more files\226\128\166"), {
        callback = function() self:sendMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

function HomeDialog:renderSendFailed()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Send failed")))
    table.insert(vg, TextBoxWidget:new{
        text = tostring(self.fail_reason or _("The transfer did not complete.")),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Try again"), {
        callback = function() self:tryAgain() end,
    }))
    table.insert(vg, self:row(_("Send more files\226\128\166"), {
        callback = function() self:sendMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

return HomeDialog