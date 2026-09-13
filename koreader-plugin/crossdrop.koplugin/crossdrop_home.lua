-- CrossDrop Home: the plugin's app-style dashboard (the "Storefront" look).
-- A TitleBar header, an underlined tab bar (Connections / Send), rich rows
-- with live status dots and short hints, tap-to-act. The white card covers
-- the whole screen so nothing shows behind it. Loaded lazily from main.lua,
-- so all widget requires happen when the dashboard opens, never at plugin
-- load. Reachability is checked on demand (it is a blocking probe) and
-- remembered on the plugin instance across tab switches.
--
-- Uses only the plugin API exported from main.lua:
--   configuredTargets() -> {kind, ip, port, folder}[]  (WiFi first)
--   resolveTarget()     -> primary target (WiFi when set, else HotSpot)
--   probeTarget(target) -> (ok, info?); "down" statuses are cheap (3s timeout)
--   sendCurrentBook()   -> probes WiFi then HotSpot, streams to whichever answers
--   chooseAndSend()     -> open KOReader's file browser to pick a book to send
--   editIp(kind)        -> input dialog for "wifi" or "hotspot"
--   statusDialog(), currentBookPath()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")

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

local function status_word(reach)
    if reach == "ok" then return _("Reachable \226\151\128") end    -- ●
    if reach == "down" then return _("Offline \226\151\138") end    -- ○
    return _("Not checked")
end

