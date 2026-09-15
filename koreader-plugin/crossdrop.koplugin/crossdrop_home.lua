-- CrossDrop Home: the plugin's app-style dashboard (the "Storefront" look).
-- A TitleBar header, an underlined tab bar (Connections / Send), rich rows
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
-- and "Send more books…"/"Try again" keep going from the same window.
--
-- E-INK REPAINT RULE (the issue that hid the whole flow on the device):
-- when one of these callbacks flips the send STATE (connecting / sending a
-- file / done / failed) it does a flashing FULL refresh — bare forceRePaint()
-- partials over a whole-screen white card were being swallowed by the panel,
-- so the transfer ran to completion with the screen still showing the old
-- tab. Progress-while-streaming (onProgress) stays a partial repaint so it
-- never flashes every chunk; only the per-file/state boundaries flash.
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
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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

-- ─────────────────────────────── the widget ──────────────────────────────

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
    send_widgets = nil,   -- live {bar_w, fill, pct, meta} during "sending"
    fail_reason = nil,    -- text shown on "failed"
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

    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("CrossDrop"),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local content = self:buildTabContent(self.tab, inner_w)

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

function HomeDialog:onCloseWidget()
    if self.plugin then
        self.plugin.home = nil
    end
    return true
end

-- ─────────────────────────────── tab bar ─────────────────────────────────

function HomeDialog:showTab(key)
    if self.tab == key then return end
    -- NOTE: there is NO UIManager:replace in this KOReader build (it crashed
    -- the plugin on the Kindle). Re-init the SAME widget for its new tab and
    -- repaint it in place instead.
    self.tab = key
    self:init()
    UIManager:setDirty(self, "full")
end

function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local tabs = {
        { key = "connections", label = _("Connections") },
        { key = "send", label = _("Send A Book") },
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
                self:showTab(t.key)
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
    if self.send_state == "connecting" then
        return self:renderSendConnecting()
    end
    if self.send_state == "sending" then
        return self:renderSendProgress()
    end
    if self.send_state == "done" then
        return self:renderSendDone()
    end
    if self.send_state == "failed" then
        return self:renderSendFailed()
    end
    return self:renderSendIdle()
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
    -- The probe is a bounded blocking call on the UI thread (3s, see main:req);
    -- paint a notice first so the tap never looks like a freeze.
    local checking = Notification:new{
        text = _("Checking WiFi\226\128\166"),
        timeout = 0,
    }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local ok, info, err = self.plugin:probeTarget(target)
    UIManager:close(checking)
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
        local text = _("Could not reach WiFi: ")
            .. tostring(err or "network error")
        UIManager:show(Notification:new{ text = text, timeout = 5 })
    end
    UIManager:setDirty(self, "partial")
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
        UIManager:setDirty(self, "partial")
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

    table.insert(vg,TextBoxWidget:new{
        text = _("Books land in the CrossDropped Files folder on the reader's card.\nSend A Book picks any ebook \226\128\148 no need to open it first.")
            .. "\nCrossDrop " .. tostring((self.plugin and self.plugin.VERSION) or ""),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })

    return vg
end

-- ─────────────────────────── Send tab ───────────────────────────────────

-- Idle: pick books, or send the one that is open (and only shown when it is).
-- The destination lives on the Connections tab: nothing here repeats it.
function HomeDialog:renderSendIdle()
    local vg = VerticalGroup:new{ align = "left" }
    local reach = self.plugin._reach or {}
    local book = self.plugin:currentBookPath()

    table.insert(vg,self:header(_("Send a book")))
    table.insert(vg,self:row(_("Click Here To Select Book(s)"), {
        callback = function() self.plugin:chooseAndSend() end,
    }))

    -- "Currently open" only appears when there IS an open book (no empty
    -- placeholder header when nothing is open).
    if book and book ~= "" then
        local name = book:match("([^/]+)$") or book
        local size = file_size(book)
        table.insert(vg,self:header(_("Currently open")))
        table.insert(vg,self:row(
            string.format("\226\151\128  %s\n%s  \226\128\164  tap to send", name,
                (size > 0 and string.format(_("%.1f MB"), size / 1048576) or "ebook")), {
            callback = function() self:beginSendBatch({ book }) end,
        }))
    end

    if reach.wifi ~= "ok" then
        table.insert(vg,TextBoxWidget:new{
            text = _("Send uses the WiFi connection \226\128\148 set or check it on the Connections tab."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end

    return vg
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

function HomeDialog:onConnecting()
    self.send_state = "connecting"
    self:repaintNow()
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
    self:repaintNow()
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

-- Live transfer: the same LineWidget bar + forceRePaint recipe the standalone
-- progress dialog used, but rendered as one of THIS dashboard's tabs — nothing
-- sits on top of CrossDrop while a book streams.
function HomeDialog:renderSendProgress()
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
    local subt
    if target then
        subt = string.format("%s  %s  \226\134\146  %s",
            _("WiFi"),
            ip_str(target), folder_str(target))
    else
        subt = ""
    end
    table.insert(vg, VerticalSpan:new{ width = sc(2) })
    table.insert(vg, TextWidget:new{
        text = subt,
        face = Font:getFace("smallinfofont"),
        max_width = inner_w,
    })

    local bar_w = inner_w
    local bar_h = sc(16)
    local border_w = Size.border.window or 1
    local fill = LineWidget:new{
        dimen = Geom:new{ w = 0, h = bar_h },
        background = Blitbuffer.COLOR_BLACK,
    }
    local track = FrameContainer:new{
        dimen = Geom:new{ w = bar_w, h = bar_h },
        bordersize = border_w,
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
        LineWidget:new{
            dimen = Geom:new{ w = bar_w - border_w * 2, h = bar_h - border_w * 2 },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }
    -- Track FIRST, fill LAST (OverlapGroup paints children in order).
    local bar = OverlapGroup:new{
        dimen = Geom:new{ w = bar_w, h = bar_h },
        track,
        fill,
    }
    local pct = TextWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 20),
        bold = true,
    }
    local meta = TextWidget:new{
        text = "",
        face = Font:getFace("smallinfofont"),
        max_width = inner_w,
    }
    self.send_widgets = { bar_w = bar_w, fill = fill, pct = pct, meta = meta }

    table.insert(vg, VerticalSpan:new{ width = sc(14) })
    table.insert(vg, bar)
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, pct)
    table.insert(vg, VerticalSpan:new{ width = sc(2) })
    table.insert(vg, meta)

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
        text = string.format(_("Sent %d book(s) to the reader."), #names)
            .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or ""),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Send more books\226\128\166"), {
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
    table.insert(vg, self:row(_("Send more books\226\128\166"), {
        callback = function() self:sendMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

return HomeDialog