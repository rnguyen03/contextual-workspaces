-- https://github.com/noctalia-dev/noctalia/blob/main/src/system/desktop_entry_launch.cpp#L45
local function stripFieldCodes(exec)
    local result = exec:gsub("%%(.?)( ?)", function(nextChar, trailingSpace)
        if nextChar:match("[fFuUdDnNick]") then
            return ""
        elseif nextChar == "%" then
            return "%" .. trailingSpace
        else
            return "%" .. nextChar .. trailingSpace
        end
    end)
    result = result:gsub(" +$", "")
    result = result:gsub("@@u *@@", "") -- Flatpak
    return result
end

-- Escapes a literal string for embedding in the Hyprland windowrulev2-style
-- regex our `class` field expects.
local function escapeForClassRegex(s)
    return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$|{}])", "\\%1"))
end

local APP_DIRS = {
    "~/.local/share/applications/",
    "~/.local/share/flatpak/exports/share/applications/",
    "/usr/local/share/applications/",
    "/usr/share/applications/",
    "/var/lib/flatpak/exports/share/applications/",
}

local function parseDesktopEntry(content)
    local data = { hidden = false }
    local inEntry = false
    for line in content:gmatch("[^\r\n]+") do
        local section = line:match("^%s*%[(.-)%]%s*$")
        if section then
            if inEntry then
                break -- only the [Desktop Entry] section matters
            end
            inEntry = (section == "Desktop Entry")
        elseif inEntry then
            local key, value = line:match("^([%w_%-]+)=(.*)$")
            if key == "Name" and not data.name then
                data.name = value
            elseif key == "Exec" then
                data.exec = stripFieldCodes(value)
            elseif key == "Icon" then
                data.icon = value
            elseif key == "StartupWMClass" then
                data.wmClass = value
            elseif key == "Type" then
                data.type = value
            elseif key == "NoDisplay" or key == "Hidden" then
                data.hidden = data.hidden or (value == "true")
            end
        end
    end
    return data
end

-- Enumerates installed .desktop entries once and caches the result; the picker's
-- refresh button clears the cache for anyone who just installed something.
-- Reading .desktop files synchronously blows a UI callback's CPU budget (confirmed
-- live), and firing readFileAsync for all of them at once doesn't work either --
-- confirmed live that it silently accepts only a handful concurrently (36
-- requested, 4 accepted, the rest dropped with no error). So these are read one at
-- a time, only starting the next once the previous one's callback has fired.
local function scanInstalledAppsAsync(onDone)
    local candidates = {}
    local seen = {}
    for _, dir in ipairs(APP_DIRS) do
        local expanded = noctalia.expandPath(dir)
        local entries = noctalia.listDir(expanded)
        for _, entry in ipairs(entries or {}) do
            local id = entry:match("^(.+)%.desktop$")
            if id and not seen[id] then
                seen[id] = true
                table.insert(candidates, { id = id, path = expanded .. entry })
            end
        end
    end

    local apps = {}
    local index = 0

    local function readNext()
        index += 1
        local candidate = candidates[index]
        if not candidate then
            table.sort(apps, function(a, b) return a.name:lower() < b.name:lower() end)
            onDone(apps)
            return
        end

        local accepted = noctalia.readFileAsync(candidate.path, function(content)
            if content then
                local data = parseDesktopEntry(content)
                if data.name and data.exec and not data.hidden
                    and (not data.type or data.type == "Application") then
                    table.insert(apps, {
                        id = candidate.id,
                        name = data.name,
                        exec = data.exec,
                        wmClass = data.wmClass,
                    })
                end
            end
            readNext()
        end)
        if not accepted then
            readNext()
        end
    end

    readNext()
end

local function deepCopyMembers(members)
    local copy = {}
    for i, m in ipairs(members or {}) do
        copy[i] = { label = m.label, class = m.class, workspace = m.workspace, launch = m.launch, pin = m.pin, appId = m.appId }
    end
    return copy
end

local function newContext()
    return { id = "ctx-" .. tostring(math.floor(noctalia.nowMs())), name = "", glyph = "apps", wallpaper = "", colorScheme = nil, members = {} }
end

