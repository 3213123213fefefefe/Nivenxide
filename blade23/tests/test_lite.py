"""Lite preservation checks plus the full edition's applicable behavior regressions."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

import test_route14 as baseline

ROOT=Path(__file__).resolve().parents[1]
AST=os.environ.get('LUAU_AST')
# These tests exclusively exercise cosmetic features absent from the optional Lite edition.
EXCLUDED={
    'test_deferred_text_events_and_stat_names_do_not_chain_writes',
    'test_esc_reopen_reuses_one_worker_and_does_not_wait_for_rendering',
    'test_leaderboard_can_map_rows_without_executor_introspection',
    'test_leaderboard_scan_is_single_flight_budgeted_and_cancellable',
    'test_menu_masks_coalesce_events_cap_frame_work_and_release_destroyed_ui',
    'test_own_leaderboard_alias_is_idempotent_and_preserves_hover_name_changes',
    'test_scramble_leaderboard_paints_outside_text_callbacks_and_cleans_up',
    'test_startup_memory_journal_is_bounded_and_keeps_last_phase',
}

class LiteRouteTests(baseline.RouteTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.source=(ROOT/'lite/sentinel.lua').read_text()
        # Native function bodies are preserved, but sparse numeric keys replace the full array.
        cls.native_bodies={}
        for m in re.finditer(r'^\[(\d+)\] = function',cls.source,re.M):
            end=re.search(r'^\[\d+\] = function|^}\nlocal function __entry',cls.source[m.end():],re.M)
            if end:
                text=cls.source[m.start():m.end()+end.start()]
                cls.native_bodies[int(m[1])]=text[text.index('function'):].rstrip().removesuffix(',')

    def part(self,start,end):
        if start.lstrip().startswith('function('):
            for text in self.native_bodies.values():
                if text.startswith(start.strip()): return text
        if start=='        local bladePrefs={':
            start='        local liteEssentials={'
        return super().part(start,end)

for name in EXCLUDED:
    setattr(LiteRouteTests,name,None)

class LiteSpecificTests(unittest.TestCase):
    run_luau=baseline.RouteTests.run_luau

    @classmethod
    def setUpClass(cls):
        cls.luau=os.environ.get('LUAU_BIN')
        cls.source=(ROOT/'lite/sentinel.lua').read_text()
        cls.full=(ROOT/'sentinel.lua').read_text()
        cls.manifest=json.loads((ROOT/'lite/manifest.json').read_text())

    def test_route_rot_and_shared_engines_are_copied_exactly(self):
        sys.path.insert(0,str(ROOT/'tools'))
        from build_lite import section
        core=section(self.full,'__modules.m356b75b2d82b = function()','    loadstring(')
        positions=list(re.finditer(r'^    local (fn\d+) = function\(\)',core,re.M))
        for i,m in enumerate(positions):
            body=core[m.start():positions[i+1].start() if i+1<len(positions) else len(core)]
            name=re.search(r'^    tbl44\.(\w+) = function\(\)',body,re.M)[1]
            if name in self.manifest['protected_modules']:
                self.assertIn(body,self.source,name)
                self.assertEqual(hashlib.sha256(body.encode()).hexdigest(),self.manifest['protected_modules'][name])
        self.assertEqual(self.manifest['source_sha256'],hashlib.sha256(self.full.encode()).hexdigest())

    def test_lite_dependency_closure_and_required_operational_controls(self):
        body=self.source[self.source.index('local function __entry(a1163)'):]
        available=set(re.findall(r'^    tbl44\.(\w+) = function',body,re.M))
        self.assertLessEqual(set(re.findall(r'tbl44\.(\w+)\(',body)),available)
        controls=set(re.findall(r':Add(?:Toggle|Slider|Input|Dropdown|KeyPicker)\(\s*"([^"\n]+)"',body))
        required={'NoKillBricks','NoFall','NoOrderlyBarriers','NoMobTrigger','AutoBard','AutoDialogue','AntiAfk',
            'AutoIngredient','AutoTrinket','AutoBag','BagRange','BlatantMode','RiskyMode','PersistentConfigs',
            'ExecuteOnServerhop','MenuKeybind','UnloadKeybind','ServerAllies','RotAlts','RotProximity',
            'RotSupplierResume','ProgKheiProximity','ProgGoToKhei','ProgStartPhase','BladeShrCount',
            'ProgStayInServer','ProgKheiStayInServer','ProgKheiSkipIllusionist','ProgSkipIllusionist'}
        self.assertLessEqual(required,controls)
        for key in ['bladeAddServerAllies','getRogueName','isModerator','moderatorInfo','flagModerator',
                    'onModeratorFlagged','fireFall','mana','holdGuards','autoBardSetup','identifyIngredient']:
            self.assertRegex(body,r'\.State\.'+key+r'\s*=')
        declared={int(x) for x in re.findall(r'^\[(\d+)\] = function',self.source,re.M)}
        self.assertEqual({int(x) for x in re.findall(r'__NATIVE\[(\d+)\]',body)},declared)

    def test_alternative_loader_resume_and_preferences_are_separate(self):
        loader=(ROOT/'lite/loader.lua').read_text()
        self.assertIn('/main/blade23/lite/sentinel.lua',loader)
        self.assertIn('/main/blade23/lite/loader.lua',self.source)
        self.assertNotIn('/main/blade23/loader.lua',self.source)
        self.assertIn('SaveManager:SetFolder("sentinel/blade23_lite")',self.source)
        self.assertIn('blade23_lite_settings_',self.source)
        self.assertIn('local legacyPrefs="sentinel/.cache/blade23_settings_',self.source)
        self.assertIn('args[1]="blade23_lite:"',self.source)
        self.assertIn('SaveManager:WriteConfig(bladePrefs.file,',self.source)
        self.assertNotIn('WriteConfig(legacyPrefs,',self.source)
        self.assertIn('Toggles16.AntiAfk:SetValue(true)',self.source)

    def test_unused_background_renderers_and_diagnostics_are_absent(self):
        for token in ['CreateChatLog','CreateMacroCreator','CreatePathEditor','CreateAutoBlockBuilder',
                      'CreatePlayerList','menuMasks','cleardrawcache','getreg_','getconnections_3',
                      'GetTotalMemoryUsageMb','blade23_ram_diagnostic','__bootSession.report']:
            self.assertNotIn(token,self.source)
        self.assertLess(len(self.source.encode()),len(self.full.encode())*.35)
        self.assertEqual(self.manifest['lite_bytes'],len(self.source.encode()))
        self.assertEqual(self.manifest['output_sha256'],hashlib.sha256(self.source.encode()).hexdigest())

    def test_performance_changes_only_on_events_and_restores_on_unload(self):
        code=(ROOT/'lite/parts/performance.lua').read_text()
        self.run_luau(r'''
local controls={};local cleanup={};local callbacks={};local frames=0;local renders={};local caps={};local deferred
local rendering={QualityLevel="original"};local settings=function() return {Rendering=rendering} end
local Enum={QualityLevel={Level01="low"}}
local setfpscap=function(n) table.insert(caps,n) end;local getfpscap=function() return 144 end
local function event(key) return {Connect=function(_,fn) callbacks[key]=fn;return {Disconnect=function() end} end} end
local aResult38={RunService={Set3dRenderingEnabled=function(_,v) table.insert(renders,v) end},UserInputService={WindowFocused=event("in"),WindowFocusReleased=event("out")}}
local Library23={Options={},Toggles={}}
local box={AddLabel=function() end}
function box:AddToggle(k,info)
 local c={Value=info.Default};function c:SetValue(v) self.Value=v;info.Callback() end
 Library23.Toggles[k]=c
end
function box:AddSlider(k,info)
 local c={Value=info.Default};function c:SetValue(v) self.Value=v;info.Callback() end
 Library23.Options[k]=c
end
local Settings={AddLeftGroupbox=function() return box end}
local a11542={Maid={Give=function(_,v) if type(v)=="function" then table.insert(cleanup,v) end end}}
local task={defer=function(fn) deferred=fn end}
'''+code+r'''
deferred();assert(caps[#caps]==20 and renders[#renders] and rendering.QualityLevel=="low")
callbacks.out();assert(caps[#caps]==15 and not renders[#renders])
local count=#caps;callbacks.out();assert(#caps==count,"no repeated writes without a change")
Library23.Options.LiteBackgroundFps:SetValue(30);assert(caps[#caps]==30)
Library23.Toggles.LiteHideBackground:SetValue(false);assert(renders[#renders])
callbacks["in"]();assert(caps[#caps]==20)
Library23.Toggles.LiteThrottle:SetValue(false);assert(caps[#caps]==144 and renders[#renders] and rendering.QualityLevel=="original")
Library23.Toggles.LiteThrottle:SetValue(true)
Library23.Unloaded=true;for _,fn in cleanup do fn() end
assert(caps[#caps]==144 and renders[#renders] and rendering.QualityLevel=="original")
count=#caps;callbacks.out();assert(#caps==count,"late focus events cannot reapply after Unload")
''')

    def test_anti_afk_hooks_restore_when_disabled_and_unloaded(self):
        a=self.source.index('        addLeftGroupboxResult17:AddToggle("AntiAfk"')
        b=self.source.index('        local v2436',a)
        code=self.source[a:b]
        self.run_luau(r'''
local disabled=0;local enabled=0;local cleanup
local getconnections=function() return {{Disable=function() disabled+=1 end,Enable=function() enabled+=1 end}} end
local LocalPlayer33={Idled={}};local Toggles16={};local Library17={Notify=function() error("supported executor") end}
local addLeftGroupboxResult17={AddToggle=function(_,key,info)
 local c={Value=info.Default};function c:SetValue(value) self.Value=value;info.Callback(value) end
 Toggles16[key]=c
end}
local a11260={Maid={Give=function(_,fn) cleanup=fn end}}
'''+code+r'''
assert(Toggles16.AntiAfk.Value and disabled==1)
Toggles16.AntiAfk:SetValue(false);assert(enabled==1)
Toggles16.AntiAfk:SetValue(true);assert(disabled==2)
cleanup();assert(enabled==2)
''')

    def test_build_is_reproducible_and_does_not_change_full_edition(self):
        if not AST: self.skipTest('Set LUAU_AST for a reproducible build check')
        before=(ROOT/'lite/sentinel.lua').read_bytes()
        full=(ROOT/'sentinel.lua').read_bytes()
        loader=(ROOT/'loader.lua').read_bytes()
        p=subprocess.run([sys.executable,str(ROOT/'tools/build_lite.py'),'--ast',AST],capture_output=True,text=True,timeout=45)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(before,(ROOT/'lite/sentinel.lua').read_bytes())
        self.assertEqual(full,(ROOT/'sentinel.lua').read_bytes())
        self.assertEqual(loader,(ROOT/'loader.lua').read_bytes())

    def test_complete_settings_initialization_and_real_save_load_autoload(self):
        save=re.search(r'save = \[=\[(.*?)\]=\]',self.source,re.S)[1]
        start=self.source.index('    local fn97 = function()')
        factory=self.source[start:self.source.index('    loadstring(',start)]
        self.run_luau(r'''
local function clone(x) if type(x)~="table" then return x end;local t={};for k,v in x do t[k]=clone(v) end;return t end
local function encode(x)
 if type(x)~="table" then return tostring(x) end
 local keys={};for k in x do table.insert(keys,k) end;table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
 local out={};for _,k in keys do table.insert(out,tostring(k)..":"..encode(x[k])) end;return "{"..table.concat(out,"|").."}"
end
local disk={};local jsons={};local tasks={};local hooks={};local folders={}
local http={JSONEncode=function(_,data) local s=encode(data);jsons[s]=clone(data);return s end,JSONDecode=function(_,s) assert(jsons[s],"invalid JSON");return clone(jsons[s]) end}
local isfile=function(p) return disk[p]~=nil end;local readfile=function(p) return disk[p] end
local writefile=function(p,s) disk[p]=s end;local delfile=function(p) disk[p]=nil end
local makefolder=function(p) folders[p]=true end;local isfolder=function(p) return folders[p]==true end
local listfiles=function(p) local out={};for k in disk do if k:sub(1,#p+1)==p.."/" then table.insert(out,k) end end;return out end
local task={defer=function(fn) table.insert(tasks,fn) end,spawn=function(fn) table.insert(tasks,fn) end,wait=function() end}
local function drain() while #tasks>0 do local fn=table.remove(tasks,1);fn() end end
local function event(name) return {Connect=function(_,fn) hooks[name]=fn;return {Disconnect=function() end} end} end
local player={UserId=123};local players={LocalPlayer=player,GetPlayers=function() return {player} end,PlayerAdded=event("added"),PlayerRemoving=event("removed")}
local services={Players=players,HttpService=http,RunService={Heartbeat=event("beat"),Set3dRenderingEnabled=function() end},
 UserInputService={WindowFocused=event("focus"),WindowFocusReleased=event("blur")},ReplicatedStorage={FindFirstChild=function() end}}
local game={GetService=function(_,key) return assert(services[key],key) end}
local Enum={QualityLevel={Level01=1}};local rendering={QualityLevel=3};local settings=function() return {Rendering=rendering} end
local setfpscap=function() end;local getfpscap=function() return 60 end
local cleanup={};local function maid() return {Give=function(_,fn) table.insert(cleanup,fn) end} end
local mem={};local resume={setupResume=function() end,teardown=function() end}
local store={get=function(k) return mem[k] end,set=function(k,v) mem[k]=v end,remove=function(k) mem[k]=nil end,
 getJSON=function(k) return mem[k] end,setJSON=function(k,v) mem[k]=v end}
local lib={Options={},Toggles={},SetKeybindFrameVisible=function() end,Notify=function() end,Unload=function() end}
local tab={};local function control(kind,key,info,inside)
 local c={Type=kind,Value=info.Default,Values=info.Values or {},Multi=info.Multi,Mode=info.Mode or "Press"}
 if c.Value==nil and kind=="Input" then c.Value="" end
 c.ConfigInstance={IsDescendantOf=function(_,container) return inside and container==tab end}
 function c:SetValue(v)
  if kind=="Slider" then v=tonumber(v) end
  if kind=="KeyPicker" then
   if type(v)=="table" then self.Value=v[1];self.Mode=v[2];self.Modifiers=v[3] else self.Value=v end
   if info.ChangedCallback then info.ChangedCallback(self.Value,self.Value) end
  else self.Value=v;if info.Callback then info.Callback(v) end end
 end
 function c:SetValues(v) self.Values=v end
 function c:SetDisabled(v) self.Disabled=v end
 if kind=="Toggle" then lib.Toggles[key]=c else lib.Options[key]=c end
 return c
end
local box={AddDivider=function() end,AddButton=function() end}
for _,kind in {"Toggle","Input","Dropdown","Slider"} do box["Add"..kind]=function(_,key,info) return control(kind,key,info,false) end end
function box:AddLabel() return {AddKeyPicker=function(_,key,info) return control("KeyPicker",key,info,false) end,SetText=function() end} end
local settingsTab={AddLeftGroupbox=function() return box end,AddRightGroupbox=function() return box end}
control("Toggle","AntiAfk",{Default=true},false)
control("Dropdown","BladeFarm",{Default="Auto",Values={"Auto","Shriekers"}},true)
control("Dropdown","RotAlts",{Default={},Values={},Multi=true},true)
control("Dropdown","ServerAllies",{Default={},Values={},Multi=true},true)
control("Toggle","RotBotEnabled",{Default=false},true)
control("Toggle","RotReceiverQueue",{Default=false},true)
local theme={BuiltInThemes={},SetLibrary=function() end,SetFolder=function() end,ApplyToGroupbox=function() end}
local modules={D=resume,q=store,a=services,e={},x={setConfig=function() end},d={new=maid},
 c={CACHE="sentinel/.cache",KEYBINDS="sentinel/.cache/blade23_lite_keybinds.json",ensureFor=function() end}}
local tbl44={cache={}};for key,value in modules do tbl44[key]=function() return value end end
local legacy="sentinel/.cache/blade23_settings_123.json"
disk[legacy]=http:JSONEncode({version=1,objects={{type="Dropdown",idx="BladeFarm",value="Shriekers"},{type="Dropdown",idx="RotAlts",value={Offline=true},multi=true}}})
local original=disk[legacy]
local save=(function()
'''+save+r'''
end)()
local state={blatant={},risky={}}
local context={Library=lib,SaveManager=save,ThemeManager=theme,State=state,Maid=maid(),Tabs={Settings=settingsTab,Blade23={Container=tab}}}
'''+factory+r'''
tbl44.af()(context);drain()
assert(state.notificationsReady and state.bladeProfileLoaded and not state.loadingConfig)
assert(lib.Options.BladeFarm.Value=="Shriekers" and lib.Options.RotAlts.Value.Offline,"import the full edition preferences once")
assert(lib.Toggles.AntiAfk.Value and lib.Toggles.LiteThrottle.Value)
lib.Options.LiteBackgroundFps:SetValue(25);lib.Options.ServerAllies:SetValue({["Friend [42]"]=true})
assert(save:Save("lite-test"));assert(disk["sentinel/blade23_lite/configs/lite-test.json"])
local auto=assert(save:ReadConfig("sentinel/.cache/blade23_lite_settings_123.json",1));local byId={}
for _,row in auto.objects do byId[row.idx]=row end
assert(byId.AntiAfk.value and byId.LiteBackgroundFps.value=="25" and byId.ServerAllies.value["Friend [42]"])
assert(not byId.RotBotEnabled and not byId.RotReceiverQueue,"operational state must not auto-start a worker")
lib.Options.LiteBackgroundFps:SetValue(15);lib.Toggles.AntiAfk:SetValue(false);lib.Options.RotAlts:SetValue({})
assert(save:Load("lite-test"));assert(lib.Options.LiteBackgroundFps.Value==25 and lib.Toggles.AntiAfk.Value and lib.Options.RotAlts.Value.Offline)
assert(save:SaveAutoloadConfig("lite-test"));lib.Options.LiteBackgroundFps:SetValue(17);save:LoadAutoloadConfig()
assert(lib.Options.LiteBackgroundFps.Value==25 and save:GetAutoloadConfig()=="lite-test")
assert(disk[legacy]==original,"Lite must not overwrite the full edition preferences")
lib.Options.LiteBackgroundFps:SetValue(23);assert(resume.beforeResume())
assert(state.flushBladeSettings());lib.Unloaded=true
for _,fn in cleanup do if type(fn)=="function" then fn() end end
assert(state.flushBladeSettings==nil and resume.beforeResume==nil)
''')

if __name__=='__main__': unittest.main()
