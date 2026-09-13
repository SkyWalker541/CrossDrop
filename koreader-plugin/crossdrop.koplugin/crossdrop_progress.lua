-- Live transfer progress dialog. The PUT runs synchronously; while the chunks
-- stream, on_progress mutates this dialog in place and forces an e-ink repaint
-- (the same technique the Storefront plugin uses for its download steps), so
-- the reader screen shows real, updating percentage/bytes/rate/ETA.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local ProgressDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    alignment = "center",
    book = nil,
    target = nil,
}

function ProgressDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local content_w = math.min(sw - sc(70), sc(480))
    local inner_w = content_w - sc(44)

    local book_line = TextWidget:new{
        text = self.book or "?",
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = inner_w,
    }
    local target_txt = (self.target and self.target.ip or "?")
    if self.target and self.target.port and self.target.port ~= 80 then
        target_txt = target_txt .. ":" .. tostring(self.target.port)
    end
    if self.target and self.target.folder and self.target.folder ~= "" then
        target_txt = target_txt .. "  →  " .. self.target.folder
    end
    local target_line = TextWidget:new{
        text = target_txt,
        face = Font:getFace("smallinfofont"),
        max_width = inner_w,
    }

    local bar_w = inner_w
    local bar_h = sc(16)
    self.bar_w = bar_w
    self.bar_fill = FrameContainer:new{
        dimen = Geom:new{ w = 0, h = bar_h },
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    local bar_track = FrameContainer:new{
        dimen = Geom:new{ w = bar_w, h = bar_h },
        bordersize = Size.border.window,
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
    }
    local bar = OverlapGroup:new{
        dimen = Geom:new{ w = bar_w, h = bar_h },
        self.bar_fill,
        bar_track,
    }

    self.pct_text = TextWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 20),
        bold = true,
    }
    self.meta_text = TextWidget:new{
        text = "",
        face = Font:getFace("smallinfofont"),
    }

    local header_row = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = "Sending to CrossDrop",
            face = Font:getFace("smallinfofontbold"),
            bold = true,
        },
        VerticalSpan:new{ width = sc(6) },
        book_line,
        VerticalSpan:new{ width = sc(2) },
        target_line,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        VerticalGroup:new{
            align = "left",
            header_row,
            VerticalSpan:new{ width = sc(14) },
            bar,
            VerticalSpan:new{ width = sc(8) },
            self.pct_text,
            VerticalSpan:new{ width = sc(2) },
            self.meta_text,
        },
    }

    self.movable = MovableContainer:new{
        frame,
        unmovable = false,
    }
    self[1] = CenterContainer:new{
        dimen = Device.screen:getSize(),
        self.movable,
    }

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- sent/total in bytes; elapsed in seconds (may be 0). Called per streamed chunk.
function ProgressDialog:update(pct, sent, total, elapsed)
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    self.pct_text:setText(string.format("%d%%", pct))
    self.bar_fill.dimen.w = math.max(1, math.floor(self.bar_w * pct / 100))

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
    self.meta_text:setText(table.concat(meta, "  ·  "))

    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    else
        UIManager:setDirty(self, function()
            return "ui", self.movable and self.movable.dimen or nil
        end)
    end
end

function ProgressDialog:onBack()
    return true
end

local CrossdropProgress = {}

function CrossdropProgress.new(book, target)
    local dlg = ProgressDialog:new{ book = book, target = target }
    UIManager:show(dlg)
    return dlg
end

return CrossdropProgress