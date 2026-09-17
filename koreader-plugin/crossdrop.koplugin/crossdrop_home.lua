-- CrossDrop Home: the plugin's app-style dashboard (the "Storefront" look).
-- A TitleBar header, an underlined tab bar (Connections / Send), rich rows
-- with live status dots and short hints, tap-to-act. The white card covers
-- the whole screen so nothing shows behind it. Loaded lazily from main.lua,
-- so all widget requires happen when the dashboard opens, never at plugin
-- load. Reachability is checked on demand (it is a blocking probe) and
-- remembered on the plugin instance across tab switches.
--
-- Every send happens INSIDE this dashboard: beginSendBatch hands the picked
-- files to plugin:sendBooks with this Home as the repaint sink, whose
-- onConnecting/onConnected/onBeginFile/onProgress/onDone callbacks rebuild the
-- Send tab in place (the same forceRePaint recipe the standalone progress
-- dialog and Storefront use). The dashboard never closes during a transfer,
-- and "Send more books…"/"Try again" keep going from the same window.
--
-- E-INK REPAINT RULE (the issue that hid the whole flow on the device):
-- when one of these callbacks flips the send STATE (connecting / sending a
-- file / done / failed) it does a full refresh — bare forceRePaint() partials
-- over a whole-screen white card were being swallowed by the panel, so the
-- transfer ran to completion with the screen still showing the old tab.
-- Not every transition flashes though: the "Connecting…" hint and MID-batch
-- file starts repaint WITHOUT a flash (repaintSoft, "partial") — a reachable
-- target answers the probe in milliseconds so its full flash would be wasted,
-- and mid-batch the screen is already showing Sending. Only the first file
-- start and the final done/failed boundary do the flashing full refresh
-- (repaintNow), and if an early partial happens to be swallowed the next full
-- always lands, so a soft repaint can never leave a stale screen.
-- There is no per-chunk repaint at all now: the "Sending…" view is a plain
-- waiting screen (the transfer drains faster than e-ink can repaint),
--
-- Uses only the plugin API exported from main.lua:
--   configuredTargets() -> {kind, ip, port, folder}[]  (WiFi only)
--   resolveTarget()     -> the WiFi target
--   probeTarget(target) -> (ok, info?); "down" statuses are cheap (3s timeout)
--   sendCurrentBook()   -> probes WiFi and streams to it
--   chooseAndSend()     -> the multi-select book picker (the send row sends)
--   editIp(kind)        -> input dialog for the WiFi IP
--   statusDialog(), currentBookPath()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")
local logger = require("logger")

-- This file's own plugin directory (icon.png lives beside it). The on-device
-- PluginLoader sets plugin.path on the module; this mirrors how the picker
-- finds titles_cache.lua so the logo also resolves when running without it.
local LUA_PLUGIN_DIR
do
    local src = debug.getinfo(1, "S").source
    if src and src:sub(1, 1) == "@" then
        LUA_PLUGIN_DIR = src:sub(2):match("^(.*)/[^/]+$")
    end
end

-- ────────────────────── small presentation helpers ──────────────────────

local function file_size(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        return lfs.attributes(path, "size") or 0
    end
    return 0
end

local function ip_str(t)
    local ip = t and t.ip or "?"
    if t and t.port and t.port ~= 80 then ip = ip .. ":" .. tostring(t.port) end
    return ip
end

local function folder_str(t)
    local folder = t and t.folder and t.folder ~= "" and t.folder or "/CrossDropped Files"
    return folder
end

-- Display name of a folder path: "/CrossDropped Files" → "CrossDropped Files".
local function folder_basename(path)
    local base = tostring(path or ""):match("([^/]+)/*$")
    return (base and base ~= "") and base or "CrossDropped Files"
end

local function status_word(reach)
    if reach == "ok" then return _("Reachable \226\151\128") end    -- ●
    if reach == "down" then return _("Offline \226\151\138") end    -- ○
    return _("Not checked")
end

-- ─────────────────────────────── the widget ──────────────────────────────

local HomeDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tab = "send",
    -- In-dashboard send state machine (see renderSend dispatch).
    send_state = "idle",  -- "idle" | "connecting" | "sending" | "done" | "failed"
    send_paths = nil,     -- full list passed to beginSendBatch
    send_target = nil,    -- {kind,ip,port,folder} of the resolved connection
    send_index = 0,       -- 1-based: current file number within the batch
    send_total = 0,       -- total files in the batch
    send_path = nil,      -- path of the file currently being sent
    send_filename = nil,  -- basename of send_path (for display)
    send_file_list = {},  -- basenames of files sent so far
    send_widgets = nil,   -- reserved: the progress bar was removed (e-ink), onProgress is inert
    fail_reason = nil,    -- text shown on "failed"
}

function HomeDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- Storefront-style sizing: every dimension is derived from the device via
    -- scaleBySize, and no text widget is allowed to auto-size past the card
    -- (every TextBoxWidget/row gets an explicit width). The white card covers
    -- the WHOLE screen (frame.dimen = sw x sh) so no other app shows behind
    -- it, while still never spilling past the edges on any device.
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("CrossDrop"),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local content = self:buildTabContent(self.tab, inner_w)

    -- A full-screen white frame (not a centered content-sized card): the
    -- whole screen paints white on top of whatever UI sits behind it. Both
    -- `dimen` AND `width`/`height` are required — FrameContainer:paintTo paints
    -- its background at container_width/height (= self.width/self.height or the
    -- content size), NOT at dimen. Without width/height the frame only painted
    -- over its content bounds and a strip of the UI below showed at the bottom.
    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            self:buildLogo(inner_w, sc),
            VerticalSpan:new{ width = sc(8) },
            self:buildTabBar(inner_w),
            VerticalSpan:new{ width = sc(20) },
            content,
            VerticalSpan:new{ width = sc(8) },
        },
    }
    self.frame = frame
    self[1] = frame

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function HomeDialog:onBack()
    UIManager:close(self)
    return true
end

-- The plugin logo (icon.png beside this file) renders as a small centered
-- header under the title bar whenever the file exists. No image on disk, no
-- logo and no dead gap — a stripped install just gets the normal spacing.
-- ImageWidget + CenterContainer are the same blitting path Storefront uses
-- for cover art, so this is proven to paint on the e-ink panel.
function HomeDialog:buildLogo(inner_w, sc)
    local dir = (self.plugin and self.plugin.path) or LUA_PLUGIN_DIR
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local icon = dir and (dir .. "/icon.png") or nil
    if not icon or not ok or not lfs or not lfs.attributes
            or lfs.attributes(icon, "mode") ~= "file" then
        self.logo_shown = false
        return VerticalSpan:new{ width = sc(6) }
    end
    self.logo_shown = true
    local size = sc(56)
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = size },
        ImageWidget:new{
            file = icon,
            width = size,
            height = size,
        },
    }
end

function HomeDialog:onCloseWidget()
    if self.plugin then
        self.plugin.home = nil
    end
    return true
end

-- ─────────────────────────────── tab bar ─────────────────────────────────

function HomeDialog:showTab(key)
    if self.tab == key then return end
    -- NOTE: there is NO UIManager:replace in this KOReader build (it crashed
    -- the plugin on the Kindle). Re-init the SAME widget for its new tab and
    -- repaint it in place instead. "ui" (not "partial"): flashless AND never
    -- promoted — the panel promotes every FULL_REFRESH_COUNT-th bare partial
    -- to a flashing full, which is exactly the "random" flashing the
    -- dashboard used to show.
    self.tab = key
    self:init()
    UIManager:setDirty(self, "ui")
end

function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local tabs = {
        { key = "connections", label = _("Connections") },
        { key = "send", label = _("Send A Book") },
    }
    local tabs_widgets = {}
    for i, t in ipairs(tabs) do
        if i > 1 then
            tabs_widgets[#tabs_widgets + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        local active = self.tab == t.key
        local btn = Button:new{
            text = t.label,
            menu_style = true,
            bold = active,
            callback = function()
                self:showTab(t.key)
            end,
        }
        local underline
        if active then
            underline = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = math.max(sc(24), btn:getSize().w), h = sc(3) },
            }
        else
            underline = VerticalSpan:new{ width = sc(3) }
        end
        tabs_widgets[#tabs_widgets + 1] = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = 0,
            padding_left = sc(8),
            padding_right = sc(8),
            bordersize = 0,
            VerticalGroup:new{
                align = "center",
                btn,
                VerticalSpan:new{ width = sc(4) },
                underline,
            },
        }
    end
    return HorizontalGroup:new(tabs_widgets)
end

function HomeDialog:row(text, opts)
    return Button:new{
        text = text,
        menu_style = true,
        width = self.row_w,
        callback = opts and opts.callback,
        hold_callback = opts and opts.hold_callback,
    }
end

function HomeDialog:header(text)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        padding_top = sc(6),
        padding_bottom = sc(2),
        bordersize = 0,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont"),
        },
    }
end

function HomeDialog:buildTabContent(tab, width)
    self.row_w = width
    if tab == "connections" then
        return self:renderConnections()
    end
    if self.send_state == "connecting" then
        return self:renderSendConnecting()
    end
    if self.send_state == "sending" then
        return self:renderSendWaiting()
    end
    if self.send_state == "done" then
        return self:renderSendDone()
    end
    if self.send_state == "failed" then
        return self:renderSendFailed()
    end
    return self:renderSendIdle()
end

-- ─────────────────────── Connections tab ────────────────────────────────

function HomeDialog:targetFor(kind)
    for _, t in ipairs(self.plugin:configuredTargets() or {}) do
        if t.kind == kind then
            return t
        end
    end
    return nil
end

