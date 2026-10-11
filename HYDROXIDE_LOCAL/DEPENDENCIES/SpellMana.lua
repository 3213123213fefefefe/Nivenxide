-- Shared spell windows for the character widget and Gelidus snap guard.
return function(ctx)
    local collection = game:GetService("CollectionService")
    local defaults = {Gate = {{75, 83}, {75, 83}}, Gelidus = {{80, 95}, {85, 100}},
        Viribus = {{23, 35}, {60, 70}}}
    local function ranges(name, character)
        local spell = (ctx.spellCosts or defaults)[name]
        if not spell or not character then return end
        local bonus = 0
        local boosts = character:FindFirstChild("Boosts")
        local boon = boosts and boosts:FindFirstChild("ScholarsBoon")
        if boon then bonus = bonus + boon.Value end
        local backpack = ctx.player:FindFirstChildOfClass("Backpack")
        if backpack then
            if backpack:FindFirstChild("WiseCasting") then bonus = bonus + 2 end
            if backpack:FindFirstChild("RemTraining") then bonus = bonus + 3 end
        end
        local function adjusted(window)
            if not window then return end
            return {math.max(0, window[1] - bonus), math.min(100, window[2] + bonus)}
        end
        return adjusted(spell[1]), adjusted(spell[2])
    end
    local function inside(value, range)
        return range ~= nil and value >= range[1] and value <= range[2]
    end
    local function blockGelidusSnap(character)
        if not character or not character:FindFirstChild("Gelidus") then return false end
        -- RightClick can serve other actions while snap is unavailable. Match
        -- the existing Viribus guard: do not swallow those clicks in SnapCool.
        if character:FindFirstChild("SnapCool") or collection:HasTag(character, "SnapCool") then
            return false
        end
        local artifacts = character:FindFirstChild("Artifacts")
        if artifacts and artifacts:FindFirstChild("PhilosophersStone") then return false end
        local mana = character:FindFirstChild("Mana")
        if not mana then return false end
        local _, snap = ranges("Gelidus", character)
        return snap ~= nil and not inside(mana.Value, snap)
    end
    local function spellNames()
        local names = {}
        for name in pairs(ctx.spellCosts or defaults) do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    return {ranges = ranges, inside = inside, blockGelidusSnap = blockGelidusSnap, spellNames = spellNames}
end
