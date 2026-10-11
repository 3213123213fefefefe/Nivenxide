-- Prepare replacement first; unload only once it can be compiled and settings saved.
return function(ctx)
    local restarting = false
    return function()
        local env = getgenv()
        if restarting or ctx.isUnloading() then return end
        restarting = true
        env.NivenxideRestarting = true
        task.spawn(function()
            local ok, err = pcall(function()
                pcall(ctx.notify, "Preparando reinicio do Nivenxide...")
                local url = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/loader.lua"
                    .. "?restart=" .. tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1000))
                local source = game:HttpGet(url, true)
                local loader, compileError = loadstring(source, "@NivenxideRestartLoader")
                assert(loader, compileError)
                local config = "__nivenxide_restart"
                local saved, saveError = ctx.saveManager:Save(config)
                assert(saved, "Nao foi possivel salvar os ajustes: " .. tostring(saveError))
                env.NivenxideRestartConfig = config
                ctx.unload()
                task.wait(0.6) -- Let pending cleanup tasks finish before a new session.
                env.NivenxideForceUpdate = true
                env.NivenxideLoading = false
                -- The old restart worker must finish before a new runtime starts.
                env.NivenxideRestarting = false
                restarting = false
                task.defer(function()
                    local loaded, loadError = pcall(loader)
                    if not loaded then
                        env.NivenxideLoading = false
                        env.NivenxideRestarting = false
                        env.NivenxideRestartConfig = nil
                        warn("[Nivenxide Restart] Falha ao carregar nova sessao: " .. tostring(loadError))
                    end
                end)
            end)
            restarting = false
            env.NivenxideRestarting = false
            if not ok then
                warn("[Nivenxide Restart] " .. tostring(err))
                env.NivenxideRestartConfig = nil
                if not ctx.isUnloading() then
                    pcall(ctx.notify, "Falha ao reiniciar; confira o console")
                end
            end
        end)
    end
end