local COLOR_SCHEME_SOURCES = { "builtin", "wallpaper", "community", "custom" }

local function colorSchemeSourceIndex(ctx)
    local source = ctx.colorScheme and ctx.colorScheme.source
    if not source then
        return nil
    end
    for i, s in ipairs(COLOR_SCHEME_SOURCES) do
        if s == source then
            return i
        end
    end
    return nil
end

--- state
local data = noctalia.state.get("cw.data") or { activeContext = nil, contexts = {} }
local editing = nil
local isNew = false
local picking = nil -- index into editing.members currently picking an app for, or nil
local expandedMembers = {} -- [member index] = true when its advanced fields are shown
local appQuery = ""
local installedApps = nil -- lazy cache, populated async, see scanInstalledAppsAsync
local scanningApps = false

local function ensureAppsScanned()
    if installedApps or scanningApps then
        return
    end
    scanningApps = true
    scanInstalledAppsAsync(function(apps)
        installedApps = apps
        scanningApps = false
        render()
    end)
end

local function filteredApps()
    local apps = installedApps or {}
    if appQuery == "" then
        return apps
    end
    local scored = {}
    for _, app in ipairs(apps) do
        local score = noctalia.fuzzyScore(appQuery, app.name)
        if score then
            table.insert(scored, { app = app, score = score })
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local out = {}
    for _, s in ipairs(scored) do
        table.insert(out, s.app)
    end
    return out
end

local function renderList()
    local rows = {}
    for _, ctx in ipairs(data.contexts) do
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.glyph({
                name = ctx.glyph or "apps",
                color = (data.activeContext == ctx.id) and "primary" or "on_surface",
            }),
            ui.label({
                text = ctx.name,
                fontSize = 14,
                fontWeight = "medium",
                flexGrow = 1,
                color = "on_surface",
            }),
            ui.label({
                text = tostring(#(ctx.members or {})) .. " apps",
                fontSize = 11,
                color = "on_surface_variant",
            }),
            ui.button({
                glyph = "player-play",
                variant = "ghost",
                controlSize = "sm",
                onClick = function() onLaunchClick(ctx.id) end,
            }),
            ui.button({
                glyph = "pencil",
                variant = "ghost",
                controlSize = "sm",
                onClick = function() onEditContextClick(ctx.id) end,
            }),
            ui.button({
                glyph = "trash",
                variant = "ghost",
                controlSize = "sm",
                onClick = function() onDeleteContextClick(ctx.id) end,
            }),
        }))
    end

    local body
    if #rows == 0 then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "apps", color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("empty-state"),
                fontSize = 13,
                color = "on_surface_variant",
                textAlign = "center",
            }),
        })
    else
        body = ui.scroll({ flexGrow = 1, gap = 8 }, rows)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "apps", color = "primary" }),
            ui.label({
                text = noctalia.tr("title"),
                fontSize = 18,
                fontWeight = "bold",
                flexGrow = 1,
                color = "on_surface",
            }),
            ui.button({
                glyph = "plus",
                text = noctalia.tr("button.new"),
                variant = "primary",
                controlSize = "sm",
                onClick = onNewContextClick,
            }),
        }),
        body,
    }))
end