function HomeDialog:check(kind)
    local target = self:targetFor(kind)
    if not target then return end
    -- The probe is a bounded blocking call on the UI thread (3s, see main:req);
    -- paint a notice first so the tap never looks like a freeze.
    local checking = Notification:new{
        text = _("Checking WiFi\226\128\166"),
        timeout = 0,
    }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local ok, info, err = self.plugin:probeTarget(target)
    UIManager:close(checking)
    local reach = self.plugin._reach or {}
    reach[kind] = ok and "ok" or "down"
    self.plugin._reach = reach
    if ok then
        local who = info and info.device and tostring(info.device) or "CrossDrop reader"
        local ver = info and info.version and tostring(info.version) or ""
        local text = _("WiFi reachable: ")
            .. who .. (ver ~= "" and ("  v" .. ver) or "")
        UIManager:show(Notification:new{ text = text, timeout = 4 })
    else
        local text = _("Could not reach WiFi: ")
            .. tostring(err or "network error")
        UIManager:show(Notification:new{ text = text, timeout = 5 })
    end
    -- "ui": flashless, never promoted to a flashing full (partials are).
    UIManager:setDirty(self, "ui")
    self:init()
end

-- Repaint the dashboard in place after a setting change (an IP edit happens
-- under a modal InputDialog, so the re-init must wait until that dialog is off
-- the stack). This is what makes a saved IP show up on the Connections tab
-- without reopening the dashboard. A partial update (no flash): the IP row
-- changed in place under a closed modal.
function HomeDialog:refresh()
    UIManager:nextTick(function()
        self.plugin._reach = {}
        self:init()
        -- "ui": flashless and never promoted to a flashing full (partials are).
        UIManager:setDirty(self, "ui")
    end)
end

