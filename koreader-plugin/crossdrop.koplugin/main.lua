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
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local DEFAULT_HOTSPOT_IP = "192.168.4.1"
local DEFAULT_FOLDER = "/CrossDropped Files"

-- UI extras (toast, live progress, full-screen Home) live in sibling modules
-- that are only required once a dialog is opened, never at plugin load.
local toast_mod, progress_mod, home_mod
local function toastModule()
    if not toast_mod then toast_mod = require("crossdrop_toast") end
    return toast_mod
end
local function progressModule()
    if not progress_mod then progress_mod = require("crossdrop_progress") end
    return progress_mod
end
local function homeModule()
    if not home_mod then home_mod = require("crossdrop_home") end
    return home_mod
end

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

-- ────────────────────── sent-books history ──────────────────────────────

local SENT_MAX = 20

local function getSentList()
    local list = G_reader_settings:readSetting("crossdrop_sent")
    return (type(list) == "table") and list or {}
end

local function saveSentList(list)
    G_reader_settings:saveSetting("crossdrop_sent", list)
end

local function addSentEntry(entry)
    local list = getSentList()
    table.insert(list, 1, entry)
    while #list > SENT_MAX do table.remove(list) end
    saveSentList(list)
end

-- Exported for the Home dashboard: current history + a clear action.
function CROSSDROP:sentList()
    return getSentList()
end

function CROSSDROP:clearSent()
    saveSentList({})
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
-- timeout in seconds (default 10; probes use a short 3s so failure is snappy).
function CROSSDROP:req(method, url, headers, source_fn, timeout)
    if not socket_available() then
        return nil, "LuaSocket unavailable", nil
    end
    local deadline = timeout or 10
    local ok, body, code = pcall(http.request, {
        url = url,
        method = method,
        headers = headers or {["User-Agent"] = "KOReader/crossdrop"},
        source = source_fn,
        create = function()
            local s = socket.tcp()
            if s then
                pcall(function()
                    s:settimeout(deadline)
                end)
            end
            return s
        end,
    })
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
function CROSSDROP:editIp(kind)
    local is_hotspot = kind == "hotspot"
    local current = is_hotspot and hotspotIp() or (wifiIp() or "")
    local ip_dialog
    ip_dialog = InputDialog:new{
        title = (is_hotspot and _("HotSpot IP (File Transfer → Create Hotspot)")
            or _("WiFi IP (File Transfer → Join Network)")),
        input = current,
        type = "text",
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
function CROSSDROP:statusDialog()
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
function CROSSDROP:sendCurrentBook()
    local book_path = self:currentBookPath()
    if not book_path then
        UIManager:show(InfoMessage:new{
            text = _("There is no book file to send. Open a book first."),
        })
        return
    end

    local target = self:probeReachable()
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("No CrossDrop reader reached.\n\nTried:\n") .. self:connectionSummary() ..
                _("\n\nOpen File Transfer on the reader (Join Network for WiFi,\nor Create Hotspot), and keep this device on the same network."),
        })
        return
    end

    local filename = book_path:match("([^/]+)$") or book_path
    local book_size = lfs.attributes(book_path, "size") or 0

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
        addSentEntry({
            ts = os.time(),
            kind = target.kind,
            ip = target.ip,
            port = target.port or 80,
            folder = target.folder or DEFAULT_FOLDER,
            file = filename,
            size = book_size,
        })
        toastModule().show(string.format(_("Book sent  %s (WiFi  %s  →  %s)"),
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

-- Store a target and immediately send the current book (Home rows, history
-- re-send taps).
function CROSSDROP:sendTo(target)
    if not target or not target.ip then return end
    self:saveTarget(target)
    self:sendCurrentBook()
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