-- Blade 23: always fetch the published runtime from this repository.
local runtimeURL = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/sentinel.lua"
if not game:IsLoaded() then game.Loaded:Wait() end
local nonce = tostring(os.time()) .. tostring(math.random(100000, 999999))
local ok, source = pcall(function()
    return game:HttpGet(runtimeURL .. "?blade23=" .. nonce, true)
end)
if not ok or type(source) ~= "string" or source == "" then
    error("[blade 23] Falha ao baixar o script do GitHub: " .. tostring(source), 0)
end
local run, compileError = loadstring(source)
if not run then
    error("[blade 23] O script baixado nao compilou: " .. tostring(compileError), 0)
end
return run()
