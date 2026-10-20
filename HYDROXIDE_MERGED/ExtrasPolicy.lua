-- Compatibility boundary: the standard Hydroxide owns every existing feature.
return function(library, baseControls)
    local blockedGroups = {
        ["Auto Parry"]=true, ["Parry Settings"]=true, ["Combat Utilities"]=true, ["Silent Aim"]=true,
        ["Player ESP"]=true, Chams=true, ["World ESP"]=true, ["Ingredient ESP"]=true,
        ["Ore ESP"]=true, Environment=true, ["Status Effects"]=true,
        Flight=true, Fling=true, Freecam=true, Speed=true, ["World Settings"]=true, Proximity=true,
        ["Auto Crafting"]=true, ["Mana & Training"]=true, ["Auto Pickup"]=true,
        Macros=true, ["Day Farm"]=true, ["Path Recorder"]=true, ["Pickup Filters"]=true,
        ["While Botting"]=true, ["Trinket Bot Config"]=true, ["Bot Safety"]=true,
        ["Looping Settings"]=true, Performance=true, Character=true, Spoofing=true, Servers=true, Exploits=true,
        Webhook=true, ["Webhook Pings"]=true, ["Chat Logger"]=true, ["Toy Alert"]=true,
    }
    local additions = {CooldownIndicator=true, NoOrderlyBarriers=true, DisableSnow=true,
        FallDamageReducer=true, FallDamageReduction=true}
    local reserved = {NsfwMode=true, SharedLook=true, ShareDebug=true, ExecuteOnServerhop=true,
        DayFarm=true, TrinketBot=true, BotEnabled=true, AutoPerfectBlock=true, SilentAim=true,
        NoStun=true, NoHystericus=true, NoConfusion=true, NoFall=true, TemperatureLock=true,
        Fly=true, Flight=true, Fling=true, Freecam=true, Speed=true, NoClip=true}
    local exempt = {Menu=true, Themes=true, Configuration=true}
    local audit, locked = {}, {}
    local function norm(value) return tostring(value or ""):lower():gsub("[^%w]", "") end
    local function isDuplicate(groupName, id, info)
        if additions[id] then return false end
        if reserved[id] then return true end
        if exempt[groupName] then return false end
        return blockedGroups[groupName] or baseControls[norm(id)]
            or (info.Text and #norm(info.Text) >= 9 and baseControls[norm(info.Text)])
    end
    local function decorateGroup(group, name)
        local hidden = blockedGroups[name]
        local revealed=false
        local visible=group.SetVisible
        if hidden and visible then
            visible(group,false)
            group.SetVisible=function(self,value) visible(self,revealed and value~=false) end
        end
        local function reveal(id)
            if hidden and additions[id] and visible then revealed=true;visible(group,true) end
        end
        local addToggle = group.AddToggle
        group.AddToggle = function(self, id, info)
            local deny = isDuplicate(name, id, info)
            if not deny then reveal(id);audit[#audit+1] = {group=name,id=id,text=info.Text} end
            if not deny then return addToggle(self,id,info) end
            -- Lock before initialization and keep it locked through config loads / script writes.
            local copy = table.clone(info)
            copy.Default, copy.Callback = false, nil
            local object = addToggle(self,id,copy)
            locked[id] = true
            local set = object.SetValue
            if set then object.SetValue = function(control) return set(control, false) end end
            if object.SetDisabled then object:SetDisabled(true) end
            if object.SetVisible then object:SetVisible(false) end
            return object
        end
        for _, method in ipairs({"AddDropdown", "AddSlider", "AddInput"}) do
            local original = group[method]
            if original then
                group[method] = function(self,id,info)
                    local object = original(self,id,info)
                    if isDuplicate(name,id,info) and not exempt[name] then
                        if object.SetVisible then object:SetVisible(false) end
                    elseif not hidden or additions[id] then reveal(id);audit[#audit+1] = {group=name,id=id,text=info.Text} end
                    return object
                end
            end
        end
        return group
    end
    local function decorateTab(tab)
        for _, method in ipairs({"AddLeftGroupbox", "AddRightGroupbox"}) do
            local original = tab[method]
            if original then tab[method] = function(self,name,...) return decorateGroup(original(self,name,...),name) end end
        end
        -- Progression and other bot panels use tabboxes rather than groupboxes.
        for _, method in ipairs({"AddLeftTabbox", "AddRightTabbox"}) do
            local original = tab[method]
            if original then
                tab[method] = function(self,...)
                    local box = original(self,...)
                    local add = box.AddTab
                    box.AddTab = function(b,name,...) return decorateGroup(add(b,name,...),name) end
                    return box
                end
            end
        end
        return tab
    end
    return {tab=decorateTab,audit=audit,locked=locked,groups=blockedGroups}
end
