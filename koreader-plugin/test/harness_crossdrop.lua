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
    ["/mnt/us"] = { "Books", "Boldonic Books", "documents", "koreader", "system", "screenshots", ".hidden", "sneaky.azw3" },
    ["/mnt/us/Books"] = { "fakebook.epub", "sub", "fakebook.sdr", "._fakebook.epub" },
    ["/mnt/us/Books/sub"] = { "nested.epub" },
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
    show = function(_, w) table.insert(UIManager._shown, w) end,
    close = function() end,
    setDirty = function() end,
    forceRePaint = function() end,
    nextTick = function(_, f) return f() end,
    scheduleIn = function() return { cancel = function() end } end,
    unschedule = function() end,
}
stubs["ui/uimanager"] = UIManager

-- ── fake device ───────────────────────────────────────────────────────────

local FAKE = {
    fail = false,           -- simulate "connection refused" on everything
    fail_put = false,       -- network is up, but the PUT transfer drops (string error)
    mkcol_count = 0,
}

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
        return '[{"name":"Books","size":0,"isDirectory":true,"isEpub":false},{"name":"MyBook.epub","size":123,"isDirectory":false,"isEpub":true}]', 200
    end
    if method == "MKCOL" then
        FAKE.mkcol_count = FAKE.mkcol_count + 1
        if FAKE.mkcol_count == 1 then return "", 201 end
        return "", 405
    end
    if method == "PUT" then
        if args and args.source then
            while args.source() do end
        end
        return "", 201
    end
    return "not found", 404
end

