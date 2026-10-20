-- New bots borrow standard controls instead of activating a second implementation.
return function(controls,state,clock)
    local closed=false
    local noFall=controls and (controls.no_fall or controls.NoFall)
    local kill=controls and (controls.no_killbrick or controls.NoKillBricks)
    local leases={}
    local function set(control,desired)
        if not control or not control.SetValue then return false end
        local lease=leases[control]
        if desired==nil then
            if lease then
                leases[control]=nil
                control:SetValue(lease.previous)
            end
            return true
        end
        if not lease then lease={previous=control.Value,last=control.Value};leases[control]=lease
        elseif control.Value~=lease.last then lease.previous=control.Value end
        if control.Value~=desired then control:SetValue(desired) end
        lease.last=desired
        return true
    end
    local function step()
        if closed then return end
        local now=clock()
        if state.scroomNoFallOverride or (state.fallDamageBypassUntil and now<state.fallDamageBypassUntil) then
            set(noFall,false)
        elseif state.noFallUntil and now<state.noFallUntil then set(noFall,true)
        else set(noFall,nil) end
    end
    return {step=step,
        setKillbricks=function(value)
            if closed then return end
            if value then return set(kill,true) end
            return set(kill,nil)
        end,
        available=noFall~=nil or kill~=nil,
        cleanup=function()
            if closed then return end
            closed=true
            for control,lease in pairs(leases) do
                leases[control]=nil
                pcall(control.SetValue,control,lease.previous)
            end
        end}
end
