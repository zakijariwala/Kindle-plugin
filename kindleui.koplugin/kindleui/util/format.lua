--[[--
Small text formatters (no KOReader dependencies; unit-tested).

@module kindleui.util.format
]]

local Format = {}

--- "850 KB", "3.4 MB", "1.2 GB"
function Format.size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 * 1024 then
        return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
end

--- "8 s", "2 min", "1 h 5 min"
function Format.duration(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    if seconds < 60 then return string.format("%d s", seconds) end
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then return string.format("%d min", minutes) end
    return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

--- Transfer speed and time left, or nil while there is too little data
-- (under a second, or nothing received yet) to give a meaningful figure.
-- @treturn string|nil e.g. "1.2 MB/s · about 14 s left"
function Format.rate(received, total, elapsed)
    if not elapsed or elapsed < 1 or not received or received <= 0 then return nil end
    local bps = received / elapsed
    local text = Format.size(bps) .. "/s"
    if total and total > received then
        text = text .. " · about " .. Format.duration((total - received) / bps) .. " left"
    end
    return text
end

return Format
