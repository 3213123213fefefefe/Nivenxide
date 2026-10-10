-- Local visual indicators. Does not modify game hotbar buttons or protections.
return function(ctx)
    local player, states, group = ctx.player, ctx.states, ctx.group
    local runService = game:GetService("RunService")
    local collection = game:GetService("CollectionService")
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    assert(playerGui, "PlayerGui indisponivel")
    local old = playerGui:FindFirstChild("NivenxideCooldownVisuals")
    if old then old:Destroy() end
    local screen = Instance.new("ScreenGui")
    screen.Name = "NivenxideCooldownVisuals"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.DisplayOrder = 1000
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.Parent = playerGui
    local oldFoot = playerGui:FindFirstChild("NivenxideNoFallFeet")
    if oldFoot then oldFoot:Destroy() end
    local foot = Instance.new("BillboardGui")
    foot.Name = "NivenxideNoFallFeet"
    foot.Size = UDim2.fromOffset(160, 24)
    foot.AlwaysOnTop = false
    foot.MaxDistance = 100
    foot.Enabled = false
    foot.Parent = playerGui
    local footText = Instance.new("TextLabel")
    footText.BackgroundTransparency = 1
    footText.Size = UDim2.fromScale(1, 1)
    footText.Font = Enum.Font.GothamMedium
    footText.TextSize = 12
    footText.TextColor3 = Color3.fromRGB(185, 235, 210)
    footText.TextTransparency = 0.15
    footText.TextStrokeTransparency = 0.65
    footText.Parent = foot
    local hotbarEnabled, noFallEnabled, showNumbers, opacity = true, true, true, 40
    local footHeight = 0.15
    local overlays, slots = {}, {}
    local lastScan, observedCharacter, previousProtection, protectionSince, estimate = -10, nil, false, nil, nil
    local destroyed = false
    local function newOverlay(name)
        local container = Instance.new("Frame")
        container.Name = "CD_" .. name
        container.BackgroundTransparency = 1
        container.BorderSizePixel = 0
        container.Active = false
        container.Visible = false
        container.Parent = screen
        local shade = Instance.new("Frame")
        shade.AnchorPoint = Vector2.new(0, 1)
        shade.Position = UDim2.fromScale(0, 1)
        shade.Size = UDim2.fromScale(1, 1)
        shade.BackgroundColor3 = Color3.fromRGB(115, 115, 115)
        shade.BackgroundTransparency = 1 - opacity / 100
        shade.BorderSizePixel = 0
        shade.Active = false
        shade.Parent = container
        local text = Instance.new("TextLabel")
        text.BackgroundTransparency = 1
        text.Size = UDim2.fromScale(1, 1)
        text.Font = Enum.Font.GothamMedium
        text.TextSize = 12
        text.TextColor3 = Color3.fromRGB(240, 240, 240)
        text.TextStrokeTransparency = 0.6
        text.Active = false
        text.Parent = container
        return {container = container, shade = shade, text = text}
    end
    for name in pairs(states) do overlays[name] = newOverlay(name) end
    local function scanHotbar()
        slots = {}
        local backpackGui = playerGui:FindFirstChild("BackpackGui")
        local main = backpackGui and backpackGui:FindFirstChild("MainFrame")
        if not main then return end
        for _, button in ipairs(main:GetChildren()) do
            if button:IsA("GuiButton") then
                local name = button.Name:gsub("^%d+", "")
                if states[name] then slots[name] = button end
            end
        end
    end
    local function visible(button)
        local ancestor = button
        while ancestor and ancestor ~= playerGui do
            if ancestor:IsA("GuiObject") and not ancestor.Visible then return false end
            if ancestor:IsA("ScreenGui") and not ancestor.Enabled then return false end
            ancestor = ancestor.Parent
        end
        return ancestor == playerGui
    end
    local function protected(character)
        -- NoFall is the actual marker used by the original Feather Feet logic.
        return character:FindFirstChild("NoFall") ~= nil
            or collection:HasTag(character, "NoFall")
    end
    local function update(dt)
        if destroyed then return end
        if ctx.library.Unloaded then return end
        local now = os.clock()
        if now - lastScan >= 0.25 then scanHotbar(); lastScan = now end
        for name, overlay in pairs(overlays) do
            local state, button = states[name], slots[name]
            local remaining = state.start and math.max(0, state.duration - (now - state.start)) or 0
            local active = hotbarEnabled and ctx.trackingEnabled() and state.visible
                and state.duration > 0 and remaining > 0 and button and button.Parent and visible(button)
            overlay.container.Visible = active and true or false
            if active then
                overlay.container.Position = UDim2.fromOffset(button.AbsolutePosition.X, button.AbsolutePosition.Y)
                overlay.container.Size = UDim2.fromOffset(button.AbsoluteSize.X, button.AbsoluteSize.Y)
                -- Bottom stays anchored; the top edge descends as cooldown expires.
                overlay.shade.Size = UDim2.fromScale(1, math.clamp(remaining / state.duration, 0, 1))
                overlay.text.Visible = showNumbers
                overlay.text.Text = string.format("%.1f", remaining)
            end
        end
        local character = player.Character
        if character ~= observedCharacter then
            observedCharacter, previousProtection, protectionSince, estimate = character, false, nil, nil
            -- Existing protection on injection has an unknown start time.
            if character and protected(character) then previousProtection = true; protectionSince = now end
        end
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local active = character and protected(character) and (not humanoid or humanoid.Health > 0)
        if active and not previousProtection then
            protectionSince, estimate = now, nil
            if character:FindFirstChild("TPSafe") then estimate = 4
            elseif collection:HasTag(character, "NoPotions") then estimate = 30 end
        end
        previousProtection = active and true or false
        if not active then protectionSince, estimate = nil, nil end
        foot.Enabled = noFallEnabled and active and root ~= nil and true or false
        if foot.Enabled then
            foot.Adornee = root
            local left = character:FindFirstChild("LeftFoot") or character:FindFirstChild("Left Leg")
            local right = character:FindFirstChild("RightFoot") or character:FindFirstChild("Right Leg")
            local offset = -(humanoid and humanoid.HipHeight or 2) - root.Size.Y / 2
            if left or right then
                local bottom = math.huge
                if left then bottom = math.min(bottom, left.Position.Y - left.Size.Y / 2) end
                if right then bottom = math.min(bottom, right.Position.Y - right.Size.Y / 2) end
                offset = bottom - root.Position.Y
            end
            foot.StudsOffsetWorldSpace = Vector3.new(0, offset + footHeight, 0)
            local remaining = estimate and math.max(0, estimate - (now - protectionSince))
            local effectStart, effectDuration = ctx.bladeEffect()
            if not remaining and effectStart and effectDuration > 0 and effectStart >= protectionSince - 1 then
                remaining = math.max(0, effectDuration - (now - effectStart))
            end
            if remaining and remaining > 0 then
                footText.Text = string.format("SEM QUEDA  ~%.1fs", remaining)
            else
                -- Marker remains authoritative when expiry is unknown or an estimate ends.
                footText.Text = "SEM QUEDA  ativo (tempo desconhecido)"
            end
        end
    end
    group:AddDivider()
    group:AddLabel("Indicadores no jogo")
    group:AddToggle("NivenxideHotbarCooldowns", {Text = "Cooldown sobre a hotbar", Default = true,
        Callback = function(value) hotbarEnabled = value end})
    group:AddSlider("NivenxideHotbarOpacity", {Text = "Opacidade cinza (%)", Default = 40,
        Min = 30, Max = 50, Rounding = 0, Callback = function(value)
            opacity = math.clamp(value, 30, 50)
            for _, overlay in pairs(overlays) do overlay.shade.BackgroundTransparency = 1 - opacity / 100 end
        end})
    group:AddToggle("NivenxideHotbarNumbers", {Text = "Segundos sobre a skill", Default = true,
        Callback = function(value) showNumbers = value end})
    group:AddToggle("NivenxideNoFallFeet", {Text = "Indicador sem queda nos pes", Default = true,
        Callback = function(value) noFallEnabled = value end})
    group:AddSlider("NivenxideNoFallHeight", {Text = "Altura do indicador nos pes", Default = 0.15,
        Min = -0.5, Max = 1, Rounding = 2,
        Callback = function(value) footHeight = math.clamp(value, -0.5, 1) end})
    group:AddLabel("Altura menor = indicador mais embaixo")
    group:AddLabel("NoFall ativo: tempo restante estimado quando conhecido")
    local connection = ctx.utility:Connection(runService.RenderStepped, update)
    local function cleanup()
        if destroyed then return end
        destroyed = true
        connection:Disconnect()
        screen:Destroy()
        foot:Destroy()
    end
    ctx.library:OnUnload(cleanup)
    return cleanup
end
