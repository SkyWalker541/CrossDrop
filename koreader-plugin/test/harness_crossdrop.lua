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
    ["ui/geometry"] = { new = function(_, o) return o or {} end },
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

-- 5b. "Send A Book" picker opens a MODAL file browser above the full-screen
-- Home (non-modal would stack below it, exactly like the old IP dialog bug),
-- in multi-select mode: tapping toggles books (dimmed + ✓). The top-right
-- slot is the send action — the core TitleBar icon-slot pattern (FileManager
-- uses the same plus↔check setRightIcon swap on this build): a question mark
-- while nothing is picked, the ✓ send mark once a book is chosen, and the
-- confirm dialog's OK button is the labeled "Send to Xteink" button.

UIManager._shown = {}
inst:chooseAndSend()
local chooser = UIManager._shown[#UIManager._shown]
check("chooseAndSend opens the file browser", type(chooser) == "table")
check("chooser is modal (paints above Home)", chooser ~= nil and chooser.modal == true, chooser and chooser.modal)
check("chooser filters supported book files", chooser and chooser.file_filter and chooser.file_filter("MyBook.epub") == true)
check("chooser ui has folder_shortcuts (browser needs it)",
    chooser and chooser.ui and chooser.ui.folder_shortcuts and type(chooser.ui.folder_shortcuts.getShortcutFullName) == "function")
check("chooser starts with an empty picker set",
    chooser and type(chooser.picked) == "table" and next(chooser.picked) == nil)
check("chooser picked does NOT collide with FocusManager's selected field",
    chooser and chooser.selected == nil, chooser and chooser.selected)
check("✕ close button stays on the title bar (left icon, wired)",
    chooser and chooser.custom_title_bar and chooser.custom_title_bar.left_icon == "close"
        and type(chooser.custom_title_bar.left_icon_tap_callback) == "function",
    chooser and chooser.custom_title_bar and chooser.custom_title_bar.left_icon)
chooser.custom_title_bar.left_icon_tap_callback() -- still callable: closes without sending
check("right slot shows the question mark before any book is picked",
    chooser and chooser.custom_title_bar and chooser.custom_title_bar.right_icon == "notice-question",
    chooser and chooser.custom_title_bar and chooser.custom_title_bar.right_icon)
local fa = { path = "/tmp/fakebook.epub" }
local fb = { path = "/tmp/fakebook2.epub" }
chooser:onFileSelect(fa)
check("tap picks a book (dim + ✓)", fa.dim == true and tostring(fa.text):match("\226\156\147"), fa.text)
check("✓ send mark appears once a book is picked",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon == "check",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon)
check("picker title shows the selection count",
    chooser.custom_title_bar and tostring(chooser.custom_title_bar.title):match("1 selected"),
    chooser.custom_title_bar and chooser.custom_title_bar.title)
chooser:onFileSelect(fb)
chooser:onFileSelect(fa)
check("tap toggles a book back off (no send on tap)",
    fa.dim == nil and chooser.picked["/tmp/fakebook.epub"] == nil)
check("title count follows the selection",
    chooser.custom_title_bar and tostring(chooser.custom_title_bar.title):match("1 selected"),
    chooser.custom_title_bar and chooser.custom_title_bar.title)
chooser:onFileSelect(fa)
check("✓ stays while books are picked",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon == "check",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon)
chooser:onFileSelect(fb) -- n=1 (fa still picked)
chooser:onFileSelect(fa) -- n=0: last book gone
check("question mark returns when the last book is unpicked",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon == "notice-question",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon)
chooser:onFileSelect(fa) -- n=1 again
check("✓ returns when picking resumes",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon == "check",
    chooser.custom_title_bar and chooser.custom_title_bar.right_icon)
chooser:onFileSelect(fb) -- back to both books (fa + fb)

-- the Send to Xteink confirm: closes the picker and runs the whole batch IN
-- the dashboard (a fake Home sink records the flow; the real Home is
-- exercised in section 14).
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
chooser.custom_title_bar.right_icon_tap_callback()
local cdlg = UIManager._shown[#UIManager._shown]
check("picker ✓ opens a confirm dialog with a Send to Xteink button",
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

-- Send with nothing picked is a gentle hint, never a send (the button is
-- hidden at 0 anyway; the guard still protects a direct callback)
UIManager._shown = {}
chooser.picked = {}
chooser.custom_title_bar.right_icon_tap_callback()
local hint0 = UIManager._shown[#UIManager._shown]
check("Send with no selection shows a hint",
    hint0 and type(hint0.text) == "string" and hint0.text:match("Tap a book"), hint0 and hint0.text)

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
UIManager._shown = {}
inst:editIp("hotspot")
local iph = UIManager._shown[#UIManager._shown]
check("editIp(hotspot) opens dialog", type(iph) == "table")
check("editIp(hotspot) dialog is modal (paints above Home)", iph ~= nil and iph.modal == true, iph and iph.modal)

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
home:check("hotspot")
check("home check() marks hotspot down (no crash)", inst._reach.hotspot == "down", inst._reach.hotspot)
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
inst._reach = { wifi = "ok", hotspot = "down" }
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

-- 12c. the file browser has a visible way back: a custom title bar whose
-- close icon closes the chooser back to the CrossDrop menu.
UIManager._shown = {}
inst:chooseAndSend()
chooser = UIManager._shown[#UIManager._shown]
check("browser has a title bar with a close button",
    chooser and chooser.custom_title_bar
        and chooser.custom_title_bar.left_icon == "close"
        and type(chooser.custom_title_bar.left_icon_tap_callback) == "function"
        and chooser.custom_title_bar.show_parent == chooser,
    chooser and chooser.custom_title_bar and chooser.custom_title_bar.left_icon)
local closed = false
local save_close = UIManager.close
UIManager.close = function(_, w) if w == chooser then closed = true end end
chooser.custom_title_bar.left_icon_tap_callback()
UIManager.close = save_close
check("browser close button closes the chooser", closed)

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
check("no-reader message guides to the reader's hotspot network",
    tostring(home.fail_reason):match("CrossDrop") and tostring(home.fail_reason):match("join the reader"),
    home.fail_reason)
check("no-reader message shows each probe's own error",
    tostring(home.fail_reason):match("connection refused"), home.fail_reason)
check("reach marks both connections down",
    inst._reach and inst._reach.wifi == "down" and inst._reach.hotspot == "down",
    inst._reach and (inst._reach.wifi or "?") .. "/" .. (inst._reach.hotspot or "?"))
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

-- 15. IP PERSISTENCE: connection IPs live in KOReader's global settings; in
-- this plugin they are only ever written by the Set WiFi/HotSpot IP dialogs.
-- A "restart" (fresh instance) must read them back exactly.
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.9.8.7")
G_reader_settings:saveSetting("crossdrop_hotspot_ip", "192.168.4.1")
local ui_r = { menu = { registerToMainMenu = function() end }, document = { file = "/tmp/fakebook.epub" } }
local inst_r = CROSSDROP:new{ ui = ui_r }
check("wifi IP survives a restart", inst_r:resolveTarget() and inst_r:resolveTarget().ip == "10.9.8.7",
    inst_r:resolveTarget() and inst_r:resolveTarget().ip)
inst_r:saveTarget({ kind = "hotspot", ip = "192.168.5.1", port = 80 })
local inst_r2 = CROSSDROP:new{ ui = ui_r }
check("hotspot IP survives a restart",
    inst_r2:configuredTargets()[2].ip == "192.168.5.1", inst_r2:configuredTargets()[2].ip)
check("port survives a restart",
    inst_r2:configuredTargets()[1].port == 80, inst_r2:configuredTargets()[1].port)
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
local inst_r3 = CROSSDROP:new{ ui = ui_r }
check("empty wifi stays deliberately unset (falls back to HotSpot)",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().kind == "hotspot",
    inst_r3:resolveTarget() and inst_r3:resolveTarget().kind)
inst:saveTarget({ kind = "wifi", ip = "192.168.1.50" })
inst:saveTarget({ kind = "hotspot", ip = "192.168.4.1" })

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)