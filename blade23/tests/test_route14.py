"""Regression checks for the attached Blade route; behavioral tests run real Luau functions.
Run with LUAU_BIN=/path/to/luau python -m unittest discover -s blade23/tests.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VEC = r'''
local Vec={}
Vec.__index=function(self,key)
 if key=="Magnitude" then return math.sqrt(self.X*self.X+self.Y*self.Y+self.Z*self.Z) end
 if key=="Unit" then return self/self.Magnitude end
 return Vec[key]
end
local Vector3={new=function(x,y,z) return setmetatable({X=x,Y=y,Z=z},Vec) end}
Vec.__add=function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
Vec.__sub=function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
Vec.__mul=function(a,b) return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
Vec.__div=function(a,b) return Vector3.new(a.X/b,a.Y/b,a.Z/b) end
function Vec:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
'''

class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'sentinel.lua').read_text()
        cls.luau = os.environ.get('LUAU_BIN') or shutil.which('luau')

    def part(self, start, end):
        a = self.source.index(start)
        return self.source[a:self.source.index(end, a)]

    def run_luau(self, body):
        if not self.luau:
            self.skipTest('Set LUAU_BIN to run behavioral Luau checks')
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / 'check.luau'
            script.write_text(body)
            result = subprocess.run([self.luau, str(script)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_exact_attached_points_and_gui(self):
        expected = json.loads((ROOT / 'routes' / 'Blade.json').read_text())['points']
        route = self.part('__L3.bladeRoute={', 'a1723.State.bladeRoutePoints=')
        positions = re.findall(r'Vector3.new\(([^)]+)\)', route)
        self.assertEqual(len(positions), 14)
        for actual, point in zip(positions, expected):
            self.assertEqual(tuple(map(float, actual.split(','))), tuple(point[k] for k in ('x','y','z')))
        self.assertIn('blade23Tabbox:AddTab("Filas")', self.source)
        self.assertIn('blade23Tabbox:AddTab("Rot")', self.source)
        self.assertNotIn('blade23Tabbox:AddTab("Cela XP")', self.source)
        self.assertIn('__L3.hiddenSetup:AddDropdown("ProgRoute"', self.source)
        self.assertIn('__L3.hiddenSetup:AddSlider("BladeDamageGoal"', self.source)
        self.assertIn('netUI.box:SetVisible(false)', self.source)
        self.assertIn('tbl358.localOnly=true', self.source)
        self.assertIn('__L3.bladePrepareLegacy=function()', self.source)
        self.assertIn('__L3.bladeXPShriekersLegacy=function()', self.source)

    def test_supply_and_xp_fifo(self):
        supply = self.part('__L3.bladeSupplyAssignments=function', '__L3.bladePrepare=function')
        xp = self.part('__L3.bladeAssignments=function', '__L3.bladeWorkerPath=')
        self.run_luau('local __L3={}\n'+supply+xp+r'''
local roster={{userId=2,name="B",stage="B1_PREP",supplyJoined=2},{userId=1,name="A",stage="B1_PREP",supplyJoined=1}}
assert(__L3.bladeSupplyAssignments(roster).userId==1)
roster[1].supplyState="running";assert(__L3.bladeSupplyAssignments(roster).userId==2)
roster[1].stage="B1_SWORD";assert(__L3.bladeSupplyAssignments(roster).userId==2,"hold while leaving P4")
roster[1].supplyState=nil;assert(__L3.bladeSupplyAssignments(roster).userId==1)
local r={{userId=1,joined=1,stage="B1_XP",preference="Automatic",shrAvailable=true},
 {userId=2,joined=2,stage="B1_XP",preference="Automatic",shrAvailable=true},
 {userId=3,joined=3,stage="B1_XP",preference="Shriekers",shrAvailable=true}}
local a=__L3.bladeAssignments(r);assert(a[1]=="shriekers" and a[2]=="scrooms" and not a[3])
r[1].farmState="running";r[1].slot="shriekers";r[1].stage="B1_EXIT"
for _,e in r do e.shrAvailable=false end
a=__L3.bladeAssignments(r);assert(a[1]=="shriekers" and a[2]=="scrooms" and not a[3])
''')

    def test_collection_path_and_requirements(self):
        prepare=self.part('__L3.bladePrepare=function()', '__L3.bladeBuySword=function()')
        requirements=self.part('__L3.bladeSupplyRequirements=function()', '__L3.bladeCollect=function()')
        self.run_luau(r'''
local __L3={bladeWorker={},bladeRoute={[4]={}}}
local near=function() return true end
local tbl303={true};local tbl308={{}}
local LocalPlayer21={UserId=1,Character={}}
local DateTime={now=function() return {UnixTimestampMillis=1} end}
local task={wait=function() end}
local method="Rots";local silver=0;local owner=2;local inventory={};local moves={};local bags={};local phase;local status
__L3.bladeValue=function(_,d) return method end
__L3.bladeSilverGoal=function() return method=="Rots" and 100 or 660 end
__L3.bladeWorkerTick=function() __L3.bladeSupplyOwner=owner end
__L3.bladeMovePoint=function(p) table.insert(moves,p);return true end
__L3.bladeBagPickup=function(v) table.insert(bags,v) end
__L3.bladeCollect=function() end
__L3.bladeCount=function(n) return inventory[n] or 0 end
__L3.bladePhase=function(p) phase=p end
__L3.bladeStatus=function(t) status=t end
local getServerValue=function() return silver end
local fn542=function() end
'''+requirements+prepare+r'''
__L3.bladePrepare();assert(table.concat(moves,",")=="1,2,3" and not phase and bags[#bags]==false)
owner=1;__L3.bladePrepare();assert(moves[#moves]==4 and bags[#bags]==true and not phase)
silver=99;__L3.bladePrepare();assert(not phase)
silver=100;__L3.bladePrepare();assert(phase=="B1_SWORD" and moves[#moves]==5 and bags[#bags]==false)
method="Quests";tbl308[1]={};__L3.bladeAtSupplyWait=false;__L3.bladeWorker.supplyState=nil;phase=nil;silver=660
__L3.bladePrepare();assert(not phase and status:find("Tespian",1,true))
inventory={['Liquid Wisdom']=1,['Health Potion']=1,['Ice Protection']=1,['Tespian Elixir']=5}
__L3.bladePrepare();assert(phase=="B1_SWORD")
''')

    def test_shrieker_gate_healing_sword_then_fists(self):
        farm=self.part('__L3.bladeXPShriekers=function()', '__L3.bladeXP=function()')
        self.run_luau(r'''
local __L3={bladeFarmAssigned="shriekers"}
local tbl303={true};local tbl308={{}}
local clock=0;local healedAt
local os={clock=function() return clock end}
local LocalPlayer21={Character={FindFirstChildOfClass=function() return {UnequipTools=function() end} end}}
local a1723={State={mana={decharge=function() end}}}
local live={};local v966={FindFirstChild=function() return live end}
local listeners={};local hum={Health=192,MaxHealth=200}
local mob={hum=hum,model={Parent=live},root={Position={}}}
local function setHP(hp) hum.Health=hp;for _,entry in listeners do if entry.on then entry.fn(hp) end end end
hum.HealthChanged={Connect=function(_,fn) local e={on=true,fn=fn};table.insert(listeners,e);return {Disconnect=function() e.on=false end} end}
local entered=false;local combat=false
local task={wait=function(t)
 assert(not combat,"HP-full gate or stability wait must not run during attacks")
 clock+=t or 0.1
 if not healedAt and clock>=1 then healedAt=clock;setHP(200) end
end}
__L3.bladeValue=function(n,d) return n=="BladeShrCount" and 1 or d end
__L3.bladeCellLoad=function() return {} end
__L3.bladeCellBounds=function() return {},{} end
__L3.bladeShriekers=function() return {mob} end
__L3.bladeStanding=function() return clock>=7 end
__L3.bladeMovePoint=function(n)
 assert(n==9 and clock-healedAt>=5 and __L3.bladeStanding());entered=true;return true
end
__L3.bladeStatus=function() end
__L3.bladeInCell=function() return true end
__L3.fn610=function() end
local fn580=function() assert(entered) end
local fn542=function() end
local swordCalls,fistCalls=0,0
__L3.bladeAttack=function(done)
 combat=true;__L3.bladeCounting=true
 if __L3.bladeCombatMode=="sword" then
  swordCalls+=1
  for i=1,838 do setHP(200);setHP(192) end
  assert(tbl308[1].bladeDamage==6704 and (tbl308[1].bladeFistDamage or 0)==0)
 else
  fistCalls+=1;assert(tbl308[1].bladeDamage==6704)
  for i=1,100 do setHP(200);setHP(192) end
 end
 assert(done());combat=false
end
'''+farm+r'''
assert(__L3.bladeXPShriekers())
assert(swordCalls==1 and fistCalls==1 and tbl308[1].bladeDamage==6704 and tbl308[1].bladeFistDamage==800)
assert(not __L3.bladeCounting and not __L3.bladeCombatMode)
for _,e in listeners do assert(not e.on,"HP listener leak") end
-- Resumed sword-complete runs only need remaining fist XP, retaining the sword count.
setHP(200);tbl308[1]={bladeDamage=6704,bladeFistDamage=400};listeners={};swordCalls=0;fistCalls=0
__L3.bladeAttack=function(done)
 combat=true;assert(__L3.bladeCombatMode=="fist");__L3.bladeCounting=true;fistCalls+=1
 for i=1,50 do setHP(200);setHP(192) end
 assert(done());combat=false
end
assert(__L3.bladeXPShriekers());assert(tbl308[1].bladeFistDamage==800 and swordCalls==0 and fistCalls==1)
''')

    def test_mana_punch_unequips_and_requires_charge(self):
        punch=self.part('__L3.bladeManaPunch=function', '__L3.bladeXPShriekers=function')
        self.run_luau(r'''
local __L3={bladeStatus=function() end}
local tool={};local mana={Value=10};local hum={UnequipTools=function() tool=nil end}
local character={FindFirstChildOfClass=function() return hum end,FindFirstChild=function() return mana end,FindFirstChildWhichIsA=function() return tool end}
local LocalPlayer21={Character=character};local charges,attacks=0,0
local a1723={State={mana={chargeUntil=function(target,running) assert(target==95);charges+=1;mana.Value=95 end}}}
local fn577=function() assert(not tool and mana.Value>=90);attacks+=1 end
'''+punch+r'''
assert(__L3.bladeManaPunch(function() return true end));assert(charges==1 and attacks==1)
mana.Value=10;a1723.State.mana.chargeUntil=function() end
assert(not __L3.bladeManaPunch(function() return true end));assert(attacks==1)
''')

    def test_p10_danger_and_p14_turn_order(self):
        exit_xp=self.part('__L3.bladeExitXP=function()', '__L3.bladeUseTespian=function()')
        orderly=self.part('__L3.bladeOrderly=function()', '__L3.bladeQuestReady=function')
        self.run_luau(r'''
local __L3={bladeStatus=function() end}
local tbl303={true};local tbl308={{bladeXPMethod="shriekers"}}
local danger=true;local turn=false;local complete=false;local method="Rots";local phase;local moves={};local binds={}
local LocalPlayer21={Character={}}
local fn537=function() return danger end
local fn542=function() end
local fn580=function() end
local near=function() return true end
local task={wait=function() end}
__L3.bladeMovePoint=function(n) table.insert(moves,n);return true end
__L3.bladeRelease=function() end
__L3.bladeStanding=function() return true end
__L3.bladePhase=function(p) phase=p end
__L3.bladeValue=function() return method end
__L3.bladeUseTespian=function() return true end
__L3.setInn=function(name) table.insert(binds,name);return true end
__L3.bladeRoute={[14]={}}
local joined=0
local a1723={State={joinRotReceiverQueue=function() joined+=1;return true end,
 rotReceiverQueueComplete=function() return complete end,rotReceiverHasTurn=function() return turn end}}
'''+exit_xp+orderly+r'''
__L3.bladeExitXP();assert(not phase and #moves==1 and moves[1]==10)
danger=false;__L3.bladeExitXP();assert(phase=="B2_ORDERLY" and #moves==1)
phase=nil;__L3.bladeOrderly();assert(table.concat(moves,",")=="10,11,12,13" and binds[1]=="Renova" and not a1723.State.bladeReceiverAtP14)
assert(joined==1 and not phase)
turn=true;__L3.bladeOrderly();assert(moves[#moves]==14 and a1723.State.bladeReceiverAtP14)
__L3.bladeOrderly();assert(#moves==5 and joined==1,"do not teleport an active walking carrier back to P14")
complete=true;__L3.bladeOrderly();assert(phase=="B3_TRAIN" and not a1723.State.bladeReceiverAtP14)
method="Quests";phase=nil;tbl308[1]={};moves={};binds={}
__L3.bladeOrderly();assert(phase=="B2_QUESTS1" and #moves==0 and #binds==0)
''')

    def test_down_waits_before_p9_and_scroom_branch_skips_shrine(self):
        move=self.part('__L3.bladeMovePoint=function', '__L3.bladeBagPickup=function')
        self.run_luau(r'''local __L3={bladeRoute={[9]="P9"},bladeWorker={},bladeStatus=function() end}
local tbl303={true};local standing=false;local waits=0;local moved=0
__L3.bladeStanding=function() return standing end
local task={wait=function() waits+=1;assert(moved==0);standing=true end}
local near=function() return true end
local fn580=function() assert(standing);moved+=1;return true end
'''+move+r'''assert(__L3.bladeMovePoint(9,true) and waits==1 and moved==1)''')
        xp=self.part('__L3.bladeXP=function()', '__L3.bladeExitXP=function()')
        self.run_luau(r'''local __L3={bladeWorker={}}
local tbl303={true};local tbl308={{}}
local LocalPlayer21={Character={}};local DateTime={now=function() return {UnixTimestampMillis=1} end}
local task={wait=function() end};local fn542=function() end
local pref="Automatic";local slot=nil;local moves={};local phase
__L3.bladeValue=function(_,d) return pref end
__L3.bladeWorkerTick=function() __L3.bladeFarmAssigned=slot end
__L3.bladeMovePoint=function(n) table.insert(moves,n);return true end
__L3.bladeStatus=function() end
__L3.bladePhase=function(p) phase=p;tbl308[1].phase=p end
__L3.bladeRelease=function() end
__L3.bladeScroomFarm=function() tbl308[1].phase="P6" end
'''+xp+r'''
__L3.bladeXP();assert(table.concat(moves,",")=="6,7,8" and not phase)
__L3.bladeXP();assert(#moves==3,"do not repeat approach while waiting")
pref="Zombie Scrooms";slot="scrooms";moves={};tbl308[1]={};__L3.bladeShrApproachCharacter=nil
__L3.bladeXP();assert(#moves==0 and phase=="B1_EXIT" and tbl308[1].bladeXPMethod=="scrooms")
''')

    def test_suppliers_require_present_free_receiver_at_p14(self):
        ready=self.part('rotSupplier.masterReady=function', 'rotSupplier.saveSettings=function')
        self.run_luau(VEC+r'''
local now=10;local os={clock=function() return now end}
local rotSupplier={seen=10,receiverPoint=Vector3.new(-2076.978759765625,615.2067260742188,-759.8974609375)}
local position=rotSupplier.receiverPoint;local health=100;local grabbing=false;local knocked=false
local character={FindFirstChild=function(_,n)
 if n=="HumanoidRootPart" then return {Position=position} end
 if n=="Grabbing" then return grabbing and {} or nil end
end,FindFirstChildOfClass=function() return {Health=health} end}
local player={UserId=1,Character=character}
local getResult26={GetPlayerByUserId=function(_,id) return id==1 and player end}
local v1345={HasTag=function(_,_,tag) return tag=="Knocked" and knocked end}
'''+ready+r'''
assert(not rotSupplier.masterReady())
rotSupplier.owner={userId=1,ready=true,state="waiting",progress=0}
assert(rotSupplier.masterReady()==player)
position=Vector3.new(-2095.048095703125,620.0502319335938,-793.3778686523438);assert(not rotSupplier.masterReady())
position=rotSupplier.receiverPoint;grabbing=true;assert(not rotSupplier.masterReady());grabbing=false
knocked=true;assert(not rotSupplier.masterReady());knocked=false
rotSupplier.owner.progress=16;assert(not rotSupplier.masterReady());rotSupplier.owner.progress=15
now=15;assert(not rotSupplier.masterReady())
''')

    def test_wipe_happens_before_rejoin(self):
        flow=self.part('        local fn694 = function()', '        local fn695 = function()')
        self.run_luau(r'''
local tbl365={true};local events={};local lives=0
local a1849={State={getServerValue=function() return lives end}}
local fn690=function() return "ferryman" end
local fn691=function() table.insert(events,"wipe");lives=3 end
local fn688=function() assert(lives==3);table.insert(events,"rejoin");return true end
local fn686=function() return false end
local task={wait=function() end}
'''+flow+r'''
fn694();assert(table.concat(events,",")=="wipe,rejoin")
''')

if __name__ == '__main__':
    unittest.main()
