-- Waiting dialog while a book streams. NO progress bar: socket.http drains the
-- whole file into the TCP buffers in milliseconds on this build, so any bar
-- just sat at 0% then jumped straight to done. Shows the book, the destination
-- and a plain "… please wait" line; update() is inert (progress never paints).

local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local WaitingDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    alignment = "center",
    book = nil,
    target = nil,
}

function WaitingDialog:init()
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

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = _("Sending to CrossDrop"),
                face = Font:getFace("smallinfofontbold"),
                bold = true,
            },
            VerticalSpan:new{ width = sc(6) },
            book_line,
            VerticalSpan:new{ width = sc(2) },
            target_line,
            VerticalSpan:new{ width = sc(14) },
            TextBoxWidget:new{
                text = _("… please wait\n\nThe reader is writing to its card."),
                face = Font:getFace("smallinfofont"),
                width = inner_w,
            },
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

-- Inert: the transfer is unpaced and finishes too fast for e-ink to show
-- anything, so there is nothing to repaint mid-flight.
function WaitingDialog:update(pct, sent, total, elapsed)
    return true
end

function WaitingDialog:onBack()
    return true
end

local CrossdropProgress = {}

function CrossdropProgress.new(book, target)
    local dlg = WaitingDialog:new{ book = book, target = target }
    UIManager:show(dlg)
    return dlg
end

return CrossdropProgress