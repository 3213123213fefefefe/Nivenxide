-- Nivenxide: GitHub bootstrap + versioned local cache.
-- Runtime snapshot: Cooldowns tab with configurable Vanguard timers.
local env = getgenv()
if env.NivenxideLoading then
    warn("[Nivenxide] Ja existe um carregamento em andamento")
    return
end
env.NivenxideLoading = true
local ok, err = pcall(function()
    assert(type(readfile) == "function" and type(writefile) == "function"
        and type(isfile) == "function" and type(isfolder) == "function"
        and type(makefolder) == "function", "Executor sem suporte a arquivos locais")
    local version = "8d4592a352c2797c25b0a2f866602cf31d590921"
    local base = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/" .. version .. "/"
    local root = "HYDROXIDE_LOCAL"
    local files = {
        "DEPENDENCIES/Chatlogger.lua",
        "DEPENDENCIES/CharacterMana.lua",
        "DEPENDENCIES/CooldownVisuals.lua",
        "DEPENDENCIES/Icons.lua",
        "DEPENDENCIES/Library.lua",
        "DEPENDENCIES/MacroSpellCast.lua",
        "DEPENDENCIES/RAMAccount.lua",
        "DEPENDENCIES/RestartScript.lua",
        "DEPENDENCIES/SaveManager.lua",
        "DEPENDENCIES/SpellMana.lua",
        "DEPENDENCIES/ThemeManager.lua",
        "DEPENDENCIES/VanguardTracker.lua",
        "ROGUE/rogue_ui.lua",
        "ROGUE_BATTLEGROUNDS/rlb.lua",
        "assets/SaturationMap.png",
        "assets/TransparencyTexture.png",
        "hello_stella.lua",
        "loader.lua",
        "start.lua",
        "LICENSE"
    }
    local versionFile = root .. "/nivenxide.version"
    local valid = not env.NivenxideForceUpdate
        and isfile(versionFile) and readfile(versionFile) == version
    if valid then
        for _, relative in ipairs(files) do
            local path = root .. "/" .. relative
            if not isfile(path) or #readfile(path) == 0 then valid = false; break end
        end
    end
    if not valid then
        print("[Nivenxide] Baixando arquivos do GitHub; aguarde...")
        -- Download everything before changing the existing cache.
        local downloads = {}
        for i, relative in ipairs(files) do
            local content = game:HttpGet(base .. root .. "/" .. relative, true)
            assert(type(content) == "string" and #content > 0, "Download vazio: " .. relative)
            downloads[relative] = content
            print(string.format("[Nivenxide] %d/%d %s", i, #files, relative))
        end
        for _, directory in ipairs({root, root .. "/DEPENDENCIES", root .. "/ROGUE",
            root .. "/ROGUE_BATTLEGROUNDS", root .. "/assets"}) do
            if not isfolder(directory) then makefolder(directory) end
        end
        -- Invalidate before writeback; any interrupted installation is retried.
        writefile(versionFile, "incomplete")
        for _, relative in ipairs(files) do
            local path, content = root .. "/" .. relative, downloads[relative]
            writefile(path, content)
            assert(readfile(path) == content, "Falha ao gravar " .. relative)
        end
        writefile(versionFile, version)
        env.NivenxideForceUpdate = false
        print("[Nivenxide] Instalacao concluida")
    else
        print("[Nivenxide] Carregando copia local")
    end
    local path = root .. "/start.lua"
    local fn, compileError = loadstring(readfile(path), "@" .. path)
    assert(fn, compileError)
    fn()
end)
env.NivenxideLoading = false
if not ok then
    warn("[Nivenxide] " .. tostring(err))
    error(err, 0)
end
