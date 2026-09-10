-- CrossDrop Home: a full-screen, Storefront-style dashboard. TitleBar header,
-- an underlined tab bar (Devices / Send / History), rich status rows with
-- ◆/● indicators, tap-to-send and hold-for-actions. Loaded lazily from
-- main.lua, so all widget requires happen at open time, never at plugin load.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")

local function file_size(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        return lfs.attributes(path, "size") or 0
    end
    return 0
end

local function reltime(ts)
    local dt = os.time() - (tonumber(ts) or 0)
    if dt < 60 then return _("just now") end
    if dt < 3600 then return string.format(_("%d m ago"), math.floor(dt / 60)) end
    if dt < 86400 then return string.format(_("%d h ago"), math.floor(dt / 3600)) end
    return string.format(_("%d d ago"), math.floor(dt / 86400))
end

local function ip_str(t)
    local ip = t and t.ip or "?"
    if t and t.port and t.port ~= 80 then ip = ip .. ":" .. tostring(t.port) end
    return ip
end

local function folder_str(t)
    local folder = t and t.folder and t.folder ~= "" and t.folder or "/Books"
    return folder
end

local HomeDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tab = "devices",
}

function HomeDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    local pad = Size.padding.default
    local inner_w = sw - pad * 2

    local current = G_reader_settings:readSetting("crossdrop_ip")
    local subtitle
    if current then
        local folder = G_reader_settings:readSetting("crossdrop_folder") or "/Books"
        subtitle = _("Target: ") .. current .. "  →  " .. folder
    else
        subtitle = _("No device configured yet — add one below")
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

    local content_w = inner_w
    local content = self:buildTabContent(self.tab, content_w - sc(8))

    local frame = FrameContainer:new{
        dimen = self.dimen,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            self:buildTabBar(content_w),
            VerticalSpan:new{ width = sc(6) },
            content,
            VerticalSpan:new{ width = sc(8) },
            ButtonTable:new{
                buttons = {
                    {
                        {
                            text = _("Close"),
                            callback = function() UIManager:close(self) end,
                        },
                    },
                },
                zero_sep = true,
                show_parent = self,
            },
        },
    }

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        frame,
    }

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local tabs = {
        { key = "devices", label = _("Devices") },
        { key = "send", label = _("Send") },
        { key = "history", label = _("History") },
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
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return Button:new{
        text = text,
        menu_style = true,
        width = self.inner_w or sc(400),
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
            face = Font:getFace("small"),
        },
    }
end

function HomeDialog:buildTabContent(tab, width)
    self.inner_w = width
    if tab == "devices" then
        return self:renderDevices(width)
    elseif tab == "send" then
        return self:renderSend(width)
    end
    return self:renderHistory(width)
end

