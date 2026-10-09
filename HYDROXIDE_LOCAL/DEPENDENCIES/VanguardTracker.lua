-- Passive, local timers. Tool.Activated is an attempt, not server confirmation.
return function(ctx)
    local names = {"Brandish", "Puncture", "Azure Ignition", "Blade Crash"}
    local states, connections, watched = {}, {}, setmetatable({}, {__mode = "k"})
    local selected = names[1]
    local effectStart, effectDuration, effectMeasured = nil, 0, false
    local enabled = true
    local group, player = ctx.group, ctx.player
    local function connect(signal, callback)
        local c = ctx.utility:Connection(signal, callback)
        connections[#connections + 1] = c
        return c
    end
    local function notify(message)
        ctx.library:Notify(message, 4)
    end
    for _, name in ipairs(names) do
        states[name] = {duration = 0}
    end
    local function use(name)
        local state = states[name]
        if not state or not enabled then return end
        local now = os.clock()
        -- Repeated attempts during the configured cooldown must not restart it.
        if state.start and state.duration > 0 and now - state.start < state.duration then return end
        state.start = now
        state.measured = false
        if name == "Blade Crash" then
            effectStart, effectMeasured = now, false
        end
    end
    local function watch(tool)
        if not tool:IsA("Tool") or not states[tool.Name] or watched[tool] then return end
        watched[tool] = true
        connect(tool.Activated, function()
            if tool.Parent == player.Character then use(tool.Name) end
        end)
        connect(tool.Destroying, function()
            watched[tool] = nil
        end)
    end
    local characterConnections = {}
    local function reset()
        for _, state in pairs(states) do state.start = nil; state.measured = false end
        effectStart, effectMeasured = nil, false
    end
    local function characterAdded(character)
        for _, c in ipairs(characterConnections) do c:Disconnect() end
        characterConnections = {}
        reset()
        for _, tool in ipairs(character:GetChildren()) do watch(tool) end
        characterConnections[#characterConnections + 1] = connect(character.ChildAdded, watch)
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            characterConnections[#characterConnections + 1] = connect(humanoid.Died, reset)
        end
    end
    local backpackConnection
    local function backpackAdded(backpack)
        if backpackConnection then backpackConnection:Disconnect() end
        for _, tool in ipairs(backpack:GetChildren()) do watch(tool) end
        backpackConnection = connect(backpack.ChildAdded, watch)
    end
    group:AddDivider()
    group:AddLabel("Vanguard — timers estimados")
    group:AddToggle("VanguardTimers", {Text = "Mostrar timers Vanguard", Default = true,
        Callback = function(value) enabled = value; if not value then reset() end end})
    group:AddLabel("0 segundos = tempo desconhecido")
    for index, name in ipairs(names) do
        local skillName = name
        group:AddInput("VanguardCD" .. index, {Text = skillName .. " CD (s)", Default = "0",
            Numeric = true, Finished = true,
            Callback = function(value)
                local seconds = tonumber(value)
                if seconds and seconds >= 0 and seconds <= 3600 then
                    states[skillName].duration = seconds
                else notify("Informe de 0 a 3600 segundos") end
            end})
    end
    group:AddInput("VanguardBladeEffect", {Text = "Blade Crash efeito (s)", Default = "0",
        Numeric = true, Finished = true,
        Callback = function(value)
            local seconds = tonumber(value)
            if seconds and seconds >= 0 and seconds <= 3600 then effectDuration = seconds
            else notify("Informe de 0 a 3600 segundos") end
        end})
    group:AddDropdown("VanguardCalibrationSkill", {Text = "Skill para medir", Values = names,
        Default = 1, Callback = function(value) selected = value end})
    group:AddButton({Text = "Registrar uso da skill selecionada", Func = function()
        use(selected)
        notify("Uso registrado: " .. selected)
    end})
    group:AddButton({Text = "Skill ficou pronta: medir CD", Func = function()
        local state = states[selected]
        if not enabled or not state.start then notify("Registre o uso primeiro"); return end
        if state.measured then notify("Registre um novo uso para medir novamente"); return end
        local seconds = math.floor((os.clock() - state.start) * 10 + 0.5) / 10
        if seconds > 3600 then notify("Medicao longa demais; registre novo uso"); return end
        state.measured = true
        for index, name in ipairs(names) do
            if name == selected then ctx.options["VanguardCD" .. index]:SetValue(tostring(seconds)) end
        end
        notify(selected .. ": CD medido " .. seconds .. "s")
    end})
    group:AddButton({Text = "Efeito Blade Crash acabou: medir", Func = function()
        if not enabled or not effectStart then notify("Use Blade Crash primeiro"); return end
        if effectMeasured then notify("Use Blade Crash novamente para medir"); return end
        local seconds = math.floor((os.clock() - effectStart) * 10 + 0.5) / 10
        if seconds > 3600 then notify("Medicao longa demais; registre novo uso"); return end
        effectMeasured = true
        ctx.options.VanguardBladeEffect:SetValue(tostring(seconds))
        notify("Blade Crash: efeito medido " .. seconds .. "s")
    end})
    group:AddButton({Text = "Limpar contadores Vanguard", Func = reset})
    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then backpackAdded(backpack) end
    connect(player.ChildAdded, function(child)
        if child:IsA("Backpack") then backpackAdded(child) end
    end)
    connect(player.CharacterAdded, characterAdded)
    connect(player.CharacterRemoving, reset)
    if player.Character then characterAdded(player.Character) end
    -- Called by the existing Status Effects update; no extra heartbeat loop.
    return function(window)
        if not enabled then return end
        local now = os.clock()
        for _, name in ipairs(names) do
            local state = states[name]
            local text = name .. ": CD desconhecido"
            if state.start then
                local elapsed = now - state.start
                if state.duration == 0 then
                    text = string.format("%s: %.1fs desde uso", name, elapsed)
                elseif elapsed < state.duration then
                    text = string.format("%s CD ~%.1fs", name, state.duration - elapsed)
                else text = name .. ": CD estimado encerrado" end
            elseif state.duration > 0 then text = name .. ": aguardando uso" end
            window:AddItem(text, Color3.fromRGB(110, 190, 255))
        end
        if effectStart then
            local elapsed = now - effectStart
            local text
            if effectDuration == 0 then text = string.format("Blade Crash efeito: %.1fs desde uso", elapsed)
            elseif not effectMeasured and elapsed < effectDuration then
                text = string.format("Blade Crash efeito ~%.1fs", effectDuration - elapsed)
            end
            if text then window:AddItem(text, Color3.fromRGB(255, 160, 70)) end
        end
    end
end