stubs["socket"] = {
    tcp = function()
        local s = { settimeout = function() end }
        return s
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

-- 3. ONE connection: WiFi only (hotspot was dropped), fixed folder
inst:saveTarget({ ip = "192.168.1.50", port = 80 })
local targets = inst:configuredTargets()
check("configuredTargets: wifi only, no hotspot",
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

-- 5b. "Send A Book" opens the CROSSDROP PICKER (crossdrop_picker.lua) — a
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
    tostring(picker:sendRowText()):match("1 book"), picker:sendRowText())
picker:toggle("/tmp/fakebook2.epub")
picker:toggle("/tmp/fakebook.epub")
check("toggle unpicks a book (no send on tap)",
    picker.picked["/tmp/fakebook.epub"] == nil, picker.picked["/tmp/fakebook.epub"])
check("send row count follows the selection",
    tostring(picker:sendRowText()):match("1 book"), picker:sendRowText())
picker:toggle("/tmp/fakebook.epub") -- both books picked again
-- the device scan (bookshelf-style walk) finds every book — including
-- nested and other source folders — and skips app/system/sidecar junk
local books = picker:scanAllBooks("/mnt/us")
local names = {}
for _, b in ipairs(books) do names[b.name] = true end
local all_names = {}
for n in pairs(names) do all_names[#all_names + 1] = n end
check("device scan finds the books (all folders, nested)",
    names["fakebook.epub"] and names["nested.epub"] and names["fakebook2.azw"]
        and names["bold.epub"] and names["sneaky.azw3"],
    table.concat(all_names, ", "))
check("scan skips app/system/hidden/sidecar dirs and AppleDouble files",
    not names["junk.epub"] and not names["junk2.pdf"] and not names["meta.epub"]
        and not names["hidden.epub"] and not names["._fakebook.epub"] and not names["screen.png"],
    names["junk.epub"] and "koreader walked" or "ok")
check("picker scanned at open (books cached on the dialog)",
    picker.books ~= nil and #picker.books == 5, picker.books and #picker.books)

-- 5d. 1.3.18 real titles + search: rows show title-like names, not raw
-- filenames, and a case-insensitive keyword search filters the pageable list.

-- System text files join FAKE_FS: the scan must still NOT pick them up
FAKE_FS["/mnt/us"] = { "Books", "Boldonic Books", "documents", "koreader", "system", "screenshots", ".hidden", "sneaky.azw3", "notes.txt" }
FAKE_FS["/mnt/us/Books"] = { "fakebook.epub", "sub", "fakebook.sdr", "._fakebook.epub", "readme.md" }
local rescan = picker:scanAllBooks("/mnt/us")
local pk_names = {}
for _, b in ipairs(rescan) do pk_names[b.name] = true end
check("scan still finds 5 books with .txt/.md present", #rescan == 5, #rescan)
check("scan excludes notes.txt and readme.md",
    not pk_names["notes.txt"] and not pk_names["readme.md"],
    pk_names["notes.txt"] and "notes.txt listed" or "ok")

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
check("search matches the displayed title (fake)", #picker:visibleBooks() == 2,
    tostring(#picker:visibleBooks()))
picker.query = "BOLD"
check("search ignores capitalisation (BOLD)", #picker:visibleBooks() == 1,
    tostring(#picker:visibleBooks()))
picker.query = "book"
check("search is a plain substring, no pattern magic (book)", #picker:visibleBooks() == 2,
    tostring(#picker:visibleBooks()))
picker.query = "azw"
check("search also matches the raw filename (azw)", #picker:visibleBooks() == 2,
    tostring(#picker:visibleBooks()))
picker.query = "zzzz"
check("unmatched search yields nothing (no crash)", #picker:visibleBooks() == 0,
    tostring(#picker:visibleBooks()))
picker.query = nil
check("clearing the query shows the full list", #picker:visibleBooks() == 5,
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
check("search narrows the visible books", #picker:visibleBooks() == 2,
    tostring(#picker:visibleBooks()))
picker:clearSearch()
check("clear search restores the full list",
    picker.query == nil and #picker:visibleBooks() == 5,
    tostring(picker.query) .. "/" .. tostring(#picker:visibleBooks()))

-- 1.3.18 follow-up: uniform font + a framed box on EVERY row (Button no
-- longer shrinks long titles into a smaller font), and the active-filter
-- caption spelled as "Search \"X\" — N results".
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
picker.query = "book"
local content = picker:buildContent()
local row_btns, search_caption = find_row_buttons(content)
local uniform, framed = #row_btns > 0, (#row_btns > 0)
for _, btn in ipairs(row_btns) do
    if btn.text_font_size ~= 22 then uniform = false end
    if not (btn.bordersize and btn.bordersize > 0) then framed = false end
end
check("every row uses one font size (22)", uniform,
    row_btns[1] and tostring(row_btns[1].text_font_size))
check("rows never shrink long titles (avoid_text_truncation off)",
    row_btns[1] and row_btns[1].avoid_text_truncation == false,
    row_btns[1] and tostring(row_btns[1].avoid_text_truncation))
check("every row is a framed box (visible border)", framed,
    row_btns[1] and tostring(row_btns[1].bordersize))
check("search caption reads Search \"X\" — N results",
    search_caption ~= nil and search_caption:find("Search", 1, true) ~= nil
        and search_caption:find("results", 1, true) ~= nil, tostring(search_caption))
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
    cdlg and cdlg.ok_text == "Send to Xteink" and tostring(cdlg.text):match("Send 2 book"),
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
    no_book and type(no_book.text) == "string" and no_book.text:match("Send A Book"),
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

-- 8b. send books always land in CrossDropped Files: folder setting cannot override
G_reader_settings:saveSetting("crossdrop_folder", "/Books")
local forced = inst:configuredTargets()
check("folder setting ignored (always CrossDropped Files)", forced[1].folder == "/CrossDropped Files", forced[1].folder)

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
end

-- 12. THE SEND CRASH: the progress dialog used childless FrameContainers for
-- its bar fill/track. OverlapGroup:init calls getSize() on every child at
-- build time and FrameContainer:getSize does self[1]:getSize() — childless
-- frames crashed the moment a transfer started. The bar is now LineWidgets.
local ProgressMod = require("crossdrop_progress")
local dlg = ProgressMod.new("mybook.epub", { ip = "192.168.1.50", port = 80, folder = "/CrossDropped Files" })
check("progress dialog builds (no childless-frame crash)", type(dlg) == "table", dlg)
if dlg then
    check("progress bar fill is sized (LineWidget, no crash on getSize)",
        dlg.bar_fill and dlg.bar_fill.dimen and dlg.bar_fill.dimen.w == 0)
    local bar = dlg[1] and dlg[1][1] and dlg[1][1][1] and dlg[1][1][1][1] and dlg[1][1][1][1][3]
    check("progress bar paints track then fill (fill on top)",
        bar and bar[1] and bar[1].__name and bar[1].__name:match("framecontainer") and bar[2] == dlg.bar_fill,
        tostring(bar and bar[1] and bar[1].__name))
    dlg:update(50, 65536, 131072, 1.0)
    check("progress update grows the fill", dlg.bar_fill.dimen.w > 0 and dlg.bar_fill.dimen.w <= dlg.bar_w,
        dlg.bar_fill.dimen.w)
    check("progress update repaints in place", dlg.pct_text and dlg.pct_text.text == "50%",
        dlg.pct_text and dlg.pct_text.text)
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
-- which repaints its OWN Send tab in place (connecting → live bar → done) —
-- nothing closes between picking, connecting, transferring, and sending more.
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
FAKE.fail, FAKE.fail_put = false, false
local ok_batch = inst:sendBooks({ "/tmp/fakebook.epub", "/tmp/fakebook2.epub" }, home)
check("in-dashboard batch sends every book", ok_batch == true)
check("home ends in the done state", home.send_state == "done", home.send_state)
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
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local inst_r3 = CROSSDROP:new{ ui = ui_r }
check("empty wifi stays unset (wifi-only, no fallback)",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().kind == "wifi"
        and inst_r3:resolveTarget().ip == "",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().ip)
inst:saveTarget({ kind = "wifi", ip = "192.168.1.50" })

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)