local function renderEdit()
    local memberRows = {}
    for i, m in ipairs(editing.members) do
        local hasApp = m.launch and m.launch ~= ""
        local expanded = expandedMembers[i]

        local function openPickerForRow()
            picking = i
            appQuery = ""
            ensureAppsScanned()
            render()
        end

        local function removeRow()
            table.remove(editing.members, i)
            expandedMembers[i] = nil
            render()
        end

        local header
        if hasApp then
            local iconPath = m.appId and noctalia.appIconPath(m.appId) or nil
            header = ui.row({ gap = 8, align = "center" }, {
                iconPath and ui.image({ path = iconPath, width = 28, height = 28 })
                    or ui.glyph({ name = "apps", color = "on_surface_variant" }),
                ui.label({
                    text = (m.label and m.label ~= "") and m.label or noctalia.tr("field.custom-app"),
                    fontSize = 14,
                    fontWeight = "medium",
                    flexGrow = 1,
                    color = "on_surface",
                }),
                ui.button({
                    glyph = "search",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = openPickerForRow,
                }),
                ui.button({
                    glyph = "x",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = removeRow,
                }),
            })
        else
            header = ui.row({ gap = 8, align = "center" }, {
                ui.button({
                    glyph = "search",
                    text = noctalia.tr("button.pick-app"),
                    variant = "primary",
                    controlSize = "sm",
                    flexGrow = 1,
                    onClick = openPickerForRow,
                }),
                ui.button({
                    glyph = "x",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = removeRow,
                }),
            })
        end

        local rowChildren = {
            header,
            ui.row({ align = "center", gap = 8 }, {
                ui.input({
                    value = m.workspace and tostring(m.workspace) or "",
                    placeholder = noctalia.tr("field.workspace"),
                    onChange = function(v) editing.members[i].workspace = tonumber(v) end,
                    width = 64,
                }),
                ui.toggle({
                    checked = m.pin == true,
                    onChange = function(v) editing.members[i].pin = v end,
                }),
                ui.label({
                    text = noctalia.tr("field.pin"),
                    fontSize = 12,
                    color = "on_surface_variant",
                    flexGrow = 1,
                }),
                ui.button({
                    glyph = expanded and "chevron-up" or "chevron-down",
                    text = noctalia.tr("button.advanced"),
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        expandedMembers[i] = not expanded
                        render()
                    end,
                }),
            }),
        }

        if expanded then
            table.insert(rowChildren, ui.column({ gap = 6, padding = 8, fill = "surface", radius = 6 }, {
                ui.input({
                    value = m.label,
                    placeholder = noctalia.tr("field.label"),
                    onChange = function(v) editing.members[i].label = v end,
                }),
                ui.input({
                    value = m.launch,
                    placeholder = noctalia.tr("field.launch"),
                    onChange = function(v)
                        editing.members[i].launch = v
                        editing.members[i].appId = nil -- no longer necessarily what that icon shows
                    end,
                }),
                ui.input({
                    value = m.class or "",
                    placeholder = noctalia.tr("field.class"),
                    onChange = function(v) editing.members[i].class = v end,
                }),
            }))
        end

        table.insert(memberRows, ui.column({ gap = 6, padding = 8, fill = "surface_variant", radius = 8 }, rowChildren))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                controlSize = "sm",
                onClick = onCancelEdit,
            }),
            ui.label({
                text = isNew and noctalia.tr("title.new-context") or noctalia.tr("title.edit-context"),
                fontSize = 18,
                fontWeight = "bold",
                flexGrow = 1,
                color = "on_surface",
            }),
        }),
        ui.row({ gap = 8 }, {
            ui.input({
                value = editing.name,
                placeholder = noctalia.tr("field.context-name"),
                onChange = function(v) editing.name = v end,
                flexGrow = 1,
            }),
            ui.input({
                value = editing.glyph or "apps",
                placeholder = noctalia.tr("field.glyph"),
                onChange = function(v) editing.glyph = v end,
                width = 90,
            }),
        }),
        ui.input({
            value = editing.wallpaper or "",
            placeholder = noctalia.tr("field.wallpaper"),
            onChange = function(v) editing.wallpaper = v end,
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.select({
                options = COLOR_SCHEME_SOURCES,
                selectedIndex = colorSchemeSourceIndex(editing),
                placeholder = noctalia.tr("field.color-scheme-source"),
                onChange = function(_, text)
                    editing.colorScheme = editing.colorScheme or {}
                    editing.colorScheme.source = text
                end,
                width = 140,
            }),
            ui.input({
                value = (editing.colorScheme and editing.colorScheme.name) or "",
                placeholder = noctalia.tr("field.color-scheme-name"),
                onChange = function(v)
                    editing.colorScheme = editing.colorScheme or {}
                    editing.colorScheme.name = v
                end,
                flexGrow = 1,
            }),
        }),
        ui.scroll({ flexGrow = 1, gap = 8 }, memberRows),
        ui.button({
            text = noctalia.tr("button.add-app"),
            variant = "outline",
            onClick = onAddMember,
        }),
        ui.row({ gap = 8 }, {
            ui.button({
                text = noctalia.tr("button.cancel"),
                variant = "ghost",
                onClick = onCancelEdit,
                flexGrow = 1,
            }),
            ui.button({
                text = noctalia.tr("button.save"),
                variant = "primary",
                onClick = onSaveEdit,
                flexGrow = 1,
            }),
        }),
    }))
