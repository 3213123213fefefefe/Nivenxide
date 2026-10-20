local policyFactory=require('../ExtrasPolicy')
local objects={}
local function group()
 local g={visible=true}
 function g:SetVisible(v) self.visible=v end
 function g:AddToggle(id,info)
  local t={Value=info.Default,visible=true,disabled=false,Callback=info.Callback}
  function t:SetValue(v) self.Value=v;if self.Callback then self.Callback(v) end end
  function t:SetVisible(v) self.visible=v end
  function t:SetDisabled(v) self.disabled=v end
  objects[id]=t
  if info.Callback then info.Callback(info.Default) end
  return t
 end
 function g:AddSlider(id,info) return self:AddToggle(id,info) end
 function g:AddDropdown(id,info) return self:AddToggle(id,info) end
 function g:AddInput(id,info) return self:AddToggle(id,info) end
 return g
end
local tab={}
function tab:AddLeftGroupbox() return group() end
tab.AddRightGroupbox=tab.AddLeftGroupbox
function tab:AddLeftTabbox()
 return {AddTab=function() return group() end}
end
tab.AddRightTabbox=tab.AddLeftTabbox
local p=policyFactory({}, {noclip=true,oldoption=true})
p.tab(tab)
local active=0
local original=tab:AddLeftGroupbox('Auto Parry')
original:SetVisible(true);assert(not original.visible)
local duplicate=original:AddToggle('AutoPerfectBlock',{Text='Auto Perfect Block',Default=true,Callback=function() active+=1 end})
assert(not duplicate.Value and not duplicate.visible and duplicate.disabled and active==0)
duplicate:SetValue(true);assert(not duplicate.Value and active==0)
local fresh=tab:AddRightGroupbox('Dash Prediction')
local addon=fresh:AddToggle('DashPredictSelf',{Text='Own Dash',Default=false,Callback=function(v) if v then active+=1 end end})
addon:SetValue(true);assert(addon.Value and active==1 and addon.visible)
local common=fresh:AddToggle('NoClip',{Text='No Clip',Default=true,Callback=function() active+=10 end})
common:SetValue(true);assert(not common.Value and active==1)
local settings=tab:AddLeftGroupbox('Menu')
local mode=settings:AddToggle('BlatantMode',{Text='Blatant Mode',Default=false})
mode:SetValue(true);assert(mode.Value)
local adult=settings:AddToggle('NsfwMode',{Default=true})
adult:SetValue(true);assert(not adult.Value)
local sub=tab:AddLeftTabbox():AddTab('Exploits')
local another=sub:AddToggle('Whatever',{Default=true});another:SetValue(true);assert(not another.Value)
local world=tab:AddLeftGroupbox('World Settings')
assert(not world.visible)
local reducer=world:AddToggle('FallDamageReducer',{Text='Fall Damage Reducer',Default=false})
reducer:SetValue(true);assert(reducer.Value and world.visible)
assert(p.locked.AutoPerfectBlock and p.locked.NoClip and p.locked.Whatever)
print('PASS: standard features permanently locked in extras, callbacks never activate, config cannot re-enable, hidden groups stay hidden, new options remain usable, tabboxes filtered')
