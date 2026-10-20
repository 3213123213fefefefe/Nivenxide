-- Separate experimental build: standard Hydroxide + filtered Sentinel extras.
local env=getgenv()
if env.HXD_MERGED_LOADING then warn("[Hydroxide Merge] Ja existe uma sessao/carregamento desta versao");return end
if type(env.Library)=="table" and env.Library.Unload and not env.Library.Unloaded then
    error("Use Unload Script no script atual antes de abrir a versao combinada",0)
end
env.HXD_MERGED_LOADING=true
local ok,err=pcall(function()
    assert(readfile and writefile and isfile and isfolder and makefolder,"Executor sem arquivos locais")
    local root="HYDROXIDE_MERGED"
    local version="caaffd42e4aefdd72668a05bc129063efb133262"
    local base="https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/"..version.."/"
    local files={
        {"standard.lua","HYDROXIDE_MERGED/standard.lua"},
        {"ExtrasEngine.lua","HYDROXIDE_MERGED/ExtrasEngine.lua"},
        {"ExtrasRuntime.lua","HYDROXIDE_MERGED/ExtrasRuntime.lua"},
        {"ExtrasPolicy.lua","HYDROXIDE_MERGED/ExtrasPolicy.lua"},
        {"CoreBridge.lua","HYDROXIDE_MERGED/CoreBridge.lua"},
        {"BaseControls.lua","HYDROXIDE_MERGED/BaseControls.lua"},
        {"ModeratorSnapshot.lua","HYDROXIDE_MERGED/ModeratorSnapshot.lua"},
        {"DEPENDENCIES/Library.lua","HYDROXIDE_MERGED/DEPENDENCIES/Library.lua"},
        {"DEPENDENCIES/Icons.lua","HYDROXIDE_MERGED/DEPENDENCIES/Icons.lua"},
        {"DEPENDENCIES/SaveManager.lua","HYDROXIDE_MERGED/DEPENDENCIES/SaveManager.lua"},
        {"DEPENDENCIES/ThemeManager.lua","HYDROXIDE_MERGED/DEPENDENCIES/ThemeManager.lua"},
        {"DEPENDENCIES/Chatlogger.lua","HYDROXIDE_MERGED/DEPENDENCIES/Chatlogger.lua"},
        {"DEPENDENCIES/RAMAccount.lua","HYDROXIDE_MERGED/DEPENDENCIES/RAMAccount.lua"},
        {"assets/SaturationMap.png","HYDROXIDE_LOCAL/assets/SaturationMap.png"},
        {"assets/TransparencyTexture.png","HYDROXIDE_LOCAL/assets/TransparencyTexture.png"},
        {"start.lua","HYDROXIDE_MERGED/start.lua"},
        {"LICENSE","HYDROXIDE_MERGED/LICENSE"},
        {"ORIGINS.json","HYDROXIDE_MERGED/ORIGINS.json"},
        {"README.md","HYDROXIDE_MERGED/README.md"},
        {"manifest.json","HYDROXIDE_MERGED/manifest.json"},
    }
    local stamp=root.."/installed.version"
    local valid=not env.HXD_MERGED_FORCE_UPDATE and isfile(stamp) and readfile(stamp)==version
    if valid then
        for _,file in ipairs(files) do
            if not isfile(root.."/"..file[1]) or #readfile(root.."/"..file[1])==0 then valid=false;break end
        end
    end
    if not valid then
        local stage={}
        for i,file in ipairs(files) do
            local data=game:HttpGet(base..file[2],true)
            assert(type(data)=="string" and #data>0,"Download vazio: "..file[1])
            stage[file[1]]=data
            print(string.format("[Hydroxide Merge] %d/%d %s",i,#files,file[1]))
        end
        for _,folder in ipairs({root,root.."/DEPENDENCIES",root.."/assets"}) do
            if not isfolder(folder) then makefolder(folder) end
        end
        writefile(stamp,"incomplete")
        for _,file in ipairs(files) do
            local path=root.."/"..file[1]
            writefile(path,stage[file[1]])
            assert(readfile(path)==stage[file[1]],"Falha ao gravar "..path)
        end
        writefile(stamp,version)
        env.HXD_MERGED_FORCE_UPDATE=false
    end
    local fn,why=loadstring(readfile(root.."/start.lua"),"@"..root.."/start.lua")
    assert(fn,why)
    fn()
end)
env.HXD_MERGED_LOADING=false
if not ok then warn("[Hydroxide Merge] "..tostring(err));error(err,0) end
