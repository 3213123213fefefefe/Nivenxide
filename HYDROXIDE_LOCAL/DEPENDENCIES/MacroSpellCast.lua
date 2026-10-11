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
            local range = ctx.range(action.spell, character, snap)
            if not range then return false, "Magia sem faixa cadastrada: " .. tostring(action.spell) end
            local mana = character:FindFirstChild("Mana")
            if not mana then return false, "Mana indisponivel" end
            local function inside() return mana.Value >= range[1] and mana.Value <= range[2] end
            if mana.Value > range[2] then return false, "Mana acima da faixa; macro interrompido" end
            if mana.Value < range[1] and not action.adjustMana then return false, "Mana abaixo da faixa; macro interrompido" end
            if snap and ctx.snapCooldown(character) then return false, "Snap em cooldown" end
            local tool = ctx.findTool(action.spell)
            if not tool then return false, "Magia nao encontrada: " .. tostring(action.spell) end
            humanoid:EquipTool(tool)
            ctx.wait()
            if cancelled() or tool.Parent ~= character then return false, "Nao foi possivel equipar a magia" end
            local deadline = ctx.clock() + math.clamp(tonumber(action.timeout) or 3, 0.2, 10)
            if not inside() then
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
            range = ctx.range(action.spell, character, snap)
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
