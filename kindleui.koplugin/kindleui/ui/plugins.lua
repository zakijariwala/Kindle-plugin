--[[--
"Installed Plugins": every plugin KOReader discovered, with a way to open it.

Discovery is KOReader's own: `PluginLoader:loadPlugins()` returns the same
enabled/disabled lists the core uses (no hard-coded list, no second scan).

Opening the screen runs no plugin code: the list comes from the module
tables KOReader already loaded, and whether a plugin "has a menu" is just a
check that its instance defines `addToMainMenu`. Only when a plugin is
tapped do we call that instance's own `addToMainMenu(menu_items)` on a
scratch table — exactly what KOReader's
FileManagerMenu/ReaderMenu do when they build the main menu (and what its
debug guard does with a mock table) — and show the resulting entries in
KOReader's native TouchMenu. Nothing is patched, wrapped, disabled or
reconfigured.

Selection mode (hold a plugin → "Select plugins to remove…") removes several
user-installed plugins at once, then restarts KOReader once. Built-in
plugins and this plugin cannot be selected.

@module kindleui.ui.plugins
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Common = require("kindleui/ui/common")
local Config = require("kindleui/config")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Perf = require("kindleui/util/perf")
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Plugins = Menu:extend{
    name = "kindleui_plugins",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    is_enable_shortcut = false,
    title_bar_fm_style = true,
    items_per_page = 10,
    plugin = nil, -- our own plugin instance
}

--- Collects the menu entries a plugin instance registers, without side effects
-- on KOReader's real menu.
-- @treturn table array of TouchMenu items (possibly empty)
function Plugins.collectMenuItems(instance)
    if type(instance) ~= "table" or type(instance.addToMainMenu) ~= "function" then
        return {}
    end
    local scratch = {}
    -- addToMainMenu may be wrapped by KOReader's handler sandbox only for on* handlers;
    -- call it defensively anyway: a broken plugin must not break this screen.
    local ok, err = pcall(instance.addToMainMenu, instance, scratch)
    if not ok then
        logger.warn("KindleUI: could not read menu of plugin", instance.name, err)
        return {}
    end
    local items = {}
    for key, item in pairs(scratch) do
        if type(item) == "table" and (item.text or item.text_func) then
            item._key = key
            table.insert(items, item)
        end
    end
    local function label(it)
        if it.text_func then
            local ok_t, t = pcall(it.text_func)
            if ok_t and t then return t end
        end
        return it.text or ""
    end
    table.sort(items, function(a, b) return label(a) < label(b) end)
    return items
end

function Plugins:init()
    self.t_open = Perf.start()
    self.title = _("Installed Plugins")
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.item_table = self:buildItems()
    Menu.init(self)
end

-- Pinned plugins (shown on Home) -------------------------------------------

Plugins.MAX_PINNED = 4

function Plugins.pinned()
    return Config.get("pinned_plugins") or {}
end

function Plugins.isPinned(name)
    for __, n in ipairs(Plugins.pinned()) do
        if n == name then return true end
    end
    return false
end

--- Pins or unpins a plugin. Returns false (and explains) when the limit is hit.
function Plugins.setPinned(name, pin)
    local list = {}
    for __, n in ipairs(Plugins.pinned()) do
        if n ~= name then table.insert(list, n) end
    end
    if pin then
        if #list >= Plugins.MAX_PINNED then
            UIManager:show(InfoMessage:new{
                text = T(_("Home shows at most %1 pinned plugins. Unpin one first."), Plugins.MAX_PINNED),
            })
            return false
        end
        table.insert(list, name)
    end
    Config.set("pinned_plugins", list)
    return true
end

--- Everything needed to show or open one plugin, or nil if it is not installed.
-- @treturn table { name, text, module, instance, disabled }
function Plugins.find(plugin, name)
    local enabled, disabled = PluginLoader:loadPlugins()
    for __, module in ipairs(enabled or {}) do
        if module.name == name then
            return {
                name = name,
                text = module.fullname or name,
                module = module,
                instance = PluginLoader:getPluginInstance(name) or (plugin and plugin.ui and plugin.ui[name]),
            }
        end
    end
    for __, module in ipairs(disabled or {}) do
        if module.name == name then
            return { name = name, text = module.fullname or name, module = module, disabled = true }
        end
    end
    return nil
end

--- Opens a plugin's own menu (or explains why there is none).
-- Its addToMainMenu() is called only now, for this one plugin.
function Plugins.open(entry)
    local desc = entry.module and entry.module.description or ""
    if entry.disabled then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 is installed but disabled.\n\nYou can enable it in Manage plugins (KOReader) at the end of the Installed Plugins list."), entry.text)
                .. (desc ~= "" and ("\n\n" .. desc) or ""),
        })
        return
    end
    local menu_items = entry.instance and Plugins.collectMenuItems(entry.instance) or {}
    if #menu_items == 0 then
        local msg
        if not entry.instance then
            msg = T(_("%1 is only available while a book is open.\n\nOpen a book, then use the KOReader menu (tap the top of the screen)."), entry.text)
        else
            msg = T(_("%1 is installed and running, but has no menu of its own.\n\nIts options (if any) are in the KOReader menus: Settings → Advanced."), entry.text)
        end
        UIManager:show(InfoMessage:new{ text = msg .. (desc ~= "" and ("\n\n" .. desc) or "") })
        return
    end
    -- A plugin with a single entry that is a sub-menu: open that sub-menu directly.
    local items = menu_items
    if #items == 1 then
        local only = items[1]
        local sub = only.sub_item_table_func and only.sub_item_table_func() or only.sub_item_table
        if sub then
            items = sub
        end
    end
    Common.showTouchMenu(items, "appbar.tools")
