--[[--
QR code helpers.

Uses KOReader's own QR implementation: `ffi/qrencode` (pure Lua encoder in
koreader-base) through the `ui/widget/qrwidget` ImageWidget.

@module kindleui.transfer.qr
]]

local QR = {}

--- Builds the URL the phone opens: http://<ip>:<port>/<token>
function QR.buildUrl(ip, port, path)
    return string.format("http://%s:%d%s", ip, port, path)
end

--- Returns a QRWidget for `text`, or nil if the code cannot be generated.
-- @int size side length in pixels
function QR.newWidget(text, size)
    -- Encode once up front: QRWidget:init() fails silently (no image) on error.
    local ok_mod, qrencode = pcall(require, "ffi/qrencode")
    if not ok_mod then return nil, "qrencode unavailable" end
    local ok, grid_ok = pcall(qrencode.qrcode, text)
    if not ok or not grid_ok then return nil, "encode failed" end
    local QRWidget = require("ui/widget/qrwidget")
    local ok_w, widget = pcall(QRWidget.new, QRWidget, {
        text = text,
        width = size,
        height = size,
    })
    if not ok_w or not widget or not widget.image then
        return nil, "widget failed"
    end
    return widget
end

return QR
