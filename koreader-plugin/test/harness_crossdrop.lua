-- Stub harness: load crossdrop.koplugin/main.lua and exercise the pure logic
-- (req/ensureFolder/listFolders/putFile/sendCurrentBook/statusDialog + FolderBrowser build)
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

local class = {}
function class:addWidget() end
function class:getSize() return { w = 0, h = 0 } end
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
function ScreenStub:getWidth() return 600 end
function ScreenStub:getHeight() return 800 end
function ScreenStub:getSize() return { w = 600, h = 800 } end
function ScreenStub:scaleBySize(v) return v end

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

local stubs = {
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s) return s end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dgray", COLOR_LIGHT_GRAY = "lgray" },
    ["ui/device"] = DeviceStub,
    ["device"] = DeviceStub,
    ["ui/font"] = { getFace = function() return { f = "face" } end, getSize = function() return 20 end },
    ["ui/geometry"] = { new = function(o) return o or {} end },
    ["ui/gesturerange"] = { new = function(o) return o or {} end },
    ["ui/size"] = { radius = { window = 4 }, padding = { default = 9, large = 15 }, span = { horizontal_default = 4 }, border = { window = 1 } },
    ["ui/widget/container/widgetcontainer"] = class:extend{},
    ["ui/widget/container/inputcontainer"] = class:extend{},
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
    scheduleIn = function() return { cancel = function() end } end,
    unschedule = function() end,
}
stubs["ui/uimanager"] = UIManager

-- ── fake device ───────────────────────────────────────────────────────────

local FAKE = {
    fail = false,           -- simulate "connection refused" (LuaSocket string error)
    mkcol_count = 0,
}

local function fake_request(args)
    if FAKE.fail then
        -- LuaSocket failure shape: (nil, "<error string>") — the old crash trigger
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

-- 1. listFolders
local ok, dirs = inst:listFolders({ ip = "192.168.1.50", port = 80 }, "/Books")
check("listFolders ok", ok == true, dirs)
check("listFolders finds Books dir", type(dirs) == "table" and dirs[1] == "Books", dirs and dirs[1])

-- 2. ensureFolder: first call 201 -> true
local eok, eerr = inst:ensureFolder({ ip = "192.168.1.50", port = 80, folder = "/Books" })
check("ensureFolder created (201)", eok == true, eerr)
-- second: 405 -> true
local eok2, eerr2 = inst:ensureFolder({ ip = "192.168.1.50", port = 80, folder = "/Books" })
check("ensureFolder exists (405)", eok2 == true, eerr2)

-- 3. putFile progress + success
local seen = {}
local pok, presult = inst:putFile({ ip = "192.168.1.50", port = 80, folder = "/Books" }, "/tmp/fakebook.epub", function(s, t) seen[#seen + 1] = s end)
check("putFile success", pok == true, presult)
check("putFile progress reported", #seen > 0 and seen[#seen] == 256000, #seen and "#seen=" .. #seen)

-- 4. sendCurrentBook success path (records progress notifications)
UIManager._shown = {}
inst:saveTarget({ ip = "192.168.1.50", port = 80, folder = "/Books" })
local target = inst:resolveTarget()
check("resolveTarget", target and target.ip == "192.168.1.50", target and target.ip)
inst:sendCurrentBook()
local last_notif = UIManager._shown[#UIManager._shown]
check("send success shows Book sent", last_notif and type(last_notif.text) == "string" and last_notif.text:match("Book sent"), last_notif and last_notif.text)

-- 5. THE CRASH CASE: connection refused (string where code should be)
FAKE.fail = true
UIManager._shown = {}
inst:sendCurrentBook()   -- must NOT raise; old code raised "attempt to compare number with string"
local fin = UIManager._shown[#UIManager._shown]
check("failure path does not crash", true)
check("failure shows Send failed", fin and type(fin.text) == "string" and fin.text:match("Send failed"), fin and fin.text)
FAKE.fail = false

-- 6. statusDialog parses device info
UIManager._shown = {}
inst:statusDialog()
local info = UIManager._shown[#UIManager._shown]
check("status dialog shows device", info and type(info.text) == "string" and info.text:match("X4"), info and info.text)

-- 7. FolderBrowser builds without error (folder listing + widgets)
local got = {}
local _CD2 = CROSSDROP:new{ ui = { menu = { registerToMainMenu = function() end } } }
G_reader_settings._store["crossdrop_ip"] = "192.168.1.50"
UIManager._shown = {}
_CD2:pickFolder()
local browser = UIManager._shown[#UIManager._shown]
got.built = (browser ~= nil)
check("FolderBrowser builds + lists remote folders", got.built == true)

-- 7b. Back steps UP a folder, not out (replace with parent folder)
if browser then
    browser.path = "/Books/sub"
    UIManager._shown = {}
    browser:onBack()
    local up = UIManager._shown[#UIManager._shown]
    check("Back goes up one folder level", up and up.path == "/Books", up and up.path)
    -- 7c. Back at the root just closes the browser
    browser.path = "/"
    local closed_ok = pcall(function() browser:onBack() end)
    check("Back at root closes browser without error", closed_ok == true)
end

-- 7d. buildSubItems: every actionable item keeps the reader menu open
local items = inst:buildSubItems()
local all_keep_open = true
for _, it in ipairs(items) do
    if it.callback and not it.keep_menu_open then all_keep_open = false end
end
check("all submenu items keep menu open (keep_menu_open)", all_keep_open == true)

-- 7e. refreshMenu rebuilds the submenu table instead of closing it
local refreshed_ok = false
local fake_menu = {
    item_table = nil,
    updateItems = function(_, p) refreshed_ok = true end,
    registerToMainMenu = function() end,
}
local inst2 = CROSSDROP:new{ ui = { menu = fake_menu } }
inst2:refreshMenu()
check("refreshMenu rebuilds (no menu:close)", refreshed_ok == true and type(fake_menu.item_table) == "table")

-- 8. menu registration
local menu_items = {}
inst:addToMainMenu(menu_items)
check("menu registered as CrossDrop", menu_items.crossdrop ~= nil and menu_items.crossdrop.text == "CrossDrop", menu_items.crossdrop and menu_items.crossdrop.text)

-- 9. Home dialog builds and renders all three tabs (Devices / Send / History)
UIManager._shown = {}
inst:openHome()
local home = UIManager._shown[#UIManager._shown]
check("home dialog opens", home ~= nil)
if home then
    check("home is modal + full-screen", home.modal == true and type(home.dimen) == "table")
    local dc = home:buildTabContent("devices", 560)
    local sc = home:buildTabContent("send", 560)
    local hc = home:buildTabContent("history", 560)
    check("home Devices tab renders", type(dc) == "table")
    check("home Send tab renders", type(sc) == "table")
    check("home History tab renders", type(hc) == "table")
    check("home Back closes", home:onBack() == true)
end

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)