function HomeDialog:renderConnections()
    local vg = VerticalGroup:new{ align = "left" }
    local reach = self.plugin._reach or {}

    table.insert(vg,self:header(_("WiFi connection")))
    local wifi = self:targetFor("wifi")
    if wifi then
        table.insert(vg,self:row(
            string.format("WiFi   %s\n%s  \226\128\164  %s", ip_str(wifi),
                _("File Transfer \226\134\146 Join Network"), status_word(reach.wifi)), {
            callback = function() self:check("wifi") end,
        }))
    end
    table.insert(vg,self:row(_("Set WiFi IP\226\128\166"), {
        callback = function() self.plugin:editIp("wifi", function() self:refresh() end) end,
    }))

    -- Setup guide for a first-time reader (the space the WiFi rows need
    -- between the controls and the text). Steps mirror the buttons directly
    -- above, so a new user reads exactly where each action happens. The
    -- version line sits ABOVE the guide: at the guide's tail it ran off the
    -- bottom of the panel. The guide itself uses the smaller info font so
    -- the steps (some wrap to 2-3 lines) fit with room to spare.
    local sc = function(v) return Device.screen:scaleBySize(v) end
    table.insert(vg, VerticalSpan:new{ width = sc(10) })
    table.insert(vg, TextBoxWidget:new{
        text = "CrossDrop " .. tostring((self.plugin and self.plugin.VERSION) or ""),
        face = Font:getFace("smallinfofontbold"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(6) })
    table.insert(vg, TextBoxWidget:new{
        text = _("To receive books, set up your Xteink device like this:\n")
            .. _("1. Put the Xteink and this Kindle on the same Wi-Fi network.\n")
            .. _("2. With CrossPoint running on the Xteink, open File Transfer and tap \"Join WiFi Network\".\n")
            .. _("3. On that screen, the device's IP address is below the QR code.\n")
            .. _("4. Tap \"Set WiFi IP\" to enter that address.\n")
            .. _("5. Then tap the connection row above to check \226\128\148 it should read \"Reachable\" when connected.\n")
            .. _("6. Send from the Send A Book tab: pick books from the list, or send the currently open book. Pick the destination folder there too \226\128\148 it defaults to CrossDropped Files on the reader."),
        face = Font:getFace("xx_smallinfofont"),
        width = self.row_w,
    })

    return vg
end

-- ─────────────────────────── Send tab ───────────────────────────────────

-- Idle: pick books, or send the one that is open (and only shown when it is),
-- plus a Destination folder row that lists the reader's folders or takes a
-- typed-in name (the CrossDropped Files default when nothing is chosen).
function HomeDialog:renderSendIdle()
    local vg = VerticalGroup:new{ align = "left" }
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local book = self.plugin:currentBookPath()

    table.insert(vg,self:header(_("Send one or more books")))
    table.insert(vg,self:row(_("Click Here To Select Book(s)"), {
        callback = function() self.plugin:chooseAndSend() end,
    }))

    -- "Currently open" only appears when there IS an open book (no empty
    -- placeholder header when nothing is open). Both book sections breathe
    -- with a spacer so the Destination folder block sits clearly apart.
    if book and book ~= "" then
        table.insert(vg, VerticalSpan:new{ width = sc(18) })
        local name = book:match("([^/]+)$") or book
        local size = file_size(book)
        table.insert(vg,self:header(_("Currently open")))
        table.insert(vg,self:row(
            string.format("\226\151\128  %s\n%s  \226\128\164  tap to send", name,
                (size > 0 and string.format(_("%.1f MB"), size / 1048576) or "ebook")), {
            callback = function() self:beginSendBatch({ book }) end,
        }))
    end

    -- Destination folder: shows which reader folder (full nested path) books
    -- land in. Always available (even offline) — picking a listed folder or
    -- typing a new name/path only needs the reader when a send later creates
    -- or uses it.
    table.insert(vg, VerticalSpan:new{ width = sc(18) })
    local target = self.plugin:resolveTarget()
    local dest_raw = folder_str(target)
    local dest_name = tostring(dest_raw):gsub("^/+", ""):gsub("/+$", "")
    if dest_name == "" then dest_name = folder_basename(dest_raw) end
    table.insert(vg, self:header(_("Destination folder")))
    table.insert(vg, self:row(
        string.format("%s\n%s  \226\128\164  tap to choose",
            dest_name, _("folder on the reader")), {
        callback = function() self:chooseDestination() end,
    }))

    return vg
end

-- ─────────────────────── destination folder tree ────────────────────────
-- A full-screen modal (the dashboard's own full-screen look, like the picker:
-- TitleBar + Button rows on a white card — this device renders NO other
-- widget language). The destination picker is a FOLDER TREE, the way a
-- computer file browser works:
--
--   · the card root is listed first;
--   · every folder row carries an expand ▸ (or ▾ when open). Tapping the
--     arrow fetches (GET /api/files?path=) and shows what is nested,
--     indented under it so subfolders read as subfolders;
--   · an open folder with no subfolders shows only
--     "No subfolders found in /X" under it;
--   · tapping the folder NAME opens a small action menu: Select (make it
--     the destination), Create Subfolder… (picks /X/<name> and adds it to
--     the tree), Cancel;
--   · folder rows are BOXLESS (bare text, like the picker's book rows);
--     action menu rows keep their box so actions stay distinct;
--   · when the reader is unreachable the dialog shows ONLY
--     "Device not found. Please check Xteink IP, and confirm that it
--     matches in Connections." — no retry rows, no typed-path fallback.

local TREE_INDENT = 24  -- scaled px of indentation per depth level
local TREE_ARROW_W = 44 -- scaled px of the ▸/▾ expand control (a real tap target)

-- One folder in the tree.
local function new_node(name, path, depth)
    return {
        name = name,
        path = path,                  -- relative, no leading slash ("Books/Fiction")
        depth = depth,                -- 0 == card root
        children = nil,               -- sorted child nodes, or nil until loaded
        expanded = false,             -- showing its children inline?
        pending = false,              -- created this session, not yet on the reader
    }
end

local DestinationDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,     -- CROSSDROP instance (setFolder / listFolders)
    home = nil,       -- the HomeDialog to refresh after a pick
    nodes = nil,      -- root folder tree (a new_node list)
    list_err = nil,   -- reader unreachable → message-only body
    selected = nil,   -- chosen destination (relative path; nil == default)
}

-- Find a node by its path (depth-first search over the whole tree).
function DestinationDialog:findNode(path)
    local function walk(list)
        for _, n in ipairs(list) do
            if n.path == path then return n end
            if n.children then
                local hit = walk(n.children)
                if hit then return hit end
            end
        end
        return nil
    end
    return walk(self.nodes or {})
end

-- Repaint the tree in place, flash-free (the no-flash rule of the dashboard).
-- "ui" (not "partial"): flashless AND never promoted — the panel promotes
-- every FULL_REFRESH_COUNT-th bare partial to a flashing full, which read as
-- "random" flashes while browsing the tree.
function DestinationDialog:rebuild()
    self:init()
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
end

-- Choose `path` as the destination and leave the dialog (dashboard refresh).
function DestinationDialog:pick(path)
    if self.plugin.setFolder then
        self.plugin:setFolder(path)
    end
    if type(path) == "string" and path ~= "" then
        self.selected = tostring(path):gsub("^/+", ""):gsub("/+$", "")
    end
    local home = self.home
    UIManager:close(self)
    UIManager:nextTick(function()
        if home and home.refresh then home:refresh() end
    end)
end

-- Leave the tree WITHOUT changing the destination (the back chevron and the
-- ✕): back to the dashboard, refreshed so its destination row shows the
-- folder as it stands — including a subfolder created here but not yet on
-- the reader (it materializes when a book is sent).
function DestinationDialog:leave()
    local home = self.home
    UIManager:close(self)
    UIManager:nextTick(function()
        if home and home.refresh then home:refresh() end
    end)
end

-- Tap the ▸/▾ control: expand (fetching children if needed) or collapse.
function DestinationDialog:toggleNode(node)
    if node.expanded then
        node.expanded = false
    else
        self:expandNode(node)
    end
    self:rebuild()
end

-- Open a folder: fetch its children once (GET /api/files?path=), or expand
-- from cache. A just-created (pending) folder opens locally without a fetch.
-- An empty folder still opens — its only content is the
-- "No subfolders found in /X" note.
function DestinationDialog:expandNode(node)
    if node.expanded then return end
    if node.pending then
        node.children = node.children or {}
        node.expanded = true
        self:rebuild()
        return
    end
    if node.children == nil then
        local target = self.plugin:resolveTarget()
        if not target or not target.ip or target.ip == "" then
            self.list_err = true
            self:rebuild()
            return
        end
        local checking = Notification:new{ text = _("Looking up folders\226\128\166"), timeout = 0 }
        UIManager:show(checking)
        UIManager:forceRePaint()
        local ok, folders, err = self.plugin:listFolders(target, node.path)
        UIManager:close(checking)
        if not ok then
            self.list_err = true
            self:rebuild()
            return
        end
        node.children = {}
        for _, name in ipairs(folders) do
            node.children[#node.children + 1] = new_node(name, node.path .. "/" .. name, node.depth + 1)
        end
    end
    node.expanded = true
    self:rebuild()
end

-- The folder NAME tap: the tiny action popup (Select / Create Subfolder /
-- Cancel), built like the picker's send-confirmation ConfirmBox — a small
-- bordered card centered over the tree, not a full page. Shown with a
-- flashless "ui" refresh exactly like that popup; only page-level state
-- transitions (opening the tree, leaving the plugin) warrant the flashing
-- full refresh on this panel.
function DestinationDialog:showFolderMenu(node)
    local popup = FolderMenuDialog:new{
        plugin = self.plugin,
        tree = self,
        node = node,
    }
    -- "ui" refresh of ONLY the popup's box region (the third arg to show):
    -- flashless, never promoted, and no whole-screen sweep for a 3-row card.
    UIManager:show(popup, "ui", popup.region)
    UIManager:forceRePaint()
end

-- Create a new subfolder under `node` (from the folder menu). The name is a
-- single folder name (no slashes — the tree handles nesting). The folder is
-- picked as the destination and added to the tree as a pending child; it
-- exists on the reader once a book is sent to it. The dashboard behind the
-- tree is refreshed too, so its destination row already shows /X/<name> —
-- the folder does not exist yet, but that IS where books will land.
function DestinationDialog:addSubfolder(node, name)
    local full = node.path .. "/" .. name
    if self.plugin.setFolder then
        self.plugin:setFolder(full)
    end
    self.selected = full
    node.children = node.children or {}
    local already = false
    for _, c in ipairs(node.children) do
        if c.name == name then already = true break end
    end
    if not already then
        local child = new_node(name, full, node.depth + 1)
        child.pending = true
        node.children[#node.children + 1] = child
        table.sort(node.children, function(a, b) return a.name < b.name end)
    end
    node.expanded = true
    self:rebuild()
    if self.home and self.home.refresh then
        self.home:refresh()
    end
end

function DestinationDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    -- Back chevron top-left returns to the dashboard. There is NO ✕ here:
    -- the dashboard is still behind this page, and X is reserved for leaving
    -- the plugin entirely (only the home dashboard carries it).
    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Destination folder"),
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "chevron.left",
        left_icon_tap_callback = function() self:leave() end,
        show_parent = self,
    }

    local vg = VerticalGroup:new{ align = "left" }
    local dest_label = (self.selected and ("/" .. self.selected)) or folder_str(self.plugin:resolveTarget())
    table.insert(vg, self:foldersHeader(_("Destination: ") .. dest_label))

    if self.list_err then
        -- The reader is unreachable: ONLY this message, nothing else.
        table.insert(vg, TextBoxWidget:new{
            text = _("Device not found. Please check Xteink IP, and confirm that it matches in Connections."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    else
        table.insert(vg, self:foldersHeader(_("Folders on the reader")))
        local nodes = self.nodes or {}
        if #nodes > 0 then
            self:appendNodes(vg, nodes, 0)
        else
            table.insert(vg, TextBoxWidget:new{
                text = _("No folders on the reader."),
                face = Font:getFace("smallinfofont"),
                width = self.row_w,
            })
        end
        table.insert(vg, self:foldersHeader(_("Default")))
        table.insert(vg, self:plainRow(_("CrossDropped Files (back to the default)"),
            function() self:pick("CrossDropped Files") end))
    end

    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            vg,
        },
    }
    self.frame = frame
    self[1] = frame
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- Render a folder list into `vg`, one indented BOXLESS row per node (bare
-- text, like the picker's book rows). Open nodes recurse into their children
-- one level deeper; an open folder with no children shows the
-- "No subfolders found in /X" note in its place.
function DestinationDialog:appendNodes(vg, nodes, depth)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local indent = math.min(depth * sc(TREE_INDENT), sc(140))
    for i = 1, #nodes do
        local node = nodes[i]
        self:treeRowInto(vg, node, indent)
        if node.expanded then
            local kids = node.children or {}
            if #kids > 0 then
                self:appendNodes(vg, kids, depth + 1)
            else
                table.insert(vg, HorizontalGroup:new{
                    HorizontalSpan:new{ width = indent + sc(TREE_ARROW_W) + sc(6) },
                    TextBoxWidget:new{
                        text = string.format(_("No subfolders found in /%s"), node.path),
                        face = Font:getFace("smallinfofont"),
                        width = math.max(self.row_w - indent - sc(TREE_ARROW_W) - sc(6), 1),
                    },
                })
            end
        end
    end
end
-- One tree row: the ▸/▾ expand control and the folder name are SEPARATE
-- buttons (separate tap targets), placed after the indentation. Tapping
-- the control opens/closes the folder's sub-tree INLINE (children appear
-- indented under it, other root folders stay visible); tapping the folder
-- NAME opens the tiny Select / Create Subfolder / Cancel popup.
function DestinationDialog:treeRowInto(vg, node, indent)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local is_expanded = node.expanded
    local arrow_text = is_expanded and "\226\150\190" or "\226\150\184" -- ▾ / ▸

    local toggle = Button:new{
        text = arrow_text,
        width = sc(TREE_ARROW_W),
        align = "center",
        bordersize = 0,
        padding_h = 0,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 28, -- bigger glyph than the row text: an easy tap target
        callback = function() self:toggleNode(node) end,
    }

    local name_text = node.name
    if node.path == self.selected then
        name_text = "\226\151\128  " .. name_text .. "   (" .. _("chosen") .. ")"
    end
    local name = Button:new{
        text = name_text,
        width = math.max(self.row_w - indent - sc(TREE_ARROW_W), 1),
        align = "left",
        bordersize = 0,
        padding_h = Size.padding.large,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        callback = function() self:showFolderMenu(node) end,
    }

    table.insert(vg, HorizontalGroup:new{
        HorizontalSpan:new{ width = indent },
        toggle,
        name,
    })
end

-- A plain boxless action row (boxless, to match the tree rows).
function DestinationDialog:plainRow(text, callback)
    return Button:new{
        text = text,
        width = self.row_w,
        align = "left",
        bordersize = 0,
        padding_h = Size.padding.large,
        avoid_text_truncation = false,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        callback = callback,
    }
end

function DestinationDialog:onBack()
    self:leave()
    return true
end

function DestinationDialog:foldersHeader(text)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        padding_top = sc(6),
        padding_bottom = sc(2),
        bordersize = 0,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont"),
        },
    }
end

-- ─────────────────────── folder action menu ────────────────────────────
-- Select / Create Subfolder… / Cancel for one tapped folder. Built like the
-- picker's send-confirmation ConfirmBox: a small bordered card, auto-sized
-- to its rows and centered over the tree via a full-screen CenterContainer
-- (the ConfirmBox recipe — this device renders no other popup language).
-- Action rows keep their box so the menu reads as actions, a step apart
-- from the boxless tree rows behind it.

FolderMenuDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,   -- CROSSDROP instance (setFolder)
    tree = nil,     -- the DestinationDialog to apply choices to
    node = nil,     -- the folder being acted on
}

