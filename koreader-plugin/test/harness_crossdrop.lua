-- Stub harness: load crossdrop.koplugin/main.lua and exercise the pure logic
-- (req/ensureFolder/putFile/sendCurrentBook/statusDialog + Home dashboard)
-- against a FAKE device, including the LuaSocket string-error case that used to crash.

-- Resolve the plugin root relative to this harness file so it runs from any
-- checkout (and in CI): arg[0] is "koreader-plugin/test/harness_crossdrop.lua".
local HARNESS_DIR = (arg and arg[0] and arg[0]:gsub("(.*/)[^/]+$", "%1")) or "koreader-plugin/test/"
local PLUGIN_ROOT = HARNESS_DIR .. "../"
package.path = PLUGIN_ROOT .. "/?.lua;" .. PLUGIN_ROOT .. "/crossdrop.koplugin/?.lua;" .. package.path

local json_mod = {}

local function decode_json(s, pos)
    pos = pos or 1
    local function skip()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function parse()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                skip()
                local k = parse()
                skip()
                assert(s:sub(pos, pos) == ":", "expected :")
                pos = pos + 1
                local v = parse()
                obj[k] = v
                skip()
                local cc = s:sub(pos, pos)
                if cc == "," then pos = pos + 1
                elseif cc == "}" then pos = pos + 1 return obj
                else error("bad obj at " .. pos) end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = parse()
                skip()
                local cc = s:sub(pos, pos)
                if cc == "," then pos = pos + 1
                elseif cc == "]" then pos = pos + 1 return arr
                else error("bad arr at " .. pos) end
            end
        elseif c == '"' then
            pos = pos + 1
            local out = {}
            while true do
                local ch = s:sub(pos, pos)
                if ch == '"' then pos = pos + 1 break end
                if ch == "\\" then
                    pos = pos + 1
                    local e = s:sub(pos, pos)
                    if e == "n" then out[#out+1] = "\n"
                    elseif e == "t" then out[#out+1] = "\t"
                    elseif e == '"' then out[#out+1] = '"'
                    elseif e == "\\" then out[#out+1] = "\\"
                    elseif e == "/" then out[#out+1] = "/"
                    else error("bad escape " .. e) end
                    pos = pos + 1
                else
                    out[#out+1] = ch
                    pos = pos + 1
                end
            end
            return table.concat(out)
        elseif c == "t" then pos = pos + 4 return true
        elseif c == "f" then pos = pos + 5 return false
        elseif c == "n" then pos = pos + 4 return nil
        elseif c:match("%d") or c == "-" then
            local start = pos
            while s:sub(pos, pos):match("[%d%.eE+-]") do pos = pos + 1 end
            return tonumber(s:sub(start, pos - 1))
        else
            error("unexpected char " .. tostring(c) .. " at " .. pos)
        end
    end
    return parse()
end

json_mod.decode = function(s)
    local ok, v = pcall(decode_json, s, 1)
    if not ok then return nil, v end
    return v
end

-- ── KOReader module stubs ────────────────────────────────────────────────

-- Geometry emulation: the Kindle PW5 SE reports 1236x1648 (portrait) and
-- scaleBySize(px) = ceil(px * min(w,h)/600) (see its ffi/framebuffer.lua).
-- The stubs measure auto-sized text instead of returning {0,0}, so a layout
-- that runs past the screen edges on the device fails the harness too.
local SCREEN_W, SCREEN_H = 1236, 1648
local SCREEN_SCALE = SCREEN_W / 600
local function scal(v) return math.ceil((v or 0) * SCREEN_SCALE) end

local FACE_SIZES = {
    cfont = 24, tfont = 26, smalltfont = 24, x_smalltfont = 22,
    ffont = 20, smallffont = 15, largeffont = 25, pgfont = 20,
    scfont = 20, rifont = 16, hpkfont = 20, hfont = 24,
    infont = 22, smallinfont = 16, infofont = 24, smallinfofont = 22,
    smallinfofontbold = 22, x_smallinfofont = 20, xx_smallinfofont = 18,
}

local function utf8_chars(s)
    local n = 0
    for _ in (s .. ""):gmatch("[\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

local function measure_text(text, face, max_width)
    local fsize = (face and face.s) or 22
    local cw = math.ceil(fsize * 0.5)
    local w, lines = 0, 1
    for part in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        w = math.max(w, utf8_chars(part) * cw)
        lines = lines + 1
    end
    if max_width then w = math.min(w, max_width) end
    return { w = w, h = lines * math.ceil(fsize * 1.2) }
end

local class = {}
function class:getSize()
    local name = self.__name
    if name == "VerticalSpan" or name == "HorizontalSpan" then
        local w = self.width or 0
        return { w = name == "HorizontalSpan" and w or 0, h = name == "VerticalSpan" and w or 0 }
    end
    if name == "VerticalGroup" or name == "HorizontalGroup" then
        local w, h = 0, 0
        for i = 1, #self do
            local kid = self[i]
            if type(kid) == "table" and type(kid.getSize) == "function" then
                local s = kid:getSize()
                if name == "VerticalGroup" then
                    w = math.max(w, s.w); h = h + s.h
                else
                    w = w + s.w; h = math.max(h, s.h)
                end
            end
        end
        return { w = w, h = h }
    end
    if name == "FrameContainer" then
        local child = self[1]
        -- Match the device: FrameContainer:getSize does self[1]:getSize() with
        -- no nil guard, and OverlapGroup:init builds all children at init time —
        -- a childless FrameContainer inside an OverlapGroup crashed the send
        -- progress dialog on the Kindle. Fail the harness instead.
        if child == nil then
            error("FrameContainer:getSize on a childless FrameContainer (crashes the Kindle)")
        end
        local cs = (type(child) == "table" and type(child.getSize) == "function") and child:getSize() or { w = 0, h = 0 }
        local p = self.padding or 0
        local b = self.bordersize or 0
        local m = self.margin or 0
        local pad_l = self.padding_left or p
        local pad_r = self.padding_right or p
        local pad_t = self.padding_top or p
        local pad_b = self.padding_bottom or p
        return { w = cs.w + (b + m) * 2 + pad_l + pad_r, h = cs.h + (b + m) * 2 + pad_t + pad_b }
    end
    if name == "CenterContainer" then
        return { w = self.dimen and self.dimen.w or 0, h = self.dimen and self.dimen.h or 0 }
    end
    if self.dimen and self.dimen.w then
        return { w = self.dimen.w, h = self.dimen.h or 0 }
    end
    if self.text ~= nil then
        return measure_text(self.text, self.face, self.width or self.max_width)
    end
    return { w = 0, h = 0 }
end
function class:getTextDimension() return { w = 0, h = 0 } end
function class:isFocusable() return false end
function class:getChildren() return {} end
function class:setText(t) self.text = t end
function class:setTitle(t) self.title = t end
function class:setSubTitle(t) self.subtitle = t end
-- Real TitleBar API (iconbutton swap): record the glyph like the device does
function class:setLeftIcon(icon) self.left_icon = icon end
function class:setRightIcon(icon) self.right_icon = icon end
function class:updateItems() return true end
function class:switchItemTable() return true end

function class:init() end
function class:new(o)
    o = setmetatable(o or {}, { __index = self })
    o:init()
    -- Match the device: the real HorizontalGroup only paints for align
    -- top/center/bottom (nil == top) and VerticalGroup for left/center/right
    -- (nil == left); anything else just logs "[!] invalid alignment" and
    -- paints NOTHING — the whole folder tree was invisible on the Kindle
    -- while every harness check stayed green. Fail here instead.
    if o.__name == "HorizontalGroup" and o.align ~= nil
        and o.align ~= "top" and o.align ~= "center" and o.align ~= "bottom" then
        error(string.format(
            "HorizontalGroup align %q is invalid on the device (top/center/bottom) — it would paint nothing",
            tostring(o.align)))
    end
    if o.__name == "VerticalGroup" and o.align ~= nil
        and o.align ~= "left" and o.align ~= "center" and o.align ~= "right" then
        error(string.format(
            "VerticalGroup align %q is invalid on the device (left/center/right)",
            tostring(o.align)))
    end
    return o
end
function class:extend(over)
    over = over or {}
    setmetatable(over, { __index = self })
    return over
end

local ScreenStub = {}
function ScreenStub:getWidth() return SCREEN_W end
function ScreenStub:getHeight() return SCREEN_H end
function ScreenStub:getSize() return { w = SCREEN_W, h = SCREEN_H } end
function ScreenStub:scaleBySize(v) return scal(v) end

local DevInputStub = { group = { Back = "back", Any = "any" } }
local DeviceStub = {
    screen = ScreenStub,
    input = DevInputStub,
    hasKeys = function() return false end,
    isTouchDevice = function() return true end,
    isKindle = function() return true end, -- scan root = /mnt/us (FAKE_FS)
}

local function widget_stub(name, extra)
    local c = class:extend{ __name = name }
    return c
end

local reader_menu_order = { tools = { "read_timer" } }
local filemanager_menu_order = { tools = { "read_timer" } }

local SAFE_FACES = {
    cfont = true, tfont = true, smalltfont = true, x_smalltfont = true,
    ffont = true, smallffont = true, largeffont = true, pgfont = true,
    scfont = true, rifont = true, hpkfont = true, hfont = true,
    infont = true, smallinfont = true, infofont = true, smallinfofont = true,
    smallinfofontbold = true, x_smallinfofont = true, xx_smallinfofont = true,
}

-- The Kindle's KOReader crashes on Font:getFace("small") etc. — those named
-- fonts have NO default size in its sizemap (that was the plugin crash). The
-- stub mirrors that so a regression fails the harness instead of the device.
local FontStub = {
    getFace = function(_, name, size)
        if size then return { f = name, s = size } end
        if SAFE_FACES[name] then return { f = name, s = FACE_SIZES[name] or 22 } end
        error(string.format("Font:getFace(%q) without a size crashed here (exactly what killed the plugin on the Kindle)",
            tostring(name)))
    end,
    getSize = function() return 20 end,
}

-- A tiny deterministic in-memory filesystem for the picker's device scan
-- (the real libkoreader-lfs stub is a bare widget stub; the picker needs
-- dir/attributes to walk for books, and the tests must not depend on the
-- machine's actual disk). Mirrors the user's Kindle layout, including dirs
-- the scan MUST skip (koreader, system, screenshots, .hidden, .sdr,
-- AppleDouble "._" companions).
local FAKE_FS = {
    ["/mnt/us"] = { "Books", "Boldonic Books", "documents", "koreader", "system", "screenshots", ".hidden", "sneaky.azw3", "wallpaper.bmp", "Guide.EPUB" },
    ["/mnt/us/Books"] = { "fakebook.epub", "sub", "fakebook.sdr", "._fakebook.epub" },
    ["/mnt/us/Books/sub"] = { "nested.epub", "rtl.xtc" },
    ["/mnt/us/Books/fakebook.sdr"] = { "meta.epub" },
    ["/mnt/us/Boldonic Books"] = { "bold.epub" },
    ["/mnt/us/documents"] = { "fakebook2.azw" },
    ["/mnt/us/koreader"] = { "junk.epub" },
    ["/mnt/us/system"] = { "junk2.pdf" },
    ["/mnt/us/screenshots"] = { "screen.png" },
    ["/mnt/us/.hidden"] = { "hidden.epub" },
}
local function fake_attributes(path, what)
    if FAKE_FS[path] then
        local t = { mode = "directory" }
        if what then return t[what] end
        return t
    end
    local parent, name = path:match("^(.*)/([^/]+)$")
    if parent and FAKE_FS[parent] then
        for _, e in ipairs(FAKE_FS[parent]) do
            if e == name then
                local t = { mode = "file", size = 256000 }
                if what then return t[what] end
                return t
            end
        end
    end
    return nil
end

local stubs = {
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s) return s end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dgray", COLOR_LIGHT_GRAY = "lgray" },
    ["ui/device"] = DeviceStub,
    ["device"] = DeviceStub,
    ["ui/font"] = FontStub,
    ["ui/geometry"] = { new = function(_, o) return o or {} end },
    ["ui/gesturerange"] = { new = function(o) return o or {} end },
    ["ui/size"] = {
        radius = { window = scal(7) },
        padding = { default = scal(5), large = scal(10) },
        span = { horizontal_default = scal(10) },
        border = { window = scal(1.5), button = scal(1.5) },
        line = { thin = scal(1), thick = scal(2) },
    },
    ["ui/widget/container/widgetcontainer"] = class:extend{},
    ["ui/widget/container/inputcontainer"] = class:extend{},
    ["ui/elements/reader_menu_order"] = reader_menu_order,
    ["ui/elements/filemanager_menu_order"] = filemanager_menu_order,
}

local function make_require()
    local real_require = require
    return function(name)
        if stubs[name] then return stubs[name] end
        if name:match("^ui/widget/") or name:match("^ui/") or name:match("^libs/") then
            return widget_stub(name)
        end
        return real_require(name)
    end
end

-- ── settings + UIManager + global recorder ───────────────────────────────

G_reader_settings = {
    _store = {},
    readSetting = function(self, k) return G_reader_settings._store[k] end,
    saveSetting = function(self, k, v) G_reader_settings._store[k] = v end,
}

UIManager = {
    -- NOTE: this build has NO UIManager:replace (it crashed the plugin on
    -- device, and the harness must not provide one either, or Home's tab
    -- switch and check() would be tested against an API that doesn't exist).
    _shown = {},
    last_dirty = nil,
    last_show_mode = nil,
    last_show_region = nil,
    last_close_mode = nil,
    last_close_region = nil,
    show = function(_, w, mode, region)
        UIManager.last_show_mode = mode
        UIManager.last_show_region = region
        table.insert(UIManager._shown, w)
    end,
    close = function(_, w, mode, region)
        UIManager.last_close_mode = mode
        UIManager.last_close_region = region
    end,
    setDirty = function(_, _, mode, region)
        UIManager.last_dirty = mode
        UIManager.last_dirty_region = region
    end,
    forceRePaint = function() end,
    nextTick = function(_, f) return f() end,
    scheduleIn = function() return { cancel = function() end } end,
    unschedule = function() end,
}
stubs["ui/uimanager"] = UIManager

-- ── fake device ───────────────────────────────────────────────────────────

local FAKE = {
    fail = false,
    fail_put = false,       -- network is up, but the PUT transfer drops (string error)
    chunked = false,        -- /api/files replies with raw chunked-transfer framing
    garbage = false,        -- /api/files replies with a non-JSON body
    mkcol_count = 0,        -- first MKCOL -> 201, rest -> 405 (see fake_request)
    mkcol_urls = {},        -- every MKCOL url answered (asserts the parent walk)
    mkcol_returns = nil,    -- optional { [url] = status } to force per-URL replies
    delete_urls = {},       -- every DELETE url answered (the delete tab's tree)
    delete_returns = nil,   -- optional { [url] = status } to force per-URL replies
    delete_409_once = nil,  -- optional { [url] = true }: first DELETE -> 409 (not empty), then 204
}

-- Real wire capture from the Xteink reader (nc at 192.168.7.45:80): it streams
-- the /api/files listing with Transfer-Encoding: chunked in many tiny writes.
-- The device's socket.http hands this framing to JSON.decode verbatim, which is
-- why the folder list once refused to parse. Regression fixture for dechunk().
local RAW_CHUNKED_FILES = "1\r\n[\r\n"
    .. "3b\r\n{\"name\":\"Books\",\"size\":0,\"isDirectory\":true,\"isEpub\":false}\r\n"
    .. "1\r\n,\r\n"
    .. "4a\r\n{\"name\":\"crash_report.txt\",\"size\":4268,\"isDirectory\":false,\"isEpub\":false}\r\n"
    .. "1\r\n,\r\n"
    .. "3b\r\n{\"name\":\"sleep\",\"size\":0,\"isDirectory\":true,\"isEpub\":false}\r\n"
    .. "1\r\n,\r\n"
    .. "48\r\n{\"name\":\"CrossDropped Files\",\"size\":0,\"isDirectory\":true,\"isEpub\":false}\r\n"
    .. "1\r\n]\r\n"
    .. "0\r\n\r\n"

local function fake_request(args)
    if FAKE.fail then
        -- LuaSocket failure shape: (nil, "<error string>") — the old crash trigger
        return nil, "connection refused"
    end
    local url, method = args.url, args.method
    if method == "PUT" and FAKE.fail_put then
        return nil, "connection refused"
    end
    local url, method = args.url, args.method
    if method == "GET" and url:match("/api/status") then
        return '{"version":"1.6.0rc","ip":"192.168.1.50","mode":"STA","rssi":-45,"freeHeap":123456,"uptime":3600,"device":"X4"}', 200
    end
    if method == "GET" and url:match("/api/files") then
        if FAKE.garbage then
            return "this is not json at all", 200
        end
        if FAKE.chunked then
            return RAW_CHUNKED_FILES, 200
        end
        return '[{"name":"Books","size":0,"isDirectory":true,"isEpub":false},'
            .. '{"name":"MyBook.epub","size":123,"isDirectory":false,"isEpub":true},'
            .. '{"name":"sleep","size":0,"isDirectory":true,"isEpub":false},'
            .. '{"name":"CrossDropped Files","size":0,"isDirectory":true,"isEpub":false}]', 200
    end
    if method == "MKCOL" then
        FAKE.mkcol_urls[#FAKE.mkcol_urls + 1] = url
        if FAKE.mkcol_returns and FAKE.mkcol_returns[url] then
            return "", FAKE.mkcol_returns[url]
        end
        FAKE.mkcol_count = FAKE.mkcol_count + 1
        if FAKE.mkcol_count == 1 then return "", 201 end
        return "", 405
    end
    if method == "DELETE" then
        FAKE.delete_urls[#FAKE.delete_urls + 1] = url
        if FAKE.delete_returns and FAKE.delete_returns[url] then
            return "", FAKE.delete_returns[url]
        end
        if FAKE.delete_409_once and FAKE.delete_409_once[url] then
            FAKE.delete_409_once[url] = nil
            return "", 409
        end
        return "", 204
    end
    if method == "PUT" then
        if args and args.source then
            while args.source() do end
        end
        return "", 201
    end
    return "not found", 404
end

-- Raw-socket transport for the folder listing: the device's socket.http only
-- returns the FIRST LINE of a multi-line body, so listFolders reads a plain
-- tcp socket. The fake hands back TCP_RESP verbatim (full HTTP response), or a
-- connect failure under FAKE.fail — exactly what a real device would send.
local CLEAN_FILES_JSON = '[{"name":"Books","size":0,"isDirectory":true,"isEpub":false},'
    .. '{"name":"MyBook.epub","size":123,"isDirectory":false,"isEpub":true},'
    .. '{"name":"sleep","size":0,"isDirectory":true,"isEpub":false},'
    .. '{"name":"CrossDropped Files","size":0,"isDirectory":true,"isEpub":false}]'
-- A listing inside a folder (Books/), for the nested-browser regression.
local SUBDIR_JSON = '[{"name":"Fiction","size":0,"isDirectory":true,"isEpub":false},'
    .. '{"name":"Non-Fiction","size":0,"isDirectory":true,"isEpub":false}]'
local TCP_RESP = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" .. CLEAN_FILES_JSON
local last_raw_request = "" -- the GET line the raw socket was asked to send
local function raw_ok(payload)
    TCP_RESP = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" .. payload
end
-- Monotonic fake clock for putFile pacing (socket.gettime/socket.sleep). The
-- harness advances it so the live-progress pacing is exercised deterministically.
local fake_clock = 0.0
local sleep_calls = 0
stubs["socket"] = {
    tcp = function()
        return {
            settimeout = function() end,
            connect = function() if FAKE.fail then return nil, "connection refused" end return 1 end,
            send = function(_, data) last_raw_request = tostring(data or "") return 1 end,
            receive = function()
                local r = TCP_RESP
                if r == nil then return nil end
                TCP_RESP = nil
                return r
            end,
            close = function() end,
        }
    end,
    gettime = function() return fake_clock end,
    sleep = function(t)
        fake_clock = fake_clock + t
        sleep_calls = sleep_calls + 1
    end,
}
stubs["socket.http"] = { request = function(args) return fake_request(args) end }

-- Freeze-fix recorder: raw socket.http forces its own 60s connect timeout, so
-- the plugin must run every request through socketutil's bounded timeouts.
-- Record what the plugin asks socketutil for; the tests assert probes use a
-- short 3s and sends use Storefront's file sizes.
local su_calls = {}
local su_resets = 0
stubs["socketutil"] = {
    FILE_BLOCK_TIMEOUT = 15,
    FILE_TOTAL_TIMEOUT = 60,
    set_timeout = function(_, b, t) su_calls[#su_calls + 1] = { b, t } end,
    reset_timeout = function() su_resets = su_resets + 1 end,
}
stubs["json"] = json_mod

-- lfs stub: real file sizes via io + the deterministic FAKE_FS directory
-- walking (the picker's device scan must not depend on the machine's disk)
stubs["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        local f = io.open(path, "rb")
        if not f then return fake_attributes(path, what) end
        if what == "size" then
            local cur = f:seek("set", 0)
            local sz = f:seek("end")
            f:close()
            return sz
        end
        if what == "mode" then
            f:close()
            return "file"
        end
        f:close()
        return fake_attributes(path, what)
    end,
    dir = function(path)
        local entries = FAKE_FS[path]
        if not entries then return nil, path .. ": no such directory" end
        local i = 0
        local function iter()
            i = i + 1
            return entries[i]
        end
        return iter, path
    end,
    currentdir = function() return "/tmp" end,
}

-- documentregistry: any filename the test picks is a supported book
stubs["document/documentregistry"] = {
    hasProvider = function() return true end,
}

-- ── run the tests ─────────────────────────────────────────────────────────

local real_require = require
_G.require = make_require()

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local CROSSDROP = dofile(PLUGIN_ROOT .. "crossdrop.koplugin/main.lua")
check("module loads", type(CROSSDROP) == "table", CROSSDROP)
check("module name is crossdrop", CROSSDROP.name == "crossdrop")

local inst = CROSSDROP:new{ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/tmp/fakebook.epub" } } }

-- a real temp book
local bfh = assert(io.open("/tmp/fakebook.epub", "wb"))
for _ = 1, 16000 do bfh:write(string.rep("x", 16)) end
bfh:close()
local bfh2 = assert(io.open("/tmp/fakebook2.epub", "wb"))
for _ = 1, 16000 do bfh2:write(string.rep("y", 16)) end
bfh2:close()

-- 1. ensureFolder: 201 then 405 both succeed (always targets CrossDropped Files)
local eok, eerr = inst:ensureFolder({ ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" })
check("ensureFolder created (201)", eok == true, eerr)
local eok2 = inst:ensureFolder({ ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" })
check("ensureFolder exists (405)", eok2 == true)

-- 2. putFile streams with progress
local seen = {}
local pok, presult = inst:putFile({ ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" }, "/tmp/fakebook.epub", function(s) seen[#seen + 1] = s end)
check("putFile success", pok == true, presult)
check("putFile progress reported", #seen > 0 and seen[#seen] == 256000, #seen and "#seen=" .. #seen)

-- 3. ONE connection: WiFi only, fixed folder
inst:saveTarget({ ip = "192.168.1.50", port = 80 })
local targets = inst:configuredTargets()
check("configuredTargets: wifi only",
    #targets == 1 and targets[1].kind == "wifi" and targets[1].ip == "192.168.1.50",
    #targets and ("#targets=" .. #targets))
check("wifi uses CrossDropped Files", targets[1].folder == "/CrossDropped Files", targets[1].folder)
check("resolveTarget is the wifi target", inst:resolveTarget() and inst:resolveTarget().kind == "wifi")

-- 4b. probeReachable answers the reachable connection; with no IP set it
-- reports the not-set error instead of falling back to anything
local reached = inst:probeReachable()
check("probeReachable finds wifi", reached and reached.kind == "wifi", reached and reached.kind)
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local reached_be = inst:probeReachable()
check("probeReachable with no IP set reports 'not set'",
    reached_be == nil and inst._probe_errors.wifi and tostring(inst._probe_errors.wifi):match("not set"),
    inst._probe_errors and inst._probe_errors.wifi)

-- 4c. probeTarget parses device info
local pok2, pinfo = inst:probeTarget({ kind = "wifi", ip = "192.168.1.50", port = 80 })
check("probeTarget ok + info", pok2 == true and pinfo and pinfo.device == "X4", pinfo and pinfo.device)

-- 4d. probe with an unset IP is a clean "not set" answer, not a network call
local pok3, _, perr3 = inst:probeTarget({ kind = "wifi", ip = "", port = 80 })
check("probeTarget with empty IP answers 'not set'",
    pok3 == nil and perr3 and tostring(perr3):match("not set"), perr3)

-- 4d. probe failure (LuaSocket string error) does not crash
FAKE.fail = true
local fok, _, ferr = inst:probeTarget({ kind = "wifi", ip = "192.168.1.50", port = 80 })
check("probeTarget failure safe", fok == nil and type(ferr) == "string", ferr)
FAKE.fail = false

-- 5. sendCurrentBook success path (records toast) + history
inst:saveTarget({ ip = "192.168.1.50", port = 80 })
UIManager._shown = {}
inst:sendCurrentBook()
local last_notif = UIManager._shown[#UIManager._shown]
check("send success shows Book sent", last_notif and type(last_notif.text) == "string" and last_notif.text:match("Book sent"), last_notif and last_notif.text)

-- 5b. "Send A File" opens the CROSSDROP PICKER (crossdrop_picker.lua) — a
-- device-wide book scan (the bookshelf.koplugin walk pattern) rendered on
-- the dashboard's proven widgets: its own picked set (toggle), the
-- always-visible "Send to Xteink" action row (sendRowText → confirmAndSend),
-- paging, and exit that always lands back on the CrossDrop dashboard.

UIManager._shown = {}
inst:chooseAndSend()
local picker = UIManager._shown[#UIManager._shown]
check("chooseAndSend opens the picker", type(picker) == "table")
check("picker is modal (paints above Home)", picker ~= nil and picker.modal == true, picker and picker.modal)
check("picker covers the full screen (storefront browser flag)",
    picker ~= nil and picker.covers_fullscreen == true, picker and picker.covers_fullscreen)
check("picker starts with an empty picked set",
    picker and type(picker.picked) == "table" and next(picker.picked) == nil)
check("picker uses a picked set (never FocusManager's selected)",
    picker and picker.selected == nil, picker and picker.selected)
check("send row names the action from the start",
    picker and tostring(picker:sendRowText()):match("Send to Xteink"),
    picker and picker:sendRowText())
picker:toggle("/tmp/fakebook.epub")
check("toggle picks a book", picker.picked["/tmp/fakebook.epub"] == true, picker.picked["/tmp/fakebook.epub"])
check("send row carries the count once books are picked",
    tostring(picker:sendRowText()):match("1 file"), picker:sendRowText())
picker:toggle("/tmp/fakebook2.epub")
picker:toggle("/tmp/fakebook.epub")
check("toggle unpicks a book (no send on tap)",
    picker.picked["/tmp/fakebook.epub"] == nil, picker.picked["/tmp/fakebook.epub"])
check("send row count follows the selection",
    tostring(picker:sendRowText()):match("1 file"), picker:sendRowText())
picker:toggle("/tmp/fakebook.epub") -- both books picked again
check("toggles repaint flashless (ui — never promoted to a full)",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
-- the device scan (bookshelf-style walk) finds every SENDABLE file — the
-- Xteink/CrossPoint list (epub/xtc/xtch/txt/bmp), case-insensitive — in
-- nested and other source folders, and skips app/system/sidecar junk AND
-- everything the reader cannot open (mobi/azw/pdf/…)
local books = picker:scanAllBooks("/mnt/us")
local names = {}
for _, b in ipairs(books) do names[b.name] = true end
local all_names = {}
for n in pairs(names) do all_names[#all_names + 1] = n end
check("device scan finds the sendable files (epub/xtc/bmp, nested)",
    names["fakebook.epub"] and names["nested.epub"] and names["bold.epub"]
        and names["rtl.xtc"] and names["wallpaper.bmp"] and names["Guide.EPUB"],
    table.concat(all_names, ", "))
check("scan skips app/system/hidden/sidecar dirs and AppleDouble files",
    not names["junk.epub"] and not names["junk2.pdf"] and not names["meta.epub"]
        and not names["hidden.epub"] and not names["._fakebook.epub"] and not names["screen.png"],
    names["junk.epub"] and "koreader walked" or "ok")
check("scan never lists files the reader cannot open (azw/azw3)",
    not names["fakebook2.azw"] and not names["sneaky.azw3"],
    names["fakebook2.azw"] and "azw listed" or "ok")
check("picker scanned at open (files cached on the dialog)",
    picker.books ~= nil and #picker.books == 6, picker.books and #picker.books)

-- 5d. 1.3.18 real titles + search: rows show title-like names, not raw
-- filenames, and a case-insensitive keyword search filters the pageable list.

-- Plain .txt joins FAKE_FS: the Xteink OPENS plain text natively, so .txt
-- files ARE sendable now (1.4.0) — while .md stays out (not a CrossPoint
-- type, and on a real device it is almost always a readme/log).
FAKE_FS["/mnt/us"] = { "Books", "Boldonic Books", "documents", "koreader", "system", "screenshots", ".hidden", "sneaky.azw3", "wallpaper.bmp", "Guide.EPUB", "notes.txt" }
FAKE_FS["/mnt/us/Books"] = { "fakebook.epub", "sub", "fakebook.sdr", "._fakebook.epub", "readme.md" }
local rescan = picker:scanAllBooks("/mnt/us")
local pk_names = {}
for _, b in ipairs(rescan) do pk_names[b.name] = true end
check("scan lists the .txt (Xteink-supported) among 7 files", #rescan == 7, #rescan)
check("scan still skips .md (not a CrossPoint type)",
    pk_names["notes.txt"] == true and not pk_names["readme.md"],
    pk_names["notes.txt"] and "notes.txt listed" or "ok")

-- isCrossPointFile: the exact Xteink list, case-insensitive
check("isCrossPointFile accepts the Xteink list (epub/xtc/xtch/txt/bmp)",
    inst:isCrossPointFile("/x/A.EPUB") == true and inst:isCrossPointFile("/x/b.xtc") == true
        and inst:isCrossPointFile("/x/c.XTCH") == true and inst:isCrossPointFile("/x/d.txt") == true
        and inst:isCrossPointFile("/x/e.bmp") == true,
    "epub/xtc/xtch/txt/bmp")
check("isCrossPointFile rejects what KOReader reads but the reader cannot open",
    inst:isCrossPointFile("/x/a.mobi") ~= true and inst:isCrossPointFile("/x/a.azw3") ~= true
        and inst:isCrossPointFile("/x/a.pdf") ~= true and inst:isCrossPointFile("/x/a.fb2") ~= true,
    "mobi/azw3/pdf/fb2")

-- cleanTitle: the side-loader junk on this very device
check("cleanTitle turns underscores into spaces",
    picker:cleanTitle("The_Primal_Hunter_Book_1.azw3") == "The Primal Hunter Book 1",
    picker:cleanTitle("The_Primal_Hunter_Book_1.azw3"))
check("cleanTitle drops Anna's Archive junk",
    not tostring(picker:cleanTitle("Less- a novel -- Andrew Sean Greer -- isbn13 9780316316125 -- d00e197c6b7871a431a4ea9d207a77df -- Anna's Archive_optimized.epub")):match("anna"),
    picker:cleanTitle("Less- a novel -- Andrew Sean Greer -- isbn13 9780316316125 -- d00e197c6b7871a431a4ea9d207a77df -- Anna's Archive_optimized.epub"))
check("cleanTitle keeps interior hyphens", picker:cleanTitle("sci-fi.novel.epub") == "sci-fi novel", picker:cleanTitle("sci-fi.novel.epub"))
check("cleanTitle has a stem fallback", picker:cleanTitle("___-._---.pdf") ~= "",
    tostring(picker:cleanTitle("___-._---.pdf")))

-- sanitizeTitle: NULs/controls out, whitespace collapsed, empties become nil
check("sanitizeTitle strips controls", picker:sanitizeTitle("Real\0Title\n") == "RealTitle",
    tostring(picker:sanitizeTitle("Real\0Title\n")))
check("sanitizeTitle empties to nil", picker:sanitizeTitle("   ") == nil)
check("sanitizeTitle caps runaway lengths", #(picker:sanitizeTitle(string.rep("a", 500)) or "") <= 200)
check("sanitizeTitle converts underscores to spaces (calibre titles)",
    picker:sanitizeTitle("Braiding_Sweetgrass_Ind_Wisdom,_Scientific") == "Braiding Sweetgrass Ind Wisdom, Scientific",
    tostring(picker:sanitizeTitle("Braiding_Sweetgrass_Ind_Wisdom,_Scientific")))
check("sanitizeTitle collapses repeated words (series packaging)",
    picker:sanitizeTitle("Dungeon Crawler Carl - 01 Anthology Anthology")
        == "Dungeon Crawler Carl - 01 Anthology",
    tostring(picker:sanitizeTitle("Dungeon Crawler Carl - 01 Anthology Anthology")))

-- mobiTitle: a hand-built record 0 (PalmDB header + BOOKMOBI + full name at
-- offset 120) — the 0x54/0x58 offsets are relative to RECORD 0, not the file.
local function be32enc(v)
    return string.char(math.floor(v / 16777216) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
end
local mobi_blob =
    string.rep(" ", 32)            -- PalmDB 32-byte name field
    .. string.rep("\0", 44)        -- …to byte 76
    .. "\0\1"                      -- record count = 1
    .. be32enc(82)                 -- record 0 data offset
    .. "BOOKMOBI"                  -- record 0: MOBI header identifier
    .. string.rep("\0", 8)
    .. string.rep("\0", 84 - 16)   -- to 0x54 (full name offset, rec0-relative)
    .. be32enc(120)
    .. be32enc(11)                 -- full name length at 0x58
    .. string.rep("\0", 120 - 92)
    .. "My Test Mob"               -- the full name at record-0 offset 120
local mobi_path = "/tmp/crossdrop_test.mobi"
local mfh = assert(io.open(mobi_path, "wb")); mfh:write(mobi_blob); mfh:close()
check("mobiTitle parses the record-0 full name",
    picker:mobiTitle(mobi_path) == "My Test Mob", tostring(picker:mobiTitle(mobi_path)))

-- fb2Title: plain-XML <book-title>, entities decoded
local fb2_path = "/tmp/crossdrop_test.fb2"
local ffh = assert(io.open(fb2_path, "wb"))
ffh:write('<?xml version="1.0"?><FictionBook><description><title-info><book-title>My Test &amp; Fancy Book</book-title></title-info></description></FictionBook>')
ffh:close()
check("fb2Title parses book-title", picker:fb2Title(fb2_path) == "My Test & Fancy Book",
    tostring(picker:fb2Title(fb2_path)))

-- the durable titles_cache.lua format round-trips
picker.title_cache_file = "/tmp/crossdrop_titles_cache.lua"
picker._cache_loaded = false
picker.title_cache = {}
local cfh = assert(io.open("/tmp/crossdrop_titles_cache.lua", "w"))
cfh:write('return {\n  ["/tmp/aa.epub"] = "Real Title",\n  ["/tmp/bb.mobi"] = "A \\"tricky\\" title",\n}\n')
cfh:close()
picker:loadTitleCache()
check("title cache loads persisted titles", picker.title_cache["/tmp/aa.epub"] == "Real Title",
    tostring(picker.title_cache["/tmp/aa.epub"]))
check("title cache survives %q quoting", picker.title_cache["/tmp/bb.mobi"] == 'A "tricky" title',
    tostring(picker.title_cache["/tmp/bb.mobi"]))
picker.title_cache["/tmp/cc.epub"] = "Newly Discovered"
picker.title_cache_dirty = true
picker:saveTitleCache()
picker.title_cache = {}
picker:loadTitleCache()
check("title cache round-trips through disk",
    picker.title_cache["/tmp/cc.epub"] == "Newly Discovered" and picker.title_cache["/tmp/aa.epub"] == "Real Title")

-- a persisted real title is used by the SCAN for that path (tier 2 beats
-- the cleaned fallback) without waiting for the lazy Document upgrade
picker.title_cache["/mnt/us/Books/fakebook.epub"] = "The Real Fake Book"
local scanned_titles = picker:scanAllBooks("/mnt/us")
local real_title
for _, b in ipairs(scanned_titles) do
    if b.path == "/mnt/us/Books/fakebook.epub" then real_title = b.title end
end
check("scan uses a persisted real title at once", real_title == "The Real Fake Book",
    tostring(real_title))

-- search: case-insensitive substring over the DISPLAYED title and the raw name
picker.query = "fake"
check("search matches the displayed title (fake)", #picker:visibleBooks() == 1,
    tostring(#picker:visibleBooks()))
picker.query = "BOLD"
check("search ignores capitalisation (BOLD)", #picker:visibleBooks() == 1,
    tostring(#picker:visibleBooks()))
picker.query = "book"
check("search is a plain substring, no pattern magic (book)", #picker:visibleBooks() == 1,
    tostring(#picker:visibleBooks()))
picker.query = "azw"
check("no unsupported azw files are listed to search (Xteink filter)",
    #picker:visibleBooks() == 0, tostring(#picker:visibleBooks()))
picker.query = "zzzz"
check("unmatched search yields nothing (no crash)", #picker:visibleBooks() == 0,
    tostring(#picker:visibleBooks()))
picker.query = nil
check("clearing the query shows the full list", #picker:visibleBooks() == 6,
    tostring(#picker:visibleBooks()))

-- The Search popup is a modal InputDialog; Save applies a trimmed,
-- lowercased filter and cancels leave the list alone.
UIManager._shown = {}
picker.query = nil
picker:showSearchDialog()
local sd2 = UIManager._shown[#UIManager._shown]
check("search button opens a popup", type(sd2) == "table" and type(sd2.buttons) == "table")
check("search popup is modal (stacks above the picker)", sd2 ~= nil and sd2.modal == true,
    sd2 and sd2.modal)
sd2.getInputText = function() return "  booK  " end
for _, row in ipairs(sd2.buttons or {}) do
    for _, btn in ipairs(row) do
        if btn.text == "Search" then btn.callback() end
    end
end
check("search Save applies a trimmed, lowercased filter",
    picker.query == "book", tostring(picker.query))
check("search applies and clears repaint flashless (ui)",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
check("search narrows the visible files", #picker:visibleBooks() == 1,
    tostring(#picker:visibleBooks()))
picker:clearSearch()
check("clear search restores the full list",
    picker.query == nil and #picker:visibleBooks() == 6,
    tostring(picker.query) .. "/" .. tostring(#picker:visibleBooks()))
check("clear search repaints flashless too",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
picker:gotoPage(2)
check("page turns repaint flashless (ui — never promoted)",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))

-- 1.3.18 follow-up: uniform font + a framed box on EVERY row (Button no
-- longer shrinks long titles into a smaller font), and the active-filter
-- caption spelled as "Search \"X\" — N results".
-- 1.3.31 change: BOOK rows are borderless (bare text with hairline rules
-- between them — the picker is a list, not a stack of boxes); only the
-- action rows (Send, Search, pages) keep their bordered-box look. Font
-- stays locked at 22 via avoid_text_truncation=false.
local function find_row_buttons(content)
    local rows, caption = {}, nil
    for i = 1, #content do
        local c = content[i]
        if type(c) == "table" then
            if c.text_font_size ~= nil then rows[#rows + 1] = c end
            if type(c.text) == "string" and c.text:find("Search", 1, true) then caption = c.text end
        end
    end
    return rows, caption
end
local function find_widgets(w, pred, out)
    out = out or {}
    if type(w) == "table" then
        if pred(w) then out[#out + 1] = w end
        for i = 1, #w do
            if type(w[i]) == "table" then find_widgets(w[i], pred, out) end
        end
    end
    return out
end
picker.query = "book"
local content = picker:buildContent()
local row_btns, search_caption = find_row_buttons(content)
local uniform, action_framed, book_borderless = #row_btns > 0, false, false
local book_rows = 0
for _, btn in ipairs(row_btns) do
    if btn.text_font_size ~= 22 then uniform = false end
    if btn.bordersize == 0 then book_rows = book_rows + 1 end
end
for _, btn in ipairs(row_btns) do
    if btn.bordersize and btn.bordersize > 0 then action_framed = true end
end
book_borderless = book_rows >= 1
check("every row uses one font size (22)", uniform,
    row_btns[1] and tostring(row_btns[1].text_font_size))
check("rows never shrink long titles (avoid_text_truncation off)",
    row_btns[1] and row_btns[1].avoid_text_truncation == false,
    row_btns[1] and tostring(row_btns[1].avoid_text_truncation))
check("book rows are borderless (no box around each book)", book_borderless,
    tostring(book_rows) .. " borderless book rows")
check("action rows keep their framed boxes (Send, Search, pages)",
    action_framed, tostring(row_btns[1] and row_btns[1].bordersize))
local hairline = find_widgets(content, function(w)
    return w.dimen ~= nil and w.dimen.h == require("ui/size").line.thick
end)
check("thin rule separates rows (hairline separators present)",
    #hairline >= #row_btns, #hairline .. " hairlines / " .. #row_btns .. " rows")
check("search caption reads Search \"X\" — N result(s)",
    search_caption ~= nil and search_caption:find("Search", 1, true) ~= nil
        and search_caption:find("result", 1, true) ~= nil, tostring(search_caption))
picker.query = "bold"
local _, cap_one = find_row_buttons(picker:buildContent())
check("search caption singularises one result",
    cap_one ~= nil and cap_one:find("1 result", 1, true) ~= nil
        and cap_one:find("results", 1, true) == nil, tostring(cap_one))
picker.query = nil

-- the send action: confirm dialog whose OK button is the labeled
-- "Send to Xteink" button, then the whole batch runs IN the dashboard
-- (a fake Home sink records the flow; the real Home is exercised in
-- section 14).
local fake_home
fake_home = {
    calls = {},
    -- the plugin colon-calls its sink: onConnected(self, target), onFileSent(self, path, target), etc.
    onConnecting = function() table.insert(fake_home.calls, "connecting") end,
    onConnected = function(_, t) table.insert(fake_home.calls, "connected:" .. t.kind) end,
    onBeginFile = function() table.insert(fake_home.calls, "begin") end,
    onProgress = function() table.insert(fake_home.calls, "progress") end,
    onFileSent = function() table.insert(fake_home.calls, "sent") end,
    onFileFailed = function() table.insert(fake_home.calls, "failed") end,
    onUnreachable = function() table.insert(fake_home.calls, "unreachable") end,
    onDone = function(_, ok) table.insert(fake_home.calls, "done:" .. tostring(ok)) end,
}
inst.home = fake_home
UIManager._shown = {}
picker:confirmAndSend()
local cdlg = UIManager._shown[#UIManager._shown]
check("send action opens a confirm dialog with a Send to Xteink button",
    cdlg and cdlg.ok_text == "Send to Xteink" and tostring(cdlg.text):match("Send 2 file"),
    cdlg and ((cdlg.ok_text or "") .. " / " .. tostring(cdlg.text or "")))
UIManager._shown = {}
cdlg.ok_callback()
check("confirm keeps the dashboard open (no close on transfer)",
    inst.home == fake_home)
check("flow opens with the Connecting state",
    fake_home.calls and fake_home.calls[1] == "connecting", fake_home.calls and fake_home.calls[1])
check("flow connected through the reachable connection",
    fake_home.calls and fake_home.calls[2] == "connected:wifi",
    fake_home.calls and fake_home.calls[2])
local sent_count = 0
for _, c in ipairs(fake_home.calls) do if c == "sent" then sent_count = sent_count + 1 end end
check("every picked book reported sent", sent_count == 2, sent_count)
check("batch completes as done",
    fake_home.calls and fake_home.calls[#fake_home.calls] == "done:true",
    fake_home.calls and fake_home.calls[#fake_home.calls])
inst.home = nil

-- Send with nothing picked is a gentle hint, never a send
UIManager._shown = {}
picker.picked = {}
picker:confirmAndSend()
local hint0 = UIManager._shown[#UIManager._shown]
check("send action with no selection shows a hint",
    hint0 and type(hint0.text) == "string" and hint0.text:match("Tap books"), hint0 and hint0.text)

-- exiting the picker (its TitleBar ✕, the dashboard's own) ALWAYS lands back
-- on the CrossDrop dashboard: if Home is still open it is repainted; if it
-- was closed meanwhile, it is reopened
UIManager._shown = {}
inst.home = nil
picker:close()
check("picker exit lands back on the CrossDrop dashboard (reopens Home if needed)",
    inst.home ~= nil, inst.home)
inst.home = nil -- restore the pre-section state for the checks below

-- 5c. sending with NO book open no longer crashes (the old on-device crash);
-- it just shows the picker hint.
inst.ui.document = { file = nil }
UIManager._shown = {}
inst:sendCurrentBook()
local no_book = UIManager._shown[#UIManager._shown]
check("no-book send shows hint (no crash)",
    no_book and type(no_book.text) == "string" and no_book.text:match("Send A File"),
    no_book and no_book.text)
inst.ui.document = { file = "/tmp/fakebook.epub" }

-- 6. THE CRASH CASE: connection refused (string where code should be)
FAKE.fail = true
UIManager._shown = {}
inst:sendCurrentBook()   -- must NOT raise; old code raised "attempt to compare number with string"
local fin = UIManager._shown[#UIManager._shown]
check("connection-refused path does not crash", true)
check("connection-refused shows no-reader message",
    fin and type(fin.text) == "string" and fin.text:match("No CrossDrop reader reached"),
    fin and fin.text)
FAKE.fail = false

-- 6b. THE OTHER CRASH CASE: device answers, then the PUT drops mid-transfer
FAKE.fail_put = true
UIManager._shown = {}
inst:sendCurrentBook()   -- must NOT raise on the string error from putFile
local fput = UIManager._shown[#UIManager._shown]
check("transfer-drop path does not crash", true)
check("transfer-drop shows Send failed", fput and type(fput.text) == "string" and fput.text:match("Send failed"), fput and fput.text)
FAKE.fail_put = false

-- 7. statusDialog parses device info (via probeReachable)
UIManager._shown = {}
inst:statusDialog()
local info = UIManager._shown[#UIManager._shown]
check("status dialog shows device", info and type(info.text) == "string" and info.text:match("X4"), info and info.text)

-- 8. editIp opens an input dialog for each connection — and it must be MODAL,
-- otherwise UIManager stacks it below the modal Home dialog and it shows
-- behind the dashboard (the reported "dialog opens behind CrossDrop" bug).
UIManager._shown = {}
inst:editIp("wifi")
local ipw = UIManager._shown[#UIManager._shown]
check("editIp(wifi) opens dialog", type(ipw) == "table")
check("editIp(wifi) dialog is modal (paints above Home)", ipw ~= nil and ipw.modal == true, ipw and ipw.modal)

-- 8b. destination folder is user-facing since 1.3.25: crossdrop_folder is
-- honored; nothing chosen == the CrossDropped Files default.
G_reader_settings:saveSetting("crossdrop_folder", nil)
check("destination defaults to CrossDropped Files",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)
inst:setFolder("My Books")
check("setFolder persists a new name",
    inst:configuredTargets()[1].folder == "/My Books",
    inst:configuredTargets()[1].folder)
check("setFolder stored under crossdrop_folder",
    G_reader_settings:readSetting("crossdrop_folder") == "/My Books",
    G_reader_settings:readSetting("crossdrop_folder"))
inst:setFolder("  Plaid Books  ")
check("setFolder trims whitespace",
    inst:configuredTargets()[1].folder == "/Plaid Books",
    inst:configuredTargets()[1].folder)
inst:setFolder("")
check("setFolder empty clears back to the default",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)
inst:setFolder("CrossDropped Files")
check("setFolder('CrossDropped Files') restores the default",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)
inst:setFolder("Books/Sci-Fi")
check("setFolder accepts a nested folder path (any depth)",
    inst:configuredTargets()[1].folder == "/Books/Sci-Fi",
    inst:configuredTargets()[1].folder)
inst:setFolder("/Books//Sci-Fi/")
check("setFolder normalizes leading/skip/trailing slashes",
    inst:configuredTargets()[1].folder == "/Books/Sci-Fi",
    inst:configuredTargets()[1].folder)
inst:setFolder("Books/../etc")
check("setFolder rejects a '..' segment",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)
inst:setFolder("Books/./etc")
check("setFolder rejects a '.' segment",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)

-- 9. menu registration: CrossDrop opens the dashboard directly (no submenu)
local menu_items = {}
inst:addToMainMenu(menu_items)
check("menu registered as CrossDrop", menu_items.crossdrop ~= nil and menu_items.crossdrop.text == "CrossDrop", menu_items.crossdrop and menu_items.crossdrop.text)
check("menu item opens the dashboard", menu_items.crossdrop and type(menu_items.crossdrop.callback) == "function")

-- 9b. CrossDrop is pinned to the TOP of the Tools list (position 2, below
-- Read Timer) in both the reader and file manager menus — the same trick
-- Storefront uses.
check("crossdrop pinned at top of reader Tools",
    reader_menu_order.tools and reader_menu_order.tools[2] == "crossdrop",
    reader_menu_order.tools and reader_menu_order.tools[2])
check("crossdrop pinned at top of file manager Tools",
    filemanager_menu_order.tools and filemanager_menu_order.tools[2] == "crossdrop",
    filemanager_menu_order.tools and filemanager_menu_order.tools[2])
check("no duplicate crossdrop entries",
    select(2, table.concat({ reader_menu_order.tools[1], reader_menu_order.tools[2] }, ","):gsub("crossdrop", "")) == 1,
    "dup check")

-- 11. Home dashboard (Storefront-style): opens full-screen, renders all tabs
UIManager._shown = {}
inst:openHome()
local home = UIManager._shown[#UIManager._shown]
check("home dialog opens", home ~= nil)
if home then
    check("home is modal + full-screen", home.modal == true and type(home.dimen) == "table")
    local cc = home:buildTabContent("connections", 560)
    local sc_ = home:buildTabContent("send", 560)
    check("home Connections tab renders", type(cc) == "table")
    check("home Send tab renders", type(sc_) == "table")
    check("home Back closes", home:onBack() == true)
end

-- 11a. Layout never spills past the screen edges on the Kindle (the sizing
-- must be device-scaled + width-capped like Storefront, regardless of screen).
check("home frame fits within screen width",
    home and home.frame and home.frame:getSize().w <= SCREEN_W,
    home and home.frame and home.frame:getSize().w or "no frame")
for _, tab in ipairs({ "connections", "send" }) do
    UIManager._shown = {}
    inst:openHome()
    local h = UIManager._shown[#UIManager._shown]
    if h then
        if h.tab ~= tab then
            h.tab = tab
            h:init()
        end
        check("frame fits screen on '" .. tab .. "' tab",
            h.frame and h.frame:getSize().w <= SCREEN_W,
            h.frame and h.frame:getSize().w or 0)
    end
end

-- 11c. Send-tab breathing room (1.3.31): content is pushed DOWN off the tab
-- bar by a sc(20) spacer, and the Send / "Currently open" / Destination
-- folder sections of the idle view are separated by sc(18) spacers instead
-- of being cramped together.
UIManager._shown = {}
inst:openHome()
local h = UIManager._shown[#UIManager._shown]
if h then
    if h.tab ~= "send" then h.tab = "send"; h:init() end
    local frame_vg = h.frame and h.frame[1]
    local below_tab = frame_vg and frame_vg[6] and frame_vg[6].width
    check("content sits below the tab bar (sc(20) spacer)",
        below_tab == scal(20), tostring(below_tab))
    local idle_vg = h:buildTabContent("send", h.row_w or 560)
    local biggest_span = 0
    for i = 1, #idle_vg do
        local c = idle_vg[i]
        if type(c) == "table" and (c.__name == "VerticalSpan" or type(c.width) == "number")
                and type(c.width) == "number" then
            if c.width > biggest_span then biggest_span = c.width end
        end
    end
    check("idle send sections separated by a sc(18) spacer",
        biggest_span >= scal(18), "largest span " .. tostring(biggest_span))
end

-- 11b. Home check() probes and remembers reachability (state survives swap)
inst:openHome()
home = UIManager._shown[#UIManager._shown]
inst._reach = {}
home:check("wifi")
check("home check() marks wifi reachable", inst._reach.wifi == "ok", inst._reach.wifi)
FAKE.fail = true
home:check("wifi")
check("home check() marks wifi down (no crash)", inst._reach.wifi == "down", inst._reach.wifi)
FAKE.fail = false

-- Walk a rendered widget tree collecting every text string (headers, rows,
-- buttons). Declared before the first section that needs it.
local function flatten_texts(w, out)
    out = out or {}
    if type(w) == "table" then
        if type(w.text) == "string" then out[#out + 1] = w.text end
        for i = 1, #w do
            if type(w[i]) == "table" then flatten_texts(w[i], out) end
        end
    end
    return out
end

-- 11c. Tab switching and check() must NOT use UIManager:replace (that exact
-- call crashed KOReader on the Kindle — the method does not exist). They
-- re-init the same widget in place and repaint.
if home then
    home.tab = "send"
    home:init()
    home:showTab("connections")
    check("showTab switches tab (no replace)", home.tab == "connections")
    home:showTab("connections")
    check("showTab no-op on same tab", home.tab == "connections")
    check("tab switch re-inits the widget", home.frame ~= nil and home[1] ~= nil)
    -- The version line sits ABOVE the setup guide (at the guide's tail it ran
    -- off the bottom of the panel on the device).
    local conn_flat = table.concat(flatten_texts(home.frame))
    local v_pos = conn_flat:find("CrossDrop " .. tostring(inst.VERSION or ""), 1, true)
    local g_pos = conn_flat:find("To receive books", 1, true)
    check("connections shows the version above the setup guide",
        v_pos ~= nil and g_pos ~= nil and v_pos < g_pos,
        tostring(v_pos) .. "/" .. tostring(g_pos))
end

-- 12. THE SEND DIALOG: a plain "… please wait" view (NO progress bar — on this
-- build socket.http drains the file to the TCP buffers in milliseconds, so
-- the bar sat at 0% then jumped to done). It must build without crashing and
-- its update() must be inert.
local ProgressMod = require("crossdrop_progress")
local dlg = ProgressMod.new("mybook.epub", { ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" })
check("waiting dialog builds (no crash)", type(dlg) == "table", dlg)
if dlg then
    local dlg_txt = table.concat(flatten_texts(dlg), "\n")
    check("waiting dialog says please wait and carries no bar",
        dlg_txt:find("please wait", 1, true) ~= nil
            and dlg.bar_fill == nil and dlg.pct_text == nil and dlg.bar_w == nil,
        dlg_txt)
    pcall(dlg.update, dlg, 100, 131072, 131072, 1.0)
    check("waiting dialog update is inert", dlg.bar_fill == nil and dlg.pct_text == nil)
end

-- 12b. Saving an IP must repaint the OPEN dashboard (the reported staleness
-- when the Connections tab stayed open). editIp takes an on_saved callback the
-- Home refresh() runs after the modal dialog closes.
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:showTab("connections")
inst._reach = { wifi = "ok" }
UIManager._shown = {}
inst:editIp("wifi", function() home:refresh() end)
local ipd = UIManager._shown[#UIManager._shown]
ipd.getInputText = function() return "10.1.2.3" end
ipd.buttons[1][1].callback()
check("IP save stores the new wifi IP",
    G_reader_settings:readSetting("crossdrop_wifi_ip") == "10.1.2.3",
    G_reader_settings:readSetting("crossdrop_wifi_ip"))
check("IP save repaints the open dashboard", home.frame ~= nil and home[1] ~= nil, "frame rebuilt")
check("IP save clears remembered reach (stale probe)",
    next(inst._reach or {}) == nil, inst._reach and next(inst._reach))

-- 12c. the picker has a visible way back: the dashboard's own TitleBar ✕
-- pattern (close_callback → PickerDialog:close) — closing the picker always
-- lands on the CrossDrop dashboard.
UIManager._shown = {}
inst:chooseAndSend()
local picker2 = UIManager._shown[#UIManager._shown]
local closed = false
local save_close = UIManager.close
UIManager.close = function(_, w) if w == picker2 then closed = true end end
inst.home = nil
picker2:close()
UIManager.close = save_close
check("picker close exits to the dashboard (Home reopened)",
    closed and inst.home ~= nil, tostring(closed) .. " / " .. tostring(inst.home ~= nil))

-- 13. THE FREEZE FIX: "Check device" / probes used raw socket.http, which
-- forces its OWN 60s connect timeout regardless of any custom create() — an
-- unreachable IP blocked the UI for a minute+ and the Kindle required a hard
-- reset. All requests now go through KOReader's socketutil bounded timeouts.
su_calls = {}
inst:probeTarget({ kind = "wifi", ip = "192.168.1.50", port = 80 })
check("probe binds its socket to 3s (no 60s http freeze)",
    su_calls[1] and su_calls[1][1] == 3, su_calls[1] and su_calls[1][1])
su_calls = {}
inst:putFile({ ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" }, "/tmp/fakebook.epub", function() end)
check("sends use Storefront file-size timeouts (15s block)",
    su_calls[1] and su_calls[1][1] == 15, su_calls[1] and su_calls[1][1])
su_calls = {}
raw_ok(CLEAN_FILES_JSON)
inst:listFolders({ ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" })
check("folder listing uses a 10s budget (still no 60s freeze)",
    su_calls[1] and su_calls[1][1] == 10, su_calls[1] and su_calls[1][1])
check("every request restores the global timeout",
    su_resets >= 2, su_resets)

-- 13b. "Check device" paints a "Checking…" notice BEFORE the blocking probe
-- and the result after — an unreachable IP never reads as a frozen screen.
UIManager._shown = {}
inst:statusDialog()
local sd = UIManager._shown
check("statusDialog shows Checking… before the result",
    sd[1] and sd[1].text and sd[1].text:match("Checking"), sd[1] and sd[1].text)
check("statusDialog still reports the device",
    sd[#sd] and sd[#sd].text and sd[#sd].text:match("X4"), sd[#sd] and sd[#sd].text)

-- 13c. THE "module not found" CRASH (recurring on the Kindle): PluginLoader
-- prepends the plugin folder to package.path ONLY while main.lua loads, then
-- RESTORES package.path (frontend/pluginloader.lua:242/269). A lazy bare
-- require() from a button/nextTick callback therefore can't see the sibling
-- files even though they exist next to main.lua. Fix: eager requires at load
-- populate package.loaded, so later accessor calls resolve from the cache.
check("sibling modules eager-cached at load (toast)",
    type(package.loaded["crossdrop_toast"]) == "table", package.loaded["crossdrop_toast"])
check("sibling modules eager-cached at load (progress)",
    type(package.loaded["crossdrop_progress"]) == "table")
check("sibling modules eager-cached at load (home)",
    type(package.loaded["crossdrop_home"]) == "table")
check("sibling modules eager-cached at load (picker)",
    type(package.loaded["crossdrop_picker"]) == "table")
local saved_path = package.path
package.path = string.gsub(package.path, PLUGIN_ROOT:gsub("%.", "%%.") .. "crossdrop%.koplugin/?.lua;", "")
check("plugin folder off package.path (PluginLoader restore simulated)",
    not package.path:match("crossdrop%.koplugin/?.lua"), package.path)
UIManager._shown = {}
inst:openHome()
check("openHome resolves siblings after restore (no module-not-found crash)",
    UIManager._shown[#UIManager._shown] ~= nil)
package.path = saved_path

-- 14. THE IN-DASHBOARD TRANSFER: sendBooks sinks into the OPEN Home dialog,
-- which repaints its OWN Send tab in place (connecting → waiting → done) —
-- nothing closes between picking, connecting, transferring, and sending more.
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
FAKE.fail, FAKE.fail_put = false, false
local ok_batch = inst:sendBooks({ "/tmp/fakebook.epub", "/tmp/fakebook2.epub" }, home)
check("in-dashboard batch sends every book", ok_batch == true)
check("home ends in the done state", home.send_state == "done", home.send_state)
check("state change repaints with a flushing FULL refresh (e-ink)",
    UIManager.last_dirty == "full", tostring(UIManager.last_dirty))
-- 1.3.32: fewer flashes. "Connecting…" and MID-batch file starts repaint with
-- a flash-free partial (the next full transition always catches up), so only
-- the first file start and the final done/failed boundary flash.
UIManager.last_dirty = nil
home:onConnecting()
check("connecting hint repaints without a flash (partial)",
    UIManager.last_dirty == "partial", tostring(UIManager.last_dirty))
UIManager.last_dirty = nil
home.onBeginFile(home, "/tmp/fakebook.epub", { ip = "192.168.1.50", port = 80 }, 2, 3)
check("mid-batch file start repaints without a flash (partial)",
    UIManager.last_dirty == "partial", tostring(UIManager.last_dirty))
UIManager.last_dirty = nil
home.onBeginFile(home, "/tmp/fakebook.epub", { ip = "192.168.1.50", port = 80 }, 1, 3)
check("first file start keeps a flushing full refresh",
    UIManager.last_dirty == "full", tostring(UIManager.last_dirty))
UIManager.last_dirty = nil
home:onDone(true)
check("done still flashes full (e-ink)",
    UIManager.last_dirty == "full", tostring(UIManager.last_dirty))
check("home stays open the whole time", inst.home == home)
check("home rendered the sent-books list", #home.send_file_list == 2, #home.send_file_list)
check("reach dot recorded the connection", inst._reach and inst._reach.wifi == "ok", inst._reach and inst._reach.wifi)
check("done tab offers Send more (loop back into the picker)",
    home.frame ~= nil and type(home.sendMore) == "function")
home:onCloseWidget()
check("closing home clears plugin.home (sendBooks falls back)",
    inst.home == nil)

-- transfer-drop: the send fails INSIDE the dashboard, list it and stay open
FAKE.fail_put = true
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
local ok_bad = inst:sendBooks({ "/tmp/fakebook.epub" }, home)
check("put-drop batch reports failure", ok_bad == false)
check("failure repaints full too (e-ink)",
    UIManager.last_dirty == "full", tostring(UIManager.last_dirty))
check("home ends in the failed state", home.send_state == "failed", home.send_state)
check("failed state carries the reason",
    home.fail_reason ~= nil and tostring(home.fail_reason) ~= "", tostring(home.fail_reason))
check("dashboard stays open after a failure", inst.home == home)
FAKE.fail_put = false

-- no connection at all: the failure summary lives on the Send tab too
FAKE.fail = true
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
local ok_none = inst:sendBooks({ "/tmp/fakebook.epub" }, home)
check("no-reader batch reports failure", ok_none == false)
check("home shows no-reader failure inline",
    home.send_state == "failed" and tostring(home.fail_reason):match("No CrossDrop reader reached"),
    home.send_state and home.fail_reason)
check("no-reader message guides to the WiFi checks",
    tostring(home.fail_reason):match("SAME Wi%-Fi") and tostring(home.fail_reason):match("Receive Books"),
    home.fail_reason)
check("no-reader message shows the probe's own error",
    tostring(home.fail_reason):match("connection refused"), home.fail_reason)
check("reach marks the connection down",
    inst._reach and inst._reach.wifi == "down",
    inst._reach and (inst._reach.wifi or "?"))
FAKE.fail = false

-- renderers for every send state build without crashing and stay in-screen
home.send_state = "sending"
home.send_index, home.send_total = 1, 1
home.send_filename = "A.epub"
home.send_target = { ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" }
home:init()
check("sending state renders (no crash)", home.frame ~= nil and home.frame:getSize().w <= SCREEN_W)
local sending_txt = table.concat(flatten_texts(home:buildTabContent("send", home.row_w)), "\n")
check("sending view says please wait and has no bar",
    sending_txt:find("please wait", 1, true) ~= nil
        and not sending_txt:find("0%", 1, true),
    sending_txt)
home.send_state = "connecting"
home:init()
check("connecting state renders", home.frame ~= nil and home.frame:getSize().w <= SCREEN_W)
home.send_state = "done"
home.send_file_list = { "A.epub", "B.epub" }
home:init()
check("done state renders (count + list)", home.frame ~= nil and home.frame:getSize().w <= SCREEN_W)
home.send_state = "failed"
home.fail_reason = "boom"
home:init()
check("failed state renders", home.frame ~= nil and home.frame:getSize().w <= SCREEN_W)

-- 14b. APP CLEANUP: the Send tab is minimal — one pick button, "Currently
-- open" only when a book is actually open, a Destination folder row (the
-- reader-folder chooser), and the title bar carries just the app title (no
-- "folder → WiFi" subtitle).
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:backToIdle() -- force send_state == "idle"
local idle_joined = table.concat(flatten_texts(home:buildTabContent("send", home.row_w)), "\n")
check("pick button reads Click Here To Select File(s)",
    idle_joined:find("Click Here To Select File(s)", 1, true) ~= nil, idle_joined)
check("Send tab header above the picker reads Send one or more files",
    idle_joined:find("Send one or more files", 1, true) ~= nil, idle_joined)
check("Send tab shows the destination folder row (default CrossDropped Files)",
    idle_joined:find("Destination folder", 1, true) ~= nil
        and idle_joined:find("CrossDropped Files", 1, true) ~= nil,
    idle_joined)
check("Send tab carries no Check device section",
    not idle_joined:find("Check device", 1, true), idle_joined)
check("Send tab carries no WiFi hint text",
    not idle_joined:find("Send uses the WiFi", 1, true), idle_joined)
check("Currently open shown when a book is open",
    idle_joined:find("Currently open", 1, true) ~= nil, idle_joined)
-- The Currently-open row only offers files the reader can OPEN: a pdf (or
-- any non-CrossPoint type) must not be sendable from here.
inst.ui.document = { file = "/tmp/fakebook.pdf" }
local pdf_joined = table.concat(flatten_texts(home:buildTabContent("send", home.row_w)), "\n")
check("Currently open hidden when the open file is not Xteink-openable (pdf)",
    not pdf_joined:find("Currently open", 1, true), pdf_joined)
inst.ui.document = { file = "/tmp/fakebook.txt" }
local txt_joined = table.concat(flatten_texts(home:buildTabContent("send", home.row_w)), "\n")
check("Currently open shown for Xteink-openable types (txt)",
    txt_joined:find("Currently open", 1, true) ~= nil, txt_joined)
inst.ui.document = nil
local no_book_joined = table.concat(flatten_texts(home:buildTabContent("send", home.row_w)), "\n")
check("Currently open hidden when no book is open",
    not no_book_joined:find("Currently open", 1, true), no_book_joined)
inst.ui.document = { file = "/tmp/fakebook.epub" }
local h_frame = home.frame
check("dashboard title bar carries no subtitle (just CrossDrop)",
    h_frame and h_frame[1] and h_frame[1][1] and h_frame[1][1].subtitle == nil,
    tostring(h_frame and h_frame[1] and h_frame[1][1] and h_frame[1][1].subtitle))
check("dashboard header renders the plugin logo (icon.png beside the plugin)",
    home.logo_shown == true, tostring(home.logo_shown))
local saved_path = inst.path
inst.path = "/tmp/no-such-plugin-dir"
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
check("header collapses to a spacer when the logo file is missing",
    home.logo_shown == false, tostring(home.logo_shown))
inst.path = saved_path
local conn_joined = table.concat(flatten_texts(home:buildTabContent("connections", home.row_w)), "\n")
check("connections tab shows the Xteink setup instructions",
    conn_joined:find("Join WiFi Network", 1, true) ~= nil
        and conn_joined:find("same Wi-Fi", 1, true) ~= nil
        and conn_joined:find("Reachable", 1, true) ~= nil,
    conn_joined)

-- 14c. FOLDER LISTING: GET /api/files → top-level folders only, sorted; raw
-- chunked framing is dechunked; a dead reader, a garbage body or an empty IP
-- fails cleanly instead of raising.
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.1.2.3")
raw_ok(CLEAN_FILES_JSON)
local lf_ok, lf = inst:listFolders(inst:resolveTarget())
local lf_set = {}
for _, n in ipairs(lf or {}) do lf_set[n] = true end
check("listFolders returns only directories (sorted)",
    lf_ok and lf[1] == "Books" and lf[2] == "CrossDropped Files" and lf[3] == "sleep" and #lf == 3,
    lf_ok and table.concat(lf, ","))
check("listFolders skips file entries",
    lf_ok and lf_set["MyBook.epub"] == nil, "file entry leaked")
raw_ok(RAW_CHUNKED_FILES)
local lfc_ok, lfc = inst:listFolders(inst:resolveTarget())
local lfc_set = {}
for _, n in ipairs(lfc or {}) do lfc_set[n] = true end
check("listFolders decodes a chunked transfer-encoding body",
    lfc_ok and #lfc == 3 and lfc_set["Books"]
        and lfc_set["sleep"] and lfc_set["CrossDropped Files"],
    lfc_ok and table.concat(lfc, ","))
raw_ok("this is not json at all")
local lfg_ok, lfg_err = inst:listFolders(inst:resolveTarget())
check("listFolders fails cleanly on a non-JSON body",
    lfg_ok == nil and tostring(lfg_err) ~= "", tostring(lfg_err))
FAKE.fail = true
raw_ok(CLEAN_FILES_JSON)
local lf2_ok, lf2_err = inst:listFolders(inst:resolveTarget())
check("listFolders fails cleanly when the reader is down",
    lf2_ok == nil and tostring(lf2_err) ~= "", tostring(lf2_err))
FAKE.fail = false
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local lf3_ok, lf3_err = inst:listFolders(inst:resolveTarget())
check("listFolders guards the empty IP",
    lf3_ok == nil and tostring(lf3_err):find("WiFi IP not set", 1, true) ~= nil, tostring(lf3_err))
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.1.2.3")

-- Walk a rendered widget tree collecting the Buttons / a named widget class
-- (file scope: several sections use these).
local function collect_buttons(w, acc)
    acc = acc or {}
    if type(w) == "table" then
        if w.__name == "ui/widget/button" then acc[#acc + 1] = w end
        for i = 1, #w do
            if type(w[i]) == "table" then collect_buttons(w[i], acc) end
        end
    end
    return acc
end
local function collect_named(w, want, acc)
    acc = acc or {}
    if type(w) == "table" then
        if w.__name == want then acc[#acc + 1] = w end
        for i = 1, #w do
            if type(w[i]) == "table" then collect_named(w[i], want, acc) end
        end
    end
    return acc
end

-- (do..end: sections 14d-14h keep their many locals out of the main chunk's
-- 200-local limit; the helpers they share live at file scope.)
do

-- 14d. DESTINATION FOLDER TREE: reached from the Send tab, renders the
-- reader's folders as a tree. The reader being unreachable shows ONLY the
-- "Device not found…" message (no retry / typed-path fallback); an unset IP
-- just shows the hint.
inst:setFolder("CrossDropped Files")
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
local dlg = UIManager._shown[#UIManager._shown]
check("chooseDestination opens the folder tree",
    dlg ~= nil and type(dlg) == "table", dlg and tostring(dlg.__name))
local root_names, root_list = {}, {}
for _, node in ipairs(dlg and dlg.nodes or {}) do
    if not root_names[node.name] then
        root_names[node.name] = true
        root_list[#root_list + 1] = node.name
    end
end
check("folder tree lists the reader folders at the root",
    root_names["Books"] and root_names["CrossDropped Files"] and root_names["sleep"]
        and not root_names["MyBook.epub"],
    table.concat(root_list, ","))
check("folder tree renders a full-screen card",
    dlg and dlg.frame ~= nil and dlg.frame:getSize().w <= SCREEN_W,
    dlg and dlg.frame and dlg.frame:getSize().w)
dlg:pick("Books")
check("picking a folder saves it",
    inst:configuredTargets()[1].folder == "/Books",
    inst:configuredTargets()[1].folder)
check("picking a folder refreshes the dashboard in place",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
FAKE.fail = true
inst:setFolder("CrossDropped Files")
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
dlg = UIManager._shown[#UIManager._shown]
check("unreachable reader opens the tree with no folders",
    dlg ~= nil and dlg.nodes == nil and dlg.list_err == true)
local dlg_flat = table.concat(flatten_texts(dlg.frame), "\n")
check("unreachable reader shows ONLY the device-not-found message",
    dlg_flat:find("Device not found", 1, true) ~= nil
        and dlg_flat:find("check Xteink IP", 1, true) ~= nil
        and dlg_flat:find("Folders on the reader", 1, true) == nil
        and dlg_flat:find("Retry", 1, true) == nil
        and dlg_flat:find("Type a folder path", 1, true) == nil,
    dlg_flat)
FAKE.fail = false
inst:setFolder("CrossDropped Files")
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
local dlg_msg = UIManager._shown[#UIManager._shown]
check("unset IP shows the Set WiFi IP hint instead of the dialog",
    dlg_msg ~= nil and type(dlg_msg.text) == "string"
        and dlg_msg.text:find("WiFi IP", 1, true) ~= nil,
    dlg_msg and dlg_msg.text)
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.1.2.3")

-- 14e. NESTED DESTINATIONS (network): listFolders answers ?path= for what
-- sits inside a folder (URL-decoded by the reader), and a deep destination
-- is MKCOL-created parent by parent so the reader's 409 (missing parent)
-- can never abort a deep create.
local tgf = { ip = "192.168.1.50", port = 80 }
raw_ok(SUBDIR_JSON)
local ln_ok, ln_folders, ln_err = inst:listFolders(tgf, "Books")
check("listFolders lists the folders inside a path",
    ln_ok == true and ln_folders[1] == "Fiction" and ln_folders[2] == "Non-Fiction",
    ln_folders and table.concat(ln_folders, ",") or tostring(ln_err))
check("listFolders asks ?path= for the subfolder",
    last_raw_request:find("GET /api/files?path=Books ", 1, true) ~= nil, last_raw_request)
raw_ok(SUBDIR_JSON)
local ln2, ln2f = inst:listFolders(tgf, "/Books")
check("listFolders tolerates a leading slash in the path",
    ln2 == true and ln2f and ln2f[1] == "Fiction", ln2f and table.concat(ln2f, ","))
raw_ok(SUBDIR_JSON)
local ln3 = inst:listFolders(tgf, "CrossDropped Files")
check("listFolders URL-encodes spaces in the path",
    ln3 ~= nil and last_raw_request:find("?path=CrossDropped%20Files", 1, true) ~= nil,
    last_raw_request)
local deep_target = { ip = "192.168.1.50", port = 80, folder = "/Books/Sci-Fi" }
FAKE.mkcol_returns = { ["http://192.168.1.50:80/Books"] = 405, ["http://192.168.1.50:80/Books/Sci-Fi"] = 201 }
FAKE.mkcol_urls = {}
local nf_ok, nf_err = inst:ensureFolder(deep_target)
check("ensureFolder creates a nested folder",
    nf_ok == true, nf_err)
check("ensureFolder MKCOLs every parent prefix in order",
    FAKE.mkcol_urls[1] == "http://192.168.1.50:80/Books"
        and FAKE.mkcol_urls[2] == "http://192.168.1.50:80/Books/Sci-Fi",
    table.concat(FAKE.mkcol_urls, " | "))
FAKE.mkcol_returns = { ["http://192.168.1.50:80/Books"] = 409 }
FAKE.mkcol_urls = {}
local nf_bad, nf_berr = inst:ensureFolder(deep_target)
check("ensureFolder stops on a missing parent (reader 409)",
    nf_bad == nil and tostring(nf_berr):find("could not create folder", 1, true) ~= nil, nf_berr)
FAKE.mkcol_returns = nil

-- 14f. FOLDER TREE NAVIGATION: an ▸ tap fetches and opens a folder, showing
-- subfolders indented under it; an open folder with nothing inside says only
-- "No subfolders found in /X"; tapping a folder NAME opens Select / Create
-- Subfolder… / Cancel; creating a subfolder adds it to the tree and picks it.
inst:setFolder("CrossDropped Files")
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
dlg = UIManager._shown[#UIManager._shown]
local flat_root = table.concat(flatten_texts(dlg.frame), "\n")
check("root tree is boxless (no create/typed clutter)",
    flat_root:find("Folders on the reader", 1, true) ~= nil
        and flat_root:find("back to the default", 1, true) ~= nil
        and flat_root:find("Device not found", 1, true) == nil
        and flat_root:find("Type a folder path", 1, true) == nil,
    flat_root)
raw_ok(SUBDIR_JSON)
local books_node = dlg:findNode("Books")
dlg:expandNode(books_node)
check("expanding a folder fetches and lists its subfolders",
    dlg:findNode("Books/Fiction") ~= nil and dlg:findNode("Books/Non-Fiction") ~= nil,
    tostring(dlg:findNode("Books/Fiction") and dlg:findNode("Books/Fiction").path))
local flat_open = table.concat(flatten_texts(dlg.frame), "\n")
check("open folder shows its subfolders with no empty note",
    flat_open:find("Fiction", 1, true) ~= nil
        and flat_open:find("No subfolders found", 1, true) == nil,
    flat_open)
check("expanding repaints flashless (ui — never promoted)",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
dlg:toggleNode(books_node)
local flat_collapsed = table.concat(flatten_texts(dlg.frame), "\n")
check("collapsing hides the subfolders again",
    dlg:findNode("Books/Fiction") ~= nil -- structure kept, just not rendered
        and flat_collapsed:find("Fiction", 1, true) == nil,
    flat_collapsed)
raw_ok("[]")
local sleep_node = dlg:findNode("sleep")
dlg:expandNode(sleep_node)
local flat_empty = table.concat(flatten_texts(dlg.frame), "\n")
check("an empty folder says only 'No subfolders found in /X'",
    dlg:findNode("sleep") ~= nil
        and dlg:findNode("sleep").children ~= nil
        and #dlg:findNode("sleep").children == 0
        and flat_empty:find("No subfolders found in /sleep", 1, true) ~= nil
        and flat_empty:find("Device not found", 1, true) == nil,
    flat_empty)
dlg:showFolderMenu(dlg:findNode("Books"))
local menu = UIManager._shown[#UIManager._shown]
check("tapping a folder name opens the action menu",
    type(menu) == "table" and menu.modal == true, menu and tostring(menu.modal))
local flat_menu = table.concat(flatten_texts(menu.frame), "\n")
check("the action menu offers Select / Create Subfolder / Cancel",
    flat_menu:find("Select", 1, true) ~= nil
        and flat_menu:find("Create Subfolder", 1, true) ~= nil
        and flat_menu:find("Cancel", 1, true) ~= nil,
    flat_menu)
menu:onSelect()
check("Select makes the folder the destination",
    inst:configuredTargets()[1].folder == "/Books",
    inst:configuredTargets()[1].folder)
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
dlg = UIManager._shown[#UIManager._shown]
dlg:showFolderMenu(dlg:findNode("Books"))
menu = UIManager._shown[#UIManager._shown]
menu:onCreate()
local sub_dlg = UIManager._shown[#UIManager._shown]
check("Create Subfolder opens a modal name dialog",
    type(sub_dlg) == "table" and sub_dlg.modal == true,
    sub_dlg and tostring(sub_dlg.__name))
sub_dlg.getInputText = function() return "Sci-Fi" end
for _, row in ipairs(sub_dlg.buttons or {}) do
    for _, btn in ipairs(row) do
        if btn.text == "Save" then btn.callback() end
    end
end
check("creating a subfolder picks <folder>/<name> as the destination",
    inst:configuredTargets()[1].folder == "/Books/Sci-Fi",
    inst:configuredTargets()[1].folder)
local created = dlg:findNode("Books/Sci-Fi")
check("creating a subfolder adds it to the tree under its parent",
    created ~= nil and created.pending == true,
    created and created.path)
dlg:expandNode(created) -- pending child: expands locally, no network call
local flat_created = table.concat(flatten_texts(dlg.frame), "\n")
check("a just-created subfolder expands locally (no subfolders yet)",
    flat_created:find("No subfolders found in /Books/Sci-Fi", 1, true) ~= nil,
    flat_created)
dlg:pick("CrossDropped Files")
check("leaving the tree restores the default",
    inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)

-- 14g. TREE WIRING: the rendered ▸ control and the folder NAME must be
-- wired to the right actions — ▸ expands/collapses INLINE (fetches the
-- children, renders them indented, does NOT pick), the NAME opens the tiny
-- Select / Create Subfolder / Cancel popup (small like the send-confirmation
-- ConfirmBox, never a full page). This is exactly the wiring that once
-- regress broke both taps to "just pick the folder" and the tree never
-- opened. (collect_buttons lives at file scope.)
inst:setFolder("CrossDropped Files")
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:chooseDestination()
dlg = UIManager._shown[#UIManager._shown]
local row_btns = collect_buttons(dlg.frame)
local books_arrow, books_name
for _, b in ipairs(row_btns) do
    if books_arrow == nil and b.text == "\226\150\184" then books_arrow = b end -- first ▸ is Books
    if b.text == "Books" then books_name = b end
end
check("each tree row exposes a ▸ control and a folder-name button",
    books_arrow ~= nil and books_name ~= nil,
    tostring(books_arrow ~= nil) .. "/" .. tostring(books_name ~= nil))
raw_ok(SUBDIR_JSON)
books_arrow.callback()
check("tapping ▸ expands the folder inline (no pick, no menu)",
    dlg:findNode("Books/Fiction") ~= nil
        and inst:configuredTargets()[1].folder ~= "/Books",
    inst:configuredTargets()[1].folder)
local flat_after_arrow = table.concat(flatten_texts(dlg.frame), "\n")
check("▸ tap renders the subfolders indented under the mother folder",
    flat_after_arrow:find("Fiction", 1, true) ~= nil
        and flat_after_arrow:find("CrossDropped Files", 1, true) ~= nil,
    flat_after_arrow)
UIManager._shown = {}
books_name.callback()
local popup = UIManager._shown[#UIManager._shown]
check("tapping the folder NAME opens the action popup",
    type(popup) == "table" and popup.modal == true
        and popup.node ~= nil and popup.node.path == "Books",
    popup and popup.node and popup.node.path)
local popup_flat = table.concat(flatten_texts(popup.frame), "\n")
check("the popup offers Select / Create Subfolder / Cancel",
    popup_flat:find("Select", 1, true) ~= nil
        and popup_flat:find("Create Subfolder", 1, true) ~= nil
        and popup_flat:find("Cancel", 1, true) ~= nil,
    popup_flat)
check("the popup is a tiny centered card, not a full page",
    popup.frame ~= nil and popup.frame:getSize().w < SCREEN_W,
    popup.frame and popup.frame:getSize().w)
check("the popup refreshes ONLY its box region (no whole-screen sweep)",
    UIManager.last_show_mode == "ui"
        and UIManager.last_show_region ~= nil
        and UIManager.last_show_region.w < SCREEN_W
        and UIManager.last_show_region.h < SCREEN_H,
    tostring(UIManager.last_show_mode) .. " "
        .. (UIManager.last_show_region and (UIManager.last_show_region.w .. "x" .. UIManager.last_show_region.h) or "no-region"))
popup:onCancel()
check("closing the popup repaints only the box-sized hole too",
    UIManager.last_close_mode == "ui" and UIManager.last_close_region ~= nil,
    tostring(UIManager.last_close_mode))
check("popup Cancel leaves the destination alone",
    inst:configuredTargets()[1].folder ~= "/Books",
    inst:configuredTargets()[1].folder)
books_arrow.callback() -- now ▾: collapses the tree back
local flat_recollapsed = table.concat(flatten_texts(dlg.frame), "\n")
check("tapping ▾ collapses the tree back (root folders stay visible)",
    flat_recollapsed:find("Fiction", 1, true) == nil
        and flat_recollapsed:find("Books", 1, true) ~= nil
        and flat_recollapsed:find("sleep", 1, true) ~= nil,
    flat_recollapsed)
dlg:pick("CrossDropped Files")

-- 14h. BACK CHEVRON + LIVE DASHBOARD + TAP TARGET: both pages carry a back
-- chevron top-left (dashboard-return, no "closing the app" reading); leaving
-- the tree refreshes the dashboard's destination row; a subfolder created
-- in the tree (pending, not yet on the reader) already shows on that row;
-- the ▸ control is a real tap target, not a hairline glyph.
-- (collect_named lives at file scope.)
inst:setFolder("CrossDropped Files")
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home.tab = "send" -- the destination row lives on the Send tab
home:init()
home:chooseDestination()
dlg = UIManager._shown[#UIManager._shown]
local tree_tbars = collect_named(dlg.frame, "ui/widget/titlebar")
check("the tree carries a back chevron and NO ✕ (home is behind it)",
    #tree_tbars > 0 and tree_tbars[1].left_icon == "chevron.left"
        and type(tree_tbars[1].left_icon_tap_callback) == "function"
        and tree_tbars[1].close_callback == nil,
    tree_tbars[1] and tostring(tree_tbars[1].left_icon))
local home_tbars = collect_named(home.frame, "ui/widget/titlebar")
check("the home dashboard keeps the ✕ (it alone leaves the plugin)",
    #home_tbars > 0 and home_tbars[1].close_callback ~= nil
        and home_tbars[1].left_icon == nil,
    tostring(#home_tbars))
row_btns = collect_buttons(dlg.frame)
local arrow_btn
for _, b in ipairs(row_btns) do
    if arrow_btn == nil and b.text == "\226\150\184" then arrow_btn = b end
end
check("the ▸ control is a real tap target (wide, bigger glyph)",
    arrow_btn ~= nil and arrow_btn.width >= scal(40)
        and (arrow_btn.text_font_size or 0) >= 26,
    arrow_btn and (tostring(arrow_btn.width) .. "/" .. tostring(arrow_btn.text_font_size)))
raw_ok(SUBDIR_JSON)
dlg:expandNode(dlg:findNode("Books"))
UIManager._shown = {}
dlg:showFolderMenu(dlg:findNode("Books"))
menu = UIManager._shown[#UIManager._shown]
menu:onCreate()
local sub_dlg2 = UIManager._shown[#UIManager._shown]
sub_dlg2.getInputText = function() return "Sci-Fi" end
for _, row in ipairs(sub_dlg2.buttons or {}) do
    for _, btn in ipairs(row) do
        if btn.text == "Save" then btn.callback() end
    end
end
check("a created (still-pending) subfolder already shows on the dashboard row",
    inst:configuredTargets()[1].folder == "/Books/Sci-Fi"
        and table.concat(flatten_texts(home.frame)):find("Books/Sci-Fi", 1, true) ~= nil,
    table.concat(flatten_texts(home.frame)))
UIManager._shown = {}
dlg:leave()
check("the back chevron leaves the tree and refreshes the dashboard",
    inst:configuredTargets()[1].folder == "/Books/Sci-Fi" -- destination kept
        and table.concat(flatten_texts(home.frame)):find("Books/Sci-Fi", 1, true) ~= nil,
    inst:configuredTargets()[1].folder)

-- The picker carries the same back chevron, wired to its dashboard-return.
UIManager._shown = {}
inst:chooseAndSend()
local picker_dlg = UIManager._shown[#UIManager._shown]
check("chooseAndSend opens the picker", type(picker_dlg) == "table" and picker_dlg.books ~= nil)
local picker_tbars = collect_named(picker_dlg.frame, "ui/widget/titlebar")
check("the picker carries the back chevron and NO ✕ (home is behind it)",
    #picker_tbars > 0 and picker_tbars[1].left_icon == "chevron.left"
        and type(picker_tbars[1].left_icon_tap_callback) == "function"
        and picker_tbars[1].close_callback == nil,
    picker_tbars[1] and tostring(picker_tbars[1].left_icon))
picker_tbars[1].left_icon_tap_callback()
check("tapping the picker's back chevron returns to the dashboard",
    picker_dlg._closed == true, tostring(picker_dlg._closed))
dlg:pick("CrossDropped Files")
end -- do (14d-14h block)

-- (do..end: sections 14i-14k keep their locals out of the main chunk's
-- 200-local limit; they reference only earlier main-chunk locals.)
do

-- 14i. DELETE TAB (1.4.0): its OWN tab (never inside Send A File), the same
-- tree system but listing FILES too, a confirm popup before anything dies,
-- one WebDAV DELETE on confirm, a popup reporting the result, and the tree
-- live-refreshing in place. Deleting the destination (or its parent) resets
-- the destination to the default.
local ENTRIES_JSON = '[{"name":"Books","size":0,"isDirectory":true,"isEpub":false},'
    .. '{"name":"MyBook.epub","size":123,"isDirectory":false,"isEpub":true},'
    .. '{"name":"CrossDropped Files","size":0,"isDirectory":true,"isEpub":false}]'
local SUBDIR_ENTRIES_JSON = '[{"name":"Fiction","size":0,"isDirectory":true,"isEpub":false},'
    .. '{"name":"Artemis Fowl.epub","size":456,"isDirectory":false,"isEpub":true}]'
inst:setFolder("CrossDropped Files")
raw_ok(ENTRIES_JSON)
local lek, entries = inst:listEntries(inst:resolveTarget())
check("listEntries lists folders AND files",
    lek and type(entries) == "table" and #entries == 3
        and entries[1].name == "Books" and entries[1].is_dir == true
        and entries[3].name == "MyBook.epub" and entries[3].is_dir == false,
    lek and type(entries) == "table" and #entries or tostring(lek))
check("listEntries sorts folders before files",
    entries and entries[1].is_dir == true and entries[2].is_dir == true
        and entries[#entries].is_dir == false)
raw_ok(SUBDIR_ENTRIES_JSON)
inst:listEntries(inst:resolveTarget(), "Books")
check("listEntries asks ?path= for the subfolder",
    last_raw_request:find("/api/files?path=Books", 1, true) ~= nil, last_raw_request)
FAKE.delete_urls = {}
local dek, derr = inst:deleteEntry(inst:resolveTarget(), "Books/Fiction")
check("deleteEntry sends one WebDAV DELETE",
    dek == true and #FAKE.delete_urls == 1
        and FAKE.delete_urls[1]:find("Books/Fiction", 1, true) ~= nil,
    tostring(dek) .. " " .. table.concat(FAKE.delete_urls, " | "))
FAKE.delete_returns = { ["http://10.1.2.3:80/Books/Fiction"] = 500 }
local dfk, dferr = inst:deleteEntry(inst:resolveTarget(), "Books/Fiction")
check("deleteEntry reports a device error",
    dfk == nil and type(dferr) == "string", tostring(dferr))
FAKE.delete_returns = nil

-- The tab itself: its own screen, never mixed into the Send tab.
raw_ok(ENTRIES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:showTab("delete")
local del_tab_flat = table.concat(flatten_texts(home.frame))
check("Delete Folders/Files is its own tab with its own screen",
    home.tab == "delete"
        and del_tab_flat:find("Delete on the reader", 1, true) ~= nil
        and del_tab_flat:find("Browse the reader and pick things to delete", 1, true) ~= nil
        and del_tab_flat:find("Nothing is deleted until you confirm", 1, true) ~= nil,
    del_tab_flat)
UIManager._shown = {}
home:openDeleteTree()
local dtree = UIManager._shown[#UIManager._shown]
check("openDeleteTree opens the delete tree (folders AND files at the root)",
    type(dtree) == "table" and dtree.modal == true and dtree.nodes ~= nil
        and dtree:findNode("Books") ~= nil and dtree:findNode("MyBook.epub") ~= nil,
    tostring(dtree and dtree.nodes and #dtree.nodes))
local dtree_flat = table.concat(flatten_texts(dtree.frame))
check("the delete tree renders folder and file rows",
    dtree_flat:find("Books", 1, true) ~= nil
        and dtree_flat:find("MyBook.epub", 1, true) ~= nil,
    dtree_flat)
local del_btns = collect_buttons(dtree.frame)
local del_arrow_count = 0
for _, b in ipairs(del_btns) do
    if b.text == "\226\150\184" then del_arrow_count = del_arrow_count + 1 end
end
check("only folders carry the ▸ control — files have none",
    del_arrow_count == 2, tostring(del_arrow_count))
raw_ok(SUBDIR_ENTRIES_JSON)
dtree:expandNode(dtree:findNode("Books"))
local dopen_flat = table.concat(flatten_texts(dtree.frame))
check("expanding shows the subfolder's files and folders inline",
    dopen_flat:find("Fiction", 1, true) ~= nil
        and dopen_flat:find("Artemis Fowl.epub", 1, true) ~= nil
        and dopen_flat:find("MyBook.epub", 1, true) ~= nil,
    dopen_flat)
-- The confirm popup: says exactly WHAT dies (file vs folder), only its box
-- region refreshes.
FAKE.delete_urls = {}
UIManager._shown = {}
dtree:showDeletePopup(dtree:findNode("Books/Fiction"))
local dpop = UIManager._shown[#UIManager._shown]
local dpop_flat = table.concat(flatten_texts(dpop.frame), "\n")
check("the folder popup asks 'Delete folder and its contents?' by name",
    dpop_flat:find("Delete folder and its contents?", 1, true) ~= nil
        and dpop_flat:find("/Books/Fiction", 1, true) ~= nil
        and dpop_flat:find("Delete", 1, true) ~= nil
        and dpop_flat:find("Cancel", 1, true) ~= nil,
    dpop_flat)
check("the delete popup refreshes only its box region",
    UIManager.last_show_region ~= nil and UIManager.last_show_region.w < SCREEN_W,
    UIManager.last_show_region and UIManager.last_show_region.w)
dpop:onCancel()
check("Cancel deletes nothing",
    dtree:findNode("Books/Fiction") ~= nil and #FAKE.delete_urls == 0,
    tostring(#FAKE.delete_urls))
-- A FILE popup says "Delete file?" instead.
UIManager._shown = {}
dtree:showDeletePopup(dtree:findNode("Books/Artemis Fowl.epub"))
dpop = UIManager._shown[#UIManager._shown]
dpop_flat = table.concat(flatten_texts(dpop.frame), "\n")
check("the file popup asks 'Delete file?' by name",
    dpop_flat:find("Delete file?", 1, true) ~= nil
        and dpop_flat:find("Artemis Fowl.epub", 1, true) ~= nil,
    dpop_flat)
dpop:onCancel()
-- Confirm: one DELETE, the tree live-refreshes, a popup reports it.
UIManager._shown = {}
FAKE.delete_urls = {}
dtree:showDeletePopup(dtree:findNode("Books/Fiction"))
dpop = UIManager._shown[#UIManager._shown]
dpop:onConfirm()
check("confirm sends the DELETE and the node leaves the tree",
    #FAKE.delete_urls == 1
        and FAKE.delete_urls[1]:find("Books/Fiction", 1, true) ~= nil
        and dtree:findNode("Books/Fiction") == nil,
    table.concat(FAKE.delete_urls, " | "))
local del_after_flat = table.concat(flatten_texts(dtree.frame))
check("the tree repaints without the deleted folder (live refresh)",
    del_after_flat:find("Fiction", 1, true) == nil
        and del_after_flat:find("Books", 1, true) ~= nil,
    del_after_flat)
check("a popup reports the deletion",
    UIManager._shown[#UIManager._shown] ~= nil
        and type(UIManager._shown[#UIManager._shown].text) == "string"
        and UIManager._shown[#UIManager._shown].text:find("Deleted", 1, true) ~= nil,
    UIManager._shown[#UIManager._shown] and UIManager._shown[#UIManager._shown].text)
-- Deleting the destination (or its parent) resets the destination.
inst:setFolder("Books/Fiction")
raw_ok(ENTRIES_JSON)
UIManager._shown = {}
home:openDeleteTree()
dtree = UIManager._shown[#UIManager._shown]
UIManager._shown = {}
FAKE.delete_urls = {}
dtree:showDeletePopup(dtree:findNode("Books"))
dpop = UIManager._shown[#UIManager._shown]
dpop:onConfirm()
check("deleting the destination's parent resets it to the default",
    #FAKE.delete_urls == 1 and FAKE.delete_urls[1]:find("/Books$", 1) ~= nil
        and inst:configuredTargets()[1].folder == "/CrossDropped Files",
    inst:configuredTargets()[1].folder)
-- Unreachable reader: message-only, nothing to tap but back.
FAKE.fail = true
UIManager._shown = {}
home:openDeleteTree()
local derr_dlg = UIManager._shown[#UIManager._shown]
local derr_flat = table.concat(flatten_texts(derr_dlg.frame))
check("unreachable reader: the delete tree shows only the device message",
    derr_dlg.list_err == true
        and derr_flat:find("Device not found", 1, true) ~= nil
        and derr_flat:find("Nothing on the reader", 1, true) == nil,
    derr_flat)
FAKE.fail = false
inst:setFolder("CrossDropped Files")

-- 14j. NON-EMPTY FOLDER PURGE (device-verified 409): the reader's DELETE
-- does NOT recurse — a folder with things inside answers 409. "Delete
-- folder and its contents" therefore purges depth-first (children listed
-- FRESH from the reader, files deleted, folders recursed) and only then
-- the folder itself.
local PURGE_FILES_JSON = '[{"name":"Novel.epub","size":99,"isDirectory":false,"isEpub":true}]'
inst:setFolder("CrossDropped Files")
raw_ok(ENTRIES_JSON)
UIManager._shown = {}
home:openDeleteTree()
dtree = UIManager._shown[#UIManager._shown]
raw_ok(PURGE_FILES_JSON) -- consumed by the purge's own fresh listing
FAKE.delete_409_once = { ["http://10.1.2.3:80/Books"] = true }
UIManager._shown = {}
FAKE.delete_urls = {}
dtree:showDeletePopup(dtree:findNode("Books"))
dpop = UIManager._shown[#UIManager._shown]
dpop:onConfirm()
check("a non-empty folder (409) is purged: contents first, folder last",
    #FAKE.delete_urls == 3
        and FAKE.delete_urls[2]:find("Novel.epub", 1, true) ~= nil
        and FAKE.delete_urls[3]:find("/Books", 1, true) ~= nil,
    table.concat(FAKE.delete_urls, " | "))
check("the purged folder leaves the tree",
    dtree:findNode("Books") == nil,
    tostring(dtree:findNode("Books")))
FAKE.delete_409_once = nil

-- 14k. PAGING: long trees slice into pages (the picker's device-proven
-- recipe), and a deletion that shortens the list clamps the page and
-- repaints the whole (shortened) tree — nothing missing, nothing stale.
-- rows_per_page is pinned to 10 (the dialogs MEASURE it from a real row on
-- the panel — the stub's synthetic row height would give ~33).
local function many_folders_json(n)
    local parts = {}
    for i = 1, n do
        parts[#parts + 1] = string.format(
            '{"name":"Folder%02d","size":0,"isDirectory":true,"isEpub":false}', i)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end
raw_ok(many_folders_json(21))
UIManager._shown = {}
home:openDeleteTree()
local ptree = UIManager._shown[#UIManager._shown]
ptree.rows_per_page = 10
ptree:init()
local pflat = table.concat(flatten_texts(ptree.frame))
check("long lists page: page 1 slices the rows and offers Next",
    pflat:find("Page 1 of 3", 1, true) ~= nil
        and pflat:find("Next page", 1, true) ~= nil
        and pflat:find("Folder01", 1, true) ~= nil
        and pflat:find("Folder11", 1, true) == nil,
    pflat)
ptree:gotoPage(3)
local pflat2 = table.concat(flatten_texts(ptree.frame))
check("the last page shows the tail with Previous and no Next",
    pflat2:find("Page 3 of 3", 1, true) ~= nil
        and pflat2:find("Previous page", 1, true) ~= nil
        and pflat2:find("Folder21", 1, true) ~= nil
        and pflat2:find("Next page", 1, true) == nil,
    pflat2)
UIManager._shown = {}
FAKE.delete_urls = {}
ptree:showDeletePopup(ptree:findNode("Folder21"))
dpop = UIManager._shown[#UIManager._shown]
dpop:onConfirm()
local pflat3 = table.concat(flatten_texts(ptree.frame))
check("a deletion that shortens the list clamps the page and repaints it",
    ptree:findNode("Folder21") == nil
        and ptree.page == 2
        and pflat3:find("Folder21", 1, true) == nil
        and pflat3:find("Folder11", 1, true) ~= nil
        and pflat3:find("Folder20", 1, true) ~= nil
        and pflat3:find("Page 2 of 2", 1, true) ~= nil,
    pflat3)
-- The destination tree pages the same way; its Default row stays visible.
inst:setFolder("CrossDropped Files")
raw_ok(many_folders_json(21))
UIManager._shown = {}
home:chooseDestination()
local dtree2 = UIManager._shown[#UIManager._shown]
dtree2.rows_per_page = 10
dtree2:init()
local dflat2 = table.concat(flatten_texts(dtree2.frame))
check("the destination tree pages too (Default stays visible)",
    dflat2:find("Page 1 of 3", 1, true) ~= nil
        and dflat2:find("Next page", 1, true) ~= nil
        and dflat2:find("back to the default", 1, true) ~= nil,
    dflat2)
dtree2:pick("CrossDropped Files")
end -- do (14i/14j/14k block)

-- 15. IP PERSISTENCE: the WiFi IP lives in KOReader's global settings; in
-- this plugin it is only ever written by the Set WiFi IP dialog.
-- A "restart" (fresh instance) must read it back exactly.
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.9.8.7")
local ui_r = { menu = { registerToMainMenu = function() end }, document = { file = "/tmp/fakebook.epub" } }
local inst_r = CROSSDROP:new{ ui = ui_r }
check("wifi IP survives a restart", inst_r:resolveTarget() and inst_r:resolveTarget().ip == "10.9.8.7",
    inst_r:resolveTarget() and inst_r:resolveTarget().ip)
inst_r:saveTarget({ kind = "wifi", ip = "192.168.5.1", port = 80 })
local inst_r2 = CROSSDROP:new{ ui = ui_r }
check("wifi IP change survives a restart",
    inst_r2:configuredTargets()[1].ip == "192.168.5.1", inst_r2:configuredTargets()[1].ip)
check("port survives a restart",
    inst_r2:configuredTargets()[1].port == 80, inst_r2:configuredTargets()[1].port)
G_reader_settings:saveSetting("crossdrop_folder", "/My Books")
check("folder survives a restart",
    inst_r2:configuredTargets()[1].folder == "/My Books",
    inst_r2:configuredTargets()[1].folder)
G_reader_settings:saveSetting("crossdrop_folder", nil)
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local inst_r3 = CROSSDROP:new{ ui = ui_r }
check("empty wifi stays unset (wifi-only, no fallback)",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().kind == "wifi"
        and inst_r3:resolveTarget().ip == "",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().ip)
inst:saveTarget({ kind = "wifi", ip = "192.168.1.50" })

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)