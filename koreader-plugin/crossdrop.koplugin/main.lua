--[[
CrossDrop — KOReader plugin.

Adds a "CrossDrop" entry to the reader menu that opens a full-screen
dashboard and can hand the currently open book to the reader over the local
network. It uses only the built-in web-server endpoints — no custom firmware:

    GET   /api/files                  list folders at the card root (destination picker)
    GET   /api/files?path=<folder>    list the folders nested inside <folder>
    MKCOL /<folder>/<child>           create a destination folder, parents first
    PUT   /<folder>/<file>            stream the book, chunk by chunk

The destination folder is optional: the send tab can list the reader's
folders (/api/files), drill into them at any depth, type a "/"-separated
path, or create a brand-new subfolder under a chosen folder. Whatever the
choice, every folder in the path is MKCOL-created before the first send.
Nothing chosen == the **CrossDropped Files** default, so a bare install
keeps the old behavior.

One connection is supported, matching the reader's File Transfer mode:

    WiFi          File Transfer → Join Network   (address shown on screen)

Its stored IP is set on the Connections tab. Sending a book probes it and
streams the book to the reader over the shared Wi-Fi network.

Pure LuaSocket (part of KOReader) — no external dependencies, and the file is
streamed chunk-by-chunk from disk so devices with little RAM (like a Kindle)
can send books of any size. A waiting dialog shows while the chunks stream
(progress bars never render on this e-ink build — the transfer drains faster
than the panel can repaint, so a bar just sat at 0% then jumped to done).

-- 1.5.0 — duplicate detection (books already on the reader):
--   * Each Send A File open scans the reader's ENTIRE card before the first
--     row paints and marks every already-there book ("On reader · size"),
--     so a duplicate is visible before anything is picked. The scan reruns on
--     every open (never cached between opens), so a book sent moments ago is
--     flagged the moment Send More reopens the picker.
--   * Picking a duplicate pauses on a "Send anyway / Don't send" confirm —
--     the flag is impossible to walk past, yet re-sending a just-fixed copy
--     stays one tap away.
--   * "Same book" = same byte size AND a name that keys alike (case and
--     separators collapse, so "The_Name_of_the_Wind.epub" and "The Name of
--     the Wind.EPUB" match); an edited/updated copy (size changed) is not
--     flagged, because that is exactly what users re-send on purpose.
--   * The one-tap "Currently open" send guards the duplicate too — no send
--     route out of the dashboard can silently re-upload.

-- 1.4.3 (test build) — Kobo connectivity hardening, Storefront-style:
--   * NetworkMgr:runWhenConnected() gates every send/check entry point. On
--     devices where KOReader manages the radio (Kobo) CrossDrop now brings
--     Wi-Fi up first instead of probing a dead link; the fast path is
--     synchronous on platforms where the radio is always up (Android and kin),
--     so behavior is unchanged where it already worked. runWhenConnected (NOT
--     runWhenOnline) is used because the reader is a LAN-only target that may
--     have no internet, and runWhenOnline would never fire its callback on
--     such a link.
--   * UIManager:preventStandby()/allowStandby() (pcall-guarded) held across
--     blocking probes, folder listings and the whole send batch, so a long
--     transfer cannot be killed by autosuspend tearing down the radio
--     mid-stream on KOReader-managed platforms.
--   * Probes retry (4s then 6s, every attempt logged so crash.log shows the
--     probe trail) — a radio/ESP32 power-save wake-up shouldn't read as a
--     false "offline".
--   * socketutil timeout codes are mapped to a clear "timed out" message.
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

-- Shown by the fast fail-fast guards on single-op network calls (folder
-- listings, deletes) when the radio is off but has a stored IP: instant,
-- actionable feedback instead of a silent bounded-timeout hang.
local WIFI_OFF_MSG =
    _("Wi-Fi is off on this device. Turn it on (Menu → Wi-Fi connection) — CrossDrop connects for you on send/check.")

-- UI extras (toast, waiting dialog, full-screen Home) are sibling modules in
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
    VERSION = "1.5.0",
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

-- KOReader's NetworkMgr — the same module Storefront gates its network calls
-- with. Required lazily + pcall'd so a build without it (or the test harness)
-- degrades to the old trust-the-radio behavior. When KOReader does NOT manage
-- the radio (Android, Cervantes…) `isWifiOn()`/`isConnected()` always answer
-- true, so gating is a synchronous no-op there and nothing changes for users
-- where it works.
local NetworkMgr_mod, NetworkMgr_tried
local function networkManager()
    if not NetworkMgr_tried then
        NetworkMgr_tried = true
        local ok, nm = pcall(require, "ui/network/manager")
        if ok and type(nm) == "table" then
            -- KOReader normally initializes NetworkMgr at startup; only if
            -- something exotic left it unwired do we init it (once — running
            -- it again would reschedule connectivity checks/broadcasts).
            if not nm.interface and type(nm.init) == "function" then
                pcall(nm.init, nm)
            end
            NetworkMgr_mod = nm
        else
            NetworkMgr_mod = false
        end
    end
    return NetworkMgr_mod
end

-- Keep the device from suspending while a blocking network op runs. On Kobo
-- (and other KOReader-managed radios) the Wi-Fi chip is torn down on suspend,
-- which would kill an in-flight transfer. pcall-guarded: not every build or
-- platform provides these guards, so this is a strict no-op where they're
-- missing. Returns a release() function.
local function standbyHold()
    if UIManager.preventStandby then
        pcall(function() UIManager:preventStandby() end)
        return function()
            pcall(function() UIManager:allowStandby() end)
        end
    end
    return function() end
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
-- timeout in seconds (default: Storefront's file sizes; probes pass short
-- retrying timeouts so failure is snappy).
--
-- FREEZE FIX: raw socket.http forces its OWN 60s connect timeout (http.lua
-- calls settimeout(http.TIMEOUT) AFTER any custom `create()`), so an
-- unreachable IP made "Check device" block the UI for a minute+ and the
-- Kindle looked hard-frozen. socketutil patches socket.tcp + http.TIMEOUT so
-- every socket op honors our value — the same mechanism Storefront uses.
--
-- socketutil surfaces forced timeouts as special non-numeric codes
-- ("timeout", "wantread", "sink timeout") rather than an HTTP status; those
-- are mapped to a clear "timed out" so the UI and crash.log say what actually
-- happened instead of a bogus string-vs-number comparison.
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
    -- otherwise comparing a string to a number raises a Lua error. The
    -- socketutil timeout codes are special-cased first for a readable message.
    if type(code) == "string" then
        if code == (su.TIMEOUT_CODE or "timeout")
            or code == (su.SINK_TIMEOUT_CODE or "sink timeout")
            or code == (su.SSL_HANDSHAKE_CODE or "wantread") then
            return nil, "timed out", code
        end
        return nil, tostring(code), body
    end
    if type(code) == "number" then
        return code >= 200 and code < 300, code, body
    end
    return nil, tostring(code or body or "unknown error"), body
end

-- The single connection in send order: WiFi (the reader's File Transfer →
-- Join Network address). Its destination folder comes from the Send A File
-- tab (crossdrop_folder) and falls back to the CrossDropped Files default.
-- The IP is empty until the user sets it.
function CROSSDROP:configuredTargets()
    local port = tonumber(G_reader_settings:readSetting("crossdrop_port") or 80) or 80
    local dest = G_reader_settings:readSetting("crossdrop_folder")
    local folder = (dest and dest ~= "") and dest or DEFAULT_FOLDER
    return {
        { kind = "wifi", ip = wifiIp() or "", port = port, folder = folder },
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
--
-- Tries a couple of escalating timeouts: the first attempt can race a radio
-- that just woke from power-save (fast re-association / ARP on Kobo NICs, and
-- modem-sleep wake-up on the ESP32 side) and misreport a reachable reader as
-- offline. Every attempt is logged so crash.log shows the full probe trail.
-- Callers run this under a standby hold and a Wi-Fi gate (see ensureWifi), so
-- the probe itself does not hold them.
function CROSSDROP:probeTarget(target)
    if not target or not target.ip or target.ip == "" then
        return nil, nil, _("WiFi IP not set (see the Connections tab)")
    end
    local attempts = { 3, 6 }
    local code, body
    for i, timeout in ipairs(attempts) do
        local ok_i, code_i, body_i = self:req("GET", base_url(target) .. "/api/status", nil, nil, timeout)
        code, body = code_i, body_i
        logger.info("crossdrop: probe ", target.kind, " ", target.ip,
            " attempt ", i, " (", timeout, "s) => ",
            ok_i and "ok" or tostring(code_i or body_i or "unknown"))
        if ok_i then
            local info
            if JSON then
                local okj, parsed = pcall(JSON.decode, body_i)
                if okj and type(parsed) == "table" then
                    info = parsed
                end
            end
            return true, info
        end
    end
    return nil, nil, (type(code) == "number")
        and string.format("device replied %s", tostring(code))
        or tostring(code or "unknown error")
end

-- Probe every configured connection with GET /api/status; return the first
-- that answers. Sends and "Check device" use this so either connection works.
-- Every probe result is recorded in self._probe_errors (kind -> error text or
-- nil when it answered) and logged — the no-reader message then shows WHY the
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

-- Save the destination folder path (crossdrop_folder, settings.reader.lua).
-- Stored as a single "/"-normalized path with a leading "/", like the
-- default. A nested destination is a plain "/"-separated path (Books/Sci-Fi)
-- at any depth the user browses to or types. An empty name clears the
-- preference (back to the CrossDropped Files default); "."/".." or empty
-- path segments are rejected, so a destination can never escape the card
-- root.
function CROSSDROP:setFolder(name)
    local segs = {}
    for seg in (tostring(name or "")
        :match("^%s*(.-)%s*$") or ""):gmatch("[^/]+") do
        seg = seg:match("^%s*(.-)%s*$") or seg
        if seg == "" or seg == "." or seg == ".." then
            G_reader_settings:saveSetting("crossdrop_folder", nil)
            return
        end
        segs[#segs + 1] = seg
    end
    if #segs == 0 then
        G_reader_settings:saveSetting("crossdrop_folder", nil)
        return
    end
    G_reader_settings:saveSetting("crossdrop_folder", "/" .. table.concat(segs, "/"))
end

-- Strip HTTP chunked-transfer framing (the reader streams /api/files in tiny
-- chunks: "1CRLF[CRLF…" with no Content-Length; the device's socket.http does
-- not decode it, so the raw framing reaches JSON.decode verbatim). Reassembles
-- the payload up to the 0-size chunk, ignoring trailers. Returns nil if the
-- body is not a well-formed chunked stream (e.g. a truncated read).
local function dechunk(body)
    if type(body) ~= "string" or body == "" then return nil end
    local out, pos, n = {}, 1, #body
    while pos <= n do
        local size_s = body:match("((%x+)[^%c]*\r\n)", pos)
        if not size_s then return nil end
        pos = pos + #size_s
        local bytes = tonumber(size_s:match("^(%x+)"), 16)
        if not bytes then return nil end
        if bytes == 0 then
            return table.concat(out)
        end
        if pos + bytes > n then return nil end
        out[#out + 1] = body:sub(pos, pos + bytes - 1)
        pos = pos + bytes
        if body:sub(pos, pos + 1) ~= "\r\n" then return nil end
        pos = pos + 2
    end
    return nil
end

-- Read an HTTP response body over a plain socket. socket.http on this build
-- returns only the FIRST LINE of a multi-line GET body (single-line /api/status
-- parses, but /api/files came back as just "1"), so the folder listing reads a
-- raw socket instead and splits headers / dechunks / decodes itself. The whole
-- read runs under socketutil's bounded timeouts (no 60s socket.http freeze)
-- and under a standby hold. Returns (true, code, body) or (nil, error_text,
-- body_or_nil). A dead radio (Wi-Fi off) is caught UP FRONT and reported
-- instantly instead of let to burn its timeout window.
function CROSSDROP:rawBody(target, path, timeout)
    if not socket_available() then
        return nil, "LuaSocket unavailable", nil
    end
    if not target or not target.ip or target.ip == "" then
        return nil, _("WiFi IP not set (see the Connections tab)"), nil
    end
    if not self:wifiUp() then
        return nil, WIFI_OFF_MSG, nil
    end
    local ok_w, r1, r2, r3 = self:withStandby(function()
        local su = socketutilModule()
        if timeout and timeout > 0 then
            su:set_timeout(timeout, timeout)
        else
            su:set_timeout(su.FILE_BLOCK_TIMEOUT or 15, su.FILE_TOTAL_TIMEOUT or 60)
        end
        local sock, herr = socket.tcp()
        if not sock then
            su:reset_timeout()
            return nil, tostring(herr or "socket error"), nil
        end
        sock:settimeout(timeout or 10)
        local oks, cerr = sock:connect(target.ip, tonumber(target.port) or 80)
        if not oks then
            sock:close()
            su:reset_timeout()
            return nil, tostring(cerr or "connect error"), nil
        end
        sock:send("GET " .. path .. " HTTP/1.0\r\n"
            .. "Host: " .. target.ip .. "\r\n"
            .. "User-Agent: KOReader/crossdrop\r\n"
            .. "Connection: close\r\n\r\n")
        local parts, size, recv_err = {}, 0, nil
        while true do
            local chunk, rerr = sock:receive("*a")
            if not chunk then
                recv_err = rerr
                break
            end
            parts[#parts + 1] = chunk
            size = size + #chunk
        end
        sock:close()
        su:reset_timeout()
        if size == 0 then
            return nil, "no response body" .. (recv_err and (" (" .. tostring(recv_err) .. ")") or ""), nil
        end
        local raw = table.concat(parts)
        local head_end = raw:find("\r\n\r\n", 1, true)
        local code_s = raw:match("^HTTP/%d%.%d (%d+)")
        local code = code_s and tonumber(code_s)
        local body = (head_end and raw:sub(head_end + 4)) or raw
        if not code or code < 200 or code >= 300 then
            return nil,
                (code and string.format("device replied %s", tostring(code)))
                or "malformed HTTP response",
                body
        end
return true, code, body
    end)
    if not ok_w then
        return nil, tostring(r1 or "operation aborted"), r3
    end
    return r1, r2, r3
end

-- List the folders inside a directory on the reader's card (GET /api/files;
-- JSON entries carry isDirectory). With no `path` this is the card root;
-- pass a folder path ("Books", "Books/Sci-Fi") to list what is nested inside
-- it. The path is URL-encoded (%20 for spaces) into ?path=<folder>, which the
-- reader answers with the same JSON shape as the root. Returns
-- (true, sorted_names[]) or (nil, error_text). Slower than a status probe —
-- the reader can take seconds to respond while it services the SD card — so
-- the budget is 10s block+total (still socketutil-bounded, never the
-- raw-http 60s freeze). The reader sends this listing chunked, so a body
-- that refuses to decode is dechunked and retried before giving up.
-- Diagnosis of a failure lands in crash.log.
function CROSSDROP:listFolders(target, path)
    if not target or not target.ip or target.ip == "" then
        return nil, _("WiFi IP not set (see the Connections tab)")
    end
    local api_path = "/api/files"
    local p = tostring(path or ""):gsub("^/+", ""):gsub("/+$", "")
    if p ~= "" then
        api_path = api_path .. "?path=" .. encode_path(p):gsub("^/", "")
    end
    local ok, code, body = self:rawBody(target, api_path, 10)
    if not ok then
        local err = (type(code) == "number")
            and string.format("device replied %s", tostring(code))
            or tostring(code or "unknown error")
        logger.info("crossdrop: listFolders failed (", target.ip, "): ", err)
        return nil, err
    end
    local folders = {}
    if JSON then
        local okj, parsed = pcall(JSON.decode, body)
        if not (okj and type(parsed) == "table") then
            okj, parsed = pcall(JSON.decode, dechunk(body))
        end
        if okj and type(parsed) == "table" then
            for _, e in ipairs(parsed) do
                if type(e) == "table" and e.isDirectory and e.name ~= "" then
                    folders[#folders + 1] = tostring(e.name)
                end
            end
        else
            local head = type(body) == "string" and string.format("%q", body:sub(1, 96)) or tostring(body)
            logger.info("crossdrop: listFolders could not parse the body from ", target.ip, " (head ", head, ")")
            return nil, "could not parse the folder list"
        end
    end
    table.sort(folders)
    logger.info("crossdrop: listFolders (", target.ip, ") -> ", #folders, " folders")
    return true, folders
end

-- List EVERYTHING in a folder — folders AND files — for the delete tab's
-- tree: { { name = "Fiction", is_dir = true, size = 0 }, ... }, folders
-- first, each group name-sorted.
function CROSSDROP:listEntries(target, path)
    if not target or not target.ip or target.ip == "" then
        return nil, _("WiFi IP not set (see the Connections tab)")
    end
    local api_path = "/api/files"
    local p = tostring(path or ""):gsub("^/+", ""):gsub("/+$", "")
    if p ~= "" then
        api_path = api_path .. "?path=" .. encode_path(p):gsub("^/", "")
    end
    local ok, code, body = self:rawBody(target, api_path, 10)
    if not ok then
        local err = (type(code) == "number")
            and string.format("device replied %s", tostring(code))
            or tostring(code or "unknown error")
        logger.info("crossdrop: listEntries failed (", target.ip, "): ", err)
        return nil, err
    end
    local entries = {}
    if JSON then
        local okj, parsed = pcall(JSON.decode, body)
        if not (okj and type(parsed) == "table") then
            okj, parsed = pcall(JSON.decode, dechunk(body))
        end
        if okj and type(parsed) == "table" then
            for _, e in ipairs(parsed) do
                if type(e) == "table" and e.name ~= "" then
                    entries[#entries + 1] = {
                        name = tostring(e.name),
                        is_dir = e.isDirectory == true,
                        size = tonumber(e.size) or 0,
                    }
                end
            end
        else
            logger.info("crossdrop: listEntries could not parse the body from ", target.ip)
            return nil, "could not parse the folder list"
        end
    end
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name < b.name
    end)
    logger.info("crossdrop: listEntries (", target.ip, ") -> ", #entries, " entries")
    return true, entries
end

-- Whole-card duplicate scan: recursively list EVERY folder on the reader's
-- card (the delete tab's purge pattern, but listing files too) and index what
-- is there by lowercase filename. Name alone is not enough for identity — two
-- unrelated books can share a name — so the size is kept too; the picker
-- treats a filename AND size match as "the same file is already on the card".
-- The folder each file lives in is kept so a duplicate notice can say where.
-- Bounded three ways so a pathological or dying reader can never wedge the
-- picker's scanning hold: depth-capped, folder-capped and wall-clock-capped
-- (a mid-scan hard failure discards the partial index — a partial answer
-- could MISS a duplicate, which is worse than none). Returns (true, index)
-- or (nil, err). index is name_lower -> { { folder, name, size }, ... }.
-- `on_progress(folders)` fires after each folder listing (the picker repaints
-- its "Scanning the reader…" notice on every one — the paint-before-block
-- rule).
local MAX_SCAN_DEPTH = 16
local MAX_SCAN_FOLDERS = 256
local MAX_SCAN_SECONDS = 90

function CROSSDROP:listAllFiles(target, on_progress)
    if not target or not target.ip or target.ip == "" then
        return nil, _("WiFi IP not set (see the Connections tab)")
    end
    local start = os.clock()
    local index = {}
    local listed = {}
    local pending = { { path = "", depth = 0 } }
    local folders, names = 0, 0
    while #pending > 0 and folders < MAX_SCAN_FOLDERS do
        if os.clock() - start > MAX_SCAN_SECONDS then
            logger.warn("crossdrop: whole-card scan hit the ", MAX_SCAN_SECONDS, "s budget; index is partial")
            break
        end
        local dir = table.remove(pending, 1)
        if not listed[dir.path] then
            listed[dir.path] = true
            local ok, entries = self:listEntries(target, dir.path)
            if not ok then
                logger.info("crossdrop: whole-card scan aborted at '", dir.path, "': ", tostring(entries))
                return nil, tostring(entries)
            end
            local prefix = (dir.path == "" and "") or (dir.path .. "/")
            for _, e in ipairs(entries) do
                if e.is_dir then
                    if dir.depth + 1 <= MAX_SCAN_DEPTH then
                        pending[#pending + 1] = { path = prefix .. e.name, depth = dir.depth + 1 }
                    end
                elseif e.name ~= "" then
                    local bucket = index[e.name:lower()]
                    if not bucket then
                        bucket = {}
                        index[e.name:lower()] = bucket
                    end
                    bucket[#bucket + 1] = { folder = dir.path, name = e.name, size = e.size or 0 }
                    names = names + 1
                end
            end
            folders = folders + 1
            if on_progress then
                pcall(on_progress, folders)
            end
        end
    end
    logger.info("crossdrop: whole-card scan listed ", folders, " folder(s), ", names, " file(s)")
    return true, index
end

-- Delete one file or folder over WebDAV: DELETE http://<ip>:<port>/<path>.
-- NOTE (device-verified): this reader's DELETE does NOT recurse — a
-- non-empty folder answers 409. Returns (true, nil, code) or (nil, err, code)
-- so callers can branch on 409 and purge the folder's contents first. Runs
-- under a standby hold (single blocking op).
function CROSSDROP:deleteEntry(target, path)
    if not target or not target.ip or target.ip == "" then
        return nil, _("WiFi IP not set (see the Connections tab)"), nil
    end
    if not self:wifiUp() then
        return nil, WIFI_OFF_MSG, nil
    end
    local ok_w, r1, r2, r3 = self:withStandby(function()
        local p = tostring(path or ""):gsub("^/+", ""):gsub("/+$", "")
        if p == "" then
            return nil, "nothing to delete", nil
        end
        -- Bounded timeout: rapid deletes queue against a reader that is still
        -- finishing the previous one on slow flash — with req's default 15s/60s
        -- socketutil timeouts each queued delete read as a frozen UI. 5s bounds
        -- the wait; a stuck reader reports an error instead of hanging.
        local ok, code, errbody = self:req("DELETE", base_url(target) .. encode_path("/" .. p),
            nil, nil, 5)
        if ok then
            logger.info("crossdrop: deleted /", p)
            return true, nil, code
        end
        local err = (type(code) == "number")
            and string.format("device replied %s (%s)", tostring(code), tostring(errbody or ""))
            or tostring(code or errbody or "unknown error")
        logger.info("crossdrop: delete failed (", target.ip, "): ", err)
        return nil, err, code
    end)
    if not ok_w then
        return nil, tostring(r1 or "operation aborted"), nil
    end
    return r1, r2, r3
end

-- Make sure the destination folder exists. A nested destination (Books/x)
-- needs EVERY parent, so each "/"-separated segment is MKCOL-created in
-- order — the reader answers 409 "Parent directory does not exist" for a
-- deep create, which a single MKCOL can never survive. 201 (newly created)
-- and 405 (already exists) are both success.
function CROSSDROP:ensureFolder(target)
    local folder = tostring(target.folder or DEFAULT_FOLDER)
    if folder == "" or folder == "/" then
        return true
    end
    local so_far = {}
    for seg in folder:gmatch("[^/]+") do
        so_far[#so_far + 1] = seg
        local prefix = "/" .. table.concat(so_far, "/")
        local ok, code, errbody = self:req("MKCOL", base_url(target) .. encode_path(prefix))
        if not ok and not (type(code) == "number" and code == 405) then
            if type(code) == "number" then
                return nil, string.format("could not create folder (%s: %s)", tostring(code), tostring(errbody or ""))
            end
            return nil, tostring(code or errbody or "unknown error")
        end
    end
    return true
end

-- Current book file path (only file-based documents can be sent).
function CROSSDROP:currentBookPath()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file or doc.file == "" then
        return nil
    end
    return doc.file
end

-- File types the Xteink/CrossPoint reader can actually OPEN (device spec):
-- EPUB 2/3, the native XTC/XTCH (specialized layouts, RTL scripts), plain
-- TXT, and BMP images (custom sleep screens). KOReader itself reads far
-- more (mobi, pdf, fb2, …) — but anything outside this list would arrive on
-- the reader as a file it cannot open, so the Send A File browser only
-- lists these. Case-insensitive: real devices carry ".EPUB" files.
local CROSSPOINT_EXT = { epub = true, xtc = true, xtch = true, txt = true, bmp = true }
function CROSSDROP:isCrossPointFile(path)
    local ext = tostring(path or ""):match("%.([^.]+)$")
    return ext ~= nil and CROSSPOINT_EXT[ext:lower()] == true
end

-- The whole "nothing answered" message: the Tried list (with the probe's own
-- error) plus the concrete fixes. If the last failure was a Wi-Fi bring-up
-- that never completed, that is said FIRST (the message is otherwise about a
-- reachable-network miss, which is a different fault).
function CROSSDROP:noReaderText()
    local note = ""
    if self._wifi_down then
        self._wifi_down = nil
        note = _("Could not turn on Wi-Fi, so the reader was never on the network.\n\nEnable Wi-Fi (Menu → Wi-Fi connection) and try again.\n\n")
    end
    return note .. _("No CrossDrop reader reached.\n\nTried:\n") .. self:connectionSummary() ..
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
-- Gated by ensureWifi: on a KOReader-managed radio (Kobo) the link is brought
-- up before probing, so a check can't aim at a dead interface.
function CROSSDROP:statusDialog()
    self:ensureWifi(function()
        self:statusDialogChecked()
    end, function()
        UIManager:show(Notification:new{
            text = _("Could not turn on Wi-Fi. Enable it via Menu → Wi-Fi connection, then check again."),
            timeout = 5,
        })
    end)
end

function CROSSDROP:statusDialogChecked()
    local ok_w, r1 = self:withStandby(function()
        local checking = Notification:new{ text = _("Checking device…"), timeout = 0 }
        UIManager:show(checking)
        UIManager:forceRePaint()
        local target = self:probeReachable()
        if not target then
            UIManager:close(checking)
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
    end)
    if not ok_w then
        logger.warn("crossdrop: status check aborted: ", tostring(r1 or ""))
    end
end

-- Stream a file to the target with an HTTP PUT. `on_progress(sent, total)` is
-- called as bytes are written. Returns (true, code) or (nil, error_text).
-- Callers run this inside a standby-held flow (sendBooksBatch/sendFileChecked);
-- it must never be used outside one.
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
    -- If the request aborted mid-stream (timeout/error) read_chunk never hit
    -- EOF, so close the handle here to avoid leaking it.
    if fh then
        fh:close()
        fh = nil
    end
    if not ok then
        return nil, (type(result) == "number")
            and string.format("device replied %s (%s)", tostring(result), tostring(result2 or ""))
            or tostring(result or "unknown error")
    end
    return true, result
end

-- Storefront-style Wi-Fi gate around a blocking network action. If the radio
-- is already up (always true on Android/Cervantes and any platform where
-- KOReader doesn't manage the radio), `on_ready` runs synchronously and this
-- is a no-op — behavior is identical to the previous build for users where it
-- already worked. If Wi-Fi is off (typically Kobo), we hand off to the
-- NetworkMgr handshake, which respects the user's "Action when Wi-Fi is off"
-- setting, and `on_ready` runs once the link is actually up (isConnected ⇒
-- link + IP — no internet needed, unlike runWhenOnline).
--
-- NetworkMgr is free to drop the callback (declined prompt, failed connect),
-- so the wait is bounded ourselves: after 45s (KOReader's own give-up point)
-- `on_fail` fires instead. If no NetworkMgr exists (test harness, exotic
-- builds) this is a synchronous no-op passing straight to `on_ready`.
function CROSSDROP:ensureWifi(on_ready, on_fail)
    local ok_ready = on_ready or function() end
    local ok_finish = on_fail or function() end
    local nm = networkManager()
    if not nm
        or type(nm.isWifiOn) ~= "function"
        or type(nm.isConnected) ~= "function"
        or (nm:isWifiOn() and nm:isConnected()) then
        ok_ready()
        return
    end
    logger.info("crossdrop: Wi-Fi is off; asking NetworkMgr to bring it up")
    if type(nm.runWhenConnected) ~= "function" then
        ok_finish()
        return
    end
    local timer
    local done = false
    local function finish(succeeded)
        if done then return end
        done = true
        if timer then
            UIManager:unschedule(timer)
            timer = nil
        end
        logger.info("crossdrop: Wi-Fi", succeeded and " is up, proceeding" or " did not come up in time")
        if succeeded then ok_ready() else ok_finish() end
    end
    timer = UIManager:scheduleIn(45, function() finish(false) end)
    local ok_run = pcall(nm.runWhenConnected, nm, function() finish(true) end)
    if not ok_run then
        finish(false)
    end
end

-- Is the Wi-Fi radio up (reportedly)? When the module is absent we are
-- conservative and answer "yes" — nothing is gated. Used only for cheap
-- synchronous fail-fast guards on single-op calls; the gated entry points
-- (connect/statusDialog/sendFile) run the full handshake instead.
function CROSSDROP:wifiUp()
    local nm = networkManager()
    if not nm or type(nm.isWifiOn) ~= "function" then
        return true
    end
    return nm:isWifiOn() == true
end

-- Run `fn` with UIManager:preventStandby held for the whole blocking op and
-- ALWAYS released afterwards, even if `fn` throws. Returns fn's results
-- (up to three) or (nil, error_text). NOTE: never nest this — inner holds are
-- not ref-counted, an inner release would clear an outer hold early.
function CROSSDROP:withStandby(fn)
    local release = standbyHold()
    local wok, r1, r2, r3 = pcall(fn)
    release()
    if wok then
        return true, r1, r2, r3
    end
    logger.warn("crossdrop: aborted in standby-held op: ", tostring(r1 or ""))
    return nil, tostring(r1 or "operation aborted")
end

-- Mark the last failure as a Wi-Fi bring-up miss and drive the sink's
-- unreachable surface (Home paints its "Send failed" state from that sink).
-- noReaderText() then starts with the Wi-Fi note instead of a network miss.
function CROSSDROP:_wifiDownReach(sink)
    self._wifi_down = true
    self._reach = {}
    for _, t in ipairs(self:configuredTargets()) do
        self._reach[t.kind] = "down"
    end
    if sink and sink.onUnreachable then
        sink:onUnreachable()
    end
end

-- Resolve the first reachable connection through a progress sink. Sink
-- callbacks: onConnecting() before the probe, onConnected(target), or
-- onUnreachable() when nothing answers. Probes are bounded (a retrying
-- 4s/6s pair, via socketutil) and the caller paints each state on screen, so
-- the UI never closes and never looks frozen. Gated by ensureWifi: where the
-- radio is already up this probes synchronously; on a KOReader-managed radio
-- (Kobo) it waits for the link first. `on_target(target)` fires once a
-- target resolves (used by sendBooks' batch continuation).
function CROSSDROP:connect(sink, on_target)
    sink = sink or {}
    local result
    self:ensureWifi(function()
        result = self:connectChecked(sink)
        if result and on_target then
            on_target(result)
        end
    end, function()
        self:_wifiDownReach(sink)
    end)
    -- The synchronous fast path (Wi-Fi already up) resolves before this return;
    -- an async bring-up resolves later (nil here) and drives the sink callbacks.
    return result
end

-- The probe half of connect(), run when Wi-Fi is already known to be up.
-- Kept separate so the gated and in-batch paths don't double-gate.
function CROSSDROP:connectChecked(sink)
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

    -- Storefront-style gate at the batch's entry: where the radio is always up
    -- this runs the batch synchronously (behavior identical to before); on a
    -- KOReader-managed radio (Kobo) the whole batch waits until Wi-Fi is up, and
    -- if that never happens the sink gets the same unreachable surface a failed
    -- probe would. When an async bring-up happens, this returns before the batch
    -- runs — the sink callbacks still drive the dashboard.
    local result
    self:ensureWifi(function()
        result = self:sendBooksChecked(ordered, sink)
    end, function()
        self:_wifiDownReach(sink)
    end)
    -- A synchronous fast-path run (radio up / no NetworkMgr) already produced
    -- the batch's result; an async bring-up returns `false` (callers never used
    -- the immediate return to drive the UI).
    return result or false
end

-- The batch itself (Wi-Fi known up). Standby is held across the WHOLE batch:
-- connect probe + every MKCOL + every PUT. On KOReader-managed radios an
-- autosuspend between blocking calls would tear the link down mid-batch.
function CROSSDROP:sendBooksChecked(ordered, sink)
    local release = standbyHold()
    local ok_w, all_ok = pcall(function()
        local target = self:connectChecked(sink)
        if not target then
            return false
        end

        local batch_start = os.clock()

        local batch_ok = true
        for i, path in ipairs(ordered) do
            if sink.onBeginFile then sink:onBeginFile(path, target, i, #ordered) end
            local folder_ok, folder_err = self:ensureFolder(target)
            if not folder_ok then
                batch_ok = false
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
                batch_ok = false
                if sink.onFileFailed then
                    sink:onFileFailed(path, tostring(result))
                end
                break
            end
            if sink.onFileSent then sink:onFileSent(path, target) end
            logger.info("crossdrop: sent ", path, " to ", target.kind, " ", target.ip)
        end
        return batch_ok
    end)
    release()
    if not ok_w then
        logger.warn("crossdrop: send batch aborted: ", tostring(all_ok or ""))
        if sink.onDone then sink:onDone(false) end
        return false
    end
    if sink.onDone then sink:onDone(all_ok) end
    return all_ok
end

-- Send an explicit book file (standalone dialog flow: probe + progress +
-- toast). Used by sendCurrentBook and as the no-Home fallback of sendBooks.
-- Gated by ensureWifi (Storefront-style): where the radio is always up this
-- runs through synchronously exactly like the previous build; on Kobo it
-- brings Wi-Fi up first so the probe below isn't aiming at a dead link.
function CROSSDROP:sendFile(book_path)
    if not book_path or book_path == "" then return end
    self:ensureWifi(function()
        self:sendFileChecked(book_path)
    end, function()
        logger.warn("crossdrop: Wi-Fi could not be brought up, not sending")
        UIManager:show(InfoMessage:new{
            text = _("Could not turn on Wi-Fi, so CrossDrop cannot send.\n\nEnable Wi-Fi (Menu → Wi-Fi connection) and try again."),
        })
    end)
end

-- The standalone send itself (Wi-Fi known up); standby held across the probe
-- AND the transfer so a long send survives autosuspend on Kobo.
function CROSSDROP:sendFileChecked(book_path)
    local ok_w, r1 = self:withStandby(function()
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
            toastModule().show(string.format(_("File sent  %s (WiFi  %s  \226\134\146  %s)"),
                tostring(filename),
                tostring(target.ip),
                tostring(target.folder or DEFAULT_FOLDER)), 3)
            logger.info("crossdrop: sent ", book_path, " to ", target.kind, " ", target.ip)
        else
            toastModule().show(_("Send failed: ") .. tostring(result) ..
                _("\nCheck the reader has File Transfer open on the\nsame Wi-Fi network, and that the IP is correct."), 5)
            logger.warn("crossdrop: send failed (", target.ip, "): ", result)
        end
    end)
    if not ok_w then
        logger.warn("crossdrop: standalone send aborted: ", tostring(r1 or ""))
    end
end

-- Send the currently open book. Guarded so a nil document just shows a hint
-- instead of crashing (the Home "Send A File" picker never hits this path).
function CROSSDROP:sendCurrentBook()
    local book_path = self:currentBookPath()
    if not book_path then
        UIManager:show(InfoMessage:new{
            text = _("There is no file to send. Use Send A File to pick one."),
        })
        return
    end
    self:guardDuplicates({ book_path }, function()
        self:sendFile(book_path)
    end)
end

-- The one-tap send paths ("Currently open" row, sendCurrentBook) bypass the
-- picker, so they never build a whole-card index. Rescan the reader here and
-- pause on the picker's exact Send-anyway/Don't-send confirm when the book is
-- ALREADY on the card — the duplication cannot be walked past on any route out
-- of the dashboard. on_ok always receives the ORIGINAL batch; confirming one
-- duplicate never drops siblings. A failed/unreachable scan just proceeds: the
-- send's own probe reports an unreachable reader.
function CROSSDROP:guardDuplicates(paths, on_ok)
    local ConfirmBox = require("ui/widget/confirmbox")
    local target = self:resolveTarget()
    if not target or not target.ip or target.ip == "" then
        on_ok(paths)
        return
    end
    local checking = Notification:new{ text = _("Scanning the reader\226\128\166"), timeout = 0 }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local ok, index = self:listAllFiles(target)
    UIManager:close(checking)
    UIManager:forceRePaint()
    if not ok or not index then
        on_ok(paths)
        return
    end
    local entry, path
    for _, p in ipairs(paths or {}) do
        local name = tostring(p):match("([^/]+)$") or tostring(p)
        local size = lfs.attributes(p, "size") or 0
        local e = pickerModule().matchReaderIndex(index, name, size)
        if e then
            entry, path = e, p
            break
        end
    end
    if not entry then
        on_ok(paths)
        return
    end
    local title = tostring(path):match("([^/]+)$") or tostring(path)
    local where = (entry.folder and entry.folder ~= "")
        and ("/" .. entry.folder) or ("/")
    where = where .. "/" .. tostring(entry.name or title)
    local confirm
    confirm = ConfirmBox:new{
        text = string.format(_("%s \226\128\148 already on the reader\n(%s)\n\nSend it to the reader again?"),
            tostring(title), where),
        ok_text = _("Send anyway"),
        cancel_text = _("Don't send"),
        ok_callback = function()
            UIManager:close(confirm)
            on_ok(paths)
        end,
        cancel_callback = function()
            UIManager:close(confirm)
        end,
    }
    logger.info("crossdrop: quick-send flagged a duplicate: ",
        tostring(path), " matches ", where)
    UIManager:show(confirm)
end

-- "Send A File": open the CrossDrop file picker (crossdrop_picker.lua) —
-- a device-wide scan for CrossPoint-openable files rendered on the
-- dashboard's proven widgets (rows of Buttons on the full-screen card,
-- the dashboard's TitleBar with its back chevron). The built-in file
-- browser is not involved at all: no FileChooser, no Menu, no custom
-- title bars — every attempt to ride those rendered blank controls on
-- this device. The picker scans once per open (cached), keeps its own
-- picked set, and its first row is the always-visible "Send to Xteink"
-- action.
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