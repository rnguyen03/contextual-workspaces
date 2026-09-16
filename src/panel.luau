local function deepCopyMembers(members)
    local copy = {}
    for i, m in ipairs(members or {}) do
        copy[i] = { label = m.label, class = m.class, workspace = m.workspace, launch = m.launch, pin = m.pin }
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
        table.insert(memberRows, ui.column({ gap = 6, padding = 8, fill = "surface_variant", radius = 8 }, {
            ui.row({ gap = 8, align = "center" }, {
                ui.input({
                    value = m.label,
                    placeholder = noctalia.tr("field.label"),
                    onChange = function(v) editing.members[i].label = v end,
                    flexGrow = 1,
                }),
                ui.button({
                    glyph = "x",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        table.remove(editing.members, i)
                        render()
                    end,
                }),
            }),
            ui.input({
                value = m.launch,
                placeholder = noctalia.tr("field.launch"),
                onChange = function(v) editing.members[i].launch = v end,
            }),
            ui.row({ gap = 8 }, {
                ui.input({
                    value = m.class or "",
                    placeholder = noctalia.tr("field.class"),
                    onChange = function(v) editing.members[i].class = v end,
                    flexGrow = 1,
                }),
                ui.input({
                    value = m.workspace and tostring(m.workspace) or "",
                    placeholder = noctalia.tr("field.workspace"),
                    onChange = function(v) editing.members[i].workspace = tonumber(v) end,
                    width = 64,
                }),
            }),
            ui.row({ align = "center", gap = 8 }, {
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
            }),
        }))
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

function render()
    if editing then
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
    table.insert(editing.members, { label = "", class = "", workspace = nil, launch = "", pin = false })
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
