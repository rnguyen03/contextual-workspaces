function onClick()
    noctalia.togglePanel("rnguyen03/contextual-workspaces:panel")
end

local function findContextById(data, id)
    if not data or not data.contexts then
        return nil
    end
    for _, ctx in ipairs(data.contexts) do
        if ctx.id == id then
            return ctx
        end
    end
    return nil
end

local function render(data)
    local active = data and findContextById(data, data.activeContext)

    barWidget.render(ui.row({ gap = 4, align = "center", justify = "center" }, {
        ui.glyph({
            color = active and "primary" or "on_surface",
            name = (active and active.glyph) or "apps",
        }),
    }))
end

--- main
render(noctalia.state.get("cw.data"))

noctalia.state.watch("cw.data", function(data)
    render(data)
end)
