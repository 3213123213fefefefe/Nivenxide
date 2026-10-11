-- Read-only copy of the game's own mana widget, projected beside the local character.
return function(ctx)
    local player, group = ctx.player, ctx.group
    local rangesGroup, intentGroup, snapGroup = ctx.rangesGroup or group, ctx.intentGroup or group, ctx.snapGroup or group
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
    number.AnchorPoint = Vector2.new(0.5, 0)
    number.Visible = false
    number.Size = UDim2.fromOffset(70, 18)
    number.Font = Enum.Font.GothamMedium
    number.TextSize = 12
    number.TextColor3 = Color3.fromRGB(255, 255, 255)
    number.TextStrokeTransparency = 0.4
    number.Parent = screen
    local numberX, numberY, numberOpacity = 75, 84, 70
    local intent = Instance.new("TextLabel")
    intent.Name = "SelfEquippedItem"
    intent.BackgroundTransparency = 1
    intent.AnchorPoint = Vector2.new(0.5, 0)
    intent.Size = UDim2.fromOffset(240, 22)
    intent.Font = Enum.Font.GothamMedium
    intent.TextSize = 13
    intent.TextColor3 = Color3.fromRGB(255, 255, 255)
    intent.TextStrokeTransparency = 0.35
    intent.Visible = false
    intent.Parent = screen
    local showIntent, intentX, intentY = true, 0, 100
    local snapStatus = Instance.new("TextLabel")
    snapStatus.Name = "LocalSnapCooldown"
    snapStatus.BackgroundTransparency = 1
    snapStatus.AnchorPoint = Vector2.new(0, 0.5)
    snapStatus.Size = UDim2.fromOffset(120, 22)
    snapStatus.Font = Enum.Font.GothamMedium
    snapStatus.TextSize = 12
    snapStatus.TextColor3 = Color3.fromRGB(255, 255, 255)
    snapStatus.TextStrokeTransparency = 0.35
    snapStatus.TextXAlignment = Enum.TextXAlignment.Left
    snapStatus.ZIndex = 1010
    snapStatus.Parent = screen
    local showSnapTimer = true
    local pendingGelidus, snapEffectSeen = nil, false
    local showSnap, snapX, snapY, snapOpacity, snapSize = true, 8, 0, 70, 10
    local snapDurations, snapStarted, snapCharacter, snapOwner, lastEquipped = {}, nil, nil, nil, nil
    local spellMana = ctx.spellMana
    local collection = game:GetService("CollectionService")
    local input = game:GetService("UserInputService")
    local inputConnection = ctx.utility:Connection(input.InputBegan, function(event)
        if event.UserInputType ~= Enum.UserInputType.MouseButton2 or input:GetFocusedTextBox() then return end
        local character = player.Character
        local tool = character and character:FindFirstChildOfClass("Tool")
        local mana = character and character:FindFirstChild("Mana")
        if not tool or tool.Name ~= "Gelidus" or not mana or snapStarted then return end
        if character:FindFirstChild("SnapCool") or collection:HasTag(character, "SnapCool") then return end
        local window
        if spellMana then local normal; normal, window = spellMana.ranges("Gelidus", character) end
        if window and (mana.Value < window[1] or mana.Value > window[2]) then return end
        -- A request alone is not a cast: wait for a mana decrease before displaying it.
        pendingGelidus = {character = character, time = os.clock(), mana = mana.Value}
    end)
    local enabled, showNumber, opacity = true, false, 70
    local activeOpacity = opacity
    local readyOpacityBoost = 15
    local rangeOpacity, boundaryOpacity = 35, 85
    local viribusSnapMin, viribusSnapMax = 55, 70
    local spellMode, showRanges, highlightRanges = "Magia equipada", true, true
    local fixedDetails = {}
    local fixedLines, showFixed50, showFixed20 = {}, true, true
    for _, percent in ipairs({50, 20}) do
        local line = Instance.new("Frame")
        line.Name = "FixedMana" .. percent
        line.BorderSizePixel = 0
        line.AnchorPoint = Vector2.new(0, 0.5)
        line.Position = UDim2.fromScale(0, 1 - percent / 100)
        line.Size = UDim2.new(1, 0, 0, 1)
        line.BackgroundColor3 = Color3.fromRGB(35, 25, 36)
        line.ZIndex = 1003
        line.Active = false
        line.Parent = host
        fixedLines[percent] = line
        fixedDetails[#fixedDetails + 1] = line
        if percent == 50 then
            for _, detail in ipairs({
                {0, 0, 0, 3}, {1, 0, 0, 3}, {0.5, 0, 0, 2},
                {0.5, -3, -3, 2}, {0.5, 3, -3, 2},
                {0.5, -3, 3, 2}, {0.5, 3, 3, 2}}) do
                local ornament = Instance.new("Frame")
                ornament.Name = "MiddleManaDecoration"
                ornament.BorderSizePixel = 0
                ornament.AnchorPoint = Vector2.new(0.5, 0.5)
                ornament.Position = UDim2.new(detail[1], detail[2], 0.5, detail[3])
                ornament.Size = UDim2.fromOffset(detail[4], detail[4])
                ornament.Rotation = 45
                ornament.BackgroundColor3 = Color3.fromRGB(35, 25, 36)
                ornament.ZIndex = 1004
                ornament.Active = false
                ornament.Parent = line
                fixedDetails[#fixedDetails + 1] = ornament
            end
        end

    end
    local markers = {}
    for index, specification in ipairs({
        {"Gate", false, Color3.fromRGB(145, 65, 205)},
        {"Gelidus", false, Color3.fromRGB(100, 220, 255)},
        {"Gelidus", true, Color3.fromRGB(110, 140, 255)},
        {"Viribus", true, Color3.fromRGB(180, 90, 95)}}) do
        local band = Instance.new("Frame")
        band.Name = specification[1] .. (specification[2] and "SnapRange" or "CastRange")
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
        fixedLines[50].Visible = showFixed50
        fixedLines[20].Visible = showFixed20
        -- Fixed reference ticks remain visible regardless of spell/range selection.
        for _, detail in ipairs(fixedDetails) do
            detail.BackgroundTransparency = 1 - boundaryOpacity / 100
        end
        local ready = false
        for _, marker in ipairs(markers) do
            local equipped = character:FindFirstChild(marker.name)
            local selected = spellMode == marker.name or spellMode == "Todas"
                or spellMode == "Snap Viribus + Snap Gate" and (marker.name == "Viribus" or marker.name == "Gate")
                or spellMode == "Snap Viribus" and marker.name == "Viribus"
                or spellMode == "Gate + Gelidus" and (marker.name == "Gate" or marker.name == "Gelidus")
                or spellMode == "Magia equipada" and equipped ~= nil
            local normal, snap
            if spellMana then normal, snap = spellMana.ranges(marker.name, character) end
            local range = marker.snap and snap or normal
            if marker.name == "Viribus" and marker.snap and range then
                -- Visual calibration from the reference; spell casting rules stay unchanged.
                local bonus = math.max(0, 60 - range[1])
                range = {math.max(0, math.min(viribusSnapMin, viribusSnapMax) - bonus),
                    math.min(100, math.max(viribusSnapMin, viribusSnapMax) + bonus)}
            end
            if spellMode == "Snap Viribus + Snap Gate" and marker.name == "Gate" then
                range = snap
            end
            local visible = showRanges and selected and range ~= nil
            marker.band.Visible = visible
            if visible then
                local inRange = mana ~= nil and spellMana.inside(mana.Value, range)
                ready = ready or inRange
                marker.band.Position = UDim2.new(0, 0, 1 - range[2] / 100, 0)
                marker.band.Size = UDim2.new(1, 0, (range[2] - range[1]) / 100, 0)
                marker.band.BackgroundTransparency = 1 - math.min(100,
                    rangeOpacity + (highlightRanges and inRange and readyOpacityBoost or 0)) / 100
                for _, edge in ipairs(marker.edges) do
                    edge.BackgroundTransparency = 1 - boundaryOpacity / 100
                    edge.BackgroundColor3 = Color3.fromRGB(35, 25, 36)
                end

            end
        end
        activeOpacity = math.min(100, opacity + (highlightRanges and ready and readyOpacityBoost or 0))
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
        number.Visible = false
        intent.Visible = false
        snapStatus.Visible = false
        if closed then return end
        local character = player.Character
        if character ~= snapCharacter then
            snapCharacter, snapStarted, snapOwner, lastEquipped = character, nil, nil, nil
            pendingGelidus, snapEffectSeen = nil, false
        end
        local tool = character and character:FindFirstChildOfClass("Tool")
        if tool then lastEquipped = tool.Name end
        local cooling = character ~= nil and (character:FindFirstChild("SnapCool") ~= nil
            or collection:HasTag(character, "SnapCool"))
        if pendingGelidus then
            local mana = character and character:FindFirstChild("Mana")
            if character ~= pendingGelidus.character or os.clock() - pendingGelidus.time > 1 then
                pendingGelidus = nil
            elseif mana and mana.Value < pendingGelidus.mana - 0.5 then
                snapStarted, snapOwner = pendingGelidus.time, "Gelidus"
                snapEffectSeen, pendingGelidus = cooling, nil
            end
        end
        if cooling then
            snapEffectSeen = true
            if not snapStarted then
                snapStarted = os.clock()
                snapOwner = tool and tool.Name or lastEquipped
            end
        elseif snapEffectSeen or (snapStarted and os.clock() - snapStarted >= (snapDurations[snapOwner] or 8)) then
            snapStarted, snapOwner, snapEffectSeen = nil, nil, false
        end
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local camera = workspace.CurrentCamera
        if not root or not camera or (humanoid and humanoid.Health <= 0) then return end
        local point, onScreen = camera:WorldToViewportPoint(root.Position)
        if not onScreen or point.Z <= 0 then return end
        intent.Visible = showIntent and tool ~= nil
        intent.Text = tool and tool.Name or ""
        intent.Position = UDim2.fromOffset(point.X + intentX, point.Y + intentY)
        local snapActive = cooling or snapStarted ~= nil
        snapStatus.Visible = showSnap and snapActive
        local duration = snapOwner and snapDurations[snapOwner]
        local remaining = snapStarted and duration and math.max(0, duration - (os.clock() - snapStarted)) or 0
        snapStatus.Text = snapActive and (showSnapTimer and remaining > 0 and string.format("Snap CD · ~%.1fs", remaining) or "Snap CD") or ""
        snapStatus.TextColor3 = Color3.fromRGB(225, 225, 225)
        snapStatus.Position = UDim2.fromOffset(point.X + x + width / 2 + snapX, point.Y + y + snapY)
        snapStatus.TextSize = snapSize
        snapStatus.TextTransparency = 1 - snapOpacity / 100
        snapStatus.TextStrokeTransparency = 1 - 0.65 * snapOpacity / 100
        local mana = character:FindFirstChild("Mana")
        number.Visible = showNumber and mana ~= nil
        number.Text = mana and (tostring(math.floor(math.clamp(mana.Value, 0, 100) + 0.5)) .. "%") or ""
        number.Position = UDim2.fromOffset(point.X + numberX, point.Y + numberY)
        number.TextTransparency = 1 - numberOpacity / 100
        number.TextStrokeTransparency = 1 - 0.6 * numberOpacity / 100
        if not enabled then return end
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
        updateRanges(character, mana)
        sync()
        host.Size = UDim2.fromOffset(width, height)
        host.Position = UDim2.fromOffset(point.X + x, point.Y + y)
        host.Visible = true
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
    group:AddSlider("NivenxideManaOpacity", {Text = "Opacidade da barra (%)", Default = 70, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) opacity = value end})
    rangesGroup:AddSlider("NivenxideManaRangeOpacity", {Text = "Opacidade das faixas (%)", Default = 35, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) rangeOpacity = value end})
    rangesGroup:AddSlider("NivenxideManaBoundaryOpacity", {Text = "Opacidade das linhas (%)", Default = 85, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) boundaryOpacity = value end})
    group:AddToggle("NivenxideManaNumber", {Text = "Mostrar % da mana (independente da barra)", Default = false,
        Callback = function(value) showNumber = value; if not value then number.Visible = false end end})
    group:AddSlider("NivenxideManaNumberX", {Text = "% da mana: posicao horizontal", Default = 75, Min = -400, Max = 400, Rounding = 0,
        Callback = function(value) numberX = value end})
    group:AddSlider("NivenxideManaNumberY", {Text = "% da mana: posicao vertical", Default = 84, Min = -300, Max = 400, Rounding = 0,
        Callback = function(value) numberY = value end})
    group:AddSlider("NivenxideManaNumberOpacity", {Text = "% da mana: opacidade (%)", Default = 70, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) numberOpacity = value end})
    rangesGroup:AddToggle("NivenxideManaFixed50", {Text = "Mostrar marca de 50%", Default = true,
        Callback = function(value) showFixed50 = value end})
    rangesGroup:AddToggle("NivenxideManaFixed20", {Text = "Mostrar marca de 20%", Default = true,
        Callback = function(value) showFixed20 = value end})
    rangesGroup:AddToggle("NivenxideManaSpellRanges", {Text = "Faixas de Gate, Gelidus e snap Viribus", Default = true,
        Callback = function(value) showRanges = value end})
    rangesGroup:AddDropdown("NivenxideManaSpellMode", {Text = "Mostrar faixas", Default = 1,
        Values = {"Magia equipada", "Gate", "Gelidus", "Gate + Gelidus", "Snap Viribus", "Todas", "Snap Viribus + Snap Gate"},
        Callback = function(value) spellMode = value end})
    rangesGroup:AddToggle("NivenxideManaRangeHighlight", {Text = "Mais opacidade na faixa certa", Default = true,
        Callback = function(value) highlightRanges = value end})
    rangesGroup:AddSlider("NivenxideManaReadyOpacityBoost", {Text = "Aumento de opacidade na faixa certa (%)", Default = 15, Min = 0, Max = 100, Rounding = 0,
        Callback = function(value) readyOpacityBoost = value end})
    rangesGroup:AddSlider("NivenxideManaViribusSnapMin", {Text = "Inicio da marcacao snap Viribus (%)", Default = 55, Min = 0, Max = 100, Rounding = 0,
        Callback = function(value) viribusSnapMin = value end})
    rangesGroup:AddSlider("NivenxideManaViribusSnapMax", {Text = "Fim da marcacao snap Viribus (%)", Default = 70, Min = 0, Max = 100, Rounding = 0,
        Callback = function(value) viribusSnapMax = value end})
    intentGroup:AddToggle("NivenxideSelfIntent", {Text = "Item equipado abaixo do personagem", Default = true,
        Callback = function(value) showIntent = value; if not value then intent.Visible = false end end})
    intentGroup:AddSlider("NivenxideSelfIntentX", {Text = "Item equipado: posicao horizontal", Default = 0, Min = -400, Max = 400, Rounding = 0,
        Callback = function(value) intentX = value end})
    intentGroup:AddSlider("NivenxideSelfIntentY", {Text = "Item equipado: posicao vertical", Default = 100, Min = -300, Max = 400, Rounding = 0,
        Callback = function(value) intentY = value end})
    snapGroup:AddToggle("NivenxideManaSnapStatus", {Text = "Status de SnapCool ao lado da mana", Default = true,
        Callback = function(value) showSnap = value end})
    snapGroup:AddToggle("NivenxideManaSnapTimer", {Text = "Mostrar tempo restante", Default = true,
        Callback = function(value) showSnapTimer = value end})
    local snapSpells = spellMana and spellMana.spellNames and spellMana.spellNames() or {"Gate", "Gelidus", "Viribus"}
    local snapControls, selectedSnapSpell = {}, "Gate"
    local function selectSnapSpell(name)
        selectedSnapSpell = name
        for spell, control in pairs(snapControls) do
            if control.SetVisible then control:SetVisible(spell == name) end
        end
    end
    snapGroup:AddDropdown("NivenxideManaSnapConfigSpell", {Text = "Configurar CD de snap da spell", Default = "Gate",
        Values = snapSpells, Callback = selectSnapSpell})
    for _, name in ipairs(snapSpells) do
        local spell = name
        snapDurations[spell] = 8
        snapControls[spell] = snapGroup:AddInput("NivenxideManaSnapCD_" .. spell, {
            Text = "Snap " .. spell .. ": CD estimado (s)", Default = "8", Finished = true,
            Callback = function(value)
                local seconds = tonumber((tostring(value):gsub(",", ".")))
                if seconds and seconds >= 0.1 and seconds <= 120 then
                    snapDurations[spell] = seconds
                else
                    ctx.library:Notify("Digite um CD entre 0.1 e 120 segundos", 4)
                end
            end})
    end
    selectSnapSpell(selectedSnapSpell)
    snapGroup:AddLabel("Gelidus: clique direito + gasto de mana; outros: inicio de SnapCool")
    snapGroup:AddSlider("NivenxideManaSnapX", {Text = "SnapCool: posicao horizontal", Default = 8, Min = -300, Max = 300, Rounding = 0,
        Callback = function(value) snapX = value end})
    snapGroup:AddSlider("NivenxideManaSnapY", {Text = "SnapCool: posicao vertical", Default = 0, Min = -300, Max = 300, Rounding = 0,
        Callback = function(value) snapY = value end})
    snapGroup:AddSlider("NivenxideManaSnapOpacity", {Text = "SnapCool: opacidade (%)", Default = 70, Min = 1, Max = 100, Rounding = 0,
        Callback = function(value) snapOpacity = value end})
    snapGroup:AddSlider("NivenxideManaSnapSize", {Text = "SnapCool: tamanho do texto", Default = 10, Min = 8, Max = 24, Rounding = 0,
        Callback = function(value) snapSize = value end})
    rangesGroup:AddLabel("Linhas dentro da barra; destaque de opacidade limitado a 100%")
    group:AddLabel("Horizontal negativo = esquerda; vertical positivo = baixo")
    local connection = ctx.utility:Connection(game:GetService("RunService").RenderStepped, update)
    local function cleanup()
        if closed then return end
        closed = true
        connection:Disconnect()
        inputConnection:Disconnect()
        screen:Destroy()
    end
    ctx.library:OnUnload(cleanup)
    return cleanup
end
