--[[
CrossDrop — KOReader plugin.

Adds a "CrossDrop" entry to the reader menu that hands the currently open book
to the reader over the local network. It uses only the built-in web-server
endpoints — no custom firmware required:

    GET   /api/status          device info + connection test
    GET   /api/files?path=/    remote folder browser (destination picker)
    MKCOL /<folder>            create a destination folder if needed
    PUT   /<folder>/<file>     stream the book, chunk by chunk

On the reader side, the matching "CrossDrop" SD plugin (the `crossdrop-plugin`
folder on the SD card) is a pure instructions screen (Settings → System →
Plugins) that explains how to install and use this plugin.

Pure LuaSocket (part of KOReader) — no external dependencies, and the file is
streamed chunk-by-chunk from disk so devices with little RAM (like a Kindle)
can send books of any size. The transfer progress dialog repaints live while
the chunks stream (the same forceRePaint technique the Storefront plugin uses).
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local InputContainer = require("ui/widget/container/inputcontainer")

-- The dialog widgets (font, buttons, frames…) are required lazily, inside the
-- dialogs that use them, so loading this plugin only depends on the core
-- modules above — exactly like the old Send-to-Xteink plugin did.
local loaded_widgets
local function widgets()
    if not loaded_widgets then
        local Device = require("device")
        loaded_widgets = {
            Blitbuffer = require("ffi/blitbuffer"),
            Button = require("ui/widget/button"),
            ButtonTable = require("ui/widget/buttontable"),
            CenterContainer = require("ui/widget/container/centercontainer"),
            Device = Device,
            Font = require("ui/font"),
            FrameContainer = require("ui/widget/container/framecontainer"),
            MovableContainer = require("ui/widget/container/movablecontainer"),
            Size = require("ui/size"),
            TextWidget = require("ui/widget/textwidget"),
            VerticalGroup = require("ui/widget/verticalgroup"),
            VerticalSpan = require("ui/widget/verticalspan"),
            Screen = Device.screen,
        }
    end
    return loaded_widgets
end

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

-- Parent of a path; "/Books/sub" -> "/Books", "/Books" -> "/", "/" -> "/".
local function parent_path(path)
    local trimmed = tostring(path or ""):gsub("/+$", "")
    if trimmed == "" then
        return "/"
    end
    local parent = trimmed:match("^(.*)/[^/]+$")
    return parent and parent or "/"
end

-- Persisted history of recently used send targets (max 10, deduped by IP).
local function getIpList()
    local list = G_reader_settings:readSetting("crossdrop_ips")
    return (type(list) == "table") and list or {}
end

local function removeFromIpList(ip)
    local list = getIpList()
    local newlist = {}
    for _, target in ipairs(list) do
        if target.ip ~= ip then
            newlist[#newlist + 1] = target
        end
    end
    G_reader_settings:saveSetting("crossdrop_ips", newlist)
    if G_reader_settings:readSetting("crossdrop_ip") == ip then
        G_reader_settings:saveSetting("crossdrop_ip", nil)
    end
end

local function clearIpList()
    G_reader_settings:saveSetting("crossdrop_ips", {})
    G_reader_settings:saveSetting("crossdrop_ip", nil)
end

local function addToIpList(target)
    if not target or not target.ip then return end
    local list = getIpList()
    local newlist = {}
    for _, t in ipairs(list) do
        if t.ip ~= target.ip then newlist[#newlist + 1] = t end
    end
    table.insert(newlist, 1, {
        ip = target.ip,
        port = target.port or 80,
        folder = target.folder or "/Books",
        ts = os.time(),
    })
    while #newlist > 10 do table.remove(newlist) end
    G_reader_settings:saveSetting("crossdrop_ips", newlist)
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

local function fmt_reltime(ts)
    local dt = os.time() - (tonumber(ts) or 0)
    if dt < 60 then return _("just now") end
    if dt < 3600 then return string.format(_("%d m ago"), math.floor(dt / 60)) end
    if dt < 86400 then return string.format(_("%d h ago"), math.floor(dt / 3600)) end
    return string.format(_("%d d ago"), math.floor(dt / 86400))
end

function CROSSDROP:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("crossdrop: self.ui or self.ui.menu not initialized")
    end
end

-- Generic HTTP call. Returns (ok, code, body). On a network failure `code`
-- carries LuaSocket's error string and `ok` is nil.
function CROSSDROP:req(method, url, headers, source_fn)
    if not socket_available() then
        return nil, "LuaSocket unavailable", nil
    end
    local ok, body, code = pcall(http.request, {
        url = url,
        method = method,
        headers = headers or {["User-Agent"] = "KOReader/crossdrop"},
        source = source_fn,
        create = function()
            local s = socket.tcp()
            if s then
                pcall(function()
                    s:settimeout(10)
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

-- Make sure the destination folder exists (MKCOL; 405 = already exists).
function CROSSDROP:ensureFolder(target)
    local folder = tostring(target.folder or "/Books")
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

-- List the directories inside a remote folder. Returns (true, list) or (nil, err).
function CROSSDROP:listFolders(target, folder)
    local encoded = ""
    if folder and folder ~= "" and folder ~= "/" then
        encoded = encode_path(folder):gsub("^/", "")
    end
    local url = base_url(target) .. "/api/files?path=" .. encoded
    local ok, code, body = self:req("GET", url)
    if not ok then
        return nil, (type(code) == "number")
            and string.format("device replied %s", tostring(code))
            or tostring(code or "unknown error")
    end
    if not JSON then
        return nil, "JSON parser unavailable"
    end
    local parsed, perr = JSON.decode(body)
    if type(parsed) ~= "table" then
        return nil, "unexpected device response" .. (perr and (" (" .. tostring(perr) .. ")") or "")
    end
    local dirs = {}
    for _, item in ipairs(parsed) do
        if type(item) == "table" and item.isDirectory and type(item.name) == "string" then
            dirs[#dirs + 1] = item.name
        end
    end
    table.sort(dirs, function(a, b) return a < b end)
    return true, dirs
end

-- Build the CrossDrop submenu. `keep_menu_open = true` keeps the reader menu
-- open underneath dialogs/browser, so Back steps out one level instead of
-- closing everything.
function CROSSDROP:buildSubItems()
    local sub_items = {
        {
            text = _("CrossDrop home..."),
            keep_menu_open = true,
            callback = function() self:openHome() end,
        },
        {
            text = _("Send current book"),
            keep_menu_open = true,
            callback = function() self:sendCurrentBook() end,
        },
    }
    local list = getIpList()
    if #list > 0 then
        sub_items[#sub_items + 1] = {text = "─" .. _("Saved devices") .. "─", enabled = false}
        for _, t in ipairs(list) do
            local label = t.ip
            if t.port and t.port ~= 80 then label = label .. ":" .. t.port end
            if t.folder and t.folder ~= "" and t.folder ~= "/" then
                label = label .. "  → " .. t.folder
            end
            sub_items[#sub_items + 1] = {
                text = label,
                keep_menu_open = true,
                callback = function()
                    self:saveTarget(t)
                    self:sendCurrentBook()
                end,
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove saved device ") .. label .. "?",
                        ok_text = _("Remove"),
                        ok_callback = function()
                            removeFromIpList(t.ip)
                            self:refreshMenu()
                        end,
                    })
                end,
            }
        end
        sub_items[#sub_items + 1] = {
            text = _("Delete all stored devices"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget all stored device addresses?"),
                    ok_text = _("Delete all"),
                    ok_callback = function()
                        clearIpList()
                        self:refreshMenu()
                    end,
                })
            end,
        }
    end
    sub_items[#sub_items + 1] = {text = "─" .. _("Device") .. "─", enabled = false}
    sub_items[#sub_items + 1] = {
        text = _("Device IP..."),
        keep_menu_open = true,
        callback = function() self:editIp() end,
    }
    sub_items[#sub_items + 1] = {
        text = _("CrossDrop hotspot (192.168.4.1)"),
        keep_menu_open = true,
        callback = function() self:useHotspot() end,
    }
    sub_items[#sub_items + 1] = {
        text = _("Destination folder..."),
        keep_menu_open = true,
        callback = function() self:pickFolder() end,
    }
    sub_items[#sub_items + 1] = {
        text = _("Check device..."),
        keep_menu_open = true,
        callback = function() self:statusDialog() end,
    }
    sub_items[#sub_items + 1] = {
        text = _("Sent books..."),
        keep_menu_open = true,
        callback = function() self:sentBooksDialog() end,
    }
    return sub_items
end

function CROSSDROP:addToMainMenu(menu_items)
    menu_items.crossdrop = {
        text = _("CrossDrop"),
        sorting_hint = "tools",
        sub_item_table = self:buildSubItems(),
    }
end

-- Rebuild the currently open CrossDrop submenu in place (e.g. after deleting a
-- saved device) instead of closing the whole menu.
function CROSSDROP:refreshMenu()
    local menu = self.ui and self.ui.menu
    if not menu then return end
    menu.item_table = self:buildSubItems()
    menu:updateItems(1)
end

-- Current book file path (only file-based documents can be sent).
function CROSSDROP:currentBookPath()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file or doc.file == "" then
        return nil
    end
    return doc.file
end

-- Resolve the send target from stored settings, or nil when not configured.
function CROSSDROP:resolveTarget()
    local ip = G_reader_settings:readSetting("crossdrop_ip")
    if not ip then
        return nil
    end
    return {
        ip = ip,
        port = tonumber(G_reader_settings:readSetting("crossdrop_port") or 80),
        folder = G_reader_settings:readSetting("crossdrop_folder") or "/Books",
        hostname = "CrossDrop",
    }
end

function CROSSDROP:saveTarget(target)
    G_reader_settings:saveSetting("crossdrop_ip", target.ip)
    G_reader_settings:saveSetting("crossdrop_port", target.port or 80)
    G_reader_settings:saveSetting("crossdrop_folder", target.folder or "/Books")
    addToIpList(target)
end

-- Quick-connect for when the reader acts as its own Wi-Fi hotspot. CrossPoint
-- (and Beta 8) run the AP on the ESP32 default 192.168.4.1 — no softAPConfig
-- override — so the reader is always reachable there while it is in hotspot
-- mode. Saves the target and immediately probes via statusDialog.
function CROSSDROP:useHotspot()
    local target = {
        ip = "192.168.4.1",
        port = 80,
        folder = G_reader_settings:readSetting("crossdrop_folder") or "/Books",
    }
    self:saveTarget(target)
    self:statusDialog()
end

-- Stream a file to the target with an HTTP PUT. `on_progress(sent, total)` is
-- called as bytes are written. Returns (true, code) or (nil, error_text).
function CROSSDROP:putFile(target, file_path, on_progress)
    local size = lfs.attributes(file_path, "size")
    if not size then
        return nil, "cannot stat file"
    end

    local filename = file_path:match("([^/]+)$") or file_path
    local url = base_url(target) .. encode_path(target.folder or "/Books") .. "/" .. url_encode_segment(filename)

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

function CROSSDROP:sendCurrentBook()
    local book_path = self:currentBookPath()
    if not book_path then
        UIManager:show(InfoMessage:new{
            text = _("There is no book file to send. Open a book first."),
        })
        return
    end

    local target = self:resolveTarget()
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("No device configured.\n\nOn the reader open File Transfer → Join Network,\nnote the IP it shows, then set it here via\n\"Device IP...\" (or the CrossDrop home screen)."),
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
            ip = target.ip,
            port = target.port or 80,
            folder = target.folder or "/Books",
            file = filename,
            size = book_size,
        })
        toastModule().show(string.format(_("Book sent to %s  →  %s"),
            tostring(target.ip), tostring(target.folder or "/Books")), 3)
        logger.info("crossdrop: sent ", book_path, " to ", target.ip)
    else
        toastModule().show(_("Send failed: ") .. tostring(result) ..
            _("\nCheck the reader has File Transfer open on the\nsame Wi-Fi network, and that the IP is correct."), 5)
        logger.warn("crossdrop: send failed (", target.ip, "): ", result)
    end
end

-- Open the full-screen CrossDrop home dashboard.
function CROSSDROP:openHome()
    UIManager:show(homeModule():new{ plugin = self })
end

-- Set the target and immediately send the current book (used by the Home
-- screen rows and history re-send taps).
function CROSSDROP:sendTo(target)
    if not target or not target.ip then return end
    self:saveTarget(target)
    self:sendCurrentBook()
end

-- Actions for a long-pressed saved device row in the Home screen.
function CROSSDROP:deviceActions(target)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ip = target.ip
    if target.port and target.port ~= 80 then ip = ip .. ":" .. tostring(target.port) end
    UIManager:show(ButtonDialog:new{
        title = ip .. "  →  " .. (target.folder and target.folder ~= "" and target.folder or "/Books"),
        buttons = {
            {
                {
                    text = _("Send current book"),
                    callback = function()
                        self:sendTo(target)
                    end,
                },
            },
            {
                {
                    text = _("Check device..."),
                    callback = function()
                        self:statusDialog()
                    end,
                },
                {
                    text = _("Destination folder..."),
                    callback = function()
                        self:pickFolder()
                    end,
                },
            },
            {
                {
                    text = _("Edit IP..."),
                    callback = function()
                        self:editIp()
                    end,
                },
                {
                    text = _("Forget"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Remove saved device ") .. ip .. "?",
                            ok_text = _("Remove"),
                            ok_callback = function()
                                removeFromIpList(target.ip)
                                self:refreshMenu()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(self.ui and self.ui.menu)
                    end,
                },
            },
        },
    })
end

function CROSSDROP:clearSentList()
    saveSentList({})
end

function CROSSDROP:editIp()
    local ip_dialog
    ip_dialog = InputDialog:new{
        title = _("Reader IP (File Transfer → Join Network)"),
        input = G_reader_settings:readSetting("crossdrop_ip") or "",
        type = "text",
        buttons = {
            {
                {
                    text = _("Save"),
                    callback = function()
                        local value = ip_dialog:getInputText()
                        if value and value ~= "" then
                            G_reader_settings:saveSetting("crossdrop_ip", value)
                            addToIpList({ip = value, port = G_reader_settings:readSetting("crossdrop_port") or 80,
                                folder = G_reader_settings:readSetting("crossdrop_folder") or "/Books"})
                        else
                            G_reader_settings:saveSetting("crossdrop_ip", nil)
                        end
                        UIManager:close(ip_dialog)
                    end,
                },
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

-- GET /api/status and show the result in a message.
function CROSSDROP:statusDialog()
    local target = self:resolveTarget()
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("No device configured.\n\nSet the IP address via \"Device IP...\"\n(first, on the reader: File Transfer → Join Network\n— the IP is shown on that screen)."),
        })
        return
    end
    local ok, code, body = self:req("GET", base_url(target) .. "/api/status")
    if not ok then
        UIManager:show(Notification:new{
            text = _("Could not reach the CrossDrop reader: ") .. tostring(code or "network error") ..
                _("\n\nSame Wi-Fi? Correct IP? File Transfer open?"),
            timeout = 5,
        })
        return
    end
    local details = body or ""
    if JSON then
        local okj, parsed = pcall(JSON.decode, body)
        if okj and type(parsed) == "table" then
            details = string.format("IP %s  ·  %s\nversion %s  ·  mode %s",
                tostring(parsed.ip or target.ip),
                tostring(parsed.device or "CrossDrop reader"),
                tostring(parsed.version or "?"),
                tostring(parsed.mode or "?"))
            if type(parsed.rssi) == "number" and parsed.mode == "STA" then
                details = details .. string.format("\nWi-Fi RSSI %d dBm", parsed.rssi)
            end
        end
    end
    UIManager:show(InfoMessage:new{
        text = _("CrossDrop device found:\n\n") .. details,
    })
end

-- Read-only log of books sent (shows reader, destination folder, size, time).
function CROSSDROP:sentBooksDialog()
    if #getSentList() == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Nothing sent yet.\n\nBooks you send are logged here with the target\nCrossDrop reader, destination folder, and size."),
        })
        return
    end
    UIManager:show(SentBooksDialog:new{})
end

-- Pick (and if needed create) the destination folder on the reader.
-- (FolderBrowser is declared before this so pickFolder can instantiate it.)
local FolderBrowser = InputContainer:extend{
    modal = true,
    dismissable = false,
    alignment = "center",
}

function CROSSDROP:pickFolder()
    local target = self:resolveTarget()
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("Set the reader's IP address via \"Device IP...\" first."),
        })
        return
    end
    local browser = FolderBrowser:new{
        builder = self,
        target = target,
        path = G_reader_settings:readSetting("crossdrop_folder") or "/Books",
        onSelect = function(path)
            self:saveTarget({ip = target.ip, port = target.port or 80, folder = path})
        end,
    }
    UIManager:show(browser)
end

-- ────────────────────────── remote folder browser ──────────────────────────

function FolderBrowser:init()
    local w = widgets()
    local Screen = w.Screen
    local TextWidget = w.TextWidget
    local Font = w.Font
    local Button = w.Button
    local VerticalGroup = w.VerticalGroup
    local ButtonTable = w.ButtonTable
    local VerticalSpan = w.VerticalSpan
    local FrameContainer = w.FrameContainer
    local Blitbuffer = w.Blitbuffer
    local Size = w.Size
    local MovableContainer = w.MovableContainer
    local CenterContainer = w.CenterContainer
    local Device = w.Device
    local max_height = Screen:getHeight()
    local content_w = math.min(Screen:getWidth() - 60, 560)
    local bw = content_w - 24

    local rows = {}
    local ok, list = self.builder:listFolders(self.target, self.path)
    if ok then
        local shown = 0
        for i = 1, #list do
            local name = list[i]
            shown = shown + 1
            rows[#rows + 1] = Button:new{
                text = name,
                width = bw,
                callback = function()
                    local newpath = (self.path == "/" and "" or self.path:gsub("/+$", "")) ..
                        "/" .. name
                    UIManager:replace(self, FolderBrowser:new{
                        builder = self.builder,
                        target = self.target,
                        path = newpath,
                        onSelect = self.onSelect,
                    })
                end,
            }
        end
        if #list == 0 then
            rows[#rows + 1] = TextWidget:new{
                text = _("(no folders here)"),
                face = Font:getFace("smallitalic"),
            }
        end
    else
        rows[#rows + 1] = TextWidget:new{
            text = _("Could not list folders on the CrossDrop reader:\n") .. tostring(list) ..
                _("\n\nYou can still pick this path — CrossDrop\ncreates it when the folder is missing."),
            face = Font:getFace("small"),
        }
    end

    local inner = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = _("Destination folder on the CrossDrop reader"),
            face = Font:getFace("small"),
        },
        TextWidget:new{
            text = self.path,
            face = Font:getFace("bold"),
        },
    }
    for i = 1, #rows do
        inner:addWidget(rows[i])
    end

    local button_table = ButtonTable:new{
        buttons = {
            {
                {
                    text = _("Up one level"),
                    enabled = self.path ~= "/",
                    callback = function()
                        UIManager:replace(self, FolderBrowser:new{
                            builder = self.builder,
                            target = self.target,
                            path = parent_path(self.path),
                            onSelect = self.onSelect,
                        })
                    end,
                },
                {
                    text = _("New folder..."),
                    callback = function() self:newFolder() end,
                },
            },
            {
                {
                    text = _("Select this folder"),
                    callback = function()
                        self.onSelect(self.path)
                        UIManager:close(self)
                    end,
                },
                {text = _("Cancel"), callback = function() UIManager:close(self) end},
            },
        },
        zero_sep = true,
        show_parent = self,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            inner,
            VerticalSpan:new{width = Size.padding.default},
            button_table,
        },
    }
    self.movable = MovableContainer:new{
        frame,
        unmovable = false,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- Back steps up one folder level while browsing; only at the root does it
-- close the browser and return to the (still open) reader menu.
function FolderBrowser:onBack()
    if self.path ~= "/" then
        UIManager:replace(self, FolderBrowser:new{
            builder = self.builder,
            target = self.target,
            path = parent_path(self.path),
            onSelect = self.onSelect,
        })
    else
        UIManager:close(self)
    end
    return true
end

function FolderBrowser:newFolder()
    local dialog
    dialog = InputDialog:new{
        title = _("New folder in ") .. self.path,
        input = "",
        type = "text",
        buttons = {
            {
                {
                    text = _("Create"),
                    callback = function()
                        local name = dialog:getInputText()
                        local clean = name and name:gsub("^/+", ""):gsub("/+$", "") or ""
                        UIManager:close(dialog)
                        if clean == "" then
                            return
                        end
                        local url = base_url(self.target) ..
                            encode_path(self.path) .. "/" .. url_encode_segment(clean)
                        local ok, code, errbody = self.builder:req("MKCOL", url)
                        if ok or (type(code) == "number" and code == 405) then
                            UIManager:show(Notification:new{
                                text = _("Folder created."),
                                timeout = 2,
                            })
                            UIManager:replace(self, FolderBrowser:new{
                                builder = self.builder,
                                target = self.target,
                                path = self.path,
                                onSelect = self.onSelect,
                            })
                        else
                            UIManager:show(Notification:new{
                                text = _("Could not create folder: ") ..
                                    (type(code) == "number" and tostring(code) or tostring(code or "error")),
                                timeout = 4,
                            })
                        end
                    end,
                },
                {text = _("Cancel"), callback = function() UIManager:close(dialog) end},
            },
        },
    }
    UIManager:show(dialog)
end

-- ────────────────────── sent-books history dialog ───────────────────────

local SentBooksDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    alignment = "center",
}