end

local function onPickApp(app)
    local i = picking
    editing.members[i].launch = app.exec
    editing.members[i].appId = app.id
    if editing.members[i].label == "" then
        editing.members[i].label = app.name
    end

    local classSource = app.wmClass
    if not classSource or classSource == "" then
        -- No StartupWMClass: best-effort guess from the exec's binary name, left
        -- editable like everything else here.
        classSource = app.exec:match("^%S+"):match("([^/]+)$")
    end
    if classSource then
        editing.members[i].class = "^(" .. escapeForClassRegex(classSource) .. ")$"
    end

    picking = nil
    render()
end

local function onCancelPick()
    picking = nil
    render()
end

local function renderPicker()
    local rows = {}
    for _, app in ipairs(filteredApps()) do
        table.insert(rows, ui.row({
            align = "center",
            gap = 8,
            padding = 4,
            onClick = function() onPickApp(app) end,
        }, {
            ui.image({ path = noctalia.appIconPath(app.id), width = 28, height = 28 }),
            ui.label({ text = app.name, fontSize = 13, flexGrow = 1, color = "on_surface" }),
        }))
    end

    local body
    if #rows == 0 then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.label({
                text = scanningApps and noctalia.tr("empty-state.apps-scanning") or noctalia.tr("empty-state.apps"),
                fontSize = 13,
                color = "on_surface_variant",
                textAlign = "center",
            }),
        })
    else
        body = ui.scroll({ flexGrow = 1, gap = 2 }, rows)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                controlSize = "sm",
                onClick = onCancelPick,
            }),
            ui.label({
                text = noctalia.tr("title.pick-app"),
                fontSize = 18,
                fontWeight = "bold",
                flexGrow = 1,
                color = "on_surface",
            }),
            ui.button({
                glyph = "refresh",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    installedApps = nil
                    ensureAppsScanned()
                    render()
                end,
            }),
        }),
        ui.input({
            value = appQuery,
            placeholder = noctalia.tr("field.search-apps"),
            onChange = function(v)
                appQuery = v
                render()
            end,
        }),
        body,
    }))
end

function render()
    if picking then
        renderPicker()
    elseif editing then
        renderEdit()
    else
        renderList()
    end
end

function onNewContextClick()
    editing = newContext()
    isNew = true
    render()
end

function onEditContextClick(id)
    for _, ctx in ipairs(data.contexts) do
        if ctx.id == id then
            editing = {
                id = ctx.id,
                name = ctx.name,
                glyph = ctx.glyph,
                wallpaper = ctx.wallpaper,
                colorScheme = ctx.colorScheme and { source = ctx.colorScheme.source, name = ctx.colorScheme.name } or nil,
                members = deepCopyMembers(ctx.members),
            }
            isNew = false
            break
        end
    end
    render()
end

function onCancelEdit()
    editing = nil
    render()
end

function onAddMember()
    table.insert(editing.members, { label = "", class = "", workspace = nil, launch = "", pin = false, appId = nil })
    render()
end

function onSaveEdit()
    if not editing.name or editing.name == "" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.name-required"))
        return
    end

    local found = false
    for i, ctx in ipairs(data.contexts) do
        if ctx.id == editing.id then
            data.contexts[i] = editing
            found = true
            break
        end
    end
    if not found then
        table.insert(data.contexts, editing)
    end

    noctalia.state.set("cw.command", { action = "save", data = data })
    editing = nil
    render()
end

function onDeleteContextClick(id)
    for i, ctx in ipairs(data.contexts) do
        if ctx.id == id then
            table.remove(data.contexts, i)
            break
        end
    end
    noctalia.state.set("cw.command", { action = "save", data = data })
    render()
end

function onLaunchClick(id)
    noctalia.state.set("cw.command", { action = "launch", id = id })
end

function onOpen(context)
    render()
end

--- main
noctalia.state.watch("cw.data", function(newData)
    data = newData
    if not editing then
        render()
    end
end)

render()
