-- Additional feature host. The standard client remains the gameplay owner.
return function(ctx)
    local realEnv = getgenv()
    local isolated = setmetatable({Library=false, HXD_MERGED=true,
        SENTINEL_RESUMED_FROM_HOP=realEnv.SENTINEL_RESUMED_FROM_HOP}, {__index=realEnv})
    realEnv.SENTINEL_RESUMED_FROM_HOP=nil
    local scope = setmetatable({getgenv=function() return isolated end}, {__index=getfenv()})
    local function compile(source, name)
        local fn, err = loadstring(source, "@HYDROXIDE_MERGED/" .. name)
        assert(fn, err)
        setfenv(fn, scope)
        return fn
    end
    scope.loadstring = function(source,name)
        local fn,err = loadstring(source,name)
        if fn then setfenv(fn,scope) end
        return fn,err
    end
    local engineFactory = compile(readfile("HYDROXIDE_MERGED/ExtrasEngine.lua"),"ExtrasEngine.lua")()
    local engine = engineFactory()
    local modules = engine.modules
    local Library = compile(engine.ui.lib,"extras-ui.lua")()
    local ThemeManager = compile(engine.ui.theme,"extras-themes.lua")()
    local SaveManager = compile(engine.ui.save,"extras-configs.lua")()
    local maidClass = modules.d()
    local originalClean = maidClass.DoCleaning
    maidClass.DoCleaning = function(self)
        -- A failed restoration must not leave the other connections / hooks alive.
        for pass=1,2 do
            for key,item in pairs(self._tasks) do
                local connection = typeof(item)=="RBXScriptConnection"
                if (pass==1 and connection) or (pass==2 and not connection) then
                    self._tasks[key]=nil
                    local one=setmetatable({_tasks={[key]=item}},getmetatable(self))
                    local ok,err=pcall(originalClean,one)
                    if not ok then warn("[Hydroxide Extras] Cleanup task: " .. tostring(err)) end
                end
            end
        end
    end
    maidClass.Destroy = maidClass.DoCleaning
    local maid = maidClass.new()
    local window = Library:CreateWindow({Title="Hydroxide · Extras Sentinel",Center=true,
        ShowCustomCursor=false,NotifySide="Left",ToggleKeybind=Enum.KeyCode.RightControl})
    local primaryToggle=ctx.original.Toggle
    local extraToggle=window.Toggle
    local primaryWrapper
    primaryWrapper=function(self,value)
        local opening=type(value)=="boolean" and value or not self.Toggled
        if type(value)=="boolean" then opening=value end
        if opening and Library.Toggled then extraToggle(window,false) end
        return primaryToggle(self,value)
    end
    if primaryToggle then
        ctx.original.Toggle=primaryWrapper
        window.Toggle=function(self,value)
            local opening=type(value)=="boolean" and value or not Library.Toggled
            if type(value)=="boolean" then opening=value end
            if opening and ctx.original.Toggled then primaryToggle(ctx.original,false) end
            return extraToggle(self,value)
        end
        maid:Give(function() if ctx.original.Toggle==primaryWrapper then ctx.original.Toggle=primaryToggle end end)
    end
    local state = {loadingConfig=true,bots={},moderatorIds={},moderatorGroups={},moderatorsLoaded=true,
        productName="rogue-lineage",productSecret=""}
    local snapshot=compile(readfile("HYDROXIDE_MERGED/ModeratorSnapshot.lua"),"ModeratorSnapshot.lua")()
    state.moderatorIds,state.moderatorGroups=snapshot.ids,snapshot.groups
    local bridge=compile(readfile("HYDROXIDE_MERGED/CoreBridge.lua"),"CoreBridge.lua")()(ctx.original.Toggles,state,tick)
    state.originalKillbricks=bridge.setKillbricks
    maid:Give(bridge.cleanup)
    if bridge.available then maid:Give(game:GetService("RunService").Heartbeat:Connect(bridge.step)) end
    local statuses, live = {}, true
    local api = {library=Library,syncGuards=bridge.step}
    local policy = compile(readfile("HYDROXIDE_MERGED/ExtrasPolicy.lua"),"ExtrasPolicy.lua")()(Library,
        compile(readfile("HYDROXIDE_MERGED/BaseControls.lua"),"BaseControls.lua")())
    local tabs = {}
    for _,name in ipairs({"Combat","Visuals","Movement","World","Automation","Botting","Player","Settings"}) do
        tabs[name] = policy.tab(window:AddTab(name))
    end
    local context = {Library=Library,ThemeManager=ThemeManager,SaveManager=SaveManager,Maid=maid,State=state,Tabs=tabs}
    state.registerBot=function(bot) table.insert(state.bots,bot) end
    state.safeTerminate=function(reason)
        if live then ctx.player:Kick("[Hydroxide Extras] " .. tostring(reason)) end
    end
    local function request(options)
        local fn = (http and http.request) or http_request or getfenv().request
        if fn then
            local ok,response=pcall(fn,options)
            if ok then return response end
        end
    end
    local function official(url)
        if type(url)~="string" then return false end
        local host=url:match("^https://([^/]+)")
        return host and (host=="roblox.com" or host:match("%.roblox%.com$") or host=="rbxcdn.com" or host:match("%.rbxcdn%.com$"))
    end
    state.robloxGet=function(url)
        if not official(url) then return nil,"Unsupported asset host" end
        local response=request({Url=url,Method="GET"})
        if response then
            local code=response.StatusCode or response.status_code
            local headers=response.Headers or response.headers or {}
            return code==200 and (response.Body or response.body) or nil,code,headers.Location or headers.location
        end
        local ok,body=pcall(game.HttpGet,game,url)
        return ok and body or nil
    end
    state.getPresence=function(ids)
        local service=game:GetService("HttpService")
        local response=request({Url="https://presence.roblox.com/v1/presence/users",Method="POST",
            Headers={["Content-Type"]="application/json"},Body=service:JSONEncode({userIds=ids})})
        if not response or (response.StatusCode or response.status_code)~=200 then return nil end
        local ok,data=pcall(service.JSONDecode,service,response.Body or response.body)
        if not ok then return nil end
        local result={}
        for _,entry in ipairs(data.userPresences or {}) do
            result[entry.userId]={gameId=entry.gameId,placeId=entry.placeId,
                joinable=entry.userPresenceType==2 and type(entry.gameId)=="string" and entry.gameId~=""}
        end
        return result
    end
    -- Reuse standard-captured mana remotes; never install a second KeyHandler/anti-cheat core.
    local remotes=modules.e()
    remotes.preloadKeyHandler=function() return nil end
    remotes.keyHandlerEnabled=function() return false end
    remotes.getRemote=function(name)
        if (name=="Charge" or name=="SetManaChargeState") and ctx.manaRemote then
            local mana=ctx.manaRemote()
            if mana and mana.Parent then return mana end
        end
        local character=ctx.player.Character
        local handler=character and character:FindFirstChild("CharacterHandler")
        local folder=handler and handler:FindFirstChild("Remotes")
        return folder and folder:FindFirstChild(name)
    end
    api.fireBlocked=function(remote) return live and remotes.fireBlocked(remote) end
    local function unload()
        if not live then return end
        live=false
        local ok,err=pcall(maid.DoCleaning,maid)
        if not ok then warn("[Hydroxide Extras] Cleanup: " .. tostring(err)) end
        if not Library.Unloaded then Library:Unload() end
    end
    Library:OnUnload(function()
        if live then live=false; pcall(maid.DoCleaning,maid) end
    end)
    api.unload=unload
    api.toggle=function() if live then window:Toggle() end end
    api.report=function()
        for _,row in ipairs(statuses) do print("[Hydroxide Extras] " .. row.name .. ": " .. row.status) end
        local locked=0;for _ in pairs(policy.locked) do locked+=1 end
        Library:Notify({Title="Verificacao da integracao",Description=tostring(#policy.audit)
            .. " controles novos; " .. tostring(locked) .. " controles duplicados bloqueados. Consulte F9 para os modulos."})
    end
    local labels={l="Combate adicional / rune cast",p="Visuais adicionais",r="Suporte de efeitos",
        w="Waypoints / boosts",A="Safe Server / mundo",E="Healer / suporte de mana",
        K="Progressao",N="Rot Bot",O="Scroom Bot",P="Healer Bot",T="Castle Rock",
        U="Suporte de macros (controles padrao bloqueados)",V="Suporte de day farm (controles padrao bloqueados)",
        X="Suporte de bots (trinket padrao bloqueado)",Y="Utilitarios novos",Z="Aliados / personalizacao",
        _="Grip Bot",aa="Judgement",ab="Skins de arma",ac="Suporte de servidores",af="Configuracao de extras"}
    local ok,err=xpcall(function()
        for _,key in ipairs({"l","p","r","w","A","E","K","N","O","P","T","U","V","X","Y","Z","_","aa","ab","ac","af"}) do
            if not live or ctx.shared.is_unloading then error("Client unloaded while attaching extras") end
            local passed,why=xpcall(function() modules[key]()(context) end,debug.traceback)
            statuses[#statuses+1]={name=labels[key],status=passed and "carregado" or tostring(why)}
            if not passed then error(labels[key] .. ": " .. tostring(why)) end
        end
    end,debug.traceback)
    state.loadingConfig=false
    if not ok then
        unload()
        error("Extras nao iniciaram; Hydroxide padrao continua ativo. " .. tostring(err))
    end
    window:Toggle(false)
    Library:Notify({Title="Extras Sentinel",Description="Carregado. Abra pela aba Extras Sentinel ou RightControl. Versao experimental."})
    return api
end
