-- Blade 23: one startup at a time, always use the published runtime.
local env=(getgenv and getgenv()) or shared
local previous=env.__BLADE23_SESSION
if previous and previous.jobId==game.JobId and (previous.state=="loading" or previous.state=="running") then
    warn("[blade 23] Ja existe uma instancia carregando ou ativa. Use Config > Unload antes de recarregar.")
    return false
end
local session={state="loading",phase="download",jobId=game.JobId,started=os.clock()}
env.__BLADE23_SESSION=session
session.report={version=1,jobId=game.JobId,placeId=game.PlaceId,samples={}}
local function checkpoint(phase)
    session.phase=phase
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
    local value=run()
    run=nil
    return value
end)
if not ok then
    session.state="failed";session.executing=false
    session.report.error=tostring(result):sub(1,300)
    checkpoint("failed")
    warn("[blade 23] Falha em "..tostring(session.phase)..": "..tostring(result))
    return false
end
return result
