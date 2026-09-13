--[[
CrossDrop — KOReader plugin.

Adds a "CrossDrop" entry to the reader menu that opens a full-screen
dashboard and can hand the currently open book to the reader over the local
network. It uses only the built-in web-server endpoints — no custom firmware:

    GET   /api/status          device info + connection test
    MKCOL /CrossDropped Files  create the fixed destination folder if needed
    PUT   /CrossDropped Files/<file>   stream the book, chunk by chunk

Every transfer lands in the fixed **CrossDropped Files** folder on the reader's
SD card — there is no folder picker, nothing to configure.

Two connections are supported, matching the reader's two File Transfer modes:

    WiFi          File Transfer → Join Network   (address shown on screen)
    HotSpot       File Transfer → Create Hotspot (always 192.168.4.1)

Each has its own stored IP. Sending a book probes both (in that order) and
streams to whichever answers — so a user can move between a router network and
the reader's own hotspot without re-entering anything.

On the reader side, the matching "CrossDrop" SD plugin (the `crossdrop-plugin`
folder on the SD card) is a setup-guide screen (Settings → System → Plugins).

Pure LuaSocket (part of KOReader) — no external dependencies, and the file is
streamed chunk-by-chunk from disk so devices with little RAM (like a Kindle)
can send books of any size. The transfer progress dialog repaints live while
the chunks stream (the same forceRePaint technique the Storefront plugin uses).
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local DEFAULT_HOTSPOT_IP = "192.168.4.1"
local DEFAULT_FOLDER = "/CrossDropped Files"

-- UI extras (toast, live progress, full-screen Home) are sibling modules in
-- this plugin folder. They must be required at plugin load (the Storefront
-- pattern), because PluginLoader puts this folder on package.path only for the
-- duration of loading main.lua and restores it afterwards: a lazy bare require
-- made later, from a button/nextTick callback, would search a package.path
-- that no longer contains this folder and crash with "module not found" even
-- though the file exists next to main.lua.
local toast_mod = require("crossdrop_toast")
local progress_mod = require("crossdrop_progress")
local home_mod = require("crossdrop_home")
local function toastModule() return toast_mod end
local function progressModule() return progress_mod end
local function homeModule() return home_mod end

local CROSSDROP = WidgetContainer:extend{
    name = "crossdrop",
    is_doc_only = false,
}

local socket, http
local luasocket_ok, luasocket_err = pcall(function()
    socket = require("socket")
    http = require("socket.http")
end)

local JSON
pcall(function()
    JSON = require("json")
end)

-- KOReader's socketutil (the Storefront plugin's network layer): it patches
-- socket.tcp and http.TIMEOUT so blocking ops are truly bounded. Required
-- lazily so a build without it (or the test harness) gets a safe fallback.
local socketutil_mod
local function socketutilModule()
    if not socketutil_mod then
        local ok, su = pcall(require, "socketutil")
        if ok and su then
            socketutil_mod = su
        else
            socketutil_mod = {
                FILE_BLOCK_TIMEOUT = 15,
                FILE_TOTAL_TIMEOUT = 60,
                set_timeout = function() end,
                reset_timeout = function() end,
            }
        end
    end
    return socketutil_mod
end

local function socket_available()
    if not luasocket_ok then
        logger.warn("crossdrop: LuaSocket unavailable in this build: ", luasocket_err)
    end
    return luasocket_ok
end

-- Percent-encode one URL path segment (UTF-8 safe: bytes > 0x7F are encoded).
local function url_encode_segment(segment)
    return (segment:gsub("([^A-Za-z0-9%-%._~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Encode a "/"-separated path into URL-safe segments (preserves the slashes).
local function encode_path(path)
    path = tostring(path or "")
    if path == "" then
        return "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    local out = {}
    for seg in path:gmatch("[^/]+") do
        out[#out + 1] = url_encode_segment(seg)
    end
    if #out == 0 then
        return "/"
    end
    return "/" .. table.concat(out, "/")
end

local function base_url(target)
    return string.format("http://%s:%d", target.ip, target.port or 80)
end

-- ────────────────────── connections (WiFi + HotSpot) ─────────────────────

local function hotspotIp()
    return G_reader_settings:readSetting("crossdrop_hotspot_ip") or DEFAULT_HOTSPOT_IP
end

local function wifiIp()
    return G_reader_settings:readSetting("crossdrop_wifi_ip")
end

local function setIp(kind, ip)
    ip = tostring(ip or ""):match("^%s*(.-)%s*$") or ""
    if kind == "hotspot" then
        G_reader_settings:saveSetting("crossdrop_hotspot_ip",
            (ip == "" and DEFAULT_HOTSPOT_IP or ip))
    else
        G_reader_settings:saveSetting("crossdrop_wifi_ip", (ip == "" and nil or ip))
    end
end

local function connectionLabel(kind)
    return kind == "hotspot" and _("HotSpot") or _("WiFi")
end

function CROSSDROP:init()
    -- 1.x migration: the single crossdrop_ip setting becomes the WiFi slot.
    if not wifiIp() and G_reader_settings:readSetting("crossdrop_ip") then
        G_reader_settings:saveSetting("crossdrop_wifi_ip", G_reader_settings:readSetting("crossdrop_ip"))
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("crossdrop: self.ui or self.ui.menu not initialized")
    end
end

-- Generic HTTP call. Returns (ok, code, body). On a network failure `code`
-- carries LuaSocket's error string and `ok` is nil. `timeout` is the socket
-- timeout in seconds (default: Storefront's file sizes; probes use short 3s
-- so failure is snappy).
--
-- FREEZE FIX: raw socket.http forces its OWN 60s connect timeout (http.lua
-- calls settimeout(http.TIMEOUT) AFTER any custom `create()`), so an
-- unreachable IP made "Check device" block the UI for a minute+ and the
-- Kindle looked hard-frozen. socketutil patches socket.tcp + http.TIMEOUT so
-- every socket op honors our value — the same mechanism Storefront uses.
function CROSSDROP:req(method, url, headers, source_fn, timeout)
    if not socket_available() then
        return nil, "LuaSocket unavailable", nil
    end
    local su = socketutilModule()
    if timeout and timeout > 0 then
        su:set_timeout(timeout, timeout)
    else
        su:set_timeout(su.FILE_BLOCK_TIMEOUT or 15, su.FILE_TOTAL_TIMEOUT or 60)
    end
    local ok, body, code = pcall(http.request, {
        url = url,
        method = method,
        headers = headers or {["User-Agent"] = "KOReader/crossdrop"},
        source = source_fn,
    })
    su:reset_timeout()
    if not ok then
        return nil, tostring(body or "request failed"), nil
    end
    -- On failure LuaSocket returns (nil, "<error message>") instead of a status
    -- code, so `code` can be a string here. Only compare it when it is a number,
    -- otherwise comparing a string to a number raises a Lua error.
    if type(code) == "number" then
        return code >= 200 and code < 300, code, body
    end
    return nil, tostring(code or body or "unknown error"), body
end

-- The two connections in send order: WiFi first, then the reader hotspot.
-- Both always target the fixed CrossDropped Files folder on the reader's card.
function CROSSDROP:configuredTargets()
    local port = tonumber(G_reader_settings:readSetting("crossdrop_port") or 80) or 80
    local list = {}
    local wifi = wifiIp()
    if wifi then
        list[#list + 1] = { kind = "wifi", ip = wifi, port = port, folder = DEFAULT_FOLDER }
    end
    list[#list + 1] = { kind = "hotspot", ip = hotspotIp(), port = port, folder = DEFAULT_FOLDER }
    return list
end

-- Primary target (WiFi when set, otherwise HotSpot). Used by dialogs that
-- operate on "the" device (status checks, checks).
function CROSSDROP:resolveTarget()
    return self:configuredTargets()[1]
end

-- Probe one connection with GET /api/status. Returns (true, info_table_or_nil)
-- or (nil, nil, error_text). The parsed JSON is optional — a device that
-- answers with a non-JSON body still counts as reachable.
function CROSSDROP:probeTarget(target)
    local ok, code, body = self:req("GET", base_url(target) .. "/api/status", nil, nil, 3)
    if ok then
        local info
        if JSON then
            local okj, parsed = pcall(JSON.decode, body)
            if okj and type(parsed) == "table" then
                info = parsed
            end
        end
        return true, info
    end
    return nil, nil, (type(code) == "number")
        and string.format("device replied %s", tostring(code))
        or tostring(code or "unknown error")
end

-- Probe every configured connection with GET /api/status; return the first
-- that answers. Sends and "Check device" use this so either connection works.
function CROSSDROP:probeReachable()
    for _, target in ipairs(self:configuredTargets()) do
        local ok, _ = self:probeTarget(target)
        if ok then
            return target
        end
    end
    return nil
end

function CROSSDROP:saveTarget(target)
    if not target or not target.ip then return end
    setIp(target.kind or "wifi", target.ip)
    if target.port then
        G_reader_settings:saveSetting("crossdrop_port", target.port)
    end
end

-- Make sure the destination folder exists (MKCOL; 405 = already exists).
function CROSSDROP:ensureFolder(target)
    local folder = tostring(target.folder or DEFAULT_FOLDER)
    if folder == "" or folder == "/" then
        return true
    end
    local ok, code, errbody = self:req("MKCOL", base_url(target) .. encode_path(folder))
    if ok then
        return true
    end
    if type(code) == "number" and code == 405 then
        return true
    end
    if type(code) == "number" then
        return nil, string.format("could not create folder (%s: %s)", tostring(code), tostring(errbody or ""))
    end
    return nil, tostring(code or errbody or "unknown error")
end

-- Current book file path (only file-based documents can be sent).
function CROSSDROP:currentBookPath()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file or doc.file == "" then
        return nil
    end
    return doc.file
end

-- The "Tried:" section for the no-connection error message.
function CROSSDROP:connectionSummary()
    local lines = {}
    for _, t in ipairs(self:configuredTargets()) do
        lines[#lines + 1] = "  " .. connectionLabel(t.kind) .. "  " .. t.ip ..
            "  →  " .. (t.folder or DEFAULT_FOLDER)
    end
    return table.concat(lines, "\n")
end

-- Edit the IP for one connection ("wifi" or "hotspot").
-- `on_saved` runs after the dialog closes so the open dashboard can repaint.
function CROSSDROP:editIp(kind, on_saved)
    local is_hotspot = kind == "hotspot"
    local current = is_hotspot and hotspotIp() or (wifiIp() or "")
    local ip_dialog
    ip_dialog = InputDialog:new{
        title = (is_hotspot and _("HotSpot IP (File Transfer → Create Hotspot)")
            or _("WiFi IP (File Transfer → Join Network)")),
        input = current,
        type = "text",
        -- modal=true is REQUIRED here: Home is a modal full-screen dialog, and
        -- UIManager stacks non-modal widgets BELOW an existing modal — a plain
        -- InputDialog would render behind the dashboard and be unusable.
        modal = true,
        buttons = {
            {
                {
                    text = _("Save"),
                    callback = function()
                        local value = ip_dialog:getInputText()
                        if value then
                            setIp(kind, value)
                        end
                        UIManager:close(ip_dialog)
                        if on_saved then
                            on_saved()
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(ip_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(ip_dialog)
end

-- GET /api/status on the first reachable connection and show the result.
-- The probe is a bounded blocking call on the UI thread, so paint a "Checking…"
-- notice BEFORE blocking (the e-ink screen updates on forceRePaint) — without
-- it an unreachable IP reads as a frozen screen for the timeout window.
function CROSSDROP:statusDialog()
    local checking = Notification:new{ text = _("Checking device…"), timeout = 0 }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local target = self:probeReachable()
    if not target then
        UIManager:show(Notification:new{
            text = _("Could not reach the CrossDrop reader.\n\nTried:\n") .. self:connectionSummary() ..
                _("\n\nSame Wi-Fi? Correct IP? File Transfer open?"),
            timeout = 6,
        })
        return
    end
    local ok, info = self:probeTarget(target)
    UIManager:close(checking)
    if not ok then
        UIManager:show(Notification:new{
            text = _("Could not reach the CrossDrop reader: ") .. tostring(info or "network error") ..
                _("\n\nSame Wi-Fi? Correct IP? File Transfer open?"),
            timeout = 5,
        })
        return
    end
    local details
    if type(info) == "table" then
        details = string.format("%s:\nIP %s  ·  %s\nversion %s  ·  mode %s",
            connectionLabel(target.kind),
            tostring(info.ip or target.ip),
            tostring(info.device or "CrossDrop reader"),
            tostring(info.version or "?"),
            tostring(info.mode or "?"))
        if type(info.rssi) == "number" and info.mode == "STA" then
            details = details .. string.format("\nWi-Fi RSSI %d dBm", info.rssi)
        end
    else
        details = string.format("%s: %s", connectionLabel(target.kind), tostring(target.ip))
    end
    UIManager:show(InfoMessage:new{
        text = _("CrossDrop device found:\n\n") .. details,
    })
end

-- Stream a file to the target with an HTTP PUT. `on_progress(sent, total)` is
-- called as bytes are written. Returns (true, code) or (nil, error_text).
function CROSSDROP:putFile(target, file_path, on_progress)
    local size = lfs.attributes(file_path, "size")
    if not size then
        return nil, "cannot stat file"
    end

    local filename = file_path:match("([^/]+)$") or file_path
    local url = base_url(target) .. encode_path(target.folder or DEFAULT_FOLDER) .. "/" .. url_encode_segment(filename)

    local fh = io.open(file_path, "rb")
    if not fh then
        return nil, "cannot open file"
    end

    local sent = 0
    local function read_chunk()
        local block = fh and fh:read(32768)
        if block then
            sent = sent + #block
            if on_progress then
                on_progress(sent, size)
            end
            return block
        end
        fh:close()
        fh = nil
        return nil
    end

    local ok, result, result2 = self:req("PUT", url,
        {
            ["Content-Length"] = tostring(size),
            ["Content-Type"] = "application/epub+zip",
            ["User-Agent"] = "KOReader/crossdrop",
        },
        read_chunk)
    if not ok then
        return nil, (type(result) == "number")
            and string.format("device replied %s (%s)", tostring(result), tostring(result2 or ""))
            or tostring(result or "unknown error")
    end
    return true, result
end

local progress_guard
-- Send an explicit book file. Used both by "Send A Book" (picked through
-- KOReader's own file browser) and sendCurrentBook. Requires no book to be
-- open, so there is no path that can crash from a missing document.
function CROSSDROP:sendFile(book_path)
    if not book_path or book_path == "" then return end

    -- Same bounded-but-blocking probe as statusDialog: show a notice before it
    -- so an unreachable target never reads as a frozen screen.
    local checking = Notification:new{ text = _("Connecting to CrossDrop…"), timeout = 0 }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local target = self:probeReachable()
    UIManager:close(checking)
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("No CrossDrop reader reached.\n\nTried:\n") .. self:connectionSummary() ..
                _("\n\nOpen File Transfer on the reader (Join Network for WiFi,\nor Create Hotspot), and keep this device on the same network."),
        })
        return
    end

    local filename = book_path:match("([^/]+)$") or book_path

    local progress = progressModule().new(filename, target)
    local start = os.clock()

    local folder_ok, folder_err = self:ensureFolder(target)
    if not folder_ok then
        UIManager:close(progress)
        toastModule().show(_("Send failed: ") .. tostring(folder_err) ..
            _("\nCheck the reader has File Transfer open on the\nsame Wi-Fi network, and that the IP is correct."), 5)
        return
    end

    local ok, result = self:putFile(target, book_path, function(sent, total)
        progress:update(sent / total * 100, sent, total, os.clock() - start)
    end)
    UIManager:close(progress)

    if ok then
        toastModule().show(string.format(_("Book sent  %s (WiFi  %s  \226\134\146  %s)"),
            tostring(filename),
            tostring(target.ip),
            tostring(target.folder or DEFAULT_FOLDER)), 3)
        logger.info("crossdrop: sent ", book_path, " to ", target.kind, " ", target.ip)
    else
        toastModule().show(_("Send failed: ") .. tostring(result) ..
            _("\nCheck the reader has File Transfer open on the\nsame Wi-Fi network, and that the IP is correct."), 5)
        logger.warn("crossdrop: send failed (", target.ip, "): ", result)
    end
end

-- Send the currently open book. Guarded so a nil document just shows a hint
-- instead of crashing (the Home "Send A Book" picker never hits this path).
function CROSSDROP:sendCurrentBook()
    local book_path = self:currentBookPath()
    if not book_path then
        UIManager:show(InfoMessage:new{
            text = _("There is no book file to send. Use Send A Book to pick one."),
        })
        return
    end
    self:sendFile(book_path)
end

-- "Send A Book": open the FileManager file browser (a modal FileChooser — the
-- same list widget FileManager hosts, shown full-screen so it paints ABOVE
-- the Home dialog) and send whatever ebook the user picks — no need to have
-- it open first. This is the primary send path.
function CROSSDROP:chooseAndSend()
    local DocumentRegistry = require("document/documentregistry")
    local FileChooser = require("ui/widget/filechooser")
    local TitleBar = require("ui/widget/titlebar")
    local start_path
    local ok_util, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ok_util and filemanagerutil and filemanagerutil.getHomeFolder then
        start_path = filemanagerutil.getHomeFolder()
    end

    -- FileChooser is the file browser's list widget; FileManager is the app
    -- that usually hosts it. Standalone, the only `ui` bits BookList/FileChooser
    -- poke at are folder shortcuts, book metadata (for metadata sorting) and a
    -- PathChanged event — a minimal shim avoids crashing when the reader has no
    -- FileManager instance to borrow from.
    local ui_shim = {
        folder_shortcuts = {
            getShortcutFullName = function() return nil end,
            hasFolderShortcut = function() return false end,
        },
        bookinfo = { getDocProps = function() return {} end },
        selected_files = {},
        handleEvent = function() return false end,
    }

    -- The browser needs a visible way back to the CrossDrop menu (it is a
    -- modal over Home, and a bare FileChooser has no close button). Mirroring
    -- FileManager, we hand it our own title bar with a close icon.
    local fc
    local custom_title_bar = TitleBar:new{
        title = _("Send A Book"),
        subtitle = "",
        fullscreen = "true",
        align = "center",
        button_padding = Device.screen:scaleBySize(5),
        left_icon = "close",
        left_icon_size_ratio = 1,
        left_icon_tap_callback = function()
            UIManager:close(fc)
        end,
        show_parent = nil, -- patched to fc right below
    }

    fc = FileChooser:new{
        ui = ui_shim,
        path = start_path,
        title = _("Send A Book"),
        file_filter = function(filename)
            return DocumentRegistry:hasProvider(filename)
        end,
        modal = true,
        -- use our title bar (with the close button) instead of Menu's default
        custom_title_bar = custom_title_bar,
    }
    custom_title_bar.show_parent = fc
    local plugin = self
    function fc:onFileSelect(item)
        local path = item and item.path
        UIManager:close(fc)
        if path then
            UIManager:nextTick(function()
                plugin:sendFile(path)
            end)
        end
        return true
    end
    UIManager:show(fc)
end

-- Open the full-screen CrossDrop dashboard. Shown with a "ui" refresh (the
-- same call Storefront uses) so the whole screen paints cleanly on e-ink.
function CROSSDROP:openHome()
    local home = homeModule():new{ plugin = self }
    UIManager:show(home, "ui")
    UIManager:forceRePaint()
end

-- Pin the CrossDrop item at the top of the Tools menu (position 2, right under
-- "Read Timer"), the same way the Storefront plugin does. Without this, the
-- item is grouped with the other plugins at the bottom of Tools, sorted by
-- sorting_hint ("tools") and alphabetical plugin name.
local function injectCrossdropIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function contains_id(tbl, id)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == id then
                return true
            elseif type(val) == "table" and contains_id(val, id) then
                return true
            end
        end
        return false
    end
    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not contains_id(order, "crossdrop") then
                table.insert(order.tools, 2, "crossdrop")
            end
        end
    end
end

-- The CrossDrop item opens the dashboard directly; all actions live there.
function CROSSDROP:addToMainMenu(menu_items)
    injectCrossdropIntoToolsMenu()
    menu_items.crossdrop = {
        text = _("CrossDrop"),
        sorting_hint = "tools",
        callback = function() self:openHome() end,
    }
end

return CROSSDROP