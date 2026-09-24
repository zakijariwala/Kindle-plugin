--[[--
Transfer provider registry.

The UI talks to a provider, never to the HTTP server directly, so another
transport (e.g. a future Cloudflare R2 relay) can be added beside the local
one without touching the local implementation:

    Transfer Provider
          └── local_http   (this MVP: phone → Kindle over the hotspot/LAN)

A future provider (e.g. cloud) is added to `list` below; nothing in the UI
shows or mentions it until it exists.

Provider interface:
    id, name, available
    provider:prepare()             -> info | nil, error_key   (pre-flight checks)
    provider:start(info, callbacks) -> session | nil, error_key

@module kindleui.transfer.provider
]]

local _ = require("gettext")

local Providers = {}

local list = {
    {
        id = "local_http",
        name = _("Local Wi-Fi"),
        available = true,
        module = "kindleui/transfer/localhttp",
    },
}

function Providers.list()
    return list
end

--- Returns the provider implementation for `id`, falling back to local_http.
function Providers.get(id)
    for __, p in ipairs(list) do
        if p.id == id and p.available then
            return require(p.module)
        end
    end
    return require("kindleui/transfer/localhttp")
end

return Providers
