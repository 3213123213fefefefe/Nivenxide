-- A synchronous mana gate: later macro actions run only after a valid cast attempt.
return function(ctx)
    return function(action, macroName)
        local charged = false
        local function stopCharge()
            if charged then charged = false; ctx.stopCharge() end
        end
        local ok, result, reason = pcall(function()
            local character = ctx.player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if not humanoid or humanoid.Health <= 0 then return false, "Personagem indisponivel" end
            local function cancelled()
                return ctx.cancelled(macroName) or ctx.player.Character ~= character or humanoid.Health <= 0
            end
            if cancelled() then return false, "Macro cancelado" end
            local snap = action.mode == "Snap"
            local backfire = action.mode == "Backfire"
            if backfire and ctx.noBackfire and ctx.noBackfire(character) then
                return false, "PhilosophersStone impede backfire"
            end
            local function desiredRange()
                local normal = ctx.range(action.spell, character, snap)
                if not normal or not backfire then return normal end
                local side = action.backfireSide or "Auto"
                if side == "Auto" then
                    side = (action.spell == "Viribus" or action.spell == "Armis") and "Acima" or "Abaixo"
                end
                local margin = math.clamp(tonumber(action.backfireMargin) or 0.1, 0.1, 5)
                if side == "Acima" then
                    local minimum = normal[2] + margin
                    if minimum > 100 then return end
                    return {minimum, math.min(100, minimum + 1)}
                end
                local minimum = math.clamp(tonumber(action.backfireMinimum) or 1, 0.1, 20)
                local maximum = math.min(minimum + 1, normal[1] - margin)
                if maximum < minimum then return end
                return {minimum, maximum}
            end
            local range = desiredRange()
            if not range then return false, "Sem faixa disponivel para este cast/backfire: " .. tostring(action.spell) end
            local mana = character:FindFirstChild("Mana")
            if not mana then return false, "Mana indisponivel" end
            local function inside() return mana.Value >= range[1] and mana.Value <= range[2] end
            if not backfire and mana.Value > range[2] then return false, "Mana acima da faixa; macro interrompido" end
            if mana.Value < range[1] and not action.adjustMana then return false, "Mana abaixo da faixa; macro interrompido" end
            if snap and ctx.snapCooldown(character) then return false, "Snap em cooldown" end
            local tool = ctx.findTool(action.spell)
            if not tool then return false, "Magia nao encontrada: " .. tostring(action.spell) end
            humanoid:EquipTool(tool)
            ctx.wait()
            if cancelled() or tool.Parent ~= character then return false, "Nao foi possivel equipar a magia" end
            local deadline = ctx.clock() + math.clamp(tonumber(action.timeout) or 3, 0.2, 10)
            if not inside() and backfire then
                if not action.adjustMana then return false, "Mana fora da faixa minima de backfire" end
                while not inside() do
                    if cancelled() then return false, "Macro cancelado" end
                    if ctx.clock() >= deadline then return false, "Tempo limite para ajustar o backfire" end
                    if tool.Parent ~= character then return false, "Magia desequipada" end
                    if ctx.blocked(character) then return false, "Ajuste de mana bloqueado" end
                    range = desiredRange()
                    if not range then return false, "Faixa de backfire indisponivel" end
                    if mana.Value < range[1] then
                        charged = true
                        ctx.charge()
                        ctx.wait(0.05)
                    else
                        stopCharge()
                        ctx.stopCharge()
                        -- Mana is above the minimum window: allow natural decay, never cast high.
                        ctx.wait()
                    end
                end
            elseif not inside() then
                if not action.adjustMana then return false, "Mana fora da faixa" end
                local target = (range[1] + range[2]) / 2
                while mana.Value < target do
                    if cancelled() then return false, "Macro cancelado" end
                    if ctx.clock() >= deadline then return false, "Tempo limite para ajustar a mana" end
                    if tool.Parent ~= character then return false, "Magia desequipada" end
                    if ctx.blocked(character) then return false, "Carregamento de mana bloqueado" end
                    charged = true
                    ctx.charge()
                    ctx.wait(0.05)
                end
            end
            stopCharge()
            -- Also stop manual charging before the final check, avoiding continued gain during cast.
            ctx.stopCharge()
            ctx.wait()
            if cancelled() then return false, "Macro cancelado" end
            if tool.Parent ~= character then return false, "Magia desequipada" end
            range = desiredRange()
            if not range or not inside() then return false, "Mana saiu da faixa; cast cancelado" end
            if ctx.blocked(character) then return false, "Personagem impedido de castar" end
            if snap and ctx.snapCooldown(character) then return false, "Snap em cooldown" end
            if ctx.cast(snap, character) == false then return false, "Cast indisponivel" end
            return true
        end)
        local cleaned, cleanupError = pcall(stopCharge)
        if not ok then return false, tostring(result) end
        if not cleaned then return false, tostring(cleanupError) end
        return result, reason
    end
end