function SentBooksDialog:init()
    local w = widgets()
    local Screen = w.Screen
    local TextWidget = w.TextWidget
    local Font = w.Font
    local Button = w.Button
    local VerticalGroup = w.VerticalGroup
    local ButtonTable = w.ButtonTable
    local VerticalSpan = w.VerticalSpan
    local FrameContainer = w.FrameContainer
    local Blitbuffer = w.Blitbuffer
    local Size = w.Size
    local MovableContainer = w.MovableContainer
    local CenterContainer = w.CenterContainer
    local Device = w.Device
    local content_w = math.min(Screen:getWidth() - 60, 560)
    local bw = content_w - 24

    local rows = {}
    local list = getSentList()
    local shown = 0
    for _, e in ipairs(list) do
        if shown >= 8 then break end
        shown = shown + 1
        local ip = e.ip or "?"
        if e.port and e.port ~= 80 then ip = ip .. ":" .. e.port end
        local folder = (e.folder and e.folder ~= "") and e.folder or "/Books"
        local meta = fmt_reltime(e.ts) .. "  ·  " .. ip .. "  →  " .. folder
        if e.size and e.size > 0 then
            meta = meta .. string.format("  ·  %.1f MB", e.size / 1048576)
        end
        rows[#rows + 1] = Button:new{
            text = tostring(e.file or "?") .. "\n" .. meta,
            width = bw,
            callback = function() UIManager:close(self) end,
        }
    end
    if #rows == 0 then
        rows[#rows + 1] = TextWidget:new{
            text = _("No books sent yet."),
            face = Font:getFace("smallitalic"),
        }
    end

    local inner = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = _("Books sent over Wi-Fi (most recent first)"),
            face = Font:getFace("small"),
        },
    }
    for i = 1, #rows do
        inner:addWidget(rows[i])
    end
    if #list > shown then
        inner:addWidget(TextWidget:new{
            text = string.format(_("... plus %d more (only the last 8 are listed)"), #list - shown),
            face = Font:getFace("smallitalic"),
        })
    end

    local button_table = ButtonTable:new{
        buttons = {
            {
                {
                    text = _("Clear history"),
                    callback = function()
                        saveSentList({})
                        UIManager:replace(self, SentBooksDialog:new{})
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() UIManager:close(self) end,
                },
            },
        },
        zero_sep = true,
        show_parent = self,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            inner,
            VerticalSpan:new{width = Size.padding.default},
            button_table,
        },
    }
    self.movable = MovableContainer:new{
        frame,
        unmovable = false,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function SentBooksDialog:onBack()
    UIManager:close(self)
    return true
end

return CROSSDROP