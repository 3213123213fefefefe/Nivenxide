-- Passive local timers keyed to skill animation playback, not M1.
-- Animation playback is observable evidence; it is not server acknowledgement.
return function(ctx)
    local names = {"Brandish", "Puncture", "Azure Ignition", "Blade Crash"}
    local states, connections, watched = {}, {}, setmetatable({}, {__mode = "k"})
    local selected = names[1]
    local animationOwners = {}
    local animatorWatched = setmetatable({}, {__mode = "k"})
    local function animationId(value)
        return tostring(value or ""):match("%d+") or ""
    end
    local effectStart, effectDuration, effectMeasured = nil, 0, false
    local enabled, showIdle, showEffect, restart = true, true, true, false
    local decimals = 1
    local cooldownColor = Color3.fromRGB(110, 190, 255)
    local effectColor = Color3.fromRGB(255, 160, 70)
    local group, player = ctx.group, ctx.player
    local appearance = ctx.appearance or group
    local measurement = ctx.measurement or group
    local controls = {}
    local function selectSkill(name)
        if not states[name] then return end
        selected = name
        for skill, list in pairs(controls) do
            for _, control in ipairs(list) do control:SetVisible(skill == name) end
        end
    end
    local function connect(signal, callback)
        local c = ctx.utility:Connection(signal, callback)
        connections[#connections + 1] = c
        return c
    end
    local function notify(message)
        ctx.library:Notify(message, 4)
    end
    for _, name in ipairs(names) do
        states[name] = {duration = 0, visible = true, label = name, animation = ""}
    end
    local function use(name, observed)
        local state = states[name]
        if not state or not enabled or not state.visible then return end
        local now = os.clock()
        -- Observed playback overrides the estimate; clicks never call this path.
        if not observed and not restart and state.start and state.duration > 0 and now - state.start < state.duration then return end
        if observed then
            if state.lastSignal and now - state.lastSignal < 0.3 then return end
            state.lastSignal = now
            if state.calibrating then
                if state.firstSignal then
                    local seconds = math.floor((now - state.firstSignal) * 1000 + 0.5) / 1000
                    if seconds <= 3600 then
                        for index, skill in ipairs(names) do
                            if skill == name then ctx.options["VanguardCD" .. index]:SetValue(tostring(seconds)) end
                        end
                        notify(name .. ": intervalo medido " .. seconds .. "s")
                    else notify("Intervalo longo demais; repita a medicao") end
                    state.calibrating, state.firstSignal = false, nil
                else
                    state.firstSignal = now
                    notify(name .. ": primeiro uso detectado; aguardando o segundo")
                end
            end
        end
        state.start = now
        state.measured = false
        if name == "Blade Crash" then
            effectStart, effectMeasured = now, false
        end
    end
    local function watch(tool)
        if not tool:IsA("Tool") or not states[tool.Name] or watched[tool] then return end
        watched[tool] = true
        local function register(instance)
            if not instance:IsA("Animation") then return end
            local function indexAnimation()
                local id = animationId(instance.AnimationId)
                if id ~= "" then
                    animationOwners[id] = animationOwners[id] or {}
                    animationOwners[id][tool.Name] = true
                end
            end
            indexAnimation()
            connect(instance:GetPropertyChangedSignal("AnimationId"), indexAnimation)
        end
        for _, instance in ipairs(tool:GetDescendants()) do register(instance) end
        connect(tool.DescendantAdded, register)
        -- Tool.Activated fires on rejected M1 attempts, so it is deliberately unused.
        connect(tool.Destroying, function() watched[tool] = nil end)
    end
    local function animationPlayed(track)
        if not enabled or not track.Animation then return end
        local id = animationId(track.Animation.AnimationId)
        if id == "" then return end
        local owner, count
        count = 0
        for _, name in ipairs(names) do
            local state = states[name]
            local matches = state.animation ~= "" and state.animation == id
                or state.animation == "" and animationOwners[id] and animationOwners[id][name]
            if state.visible and matches then owner = name; count = count + 1 end
        end
        if count ~= 1 then return end -- Never guess when skills share an animation.
        if states[owner].animation == "" then
            for index, name in ipairs(names) do
                if name == owner then ctx.options["VanguardAnimation" .. index]:SetValue(id) end
            end
            print("[Nivenxide] Animacao aprendida: " .. owner .. "=" .. id)
        end
        use(owner, true)
    end
    local function watchAnimator(instance)
        if not instance:IsA("Animator") or animatorWatched[instance] then return end
        animatorWatched[instance] = true
        return connect(instance.AnimationPlayed, animationPlayed)
    end
    local characterConnections = {}
    local function reset()
        for _, state in pairs(states) do
            state.start, state.lastSignal, state.firstSignal = nil, nil, nil
            state.calibrating, state.measured = false, false
        end
        effectStart, effectMeasured = nil, false
    end
    local function characterAdded(character)
        for _, c in ipairs(characterConnections) do c:Disconnect() end
        characterConnections = {}
        reset()
        animationOwners = {}
        local backpack = player:FindFirstChildOfClass("Backpack")
        if backpack then
            -- Reindex surviving tools after respawn as well.
            for _, tool in ipairs(backpack:GetChildren()) do watched[tool] = nil; watch(tool) end
        end
        for _, tool in ipairs(character:GetChildren()) do watch(tool) end
        for _, instance in ipairs(character:GetDescendants()) do
            local connection = watchAnimator(instance)
            if connection then characterConnections[#characterConnections + 1] = connection end
        end
        characterConnections[#characterConnections + 1] = connect(character.DescendantAdded, function(instance)
            local connection = watchAnimator(instance)
            if connection then characterConnections[#characterConnections + 1] = connection end
        end)
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
    group:AddLabel("Selecione uma skill e configure em segundos")
    group:AddLabel("0 = desconhecido; aceita valores como 12.5")
    group:AddDropdown("VanguardCalibrationSkill", {Text = "Skill", Values = names,
        Default = 1, Callback = selectSkill})
    for index, name in ipairs(names) do
        local skillName = name
        local list = {}
        controls[name] = list
        list[#list + 1] = group:AddToggle("VanguardSkillEnabled" .. index, {
            Text = "Rastrear " .. skillName, Default = true,
            Callback = function(value)
                states[skillName].visible = value
                if not value then
                    states[skillName].start, states[skillName].firstSignal = nil, nil
                    states[skillName].lastSignal, states[skillName].calibrating = nil, false
                    if skillName == "Blade Crash" then effectStart = nil end
                end
            end})
        list[#list + 1] = group:AddInput("VanguardLabel" .. index, {
            Text = "Nome no painel", Default = skillName, Finished = true,
            Callback = function(value)
                states[skillName].label = (type(value) == "string" and value ~= "") and value or skillName
            end})
        list[#list + 1] = group:AddInput("VanguardAnimation" .. index, {
            Text = "ID da animacao (vazio = aprender)", Default = "", Finished = true,
            Callback = function(value)
                local state = states[skillName]
                state.animation = animationId(value)
                state.start, state.lastSignal, state.firstSignal = nil, nil, nil
            end})
        list[#list + 1] = group:AddInput("VanguardCD" .. index, {
            Text = "Cooldown (segundos)", Default = "0", Numeric = true, Finished = true,
            Callback = function(value)
                local seconds = tonumber(value)
                if seconds and seconds >= 0 and seconds <= 3600 then
                    states[skillName].duration = seconds
                else notify("Informe de 0 a 3600 segundos") end
            end})
    end
    local bladeControls = controls["Blade Crash"]
    bladeControls[#bladeControls + 1] = group:AddInput("VanguardBladeEffect", {
        Text = "Duracao do efeito (segundos)", Default = "0", Numeric = true, Finished = true,
        Callback = function(value)
            local seconds = tonumber(value)
            if seconds and seconds >= 0 and seconds <= 3600 then effectDuration = seconds
            else notify("Informe de 0 a 3600 segundos") end
        end})
    selectSkill(selected)
    group:AddLabel("Salve os tempos em Config > Save config")
    appearance:AddToggle("VanguardTimers", {Text = "Ativar rastreamento", Default = true,
        Callback = function(value) enabled = value; if not value then reset() end end})
    appearance:AddToggle("VanguardShowIdle", {Text = "Mostrar skills sem CD ativo", Default = true,
        Callback = function(value) showIdle = value end})
    appearance:AddToggle("VanguardShowEffect", {Text = "Mostrar efeito Blade Crash", Default = true,
        Callback = function(value) showEffect = value end})
    appearance:AddToggle("VanguardRestart", {Text = "Reiniciar registro manual durante CD", Default = false,
        Callback = function(value) restart = value end})
    appearance:AddSlider("VanguardDecimals", {Text = "Casas decimais", Default = 1, Min = 0, Max = 2,
        Rounding = 0, Callback = function(value) decimals = math.max(0, math.min(2, math.floor(value))) end})
    appearance:AddLabel("Cor dos cooldowns"):AddColorPicker("VanguardCooldownColor", {
        Default = cooldownColor, Title = "Cooldowns", Callback = function(value) cooldownColor = value end})
    appearance:AddLabel("Cor do efeito"):AddColorPicker("VanguardEffectColor", {
        Default = effectColor, Title = "Blade Crash", Callback = function(value) effectColor = value end})
    appearance:AddButton({Text = "Mostrar painel de timers", Func = function()
        if ctx.toggles and ctx.toggles.StatusEffects then ctx.toggles.StatusEffects:SetValue(true) end
        notify("Timers no painel Status Effects; arraste-o para posicionar")
    end})
    appearance:AddLabel("Posicao: arraste o painel Status Effects")
    appearance:AddLabel("Gatilho: animacao da skill; M1 ignorado")
    appearance:AddLabel("Animacao observada nao confirma aceite do servidor")
    measurement:AddButton({Text = "Medir intervalo entre dois usos", Func = function()
        local state = states[selected]
        if not enabled or not state.visible then notify("Ative o rastreamento desta skill"); return end
        state.calibrating, state.firstSignal = true, nil
        notify("Use " .. selected .. " duas vezes; M1 sem animacao sera ignorado")
    end})
    measurement:AddButton({Text = "Cancelar medicao automatica", Func = function()
        states[selected].calibrating, states[selected].firstSignal = false, nil
    end})
    measurement:AddButton({Text = "Reaprender animacao da skill", Func = function()
        for index, name in ipairs(names) do
            if name == selected then ctx.options["VanguardAnimation" .. index]:SetValue("") end
        end
        notify("Use a skill uma vez para aprender sua primeira animacao")
    end})
    measurement:AddLabel("Intervalo inclui atraso da proxima tentativa")
    measurement:AddButton({Text = "Registrar uso da skill selecionada", Func = function()
        use(selected)
        notify("Uso registrado: " .. selected)
    end})
    measurement:AddButton({Text = "Skill ficou pronta: medir CD", Func = function()
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
    measurement:AddButton({Text = "Efeito Blade Crash acabou: medir", Func = function()
        if not enabled or not effectStart then notify("Use Blade Crash primeiro"); return end
        if effectMeasured then notify("Use Blade Crash novamente para medir"); return end
        local seconds = math.floor((os.clock() - effectStart) * 10 + 0.5) / 10
        if seconds > 3600 then notify("Medicao longa demais; registre novo uso"); return end
        effectMeasured = true
        ctx.options.VanguardBladeEffect:SetValue(tostring(seconds))
        notify("Blade Crash: efeito medido " .. seconds .. "s")
    end})
    measurement:AddButton({Text = "Limpar contadores Vanguard", Func = reset})
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
            local label = state.label
            local active = state.start and (state.duration == 0 or now - state.start < state.duration)
            local text = label .. ": CD desconhecido"
            if state.start then
                local elapsed = now - state.start
                if state.duration == 0 then
                    text = string.format("%s: %." .. decimals .. "fs desde uso", label, elapsed)
                elseif elapsed < state.duration then
                    text = string.format("%s CD ~%." .. decimals .. "fs", label, state.duration - elapsed)
                else text = label .. ": CD estimado encerrado" end
            elseif state.duration > 0 then text = label .. ": aguardando uso" end
            if state.calibrating then
                text = label .. (state.firstSignal and ": medindo intervalo..." or ": aguardando primeiro uso")
            end
            if state.visible and (showIdle or active or state.calibrating) then window:AddItem(text, cooldownColor) end
        end
        if showEffect and states["Blade Crash"].visible and effectStart then
            local elapsed = now - effectStart
            local text
            if effectDuration == 0 then text = string.format("%s efeito: %." .. decimals .. "fs desde uso", states["Blade Crash"].label, elapsed)
            elseif not effectMeasured and elapsed < effectDuration then
                text = string.format("%s efeito ~%." .. decimals .. "fs", states["Blade Crash"].label, effectDuration - elapsed)
            end
            if text then window:AddItem(text, effectColor) end
        end
    end
end
