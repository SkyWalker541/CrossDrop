-- CrossDrop theme tokens: the Storefront-style sizing/color vocabulary this
-- plugin draws with (mirrors storefront_theme.lua). Scaled once at load from
-- the target device's reported DPI via scaleBySize; every widget reads from
-- here so the whole plugin stays visually consistent. Loaded lazily with the
-- dashboard — this module touches no KOReader widget classes.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")

local function sc(v)
    return (Device and Device.screen and Device.screen.scaleBySize) and Device.screen:scaleBySize(v) or v
end

return {
    border_line_h = sc(1),
    border_window = sc(2),
    border_btn = sc(1),
    color_border = Blitbuffer.COLOR_DARK_GRAY,
    color_bg = Blitbuffer.COLOR_WHITE,
    color_bg_dim = Blitbuffer.COLOR_LIGHT_GRAY,
    color_label_dim = (Blitbuffer.Color8 and Blitbuffer.Color8(80)) or nil,
    color_section_rule = Blitbuffer.COLOR_DARK_GRAY,
    radius_window = 0,
    radius_btn = sc(4),
    gap = sc(8),
    title_font_size = 22,
    face_label_size = 18,
    subtext_font_size = 16,
    section_header_font_size = 16,
    icon_button_size = sc(48),
    icon_size = sc(24),
    tab_icon_size = sc(22),
}