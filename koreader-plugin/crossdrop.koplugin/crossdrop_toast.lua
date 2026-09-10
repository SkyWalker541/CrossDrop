-- Toast notifications, storefront-style: a small centered card that appears
-- briefly, dismisses on tap/key, and never steals focus. Load time is fine —
-- this module is only required by main.lua once a dialog opens, never at
-- plugin load.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")

local CrossdropToastWidget = InputContainer:extend{
    text = "",
    timeout = 3,
    dismissable = true,
}

function CrossdropToastWidget:init()
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    self.dimen = Geom:new{ w = sw, h = sh }

    local max_w = math.min(sw - sc(32), sc(640))
    local label = TextBoxWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_w - sc(48),
        alignment = "center",
    }

    local card = FrameContainer:new{
        padding = sc(14),
        padding_left = sc(18),
        padding_right = sc(18),
        radius = Size.radius.window,
        bordersize = Size.border.window,
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = sc(6) },
            label,
            HorizontalSpan:new{ width = sc(6) },
        },
    }

    local size = card:getSize()
    card.dimen = Geom:new{
        x = math.floor((sw - size.w) / 2),
        y = math.floor((sh - size.h) / 2),
        w = size.w,
        h = size.h,
    }
    self.card = card

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        card,
    }

    if self.dismissable ~= false then
        if Device:hasKeys() then
            self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
        end
        if Device:isTouchDevice() then
            self.ges_events = {
                TapDismiss = {
                    GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } }
                },
            }
        end
    end

    if self.timeout and self.timeout > 0 then
        self._timer = UIManager:scheduleIn(self.timeout, function()
            self:close()
        end)
    end
end

function CrossdropToastWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", (self.card and self.card.dimen) or self.dimen
    end)
    return true
end

function CrossdropToastWidget:onCloseWidget()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
end

function CrossdropToastWidget:onAnyKeyPressed()
    if self.dismissable ~= false then
        self:close()
        return true
    end
end

function CrossdropToastWidget:onTapDismiss()
    if self.dismissable ~= false then
        self:close()
        return true
    end
end

function CrossdropToastWidget:close()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    UIManager:close(self)
end

local CrossdropToast = {}

function CrossdropToast.show(text, timeout)
    local toast = CrossdropToastWidget:new{
        text = text or "",
        timeout = timeout or 3,
    }
    UIManager:show(toast)
    return toast
end

return CrossdropToast