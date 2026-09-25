--[[--
Kindle-side steps of "Install plugin from phone", after the .zip arrived:

    review(zip)   look inside (nothing from the zip runs) → pick one plugin if
                  the zip holds several → confirm screen → install → restart
    confirmUndo() "Undo last plugin install" → revert → restart

The file work is in util/plugininstaller.lua; this module only asks and tells.

@module kindleui.ui.plugininstall
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Installer = require("kindleui/util/plugininstaller")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local PluginInstall = {}

local ERRORS = {
    not_zip = _("This file is not a readable .zip archive."),
    no_plugin = _("No KOReader plugin was found in this .zip.\n\nA plugin is a folder named <name>.koplugin with main.lua and _meta.lua inside."),
    builtin = _("%1 is one of KOReader's built-in plugins. It cannot be replaced from here."),
    self = _("This is the Kindle-style Home plugin itself. Use Settings → About → Check for updates to update it."),
    unsafe_path = _("The .zip contains unsafe file paths. Nothing was installed."),
    link = _("The .zip contains links or special files. Nothing was installed."),
    too_big = _("The plugin is too large once unpacked. Nothing was installed."),
    too_many = _("The plugin contains too many files. Nothing was installed."),
    empty = _("The plugin folder is empty. Nothing was installed."),
    disk_full = _("Not enough storage space to install this plugin."),
    extract = _("The plugin could not be unpacked. Nothing was installed."),
    invalid = _("The plugin's main.lua or _meta.lua contains errors. Nothing was installed."),
    swap = _("The plugin could not be moved into place. The installed plugins are unchanged."),
    nothing = _("There is no plugin install to undo."),
}

local function info(text)
    UIManager:show(InfoMessage:new{ text = text })
end

-- Shows a message, lets it paint, runs the (blocking) file work, closes it.
local function withMessage(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, a, b = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.warn("KindleUI installer: error:", a)
        return nil, "extract"
    end
    return a, b
end

local function label(c)
    return c.fullname ~= c.short and T("%1 (%2)", c.fullname, c.name) or c.name
end

local function install(zip_path, analysis, c)
    local ok, err = withMessage(T(_("Installing %1…"), c.fullname), function()
        return Installer.install(zip_path, analysis, c)
    end)
    Installer.clearIncoming()
    if not ok then
        info(T(ERRORS[err] or ERRORS.extract, c.fullname))
        return
    end
    UIManager:askForRestart(T(_("%1 is installed. Restart KOReader now to load it?"), c.fullname))
end

--- The confirm screen for one plugin of the zip.
function PluginInstall.confirm(zip_path, analysis, c)
    if c.builtin or c.name == "kindleui.koplugin" then
        Installer.clearIncoming()
        info(T(c.builtin and ERRORS.builtin or ERRORS.self, c.fullname))
        return
    end
    local parts = { T(_("Install this plugin?\n\n%1"), label(c)) }
    if c.description then table.insert(parts, c.description) end
    table.insert(parts, c.exists
        and _("It replaces the installed version. The current version is kept, so you can undo this in Settings → Advanced.")
        or _("This is a new plugin."))
    table.insert(parts, _("⚠ Plugins have full access to KOReader and to your files. Only install plugins from sources you trust."))
    if c.disabled then
        table.insert(parts, _("This plugin is disabled in Manage plugins. Enable it there after the restart."))
    end
    UIManager:show(ConfirmBox:new{
        text = table.concat(parts, "\n\n"),
        ok_text = c.exists and _("Replace") or _("Install"),
        ok_callback = function() install(zip_path, analysis, c) end,
        cancel_callback = function() Installer.clearIncoming() end,
    })
end

--- Looks at a received zip and walks the user through installing it.
function PluginInstall.review(zip_path, zip_name)
    local analysis, err = Installer.analyze(zip_path, zip_name)
    if not analysis then
        Installer.clearIncoming()
        info(ERRORS[err] or ERRORS.not_zip)
        return
    end
    local candidates = analysis.candidates
    if #candidates == 1 then
        PluginInstall.confirm(zip_path, analysis, candidates[1])
        return
    end
    local dialog
    local buttons = {}
    for __, c in ipairs(candidates) do
        table.insert(buttons, {{
            text = label(c),
            callback = function()
                UIManager:close(dialog)
                PluginInstall.confirm(zip_path, analysis, c)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
            Installer.clearIncoming()
        end,
    }})
    dialog = ButtonDialog:new{
        title = _("This .zip contains several plugins. Which one do you want to install?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Settings → Advanced → Undo last plugin install.
function PluginInstall.confirmUndo()
    local record = Installer.lastInstall()
    if not record then
        info(ERRORS.nothing)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = record.had_previous
            and T(_("Undo the last plugin install?\n\n%1 goes back to the version installed before."), record.name)
            or T(_("Undo the last plugin install?\n\n%1 is removed."), record.name),
        ok_text = _("Undo"),
        ok_callback = function()
            local ok, err = Installer.undo()
            if not ok then
                info(ERRORS[err] or ERRORS.swap)
                return
            end
            UIManager:askForRestart(_("The plugin install was undone. Restart KOReader now?"))
        end,
    })
end

return PluginInstall
