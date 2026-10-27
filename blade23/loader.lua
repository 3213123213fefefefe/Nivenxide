-- A live interface owns the session; a stale flag alone must never block a retry.
local __bootEnv=(getgenv and getgenv()) or shared
local function __bladeSession(runtime)
  local previous=__bootEnv.__BLADE23_SESSION
  local same=type(previous)=="table" and previous.jobId==game.JobId
    and (previous.gameRef==nil or previous.gameRef==game)
    and (previous.placeId==nil or previous.placeId==game.PlaceId)
  local inherited
  local legacyHandoff=same and previous.phase=="execute" and previous.thread==nil and not previous.executing
  if same and previous.state=="loading" and runtime and (previous.runtimeHandoff or legacyHandoff) and not previous.cancelled then
    previous.runtimeHandoff=nil;previous.executing=true
    if type(previous.abort)=="function" then return previous end
    inherited=previous;previous=nil;same=false -- Upgrade a loader cached before this lifecycle version.
  end
  if same then
    local live=false
    if previous.state=="running" then
      pcall(function()
        local lib=previous.library
        live=lib~=nil and not lib.Unloaded and lib.ScreenGui~=nil and lib.ScreenGui.Parent~=nil
      end)
    elseif previous.state=="loading" and not previous.cancelled then
      local age=os.clock()-(previous.updated or previous.started or 0)
      local dead=previous.thread and coroutine.status(previous.thread)=="dead"
      live=not dead and age>=0 and age<90
    elseif previous.state=="unloading" then
      local age=os.clock()-(previous.updated or 0)
      live=age>=0 and age<15
    end
    if live then
      warn("[blade 23] Ja existe uma instancia carregando, ativa ou encerrando. Aguarde ou use Config > Unload.")
      return nil
    end
  end
  if type(previous)=="table" then
    if same and type(previous.abort)=="function" then
      pcall(previous.abort,"sessao anterior incompleta")
    else
      previous.cancelled=true;previous.executing=false
      if same then
        if previous.library and previous.library.Unload then pcall(function() previous.library:Unload() end) end
        if previous.coreCleanup then pcall(previous.coreCleanup) end
      elseif __bootEnv.Library==previous.library then
        __bootEnv.Library=nil -- Do not invoke old-world hooks from the next DataModel.
      end
    end
  end
  local session=inherited or {state="loading",jobId=game.JobId,started=os.clock()}
  session.gameRef=game;session.placeId=game.PlaceId;session.updated=os.clock();session.thread=coroutine.running()
  __bootEnv.__BLADE23_SESSION=session
  session.abort=function(reason)
    if session.state=="unloaded" then return end
    local loading=session.state=="loading"
    local unloading=session.state=="unloading"
    session.cancelled=true;session.executing=false;session.error=tostring(reason)
    for _,thread in {loading and session.thread or nil,unloading and session.unloadThread or nil} do
      if thread and thread~=coroutine.running() and task and task.cancel then pcall(task.cancel,thread) end
    end
    if session.library and session.library.Unload then
      session.library.Unloading=false -- The abandoned cleanup coroutine has been cancelled above.
      pcall(function() session.library:Unload() end)
    end
    if session.cleanup then pcall(session.cleanup) end
    if session.coreCleanup then pcall(session.coreCleanup);session.coreCleanup=nil end
    if session.guardKey and __bootEnv[session.guardKey]==session then __bootEnv[session.guardKey]=nil end
    if session.state~="unloaded" then session.state="failed" end
  end
  if task and task.spawn and task.wait then
    task.spawn(function()
      while __bootEnv.__BLADE23_SESSION==session and session.state=="loading" and not session.cancelled do
        task.wait(1)
        if session.state=="loading" and os.clock()-session.updated>=90 then
          session.abort("tempo limite no carregamento: "..tostring(session.phase))
          warn("[blade 23] Carregamento interrompido; execute o loader novamente. Etapa: "..tostring(session.phase))
          break
        end
      end
    end)
  end
  return session
end
local session=__bladeSession(false)
if not session then return false end
session.phase="download"
session.report={version=1,jobId=game.JobId,placeId=game.PlaceId,samples={}}
local function checkpoint(phase)
    session.phase=phase
    session.updated=os.clock()
    local sample={phase=phase,seconds=math.floor((os.clock()-session.started)*10)/10}
    pcall(function() sample.luaMB=math.floor(gcinfo()/1024*10)/10 end)
    pcall(function() sample.clientMB=math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb()*10)/10 end)
    table.insert(session.report.samples,sample)
    session.report.phase=phase;session.report.state=session.state
    if writefile then pcall(function()
        if makefolder and isfolder then
            if not isfolder("sentinel") then makefolder("sentinel") end
            if not isfolder("sentinel/.cache") then makefolder("sentinel/.cache") end
        end
        writefile("sentinel/.cache/blade23_ram_diagnostic.json",game:GetService("HttpService"):JSONEncode(session.report))
    end) end
end
checkpoint("download")
local runtimeURL="https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/sentinel.lua"
local ok,result=pcall(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    local nonce=tostring(os.time())..tostring(math.random(100000,999999))
    local source=game:HttpGet(runtimeURL.."?blade23="..nonce,true)
    if type(source)~="string" or source=="" then error("Resposta vazia ao baixar o runtime",0) end
    checkpoint("compile")
    local run,compileError=loadstring(source)
    source=nil
    if not run then error("O runtime nao compilou: "..tostring(compileError),0) end
    checkpoint("execute")
    if session.cancelled then error("carregamento cancelado",0) end
    session.runtimeHandoff=true
    local value=run()
    session.runtimeHandoff=nil
    run=nil
    return value
end)
if not ok then
    session.abort(result)
    session.state="failed";session.executing=false
    session.report.error=tostring(result):sub(1,300)
    checkpoint("failed")
    warn("[blade 23] Falha em "..tostring(session.phase)..": "..tostring(result))
    return false
end
if result~=true or session.state~="running" then
    session.abort("runtime terminou antes de abrir a interface")
    return false
end
return true
