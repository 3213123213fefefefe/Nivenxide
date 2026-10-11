-- Read-only copy of the game's own mana widget, projected beside the local character.
return function(ctx)
    local player, group = ctx.player, ctx.group
    local gui = assert(player:FindFirstChildOfClass("PlayerGui"), "PlayerGui indisponivel")
    local old = gui:FindFirstChild("NivenxideCharacterMana")
    if old then old:Destroy() end
    local screen = Instance.new("ScreenGui")
    screen.Name = "NivenxideCharacterMana"
    screen.IgnoreGuiInset = true
    screen.ResetOnSpawn = false
    screen.DisplayOrder = 1000
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.Parent = gui
    local host = Instance.new("Frame")
    host.Name = "ManaCopy"
    host.BackgroundTransparency = 1
    host.AnchorPoint = Vector2.new(0.5, 0.5)
    host.Visible = false
    host.Parent = screen
    local number = Instance.new("TextLabel")
    number.Name = "ManaAmount"
    number.BackgroundTransparency = 1
    number.Position = UDim2.new(0.5, -35, 1, 4)
    number.Size = UDim2.fromOffset(70, 18)
    number.Font = Enum.Font.GothamMedium
    number.TextSize = 12
    number.TextColor3 = Color3.fromRGB(255, 255, 255)
    number.TextStrokeTransparency = 0.4
    number.Parent = host
    local enabled, showNumber, opacity = true, false, 70
    local activeOpacity = opacity
    local spellMode, showRanges, highlightRanges = "Magia equipada", true, true
    local spellMana = ctx.spellMana
    local markers = {}
    for index, specification in ipairs({
        {"Gate", false, Color3.fromRGB(255, 205, 80)},
        {"Gelidus", false, Color3.fromRGB(100, 220, 255)},
        {"Gelidus", true, Color3.fromRGB(110, 140, 255)}}) do
        local band = Instance.new("Frame")
        band.Name = specification[2] and "GelidusSnapRange" or specification[1] .. "CastRange"
        band.BorderSizePixel = 0
        band.BackgroundColor3 = specification[3]
        band.ZIndex = 1000
        band.Active = false
        band.Visible = false
        band.Parent = host
        -- Both boundaries sit inside the mana column, like the game's markings.
        local edges = {}
        for _, bottom in ipairs({false, true}) do
            local edge = Instance.new("Frame")
            edge.Name = bottom and "LowerBoundary" or "UpperBoundary"
            edge.BorderSizePixel = 0
            edge.BackgroundColor3 = Color3.fromRGB(35, 25, 36)
            edge.BackgroundTransparency = 0.15
            edge.AnchorPoint = Vector2.new(0, bottom and 1 or 0)
            edge.Position = UDim2.fromScale(0, bottom and 1 or 0)
            edge.Size = UDim2.new(1, 0, 0, 1)
            edge.ZIndex = 1001
            edge.Active = false
            edge.Parent = band
            edges[#edges + 1] = edge
        end
        markers[index] = {name = specification[1], snap = specification[2],
            color = specification[3], band = band, edges = edges}
    end
    local function updateRanges(character, mana)
        local ready = false
        for _, marker in ipairs(markers) do
            local equipped = character:FindFirstChild(marker.name)
            local selected = spellMode == marker.name or spellMode == "Gate + Gelidus"
                or spellMode == "Magia equipada" and equipped ~= nil
            local normal, snap
            if spellMana then normal, snap = spellMana.ranges(marker.name, character) end
            local range = marker.snap and snap or normal
            local visible = showRanges and selected and range ~= nil
            marker.band.Visible = visible
            if visible then
                local inRange = mana ~= nil and spellMana.inside(mana.Value, range)
                ready = ready or inRange
                marker.band.Position = UDim2.new(0, 2, 1 - range[2] / 100, 0)
                marker.band.Size = UDim2.new(1, -4, (range[2] - range[1]) / 100, 0)
                marker.band.BackgroundTransparency = inRange and 0.78 or 0.92
                for _, edge in ipairs(marker.edges) do
                    edge.BackgroundColor3 = inRange and Color3.fromRGB(140, 255, 160)
                        or Color3.fromRGB(35, 25, 36)
                end
            end
        end
        activeOpacity = math.min(100, opacity + (highlightRanges and ready and 15 or 0))
    end
    local x, y, width, height = 75, 0, 18, 160
    local source, copy, pairsToSync, sourceNodes = nil, nil, {}, {}
    local nextScan, closed = 0, false
    local function isScript(instance)
        return instance:IsA("LuaSourceContainer")
    end
    local function pairTree(original, duplicate)
        pairsToSync[#pairsToSync + 1] = {original, duplicate}
        local copies = duplicate:GetChildren()
        local index = 0
        for _, child in ipairs(original:GetChildren()) do
            if not isScript(child) then
                index = index + 1
                if copies[index] then pairTree(child, copies[index]) end
            end
        end
    end
    local function rebuild(original)
        if copy then copy:Destroy() end
        source, copy, pairsToSync, sourceNodes = original, nil, {}, {}
        if not original then return end
        copy = original:Clone()
        if not copy then return end
        for _, child in ipairs(copy:GetDescendants()) do
            if isScript(child) then child:Destroy() end
        end
        copy.Name = "OriginalManaCopy"
        copy.Parent = host
        pairTree(original, copy)
        sourceNodes = original:GetDescendants()
    end
    local guiProperties = {"Position", "Size", "AnchorPoint", "Rotation", "BackgroundColor3",
        "BorderColor3", "BorderSizePixel", "Visible", "ClipsDescendants", "ZIndex"}
    local imageProperties = {"Image", "ImageColor3", "ImageRectOffset", "ImageRectSize", "ScaleType", "SliceCenter", "SliceScale", "TileSize"}
    local textProperties = {"Text", "TextColor3", "TextSize", "Font", "TextScaled", "TextWrapped", "TextXAlignment", "TextYAlignment", "TextStrokeColor3"}
    local function properties(a, b, list, skipGeometry)
        for _, property in ipairs(list) do
            if not skipGeometry or (property ~= "Position" and property ~= "Size" and property ~= "AnchorPoint") then
                b[property] = a[property]
            end
        end
    end
    local function transparency(a, b, property)
        b[property] = 1 - (1 - a[property]) * activeOpacity / 100
    end
    local function sync()
        for _, pair in ipairs(pairsToSync) do
            local a, b = pair[1], pair[2]
            if a:IsA("GuiObject") then
                properties(a, b, guiProperties, a == source)
                b.Active = false
                transparency(a, b, "BackgroundTransparency")
                if a:IsA("ImageLabel") or a:IsA("ImageButton") then
                    properties(a, b, imageProperties)
                    transparency(a, b, "ImageTransparency")
                elseif a:IsA("TextLabel") or a:IsA("TextButton") then
                    properties(a, b, textProperties)
                    transparency(a, b, "TextTransparency")
                    transparency(a, b, "TextStrokeTransparency")
                end
            elseif a:IsA("UIGradient") then
                properties(a, b, {"Color", "Transparency", "Offset", "Rotation", "Enabled"})
            elseif a:IsA("UIStroke") then
                properties(a, b, {"Color", "Thickness", "Enabled"})
                transparency(a, b, "Transparency")
            end
        end
        copy.AnchorPoint = Vector2.new(0, 0)
        copy.Position = UDim2.fromScale(0, 0)
        copy.Size = UDim2.fromScale(1, 1)
    end
    local function update()
        host.Visible = false
        if closed or not enabled then return end
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local camera = workspace.CurrentCamera
        if not root or not camera or (humanoid and humanoid.Health <= 0) then return end
        if os.clock() >= nextScan then
            nextScan = os.clock() + 0.5
            local stats = gui:FindFirstChild("StatGui")
            local left = stats and stats:FindFirstChild("LeftContainer")
            local original = left and left:FindFirstChild("Mana")
            local nodes = original and original:GetDescendants() or {}
            local changed = original ~= source or #nodes ~= #sourceNodes
            for i, node in ipairs(nodes) do if node ~= sourceNodes[i] then changed = true; break end end
            if changed then rebuild(original) end
        end
        if not source or not source.Parent or not copy then return end
        local parent = source
        while parent and parent ~= gui do
            if parent:IsA("GuiObject") and not parent.Visible then return end
            if parent:IsA("ScreenGui") and not parent.Enabled then return end
            parent = parent.Parent
        end
        local point, onScreen = camera:WorldToViewportPoint(root.Position)
        if not onScreen or point.Z <= 0 then return end
        local mana = character:FindFirstChild("Mana")
        updateRanges(character, mana)
        sync()
        host.Size = UDim2.fromOffset(width, height)
        host.Position = UDim2.fromOffset(point.X + x, point.Y + y)
        host.Visible = true
        number.Visible = showNumber and mana ~= nil
        number.Text = mana and tostring(math.floor(math.clamp(mana.Value, 0, 100) + 0.5)) or ""
        number.TextTransparency = 1 - activeOpacity / 100
        number.TextStrokeTransparency = 1 - 0.6 * activeOpacity / 100
    end
    group:AddToggle("NivenxideCharacterMana", {Text = "Copia da mana ao lado do personagem", Default = true,
        Callback = function(value) enabled = value; if not value then host.Visible = false end end})
    group:AddSlider("NivenxideManaOffsetX", {Text = "Posicao horizontal", Default = 75, Min = -400, Max = 400, Rounding = 0,
        Callback = function(value) x = value end})
    group:AddSlider("NivenxideManaOffsetY", {Text = "Posicao vertical", Default = 0, Min = -300, Max = 300, Rounding = 0,
        Callback = function(value) y = value end})
    group:AddSlider("NivenxideManaWidth", {Text = "Largura (pixels)", Default = 18, Min = 6, Max = 100, Rounding = 0,
        Callback = function(value) width = value end})
    group:AddSlider("NivenxideManaHeight", {Text = "Altura (pixels)", Default = 160, Min = 40, Max = 400, Rounding = 0,
        Callback = function(value) height = value end})
    group:AddSlider("NivenxideManaOpacity", {Text = "Opacidade fora da faixa (%)", Default = 70, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) opacity = value end})
    group:AddToggle("NivenxideManaNumber", {Text = "Mostrar valor da mana", Default = false,
        Callback = function(value) showNumber = value end})
    group:AddToggle("NivenxideManaSpellRanges", {Text = "Faixas de Gate e Gelidus", Default = true,
        Callback = function(value) showRanges = value end})
    group:AddDropdown("NivenxideManaSpellMode", {Text = "Mostrar faixas", Default = 1,
        Values = {"Magia equipada", "Gate", "Gelidus", "Gate + Gelidus"},
        Callback = function(value) spellMode = value end})
    group:AddToggle("NivenxideManaRangeHighlight", {Text = "Mais opacidade na faixa certa (+15)", Default = true,
        Callback = function(value) highlightRanges = value end})
    group:AddLabel("Linhas dentro da barra; verde = mana na faixa; destaque limitado a 100%")
    group:AddLabel("Horizontal negativo = esquerda; vertical positivo = baixo")
    local connection = ctx.utility:Connection(game:GetService("RunService").RenderStepped, update)
    local function cleanup()
        if closed then return end
        closed = true
        connection:Disconnect()
        screen:Destroy()
    end
    ctx.library:OnUnload(cleanup)
    return cleanup
end
