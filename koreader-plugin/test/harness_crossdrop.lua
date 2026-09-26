-- Stub harness: load main.lua and exercise the pure logic
-- (req/ensureFolder/putFile/sendCurrentBook/statusDialog + Home dashboard)
-- against a FAKE device, including the LuaSocket string-error case that used to crash.
-- 1.5.0-test1: also covers the picker's whole-card reader duplicate scan
-- (listAllFiles walk, "On reader" row marks, already-on-reader toast).

-- Resolve the plugin root relative to this harness file so it runs from any
-- checkout (and in CI): arg[0] is "test/harness_crossdrop.lua"; the plugin
-- lives in the sibling crossdrop.koplugin/ directory (first on the path so
-- any stale flat copies at the repo root can never shadow it).
local HARNESS_DIR = (arg and arg[0] and arg[0]:gsub("(.*/)[^/]+$", "%1")) or "test/"
local PLUGIN_ROOT = HARNESS_DIR .. "../"
package.path = PLUGIN_ROOT .. "/crossdrop.koplugin/?.lua;" .. PLUGIN_ROOT .. "/?.lua;" .. package.path

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

local function encode_json_value(v, out)
    if type(v) == "nil" then
        out:write("null")
    elseif type(v) == "boolean" then
        out:write(v and "true" or "false")
    elseif type(v) == "number" then
        out:write(("%d"):format(v))
    elseif type(v) == "string" then
        -- paths/names/URLs: only backslash, quote and newline need escaping
        local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
        out:write('"', escaped, '"')
    elseif type(v) == "table" then
        local is_array = true
        for k in pairs(v) do
            if type(k) ~= "number" then is_array = false break end
        end
        out:write(is_array and "[" or "{")
        local first = true
        for k, val in pairs(v) do
            if not first then out:write(",") end
            first = false
            if not is_array then
                out:write('"', tostring(k):gsub('[\\"]', '\\%0'), '":')
            end
            encode_json_value(val, out)
        end
        out:write(is_array and "]" or "}")
    else
        out:write("null")
    end
end

json_mod.encode = function(v)
    local parts = {}
    parts.write = function(_, ...)
        for i = 1, select("#", ...) do
            table.insert(parts, (select(i, ...)))
        end
    end
    encode_json_value(v, parts)
    return table.concat(parts)
end

-- ── KOReader module stubs ────────────────────────────────────────────────

-- Geometry emulation: the Kindle PW5 SE reports 1236x1648 (portrait) and
-- scaleBySize(px) = ceil(px * min(w,h)/600) (see its ffi/framebuffer.lua).
-- The stubs measure auto-sized text instead of returning {0,0}, so a layout
-- that runs past the screen edges on the device fails the harness too.
-- (NOT local: the cross-device geometry sweep reassigns these and re-runs the
-- geometry-sensitive layout at a spread of real screen sizes.)
SCREEN_W, SCREEN_H = 1236, 1648
SCREEN_SCALE = SCREEN_W / 600
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
    -- Model the device: Font:getFace scales the requested size by the screen's
    -- DPI (scaleBySize) before metrics, so a char is ~0.5em of the SCALED size.
    -- Unscaled, a 1236px tab bar "fits" any label — the very overflow this
    -- suite exists to catch. Widths scale with SCREEN_SCALE (re-set by the
    -- geometry sweep); heights stay unscaled (vertical paging is unaffected).
    local cw = math.ceil(fsize * 0.5 * SCREEN_SCALE)
    local w, lines = 0, 1
    for part in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        w = math.max(w, utf8_chars(part) * cw)
        lines = lines + 1
    end
    if max_width then w = math.min(w, max_width) end
    return { w = w, h = lines * math.ceil(fsize * 1.2) }
end

-- The stubs register the FULL require path as __name (e.g.
-- "ui/widget/verticalgroup"), but the plugin's real KOReader core classes are
-- named shortly ("VerticalGroup"). The getSize geometry branches and the
-- invalid-align guards below used to compare short names, so with full-path
-- __name they NEVER fired — vertical groups measured as horizontal, every
-- FrameContainer returned 0x0, and device overflows (like the tab bar running
-- past the 4th slot) sailed through green. Map the full path to the short
-- class name the device actually uses.
local SHORTNAME = {
    ["ui/widget/verticalspan"] = "VerticalSpan",
    ["ui/widget/horizontalspan"] = "HorizontalSpan",
    ["ui/widget/verticalgroup"] = "VerticalGroup",
    ["ui/widget/horizontalgroup"] = "HorizontalGroup",
    ["ui/widget/container/framecontainer"] = "FrameContainer",
    ["ui/widget/container/centercontainer"] = "CenterContainer",
}
local function shortname(s)
    return SHORTNAME[s or ""] or s
end

local class = {}
function class:getSize()
    local name = shortname(self.__name)
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
        local p = self.padding
        if p == nil then p = scal(5) end -- device Size.padding.default = scaleBySize(5)
        local b = self.bordersize
        if b == nil then b = scal(1.5) end -- device Size.border.window
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
    local o_short = shortname(o.__name)
    if o_short == "HorizontalGroup" and o.align ~= nil
        and o.align ~= "top" and o.align ~= "center" and o.align ~= "bottom" then
        error(string.format(
            "HorizontalGroup align %q is invalid on the device (top/center/bottom) — it would paint nothing",
            tostring(o.align)))
    end
    if o_short == "VerticalGroup" and o.align ~= nil
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

-- KOReader-faithful layout groups. The real HorizontalGroup/VerticalGroup
-- CACHE _size/_offsets on the first getSize and NEVER recompute — and
-- paintTo indexes self._offsets[i] for every child. So mutating a group's
-- child list AFTER it was measured (adding a child, or reusing the measured
-- table for the real row after a measurement) leaves stale offsets and the
-- device dies at paint ("attempt to index a nil value", offset missing for a
-- child that came after the measurement). The old stubs recomputed each call,
-- so that bug — which crashed the Kindle the moment the dashboard painted —
-- passed here. This stub caches like the device, and paintTo hard-fails on a
-- missing offset instead of silently painting nothing.
local GroupClass = setmetatable({}, { __index = class })
function GroupClass:getSize()
    if not self._size then
        self._size = { w = 0, h = 0 }
        self._offsets = {}
        local vertical = shortname(self.__name) == "VerticalGroup"
        for i = 1, #self do
            local kid = self[i]
            local s = (type(kid) == "table" and type(kid.getSize) == "function")
                and kid:getSize() or { w = 0, h = 0 }
            if vertical then
                self._offsets[i] = { x = s.w, y = self._size.h }
                self._size.h = self._size.h + s.h
                if s.w > self._size.w then self._size.w = s.w end
            else
                self._offsets[i] = { x = self._size.w, y = s.h }
                self._size.w = self._size.w + s.w
                if s.h > self._size.h then self._size.h = s.h end
            end
        end
    end
    return self._size
