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
    local version = "6cf44b4c018f23f7e105aba3a7310c5ba23e4d2a"
    local base = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/" .. version .. "/"
    local root = "HYDROXIDE_LOCAL"
    local files = {
        "DEPENDENCIES/Chatlogger.lua",
        "DEPENDENCIES/CharacterMana.lua",
        "DEPENDENCIES/CooldownVisuals.lua",
        "DEPENDENCIES/Icons.lua",
        "DEPENDENCIES/Library.lua",
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
    local previousVersion = "9d0ac6626b84df74c3fd2e2cab83b4982a611938"
    local fingerprints = {
        ["DEPENDENCIES/Chatlogger.lua"] = "7bed3460e5625a114718a854f305d9756409b93fe982b7698fdcaa9a95a6abc7:18835",
        ["DEPENDENCIES/CharacterMana.lua"] = "a5bbff7376ee22eb8f5317d4f64bb8f5300c54cd74861d1ae7104a844b6e2855:11727",
        ["DEPENDENCIES/CooldownVisuals.lua"] = "52135e201f627960edee8787c5f62a608828125b02810fc214f3f0146c48e258:11530",
        ["DEPENDENCIES/Icons.lua"] = "9f131dfb47de74db572416b8bb33b9d4c1e5633aa55092918466aa8cdf2c049c:63721",
        ["DEPENDENCIES/Library.lua"] = "fee5f233c9eb3a45dad87d18c1e592160192c72d6642565fa9e9e29ae48f6c58:233795",
        ["DEPENDENCIES/RAMAccount.lua"] = "d14f62c34d3a7b8e9d34686677e2a1e4139dbea2b38e1c24f4320f0a0cd3f9a5:4663",
        ["DEPENDENCIES/RestartScript.lua"] = "43370ba5fc28a78cff36f077f0d431a5bb667a499f25dd29533d746e2270ceb0:1557",
        ["DEPENDENCIES/SaveManager.lua"] = "01bf2a4c002859d63e40ce5d09b6cb6b4b4b76c83cd5b3221e703fbf34c78d05:18462",
        ["DEPENDENCIES/SpellMana.lua"] = "4546ad9504bd80b1941069a28ce3f5f8e45943ded58900302f7bcd9124db44a4:2118",
        ["DEPENDENCIES/ThemeManager.lua"] = "52eb0f1618c4922644ae092b54bc72d2e2d45620deaa49e8e252e770088ae13e:19590",
        ["DEPENDENCIES/VanguardTracker.lua"] = "a98164bb7a3f1ddd467d554d2449c8e4af48321a6310b7e061e179c0c5a44572:20021",
        ["ROGUE/rogue_ui.lua"] = "c16520bd48690d5cfdfdb40ab72f4446023a579d259d7ba9158ed6552a8e13bb:1303312",
        ["ROGUE_BATTLEGROUNDS/rlb.lua"] = "f473c2c6eb2d63f6cf1b4b0fbf14d8051c71eeb3c352147f3914b0e65b436a94:634695",
        ["assets/SaturationMap.png"] = "6de7aec9338f0193009af0f959f1fca6f68eefac6b471f00ba94c74078e841fb:32607",
        ["assets/TransparencyTexture.png"] = "32195d995f08a9a729b1de3982f33ce37052b64748d9462146f082ffb4233cf9:163",
        ["hello_stella.lua"] = "ee4e1f54004e3cde0342db11191d8ab25d4b3e9b7e1216a777f5f9c9dc25fe1e:51915",
        ["loader.lua"] = "bb361083dea3dfc06be54c53ba862a25f38c9564c7930bf45dcf8926ba505a6a:355",
        ["start.lua"] = "90f9d140fbe421c0ae861c80a88befc06be695f81a9f607032ea721f24d54125:757",
        ["LICENSE"] = "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0:34523",
    }
    local previousFingerprints = {
        ["DEPENDENCIES/Chatlogger.lua"] = "7bed3460e5625a114718a854f305d9756409b93fe982b7698fdcaa9a95a6abc7:18835",
        ["DEPENDENCIES/CharacterMana.lua"] = "a5bbff7376ee22eb8f5317d4f64bb8f5300c54cd74861d1ae7104a844b6e2855:11727",
        ["DEPENDENCIES/CooldownVisuals.lua"] = "52135e201f627960edee8787c5f62a608828125b02810fc214f3f0146c48e258:11530",
        ["DEPENDENCIES/Icons.lua"] = "9f131dfb47de74db572416b8bb33b9d4c1e5633aa55092918466aa8cdf2c049c:63721",
        ["DEPENDENCIES/Library.lua"] = "fee5f233c9eb3a45dad87d18c1e592160192c72d6642565fa9e9e29ae48f6c58:233795",
        ["DEPENDENCIES/RAMAccount.lua"] = "d14f62c34d3a7b8e9d34686677e2a1e4139dbea2b38e1c24f4320f0a0cd3f9a5:4663",
        ["DEPENDENCIES/RestartScript.lua"] = "43370ba5fc28a78cff36f077f0d431a5bb667a499f25dd29533d746e2270ceb0:1557",
        ["DEPENDENCIES/SaveManager.lua"] = "01bf2a4c002859d63e40ce5d09b6cb6b4b4b76c83cd5b3221e703fbf34c78d05:18462",
        ["DEPENDENCIES/SpellMana.lua"] = "4546ad9504bd80b1941069a28ce3f5f8e45943ded58900302f7bcd9124db44a4:2118",
        ["DEPENDENCIES/ThemeManager.lua"] = "52eb0f1618c4922644ae092b54bc72d2e2d45620deaa49e8e252e770088ae13e:19590",
        ["DEPENDENCIES/VanguardTracker.lua"] = "a98164bb7a3f1ddd467d554d2449c8e4af48321a6310b7e061e179c0c5a44572:20021",
        ["ROGUE/rogue_ui.lua"] = "3adf1149ef55d3a7a8a929da07faf2b0ea9b413c433337930aac68d50a96de29:1303311",
        ["ROGUE_BATTLEGROUNDS/rlb.lua"] = "f473c2c6eb2d63f6cf1b4b0fbf14d8051c71eeb3c352147f3914b0e65b436a94:634695",
        ["assets/SaturationMap.png"] = "6de7aec9338f0193009af0f959f1fca6f68eefac6b471f00ba94c74078e841fb:32607",
        ["assets/TransparencyTexture.png"] = "32195d995f08a9a729b1de3982f33ce37052b64748d9462146f082ffb4233cf9:163",
        ["hello_stella.lua"] = "ee4e1f54004e3cde0342db11191d8ab25d4b3e9b7e1216a777f5f9c9dc25fe1e:51915",
        ["loader.lua"] = "bb361083dea3dfc06be54c53ba862a25f38c9564c7930bf45dcf8926ba505a6a:355",
        ["start.lua"] = "90f9d140fbe421c0ae861c80a88befc06be695f81a9f607032ea721f24d54125:757",
        ["LICENSE"] = "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0:34523",
    }
    local versionFile = root .. "/nivenxide.version"
    local cacheFile = root .. "/nivenxide.cache"
    local started = os.clock()
    local cachedVersion = isfile(versionFile) and readfile(versionFile) or ""
    local cached = {}
    if isfile(cacheFile) then
        local data = readfile(cacheFile)
        local metadataVersion = data:match("^VERSION=([^\n]+)\n")
        if metadataVersion == cachedVersion and cachedVersion ~= "incomplete" then
            for relative, fingerprint in data:gmatch("\n([^=\n]+)=([^\n]+)") do
                cached[relative] = fingerprint
            end
        end
    end
    -- Migrate the previous valid installation without redownloading unchanged files.
    if cachedVersion == previousVersion and next(cached) == nil then
        cached = previousFingerprints
    end
    local queue = {}
    for _, relative in ipairs(files) do
        local path = root .. "/" .. relative
        local reusable = not env.NivenxideForceUpdate and cached[relative] == fingerprints[relative]
        if reusable then
            local expectedSize = tonumber(fingerprints[relative]:match(":(%d+)$"))
            local okRead, content = pcall(function() return isfile(path) and readfile(path) end)
            reusable = okRead and type(content) == "string" and #content == expectedSize
        end
        if not reusable then queue[#queue + 1] = relative end
    end
    local downloads = {}
    if #queue > 0 then
        print(string.format("[Nivenxide] Atualizando %d/%d arquivos (ate 4 downloads simultaneos)...", #queue, #files))
        local nextIndex, completed = 1, 0
        local workers = math.min(4, #queue)
        local pending, firstError = workers, nil
        for _ = 1, workers do
            task.spawn(function()
                local success, workerError = pcall(function()
                    while not firstError do
                        local index = nextIndex
                        nextIndex = nextIndex + 1
                        local relative = queue[index]
                        if not relative then break end
                        local content = game:HttpGet(base .. root .. "/" .. relative, true)
                        local expectedSize = tonumber(fingerprints[relative]:match(":(%d+)$"))
                        assert(type(content) == "string" and #content == expectedSize, "Download incompleto: " .. relative)
                        downloads[relative] = content
                        completed = completed + 1
                        print(string.format("[Nivenxide] %d/%d %s", completed, #queue, relative))
                    end
                end)
                if not success then firstError = firstError or workerError end
                pending = pending - 1
            end)
        end
        while pending > 0 do task.wait() end
        assert(not firstError, firstError)
    end
    if #queue > 0 or cachedVersion ~= version or not isfile(cacheFile) then
        for _, directory in ipairs({root, root .. "/DEPENDENCIES", root .. "/ROGUE",
            root .. "/ROGUE_BATTLEGROUNDS", root .. "/assets"}) do
            if not isfolder(directory) then makefolder(directory) end
        end
        -- All downloads complete before mutating the cache; interrupted writes invalidate it.
        writefile(versionFile, "incomplete")
        for _, relative in ipairs(queue) do
            local path, content = root .. "/" .. relative, downloads[relative]
            writefile(path, content)
            assert(readfile(path) == content, "Falha ao gravar " .. relative)
        end
        local metadata = {"VERSION=" .. version}
        for _, relative in ipairs(files) do metadata[#metadata + 1] = relative .. "=" .. fingerprints[relative] end
        writefile(cacheFile, table.concat(metadata, "\n") .. "\n")
        writefile(versionFile, version)
    end
    env.NivenxideForceUpdate = false
    print(string.format("[Nivenxide] Cache pronto em %.2fs; %d arquivo(s) baixado(s)", os.clock() - started, #queue))
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
