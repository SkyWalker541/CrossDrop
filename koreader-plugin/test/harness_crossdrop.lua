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
function class:setText() end

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

local stubs = {
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s) return s end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dgray", COLOR_LIGHT_GRAY = "lgray" },
    ["ui/device"] = DeviceStub,
    ["device"] = DeviceStub,
    ["ui/font"] = FontStub,
    ["ui/geometry"] = { new = function(o) return o or {} end },
    ["ui/gesturerange"] = { new = function(o) return o or {} end },
    ["ui/size"] = {
        radius = { window = scal(7) },
        padding = { default = scal(5), large = scal(10) },
        span = { horizontal_default = scal(10) },
        border = { window = scal(1.5) },
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
    _shown = {},
    show = function(_, w) table.insert(UIManager._shown, w) end,
    close = function() end,
    replace = function(_, o, n) table.insert(UIManager._shown, n) end,
    setDirty = function() end,
    forceRePaint = function() end,
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
stubs["json"] = json_mod

-- lfs stub: size via io
stubs["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        local f = io.open(path, "rb")
        if not f then return nil end
        if what == "size" then
            local cur = f:seek("set", 0)
            local sz = f:seek("end")
            f:close()
            return sz
        end
        f:close()
        return nil
    end,
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

-- 3. two connections: WiFi first (when set), HotSpot always present, fixed folder
inst:saveTarget({ ip = "192.168.1.50", port = 80 })
local targets = inst:configuredTargets()
check("configuredTargets: wifi first", targets[1] and targets[1].kind == "wifi" and targets[1].ip == "192.168.1.50", targets[1] and targets[1].kind)
check("configuredTargets: hotspot always present", targets[2] and targets[2].kind == "hotspot" and targets[2].ip == "192.168.4.1", targets[2] and targets[2].ip)
check("both connections use CrossDropped Files", targets[1].folder == "/CrossDropped Files" and targets[2].folder == "/CrossDropped Files", targets[1].folder and targets[2].folder)
check("resolveTarget picks wifi", inst:resolveTarget() and inst:resolveTarget().kind == "wifi")

-- 4b. probeReachable answers the reachable connection; falls back to hotspot
local reached = inst:probeReachable()
check("probeReachable finds wifi", reached and reached.kind == "wifi", reached and reached.kind)
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local reached_be = inst:probeReachable()
check("probeReachable falls back to hotspot", reached_be and reached_be.kind == "hotspot", reached_be and reached_be.kind)

-- 4c. probeTarget parses device info
local pok2, pinfo = inst:probeTarget({ kind = "wifi", ip = "192.168.1.50", port = 80 })
check("probeTarget ok + info", pok2 == true and pinfo and pinfo.device == "X4", pinfo and pinfo.device)

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

-- 5b. history records the entry; sentList/clearSent work
local sent = inst:sentList()
check("sentList has one entry", type(sent) == "table" and #sent == 1 and sent[1].file == "fakebook.epub", sent and sent[1] and sent[1].file)
check("history entry records kind wifi", sent[1] and sent[1].kind == "wifi", sent[1] and sent[1].kind)
inst:clearSent()
check("clearSent empties history", #(inst:sentList() or {}) == 0)

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

-- 8. editIp opens an input dialog for each connection
UIManager._shown = {}
inst:editIp("wifi")
check("editIp(wifi) opens dialog", type(UIManager._shown[#UIManager._shown]) == "table")
UIManager._shown = {}
inst:editIp("hotspot")
check("editIp(hotspot) opens dialog", type(UIManager._shown[#UIManager._shown]) == "table")

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
    local hc = home:buildTabContent("history", 560)
    check("home Connections tab renders", type(cc) == "table")
    check("home Send tab renders", type(sc_) == "table")
    check("home History tab renders", type(hc) == "table")
    check("home Back closes", home:onBack() == true)
end

-- 11a. Layout never spills past the screen edges on the Kindle (the sizing
-- must be device-scaled + width-capped like Storefront, regardless of screen).
check("home frame fits within screen width",
    home and home.frame and home.frame:getSize().w <= SCREEN_W,
    home and home.frame and home.frame:getSize().w or "no frame")
for _, tab in ipairs({ "connections", "send", "history" }) do
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
home:check("hotspot")
check("home check() marks hotspot down (no crash)", inst._reach.hotspot == "down", inst._reach.hotspot)
FAKE.fail = false

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)