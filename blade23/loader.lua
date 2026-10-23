-- Blade 23: one startup at a time, always use the published runtime.
local env=(getgenv and getgenv()) or shared
local previous=env.__BLADE23_SESSION
if previous and previous.jobId==game.JobId and (previous.state=="loading" or previous.state=="running") then
    warn("[blade 23] Ja existe uma instancia carregando ou ativa. Use Config > Unload antes de recarregar.")
    return false
end
local session={state="loading",jobId=game.JobId}
env.__BLADE23_SESSION=session
local runtimeURL="https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/sentinel.lua"
local ok,result=pcall(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    local nonce=tostring(os.time())..tostring(math.random(100000,999999))
    local source=game:HttpGet(runtimeURL.."?blade23="..nonce,true)
    if type(source)~="string" or source=="" then error("Resposta vazia ao baixar o runtime",0) end
    local run,compileError=loadstring(source)
    source=nil
    if not run then error("O runtime nao compilou: "..tostring(compileError),0) end
    local value=run()
    run=nil
    return value
end)
if not ok then
    session.state="failed";session.executing=false
    warn("[blade 23] Falha ao carregar: "..tostring(result))
    return false
end
return result