-- Select: like the picker's send-confirmation, the work after the closes is
-- deferred with nextTick — running the close→close→dashboard-repaint chain
-- synchronously inside the tap handler froze the panel once on the device.
-- The close passes the popup's box region: only that hole repaints, not the
-- whole screen.
function FolderMenuDialog:onSelect()
    local tree, node = self.tree, self.node
    UIManager:close(self, "ui", self.region)
    UIManager:nextTick(function()
        if tree and node then tree:pick(node.path) end
    end)
end

function FolderMenuDialog:onCancel()
    UIManager:close(self, "ui", self.region)
end

-- Create a subfolder under this folder: a single-name input dialog. The new
-- folder becomes the destination and is added to the tree as a pending child.
function FolderMenuDialog:onCreate()
    local InputDialog = require("ui/widget/inputdialog")
    local menu = self
    local name_dialog
    name_dialog = InputDialog:new{
        title = _("New subfolder"),
        input = "",
        input_hint = string.format(_("Under /%s \226\128\148 created on the reader when a book is sent"), tostring(menu.node.path)),
        type = "text",
        modal = true,
        buttons = {
            {
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = name_dialog:getInputText() or ""
                        local name = text:match("^%s*(.-)%s*$") or ""
                        if name == "" then
                            UIManager:show(Notification:new{ text = _("Enter a folder name first."), timeout = 3 })
                            return
                        end
                        if name:find("/") then
                            UIManager:show(Notification:new{ text = _("One folder name only \226\128\148 no slashes."), timeout = 3 })
                            return
                        end
                        if name == "." or name == ".." then
                            UIManager:show(Notification:new{ text = _("That is not usable as a folder name."), timeout = 3 })
                            return
                        end
                        UIManager:close(name_dialog)
                        UIManager:close(menu)
                        -- nextTick, like Select: the close→rebuild repaint
                        -- chain must not run inside the tap handler.
                        UIManager:nextTick(function()
                            if menu.tree then menu.tree:addSubfolder(menu.node, name) end
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(name_dialog) end,
                },
            },
        },
    }
    UIManager:show(name_dialog)
