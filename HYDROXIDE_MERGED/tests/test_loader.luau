local source=[====[-- Separate experimental build: standard Hydroxide + filtered Sentinel extras.
local env=getgenv()
if env.HXD_MERGED_LOADING then warn("[Hydroxide Merge] Ja existe uma sessao/carregamento desta versao");return end
if type(env.Library)=="table" and env.Library.Unload and not env.Library.Unloaded then
    error("Use Unload Script no script atual antes de abrir a versao combinada",0)
end
env.HXD_MERGED_LOADING=true
local ok,err=pcall(function()
    assert(readfile and writefile and isfile and isfolder and makefolder,"Executor sem arquivos locais")
    local root="HYDROXIDE_MERGED"
    local version="__MERGE_VERSION__"
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
]====]
local function run(existing,fail,stamp,corrupt)
 local env={Library=existing};local files={};local folders={};local calls=0;local starts=0
 if stamp then files['HYDROXIDE_MERGED/installed.version']='__MERGE_VERSION__' end
 local function content(path)
  if path=='start.lua' then return 'return true' end
  return 'bytes:'..path
 end
 local scope={}
 scope.getgenv=function()return env end
 scope.isfile=function(path)return files[path]~=nil end
 scope.isfolder=function(path)return folders[path]==true end
 scope.makefolder=function(path)folders[path]=true end
 scope.readfile=function(path)return assert(files[path],path) end
 scope.writefile=function(path,data) files[path]=data;if corrupt and string.find(path,'ExtrasPolicy',1,true) then files[path]='bad' end end
 scope.game={HttpGet=function(_,url)
  calls+=1
  if fail and calls==fail then error('download failure') end
  local path=url:match('/HYDROXIDE_MERGED/(.+)$') or url:match('/HYDROXIDE_LOCAL/(.+)$')
  return content(path)
 end}
 scope.loadstring=function(text,name)
  assert(text=='return true' and name=='@HYDROXIDE_MERGED/start.lua')
  return function() starts+=1;assert(env.HXD_MERGED_LOADING) end
 end
 scope.warn=function()end
 scope.print=function()end
 setmetatable(scope,{__index=getfenv()})
 local fn=assert(loadstring(source));setfenv(fn,scope)
 local ok=pcall(fn)
 return ok,files,calls,starts,env,fn,function()return calls,starts end
end
local ok,files,calls,starts,env,fn,count=run(nil)
assert(ok and calls==20 and starts==1 and env.HXD_MERGED_LOADING==false)
assert(files['HYDROXIDE_MERGED/installed.version']=='__MERGE_VERSION__')
fn();assert(env.HXD_MERGED_LOADING==false);local downloaded,ran=count();assert(downloaded==20 and ran==2)
local ok2,f2,c2,s2,e2=run({Unload=function()end})
assert(not ok2 and c2==0 and s2==0)
local ok3,f3,c3,s3,e3=run(nil,3)
assert(not ok3 and s3==0 and next(f3)==nil and e3.HXD_MERGED_LOADING==false)
local ok4,f4,c4,s4,e4=run(nil,nil,nil,true)
assert(not ok4 and s4==0 and f4['HYDROXIDE_MERGED/installed.version']=='incomplete' and e4.HXD_MERGED_LOADING==false)
print('PASS: combined loader installs 20 paths, launches cached start, rejects active client, stages downloads atomically, detects write errors and clears load lock')
