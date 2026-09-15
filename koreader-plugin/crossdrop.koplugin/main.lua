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

One connection is supported, matching the reader's File Transfer mode:

    WiFi          File Transfer → Join Network   (address shown on screen)

Its stored IP is set on the Connections tab. Sending a book probes it and
streams the book to the reader over the shared Wi-Fi network. (The reader's
"Create Hotspot" mode was dropped: it never worked reliably.)

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
local picker_mod = require("crossdrop_picker")
local function toastModule() return toast_mod end
local function progressModule() return progress_mod end
local function homeModule() return home_mod end
local function pickerModule() return picker_mod end

local CROSSDROP = WidgetContainer:extend{
    name = "crossdrop",
    is_doc_only = false,
    -- Shown on the dashboard's Connections tab so the running build is
    -- always identifiable on the device (KOReader loads plugins once at
    -- startup — a replaced plugin file does nothing until restart).
    VERSION = "1.3.21",
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

-- ───────────────────────────── connection (WiFi) ────────────────────────────

local function wifiIp()
    return G_reader_settings:readSetting("crossdrop_wifi_ip")
end

-- Settings keys are version-independent and only ever change when the user
-- taps "Set WiFi IP": crossdrop_wifi_ip / crossdrop_port persist in KOReader's
-- global settings (settings.reader.lua, on the SD card) forever — nothing in
-- this plugin writes a default over a saved WiFi IP. WiFi empty == the user
-- has not set it yet (the dashboard prompts for it).
local function setIp(kind, ip)
    ip = tostring(ip or ""):match("^%s*(.-)%s*$") or ""
    if ip == "" then
        G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
    else
        G_reader_settings:saveSetting("crossdrop_wifi_ip", ip)
    end
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

-- The single connection in send order: WiFi (the reader's File Transfer →
-- Join Network address). It always targets the fixed CrossDropped Files
-- folder on the reader's card. The IP is empty until the user sets it.
function CROSSDROP:configuredTargets()
    local port = tonumber(G_reader_settings:readSetting("crossdrop_port") or 80) or 80
    return {
        { kind = "wifi", ip = wifiIp() or "", port = port, folder = DEFAULT_FOLDER },
    }
end

-- The connection. Used by dialogs that operate on "the" device (status
-- checks, sends).
function CROSSDROP:resolveTarget()
    return self:configuredTargets()[1]
end

-- Probe the connection with GET /api/status. Returns (true, info_table_or_nil)
-- or (nil, nil, error_text). The parsed JSON is optional — a device that
-- answers with a non-JSON body still counts as reachable.
function CROSSDROP:probeTarget(target)
    if not target or not target.ip or target.ip == "" then
        return nil, nil, _("WiFi IP not set (see the Connections tab)")
    end
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
-- Every probe result is recorded in self._probe_errors (kind -> error text or
-- nil when it answered) and logged — the no-reader message then shows WHY each
-- connection failed (timeout, refused…), and a "freeze" during a check can be
-- root-caused from crash.log afterwards.
function CROSSDROP:probeReachable()
    self._probe_errors = {}
    for _, target in ipairs(self:configuredTargets()) do
        local ok, _, err = self:probeTarget(target)
        self._probe_errors[target.kind] = ok and nil or tostring(err)
        logger.info("crossdrop: probe ", target.kind, " ", target.ip,
            ok and " -> ok" or (" -> failed: " .. tostring(err)))
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

-- The whole "nothing answered" message: the Tried list (with the probe's own
-- error) plus the concrete fixes.
function CROSSDROP:noReaderText()
    return _("No CrossDrop reader reached.\n\nTried:\n") .. self:connectionSummary() ..
        _("\n\nCheck:\n\226\128\162  The reader is on and shows File Transfer\226\128\148Receive Books.\n\226\128\162  This Kindle is on the SAME Wi-Fi as the reader.\n\226\128\162  The WiFi IP matches the address the reader shows on\n    its Receive Books screen (set it on the Connections tab).")
end

-- The "Tried:" section for the no-connection error message. When a probe just
-- ran, appends its result ("[timeout]", "[connection refused]") so the message
-- says what actually happened instead of just listing the address.
function CROSSDROP:connectionSummary()
    local errs = self._probe_errors or {}
    local lines = {}
    for _, t in ipairs(self:configuredTargets()) do
        local result = errs[t.kind] and ("[" .. errs[t.kind] .. "]") or "no reply"
        lines[#lines + 1] = "  WiFi  " .. t.ip ..
            "  \226\134\146  " .. (t.folder or DEFAULT_FOLDER) .. "   " .. result
    end
    return table.concat(lines, "\n")
end

-- Edit the WiFi IP. `on_saved` runs after the dialog closes so the open
-- dashboard can repaint.
function CROSSDROP:editIp(kind, on_saved)
    local ip_dialog
    ip_dialog = InputDialog:new{
        title = _("WiFi IP (File Transfer → Join Network)"),
        input = wifiIp() or "",
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
            text = self:noReaderText(),
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
            _("WiFi"),
            tostring(info.ip or target.ip),
            tostring(info.device or "CrossDrop reader"),
            tostring(info.version or "?"),
            tostring(info.mode or "?"))
        if type(info.rssi) == "number" and info.mode == "STA" then
            details = details .. string.format("\nWi-Fi RSSI %d dBm", info.rssi)
        end
    else
        details = string.format("%s: %s", _("WiFi"), tostring(target.ip))
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

-- Resolve the first reachable connection through a progress sink. Sink
-- callbacks: onConnecting() before the probe, onConnected(target), or
-- onUnreachable() when nothing answers. Probes are bounded (3s each, via
-- socketutil) and the caller paints each state on screen, so the UI never
-- closes and never looks frozen.
function CROSSDROP:connect(sink)
    sink = sink or {}
    if sink.onConnecting then sink:onConnecting() end
    local target = self:probeReachable()
    if not target then
        self._reach = {}
        for _, t in ipairs(self:configuredTargets()) do
            self._reach[t.kind] = "down"
        end
        if sink.onUnreachable then sink:onUnreachable() end
        return nil
    end
    self._reach = { [target.kind] = "ok" }
    if sink.onConnected then sink:onConnected(target) end
    return target
end

-- Send a batch of picked books. The whole flow — connect + each transfer —
-- happens INSIDE the open CrossDrop dashboard: `sink` is the Home dialog,
-- whose callbacks repaint its own tabs in place, so nothing is ever closed and
-- more books can be sent when the batch finishes. Without an in-dashboard sink
-- (programmatic use) it falls back to the standalone per-file dialog.
function CROSSDROP:sendBooks(paths, sink)
    sink = sink or {}
    local seen, ordered = {}, {}
    for _, p in ipairs(paths or {}) do
        p = tostring(p or "")
        if p ~= "" and not seen[p] then
            seen[p] = true
            ordered[#ordered + 1] = p
        end
    end
    if #ordered == 0 then return false end
    table.sort(ordered)

    -- No Home on screen (e.g. called programmatically): use the standalone
    -- progress dialog instead, one file at a time.
    if type(sink.onProgress) ~= "function" then
        for _, p in ipairs(ordered) do
            self:sendFile(p)
        end
        return true
    end

    local target = self:connect(sink)
    if not target then return false end

    local batch_start = os.clock()

    local all_ok = true
    for i, path in ipairs(ordered) do
        if sink.onBeginFile then sink:onBeginFile(path, target, i, #ordered) end
        local folder_ok, folder_err = self:ensureFolder(target)
        if not folder_ok then
            all_ok = false
            if sink.onFileFailed then
                sink:onFileFailed(path, _("could not create the destination folder: ") .. tostring(folder_err))
            end
            break
        end
        local ok, result = self:putFile(target, path, function(sent, total)
            if sink.onProgress then
                sink:onProgress(path, sent / total * 100, sent, total, os.clock() - batch_start)
            end
        end)
        if not ok then
            all_ok = false
            if sink.onFileFailed then
                sink:onFileFailed(path, tostring(result))
            end
            break
        end
        if sink.onFileSent then sink:onFileSent(path, target) end
        logger.info("crossdrop: sent ", path, " to ", target.kind, " ", target.ip)
    end
    if sink.onDone then sink:onDone(all_ok) end
    return all_ok
end

-- Send an explicit book file (standalone dialog flow: probe + progress +
-- toast). Used by sendCurrentBook and as the no-Home fallback of sendBooks.
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
            text = self:noReaderText(),
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

-- "Send A Book": open the CrossDrop book picker (crossdrop_picker.lua) —
-- a device-wide book scan (the bookshelf.koplugin walk pattern) rendered on
-- the dashboard's proven widgets (rows of Buttons on the full-screen card,
-- the dashboard's TitleBar with its ✕). The built-in file browser is not
-- involved at all: no FileChooser, no Menu, no custom title bars — every
-- attempt to ride those (1.3.9–1.3.14) rendered blank controls on this
-- device. The picker scans once per open (cached), keeps its own picked
-- set, and its first row is the always-visible "Send to Xteink" action.
function CROSSDROP:chooseAndSend()
    local picker = pickerModule():new{ plugin = self }
    -- "ui" refresh type, exactly like openHome(): guarantees the picker is
    -- enqueued for painting (a bare show() leaves the refresh to chance when
    -- a full-screen modal is already up — which read as "opened behind").
    UIManager:show(picker, "ui")
    UIManager:forceRePaint()
    -- Diagnostics: if the picker ever misbehaves on the device again,
    -- crash.log says what was on screen (books found, modal flag, and the
    -- picker's position in the UIManager window stack).
    local stack = UIManager._window_stack or {}
    local pos, total = 0, #stack
    for i, w in ipairs(stack) do
        if w and w.widget == picker then pos = i end
    end
    logger.info("crossdrop: picker shown (books=", picker.books and #picker.books or 0,
        " modal=", tostring(picker.modal), " stackpos=", pos, "/", total, ")")
end

-- Open the full-screen CrossDrop dashboard. Shown with a "ui" refresh (the
-- same call Storefront uses) so the whole screen paints cleanly on e-ink.
-- The open instance is stored on the plugin so send flows can target it and
-- keep every transfer inside the dashboard (see sendBooks/chooseAndSend).
function CROSSDROP:openHome()
    local home = homeModule():new{ plugin = self }
    self.home = home
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