end

function FolderMenuDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local pad = Size.padding.default
    -- The ConfirmBox look: the card is a modest share of the screen, sized
    -- to its three rows — nothing like a full page.
    local box_w = math.min(math.floor(sw * 0.6), sw - sc(40))
    local inner_w = box_w - pad * 2

    local vg = VerticalGroup:new{}
    table.insert(vg, VerticalSpan:new{ width = sc(4) })
    table.insert(vg, TextBoxWidget:new{
        text = string.format(_("/%s"), tostring(self.node and self.node.path or "")),
        face = Font:getFace("smallinfofontbold"),
        width = inner_w,
        alignment = "center",
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:menuRow(inner_w, _("Select"), function() self:onSelect() end))
    table.insert(vg, self:menuRow(inner_w, _("Create Subfolder\226\128\166"), function() self:onCreate() end))
    table.insert(vg, self:menuRow(inner_w, _("Cancel"), function() self:onCancel() end))
    table.insert(vg, VerticalSpan:new{ width = sc(4) })

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = pad,
        vg,
    }
    self.frame = frame
    -- Full-screen CenterContainer centers the small card over the tree:
    -- the ConfirmBox recipe (this is how KOReader centers popups).
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        frame,
    }
    self.dimen = Geom:new{ w = sw, h = sh }
    -- The popup's OWN box region (where the CenterContainer places the
    -- frame). UIManager:show/close accept a refresh region — passing this
    -- one refreshes ONLY the box on open and repaints ONLY the box-sized
    -- hole on close, instead of sweeping the whole screen both times.
    local fs = frame:getSize()
    local bw = fs and fs.w or box_w
    local bh = fs and fs.h or sh
    self.region = Geom:new{
        x = math.floor((sw - bw) / 2),
        y = math.floor((sh - bh) / 2),
        w = bw,
        h = bh,
    }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function FolderMenuDialog:menuRow(row_w, text, callback)
    return Button:new{
        text = text,
        menu_style = true,
        width = row_w,
        callback = callback,
    }