local function reach_summary(reach)
    local parts = {}
    if reach.wifi == "ok" then parts[#parts + 1] = _("WiFi \226\151\128") end
    if reach.wifi == "down" then parts[#parts + 1] = _("WiFi \226\151\138") end
    if reach.hotspot == "ok" then parts[#parts + 1] = _("HotSpot \226\151\128") end
    if reach.hotspot == "down" then parts[#parts + 1] = _("HotSpot \226\151\138") end
    if #parts == 0 then return nil end
    return table.concat(parts, "  " .. string.char(0xB7) .. "  ")
end

-- ─────────────────────────────── the widget ──────────────────────────────

local HomeDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tab = "connections",
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

    local reach = self.plugin._reach or {}
    local target = self.plugin:resolveTarget()
    local folder = (target and target.folder) or "/CrossDropped Files"
    local summary = reach_summary(reach)
    local subtitle
    if reach.wifi == "down" and reach.hotspot == "down" then
        subtitle = _("No reader reached \226\128\148 is File Transfer open?")
    elseif summary then
        subtitle = folder .. "  \226\134\146  " .. summary
    else
        subtitle = _("Destination \226\134\146 ") .. folder ..
            _("\nTap a connection to check it")
    end

    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("CrossDrop"),
        subtitle = subtitle,
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local content = self:buildTabContent(self.tab, inner_w)

    -- A full-screen white frame (not a centered content-sized card): the
    -- whole screen paints white on top of whatever UI sits behind it.
    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            self:buildTabBar(inner_w),
            VerticalSpan:new{ width = sc(6) },
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
    UIManager:close(self)
    return true
end

-- ─────────────────────────────── tab bar ─────────────────────────────────

function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local tabs = {
        { key = "connections", label = _("Connections") },
        { key = "send", label = _("Send") },
    }
    local tabs_widgets = {}
    for i, t in ipairs(tabs) do
        if i > 1 then
            tabs_widgets[#tabs_widgets + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        local active = self.tab == t.key
        local btn = Button:new{
            text = t.label,
            menu_style = true,
            bold = active,
            callback = function()
                if self.tab ~= t.key then
                    UIManager:replace(self, HomeDialog:new{
                        plugin = self.plugin,
                        tab = t.key,
                    })
                end
            end,
        }
        local underline
        if active then
            underline = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = math.max(sc(24), btn:getSize().w), h = sc(3) },
            }
        else
            underline = VerticalSpan:new{ width = sc(3) }
        end
        tabs_widgets[#tabs_widgets + 1] = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = 0,
            padding_left = sc(8),
            padding_right = sc(8),
            bordersize = 0,
            VerticalGroup:new{
                align = "center",
                btn,
                VerticalSpan:new{ width = sc(4) },
                underline,
            },
        }
    end
    return HorizontalGroup:new(tabs_widgets)
end

function HomeDialog:row(text, opts)
    return Button:new{
        text = text,
        menu_style = true,
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

function HomeDialog:buildTabContent(tab, width)
    self.row_w = width
    if tab == "connections" then
        return self:renderConnections()
    end
    return self:renderSend()
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

function HomeDialog:check(kind)
    local target = self:targetFor(kind)
    if not target then return end
    local ok, info, err = self.plugin:probeTarget(target)
    local reach = self.plugin._reach or {}
    reach[kind] = ok and "ok" or "down"
    self.plugin._reach = reach
    if ok then
        local who = info and info.device and tostring(info.device) or "CrossDrop reader"
        local ver = info and info.version and tostring(info.version) or ""
        local text = (kind == "wifi" and _("WiFi reachable: ") or _("HotSpot reachable: "))
            .. who .. (ver ~= "" and ("  v" .. ver) or "")
        UIManager:show(Notification:new{ text = text, timeout = 4 })
    else
        local text = (kind == "wifi" and _("Could not reach WiFi: ") or _("Could not reach HotSpot: "))
            .. tostring(err or "network error")
        UIManager:show(Notification:new{ text = text, timeout = 5 })
    end
    UIManager:replace(self, HomeDialog:new{ plugin = self.plugin, tab = self.tab })
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
        callback = function() self.plugin:editIp("wifi") end,
    }))

    table.insert(vg,self:header(_("HotSpot connection")))
    local hotspot = self:targetFor("hotspot")
    if hotspot then
        table.insert(vg,self:row(
            string.format("HotSpot   %s\n%s  \226\128\164  %s", ip_str(hotspot),
                _("File Transfer \226\134\146 Create Hotspot"), status_word(reach.hotspot)), {
            callback = function() self:check("hotspot") end,
        }))
    end
    table.insert(vg,self:row(_("Set HotSpot IP\226\128\166"), {
        callback = function() self.plugin:editIp("hotspot") end,
    }))

    table.insert(vg,TextBoxWidget:new{
        text = _("Books land in the CrossDropped Files folder on the reader's card.\nSend A Book picks any ebook \226\128\148 no need to open it first."),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })

    return vg
end

-- ─────────────────────────── Send tab ───────────────────────────────────

function HomeDialog:renderSend()
    local vg = VerticalGroup:new{ align = "left" }
    local reach = self.plugin._reach or {}
    local book = self.plugin:currentBookPath()

    table.insert(vg,self:header(_("Send a book")))
    table.insert(vg,self:row(_("Send A Book\226\128\166"), {
        callback = function() self.plugin:chooseAndSend() end,
    }))

    table.insert(vg,self:header(_("Currently open")))
    if book and book ~= "" then
        local name = book:match("([^/]+)$") or book
        local size = file_size(book)
        table.insert(vg,self:row(
            string.format("\226\151\128  %s\n%s  \226\128\164  tap to send", name,
                (size > 0 and string.format(_("%.1f MB"), size / 1048576) or "ebook")), {
            callback = function() self.plugin:sendCurrentBook() end,
        }))
    else
        table.insert(vg,TextBoxWidget:new{
            text = _("No book open just now \226\128\148 Send A Book picks any ebook."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end

    table.insert(vg,self:header(_("Destination")))
    local target = self.plugin:resolveTarget() or { ip = "?", port = 80, folder = "/CrossDropped Files", kind = "?" }
    local which
    if target.kind == "wifi" then
        which = _("via WiFi")
    else
        which = _("via HotSpot (WiFi not set)")
    end
    table.insert(vg,self:row(
        string.format("%s  \226\134\146  %s\n%s  \226\128\164  tap to check the reader", ip_str(target), folder_str(target), which), {
        callback = function() self.plugin:statusDialog() end,
    }))
    table.insert(vg,self:row(_("Check device\226\128\166"), {
        callback = function() self.plugin:statusDialog() end,
    }))

    if reach.wifi ~= "ok" and reach.hotspot ~= "ok" then
        table.insert(vg,TextBoxWidget:new{
            text = _("Send probes WiFi first, then the HotSpot, and uses whichever answers.\nNo connection checked yet or none reachable."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end

    return vg
end

return HomeDialog