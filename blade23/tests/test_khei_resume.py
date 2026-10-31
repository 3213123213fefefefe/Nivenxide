import os,re,unittest
from pathlib import Path
import test_route14 as baseline
ROOT=Path(__file__).resolve().parents[1]
class KheiResumeTests(unittest.TestCase):
    run_luau=baseline.RouteTests.run_luau
    @classmethod
    def setUpClass(cls):
        cls.luau=os.getenv('LUAU_BIN')
    def test_play_observes_manual_entry_without_fixed_waits(self):
        for path in ['sentinel.lua','lite/sentinel.lua']:
            s=(ROOT/path).read_text();a=s.index('        __L3.fn641 = function()');code=s[a:s.index('        -- Blade/Sigil',a)]
            self.run_luau('''
local clock=0;local os={clock=function() return clock end};local menu=true;local clicks=0
local LocalPlayer21={Character={FindFirstChild=function() return {} end}}
local tbl303={true};local a1723={State={}};local __L3={startMenu=function() return menu end,clickPlay=function() clicks+=1 end,progStatusLabel={SetText=function() end}}
local task={wait=function(dt) clock+=dt;menu=nil end,spawn=function() error("unexpected failure") end}
local sResult7={awaitPlaced=function(active) assert(active()) end}
'''+code+'''
__L3.fn641();assert(clicks==1 and clock==0.2,"a menu with an old root still needs Play; manual entry ends the wait immediately")
clock=0;clicks=0;__L3.fn641();assert(clock==0 and clicks==0,"already playing must not wait for StartMenu to appear")
''')
    def test_selectable_khei_steps_preserve_confirmed_sacrifice(self):
        for path in ['sentinel.lua','lite/sentinel.lua']:
            s=(ROOT/path).read_text();a=s.index('        __L3.bladeStartStages=');code=s[a:s.index('        __L3.bladeCount=',a)]
            self.run_luau('''
local __L3={};local game={PlaceId=2};local num274=2;local tbl303={false};local tbl308={};local save={spireGiven=true}
local fn541=function() return save end;local fn542=function() end;local qResult3={remove=function() end}
'''+code+'''
for label,step in {["Khei - marcar spawn"]="inn",["Khei - Spire"]="spire",["Khei - perder 1 vida (Purity)"]="sacrifice",["Khei - Valter"]="valter"} do
 assert(__L3.bladeSelectStart(label));assert(save.phase=="KHEI" and save.kheiStep==step and save.spireGiven)
end
''')
    def test_transport_arrival_clears_resume_intent_without_starting_worker(self):
        for path in ['sentinel.lua','lite/sentinel.lua']:
            s=(ROOT/path).read_text();a=s.index('          -- Handoff is transport only');code=s[a:s.index('          if qResult3.get("progression_active")',a)]
            self.run_luau('''
local mem={khei_run="true",khei_manual="true",progression_active="true"};local qResult3={get=function(k) return mem[k] end,remove=function(k) mem[k]=nil end}
local game={PlaceId=2};local num274=2;local __L3={kheiManualRequested=true,progStatusLabel={SetText=function() end}}
local fn531=function(active) assert(not active) end;local fn532=function(enabled) assert(enabled) end
local function arrive()
'''+code+'''
error("must stop at transport arrival")
end
arrive();assert(not next(mem) and not __L3.kheiManualRequested)
''')
