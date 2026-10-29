-- Nivenxide: standalone anti-AFK, based on Hydroxide's Idled connection method.
-- No UI, frame callbacks, polling loops, simulated inputs or other downloads.
assert(type(getconnections) == "function", "[Anti-AFK] Executor sem getconnections")
if not game:IsLoaded() then game.Loaded:Wait() end

local players = game:GetService("Players")
local player = players.LocalPlayer
assert(player, "[Anti-AFK] LocalPlayer indisponivel")

local env = getgenv()
local state = env.NivenxideAntiAFK
if not state then
    state = {connections = {}}
    env.NivenxideAntiAFK = state
end

local count = 0
for _, connection in ipairs(getconnections(player.Idled)) do
    -- Preserve connections already disabled by another script.
    if connection.Enabled ~= false then
        local ok = pcall(function() connection:Disable() end)
        if ok then
            state.connections[#state.connections + 1] = connection
            count = count + 1
        end
    end
end

-- Optional: getgenv().NivenxideAntiAFK.Stop()
function state.Stop()
    for _, connection in ipairs(state.connections) do
        pcall(function() connection:Enable() end)
    end
    state.connections = {}
    if env.NivenxideAntiAFK == state then env.NivenxideAntiAFK = nil end
end

if #state.connections > 0 then
    print("[Anti-AFK] Ativo. Sem loops ou cliques simulados.")
elseif count == 0 then
    warn("[Anti-AFK] Nenhuma conexao ativa encontrada. Pode ja estar desativada; execute novamente apos o jogo carregar.")
end
