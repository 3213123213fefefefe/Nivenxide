local runtime=require('../ExtrasRuntime')
local policy=require('../ExtrasPolicy')
local coreBridge=require('../CoreBridge')
local keys={'l','p','r','w','A','E','K','N','O','P','T','U','V','X','Y','Z','_','aa','ab','ac','af'}
local function test(failAt)
 local original={owned=true,Toggled=true,Toggle=function(self,value) self.Toggled=value end};local primaryOriginal=original.Toggle;local env={Library=original};local callbacks={};local attached={};local cleans=0;local captured;local library={Unloaded=false}
 local class={};class.__index=class
 function class.new() return setmetatable({_tasks={}},class) end
 function class:Give(job) table.insert(self._tasks,job) end
 function class:DoCleaning() for k,job in pairs(self._tasks) do self._tasks[k]=nil;job() end end
 class.Destroy=class.DoCleaning
 local function group()
  local g={}
  function g:SetVisible(v) self.visible=v end
  function g:AddToggle(id,info)
   local object={Value=info.Default}
   function object:SetValue(value) self.Value=value;if info.Callback then info.Callback(value) end end
   function object:SetVisible(v) self.visible=v end
   function object:SetDisabled(v) self.disabled=v end
   return object
  end
  function g:AddSlider(id,info) return self:AddToggle(id,info) end
  g.AddDropdown=g.AddSlider;g.AddInput=g.AddSlider
  return g
 end
 local window={}
 function window:AddTab(name)
  local tab={}
  function tab:AddLeftGroupbox() return group() end
  tab.AddRightGroupbox=tab.AddLeftGroupbox
  return tab
 end
 function window:Toggle(v) if v==nil then v=not library.Toggled end;self.visible=v;library.Toggled=v end
 function library:CreateWindow() return window end
 function library:OnUnload(fn) table.insert(callbacks,fn) end
 function library:Unload() self.Unloaded=true;for _,f in callbacks do f() end end
 function library:Notify(info) assert(type(info)=='table') end
 local remotes={fireBlocked=function() return true end}
 local modules={d=function()return class end,e=function()return remotes end}
 for _,key in keys do
  modules[key]=function() return function(context)
   captured=context
   assert(context.State.loadingConfig)
   table.insert(attached,key)
   context.Maid:Give(function() cleans+=1 end)
   if key==failAt then error('injected module failure') end
  end end
 end
 local scope={getgenv=function() return env end,loadstring=loadstring,setfenv=setfenv,getfenv=getfenv,
  readfile=function(path)
   if string.find(path,'CoreBridge.lua',1,true) then return 'return mockCoreBridge' end
   if string.find(path,'ExtrasEngine.lua',1,true) then return 'return mockEngineFactory' end
   if string.find(path,'ExtrasPolicy.lua',1,true) then return 'return mockPolicy' end
   if string.find(path,'BaseControls.lua',1,true) then return 'return {}' end
   if string.find(path,'ModeratorSnapshot.lua',1,true) then return 'return {ids={[123]=true},groups={1}}' end
   error('Unexpected read '..path)
  end,
  mockEngineFactory=function()return {modules=modules,ui={lib='getgenv().Library=mockLibrary;return mockLibrary',theme='return {}',save='return {}'}} end,
  tick=function()return 0 end,mockCoreBridge=coreBridge,mockPolicy=policy,mockLibrary=library,Enum={KeyCode={RightControl=1}},
 }
 setmetatable(scope,{__index=getfenv()})
 setfenv(runtime,scope)
 local ctx={original=original,player={},shared={is_unloading=false}}
 local ok,result=pcall(runtime,ctx)
 assert(env.Library==original,'Extras must not replace the primary library')
 if failAt then
  assert(not ok and library.Unloaded and cleans==#attached,'Failed startup must clean all attached modules')
 else
  assert(ok and #attached==#keys and not library.Unloaded,tostring(result))
  assert(captured.State.moderatorIds[123] and not captured.State.loadingConfig)
  assert(result.fireBlocked({}))
  result.toggle();assert(not original.Toggled and library.Toggled)
  original:Toggle(true);assert(original.Toggled and not library.Toggled)
  assert(captured.State.robloxGet('http://127.0.0.1:7963')==nil)
  result.unload();result.unload()
  assert(library.Unloaded and cleans==#keys and not result.fireBlocked({}) and original.Toggle==primaryOriginal)
 end
end
test(nil)
test('K')
print('PASS: runtime initializes all feature families, isolates library globals, handles module failure, rejects non-Roblox asset hosts, unloads idempotently and leaves primary client owned by Hydroxide')