end

function FolderMenuDialog:onBack()
    UIManager:close(self, "ui", self.region)
    return true
end

-- Open the destination folder tree. The root listing is one bounded attempt
-- (socketutil); if the reader does not answer, the tree opens with ONLY the
-- "Device not found…" message — nothing to retry or type around. No
-- "Looking up…" notice first: against a reachable reader the listing returns
-- in milliseconds, and the notice's show/close repaint cycle both added a
-- paint to every open and raced the tree's first paint (a stale region
-- half-covered it). The tree paints in ONE flashless "ui" pass, exactly
-- like the picker.
function HomeDialog:chooseDestination()
    local InfoMessage = require("ui/widget/infomessage")
    local target = self.plugin:resolveTarget()
    if not target or not target.ip or target.ip == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set the WiFi IP on the Connections tab first."),
        })
        return
    end
    local ok, folders = self.plugin:listFolders(target)
    local nodes
    if ok and folders then
        nodes = {}
        for _, name in ipairs(folders) do
            nodes[#nodes + 1] = new_node(name, name, 0)
        end
    end
    UIManager:show(DestinationDialog:new{
        plugin = self.plugin,
        home = self,
        nodes = nodes,
        list_err = not ok,
    }, "ui")
    UIManager:forceRePaint()
end

-- ─────────────── in-dashboard send: the progress sink ─────────────────────
-- plugin:sendBooks(paths, self) drives these callbacks synchronously while the
-- connection probes and the chunked PUT run on the UI thread. Each one rebuilds
-- the Send tab in place, so the whole flow is visible inside CrossDrop — the
-- dashboard never closes, and afterwards Send More / Try Again keep
-- controlling the same window. State changes paint via repaintNow (a flashing
-- full refresh) so the panel really shows them; see the header comment.

function HomeDialog:beginSendBatch(paths)
    self.send_state = "connecting"
    self.send_paths = type(paths) == "table" and paths or {}
    self.send_total = #self.send_paths
    self.send_index = 0
    self.send_file_list = {}
    self.send_target = nil
    self.fail_reason = nil
    self.plugin:sendBooks(self.send_paths, self)
end

-- Rebuild this dashboard's frame and repaint it with a flushing FULL refresh
-- (forceRePaint alone enqueues only a partial over the white card, which an
-- e-ink panel can fail to show when the whole screen is repainting).
function HomeDialog:repaintNow()
    self:init()
    UIManager:setDirty(self, "full")
    UIManager:forceRePaint()
end

-- FLASH-FREE variant (1.3.32): rebuilds and repaints in place WITHOUT the
-- full-refresh flash. Used where the change is almost always followed a frame
-- later by a real full transition: the "Connecting…" hint (reachable targets
-- reply in milliseconds) and MID-batch file starts (the screen is already
-- showing Sending). If the panel swallows the partial, the next full always
-- lands, so a soft repaint can never leave a stale screen.
function HomeDialog:repaintSoft()
    self:init()
    UIManager:setDirty(self, "partial")
    UIManager:forceRePaint()
end

function HomeDialog:onConnecting()
    self.send_state = "connecting"
    self:repaintSoft()
end

function HomeDialog:onConnected(target)
    self.send_target = target
end

function HomeDialog:onUnreachable()
    self.send_state = "failed"
    self.fail_reason = self.plugin:noReaderText()
    self:repaintNow()
end

function HomeDialog:onBeginFile(path, target, idx, total)
    self.send_state = "sending"
    self.send_target = target
    self.send_path = path
    self.send_filename = path:match("([^/]+)$") or path
    self.send_index = idx
    self.send_total = total
    self.send_widgets = nil
    -- First file start flashes (the real transition into Sending); MID-batch
    -- file starts only soft-repaint (the screen already shows Sending and a
    -- flash per file would make multi-book batches strobe).
    if idx and idx > 1 then
        self:repaintSoft()
    else
        self:repaintNow()
    end
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("crossdrop: home shows Sending ", idx, "/", total, " ",
        self.send_filename, " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:onProgress(path, pct, sent, total, elapsed)
    local w = self.send_widgets
    if not w then return end
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    w.pct:setText(string.format("%d%%", pct))
    w.fill.dimen.w = math.max(1, math.floor(w.bar_w * pct / 100))

    local meta = {}
    if total and total > 0 then
        meta[#meta + 1] = string.format("%.1f / %.1f MB", sent / 1048576, total / 1048576)
    else
        meta[#meta + 1] = string.format("%.1f MB", sent / 1048576)
    end
    if elapsed and elapsed > 0 then
        local rate = sent / elapsed
        meta[#meta + 1] = string.format("%.2f MB/s", rate / 1048576)
        if total and total > 0 and pct > 0 then
            local remaining = total - sent
            local eta = remaining / math.max(rate, 1)
            meta[#meta + 1] = string.format("ETA %d:%02d", math.floor(eta / 60), math.floor(eta % 60))
        end
    end
    w.meta:setText(table.concat(meta, "  \194\183  "))
    UIManager:forceRePaint()
end

function HomeDialog:onFileSent(path, target)
    self.send_file_list[#self.send_file_list + 1] = path:match("([^/]+)$") or path
end

function HomeDialog:onFileFailed(path, reason)
    self.fail_reason = (path:match("([^/]+)$") or path) .. "\n" .. tostring(reason)
end

function HomeDialog:onDone(all_ok)
    self.send_state = all_ok and "done" or "failed"
    if not all_ok and not self.fail_reason then
        self.fail_reason = _("The transfer did not complete.")
    end
    self:repaintNow()
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("crossdrop: home shows ", self.send_state,
        " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:sendMore()
    self.send_state = "idle"
    self.send_paths = nil
    self.send_file_list = {}
    self:init()
    UIManager:forceRePaint()
    self.plugin:chooseAndSend()
end

function HomeDialog:tryAgain()
    self:beginSendBatch(self.send_paths or {})
end

function HomeDialog:backToIdle()
    self.send_state = "idle"
    self.send_paths = nil
    self.send_target = nil
    self.send_file_list = {}
    self.fail_reason = nil
    self.send_widgets = nil
    self:init()
    UIManager:setDirty(self, "full")
end

-- Connecting: painted BEFORE the blocking 3s probes start (the Storefront
-- "paint progress first, then block" rule), so no reachable state ever reads
-- as a frozen screen.
function HomeDialog:renderSendConnecting()
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Sending")))
    local target = self.send_target
    table.insert(vg, TextBoxWidget:new{
        text = target
            and string.format("Connected     %s\n%s  \226\134\146  %s",
                _("WiFi"),
                ip_str(target), folder_str(target))
            or _("Connecting to CrossDrop \226\128\166"),
        face = Font:getFace("cfont", 18),
        width = self.row_w,
    })
    if not target then
        table.insert(vg, TextBoxWidget:new{
            text = _("Looking for the reader on your network. It answers within seconds."),
            face = Font:getFace("smallinfofont"),
            width = self.row_w,
        })
    end
    return vg
end

-- Sending: NO progress bar. socket.http hands the whole file to the TCP
-- buffers in milliseconds, so a bar would sit at 0% then jump straight to
-- done — worse than useless. This paints once at transfer start and the
-- device reply flips the tab to Done; onProgress stays inert.
function HomeDialog:renderSendWaiting()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    local inner_w = self.row_w

    table.insert(vg, self:header(string.format(_("Sending %d of %d"),
        self.send_index, self.send_total)))

    table.insert(vg, TextWidget:new{
        text = tostring(self.send_filename or "?"),
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = inner_w,
    })
    local target = self.send_target
    if target then
        table.insert(vg, TextWidget:new{
            text = string.format("%s  %s  \226\134\146  %s",
                _("WiFi"),
                ip_str(target), folder_str(target)),
            face = Font:getFace("smallinfofont"),
            max_width = inner_w,
        })
    end

    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, TextBoxWidget:new{
        text = _("… please wait\n\nThe reader is writing to its card."),
        face = Font:getFace("smallinfofont"),
        width = inner_w,
    })

    return vg
end

function HomeDialog:renderSendDone()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local names = self.send_file_list or {}
    local lines = {}
    for _, n in ipairs(names) do
        lines[#lines + 1] = "\226\156\147  " .. n
    end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Done")))
    table.insert(vg, TextBoxWidget:new{
        text = string.format(_("Sent %d book(s) to the reader."), #names)
            .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or ""),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Send more books\226\128\166"), {
        callback = function() self:sendMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

function HomeDialog:renderSendFailed()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Send failed")))
    table.insert(vg, TextBoxWidget:new{
        text = tostring(self.fail_reason or _("The transfer did not complete.")),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Try again"), {
        callback = function() self:tryAgain() end,
    }))
    table.insert(vg, self:row(_("Send more books\226\128\166"), {
        callback = function() self:sendMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

return HomeDialog