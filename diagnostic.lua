-- Read-only, 45-second local signal capture; does not activate any skill.
local env = getgenv()
if env.NivenxideDiagnosticStop then env.NivenxideDiagnosticStop() end
local player = game:GetService("Players").LocalPlayer
local tags = game:GetService("CollectionService")
local character = player.Character
assert(character, "Entre no jogo antes de iniciar o diagnostico")
local connections, lines, closed = {}, {}, false
local started = os.clock()
local function record(kind, detail)
    if closed or #lines >= 500 then return end
    local line = string.format("[Nivenxide DIAG] +%.3fs %s %s", os.clock() - started, kind, tostring(detail))
    lines[#lines + 1] = line
    print(line)
end
local function connect(signal, callback)
    connections[#connections + 1] = signal:Connect(callback)
end
local function stop()
    if closed then return end
    record("FIM", "Copie as linhas Nivenxide DIAG do console")
    closed = true
    for _, connection in ipairs(connections) do connection:Disconnect() end
    env.NivenxideDiagnosticLog = table.concat(lines, "\n")
    env.NivenxideDiagnosticStop = nil
    if type(writefile) == "function" then
        local ok = pcall(writefile, "Nivenxide_diagnostic.txt", env.NivenxideDiagnosticLog)
        if ok then print("[Nivenxide DIAG] Log salvo: workspace/Nivenxide_diagnostic.txt") end
    end
end
env.NivenxideDiagnosticStop = stop
local trackedTags = {}
local function watchTag(name)
    if trackedTags[name] then return end
    trackedTags[name] = true
    local function localInstance(instance)
        return instance == character or instance:IsDescendantOf(character)
    end
    connect(tags:GetInstanceAddedSignal(name), function(instance)
        if localInstance(instance) then record("TAG+", name .. " @ " .. instance.Name) end
    end)
    connect(tags:GetInstanceRemovedSignal(name), function(instance)
        if localInstance(instance) then record("TAG-", name .. " @ " .. instance.Name) end
    end)
end
for _, name in ipairs(tags:GetAllTags()) do watchTag(name) end
for _, name in ipairs(tags:GetTags(character)) do record("TAG_INICIAL", name) end
local watched = setmetatable({}, {__mode = "k"})
local names = {Brandish=true, Puncture=true, ["Azure Ignition"]=true, ["Blade Crash"]=true}
local function watchTool(tool)
    if not tool:IsA("Tool") or not names[tool.Name] or watched[tool] then return end
    watched[tool] = true
    connect(tool.Activated, function() record("TENTATIVA", tool.Name) end)
    connect(tool:GetPropertyChangedSignal("Enabled"), function()
        record("TOOL_ENABLED", tool.Name .. "=" .. tostring(tool.Enabled))
    end)
    connect(tool.AttributeChanged, function(name)
        record("TOOL_ATTR", tool.Name .. "." .. name .. "=" .. tostring(tool:GetAttribute(name)))
    end)
end
for _, child in ipairs(character:GetChildren()) do watchTool(child) end
local backpack = player:FindFirstChildOfClass("Backpack")
if backpack then
    for _, child in ipairs(backpack:GetChildren()) do watchTool(child) end
    connect(backpack.ChildAdded, watchTool)
end
connect(character.ChildAdded, function(child)
    record("CHAR+", child.Name .. " (" .. child.ClassName .. ")")
    watchTool(child)
end)
connect(character.ChildRemoved, function(child) record("CHAR-", child.Name) end)
connect(character.AttributeChanged, function(name)
    record("CHAR_ATTR", name .. "=" .. tostring(character:GetAttribute(name)))
end)
local animatorSeen = setmetatable({}, {__mode = "k"})
local function watchAnimator(instance)
    if not instance:IsA("Animator") or animatorSeen[instance] then return end
    animatorSeen[instance] = true
    connect(instance.AnimationPlayed, function(track)
        local animation = track.Animation
        record("ANIM", animation and animation.AnimationId or track.Name)
    end)
end
for _, instance in ipairs(character:GetDescendants()) do watchAnimator(instance) end
connect(character.DescendantAdded, watchAnimator)
connect(player.CharacterRemoving, function(old) if old == character then stop() end end)
-- Discovers new tag names; event timestamps still reflect receipt by the client.
task.spawn(function()
    while not closed do
        for _, name in ipairs(tags:GetAllTags()) do watchTag(name) end
        task.wait(0.1)
    end
end)
record("INICIO", "45s: use UMA skill e tente ate conseguir usa-la novamente; nao use outras skills")
task.delay(45, stop)
