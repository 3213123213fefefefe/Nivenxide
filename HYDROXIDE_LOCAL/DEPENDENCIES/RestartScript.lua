-- Prepare replacement first; unload only once it can be compiled and settings saved.
return function(ctx)
    return function()
        local env = getgenv()
        if env.NivenxideRestarting or ctx.isUnloading() then return end
        env.NivenxideRestarting = true
        ctx.notify("Preparando reinicio do Nivenxide...")
        task.spawn(function()
            local ok, err = pcall(function()
                local url = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/loader.lua"
                    .. "?restart=" .. tostring(os.time())
                local source = game:HttpGet(url, true)
                local loader, compileError = loadstring(source, "@NivenxideRestartLoader")
                assert(loader, compileError)
                local config = "__nivenxide_restart"
                local saved, saveError = ctx.saveManager:Save(config)
                assert(saved, "Nao foi possivel salvar os ajustes: " .. tostring(saveError))
                env.NivenxideRestartConfig = config
                ctx.unload()
                task.wait(0.6) -- Let pending cleanup tasks finish before a new session.
                loader()
            end)
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