end

-- Removing plugins ---------------------------------------------------------------

--- True if `module` is a user-installed plugin that may be deleted (not
-- built into KOReader, not this plugin, folder known).
function Plugins.removable(module)
    if type(module) ~= "table" or not module.name or module.name == "kindleui" then return false end
    if type(module.path) ~= "string" or not module.path:match("%.koplugin/?$") then return false end
    local ok, builtins = pcall(function() return require("kindleui/util/plugininstaller").builtins() end)
    return not (ok and builtins[module.name])
end

--- Deletes the plugin folders; returns the names removed and the ones that failed.
function Plugins.removeAll(modules)
    local Updater = require("kindleui/util/updater")
    local lfs = require("libs/libkoreader-lfs")
    local removed, failed = {}, {}
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    for __, m in ipairs(modules) do
        if Plugins.removable(m) then
            Updater._purge(m.path)
            if lfs.attributes(m.path, "mode") then
                table.insert(failed, m.fullname or m.name)
            else
                table.insert(removed, m.fullname or m.name)
                disabled[m.name] = nil
                if Plugins.isPinned(m.name) then Plugins.setPinned(m.name, false) end
                logger.info("KindleUI: removed plugin", m.name)
            end
        end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    return removed, failed
end

function Plugins:setSelecting(on, first)
    self.selecting = on and true or nil
    self.to_remove = on and {} or nil
    if on and first then self.to_remove[first.name] = first end
    self:switchItemTable(nil, self:buildItems(), -1, nil, self:subtitleText())
end

function Plugins:subtitleText()
    if not self.selecting then return nil end
    local n = 0
    for __ in pairs(self.to_remove) do n = n + 1 end
    return T(_("%1 selected for removal"), n)
end

function Plugins:confirmRemove()
    local modules, names = {}, {}
    for __, m in pairs(self.to_remove) do
        table.insert(modules, m)
        table.insert(names, m.fullname or m.name)
    end
    table.sort(names)
    if #modules == 0 then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove these plugins permanently?\n\n%1\n\nKOReader restarts afterwards. Their settings are kept."),
            table.concat(names, "\n")),
        ok_text = _("Remove"),
        ok_callback = function()
            local removed, failed = Plugins.removeAll(modules)
            self:setSelecting(false)
            if #failed > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not remove:\n%1"), table.concat(failed, "\n")),
                })
            end
            if #removed > 0 then
                UIManager:askForRestart(_("Plugins removed. Restart KOReader now?"))
            end
        end,
    })
end

-- The list ------------------------------------------------------------------

function Plugins:buildItems()
    if self.selecting then return self:buildSelectItems() end
    local enabled, disabled = PluginLoader:loadPlugins()
    local rows = {}
    for __, module in ipairs(enabled or {}) do
        if module.name ~= "kindleui" then
            local instance = PluginLoader:getPluginInstance(module.name)
                or (self.plugin.ui and self.plugin.ui[module.name])
            local has_menu = type(instance) == "table" and type(instance.addToMainMenu) == "function"
            local state
            if has_menu then
                state = _("Open")
            elseif not instance then
                -- is_doc_only plugins only exist while a book is open
                state = _("While reading")
            else
                state = _("No menu")
            end
            if Plugins.isPinned(module.name) then
                state = _("Pinned") .. " · " .. state
            end
            table.insert(rows, {
                text = module.fullname or module.name,
                mandatory = state,
                entry = { name = module.name, text = module.fullname or module.name, module = module, instance = instance },
            })
        end
    end
    for __, module in ipairs(disabled or {}) do
        table.insert(rows, {
            text = module.fullname or module.name,
            mandatory = _("Disabled"),
            entry = { name = module.name, text = module.fullname or module.name, module = module, disabled = true },
        })
    end
    table.sort(rows, function(a, b) return a.text:lower() < b.text:lower() end)
    table.insert(rows, {
        text = _("Install plugin from phone…"),
        mandatory = "",
        install = true,
    })
    table.insert(rows, {
        text = _("Manage plugins (KOReader)…"),
        mandatory = "",
        manage = true,
    })
    return rows