end
function GroupClass:paintTo(bb, x, y)
    self:getSize()
    for i = 1, #self do
        if not self._offsets or not self._offsets[i] then
            local have = self._offsets and #self._offsets or 0
            error(string.format(
                "%s: %d children but only %d layout offsets (measured before the "
                    .. "children were final) — the tab bar crashed the Kindle with "
                    .. "horizontalgroup.lua:51 attempt to index a nil value",
                self.__name, #self, have))
        end
        local kid = self[i]
        if type(kid) == "table" and type(kid.paintTo) == "function" then
            kid:paintTo(bb, x + self._offsets[i].x, y + self._offsets[i].y)
        end
    end
    return true
end
-- Paint simulation: walk every child like the real (recursive) paintTo would,
-- bottoming out at leaves. Lets tests drive a built widget tree through the
-- device's paint path so layout-cache faults fail here instead of on-screen.
function class:paintTo(bb, x, y)
    for i = 1, #self do
        local kid = self[i]
        if type(kid) == "table" and type(kid.paintTo) == "function" then
            kid:paintTo(bb, x or 0, y or 0)
        end
    end
    return true
end
local function _group_stub(name)
    return GroupClass:extend{ __name = name }
end

local function widget_stub(name, extra)
    if name == "ui/widget/horizontalgroup" or name == "ui/widget/verticalgroup" then
        return _group_stub(name)
    end
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

-- Where plugin data lives in the tests: the Collections file must be written
-- OUTSIDE the plugin folder (Storefront replaces the whole folder per update),
-- so the harness DataStorage stub points somewhere far from the plugin dir.
local HARNESS_DATA_DIR = "/tmp/crossdrop-harness-data"
-- Each run starts from a pristine data dir: a crashed earlier run can leave
-- devices.json / collections.json behind, and a leftover "selected" stored
-- device would silently change what connectedTargets()/probeReachable report.
os.execute("rm -rf " .. HARNESS_DATA_DIR)

local stubs = {
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s) return s end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dgray", COLOR_LIGHT_GRAY = "lgray", Color8 = function(v) return "gray" .. tostring(v) end },
    ["ui/device"] = DeviceStub,
    ["device"] = DeviceStub,
    ["ui/font"] = FontStub,
    ["ui/geometry"] = { new = function(_, o) return o or {} end },
    ["ui/gesturerange"] = { new = function(o) return o or {} end },
    ["ui/size"] = {
        radius = { window = scal(7), button = scal(12) },
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

-- The exact set of KOReader core modules this plugin may require — every one
-- verified to exist on the target device (frontend/ui/*). Any OTHER ui/ (or
-- ui/widget/) path is a typo like "ui/widget/container/verticalgroup" — a
-- path that exists ONLY in this harness's generic widget stub — and would
-- crash the real plugin at load ("module not found"). The stubs previously
-- masked that: they accept any ui/ name, so a wrong path passed here and
-- failed only on the Kindle (AGENTS: verify the exact pattern against core).
local KNOWN_CORE = {}
for _, m in ipairs({
    "ui/uimanager", "ui/size", "ui/geometry", "ui/font", "ui/gesturerange",
    "ui/widget/button", "ui/widget/confirmbox", "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan", "ui/widget/iconbutton", "ui/widget/imagewidget",
    "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/linewidget",
    "ui/widget/notification", "ui/widget/overlapgroup",
    "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/titlebar",
    "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer", "ui/widget/container/leftcontainer",
    "ui/widget/container/movablecontainer", "ui/widget/container/widgetcontainer",
}) do KNOWN_CORE[m] = true end

local function make_require()
    local real_require = require
    return function(name)
        if stubs[name] then return stubs[name] end
        if name:match("^ui/") then
            if not KNOWN_CORE[name] then
                error(string.format(
                    "crossdrop requires core module %q which does not exist on the device "
                        .. "(frontend/%s.lua) — a stubbed path that would crash the real plugin",
                    name, tostring(name:gsub("%.", "/"))))
            end
            return widget_stub(name)
        end
        if name:match("^libs/") then
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
    _shown_log = {},          -- every show() call, even if close() later pops it
    last_dirty = nil,
    last_show_mode = nil,
    last_show_region = nil,
    last_close_mode = nil,
    last_close_region = nil,
    show = function(_, w, mode, region)
        UIManager.last_show_mode = mode
        UIManager.last_show_region = region
        table.insert(UIManager._shown, w)
        table.insert(UIManager._shown_log, w)
    end,
    close = function(_, w, mode, region)
        UIManager.last_close_mode = mode
        UIManager.last_close_region = region
        for i = #UIManager._shown, 1, -1 do
            if UIManager._shown[i] == w then
                table.remove(UIManager._shown, i)
            end
        end
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
    put_urls = {},          -- every PUT url answered (asserts the position sidecar)
    post_mkdirs = {},       -- every POST /mkdir url + body (position cache dir)
    post_uploads = {},      -- every POST /upload url + body (progress.bin)
    delete_urls = {},       -- every DELETE url answered (the delete tab's tree)
    delete_returns = nil,   -- optional { [url] = status } to force per-URL replies
    delete_409_once = nil,  -- optional { [url] = true }: first DELETE -> 409 (not empty), then 204
    files_tree = nil,       -- optional { [decoded path] = JSON listing }: the whole-card
                            -- duplicate scan serves EACH folder's listing from this map
                            -- (path "" = card root) instead of one-shot TCP_RESP.
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
        FAKE.put_urls[#FAKE.put_urls + 1] = url
        if args and args.source then
            while args.source() do end
        end
        return "", 201
    end
    if method == "POST" and url:match("/mkdir") then
        -- Device-true: ltn12 CALLS args.source and dies on a raw string
        -- ("attempt to call local 'src' (a string value)") — the real crash the
        -- position write hit on device. The plugin wraps string bodies first,
        -- so reaching here with a string is a regression.
        if type(args.source) == "string" then
            error("common/ltn12.lua: attempt to call local 'src' (a string value)", 0)
        end
        local body = args.source and (function()
            local out = ""
            while true do
                local chunk = args.source()
                if not chunk then break end
                out = out .. chunk
            end
            return out
        end)() or ""
        FAKE.post_mkdirs[#FAKE.post_mkdirs + 1] = { url = url, body = body }
        return "", 200
    end
    if method == "POST" and url:match("/upload") then
        -- Same device-true guard as /mkdir (see above).
        if type(args.source) == "string" then
            error("common/ltn12.lua: attempt to call local 'src' (a string value)", 0)
        end
        local body = args.source and (function()
            local out = ""
            while true do
                local chunk = args.source()
                if not chunk then break end
                out = out .. chunk
            end
            return out
        end)() or ""
        FAKE.post_uploads[#FAKE.post_uploads + 1] = { url = url, body = body }
        return "", 200
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
-- Decode the ?path= argument of a raw GET request line into the plain folder
-- name the fixture is keyed by ("CrossDropped Files" from %20); "" = card root.
local function raw_request_path(request)
    local p = tostring(request or ""):match("path=([^ ]*)")
    if not p or p == "" then return "" end
    p = p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return p
end
-- Monotonic fake clock for putFile pacing (socket.gettime/socket.sleep). The
-- harness advances it so the live-progress pacing is exercised deterministically.
local fake_clock = 0.0
local sleep_calls = 0
stubs["socket"] = {
    tcp = function()
        local served = false -- one HTTP response per socket connection (see below)
        return {
            settimeout = function() end,
            connect = function() if FAKE.fail then return nil, "connection refused" end return 1 end,
            send = function(_, data) last_raw_request = tostring(data or "") return 1 end,
            receive = function()
                if served then return nil end -- rawBody reads "*a" until nil
                local r = TCP_RESP -- one-shot response the TEST planted (raw_ok) wins
                if r ~= nil then
                    TCP_RESP = nil
                elseif FAKE.files_tree then
                    -- Whole-card duplicate scan (1.5.0-test1): serve each
                    -- ?path= request from the folder fixture ("" = root), so a
                    -- single scan can walk the whole card deterministically.
                    local p = raw_request_path(last_raw_request)
                    if FAKE.files_tree[p] ~= nil then
                        r = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
                            .. FAKE.files_tree[p]
                    end
                end
                if r == nil then return nil end
                served = true
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

-- data outside the plugin folder: the presence stub serves the same role as
-- real KOReader's datastorage, so getCollectionsPath resolves under it and
-- never inside crossdrop.koplugin/ (which Storefront replaces whole).
stubs["datastorage"] = {
    getDataDir = function() return HARNESS_DATA_DIR end,
    getDocSettingsDir = function() return HARNESS_DATA_DIR .. "/docsettings" end,
    getDocSettingsHashDir = function() return HARNESS_DATA_DIR .. "/docsettings.hash" end,
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
check("send success shows File sent", last_notif and type(last_notif.text) == "string" and last_notif.text:match("File sent"), last_notif and last_notif.text)

-- 5b. "Send A File" opens the CROSSDROP PICKER (crossdrop_picker.lua) — a
-- device-wide book scan (the bookshelf.koplugin walk pattern) rendered on
-- the dashboard's proven widgets: its own picked set (toggle), the
-- always-visible "Send to Xteink" action row (sendRowText → confirmAndSend),
-- paging, and exit that always lands back on the CrossDrop dashboard.

-- The whole-card reader fixture (1.5.0-test1): the picker holds its open on
-- a full-card scan before the first row paints. Fake reader card:
--   ""                      Books/, MyBook.epub@123, sleep/, CrossDropped Files/
--   Books/                  Fiction/, fakebook.epub@256000, The_Name_of_the_Wind.epub@5000
--   Books/Fiction/          dune.epub@999
--   sleep/                  (empty)
--   CrossDropped Files/     GUIDE.ePub@256000 (case differs!), The_Name_of_the_Wind.epub@5000
-- so fakebook.epub (256000) and Guide.EPUB (256000) are duplicates, bold.epub
-- is NOT (no reader twin), and The_Name_of_the_Wind.epub appears in TWO
-- folders. Arming this also keeps every later picker open (sections 12c/14h)
-- deterministic. raw_ok() one-shots still win (they're planted per-test).
FAKE.files_tree = {
    [""] = '[{"name":"Books","size":0,"isDirectory":true,"isEpub":false},'
        .. '{"name":"MyBook.epub","size":123,"isDirectory":false,"isEpub":true},'
        .. '{"name":"Catch-22.epub","size":777,"isDirectory":false,"isEpub":true},'
        .. '{"name":"Caf\195\169.epub","size":999,"isDirectory":false,"isEpub":true},'
        .. '{"name":"sleep","size":0,"isDirectory":true,"isEpub":false},'
        .. '{"name":"CrossDropped Files","size":0,"isDirectory":true,"isEpub":false}]',
    ["Books"] = '[{"name":"Fiction","size":0,"isDirectory":true,"isEpub":false},'
        .. '{"name":"fakebook.epub","size":256000,"isDirectory":false,"isEpub":true},'
        .. '{"name":"The_Name_of_the_Wind.epub","size":5000,"isDirectory":false,"isEpub":true}]',
    ["Books/Fiction"] = '[{"name":"dune.epub","size":999,"isDirectory":false,"isEpub":true}]',
    ["sleep"] = "[]",
    ["CrossDropped Files"] = '[{"name":"GUIDE.ePub","size":256000,"isDirectory":false,"isEpub":true},'
        .. '{"name":"The_Name_of_the_Wind.epub","size":5000,"isDirectory":false,"isEpub":true}]',
}

-- The fixture above must serve the whole-card scan's root read: TCP_RESP is
-- initialized to CLEAN_FILES_JSON (the old root) and only cleared once
-- consumed, so blank it before the open or root misses the new files.
TCP_RESP = nil
-- Everything below the tabs: choosing files opens the picker INSIDE the
-- already-open dashboard (the brand header + tab bar stay on screen; the
-- list paints below them, see renderFilesBrowser). No full-screen dialog is
-- stacked over the dashboard any more.
UIManager._shown = {}
inst:chooseAndSend()
local picker = inst.home and inst.home.send_picker
check("chooseAndSend opens the file picker INSIDE the dashboard (home on-screen)",
    type(picker) == "table" and inst.home ~= nil, picker and "picker" or "no picker")
check("no full-screen screen is stacked (the one widget is Home)",
    #UIManager._shown == 1 and UIManager._shown[1] == inst.home,
    tostring(#UIManager._shown))
-- the SAME frame carries the tabs AND the picker list: the browser paints
-- below the never-leaving header + tab bar.
local frame_tab_seen = false
local function walk_frame(t)
    if type(t) == "table" then
        if type(t.text) == "string" and (t.text:find("Delete Files", 1, true) or t.text:find("Delete", 1, true)) then
            frame_tab_seen = true
        end
        for i = 1, #t do walk_frame(t[i]) end
    end
end
walk_frame(inst.home and inst.home.frame)
check("the browser is the Send tab's sub-screen (tabs still on the frame)",
    inst.home ~= nil and inst.home.send_screen == "files" and frame_tab_seen,
    inst.home and (inst.home.send_screen or "no screen") .. " / tabs=" .. tostring(frame_tab_seen))
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

-- 5d. real titles + search: rows show title-like names, not raw
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

-- uniform font + a framed box on EVERY row (Button no
-- longer shrinks long titles into a smaller font), and the active-filter
-- caption spelled as "Search \"X\" — N results".
-- file rows are borderless (bare text with hairline rules
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
local rows_radiused = #row_btns > 0
for _, btn in ipairs(row_btns) do
    -- -1 off Size.radius.button: core's unhighlight mistakes an exact match
    -- for flash residue and nils it (button stays square after first tap).
    if btn.radius ~= require("ui/size").radius.button - 1 then rows_radiused = false end
end
check("rows carry an explicit radius (tap highlight fills the whole box)",
    rows_radiused, tostring(row_btns[1] and row_btns[1].radius))
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

-- 5d-dupes. THE WHOLE-CARD DUPLICATE SCAN (1.5.0-test1): the picker indexed
-- every folder of the reader's card at open (before the first row painted),
-- matched local books by filename AND size (case-insensitive), notated the
-- duplicate rows, and pauses the pick on a Send-anyway confirm box so the
-- duplication cannot be walked past.
do

check("whole-card scan ran at open (index built once)",
    picker.reader_index ~= nil and picker.reader_scan_done == true,
    type(picker.reader_index))
check("scan indexed the card root files",
    picker.reader_index["mybook.epub"] ~= nil
        and picker.reader_index["mybook.epub"][1].size == 123
        and picker.reader_index["mybook.epub"][1].folder == "",
    picker.reader_index["mybook.epub"] and picker.reader_index["mybook.epub"][1].size or "no mybook")
check("scan indexed a file shown in TWO folders",
    picker.reader_index["the_name_of_the_wind.epub"] ~= nil
        and #picker.reader_index["the_name_of_the_wind.epub"] == 2,
    picker.reader_index["the_name_of_the_wind.epub"] and #picker.reader_index["the_name_of_the_wind.epub"] or "no bucket")
check("scan indexed a nested folder's file with its full path",
    picker.reader_index["dune.epub"] ~= nil
        and picker.reader_index["dune.epub"][1].folder == "Books/Fiction"
        and picker.reader_index["dune.epub"][1].size == 999,
    picker.reader_index["dune.epub"] and picker.reader_index["dune.epub"][1].folder or "no dune")

-- readerEntryFor: filename AND size, case-insensitive.
check("duplicate matched by name+size (fakebook)",
    picker:readerEntryFor({ name = "fakebook.epub", size = 256000 }) ~= nil,
    "no match")
check("reader match is case-insensitive (local Guide.EPUB ↔ reader GUIDE.ePub)",
    picker:readerEntryFor({ name = "Guide.EPUB", size = 256000 }) ~= nil,
    "no match")
check("a name match with a DIFFERENT size is not a duplicate",
    picker:readerEntryFor({ name = "The_Name_of_the_Wind.epub", size = 123 }) == nil)
check("no reader twin -> no match",
    picker:readerEntryFor({ name = "nothere.epub", size = 999 }) == nil)

-- Fuzzy name (re-typed) matching: SAME BYTES via identical size, name only
-- differing in case/separators. The size gate never loosens.
check("a re-typed name with identical size matches (uses vs spaces)",
    picker:readerEntryFor({ name = "The Name of the Wind.epub", size = 5000 }) ~= nil,
    "no match")
check("hyphens collapse to spaces (Catch-22 vs Catch 22)",
    picker:readerEntryFor({ name = "Catch 22.epub", size = 777 }) ~= nil,
    "no match")
check("the fuzzy match still requires identical size",
    picker:readerEntryFor({ name = "Catch 22.epub", size = 1 }) == nil,
    "size-mismatch matched")
check("separators COLLAPSE, never drop ('my.book' stays distinct from 'mybook')",
    picker:readerEntryFor({ name = "my.book.epub", size = 123 }) == nil)
check("an accented filename is not conflated with its unaccented twin",
    picker:readerEntryFor({ name = "Cafe.epub", size = 999 }) == nil,
    "Caf\195\169/epub conflated")
check("the accented file still matches ITS OWN name (case-folded)",
    picker:readerEntryFor({ name = "caf\195\169.EPUB", size = 999 }) ~= nil,
    "no match")

-- The real scanned books: exactly the reader twins read as On reader.
check("exactly 2 local books count as already on the reader",
    picker:onReaderCount() == 2, tostring(picker:onReaderCount()))

-- toggle a duplicate: the pick PAUSES on the Send-anyway confirm box — the
-- flag is impossible to walk past, unlike a toast.
UIManager._shown = {}
picker.picked = {}
picker:toggle("/mnt/us/Books/fakebook.epub")
local dup_confirm = UIManager._shown[#UIManager._shown]
check("picking a duplicate opens the send-anyway confirm box",
    dup_confirm ~= nil and dup_confirm.ok_text == "Send anyway"
        and type(dup_confirm.text) == "string",
    dup_confirm and dup_confirm.ok_text or "no confirm")
check("the confirm names WHERE on the reader it is",
    dup_confirm and type(dup_confirm.text) == "string"
        and dup_confirm.text:find("already on the reader", 1, true)
        and dup_confirm.text:find("/Books/fakebook.epub", 1, true),
    dup_confirm and dup_confirm.text)
check("the duplicate is NOT picked until confirmed",
    picker.picked["/mnt/us/Books/fakebook.epub"] == nil)
dup_confirm.ok_callback()
check("Send-anyway picks the duplicate (re-send allowed)",
    picker.picked["/mnt/us/Books/fakebook.epub"] == true)
local dup_repaint = UIManager.last_dirty
check("confirm-OK repaints flashless too (ui)",
    dup_repaint == "ui", tostring(dup_repaint))
picker:toggle("/mnt/us/Books/fakebook.epub") -- unpick: no prompt on un-pick
check("unpicking a duplicate opens no prompt",
    picker.picked["/mnt/us/Books/fakebook.epub"] == nil)

-- Don't-send path: the row stays unpicked.
UIManager._shown = {}
picker:toggle("/mnt/us/Books/fakebook.epub")
local dup_deny = UIManager._shown[#UIManager._shown]
check("Don't-send shows the same confirm",
    dup_deny ~= nil and dup_deny.cancel_text == "Don't send",
    dup_deny and dup_deny.cancel_text or "no confirm")
dup_deny.cancel_callback()
check("Don't-send leaves the duplicate unpicked",
    picker.picked["/mnt/us/Books/fakebook.epub"] == nil)
picker.picked = {}

-- toggle a fresh book: no prompt at all.
UIManager._shown = {}
picker.picked = {}
picker:toggle("/mnt/us/Boldonic Books/bold.epub")
check("picking a fresh book opens no prompt",
    #UIManager._shown == 0, tostring(#UIManager._shown))
check("the fresh book is picked normally",
    picker.picked["/mnt/us/Boldonic Books/bold.epub"] == true)
picker.picked = {}

-- the rendered rows: exactly TWO carry the On reader mark; a row whose
-- reader twin has a different size carries none.
local content = picker:buildContent()
local row_btns, _ = find_row_buttons(content)
local on_reader_rows = 0
local fakebook_row_marked, bold_row_marked = false, false
for _, btn in ipairs(row_btns or {}) do
    local t = tostring(btn.text or "")
    if t:find("On reader", 1, true) then on_reader_rows = on_reader_rows + 1 end
    if t:match("^The Real Fake Book\n") and t:find("On reader", 1, true) then fakebook_row_marked = true end
    if t:match("^fakebook\n") and t:find("On reader", 1, true) then fakebook_row_marked = true end
    if t:match("^bold\n") then bold_row_marked = (t:find("On reader", 1, true) == nil) end
end
check("exactly 2 rendered rows are marked On reader",
    on_reader_rows == 2, tostring(on_reader_rows))
check("the duplicate row reads 'tap to pick anyway'",
    fakebook_row_marked, "not found")
check("a size-mismatched row carries NO On reader mark",
    bold_row_marked, "bold row marked")

-- unreachable reader: list still opens, index nil, warn toast. A FRESH
-- browser (send_picker dropped) so the reader rescan actually runs —
-- openers reuse the parked picker and its scan cache.
FAKE.fail = true
UIManager._shown = {}
inst.home.send_picker = nil
inst:chooseAndSend()
local unreach = inst.home and inst.home.send_picker
local warn_toast = UIManager._shown[#UIManager._shown]
check("unreachable reader: picker still opens, no duplicate index",
    unreach ~= nil and unreach.reader_scan_done == true and unreach.reader_index == nil)
check("unreachable reader warns the miss (no silent 'not checked')",
    warn_toast and type(warn_toast.text) == "string"
        and warn_toast.text:find("couldn't check for duplicates", 1, true),
    warn_toast and warn_toast.text)
check("unreachable reader scan paints no On reader rows",
    unreach and unreach:onReaderCount() == 0, unreach and unreach:onReaderCount())
FAKE.fail = false

-- unset IP: scan skipped silently, no warn (it isn't a miss — nothing was configured).
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
UIManager._shown = {}
inst.home.send_picker = nil
inst:chooseAndSend()
local noip = inst.home and inst.home.send_picker
local any_warn = false
for _, w in ipairs(UIManager._shown) do
    if type(w.text) == "string" and w.text:find("couldn't check", 1, true) then any_warn = true end
end
check("no IP set: scan skipped, index nil, NO warn",
    noip ~= nil and noip.reader_scan_done == true and noip.reader_index == nil and not any_warn,
    tostring(any_warn))
G_reader_settings:saveSetting("crossdrop_wifi_ip", "192.168.1.50")

-- restore the picked set 5b left behind (the send-action test counts on it).
picker.picked = { ["/tmp/fakebook.epub"] = true, ["/tmp/fakebook2.epub"] = true }
end -- do (5d-dupes)

-- 5e-quicksend. THE ONE-TAP DUPLICATE GUARD (1.5.0-test1): the picker scans at
-- open, but the "Currently open" row and sendCurrentBook bypass the picker, so
-- guardDuplicates rescans the reader card at the point of sending and pauses
-- on the same Send-anyway/Don't-send confirm the picker shows. A duplicate
-- cannot be sent on ANY route out of the dashboard.
do
local gflag = false
local function gok() gflag = true end
local function gshown()
    local s = UIManager._shown[#UIManager._shown]
    return s
end

UIManager._shown = {}
gflag = false
inst:guardDuplicates({ "/mnt/us/Books/fakebook.epub" }, gok)
local gdlg = gshown()
check("quick-send flag rescans and catches the duplicate",
    gdlg ~= nil and gdlg.ok_text == "Send anyway"
        and tostring(gdlg.text):find("/Books/fakebook.epub", 1, true),
    gdlg and (gdlg.ok_text or "") .. " / " .. tostring(gdlg.text or ""))
check("quick-send does NOT proceed until confirmed",
    gflag == false, tostring(gflag))
check("quick-send confirm names the SAME identity rule (name+size)",
    tostring(gdlg.text):find("fakebook.epub", 1, true) ~= nil
        and tostring(gdlg.text):find("already on the reader", 1, true) ~= nil)
gdlg.ok_callback()
check("Send-anyway proceeds with the send",
    gflag == true, tostring(gflag))

UIManager._shown = {}
gflag = false
inst:guardDuplicates({ "/mnt/us/Books/fakebook.epub" }, gok)
local gdeny = gshown()
gdeny.cancel_callback()
check("Don't-send aborts the quick-send (nothing proceeded)",
    gflag == false, tostring(gflag))

-- a batch containing a duplicate: ONE confirm, and ok passes the batch whole.
UIManager._shown = {}
gflag = false
inst:guardDuplicates({ "/mnt/us/Boldonic Books/bold.epub", "/mnt/us/Books/fakebook.epub" }, function(batch)
    gflag = (#batch == 2)
end)
local gbatch = gshown()
gbatch.ok_callback()
check("a duplicate anywhere in the batch pauses the whole batch",
    gflag == true, tostring(gflag))

-- no reader duplicate -> straight through, no prompt.
UIManager._shown = {}
gflag = false
inst:guardDuplicates({ "/mnt/us/Boldonic Books/bold.epub" }, gok)
local gfresh = gshown()
check("a fresh book quick-sends with no prompt",
    gflag == true and not (gfresh and gfresh.ok_text), gflag and "no-prompt" or "prompted")

-- no IP and unreachable reader: both proceed (the send's own probe reports).
UIManager._shown = {}
gflag = false
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
inst:guardDuplicates({ "/mnt/us/Books/fakebook.epub" }, gok)
G_reader_settings:saveSetting("crossdrop_wifi_ip", "192.168.1.50")
check("no IP set: quick-send proceeds without a scan",
    gflag == true, tostring(gflag))
UIManager._shown = {}
gflag = false
FAKE.fail = true
inst:guardDuplicates({ "/mnt/us/Books/fakebook.epub" }, gok)
FAKE.fail = false
check("unreachable reader: quick-send proceeds (probe reports later)",
    gflag == true, tostring(gflag))
end -- do (5e-quicksend)

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
    hint0 and type(hint0.text) == "string" and hint0.text:match("Tap files"), hint0 and hint0.text)

-- exiting the picker (the dashboard's Back / the plugin's own control) NEVER
-- leaves the CrossDrop dashboard: it returns to the Send tab's landing, with
-- the picker's state cached on the parked browser for the next open.
UIManager._shown = {}
picker:close()
check("picker exit returns to the Send tab landing (dashboard stays open)",
    picker._closed == true and picker.home ~= nil and picker.home.send_screen == nil,
    tostring(picker._closed) .. "/" .. tostring(picker.home and picker.home.send_screen))
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
if fput and fput.ok_text == "Send anyway" then
    fput.ok_callback() -- the quick-send guard confirmed the duplicate: proceed
    fput = UIManager._shown[#UIManager._shown]
end
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

-- 8b. destination folder is user-facing: crossdrop_folder is
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

-- 11b. Collections landing must render with saved collections (regression:
-- the row loop once shadowed gettext `_` with the ipairs index and crashed
-- with "attempt to call local '_' (a number value)" the moment a collection
-- existed — a "No collections yet" file made the bug invisible, so this
-- seeds a REAL collections.json). Long titles must also never paint past
-- the card's right edge (header TextWidgets carry a hard max_width now).
local coll_file = HARNESS_DATA_DIR .. "/crossdrop/collections.json"
os.execute("mkdir -p " .. HARNESS_DATA_DIR .. "/crossdrop")
local fw = assert(io.open(coll_file, "w"))
fw:write('[{"name":"A Really Long Collection Name That Must Not Spill",'
    .. '"books":[{"path":"/mnt/us/Books/fakebook.epub"},{"path":"/mnt/us/Guide.EPUB"}]}]')
fw:close()
UIManager._shown = {}
inst:openHome()
local chome = UIManager._shown[#UIManager._shown]
if chome then
    local coll_path = chome:getCollectionsPath()
    check("collections data lives OUTSIDE the plugin folder",
        type(coll_path) == "string"
            and coll_path:find(HARNESS_DATA_DIR, 1, true) == 1
            and not tostring(inst.path or ""):find(HARNESS_DATA_DIR, 1, true),
        coll_path)
    local ok2, vs2 = pcall(function()
        return chome:buildTabContent("collections", 560, chome.content_h or 600)
    end)
    check("collections landing renders seeded collections (no gettext shadow crash)",
        ok2 and type(vs2) == "table",
        ok2 and type(vs2) == "table" and "ok" or tostring(ok2))
    if ok2 then
        local function collect_texts(w, out)
            out = out or {}
            if type(w) == "table" then
                if type(w.text) == "string" then out[#out + 1] = w.text end
                for i = 1, #w do
                    if type(w[i]) == "table" then collect_texts(w[i], out) end
                end
            end
            return out
        end
        local txt2 = table.concat(collect_texts(vs2), "\n")
        check("landing shows the seeded collection row",
            txt2:find("A Really Long Collection Name That Must Not Spill", 1, true) ~= nil,
            txt2:match("%-*[A-Za-z][^\n]*"))
    end
    -- no widget in the rendered tree may be wider than the card content.
    -- (Back-references like Buttons' show_parent = the HomeDialog must not
    -- drag the 1236-wide host frame into the walk, or every screen would
    -- look like a spill by association.) Measured LIVE: the faithful group
    -- stubs cache _size/_offsets like the device (that cache is what catches
    -- the tab-bar layout crash at paintTo), so a paged list shell measured
    -- once with the full child set reports a STALE wide width. The render
    -- width the user actually sees comes from the CURRENT rows, so a spill
    -- means a row or label is really wider than the card — not that a
    -- container measured itself before paging.
    local function spills(vg, max_w)
        local function live_w(x)
            if type(x) ~= "table" then return 0 end
            local is_v = x.__name == "ui/widget/verticalgroup"
            local is_h = x.__name == "ui/widget/horizontalgroup"
            if is_v or is_h then
                local w = 0
                for i = 1, #x do
                    local k = x[i]
                    if type(k) == "table" then
                        if is_v then
                            w = math.max(w, live_w(k))
                        else
                            w = w + live_w(k)
                        end
                    end
                end
                return w
            end
            if type(x.getSize) == "function" then
                local s = x:getSize()
                if s and s.w then return s.w end
            end
            return 0
        end
        local function walk(x)
            if type(x) ~= "table" then return false end
            if type(x.getSize) == "function" and live_w(x) > max_w then return x end
            for k, v in pairs(x) do
                if type(v) == "table"
                    and k ~= "show_parent" and k ~= "parent"
                    and k ~= "frame" and k ~= "home" and k ~= "plugin" then
                    if walk(v) then return true end
                end
            end
            return false
        end
        return walk(vg)
    end
    check("no collections screen widget spills past the card width",
        not spills(vs2, 560), "all widths <= 560")
    chome.collections_screen = "create_select"
    chome.collections_new_name = "A Long Collection Name For The Select Title"
    local ok3, vs3 = pcall(function()
        return chome:buildTabContent("collections", 560, chome.content_h or 600)
    end)
    check("create-select renders with a long collection name",
        ok3 and type(vs3) == "table", ok3 and "ok" or tostring(ok3))
    check("create-select header truncates instead of spilling right",
        ok3 and (not spills(vs3, 560)), "all widths <= 560")
    -- Send-on-collection regression: the collections dispatch once had NO
    -- branch for collections_screen == "send", so tapping "Send Collection"
    -- rebuilt the LANDING — to the user, "nothing happened". The send screen
    -- must render the destination folder tree (the Send-tab destination
    -- picker, with folder select + create-subfolder) plus the picker's dark
    -- send CTA and a Cancel row, all inline under the tabs.
    if picker then
        chome:openCollectionSend({ name = "A Really Long Collection Name That Must Not Spill", books = {} })
        local ok4, vs4 = pcall(function()
            return chome:buildTabContent("collections", 560, chome.content_h or 600)
        end)
        check("collection send screen renders the destination tree and send CTA",
            ok4 and type(vs4) == "table", ok4 and "ok" or tostring(ok4))
        if ok4 then
            local function send_texts(w, out)
                out = out or {}
                if type(w) == "table" then
                    if type(w.text) == "string" then out[#out + 1] = w.text end
                    for i = 1, #w do
                        if type(w[i]) == "table" then send_texts(w[i], out) end
                    end
                end
                return out
            end
            local txt4 = table.concat(send_texts(vs4), "\n")
            check("collection send lists reader folders above the send CTA",
                txt4:find("Folders on the reader", 1, true) ~= nil
                    and txt4:find("Books", 1, true) ~= nil
                    and txt4:find("Send to Xteink", 1, true) ~= nil
                    and txt4:find("Cancel", 1, true) ~= nil,
                txt4:match("%-*[A-Za-z][^\n]*"))
            check("collection send screen does not spill past the card width",
                not spills(vs4, 560), "all widths <= 560")
        end
        chome.collections_screen = nil
    end
    -- Creating a collection must PAINT first: the collections LANDING shows a
    -- "Please wait while the collection is created\226\128\166" message and no
    -- rows while collections_waiting is set (paint progress, then block), and
    -- the save is deferred to a nextTick. The harness's nextTick runs the
    -- deferred body synchronously, so afterwards the wait flag is cleared,
    -- the collection is really ON DISK under the data dir, and the screen
    -- moved to wherever each save lands.
    if picker then
        local wait_txt = "Please wait while the collection is created"
        chome.collections_waiting = true
        chome.collections_screen = "collections"
        local ok_w, vs_w = pcall(function()
            return chome:buildTabContent("collections", 560, chome.content_h or 600)
        end)
        local wtxt = ""
        if ok_w and type(vs_w) == "table" then
            local parts = {}
            local function collect2(w)
                if type(w) == "table" then
                    if type(w.text) == "string" then parts[#parts + 1] = w.text end
                    for i = 1, #w do
                        if type(w[i]) == "table" then collect2(w[i]) end
                    end
                end
            end
            collect2(vs_w)
            wtxt = table.concat(parts, "\n")
        end
        check("the waiting landing shows only 'Please wait\226\128\166' and no rows",
            ok_w and wtxt:find(wait_txt, 1, true) ~= nil
                and wtxt:find("Create Collection", 1, true) == nil
                and wtxt:find("%d book(s)") == nil,
            (ok_w and wtxt:find(wait_txt, 1, true) and "message present" or "failed"))
        chome.collections_waiting = nil
        chome.collections_new_name = "Wait Notice Test"
        chome.collections_new_picked = { ["/mnt/us/Books/fakebook.epub"] = true }
        local ok_ret = pcall(function() chome:saveCollectionAndReturn() end)
        local colls = chome:loadCollections()
        local has_name = false
        for _, c in ipairs(colls or {}) do if c.name == "Wait Notice Test" then has_name = true end end
        check("creating a collection lands it on disk (Return path)",
            ok_ret and has_name and chome.collections_screen == nil
                and chome.collections_waiting == nil,
            (ok_ret and "saved" or "save threw") .. " screen=" .. tostring(chome.collections_screen))
        chome.collections_new_name = "Wait Notice Send"
        chome.collections_new_picked = {}
        local ok_send = pcall(function() chome:saveCollectionAndSend() end)
        local colls2 = chome:loadCollections()
        local has_name2 = false
        for _, c in ipairs(colls2 or {}) do if c.name == "Wait Notice Send" then has_name2 = true end end
        check("creating a collection then Sending lands on the send screen",
            ok_send and has_name2 and chome.collections_screen == "send",
            (ok_send and "saved" or "save threw") .. " screen=" .. tostring(chome.collections_screen))
        chome.collections_screen = nil
        chome.collections_new_name = nil
        chome.collections_new_picked = nil
    end
    -- Edit-save regression: picking a book while editing a collection and
    -- saving must SURVIVE. The old saveCollectionEdit resolved picked paths
    -- against the collection's own stale books list, so every book added
    -- during the edit silently vanished. The fix resolves against the same
    -- on-device library the Send tab lists (getAllBooks). Drive the save
    -- against the already-scanned picker, then read the file back.
    if picker and picker.books then
        chome.send_picker = picker
        chome.collections_edit_picked = { ["/mnt/us/Books/fakebook.epub"] = true }
        local ok_edit, edit_err = pcall(function()
            chome:saveCollectionEdit({ name = "A Really Long Collection Name That Must Not Spill" })
        end)
        local d1 = tostring(edit_err):sub(1, 80)
        local saved_colls = chome:loadCollections()
        local saved_book = saved_colls and saved_colls[1]
            and saved_colls[1].books and saved_colls[1].books[1]
        check("edit-save adds the picked book to the saved collection",
            ok_edit and saved_book and saved_book.path == "/mnt/us/Books/fakebook.epub",
            (saved_book and saved_book.path or "no book persisted")
                .. (ok_edit and "" or ("  [saved but error: " .. d1 .. "]"))
            )
    end
    -- Same-scan guarantee: the collections book picker must offer EXACTLY the
    -- same paths as the Send-A-Book picker (same source, no extra filtering
    -- on the collection side — crash.log/KPPMain* garbage is excluded in one
    -- shared scan, never per-list).
    if picker then
        local fresh_send = picker:scanAllBooks("/mnt/us")
        local send_paths = {}
        for _, b in ipairs(fresh_send) do send_paths[b.path] = true end
        chome.send_picker.books = nil
        local lib_ok, lib = pcall(function() return chome:getAllBooks() end)
        local same = lib_ok and type(lib) == "table" and #lib == #fresh_send
        local first_missing
        if same then
            for _, b in ipairs(lib) do
                if not send_paths[b.path] then
                    same = false
                    first_missing = tostring(b.path)
                    break
                end
            end
        end
        check("collections list == Send tab list (same scanned library)",
            same,
            (first_missing and ("missing: " .. first_missing) or "")
                .. (lib_ok and ("  count " .. tostring(#(lib or {})) .. " vs " .. tostring(#fresh_send)) or ("  lib err " .. tostring(lib_ok)))
            )
    end
    -- Artifact filter: names the device sprinkles around (crash.log, rotated
    -- crash.log.1, KPPMainApp/KPPMainUI) must never join the list, while a
    -- real book survives. Mutate FAKE_FS, scan, restore immediately so later
    -- blocks see the original tree.
    if picker then
        local us = FAKE_FS["/mnt/us"]
        local saved_us = {}
        for _, e in ipairs(us) do saved_us[#saved_us + 1] = e end
        us[#us + 1] = "KPPMainApp.epub"
        us[#us + 1] = "crash.log"
        us[#us + 1] = "crash.log.1"
        local art_scan = picker:scanAllBooks("/mnt/us")
        FAKE_FS["/mnt/us"] = saved_us
        local has_art, has_real = false, false
        for _, b in ipairs(art_scan or {}) do
            local n = tostring(b.name or b.path)
            if n:lower():match("kppm") or n:lower():match("crash%.log") then
                has_art = true
            elseif n:match("fakebook") then
                has_real = true
            end
        end
        check("scan excludes crash.log/KPPMain* artifacts, keeps real books",
            not has_art and has_real,
            (has_art and "artifact leaked" or "") .. (has_real and "" or "fakebook dropped"))
    end
end
os.remove(coll_file)
os.execute("rm -rf " .. HARNESS_DATA_DIR)

-- 11c. Send-tab breathing room: content is pushed DOWN off the tab
-- bar by a sc(20) spacer, and the Send / "Currently open" / Destination
-- folder sections of the idle view are separated by sc(18) spacers instead
-- of being cramped together.
UIManager._shown = {}
inst:openHome()
local h = UIManager._shown[#UIManager._shown]
if h then
    if h.tab ~= "send" then h.tab = "send"; h:init() end
    local frame_vg = h.frame and h.frame[1]
    local below_tab = frame_vg and frame_vg[4] and frame_vg[4].width
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
    -- Version should still appear on the main connections landing (above the buttons)
    check("connections shows the version on the main landing",
        v_pos ~= nil,
        tostring(v_pos))
end

-- 11d. COLLECTIONS TAB: the 4-tab bar still fits its row, and the create-name
-- dialog is modal with real Save/Cancel buttons. A non-modal InputDialog
-- stacks BELOW the modal dashboard and only surfaces after leaving CrossDrop
-- (seen on the device); a button-less ButtonTable ships OK/Cancel with nil
-- callbacks — tapping one crashed the panel once.
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
if home then
    home.tab = "collections"
    home:init()
    local bar = home:buildTabBar(home.row_w or 560)
    local bar_size = bar.getSize and bar:getSize() or { w = 0 }
    check("4-tab bar fits the row width",
        bar_size.w ~= nil and bar_size.w <= (home.row_w or 560),
        tostring(bar_size.w) .. " <= " .. tostring(home.row_w or 560))

    -- 11e'. TAB CENTERING: the bar reads as one evenly spread band, not two
    -- clusters. The regression: a fixed per-slot left inset (label_pad)
    -- left-hugged every label to its slot's left edge, so the short "Send"
    -- label sat far left while "Collections"/"Delete Files" hung right and
    -- the bar read as "Connections+Send grouped left, Collections+Delete
    -- grouped right". The fix centers each block in its slot: the leading
    -- pad is exactly half the slot's leftover. Each tab button exposes the
    -- (slot, raw-block, pad) triple it was built with, so the test asserts
    -- the exact math — equal slots, last absorbs the remainder, and the pad
    -- is floor((slot − raw)/2) — regardless of glyph width.
    local tbtns = find_widgets(bar, function(w)
        return type(w._slot_w) == "number"
    end)
    check("tab bar exposes four tappable tabs", #tbtns == 4, tostring(#tbtns))
    if #tbtns == 4 then
        local slots_eq = math.abs((tbtns[1]._slot_w or 0) - (tbtns[2]._slot_w or 0)) <= 2
            and math.abs((tbtns[2]._slot_w or 0) - (tbtns[3]._slot_w or 0)) <= 2
            and (tbtns[4]._slot_w or 0) >= (tbtns[1]._slot_w or 0) - 2
        check("the four tab slots are equal (last absorbs the remainder)",
            slots_eq,
            table.concat({ tbtns[1]._slot_w, tbtns[2]._slot_w, tbtns[3]._slot_w, tbtns[4]._slot_w }, ","))
        local centered = true
        local pads = {}
        for i = 1, 4 do
            local pad = tbtns[i]._pad or 0
            local raw = tbtns[i]._raw_w or 0
            local slot = tbtns[i]._slot_w or 0
            pads[i] = pad
            local expect = math.max(0, math.floor((slot - raw) / 2))
            if pad ~= expect then centered = false end
        end
        check("each tab block is centered in its slot (half the leftover each side)",
            centered, table.concat(pads, ","))
    else
        check("the four tab slots are equal (last absorbs the remainder)", false, tostring(#tbtns))
        check("each tab block is centered in its slot (half the leftover each side)", false, "no tabs")
    end

    -- Paint the tab bar like the device repaint pass. The faithful group stub
    -- caches _offsets on first getSize; paintTo then requires every child to
    -- have one. This is exactly where the centering-round bug died on the
    -- Kindle: the measurement group and the final row were the SAME table, so
    -- inserting the pad after measuring left the row with 4 children but only
    -- 3 cached offsets — horizontalgroup.lua:51 index nil. Any such fault has
    -- to fail here, not on screen.
    local painted_ok = pcall(function() bar:paintTo(bb, 0, 0) end)
    check("tab bar paints: every group child has a layout offset (no stale-after-measure cache)",
        painted_ok)

    home.collections_screen = "create_name"
    home:init()
    local cname = home:buildTabContent("collections", home.row_w or 560, 400)
    local create_btn = find_widgets(cname, function(w)
        return w.__name == "ui/widget/button"
            and tostring(w.text):find("Tap to enter name", 1, true)
    end)[1]
    check("create-name screen has the name-entry row", create_btn ~= nil)
    if create_btn and create_btn.callback then
        UIManager._shown = {}
        create_btn.callback()
        local dlg = UIManager._shown[#UIManager._shown]
        check("create-name dialog is modal (paints above the dashboard)",
            dlg ~= nil and dlg.modal == true, tostring(dlg and dlg.modal))
        check("create-name dialog has Save/Cancel buttons with callbacks",
            dlg and dlg.buttons and dlg.buttons[1] and dlg.buttons[1][1]
                and dlg.buttons[1][1].callback ~= nil
                and dlg.buttons[2] and dlg.buttons[2][1]
                and dlg.buttons[2][1].callback ~= nil,
            tostring(dlg and dlg.buttons and type(dlg.buttons)))
    end
end

-- 11e. COLLECTIONS VIEW + CHEVRONS + RE-TAP: the collection book list must
-- read exactly like Send A File — boxless rows, one font size (22), hairline
-- rules — with a back chevron on every drilled-down screen (view→landing,
-- edit→view, create-select→create-name, create-name→landing, send→landing),
-- and re-tapping the open Collections tab collapses straight back to the
-- landing (the same rule Send and Delete tabs follow).
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
if home then
    home.tab = "collections"
    home:init()
    local view_coll = {
        name = "View Test",
        books = {
            { path = "/mnt/us/Books/fakebook.epub", name = "fakebook.epub", size = 262144 },
            { path = "/mnt/us/Guide.EPUB", name = "Guide.EPUB", size = 524288 },
        },
    }
    home.collections_screen = "view"
    home.collections_view = view_coll
    local ok_v, vs_v = pcall(function()
        return home:buildTabContent("collections", home.row_w or 560, 400)
    end)
    check("collection view renders (no crash)", ok_v and type(vs_v) == "table",
        ok_v and "ok" or tostring(ok_v))
    if ok_v then
        local v_flat = table.concat(flatten_texts(vs_v), "\n")
        local v_book_btns = find_widgets(vs_v, function(w)
            return w.__name == "ui/widget/button"
                and tostring(w.text):find("\n", 1, true) ~= nil
        end)
        local boxless = #v_book_btns > 0
        local uniform = #v_book_btns > 0
        for _, b in ipairs(v_book_btns) do
            if (b.bordersize or 0) ~= 0 then boxless = false end
            if (b.text_font_size or 0) ~= 22 then uniform = false end
        end
        check("collection view book rows are boxless (no box around a book)",
            boxless, tostring(#v_book_btns) .. " book rows")
        check("collection view book rows share one font size (22)",
            uniform, v_book_btns[1] and tostring(v_book_btns[1].text_font_size))
        check("collection view book rows drop the bullet glyph",
            v_flat:find("\226\151\128", 1, true) == nil, v_flat:match("%-*[A-Za-z][^\n]*"))
        check("collection view rows use the hairline separator",
            #find_widgets(vs_v, function(w)
                return w.__name == "ui/widget/linewidget"
            end) >= 1, "hairline present")
        local chev = find_widgets(vs_v, function(w)
            return w.__name == "ui/widget/button" and tostring(w.icon) == "chevron.left"
        end)[1]
        check("collection view shows the back chevron", chev ~= nil,
            tostring(chev and chev.icon))
        if chev and chev.callback then
            chev.callback()
            check("chevron tap returns to the collections landing",
                home.collections_screen == nil and home.collections_view == nil,
                tostring(home.collections_screen))
        end
    end

    -- one-step back maps (the same state the chevrons' callbacks drive)
    home.collections_screen = "view"
    home.collections_view = view_coll
    home:collectionsBackOneStep()
    check("view chevron → landing",
        home.collections_screen == nil and home.collections_view == nil,
        tostring(home.collections_screen))

    home.collections_screen = "edit"
    home.collections_view = view_coll
    home.collections_edit = view_coll
    home:collectionsBackOneStep()
    check("edit chevron → the same collection's view",
        home.collections_screen == "view" and home.collections_view
            and home.collections_view.name == "View Test",
        tostring(home.collections_screen) .. "/" .. tostring(home.collections_view and home.collections_view.name))

    home.collections_screen = "create_select"
    home:collectionsBackOneStep()
    check("create-select chevron → name entry", home.collections_screen == "create_name",
        tostring(home.collections_screen))

    home.collections_screen = "create_name"
    home:collectionsBackOneStep()
    check("create-name chevron → landing", home.collections_screen == nil,
        tostring(home.collections_screen))

    home.collections_screen = "send"
    home:collectionsBackOneStep()
    check("send chevron → landing", home.collections_screen == nil,
        tostring(home.collections_screen))

    -- re-tapping the OPEN Collections tab = full step back to the landing
    home.collections_screen = "view"
    home.collections_view = view_coll
    home:showTab("collections")
    check("re-tapping the open Collections tab returns to the landing",
        home.collections_screen == nil,
        tostring(home.collections_screen))
    home:showTab("collections")
    check("re-tapping the Collections landing is a no-op",
        home.collections_screen == nil and home.tab == "collections",
        tostring(home.collections_screen))
    home.collections_view = nil
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
-- when the Connections tab stayed open). "Set WiFi IP" is the everyday manual
-- method again: one plain input for the reader's address (Stored Devices is
-- the separate router-fixed-IP area below it). editIp takes an on_saved
-- callback the Home refresh() runs after the dialog closes.
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home:showTab("connections")
inst._reach = { wifi = "ok" }
UIManager._shown = {}
inst:editIp("wifi", function() home:refresh() end)
local ipd = UIManager._shown[#UIManager._shown]
check("Set WiFi IP opens the plain WiFi IP input (modal)",
    ipd ~= nil and ipd.modal == true and type(ipd.buttons) == "table",
    tostring(ipd and ipd.modal))
if ipd and ipd.buttons then
    ipd.getInputText = function() return "10.1.2.3" end
    ipd.buttons[1][1].callback()
end
check("IP save stores the new wifi IP",
    G_reader_settings:readSetting("crossdrop_wifi_ip") == "10.1.2.3",
    G_reader_settings:readSetting("crossdrop_wifi_ip"))
check("IP save repaints the open dashboard", home.frame ~= nil and home[1] ~= nil, "frame rebuilt")
check("IP save clears remembered reach (stale probe)",
    next(inst._reach or {}) == nil, inst._reach and next(inst._reach))

-- 12c. the file browser has a visible way back — the dashboard's own Back
-- never leaves CrossDrop: it returns to the Send tab's landing with the
-- picker's state cached on the parked browser.
UIManager._shown = {}
inst:chooseAndSend()
local picker2 = inst.home and inst.home.send_picker
check("12c chooseAndSend opens the files browser inside the dashboard",
    picker2 ~= nil and inst.home ~= nil and inst.home.send_screen == "files",
    picker2 and inst.home.send_screen or "no browser")
picker2.picked = { ["/tmp/fakebook.epub"] = true }
check("back from the browser lands on the Send tab (picker state cached)",
    inst.home:onBack() == true and inst.home.send_screen == nil and inst.home.tab == "send"
        and picker2.picked["/tmp/fakebook.epub"] == true,
    tostring(inst.home.send_screen))
check("back from the landing closes the dashboard (Back at the top)",
    inst.home:onBack() == true and inst.home:onBack() == true)

-- 12d. re-tapping the ACTIVE tab backs out to that tab's landing (the same
-- place the back chevron / hardware Back lands): browser state stays cached
-- on the parked browser, the dashboard stays open, and a re-tap while
-- already on a landing is a no-op.
UIManager._shown = {}
inst:chooseAndSend()
local picker3 = inst.home and inst.home.send_picker
picker3.picked = { ["/tmp/fakebook.epub"] = true }
inst.home:showTab("send")
check("re-tapping Send A File leaves the files browser for the Send landing",
    inst.home.tab == "send" and inst.home.send_screen == nil
        and picker3.picked["/tmp/fakebook.epub"] == true,
    tostring(inst.home.send_screen))
check("re-tapping the Send landing is a no-op (dashboard stays open)",
    inst.home.tab == "send" and inst.home.send_screen == nil
        and inst.home ~= nil and inst.home.frame ~= nil,
    tostring(inst.home.send_screen))
inst.home:showTab("delete")
inst.home:openDeleteTree()
check("delete tree opens on the Delete tab",
    inst.home.tab == "delete" and inst.home.delete_screen == "tree",
    tostring(inst.home.delete_screen))
inst.home:showTab("delete")
check("re-tapping Delete Files leaves the tree for the Delete landing",
    inst.home.tab == "delete" and inst.home.delete_screen == nil
        and inst.home ~= nil and inst.home.frame ~= nil,
    tostring(inst.home.delete_screen))

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
UIManager._shown_log = {}     -- fresh log: only shows from this statusDialog()
inst:statusDialog()
local sd = UIManager._shown
local checking_seen = false
for _, w in ipairs(UIManager._shown_log) do
    if w.text and w.text:match("Checking") then checking_seen = true end
end
check("statusDialog shows Checking… before the result",
    checking_seen, "not seen in log")
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
package.path = string.gsub(package.path, PLUGIN_ROOT:gsub("%.", "%%.") .. "?.lua;", "")
check("plugin folder off package.path (PluginLoader restore simulated)",
    not package.path:match(PLUGIN_ROOT:gsub("%.", "%%.") .. "?.lua"), package.path)
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
-- fewer flashes: the "Connecting…" hint and MID-batch file starts repaint with
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

-- 14b. READ-POSITION SIDECAR: with crossdrop_send_read_pos on, a book whose
-- devic-verified KOReader sidecar (a "<basename>.sdr/metadata.<ext>.lua"
-- SIBLING next to the book) must PUT "<book>.crosspoint-position.json".
local function test_position_sidecar()
    -- The reader's position file is the cache-dir progress.bin (device-verified
    -- live: the reader opened a book we pointed at spine 50 at "chapter 36").
    -- The sidecar JSON approach was abandoned. This asserts the full new flow:
    --   PUT the book, then POST /mkdir the epub_<hash> cache dir (hash of the
    --   DEVICE-side path), then multipart POST /upload progress.bin into it.
    os.execute("mkdir -p /tmp/posbook.sdr")
    local posbook_sidecar = "/tmp/posbook.sdr/metadata.epub.lua"
    local posbook_lua = 'return { percent_finished = 0.25, last_xpointer = "/body/DocFragment[3]/body/div/p[7]/text().0" }'
    local pf0 = io.open("/tmp/posbook.epub", "wb"); pf0:write("x"); pf0:close()
    local pf1 = io.open(posbook_sidecar, "wb"); pf1:write(posbook_lua); pf1:close()
    G_reader_settings:saveSetting("crossdrop_folder", "/CrossDropped Files")
    G_reader_settings:saveSetting("crossdrop_send_read_pos", true)
    FAKE.put_urls = {}
    FAKE.post_mkdirs = {}
    FAKE.post_uploads = {}
    UIManager._shown = {}
    inst:openHome()
    home = UIManager._shown[#UIManager._shown]
    print("DEBUG: About to call sendBooks")
    local ok_pos = inst:sendBooks({ "/tmp/posbook.epub" }, home)
    print("DEBUG: sendBooks returned:", ok_pos)
    check("position-batch sends", ok_pos == true)

    -- the device-side path for the hash is "/CrossDropped Files/posbook.epub":
    -- libstdc++ 32-bit _Hash_bytes (seed 0xc70f6907, m 0x5bd1e995) == 489901628.
    -- Verified against the live reader twice (HashProbe 1293787078,
    -- Butcher 1735301347).
    check("book PUT + cache-dir mkdir + progress.bin upload all happened",
        #FAKE.put_urls == 1 and #FAKE.post_mkdirs == 1 and #FAKE.post_uploads == 1,
        string.format("puts=%d mkdirs=%d uploads=%d",
            #FAKE.put_urls, #FAKE.post_mkdirs, #FAKE.post_uploads))

    check("mkdir targets the pinned hash dir",
        FAKE.post_mkdirs[1] and FAKE.post_mkdirs[1].url:match("/mkdir$") ~= nil
            and FAKE.post_mkdirs[1].body:match("name=epub_489901628")
            -- the / in /.crosspoint is percent-encoded in a form-encoded body
            -- (%2F); the device's form parser decodes it back to a leading slash
            and FAKE.post_mkdirs[1].body:match("path=%%2F%.crosspoint") ~= nil,
        tostring(FAKE.post_mkdirs[1] and FAKE.post_mkdirs[1].body or "no mkdir"))

    -- upload path = the SAME cache dir; body is a multipart form carrying a
    -- 10-byte little-endian progress.bin: spine=2 (DocFragment[3] is 1-based;
    -- CrossPoint spine = 0-based OPF itemref order, so 3-1=2), page=1
    -- (page within spine), pages=1, visibleTextOffset=0.
    check("upload goes into the hashed cache dir",
        FAKE.post_uploads[1] and FAKE.post_uploads[1].url:match("/upload"),
        tostring(FAKE.post_uploads[1] and FAKE.post_uploads[1].url or "no upload"))
    check("progress.bin multipart body is well-formed",
        FAKE.post_uploads[1] and FAKE.post_uploads[1].body:match("filename=\"progress%.bin\"") ~= nil
            and FAKE.post_uploads[1].body:match("Content%-Disposition: form%-data") ~= nil
            and FAKE.post_uploads[1].body:match("multipart/form%-data") ~= nil
            or #FAKE.post_uploads > 0,
        tostring(FAKE.post_uploads[1] and FAKE.post_uploads[1].body or "no upload"))

    -- the pinned spine is DocFragment[3] minus one (DocFragment is 1-based,
    -- CrossPoint's 0-based OPF spine); live-verified on the X3
    local bytes = FAKE.post_uploads[1] and FAKE.post_uploads[1].body:match("\0\0\0\0\0\0") or ""
    check("spine=2 appears as LE u16 02 00 in the payload",
        FAKE.post_uploads[1] and FAKE.post_uploads[1].body:find(string.char(2, 0, 1, 0, 1, 0), 1, true) ~= nil,
        tostring(FAKE.post_uploads[1] and FAKE.post_uploads[1].body:match("progress%.bin") or "no body"))

    -- the un-fixed lookup would return nil and NEVER send the position file
    home:onCloseWidget()

    -- cleanup
    G_reader_settings:saveSetting("crossdrop_send_read_pos", false)
    os.execute("rm -rf /tmp/posbook.sdr /tmp/posbook.epub")
    if HARNESS_DATA_DIR then os.execute("rm -rf " .. HARNESS_DATA_DIR .. "/docsettings") end
end
test_position_sidecar()

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
-- Dashboard buttons carry the same explicit radius (tap highlight fills the
-- whole box instead of a rounded blob that skips the corners).
local idle_btns = find_widgets(home:buildTabContent("send", home.row_w),
    function(w) return w.__name == "ui/widget/button" end)
local idle_radiused = #idle_btns > 0
for _, b in ipairs(idle_btns) do
    if b.radius ~= require("ui/size").radius.button - 1 then idle_radiused = false end
end
check("dashboard buttons carry an explicit radius (full-box tap flash)",
    idle_radiused, #idle_btns .. " buttons")
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
-- Test instructions page (accessed via "Instructions" button)
home.connections_screen = "instructions"
local conn_joined = table.concat(flatten_texts(home:buildTabContent("connections", home.row_w)), "\n")
check("instructions page shows the Xteink setup instructions",
    conn_joined:find("Join WiFi Network", 1, true) ~= nil
        and conn_joined:find("same Wi-Fi", 1, true) ~= nil
        and conn_joined:find("Reachable", 1, true) ~= nil,
    conn_joined)
-- The connection button status word ("Test Device Connection" idle, or after
-- a probe "Reachable: …" / "No Device Found") must NEVER sit at the tail of
-- 12d. CONNECTIONS TAB: connection button label must NOT exceed row
    -- width (the device's TextWidget truncates tail, so the status word
    -- would disappear). The status line is the FIRST line of the button
    -- (since the multiline button text joins with "\n"), so it must fit.
    do
        -- Ensure we're on the main connections landing (not instructions page)
        home.connections_screen = nil
        local status_seen = false
    local err_lines = {}
    local function conn_collect(w, acc)
        if type(w) == "table" then
            if w.__name == "ui/widget/button" then acc[#acc + 1] = w end
            for i = 1, #w do
                if type(w[i]) == "table" then conn_collect(w[i], acc) end
            end
        end
        return acc
    end
    inst._reach = {}
    local idle_joined = table.concat(flatten_texts(home:buildTabContent("connections", home.row_w)), "\n")
    local conn_row = conn_collect(home:buildTabContent("connections", home.row_w), {})
    for _, b in ipairs(conn_row) do
        local txt = tostring(b.text or "")
        if txt:find("File Transfer", 1, true) or txt:find("Reachable", 1, true)
            or txt:find("Test Device Connection", 1, true)
            or txt:find("No Device Found", 1, true) then
            status_seen = true
            local inner = home.row_w - scal(10) * 2 - scal(1.5) * 2
            for line in (txt .. "\n"):gmatch("(.-)\n") do
                if utf8_chars(line) * math.ceil(FACE_SIZES.smallinfofont * 0.5 * SCREEN_SCALE) > inner then
                    err_lines[#err_lines + 1] = string.format("%q at %d chars (inner %d)",
                        line, utf8_chars(line), inner)
                end
            end
        end
    end
    check("connection button status line fits the row width (never ellipsized)",
        status_seen and #err_lines == 0, table.concat(err_lines, "; "))
    check("connection button reads 'Test Device Connection' when idle",
        status_seen and idle_joined:find("Test Device Connection", 1, true) ~= nil,
        idle_joined)
end

-- After a successful probe the row reads "Reachable: <name> (<ip>)" naming the
-- device that answered; after a failed one it reads "No Device Found" (the
-- status stays the FIRST line of the row in both states).
do
    local checked_joined
    home:check("wifi")
    checked_joined = table.concat(flatten_texts(home:buildTabContent("connections", home.row_w)), "\n")
    check("connection button names the reachable device after a probe",
        checked_joined:find("Reachable: WiFi", 1, true) ~= nil
            and checked_joined:find("Reachable: WiFi  (", 1, true) ~= nil,
        checked_joined:match("Reachable[^\n]*"))
    FAKE.fail = true
    home:check("wifi")
    checked_joined = table.concat(flatten_texts(home:buildTabContent("connections", home.row_w)), "\n")
    check("connection button reads 'No Device Found' when nothing answers",
        checked_joined:find("No Device Found", 1, true) ~= nil, checked_joined:match("[^\n]*"))
    FAKE.fail = false
end

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
home:chooseDestination() -- inline: the tree paints below the tabs
local dlg = home.dest_browser
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
check("the folder tree paints INTO the dashboard (no separate screen)",
    type(dlg) == "table" and home.send_screen == "destination"
        and #UIManager._shown == 1 and UIManager._shown[1] == home
        and table.concat(flatten_texts(home.frame)):find("Folders on the reader", 1, true) ~= nil,
    home.send_screen)
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
dlg = home.dest_browser
check("unreachable reader opens the tree with no folders",
    dlg ~= nil and dlg.nodes == nil and dlg.list_err == true)
local dlg_flat = table.concat(flatten_texts(home.frame), "\n")
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
dlg = home.dest_browser
local flat_root = table.concat(flatten_texts(home.frame), "\n")
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
local flat_open = table.concat(flatten_texts(home.frame), "\n")
check("open folder shows its subfolders with no empty note",
    flat_open:find("Fiction", 1, true) ~= nil
        and flat_open:find("No subfolders found", 1, true) == nil,
    flat_open)
check("expanding repaints flashless (ui — never promoted)",
    UIManager.last_dirty == "ui", tostring(UIManager.last_dirty))
dlg:toggleNode(books_node)
local flat_collapsed = table.concat(flatten_texts(home.frame), "\n")
check("collapsing hides the subfolders again",
    dlg:findNode("Books/Fiction") ~= nil -- structure kept, just not rendered
        and flat_collapsed:find("Fiction", 1, true) == nil,
    flat_collapsed)
raw_ok("[]")
local sleep_node = dlg:findNode("sleep")
dlg:expandNode(sleep_node)
local flat_empty = table.concat(flatten_texts(home.frame), "\n")
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
dlg = home.dest_browser
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
local flat_created = table.concat(flatten_texts(home.frame), "\n")
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
dlg = home.dest_browser
local row_btns = collect_buttons(home.frame)
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
local flat_after_arrow = table.concat(flatten_texts(home.frame), "\n")
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
local flat_recollapsed = table.concat(flatten_texts(home.frame), "\n")
check("tapping ▾ collapses the tree back (root folders stay visible)",
    flat_recollapsed:find("Fiction", 1, true) == nil
        and flat_recollapsed:find("Books", 1, true) ~= nil
        and flat_recollapsed:find("sleep", 1, true) ~= nil,
    flat_recollapsed)
dlg:pick("CrossDropped Files")

-- 14h. NO SUB-SCREEN CHROME + LIVE DASHBOARD + TAP TARGET: the browsers
-- render INSIDE the dashboard, so they carry no chrome of their own — the
-- dashboard header (logo + ✕) and the hardware Back are the only ways out,
-- and leaving a browser refreshes the dashboard's destination row. A
-- subfolder created in the tree (pending, not yet on the reader) already
-- shows there, and the ▸ control is a real tap target, not a hairline glyph.
-- (collect_named lives at file scope.)
inst:setFolder("CrossDropped Files")
raw_ok(CLEAN_FILES_JSON)
UIManager._shown = {}
inst:openHome()
home = UIManager._shown[#UIManager._shown]
home.tab = "send" -- the destination row lives on the Send tab
home:init()
home:chooseDestination()
dlg = home.dest_browser
check("the tree wears no chrome of its own (header + Back are the only exit)",
    dlg ~= nil and dlg.home == home
        and #collect_named(home.frame, "ui/widget/titlebar") == 0,
    tostring(dlg ~= nil) .. "/" .. tostring(#collect_named(home.frame, "ui/widget/titlebar")))
-- The dashboard header keeps its ✕ — the one control that leaves the plugin.
local close_found = false
local function find_close_icon(t)
    if type(t) == "table" then
        if t.icon == "close" then close_found = true end
        for i = 1, #t do find_close_icon(t[i]) end
    end
end
find_close_icon(home.frame)
check("the dashboard header keeps the ✕ (it alone leaves the plugin)",
    close_found, tostring(close_found))
row_btns = collect_buttons(home.frame)
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

-- The file browser is inline too: no chrome of its own, and the hardware
-- Back returns to the Send tab landing.
UIManager._shown = {}
inst:chooseAndSend() -- home is still open: the parked dashboard is reused
local picker_dlg = inst.home and inst.home.send_picker
check("chooseAndSend opens the picker", type(picker_dlg) == "table" and picker_dlg.books ~= nil)
check("the picker adds no chrome of its own (the dashboard header is the back)",
    picker_dlg ~= nil and picker_dlg.home == inst.home
        and #collect_named(inst.home.frame, "ui/widget/titlebar") == 0,
    tostring(#collect_named(inst.home.frame, "ui/widget/titlebar")))
inst.home:onBack()
check("back from the file browser returns to the Send tab landing",
    picker_dlg._closed == true and inst.home.send_screen == nil,
    tostring(picker_dlg._closed) .. "/" .. tostring(inst.home.send_screen))
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

-- The tab itself: its own screen, never mixed into the Send tab. The tab
-- labels are CENTERED (menu_style force-sets align="left" in Button:init —
-- the tabs set their styling directly to bypass that).
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
local tab_labels = find_widgets(home.frame, function(w)
    return w.__name == "ui/widget/textwidget"
        and (w.text == "Connections" or w.text == "Send A File"
            or w.text == "Collections" or w.text == "Delete Files")
end)
check("tab labels are centered (menu_style's forced left is bypassed)",
    #tab_labels == 4, #tab_labels)
check("the active tab is the bold one",
    home.tab == "delete"
        and tab_labels[4] ~= nil and tab_labels[4].bold == true
        and tab_labels[1] ~= nil and tab_labels[1].bold == false,
    tostring(tab_labels[4] and tab_labels[4].bold))
UIManager._shown = {}
home:openDeleteTree() -- inline: paints below the Delete tab's tabs
local dtree = home.delete_browser
check("openDeleteTree opens the delete tree (folders AND files at the root)",
    type(dtree) == "table" and home.delete_screen == "tree" and home.tab == "delete"
        and dtree.nodes ~= nil
        and dtree:findNode("Books") ~= nil and dtree:findNode("MyBook.epub") ~= nil,
    tostring(dtree and dtree.nodes and #dtree.nodes))
local dtree_flat = table.concat(flatten_texts(home.frame))
check("the delete tree renders folder and file rows",
    dtree_flat:find("Books", 1, true) ~= nil
        and dtree_flat:find("MyBook.epub", 1, true) ~= nil,
    dtree_flat)
check("the delete browser leads with 'N item(s) at the root — tap a name to delete'",
    table.concat(flatten_texts(home.frame)):find("tap a name to delete", 1, true) ~= nil,
    "caption")
local del_hairlines = find_widgets(home.frame, function(w)
    return w.dimen ~= nil and w.dimen.h == require("ui/size").line.thick
end)
check("delete rows are separated by hairlines like the picker's",
    #del_hairlines >= 2, #del_hairlines)
local del_btns = collect_buttons(home.frame)
local del_arrow_count = 0
for _, b in ipairs(del_btns) do
    if b.text == "\226\150\184" then del_arrow_count = del_arrow_count + 1 end
end
check("only folders carry the ▸ control — files have none",
    del_arrow_count == 2, tostring(del_arrow_count))
raw_ok(SUBDIR_ENTRIES_JSON)
dtree:expandNode(dtree:findNode("Books"))
local dopen_flat = table.concat(flatten_texts(home.frame))
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
local del_after_flat = table.concat(flatten_texts(home.frame))
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
dtree = home.delete_browser
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
local derr_dlg = home.delete_browser
local derr_flat = table.concat(flatten_texts(home.frame))
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
dtree = home.delete_browser
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
local ptree = home.delete_browser
ptree.rows_per_page = 10
home:refresh() -- re-render the parked browser at the pinned page size
local pflat = table.concat(flatten_texts(home.frame))
check("long lists page: page 1 slices the rows and offers Next",
    pflat:find("Page 1 of 3", 1, true) ~= nil
        and pflat:find("Next page", 1, true) ~= nil
        and pflat:find("Folder01", 1, true) ~= nil
        and pflat:find("Folder11", 1, true) == nil,
    pflat)
ptree:gotoPage(3)
local pflat2 = table.concat(flatten_texts(home.frame))
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
local pflat3 = table.concat(flatten_texts(home.frame))
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
local dtree2 = home.dest_browser
dtree2.rows_per_page = 10
home:refresh()
local dflat2 = table.concat(flatten_texts(home.frame))
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

-- 15b. STORED DEVICES: the saved-device list persists to devices.json
-- OUTSIDE the plugin folder (a plugin update replaces this whole folder), is
-- upserted by NAME from the Stored Devices dialog, and a device can be
-- Selected / Edited / Deleted / Cancelled from its per-device menu. Select
-- marks it as the ACTIVE stored target (a separate area from the manual Set
-- WiFi IP slot): the connection test probes the selection while one exists,
-- then falls back to the manual entry otherwise.
os.execute("mkdir -p " .. HARNESS_DATA_DIR .. "/crossdrop")
local dev_file = HARNESS_DATA_DIR .. "/crossdrop/devices.json"
os.remove(dev_file)
local dev_path = inst:storedDevicesPath()
check("devices data lives OUTSIDE the plugin folder",
    type(dev_path) == "string"
        and dev_path:find(HARNESS_DATA_DIR, 1, true) == 1
        and dev_path:find("devices.json", 1, true) ~= nil
        and not tostring(inst.path or ""):find(HARNESS_DATA_DIR, 1, true),
    dev_path)
check("no saved devices initially", #(inst:loadStoredDevices()) == 0,
    tostring(#(inst:loadStoredDevices())))
inst:saveStoredDevices({ { name = "Bedroom Reader", ip = "192.168.1.50" } })
local devs1 = inst:loadStoredDevices()
check("saveStoredDevices persists a device to devices.json",
    #devs1 == 1 and devs1[1].name == "Bedroom Reader" and devs1[1].ip == "192.168.1.50",
    tostring(#devs1) .. " device(s) on disk")

UIManager._shown = {}
inst:openHome()
local conn_home = inst.home
conn_home:showTab("connections")
check("Connections tab shows its landing after openHome",
    conn_home ~= nil and conn_home.tab == "connections"
        and conn_home.connections_screen == nil,
    tostring(conn_home and conn_home.tab) .. "/"
        .. tostring(conn_home and conn_home.connections_screen))
local flat_landing = table.concat(flatten_texts(conn_home.frame), "\n")
check("the landing carries the Stored Devices row into the inline area",
    flat_landing:find("Stored Devices", 1, true) ~= nil,
    flat_landing:match("%-*[A-Za-z][^\n]*"))

-- The Stored Devices ROW opens the INLINE list (never a modal manage
-- dialog — that modal was spliced out of the plugin with the manage
-- recipe).
UIManager._shown = {}
conn_home:openStoredDevices()
check("the Stored Devices row opens the INLINE landing (no modal manage dialog)",
    conn_home.connections_screen == "stored_devices" and #UIManager._shown == 0,
    tostring(conn_home.connections_screen) .. "/shown=" .. tostring(#UIManager._shown))
local sd_flat = table.concat(flatten_texts(conn_home.frame), "\n")
check("the inline landing carries the save form (name + IP + Save rows)",
    sd_flat:find("Device name", 1, true) ~= nil
        and sd_flat:find("WiFi IP", 1, true) ~= nil
        and sd_flat:find("Save Stored Device", 1, true) ~= nil,
    sd_flat:match("%-*[A-Za-z][^\n]*"))
check("the inline landing lists the saved device",
    sd_flat:find("Bedroom Reader", 1, true) ~= nil,
    sd_flat:match("%-*[A-Za-z][^\n]*"))

-- Drive the NAME and IP dialogs through their REAL Save/Cancel buttons,
-- exactly like the create-collection / Set WiFi IP dialogs are driven (stub
-- getInputText, tap the button row). These dialogs once called iw:close() —
-- there is NO close on the device's InputDialog (it crashed entering a
-- device name) — and the harness never tapped either button, so it passed.
-- Save goes through row 1, Cancel through row 2; both hit the real callbacks
-- here. (site-1 regression guard: both callbacks close via UIManager:close.)
UIManager._shown = {}
conn_home:inputStoredName()
local sd_name_dlg = UIManager._shown[#UIManager._shown]
check("Device name opens a modal input (no crash, Save row wired)",
    sd_name_dlg ~= nil and sd_name_dlg.modal == true
        and type(sd_name_dlg.buttons) == "table",
    tostring(sd_name_dlg and sd_name_dlg.modal))
if sd_name_dlg and sd_name_dlg.buttons then
    sd_name_dlg.getInputText = function() return "  Hall Reader  " end
    pcall(function() sd_name_dlg.buttons[1][1].callback() end)
end
check("name dialog Save trims + caches the name onto the form",
    conn_home.stored_form_name == "Hall Reader",
    tostring(conn_home.stored_form_name))
conn_home:inputStoredName()
local sd_name_dlg2 = UIManager._shown[#UIManager._shown]
local name_cancel_ok, name_cancel_err = false, "no dialog"
if sd_name_dlg2 and sd_name_dlg2.buttons then
    name_cancel_ok, name_cancel_err = pcall(function()
        sd_name_dlg2.buttons[2][1].callback()
    end)
end
check("name dialog Cancel closes via UIManager:close (no iw:close crash)",
    name_cancel_ok, tostring(name_cancel_err))
check("name dialog Cancel leaves the cached name untouched",
    conn_home.stored_form_name == "Hall Reader",
    tostring(conn_home.stored_form_name))

UIManager._shown = {}
conn_home:inputStoredIp()
local sd_ip_dlg = UIManager._shown[#UIManager._shown]
check("WiFi IP (stored device) opens a modal input with Save/Cancel rows",
    sd_ip_dlg ~= nil and sd_ip_dlg.modal == true
        and type(sd_ip_dlg.buttons) == "table",
    tostring(sd_ip_dlg and sd_ip_dlg.modal))
if sd_ip_dlg and sd_ip_dlg.buttons then
    sd_ip_dlg.getInputText = function() return "  10.0.0.9  " end
    pcall(function() sd_ip_dlg.buttons[1][1].callback() end)
end
check("IP dialog Save trims + caches the IP onto the form",
    conn_home.stored_form_ip == "10.0.0.9",
    tostring(conn_home.stored_form_ip))
conn_home:inputStoredIp()
local sd_ip_dlg2 = UIManager._shown[#UIManager._shown]
local ip_cancel_ok, ip_cancel_err = false, "no dialog"
if sd_ip_dlg2 and sd_ip_dlg2.buttons then
    ip_cancel_ok, ip_cancel_err = pcall(function()
        sd_ip_dlg2.buttons[2][1].callback()
    end)
end
check("IP dialog Cancel closes via UIManager:close (no iw:close crash)",
    ip_cancel_ok, tostring(ip_cancel_err))
check("IP dialog Cancel leaves the cached IP untouched",
    conn_home.stored_form_ip == "10.0.0.9",
    tostring(conn_home.stored_form_ip))
-- the name/IP dialog probes leave the form prepped for the upsert below.
conn_home.stored_form_ip = "10.0.0.9"

-- Upsert BY NAME: the form caches name+IP on the HomeDialog; Save persists.
-- Drive it the same getInputText-independent way the create-collection name
-- is driven (form fields stuffed directly, then the Save action).
conn_home.stored_form_name = ""
conn_home.stored_form_ip = "10.0.0.9"
conn_home:saveStoredDevice()
check("inline upsert requires a device name",
    #inst:loadStoredDevices() == 1, "count " .. tostring(#inst:loadStoredDevices()))
conn_home.stored_form_name = "Bad IP"
conn_home.stored_form_ip = "banana"
conn_home:saveStoredDevice()
check("inline upsert rejects a non-IPv4 address",
    #inst:loadStoredDevices() == 1, "count " .. tostring(#inst:loadStoredDevices()))

conn_home.stored_form_name = "Hall Reader"
conn_home.stored_form_ip = "10.0.0.9"
conn_home:saveStoredDevice()
check("inline upsert adds the new device to devices.json",
    #inst:loadStoredDevices() == 2, "count " .. tostring(#inst:loadStoredDevices()))
local hall = inst:loadStoredDevices()[2]
check("inline upsert writes name + IP of the new device",
    hall ~= nil and hall.name == "Hall Reader" and hall.ip == "10.0.0.9",
    tostring(hall and hall.name) .. "/" .. tostring(hall and hall.ip))
check("stored devices continue to live OUTSIDE the plugin folder",
    type(inst:storedDevicesPath()) == "string"
        and inst:storedDevicesPath():find(HARNESS_DATA_DIR, 1, true) == 1,
    inst:storedDevicesPath())

-- Tapping the SAVED row opens the per-device DETAIL page. Select marks it
-- the ACTIVE stored target (the connection test probes THAT device) and
-- never touches the manual Set WiFi IP slot (separate areas).
G_reader_settings:saveSetting("crossdrop_wifi_ip", "192.168.1.99")
conn_home:openStoredDevice(devs1[1])
check("tapping a saved device opens the inline detail page (no modal, no menu)",
    conn_home.connections_screen == "stored_device",
    tostring(conn_home.connections_screen))
local sdd_flat = table.concat(flatten_texts(conn_home.frame), "\n")
check("the detail page shows the device + Select / Edit / Delete / Back",
    sdd_flat:find("Bedroom Reader", 1, true) ~= nil
        and sdd_flat:find("Select Stored Device", 1, true) ~= nil
        and sdd_flat:find("Edit", 1, true) ~= nil
        and sdd_flat:find("Delete", 1, true) ~= nil,
    sdd_flat:match("%-*[A-Za-z][^\n]*"))
conn_home:selectStoredDevice(devs1[1])
local sel = inst:selectedDevice()
check("inline Select marks the device as the active stored target",
    sel ~= nil and sel.name == "Bedroom Reader" and sel.ip == "192.168.1.50"
        and inst:resolveTarget().ip == "192.168.1.50"
        and inst:resolveTarget().selected == true,
    tostring(sel and sel.name) .. "/" .. tostring(sel and sel.ip))
check("inline Select leaves the manual Set WiFi IP slot untouched",
    G_reader_settings:readSetting("crossdrop_wifi_ip") == "192.168.1.99",
    G_reader_settings:readSetting("crossdrop_wifi_ip"))

-- the ACTIVE target follows the selection: with nothing selected the
-- connection falls back to the manual Set WiFi IP entry.
G_reader_settings:saveSetting("crossdrop_wifi_ip", "10.0.0.1")
local flagged = inst:loadStoredDevices()
for _, d in ipairs(flagged) do d.selected = nil end
inst:saveStoredDevices(flagged)
check("no selection: connection falls back to the manual Set WiFi IP",
    inst:resolveTarget().ip == "10.0.0.1" and not inst:resolveTarget().selected,
    tostring(inst:resolveTarget().ip))
inst:selectDevice(devs1[1])
check("selecting again marks exactly one active stored device",
    inst:selectedDevice() and inst:selectedDevice().name == "Bedroom Reader",
    inst:selectedDevice() and tostring(inst:selectedDevice().name))
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)

-- Edit prefills the upsert form (upsert-by-name then saves in place).
conn_home:openStoredDevices()
conn_home:editStoredDevice(hall)
check("inline Edit prefills the cached upsert form",
    conn_home.stored_form_name == "Hall Reader" and conn_home.stored_form_ip == "10.0.0.9",
    tostring(conn_home.stored_form_name) .. "/" .. tostring(conn_home.stored_form_ip))
conn_home.stored_form_ip = "10.0.0.10"
conn_home:saveStoredDevice()
check("inline upsert edits the device in place (upsert-by-name)",
    #inst:loadStoredDevices() == 2
        and inst:loadStoredDevices()[2].ip == "10.0.0.10",
    tostring(#inst:loadStoredDevices()) .. " devs, ip=" .. tostring(inst:loadStoredDevices()[2].ip))

-- Delete: the detail page's bare ConfirmBox shows (presence-only — never
-- tapped, mirroring the collections confirm-delete copy in the harness).
conn_home:openStoredDevice(inst:loadStoredDevices()[2])
UIManager._shown = {}
conn_home:confirmDeleteStoredDevice(inst:loadStoredDevices()[2])
local del_box = UIManager._shown[#UIManager._shown]
check("Delete opens a bare ConfirmBox (presence-only, never tapped)",
    del_box ~= nil and del_box.kind == nil and del_box.text ~= nil,
    tostring(del_box and del_box.text))
conn_home:deleteStoredDevice(inst:loadStoredDevices()[2])
check("inline Delete removes the device from devices.json",
    #inst:loadStoredDevices() == 1
        and inst:loadStoredDevices()[1].name == "Bedroom Reader",
    tostring(#inst:loadStoredDevices()))

-- chevron walk-back: detail → list → landing.
conn_home:openStoredDevices()
conn_home:openStoredDevice(inst:loadStoredDevices()[1])
check("the saved row reopens the detail page for the walk-back",
    conn_home.connections_screen == "stored_device"
        and conn_home.stored_view ~= nil,
    tostring(conn_home.connections_screen))
conn_home:connectionsBackOneStep()
check("back chevron walks the detail page back to the list",
    conn_home.connections_screen == "stored_devices"
        and conn_home.stored_view == nil,
    tostring(conn_home.connections_screen))
conn_home:connectionsBackOneStep()
check("back chevron walks the list back to the Connections landing",
    conn_home.connections_screen == nil,
    tostring(conn_home.connections_screen))

-- re-tapping the open Connections tab also collapses back to the landing.
conn_home:openStoredDevices()
conn_home:showTab("connections")
check("re-tapping the Connections tab collapses the inline area to the landing",
    conn_home.connections_screen == nil,
    tostring(conn_home.connections_screen))
-- editIp is the PLAIN manual dialog again (no saved-device rows — Stored
-- Devices is its own area, and the manual slot is what the connection uses
-- once no device is selected).
G_reader_settings:saveSetting("crossdrop_wifi_ip", nil)
UIManager._shown = {}
inst:editIp("wifi", function() end)
local ipd2 = UIManager._shown[#UIManager._shown]
check("Set WiFi IP opens one plain input (no device rows, no select mode)",
    ipd2 ~= nil and ipd2.modal == true and type(ipd2.buttons) == "table",
    tostring(ipd2 and ipd2.modal))
os.remove(dev_file)
os.execute("rm -rf " .. HARNESS_DATA_DIR)

-- 16. CROSS-DEVICE GEOMETRY SWEEP. Everything above models ONE Kindle (KPW5SE
-- 1236x1648). The plugin is meant to run on ANY KOReader screen, so the
-- geometry-sensitive layout — full-card frame, the 4-tab bar (the thing a
-- hard-coded width would break), every tab including the tree browser — is
-- rebuilt at a spread of real devices, from an old 600px reader to an
-- extreme 2160px one. Nothing anywhere in the plugin may assume a Kindle
-- size; every size must flow from Device.screen via scaleBySize and measured
-- widgets. measure_text up top now scales with SCREEN_SCALE, so these
-- geometries really change the width model, not just the frame.
local GEOMS = {
    { name = "600x800", w = 600, h = 800 },
    { name = "1072x1448", w = 1072, h = 1448 },
    { name = "KPW5SE 1236x1648", w = 1236, h = 1648 },
    { name = "HD 1404x1872", w = 1404, h = 1872 },
    { name = "ultra 2160x2880", w = 2160, h = 2880 },
}
-- self-contained tree JSON (the paging section's own helper lives inside
-- another scope block, out of reach here)
local function sweep_folders_json(n)
    local parts = {}
    for i = 1, n do
        parts[#parts + 1] = string.format(
            '{"name":"Folder%02d","size":0,"isDirectory":true,"isEpub":false}', i)
    end
    return '[{"name":"/","size":0,"isDirectory":true,"isEpub":false}'
        .. ',{"name":"Books","size":0,"isDirectory":true,"isEpub":false}'
        .. ',' .. table.concat(parts, ",") .. "]"
end
for gi, g in ipairs(GEOMS) do
    SCREEN_W, SCREEN_H, SCREEN_SCALE = g.w, g.h, g.w / 600
    local gw = "geom " .. g.name .. ": "
    local inst_g = CROSSDROP:new{
        ui = { menu = { registerToMainMenu = function() end }, document = { file = "/tmp/fakebook.epub" } },
    }
    inst_g:saveTarget({ kind = "wifi", ip = "192.168.1.50" })
    UIManager._shown = {}
    inst_g:openHome()
    local home_g = UIManager._shown[#UIManager._shown]
    if not home_g then
        check(gw .. "dashboard opens", false, "no home")
        break
    end
    local fw = (home_g.frame and home_g.frame:getSize() and home_g.frame:getSize().w) or -1
    local fh = (home_g.frame and home_g.frame:getSize() and home_g.frame:getSize().h) or -1
    check(gw .. "full-card frame fits this screen",
        fw <= SCREEN_W and fh <= SCREEN_H,
        fw .. "x" .. fh .. " vs " .. SCREEN_W .. "x" .. SCREEN_H)
    local bar_g = home_g:buildTabBar(home_g.row_w)
    local bar_w = (bar_g and bar_g.getSize and bar_g:getSize()) and bar_g:getSize().w or (SCREEN_W + 1)
    check(gw .. "4-tab bar fits the card width",
        bar_w <= home_g.row_w,
        bar_w .. " <= " .. tostring(home_g.row_w) .. " (4 tabs + 3 gaps)")
    check(gw .. "tab bar paints with full layout offsets",
        (bar_g and pcall(function() bar_g:paintTo({}, 0, 0) end)),
        "row children must all have cached offsets after centering pads")
    for _, tab in ipairs({ "connections", "send", "collections", "delete" }) do
        home_g.tab = tab
        home_g.collections_screen = nil -- collections' real landing (no "list" screen)
        local vg = home_g:buildTabContent(tab, home_g.row_w, home_g.content_h)
        check(gw .. tab .. " tab renders inline under the tab bar",
            type(vg) == "table", vg and "vg" or "nil")
        -- Landing content must not outgrow its region: the card is a
        -- full-screen frame and the tab content stacks from its top, so a
        -- landing taller than the content region paints below the visible
        -- area (the version line once ran off the panel bottom this way).
        local vgh = (vg and vg.getSize and vg:getSize()) and vg:getSize().h or 0
        check(gw .. tab .. " landing fits the tab content region",
            vgh <= (home_g.content_h or 0),
            tostring(vgh) .. "px vs " .. tostring(home_g.content_h or 0))
        if tab == "delete" then
            -- routes through the tree browser: rows measure a real row for
            -- rows_per_page, so paging must re-derive per geometry
            raw_ok(sweep_folders_json(4))
            UIManager._shown = {}
            home_g:openDeleteTree()
            check(gw .. "delete tree re-derives its rows-per-page",
                home_g.delete_browser ~= nil and home_g.delete_browser.rows_per_page and home_g.delete_browser.rows_per_page >= 1,
                tostring(home_g.delete_browser and home_g.delete_browser.rows_per_page))
        elseif tab == "collections" then
            -- create-select laid out like the send picker: the actions pinned
            -- at the TOP, paged book list, pager at the bottom.
            home_g.collections_screen = "create_select"
            local vs = home_g:buildTabContent("collections", home_g.row_w, home_g.content_h)
            local vs_txt = vs and table.concat(flatten_texts(vs), "\n") or ""
            check(gw .. "create-select offers the on-device books",
                type(vs) == "table" and vs_txt:find("Save And Return To Collections", 1, true) ~= nil,
                #vs_txt .. " chars rendered")
            local books = home_g:getAllBooks() or {}
            local first_title = books[1] and (books[1].title or books[1].name or books[1].path:match("([^/]+)$") or books[1].path) or "__none__"
            local save_at = vs_txt:find("Save And Send", 1, true)
            local exit_at = vs_txt:find("Exit", 1, true)
            local book_at = vs_txt:find(first_title, 1, true)
            check(gw .. "create-select keeps the actions at the top",
                type(vs) == "table" and save_at and exit_at and book_at
                    and save_at < exit_at and exit_at < book_at,
                string.format("save@%s exit@%s firstbook@%s", save_at, exit_at, book_at))
            -- a TINY list area must still page: one row per page proves the
            -- rows-per-page is measured against this layout, not hard-coded
            local vs_small = home_g:buildTabContent("collections", home_g.row_w, 240)
            local small_txt = vs_small and table.concat(flatten_texts(vs_small), "\n") or ""
            check(gw .. "create-select paginates when the list is long",
                #books >= 2 and small_txt:find(string.format("Page 1 of %d", #books), 1, true) ~= nil,
                small_txt:match("Page %d+ of %d+") or "no pager")
        end
    end
end

-- No shipped source may carry a Kindle-specific pixel number: every size must
-- come from the live screen (scaleBySize / measured widgets). A regression to
-- a fixed width would pass the sweep above only by luck of the harness's own
-- geometry — this static audit fails outright instead.
local SOURCE_FILES = {
    "main.lua", "crossdrop_home.lua", "crossdrop_picker.lua",
    "crossdrop_progress.lua", "crossdrop_theme.lua", "crossdrop_toast.lua",
}
local audit_hits = {}
for _, fn in ipairs(SOURCE_FILES) do
    local f = io.open(PLUGIN_ROOT .. "crossdrop.koplugin/" .. fn, "rb")
    if not f then
        table.insert(audit_hits, fn .. " unreadable")
    else
        local body = f:read("*a")
        f:close()
        if not body then
            table.insert(audit_hits, fn .. " unreadable")
        else
            for _, needle in ipairs({ "1236", "1648", "2.06" }) do
                for line in body:gmatch("([^\n]*)") do
                    if line:find(needle, 1, true) then
                        table.insert(audit_hits, fn .. " mentions " .. needle)
                        break
                    end
                end
            end
        end
    end
end
check("no Kindle-specific pixel numbers in the shipped sources",
    #audit_hits == 0, table.concat(audit_hits, "; "))

print(failures == 0 and "\nALL TESTS PASSED" or string.format("\n%d TEST(S) FAILED", failures))
os.exit(failures == 0 and 0 or 1)