function HomeDialog:renderDevices(width)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    local list = G_reader_settings:readSetting("crossdrop_ips")
    if not list or #list == 0 then
        vg:addWidget(TextWidget:new{
            text = _("No saved devices yet.\n\nPick a device below to add your first one."),
            face = Font:getFace("small"),
        })
    else
        vg:addWidget(self:header(_("Saved devices")))
        local current = G_reader_settings:readSetting("crossdrop_ip")
        local shown = 0
        for i, t in ipairs(list) do
            if shown >= 6 then break end
            shown = shown + 1
            local active = (t.ip == current)
            local dot = active and "\226\128\167 " or "\226\151\170 "
            local line1 = dot .. ip_str(t) .. "  \226\134\146  " .. folder_str(t)
            local line2 = (active and _("Current target · ") or "")
                .. (t.ts and (_("last used ") .. reltime(t.ts)) or _("saved"))
            local target = t
            vg:addWidget(self:row(line1 .. "\n" .. line2, {
                callback = function()
                    self.plugin:sendTo(target)
                end,
                hold_callback = function()
                    self.plugin:deviceActions(target)
                end,
            }))
        end
        if #list > shown then
            vg:addWidget(TextWidget:new{
                text = string.format(_("… plus %d more"), #list - shown),
                face = Font:getFace("smallitalic"),
            })
        end
    end

    vg:addWidget(self:header(_("Add a device")))
    vg:addWidget(self:row(_("Enter device IP…"), {
        callback = function() self.plugin:editIp() end,
    }))
    vg:addWidget(self:row(_("CrossDrop hotspot (192.168.4.1)"), {
        callback = function() self.plugin:useHotspot() end,
    }))
    return vg
end

function HomeDialog:renderSend(width)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    local book = self.plugin:currentBookPath()
    local has_book = book and book ~= ""
    local target = self.plugin:resolveTarget()

    if has_book then
        local name = book:match("([^/]+)$") or book
        vg:addWidget(self:header(_("Now open")))
        vg:addWidget(self:row("\226\128\167 " .. name, {
            callback = function()
                self.plugin:sendCurrentBook()
            end,
        }))
        vg:addWidget(self:row(string.format(_("Size %.1f MB"), file_size(book) / 1048576), {
            callback = function()
                self.plugin:sendCurrentBook()
            end,
        }))
    else
        vg:addWidget(TextWidget:new{
            text = _("No book open.\n\nOpen a book, then come back here to send it."),
            face = Font:getFace("small"),
        })
    end

    vg:addWidget(self:header(_("Destination")))
    if target then
        local prefix = self:currentIsHotspot() and _("\226\128\167 Hotspot ") or ""
        vg:addWidget(self:row(prefix .. ip_str(target) .. "  \226\134\146  " .. folder_str(target), {
            callback = function() self.plugin:statusDialog() end,
        }))
    else
        vg:addWidget(self:row(_("No device configured yet"), {
            callback = function() self.plugin:editIp() end,
        }))
    end
    vg:addWidget(self:row(_("Destination folder…"), {
        callback = function() self.plugin:pickFolder() end,
    }))
    vg:addWidget(self:row(_("Check device…"), {
        callback = function() self.plugin:statusDialog() end,
    }))
    return vg
end

function HomeDialog:currentIsHotspot()
    return G_reader_settings:readSetting("crossdrop_ip") == "192.168.4.1"
end

function HomeDialog:renderHistory(width)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    local list = G_reader_settings:readSetting("crossdrop_sent")
    if not list or #list == 0 then
        vg:addWidget(TextWidget:new{
            text = _("Nothing sent yet.\n\nBooks you send show up here with the\nCrossDrop reader, folder, size, and time."),
            face = Font:getFace("small"),
        })
    else
        vg:addWidget(self:header(_("Books sent (most recent first)")))
        local shown = 0
        for i, e in ipairs(list) do
            if shown >= 8 then break end
            shown = shown + 1
            local meta = reltime(e.ts) .. "  ·  " .. ip_str(e) .. "  \226\134\146  " .. folder_str(e)
            if e.size and e.size > 0 then
                meta = meta .. string.format("  ·  %.1f MB", e.size / 1048576)
            end
            local entry = e
            vg:addWidget(self:row((e.file or "?") .. "\n" .. meta .. _("  (tap to send again)"), {
                callback = function()
                    self.plugin:sendTo({
                        ip = entry.ip,
                        port = entry.port or 80,
                        folder = entry.folder or "/Books",
                    })
                end,
            }))
        end
        if #list > shown then
            vg:addWidget(TextWidget:new{
                text = string.format(_("… plus %d more"), #list - shown),
                face = Font:getFace("smallitalic"),
            })
        end
        vg:addWidget(self:row(_("Clear history"), {
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget all sent-book history?"),
                    ok_text = _("Delete all"),
                    ok_callback = function()
                        self.plugin:clearSentList()
                    end,
                })
            end,
        }))
    end
    return vg
end

function HomeDialog:onBack()
    UIManager:close(self)
    return true
end

return HomeDialog