end

-- Selection mode: only removable plugins can be ticked.
function Plugins:buildSelectItems()
    local enabled, disabled = PluginLoader:loadPlugins()
    local rows = {}
    local n = 0
    for __ in pairs(self.to_remove) do n = n + 1 end
    for __, list in ipairs({ enabled or {}, disabled or {} }) do
        for ___, module in ipairs(list) do
            if module.name ~= "kindleui" then
                local removable = Plugins.removable(module)
                local mark = removable and (self.to_remove[module.name] and "☑ " or "☐ ") or ""
                table.insert(rows, {
                    text = mark .. (module.fullname or module.name),
                    mandatory = removable and "" or _("Built-in"),
                    dim = not removable,
                    select_module = removable and module or nil,
                    sort_key = (module.fullname or module.name):lower(),
                })
            end
        end
    end
    table.sort(rows, function(a, b) return a.sort_key < b.sort_key end)
    table.insert(rows, 1, {
        text = T(_("Remove %1 selected…"), n),
        mandatory = "",
        remove_selected = true,
        dim = n == 0,
    })
    table.insert(rows, 2, { text = _("Cancel selection"), mandatory = "", cancel_select = true })
    return rows
end

function Plugins:onMenuChoice(item)
    if self.selecting then
        if item.select_module then
            local name = item.select_module.name
            self.to_remove[name] = not self.to_remove[name] and item.select_module or nil
            self:switchItemTable(nil, self:buildItems(), -1, nil, self:subtitleText())
        elseif item.remove_selected then
            self:confirmRemove()
        elseif item.cancel_select then
            self:setSelecting(false)
        end
        return true
    end
    if item.manage then
        self.plugin:showPluginManagement()
    elseif item.install then
        UIManager:close(self)
        self.plugin:showPluginTransfer()
    elseif item.entry then
        Plugins.open(item.entry)
    end
    return true
end

-- Hold a plugin: pin it to (or unpin it from) Home.
function Plugins:onMenuHold(item)
    if self.selecting then return self:onMenuChoice(item) end
    local entry = item.entry
    if not entry then return true end
    local dialog
    local remove_row = Plugins.removable(entry.module) and {{
        text = _("Select plugins to remove…"),
        callback = function()
            UIManager:close(dialog)
            self:setSelecting(true, entry.module)
        end,
    }} or nil
    if entry.disabled then
        if not remove_row then return true end
        dialog = ButtonDialog:new{ title = entry.text, title_align = "center", buttons = { remove_row } }
        UIManager:show(dialog)
        return true
    end
    local pinned = Plugins.isPinned(entry.name)
    dialog = ButtonDialog:new{
        title = entry.text,
        title_align = "center",
        buttons = {
            {{
                text = pinned and _("Unpin from Home") or _("Pin to Home"),
                callback = function()
                    UIManager:close(dialog)
                    if Plugins.setPinned(entry.name, not pinned) then
                        self:switchItemTable(nil, self:buildItems(), -1)
                        self.plugin:onLibraryChanged() -- Home rebuilds when this screen closes
                    end
                end,
            }},
            {{
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    Plugins.open(entry)
                end,
            }},
            remove_row,
        },
    }
    UIManager:show(dialog)
    return true
end

-- ✕ / Back first leaves selection mode.
function Plugins:onClose()
    if self.selecting then
        self:setSelecting(false)
        return true
    end
    return Menu.onClose(self)
end

function Plugins:paintTo(bb, x, y)
    Menu.paintTo(self, bb, x, y)
    if self.t_open then
        Perf.log("plugins open (to first paint)", self.t_open, { plugins = #self.item_table - 2 })
        self.t_open = nil
    end
end

function Plugins:onCloseWidget()
    Menu.onCloseWidget(self)
    if self.plugin then self.plugin:onChildClosed() end
end

return Plugins
