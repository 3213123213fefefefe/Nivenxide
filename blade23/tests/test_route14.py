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
__L3.bladePointReached=function() return true end
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
local __L3={bladeFarmAssigned="shriekers",bladeFullHP=function(h) return h.Health>=h.MaxHealth end}
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
 assert(n==9 and clock-healedAt>=3 and __L3.bladeStanding());entered=true;return true
end
__L3.bladeStatus=function() end
__L3.bladeInCell=function() return true end
__L3.bladeMobInCell=function() return true end
__L3.fn610=function() end
local fn580=function() assert(entered) end
local fn542=function() end
local swordCalls,fistCalls,unlockCalls=0,0,0
__L3.bladeAttack=function(done)
 combat=true;__L3.bladeCounting=true
 if __L3.bladeCombatMode=="sword" then
  swordCalls+=1
  for i=1,838 do setHP(200);setHP(192) end
  assert(tbl308[1].bladeDamage==6704 and (tbl308[1].bladeFistDamage or 0)==0)
 elseif __L3.bladeCombatMode=="unlock" then
  unlockCalls+=1
  for i=1,3 do
   __L3.bladeUnlockAwaiting=true;setHP(200);setHP(192);setHP(184)
   assert(tbl308[1].bladeUnlockHits==i,"multiple damaged mobs/deltas from one M1 must not count twice")
  end
  assert(tbl308[1].bladeFistDamage==0,"ordinary punches do not count toward charged damage")
 else
  fistCalls+=1;assert(tbl308[1].bladeDamage==6704)
  for i=1,38 do setHP(200);setHP(192) end
 end
 assert(done());combat=false
end
'''+farm+r'''
assert(__L3.bladeXPShriekers())
assert(swordCalls==1 and fistCalls==1 and unlockCalls==1 and tbl308[1].bladeUnlockHits==3 and tbl308[1].bladeDamage==6704 and tbl308[1].bladeFistDamage==304)
assert(not __L3.bladeCounting and not __L3.bladeCombatMode)
for _,e in listeners do assert(not e.on,"HP listener leak") end
-- Resumed sword-complete runs only need remaining fist XP, retaining the sword count.
setHP(200);tbl308[1]={bladeDamage=6704,bladeFistDamage=144};listeners={};swordCalls=0;fistCalls=0
__L3.bladeAttack=function(done)
 combat=true;assert(__L3.bladeCombatMode=="fist");__L3.bladeCounting=true;fistCalls+=1
 for i=1,20 do setHP(200);setHP(192) end
 assert(done());combat=false
end
assert(__L3.bladeXPShriekers());assert(tbl308[1].bladeFistDamage==304 and swordCalls==0 and fistCalls==1)
-- Interrupted unlock resumes from two confirmed ordinary hits instead of restarting from zero.
setHP(200);tbl308[1]={bladeDamage=6704,bladeFistDamage=0,bladeUnlockHits=2};listeners={}
local plainRemaining=0
__L3.bladeAttack=function(done)
 combat=true;__L3.bladeCounting=true
 if __L3.bladeCombatMode=="unlock" then
  plainRemaining+=1;__L3.bladeUnlockAwaiting=true;setHP(192)
  assert(tbl308[1].bladeUnlockHits==3)
 else
  assert(__L3.bladeCombatMode=="fist")
  for i=1,38 do setHP(200);setHP(192) end
 end
 assert(done());combat=false
end
assert(__L3.bladeXPShriekers() and plainRemaining==1)
''')

    def test_mana_punch_unequips_and_requires_charge(self):
        punch=self.part('__L3.bladeManaPunch=function', '__L3.bladeXPShriekers=function')
        self.run_luau(r'''
local __L3={bladeStatus=function() end}
local tool={};local mana={Value=10};local hum={UnequipTools=function() tool=nil end}
local character={FindFirstChildOfClass=function() return hum end,FindFirstChild=function(_,key) if key=="Mana" then return mana end end,FindFirstChildWhichIsA=function() return tool end}
local LocalPlayer21={Character=character};local charges,attacks=0,0
local tbl308={{bladeFistDamage=0}}
local fn576=function() return false end
local os={clock=function() return 0 end}
local task={wait=function() end}
local a1723={State={mana={chargeUntil=function(target,running) assert(target==95);charges+=1;mana.Value=95 end}}}
local fn577=function() assert(not tool);attacks+=1;mana.Value-=10 end
'''+punch+r'''
assert(__L3.bladeManaPunch(function() return true end));assert(charges==1 and attacks==4)
mana.Value=10;a1723.State.mana.chargeUntil=function() end
assert(not __L3.bladeManaPunch(function() return true end));assert(attacks==4)
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
__L3.bladePointReached=function() return true end
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
local LocalPlayer21={Character={}}
__L3.bladeWaitPoints={}
__L3.bladePointReached=function() return false end
local tbl303={true};local standing=false;local waits=0;local moved=0
__L3.bladeStanding=function() return standing end
local task={wait=function() waits+=1;assert(moved==0);standing=true end}
local near=function() return true end
local fn580=function() assert(standing);moved+=1;return true end
'''+move+r'''assert(__L3.bladeMovePoint(9,true) and waits==1 and moved==1)''')
        xp=self.part('__L3.bladeXP=function()', '__L3.bladeExitXP=function()')
        self.run_luau(r'''local __L3={bladeWorker={},bladeXPWaitStatus=function() return "waiting" end}
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

    def test_suppliers_detect_receiver_without_queue_record(self):
        ready=self.part('rotSupplier.masterReady=function', 'rotSupplier.saveSettings=function')
        self.run_luau(VEC+r'''
local now=10;local os={clock=function() return now end}
local rotSupplier={presenceRadius=6,receiverPoint=Vector3.new(-2076.978759765625,615.2067260742188,-759.8974609375)}
local LocalPlayer24={UserId=99};local position=rotSupplier.receiverPoint-Vector3.new(0,6,0)
local health=100;local grabbing=false;local knocked=false
local character={FindFirstChild=function(_,n)
 if n=="HumanoidRootPart" then return {Position=position} end
 if n=="Grabbing" then return grabbing and {} or nil end
end,FindFirstChildOfClass=function() return {Health=health} end}
local player={UserId=1,Character=character};local players={LocalPlayer24,player}
local getResult26={GetPlayers=function() return players end}
local v1345={HasTag=function(_,_,tag) return tag=="Knocked" and knocked end}
local channelResult={roster=function() return {} end}
'''+ready+r'''
assert(rotSupplier.owner==nil and rotSupplier.masterReady()==player,"presence must work without any queue or other-PC file")
position=Vector3.new(-2095.048095703125,620.0502319335938,-793.3778686523438);assert(not rotSupplier.masterReady())
position=rotSupplier.receiverPoint;grabbing=true;assert(not rotSupplier.masterReady());grabbing=false
knocked=true;assert(not rotSupplier.masterReady());knocked=false
health=0;assert(not rotSupplier.masterReady());health=100
position=rotSupplier.receiverPoint+Vector3.new(0,13,0);assert(not rotSupplier.masterReady())
position=rotSupplier.receiverPoint;assert(rotSupplier.masterReady(1)==player and not rotSupplier.masterReady(2))
-- A local supplier at the point must never become another supplier's Master.
now+=1;channelResult.roster=function() return {{userId=1,rotSupplier=true}} end
assert(not rotSupplier.masterReady())
now+=1;channelResult.roster=function() return {} end
assert(rotSupplier.masterReady()==player)
-- The standby point is outside the six-stud horizontal trigger.
position=Vector3.new(-2085.454589844,609.353881836,-754.801147461);assert(not rotSupplier.masterReady())
-- Ignore the local player's own character, even when no one else is present.
LocalPlayer24.Character=character;players={LocalPlayer24};position=rotSupplier.receiverPoint
assert(not rotSupplier.masterReady())
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

    def test_wait_points_land_and_do_not_refly_after_gravity(self):
        movement=self.part('__L3.bladeWaitPoints=', '__L3.bladeBagPickup=function')
        self.run_luau(VEC+r'''
Vector3.zero=Vector3.new(0,0,0)
local __L3={bladeRoute={[4]=Vector3.new(5,20,5)},bladeWorker={},bladeStatus=function() end,bladeStanding=function() return true end}
local tbl303={true};local LocalPlayer21={};local newResult61={attachLock=true}
local root={Position=Vector3.new(0,20,0),Anchored=true};local state
local hum={SetStateEnabled=function(_,n,v) assert(n==5 and v) end,ChangeState=function(_,s) state=s end}
local char={FindFirstChild=function() return root end,FindFirstChildOfClass=function() return hum end}
LocalPlayer21.Character=char
local Toggles8={};local disabled=0
for _,name in {"Flight","BetterFlight","Noclip"} do
 local toggle={Value=true};toggle.SetValue=function(_,value) assert(not value);toggle.Value=value;disabled+=1 end;Toggles8[name]=toggle
end
local clipped=0;local fn499=function(c) assert(c==char);clipped+=1 end
local cleared=0;local sResult7={clearVeil=function() cleared+=1 end}
local Enum={HumanoidStateType={GettingUp=7}}
local task={wait=function() end};local moves=0
local fn580=function(points) moves+=1;root.Position=points[1];return true end
local near=function(p,r) return (root.Position-p).Magnitude<=r end
'''+movement+r'''
assert(__L3.bladeMovePoint(4,true))
assert(moves==1 and disabled==3 and clipped==1 and cleared==1 and newResult61.attachLock==nil)
assert(not root.Anchored and root.AssemblyLinearVelocity==Vector3.zero and state==7)
root.Position=Vector3.new(5,2,5)
for i=1,1000 do assert(__L3.bladeMovePoint(4,true)) end
assert(moves==1 and clipped==1,"waiting on the floor must not lift the account every tick")
root.Position=Vector3.new(30,2,5);assert(__L3.bladeMovePoint(4,true) and moves==2)
LocalPlayer21.Character={FindFirstChild=function() return root end}
root.Position=Vector3.new(5,2,5);assert(not __L3.bladePointReached(4),"arrival belongs to the old character")
''')

    def test_purchase_retries_are_serial_throttled_and_no_position_hold(self):
        purchase=self.part('__L3.bladeBuySword=function()', '-- Exact XP cell:')
        self.run_luau(r'''
local now=0;local os={clock=function() return now end};local task={wait=function(t) now+=t end}
local __L3={bladeRoute={[5]={}},bladeStatus=function() end,bladeMovePoint=function() return true end}
local tbl303={true};local sword=false;local fn591=function() return sword end
local getServerValue=function() return 100 end;local fn534=function() end
local flags={};local fn536=function(value) table.insert(flags,value) end
local detector={};local merchant={IsA=function() return false end,FindFirstChildWhichIsA=function() return detector end}
local HResult={nearestNPC=function() return merchant,0 end};local FResult={};local calls=0;local fail=false;local buy=false
FResult.run=function(_,answers,options)
 calls+=1;assert(answers[1]=="I'll buy it." and options.doneWhen==nil and options.holdPosition==false)
 assert(options.timeout==5 and options.maxReplays==0 and options.shouldRun())
 if fail then error("simulated failure") end
 if buy then sword=true;assert(not options.shouldRun()) end
end
'''+purchase+r'''
assert(not __L3.bladeBuySword() and calls==1 and not __L3.bladeSwordBusy and flags[#flags]==false)
assert(not __L3.bladeBuySword() and calls==1,"no immediate duplicate purchase")
now+=3;fail=true;assert(not __L3.bladeBuySword() and calls==2 and not __L3.bladeSwordBusy and flags[#flags]==false)
now+=3;fail=false;buy=true;assert(__L3.bladeBuySword() and calls==3)
assert(__L3.bladeBuySword() and calls==3,"inventory confirmation prevents another purchase")
''')

    def test_collection_touches_potions_without_moving_to_silver(self):
        collect=self.part('__L3.bladeCollect=function()', '__L3.bladePrepareLegacy=function()')
        self.run_luau(VEC+r'''
local __L3={};local root={Position=Vector3.new(0,0,0)}
local LocalPlayer21={Character={FindFirstChild=function() return root end}};local tbl303={true}
local money={Name="MoneyBag"};local potion={Name="ToolBag",Position=Vector3.new(5,0,0),FindFirstChild=function() return {FindFirstChild=function() return {Text="Health Potion"} end} end}
local thrown={GetChildren=function() return {money,potion} end};local v966={FindFirstChild=function() return thrown end}
local touches=0;local firetouchinterest=function(part,r,event) assert(part==potion and r==root);touches+=1 end
__L3.bladeSupplyRequirements=function() return {['Health Potion']=1} end
__L3.fn596=function(p) return p end;__L3.bladeCount=function() return 0 end
__L3.fn597=function() error("must not approach a bag") end;local v1013=function() error("must not fly back") end
'''+collect+r'''
__L3.bladeCollect();assert(touches==2)
__L3.bladeSupplyRequirements=function() return {} end;__L3.bladeCollect();assert(touches==2)
''')

    def test_minimum_setting_overrides_old_snapshot_and_uses_own_queue_readiness(self):
        value=self.part('__L3.bladeValue=function', '__L3.bladeSilverGoal=function')
        assignments=self.part('__L3.bladeAssignments=function', '__L3.bladeWorkerPath=')
        self.run_luau(r'''
local __L3={bladeRunConfig={BladeShrCount=50}};local Options8={BladeShrCount={Value=7}};local Toggles8={}
'''+value+assignments+r'''
assert(__L3.bladeValue("BladeShrCount",50)==7)
Options8.BladeShrCount.Value=23;assert(__L3.bladeValue("BladeShrCount",50)==23)
local roster={{userId=1,joined=1,stage="B1_XP",preference="Shriekers",shrAvailable=false},
 {userId=2,joined=2,stage="B1_XP",preference="Shriekers",shrAvailable=true}}
local a=__L3.bladeAssignments(roster);assert(not a[1] and a[2]=="shriekers")
''')

    def test_entry_starts_after_three_seconds_for_seven_full_shriekers(self):
        farm=self.part('__L3.bladeXPShriekers=function()', '__L3.bladeXP=function()')
        # Stop the extracted real routine immediately after its gate, before combat setup.
        gate=farm[:farm.index('          if not __L3.bladeMovePoint(9,true)')]+r'''
          return os.clock()
        end
'''
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end};local task={wait=function(t) clock+=t end}
local tbl303={true};local tbl308={{}};local count=6
local __L3={bladeFullHP=function(h) return h.Health>=h.MaxHealth end,bladeFarmAssigned="shriekers",bladeCellLoad=function() return {} end,bladeCellBounds=function() return {},{} end,
 bladeValue=function() return 7 end,bladeStanding=function() return true end,bladeStatus=function() end}
__L3.bladeShriekers=function()
 if clock>=1 then count=7 end
 local mobs={};for i=1,count do mobs[i]={hum={Health=200,MaxHealth=200}} end;return mobs
end
'''+gate+r'''
assert(__L3.bladeXPShriekers()==4,"seven mobs appear at t=1; enter at t=4, not at fifty mobs or after five seconds")
''')

    def test_training_waits_fifteen_seconds_counts_paid_skills_and_never_buys_fourth(self):
        training=self.part('__L3.bladeTrainingCount=function', '__L3.bladeStep=function')
        self.run_luau(VEC+r'''
local __L3={};local __L2={fn502=function(skills) return skills end,tbl279={"a","b","c"}}
local tbl271={"Pommel Strike","Action Surge","Plate Training","MercenaryCarry"}
local tbl303={true};local tbl308={{}};local LocalPlayer21={Character={}}
local clock=0;local os={clock=function() return clock end};local silver=0;local pendingAt
local task={wait=function(t)
 clock+=t
 if pendingAt and clock>=pendingAt then silver-=20;pendingAt=nil end
 if clock>=15 and silver==0 then silver=1000 end
end}
local getServerValue=function() return silver end;local fn542=function() end;local fn534=function() end
local nav=0;local binds=0;local land=0;local at=false
local fn580=function() nav+=1;at=true;return true end
local near=function() return at end
__L3.setInn=function() binds+=1;return true end
__L3.bladeLand=function() land+=1 end
__L3.bladeStanding=function() return true end
__L3.bladeStatus=function() end
__L3.bladeBagPickup=function() end
local HResult={nearestNPC=function() return {} end};local calls=0;local times={}
local FResult={run=function(_,answers,opts)
 calls+=1;times[calls]=clock
 assert(opts.allowAnswer(answers[#answers]))
 assert(not opts.allowAnswer(answers[#answers]),"a duplicate dialogue event cannot pay twice")
 assert(opts.maxReplays==0 and opts.holdPosition==false)
 if silver>0 then pendingAt=clock+2 end
end}
'''+training+r'''
assert(__L3.bladeAlfricTrain())
assert(calls==4 and nav==1 and binds==1 and land==1,"one failed attempt, then exactly three paid skills without a reset")
assert(tbl308[1].bladeTraining.alfric.confirmed==3 and silver==940)
assert(times[2]-times[1]>=15,"failed purchase retries after 15 seconds")
assert(times[3]-times[2]>=2 and times[4]-times[3]>=2,"wait for each delayed debit before buying again")
assert(__L3.bladeAlfricTrain() and calls==4 and nav==1,"completed base training cannot buy a fourth skill")
assert(__L3.bladeTrainPurchase("jagen","Jagen",{}, {"pay"},{"ultra"},1))
assert(calls==5 and tbl308[1].bladeTraining.jagen.confirmed==1)
''')

    def test_supplier_approach_uses_flight_and_cleans_it_up(self):
        flight=self.part('rotSupplier.flyTo=function', '        rotDelivery.begin=')
        self.run_luau(VEC+r'''
Vector3.zero=Vector3.new(0,0,0)
local player={UserId=1};local target={Position=Vector3.new(10,20,30)}
local root={Anchored=true};local char={};local LocalPlayer24={Character=char}
local rotSupplier={masterReady=function(id) assert(id==1);return player,target end,status={SetText=function() end}}
local disconnected=0;local cleared=0;local clipped=0;local destination
local fn676=function() return {Disconnect=function() disconnected+=1 end} end
local fn677=function(p,speed) destination=p;assert(speed==100) end
local sResult10={root=function() return root end,humanoid=function() return nil end,
 clearVeil=function() cleared+=1 end,reclip=function(c) assert(c==char);clipped+=1 end}
'''+flight+r'''
assert(rotSupplier.approach(player));assert(destination.X==10 and destination.Y==22 and destination.Z==30)
assert(disconnected==1 and cleared==1 and clipped==1 and not root.Anchored)
''')

    def test_supplier_clicks_play_even_with_menu_placeholder_character(self):
        play=self.part('rotSupplier.ensurePlaying=function', '        local fn687 =')
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end};local task={wait=function(t) clock+=t end}
local tbl365={true};local menu=true;local clicks=0
local rotSupplier={status={SetText=function() end}}
local sResult10={root=function() return {} end}
local vResult6={startMenu=function() return menu end,clickPlay=function() clicks+=1;if clicks==3 then menu=false end end}
'''+play+r'''
assert(rotSupplier.ensurePlaying() and clicks==3)
menu=true;tbl365[1]=false;assert(not rotSupplier.ensurePlaying() and clicks==3)
''')

    def test_detection_queue_and_entry_with_33_and_50_mobs(self):
        detect=self.part('__L3.bladeFullHP=function', '__L3.bladeLockSetup=function')
        roster=self.part('__L3.bladeRoster=function', '__L3.bladeWorkerPath=')
        tick=self.part('__L3.bladeWorkerTick=function', '__L3.bladeRelease=function')
        xp=self.part('__L3.bladeXP=function()', '__L3.bladeExitXP=function()')
        farm=self.part('__L3.bladeXPShriekers=function()', '__L3.bladeXP=function()')
        gate=farm[:farm.index('          if not __L3.bladeMovePoint(9,true)')]+r'''
          enteredAt=os.clock()
          return true
        end
'''
        self.run_luau(VEC+r'''
local clock=0;local enteredAt;local os={clock=function() return clock end,time=function() return 100 end}
local task={wait=function(t) clock+=t or 0 end};local DateTime={now=function() return {UnixTimestampMillis=100000} end}
local LocalPlayer21={UserId=1,Name="test",Character={}}
local game={JobId="same-job"};local a1723={State={}}
local __L3={bladeWorker={},bladeWorkerPath="self.json",bladeShrApproachCharacter=LocalPlayer21.Character}
local tbl303={true};local tbl308={{phase="B1_XP"}};local fn542=function() end
local count=33;local minimum=33;local mobs={};local calls=0
for i=1,50 do
 local root={Position=Vector3.new(i%2==0 and -0.5 or 5,0,5),Size=Vector3.new(2,2,2)}
 local hum={Health=i==1 and 199.999 or 200,MaxHealth=200}
 local mob={Name=i..".Shrieker",PrimaryPart=root,
  FindFirstChild=function() return root end,FindFirstChildOfClass=function() return hum end}
 mobs[i]=mob
end
local live={GetChildren=function() local t={};for i=1,count do t[i]=mobs[i] end;return t end}
local v966={FindFirstChild=function() return live end}
__L3.bladeValue=function(name,default) if name=="BladeShrCount" then return minimum elseif name=="BladeFarm" then return "Shriekers" end;return default end
__L3.bladeCellLoad=function() return {} end
__L3.bladeCellBounds=function() return {minX=0,maxX=10,minZ=0,maxZ=10,minY=-6,maxY=6},Vector3.new(5,0,5) end
__L3.bladeEnabled=function() return true end
__L3.bladeStanding=function() return true end
__L3.bladeStatus=function() end
__L3.bladeSupplyAssignments=function() return nil end
__L3.bladePhase=function(phase) tbl308[1].phase=phase end
__L3.bladeRelease=function() error("must not release a valid entry") end
__L3.bladeIO={sharedList=function() return {} end,readJson=function() return nil end,
 sharedNow=function() return 100 end,sharedLease=function() return 8 end,
 writeJson=function() calls+=1;return true end,channel=function() return {roster=function() return {} end} end}
'''+detect+roster+tick+gate+xp+r'''
__L3.bladeXP()
assert(calls>=3 and tbl308[1].phase=="B1_EXIT" and enteredAt>=3 and enteredAt<4)
assert(__L3.bladeShrReport.count==33 and __L3.bladeShrReport.full==33,"boundary overlap and rounded full HP must count")
count=50;minimum=50;clock=0;enteredAt=nil;tbl308[1]={phase="B1_XP"};__L3.bladeWorker={}
__L3.bladeXP();assert(tbl308[1].phase=="B1_EXIT" and enteredAt>=3 and __L3.bladeShrReport.full==50)
-- A full sword hit must still block entry; HP tolerance only handles rounding noise.
mobs[1].FindFirstChildOfClass=function() return {Health=192,MaxHealth=200} end
__L3.bladeShriekers();assert(__L3.bladeShrReport.full==49)
assert(__L3.bladeXPWaitStatus():find("aguardando HP cheio",1,true))
-- Mobs wholly outside this cell must not be counted, even when nearby.
mobs[2].PrimaryPart.Position=Vector3.new(15,0,5)
__L3.bladeShriekers();assert(__L3.bladeShrReport.count==49 and __L3.bladeShrReport.outside==1)
assert(__L3.bladeXPWaitStatus():find("faltam alvos dentro da cela",1,true))
''')


    def test_reserved_shrieker_entry_does_not_wait_for_danger_to_clear(self):
        wait=self.part('local fn539 = function()', '        local fn540 =')
        self.run_luau(r'''
local __L3={bladeRunConfig={},bladeFarmAssigned="shriekers"};local tbl308={{phase="B1_XP"}};local tbl303={true}
local nearby=true;local fn537=function() return true end;local fn538=function() return nearby end
local waits=0;local task={wait=function() waits+=1;nearby=false end}
'''+wait+r'''
fn539();assert(waits==0,"Danger and a nearby necro must not prevent entry into the reserved combat farm")
__L3.bladeFarmAssigned=nil;fn539();assert(waits==1,"unreserved movement keeps its existing wait")
''')

    def test_aim_sweep_matches_brute_force_without_quadratic_cone_checks(self):
        aim=self.part('__L3.bladeConeCount=function', '__L3.bladeAttack=function')
        self.run_luau(VEC+r'''
local __L3={bladeValue=function(name,d) if name=="BladeM1Step" then return 0 end;return d end}
'''+aim+r'''
local count=__L3.bladeConeCount;local calls=0
__L3.bladeConeCount=function(...) calls+=1;return count(...) end
math.randomseed(2026)
local origin=Vector3.new(0,0,0);local look=Vector3.new(0,0,-1);local half=math.rad(55)
for trial=1,80 do
 local targets={};local angles={0}
 for i=1,35 do
  local angle=math.random()*math.pi*2;local radius=math.random()*7
  targets[i]={Position=Vector3.new(math.sin(angle)*radius,0,-math.cos(angle)*radius)}
  for _,a in {angle,angle-half,angle+half} do table.insert(angles,a) end
 end
 targets[#targets+1]={Position=origin}
 local expected=0
 for _,angle in angles do expected=math.max(expected,count(origin,Vector3.new(math.sin(angle),0,-math.cos(angle)),targets,8,half)) end
 local plan=__L3.bladeAimPlan(origin,origin,look,targets,{},function() return false end,function() return true end)
 assert(plan.count==expected,"coverage changed")
 assert(count(origin,plan.direction,targets,8,half)==plan.count)
end
assert(calls==80,"the sweep should check the initial direction once per position, not every angle against every target")
''')

    def test_detached_mob_health_listeners_are_pruned_during_farm(self):
        farm=self.part('__L3.bladeXPShriekers=function()', '__L3.bladeXP=function()')
        start=farm.index('          local connections,watched=')
        end=farm.index('          local targets=function()')
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end}
local save={};local tbl303={true};local bounds={};local fn542=function() end
local live={};local v966={FindFirstChild=function() return live end}
local mobs={};local __L3={bladeShriekers=function() return mobs end}
local all={}
local function mob()
 local entry={disconnected=false};all[#all+1]=entry
 local h={Health=200,HealthChanged={Connect=function() return {Disconnect=function() entry.disconnected=true end} end}}
 return {hum=h,model={Parent=live},root={Position={}}}
end
mobs={mob()}
'''+farm[start:end]+r'''
for i=1,1000 do
 mobs[1].model.Parent=nil;mobs={mob()};clock+=0.5;refresh()
 local n=0;for _ in connections do n+=1 end;assert(n==1,"retained a removed mob connection")
end
for i=1,#all-1 do assert(all[i].disconnected) end
''')

    def test_stacked_shriekers_count_without_including_neighbor_cell(self):
        membership=self.part('__L3.bladeMobInCell=function', '__L3.bladeShriekers=function')
        self.run_luau(VEC+r'''
local __L3={}
'''+membership+r'''
local bounds={minX=0,maxX=10,minZ=0,maxZ=10,minY=-6,maxY=6}
assert(__L3.bladeMobInCell({Position=Vector3.new(5,14,5),Size=Vector3.new(2,2,2)},bounds),"spawned mobs stacked above another mob still belong to the cell")
assert(__L3.bladeMobInCell({Position=Vector3.new(-1.5,0,5),Size=Vector3.new(2,2,2)},bounds))
assert(not __L3.bladeMobInCell({Position=Vector3.new(20,0,5),Size=Vector3.new(2,2,2)},bounds))
''')

    def test_draug_visit_binds_then_talks_and_is_not_repeated(self):
        draug=self.part('__L3.bladeDraugVisit=function()', '__L3.bladeTrainingCount=function')
        self.run_luau(VEC+r'''
local __L3={bladeStatus=function() end};local __L2={tbl278={"Welcome back"}}
local tbl308={{}};local tbl303={true};local clock=0;local os={clock=function() return clock end}
local at=false;local events={};local accept=false
__L3.setInn=function(inn) assert(inn=="Castle Sanctuary");table.insert(events,"spawn");tbl308[1].boundInn=inn;return true end
local fn580=function() at=true;table.insert(events,"move");return true end
local near=function() return at end
__L3.bladeLand=function() table.insert(events,"land") end
__L3.bladeTrainWait=function() table.insert(events,"retry") end
local HResult={nearestNPC=function(name) assert(name=="Draug");return {} end}
local FResult={run=function(_,answers,opts) assert(answers[1]=="Thank you." and opts.holdPosition==false);table.insert(events,"talk");return accept end}
local fn542=function() end
'''+draug+r'''
assert(not __L3.bladeDraugVisit() and table.concat(events,",")=="spawn,move,land,talk,retry")
accept=true;assert(__L3.bladeDraugVisit() and tbl308[1].done.p6_draug and tbl308[1].bladeDraugDone)
local n=#events;assert(__L3.bladeDraugVisit() and #events==n)
''')
        ultra=self.part('__L3.fn638 = function()', 'fn534("P7: section 1')
        self.assertLess(ultra.index('bladeDraugVisit()'),ultra.index('bladeTrainerApproach("jagen"'))

    def test_core_hooks_and_respawn_event_cleanup_across_reloads(self):
        core=self.part('local fn44 = function()', '    tbl44.f = function()')
        self.run_luau(r'''
local __bootSession={};local tbl44={};local activeConnections=0;local replacements={};local fail=false;local count=0
local fire=function() end;local destroy=function() end
local workspace={Destroy=destroy};local Instance={new=function() return {FireServer=fire} end}
local connect={Connect=function(_,fn) activeConnections+=1;local on=true;return {Disconnect=function() if on then activeConnections-=1;on=false end end} end}
local player={CharacterAdded=connect};local services={Players={LocalPlayer=player},RunService={}}
tbl44.a=function() return services end;tbl44.e=function() return {keyHandlerEnabled=function() return false end} end
local getgenv=function() return {} end;local checkcaller=function() return true end
local newcclosure=function(fn) return fn end;local islclosure=function() return false end;local getupvalues=function() return {} end
local hookfunction=function(target,replacement)
 count+=1;if fail and target==coroutine.wrap then error("simulated failed hook") end
 local original=replacements[target] or target;replacements[target]=replacement;return original
end
local task={spawn=function(fn) fn() end,wait=function() end}
'''+core+r'''
for i=1,100 do
 fn44()("Normal");assert(activeConnections==1)
 assert(replacements[destroy]~=destroy and replacements[fire]~=fire)
 __bootSession.coreCleanup();__bootSession.coreCleanup()
 assert(activeConnections==0 and replacements[destroy]==destroy and replacements[fire]==fire and replacements[coroutine.wrap]==coroutine.wrap)
end
fail=true;assert(not pcall(fn44(),"Normal"));fail=false
__bootSession.coreCleanup();assert(activeConnections==0 and replacements[destroy]==destroy and replacements[fire]==fire)
''')

    def test_loader_rejects_concurrent_start_and_allows_reload_after_unload(self):
        loader=(ROOT/'loader.lua').read_text()
        self.run_luau(r'''
local env={};local getgenv=function() return env end
local warnings=0;local warn=function() warnings+=1 end
local downloads,compiles,runs=0,0,0;local nested;local broken=false
local game={JobId="same-job",IsLoaded=function() return true end}
local loadstring=function(source)
 compiles+=1;if broken then return nil,"compile failure" end
 return function() runs+=1;env.__BLADE23_SESSION.state="running";return true end
end
local function execute()
'''+loader+r'''
end
game.HttpGet=function()
 downloads+=1;nested=execute();assert(nested==false,"concurrent load must return before another download")
 return "runtime"
end
assert(execute() and downloads==1 and compiles==1 and runs==1)
assert(not execute() and downloads==1 and compiles==1)
env.__BLADE23_SESSION.state="unloaded"
assert(execute() and downloads==2 and compiles==2 and runs==2)
env.__BLADE23_SESSION.state="unloaded";broken=true
assert(not execute() and env.__BLADE23_SESSION.state=="failed")
broken=false;assert(execute() and runs==3)
''')

    def test_startup_memory_journal_is_bounded_and_keeps_last_phase(self):
        startup=self.source[:self.source.index('local __UI_FILES =')]
        self.run_luau(r'''
local env={};local getgenv=function() return env end
local game={JobId="job",PlaceId=1,GetService=function(_,name)
 if name=="Stats" then return {GetTotalMemoryUsageMb=function() return 1234.5 end} end
 return {JSONEncode=function() return "report" end}
end}
local gcinfo=function() return 65536 end;local identifyexecutor=function() return "test-executor" end
local writes=0;local writefile=function() writes+=1 end
'''+startup+r'''
__bootSession.state="running";__bootMark("ready")
for i=1,1000 do __bootMark("sample",true) end
assert(#__bootSession.report.samples==64 and __bootSession.report.phase=="ready")
assert(__bootSession.report.samples[1].luaMB==64 and __bootSession.report.samples[1].clientMB==1234.5)
assert(__bootSession.report.executor=="test-executor" and writes==1002)
''')

    def test_unload_is_reentrant_and_releases_callback_references(self):
        unload=self.part('function Library:Unload()', 'Library:GiveSignal(UserInputService.WindowFocused:')
        self.run_luau(r'''
local env={};local getgenv=function() return env end
local Library={UnloadSignals={},Signals={}};local calls=0;local destroyed=0
function Library:SafeCallback(fn) fn() end
local RunService={UnbindFromRenderStep=function() end}
local UserInputService={};local OriginalMouseIconEnabled=true
local ScreenGui={Destroy=function() destroyed+=1 end};local Cursor;local CursorOutline;local DimState={}
for _,name in {"Toggles","Options","Registry","Tabs","KeybindRows","SearchIndex","SearchBoxes"} do Library[name]={} end
Library.UnloadSignals[1]=function() calls+=1;Library:Unload() end
'''+unload+r'''
Library:Unload();Library:Unload()
assert(calls==1 and destroyed==1 and #Library.UnloadSignals==0 and Library.Unloaded)
''')

    def test_plain_punch_works_at_twenty_fps_without_charging(self):
        plain=self.part('__L3.bladePlainPunch=function', '__L3.bladeManaPunch=function')
        self.run_luau(r'''
local __L3={};local clock=0;local os={clock=function() return clock end}
local tool={};local hum={UnequipTools=function() tool=nil end}
local character={FindFirstChild=function() end,FindFirstChildOfClass=function() return hum end,FindFirstChildWhichIsA=function() return tool end}
local LocalPlayer21={Character=character};local attacks=0;local releases=0;local pending
local a1723={State={mana={chargeUntil=function() error("ordinary punch must never charge mana") end,decharge=function() releases+=1 end}}}
local land=true
local fn577=function() assert(not tool);attacks+=1;if land then pending=clock+0.1 end end
local task={wait=function(t)
 clock+=math.max(0.05,math.ceil((t or 0)/0.05)*0.05)
 if pending and clock>=pending then __L3.bladeUnlockAwaiting=false;pending=nil end
end}
'''+plain+r'''
for i=1,3 do assert(__L3.bladePlainPunch(function() return true end)) end
assert(attacks==3 and releases==6 and __L3.bladeUnlockAwaiting==nil)
land=false;assert(not __L3.bladePlainPunch(function() return true end) and clock<2.1)
assert(not __L3.bladePlainPunch(function() return false end) and attacks==4)
''')

    def test_explicit_allies_and_rot_alts_override_enemy_filter_for_progression(self):
        friendly=self.part('__L2.fn512 = function', '      __L2.fn513 = function')
        self.run_luau(r'''
local __L2={}
'''+friendly+r'''
local alice={UserId=10,Name="Alice"};local rot={UserId=20,Name="RotVictim"};local enemy={UserId=30,Name="Enemy"}
local app={State={isFriend=function(p) return p==alice end,isFriendly=function() return false end},Library={Options={RotAlts={Value={RotVictim=true}}}}}
assert(__L2.fn512(app,alice));assert(__L2.fn512(app,rot));assert(not __L2.fn512(app,enemy))
app.State.bladeRunAlts={["30"]=true};assert(__L2.fn512(app,enemy))
app.State.bladeRunAlts={};app.State.bladeTeam={[20]=true};assert(__L2.fn512(app,rot))
assert(not __L2.fn512(app,nil))
''')


    def test_server_ally_selector_keeps_saved_offline_ids_and_refreshes_without_erasing(self):
        refresh=self.part('local alliesUpdating=false', '        local toggleFriend')
        ui=self.part('alliesUpdating=true -- AddDropdown', '        local addLeftGroupboxResult17')
        self.run_luau(r'''
local res464={[42]="Offline"};local Options17={};local saved;local events={};local self={UserId=1,Name="Self"};local alice={UserId=10,Name="Alice"}
local LocalPlayer33=self;local players={self,alice}
local signal={Connect=function(_,fn) table.insert(events,fn);return {} end}
local getResult42={GetPlayers=function() return players end,PlayerAdded=signal,PlayerRemoving=signal}
local fn1094=function(value) saved=table.clone(value) end
local task={defer=function(fn) fn() end}
local group={AddLabel=function() end,AddButton=function() end}
function group:AddDropdown(name,settings)
 local option={Value={},SetValues=function(obj,values) obj.Values=values end}
 function option:SetValue(value) self.Value=value;settings.Callback(value) end
 Options17[name]=option;settings.Callback(settings.Default)
end
local a11260={State={},Tabs={Blade23={AddRightGroupbox=function() return group end}},Maid={Give=function() end},SaveManager={SetIgnoreIndexes=function() end}}
'''+refresh+ui+r'''
assert(res464[42]=="Offline","constructing dropdown must not erase saved friends")
assert(Options17.ServerAllies.Value["Offline [42]"])
a11260.State.loadingConfig=true
Options17.ServerAllies:SetValue({["Alice [10]"]=true,["Offline [42]"]=true})
assert(saved[10]=="Alice" and saved[42]=="Offline","loading a profile must update effective allies, not only the dropdown")
a11260.State.loadingConfig=false
players={self};fn1104()
assert(Options17.ServerAllies.Value["Alice [10]"] and res464[10]=="Alice")
Options17.ServerAllies:SetValue({})
assert(next(saved)==nil and next(res464)==nil)
''')


    def test_threat_settings_are_independent_between_gaia_and_khei(self):
        helpers=self.part('__L3.bladeThreatDistance=function()', '        __L3.bladeEnabled=function()')
        self.run_luau(r'''
local __L3={};local a1723={State={}};local __L2={fn512=function() return false end};local num274=3541987450;local game={PlaceId=5208655184}
local Options8={ProgProximity={Value=120},ProgKheiProximity={Value=650}}
local Toggles8={ProgStayInServer={Value=true},ProgKheiStayInServer={Value=false}}
'''+helpers+r'''
assert(__L3.bladeThreatDistance()==120 and __L3.bladeStayHere())
game.PlaceId=num274;assert(__L3.bladeThreatDistance()==650 and not __L3.bladeStayHere())
Options8.ProgKheiProximity.Value=0;assert(__L3.bladeThreatDistance()==0)
''')


    def test_menu_pause_waits_for_old_worker_and_manual_play_preserving_progress(self):
        pause=self.part('__L3.bladePauseForMenu=function(reason)', '        a1723.Maid:Give(function() __L3.bladeMenuPause')
        self.run_luau(r'''
local __L3={bladeCoreRunning=true,progStatusLabel={SetText=function() end},bladeLand=function() end}
local tbl303={true};local tbl307={};local tbl308={};local Toggles8={};local game={JobId="job",PlaceId=1};local num274=2
local save={phase="B1_XP",bladeDamage=4000,bladeFistDamage=0,bladeUnlockHits=2};local saves=0;local resumes=0;local menu=false;local spawned=false;local forced=0
local a1723={State={mana={decharge=function() end}}}
local stored={};local qResult3={get=function(key) return stored[key] end,set=function(key,value) stored[key]=value end}
local fn531=function() end;local fn532=function() end;local fn542=function() saves+=1 end
local fn497=function() return spawned end
local v1009=function() tbl303[1]=false;stored.khei_run=nil end
local jobs={};local task={spawn=function(fn) table.insert(jobs,coroutine.create(fn)) end,wait=function() coroutine.yield() end}
local function step() for _,thread in table.clone(jobs) do if coroutine.status(thread)~="dead" then local ok,err=coroutine.resume(thread);assert(ok,err) end end end
local vResult5={forceMenu=function(active) assert(active() and not __L3.bladeCoreRunning and not tbl303[1]);forced+=1;menu=true;return true end,startMenu=function() return menu end}
__L3.fn648=function(resume)
 assert(resume and save.bladeDamage==4000 and save.bladeUnlockHits==2 and save.phase=="B1_XP")
 resumes+=1;tbl303[1]=true
end
'''+pause+r'''
assert(__L3.bladePauseForMenu("Enemy"));assert(not __L3.bladePauseForMenu("Enemy again"))
step();assert(forced==0 and resumes==0 and a1723.State.bladeManualMenu)
__L3.bladeCoreRunning=false;step();assert(forced==1 and resumes==0 and saves==1)
for i=1,10 do step() end;assert(resumes==0,"must not press Play automatically")
menu=false;step();assert(resumes==0,"wait until character has spawned")
spawned=true;step();assert(resumes==1 and __L3.bladeMenuPause==nil and not a1723.State.bladeManualMenu)
step();assert(resumes==1,"only one resumed worker")
assert(__L3.bladePauseForMenu("Enemy"));step();assert(menu)
__L3.bladeMenuPause=nil;a1723.State.bladeManualMenu=false;menu=false;step();assert(resumes==1,"Stop cancels pending resume")
-- A Gaia-to-Khei handoff resumes its own stage rather than restarting a completed Gaia run.
tbl303[1]=true;stored.khei_run="true";spawned=true
local handoffs=0;a1723.State.progKheiHandoff=function(resume) assert(resume and stored.khei_run=="true");handoffs+=1 end
assert(__L3.bladePauseForMenu("Illusionist"));step();menu=false;step();assert(handoffs==1 and resumes==1)
''')


    def test_stay_server_menus_even_if_blade_hops_are_disabled(self):
        action=self.part('local fn558 = function(', '        local fn559 = function()')
        self.run_luau(r'''
local tbl303={true};local tbl304={false};local __L3={bladeEnabled=function() return true end,bladeValue=function() return false end}
local stays=true;local pauses=0;local hops=0
__L3.bladeStayHere=function() return stays end;__L3.bladePauseForMenu=function() pauses+=1;return true end
local fn557=function() hops+=1;return true end
'''+action+r'''
assert(fn558("Enemy") and pauses==1 and hops==0)
stays=false;assert(not fn558("Enemy") and hops==0)
__L3.bladeValue=function() return true end;assert(fn558("Enemy") and hops==1)
''')


    def test_illusionist_super_menu_and_world_skip_settings(self):
        detect=self.part('local fn563 = function(', '        local fn564 = function(')
        self.run_luau(r'''
local tbl303={true};local LocalPlayer21={};local enemy={Name="Illu",Character={}};local game={PlaceId=1};local num274=2
local a1723={State={}};local __L2={fn512=function() return false end};local super=false;local fn562=function() return super end
local fn553=function() return false end;local GResult={isIllusionist=function() return true end}
local Toggles8={ProgSkipIllusionist={Value=false},ProgMenuIllusionistSuper={Value=true},ProgKheiSkipIllusionist={Value=false}}
local menus=0;local reactions=0;local __L3={bladePauseForMenu=function() menus+=1;return true end,bladeThreatDistance=function() return 50 end}
local fn549=function(p) return p.Name end;local fn558=function() reactions+=1;return true end
'''+detect+r'''
assert(not fn563(enemy,true) and menus==0)
super=true;assert(fn563(enemy,true) and menus==1 and reactions==0)
game.PlaceId=num274;assert(not fn563(enemy,true) and menus==1)
Toggles8.ProgKheiSkipIllusionist.Value=true;assert(fn563(enemy,true) and reactions==1)
__L2.fn512=function() return true end;assert(not fn563(enemy,true) and reactions==1)
''')


    def test_proximity_watcher_keeps_stay_checks_and_excludes_allies_even_in_danger(self):
        start='function(X, D, j, I, l, Z, g, x, i, y, Q, A, F, n, c, Y, f, r, H, e, h, q, s, proximityDistance)'
        native=self.part(start,'  function(X, D, j)')
        native=native.rstrip().removesuffix(',')
        self.run_luau(VEC+r'''
local tick=function() return 100 end
local reported=0;local ally={Name="Ally"};local enemy={Name="Enemy"}
local function character(x) return {FindFirstChild=function(_,key) if key=="HumanoidRootPart" then return {Position=Vector3.new(x,0,0)} end end} end
ally.Character=character(5);enemy.Character=character(20)
local self={Character=character(0)};local players={GetPlayers=function() return {self,ally,enemy} end}
local factory='''+native+r'''
local watcher=factory({HasTag=function() return true end},self,{ProgProximity={Value=0}},100,players,{RANGE={opalHold=0},allowed=function() return false end},{ProgStayInServer={Value=true}},function() end,{},function() end,function(_,p) return p==ally end,function(p) return p.Name end,{function() end},{0},{},function() return 0 end,function(reason) reported+=1;assert(reason:find("Enemy",1,true)) end,{0},{true},{0},{0},{true},function() return true end,function() return 50 end)
watcher(0.1);assert(reported==1)
''')


    def test_only_manual_stop_cancels_menu_pause_while_previous_stage_unwinds(self):
        stop=self.part('v1009 = function(a1824)', '        __L3.bladePauseForMenu=function(reason)')
        self.run_luau(r'''
local v1009;local tbl303={false};local __L3={bladeMenuPause={},bladePausing=false};local a1723={State={bladeManualMenu=true}}
local fn531=function() end;local fn532=function() end
'''+stop+r'''
v1009();assert(__L3.bladeMenuPause and a1723.State.bladeManualMenu)
v1009(true);assert(__L3.bladeMenuPause==nil and not a1723.State.bladeManualMenu)
''')


    def test_config_roundtrip_restores_alts_and_allies_including_offline_and_empty_lists(self):
        parser=self.part('        Dropdown = {', '        ColorPicker = {')
        methods=self.part('    function SaveManager:Save(name)', '    function SaveManager:Delete(name)')
        setter=self.part('function Dropdown:SetValue(value)', '\tfunction Dropdown:GetValue()')
        self.assertNotIn('"RotAlts"',self.part('local tbl732 = {','        for i135'))
        self.assertNotIn('SetIgnoreIndexes({"ServerAllies"})',self.source)
        self.run_luau(r'''
local function clone(x) if type(x)~="table" then return x end;local t={};for k,v in x do t[k]=clone(v) end;return t end
local disk={};local encoded
local HttpService={JSONEncode=function(_,data) encoded=clone(data);return "json" end,JSONDecode=function() return clone(encoded) end}
local writefile=function(path,value) disk[path]=value end;local readfile=function(path) return disk[path] end;local isfile=function(path) return disk[path]~=nil end
local task={spawn=function(fn,...) fn(...) end,wait=function() end}
local SaveManager={Folder="sentinel",Ignore={},Library={Toggles={},Options={}},CheckFolderTree=function() end,CheckSubFolder=function() return false end}
local function option(values,value)
 local Dropdown={Type="Dropdown",Multi=true,Values=values,Value=value,Display=function() end,SetValues=function(obj,new) obj.Values=new end}
 local fire=function() end
'''+setter+r'''
 return Dropdown
end
SaveManager.Parser={
'''+parser+r'''
}
'''+methods+r'''
local alts=option({"CurrentAlt"},{OfflineAlt=true})
local allies=option({"Online [10]"},{["Offline [42]"]=true})
SaveManager.Library.Options={RotAlts=alts,ServerAllies=allies}
assert(SaveManager:Save("Bots"))
alts.Value={};allies.Value={}
assert(SaveManager:Load("Bots"))
assert(alts.Value.OfflineAlt and allies.Value["Offline [42]"])
assert(table.find(alts.Values,"OfflineAlt") and table.find(allies.Values,"Offline [42]"))
-- Saving an intentionally empty profile clears the lists when loaded later.
alts.Value={};allies.Value={};assert(SaveManager:Save("Empty"))
alts.Value.CurrentAlt=true;allies.Value["Online [10]"]=true
assert(SaveManager:Load("Empty") and next(alts.Value)==nil and next(allies.Value)==nil)
''')


    def test_rot_refresh_preserves_offline_selection_and_supplier_role_does_not_clear_it(self):
        refresh=self.part('local function rotRefreshPlayers()', '        local function rotCollectSelected()')
        role=self.part('local fn670 = function()', '        local fn671 = function()')
        self.assertNotIn('Options9.RotAlts:SetValue({})',self.source)
        self.run_luau(r'''
local Options9={RotAlts={Value={OfflineAlt=true},SetValues=function(obj,values) obj.Values=values end}}
local LocalPlayer24={Name="Me"};local getResult26={GetPlayers=function() return {LocalPlayer24,{Name="OnlineAlt"}} end}
local tbl368={};local tbl369={};local rotSupplier={explicitSupplier=true};local a1849={State={}}
'''+refresh+role+r'''
rotRefreshPlayers()
assert(Options9.RotAlts.Value.OfflineAlt and table.find(Options9.RotAlts.Values,"OfflineAlt"))
assert(not fn670(),"supplier role must not turn into a carrier just because a saved config has alts")
rotSupplier.explicitSupplier=false;assert(fn670(),"receiver uses the preserved selection")
rotSupplier.explicitSupplier=true;a1849.State.bladeRunAlts={OfflineAlt=true};assert(fn670(),"active Sigil receiver config remains authoritative")
''')



    def test_blade_autosave_restores_all_control_types_and_never_starts_workers(self):
        prefs=self.part('        local bladePrefs={', '        local function allowBladeProfileSettings()')
        parsers=self.part('    SaveManager.Parser = {', '    function SaveManager:SetLibrary(library)')
        self.run_luau(r'''
local function clone(x) if type(x)~="table" then return x end;local t={};for k,v in x do t[k]=clone(v) end;return t end
local function encode(x)
 if type(x)~="table" then return tostring(x) end
 local keys={};for k in x do table.insert(keys,k) end;table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
 local out={};for _,k in keys do table.insert(out,tostring(k)..":"..encode(x[k])) end;return "{"..table.concat(out,"|").."}"
end
local dataByJSON,disk={},{};local writes=0;local warnings=0
local http={JSONEncode=function(_,data) local json=encode(data);dataByJSON[json]=clone(data);return json end,JSONDecode=function(_,json) assert(dataByJSON[json],"bad json");return clone(dataByJSON[json]) end}
local game={GetService=function(_,name) if name=="Players" then return {LocalPlayer={UserId=123}} end;return http end}
local warn=function() warnings+=1 end
local isfile=function(path) return disk[path]~=nil end;local readfile=function(path) return disk[path] end
local writefile=function(path,value) writes+=1;disk[path]=value end
local isfolder=function() return true end;local makefolder=function() end
local tab={};local a11542={Tabs={Blade23={Container=tab}},State={}}
local function color(hex) return {hex=hex,ToHex=function(self) return self.hex end} end
local Color3={fromHex=color}
local function control(kind,value,inside)
 local c={Type=kind,Value=value,Values={"Online"},Mode="Press",Modifiers={"Ctrl"},Transparency=0.3}
 c.ConfigInstance={IsDescendantOf=function(_,container) return inside~=false and container==tab end}
 c.SetValues=function(self,v) self.Values=v end
 c.SetValue=function(self,v) if kind=="Slider" then self.Value=tonumber(v) elseif kind=="KeyPicker" then self.Value=v[1];self.Mode=v[2];self.Modifiers=v[3] else self.Value=v end end
 c.SetValueRGB=function(self,v,alpha) self.Value=v;self.Transparency=alpha end
 return c
end
local Library23={Toggles={Stay=control("Toggle",true),RotBotEnabled=control("Toggle",true),RotReceiverQueue=control("Toggle",true)},Options={
 Speed=control("Slider",100),Text=control("Input","url"),RotAlts=control("Dropdown",{Offline=true}),ServerAllies=control("Dropdown",{["Friend [42]"]=true}),
 Stop=control("KeyPicker","F8"),Tint=control("ColorPicker",color("abcdef")),OtherTab=control("Input","outside",false)}}
Library23.Options.RotAlts.Multi=true;Library23.Options.ServerAllies.Multi=true
local SaveManager={Library=Library23}
'''+parsers+prefs+r'''
assert(bladePrefs.file:find("123",1,true))
bladePrefs.ready=true;assert(bladePrefs.save() and writes==1)
assert(bladePrefs.save() and writes==1,"unchanged settings must not keep writing files")
local saved=clone(dataByJSON[disk[bladePrefs.file]])
for _,row in saved.objects do assert(row.idx~="RotBotEnabled" and row.idx~="RotReceiverQueue" and row.idx~="OtherTab") end
assert(#saved.objects==7,"all Blade control types, including keys, colors, offline selections")
Library23.Toggles.Stay.Value=false;Library23.Toggles.RotBotEnabled.Value=false;Library23.Toggles.RotReceiverQueue.Value=false
Library23.Options.Speed.Value=1;Library23.Options.Text.Value="changed";Library23.Options.RotAlts.Value={};Library23.Options.ServerAllies.Value={}
Library23.Options.Stop.Value="F1";Library23.Options.Tint.Value=color("000000")
assert(bladePrefs.restore() and a11542.State.bladeProfileLoaded and not a11542.State.loadingConfig)
assert(Library23.Toggles.Stay.Value and not Library23.Toggles.RotBotEnabled.Value and not Library23.Toggles.RotReceiverQueue.Value)
assert(Library23.Options.Speed.Value==100 and Library23.Options.Text.Value=="url")
assert(Library23.Options.RotAlts.Value.Offline and table.find(Library23.Options.RotAlts.Values,"Offline"))
assert(Library23.Options.ServerAllies.Value["Friend [42]"] and Library23.Options.Stop.Value=="F8" and Library23.Options.Stop.Mode=="Press")
assert(Library23.Options.Tint.Value.hex=="abcdef" and Library23.Options.Tint.Transparency==0.3)
a11542.State.loadingConfig=true;Library23.Options.Text.Value="pending";bladePrefs.save();assert(writes==1)
a11542.State.loadingConfig=false;bladePrefs.save();assert(writes==2)
Library23.Options.RotAlts.Value={};Library23.Options.ServerAllies.Value={};bladePrefs.save()
Library23.Options.RotAlts.Value={Someone=true};Library23.Options.ServerAllies.Value={Someone=true};bladePrefs.restore()
assert(next(Library23.Options.RotAlts.Value)==nil and next(Library23.Options.ServerAllies.Value)==nil)
disk[bladePrefs.file]="invalid";assert(not bladePrefs.restore() and disk[bladePrefs.file]=="invalid" and warnings==1)
''')

    def test_latest_blade_preferences_are_loaded_before_workers_and_not_overwritten_by_legacy(self):
        startup=self.part('        SaveManager:BuildConfigSection(Settings,', '        if cond50 and Library23.Toggles.ExecuteOnServerhop then')
        self.assertLess(startup.index('SaveManager:LoadAutoloadConfig()'),startup.index('bladePrefs.restore()'))
        self.assertLess(startup.index('bladePrefs.restore()'),startup.index('a11542.State.notificationsReady = true'))
        legacy=self.part('__L3.fn650 = function()', '        __L3.hiddenSetup=')
        self.assertIn('if a1723.State.bladeProfileLoaded then return end',legacy)
        self.assertNotIn('MapPoints = CreateWindowResult:AddTab',self.source)
        self.assertNotIn('pointsUI=',self.source)

    def test_leaderboard_can_map_rows_without_executor_introspection(self):
        helper=self.part('        local function leaderboardPlayerFromLabel(label)', '        local fn1063 = function(')
        self.run_luau(r'''
local alice={Name="Alice",UserId=1};local bob={Name="Bob",UserId=2}
local getResult41={GetPlayers=function() return {alice,bob} end,GetPlayerByUserId=function(_,id) return id==1 and alice or id==2 and bob end}
local names={[alice]="Rogue One",[bob]="Rogue Two"};local fn1036=function(player) return names[player] end
local function label(name,text,id) return {Name=name,Text=text,GetAttribute=function(_,key) if key=="UserId" then return id end end} end
'''+helper+r'''
assert(leaderboardPlayerFromLabel(label("Row","<b>Alice</b>"))==alice)
assert(leaderboardPlayerFromLabel(label("Row","Rogue Two"))==bob)
assert(leaderboardPlayerFromLabel(label("Row","whatever",1))==alice)
assert(leaderboardPlayerFromLabel(label("Row","unrelated"))==nil)
names[bob]="Rogue One";assert(leaderboardPlayerFromLabel(label("Row","Rogue One"))==nil)
''')


    def test_local_client_presence_is_independent_of_queues_and_rejects_stale_or_other_servers(self):
        service=self.part('      tbl358.localClients=function()', '      tbl358.channel = function(')
        self.run_luau(r'''
local now=100;local os={time=function() return now end,clock=function() return now end}
local function clone(t) local r={};for k,v in t do r[k]=v end;return r end
local disk={};local reads=0;local writes=0
local readJson=function(path) reads+=1;return disk[path] and clone(disk[path]) end
local writeJson=function(path,value) writes+=1;disk[path]=clone(value);return true end
local alice={UserId=1};local bob={UserId=2};local foreign={UserId=3};local inactive={UserId=4}
local players={alice,bob,foreign,inactive}
local function create(player,job,place)
 local tbl358={};local LocalPlayer23=player;local game={JobId=job,PlaceId=place}
 local getResult25={GetPlayers=function() return players end}
 local v1317={Heartbeat={Connect=function(_,fn) return {Disconnect=function(self) self.disconnected=true end,fire=fn} end}}
'''+service+r'''
 return tbl358.localClients()
end
local a=create(alice,"same",10);local b=create(bob,"same",10);create(foreign,"other",10)
a.tick();assert(a.isAlly(bob) and b.isAlly(alice),"idle loaded clients must be recognized without a worker/queue")
assert(not a.isAlly(foreign) and not a.isAlly(inactive))
local count=reads;for i=1,1000 do assert(a.isAlly(bob)) end;assert(reads==count,"hot proximity checks must use the cached presence")
local filename="sentinel/.cache/blade_local_clients/p_2.json"
disk[filename].placeId=11;a.tick();assert(not a.isAlly(bob))
disk[filename].placeId=10;disk[filename].at=now+20;a.tick();assert(not a.isAlly(bob),"future records cannot mark enemies as local")
b.tick();a.tick();assert(a.isAlly(bob))
now+=9;assert(not a.isAlly(bob),"crashed accounts expire even if active=true was left on disk")
b.tick();a.tick();assert(a.isAlly(bob))
b.stop();a.tick();assert(not a.isAlly(bob) and not b.isAlly(alice))
local w=writes;b.stop();assert(writes==w,"unload cleanup is idempotent")
players={alice};a.tick();assert(next(a.members)==1 and a.checked[2]==nil)
''')

    def test_menu_masks_coalesce_events_cap_frame_work_and_release_destroyed_ui(self):
        masks=self.part('        local menuMasks={', '        a11260.Maid:Give(v2420.Heartbeat:Connect(function()')
        queue=self.part('local function __frameWorkQueue()', 'local __UI_FILES = {')
        self.run_luau(r'''
local task={wait=function() end};local flag135=true;local Toggles16={StreamerMode={Value=true}}
local function signal()
 local handlers={};local s={}
 s.Connect=function(_,fn) local key={};handlers[key]=fn;return {Disconnect=function() handlers[key]=nil end} end
 s.fire=function() local copy=table.clone(handlers);for key,fn in copy do if handlers[key] then fn() end end end
 s.count=function() local n=0;for _ in handlers do n+=1 end;return n end
 return s
end
local function object()
 local changed=signal();local destroyed=signal();local added=signal();local value="Original";local writes=0
 local result={Parent=true,Destroying=destroyed,DescendantAdded=added,GetPropertyChangedSignal=function() return changed end,GetChildren=function() return {} end}
 setmetatable(result,{__index=function(_,key) if key=="Text" then return value elseif key=="writes" then return writes end end,__newindex=function(t,key,v) if key=="Text" then writes+=1;value=v;changed.fire() else rawset(t,key,v) end end})
 return result,changed,destroyed
end
'''+queue+masks+r'''
local label,changed,destroyed=object()
menuMasks.bind(label,"Text",function() return "Alias" end)
for i=1,1000 do menuMasks.bind(label,"Text",function() return "Alias" end);changed.fire() end
assert(changed.count()==1 and destroyed.count()==1 and label.writes==0,"binding/changing must queue, never recursively rewrite")
menuMasks.flush();assert(label.Text=="Alias" and label.writes==1 and next(menuMasks.pending)==nil)
-- Simulate Roblox enforcing the original text from its own callback.
local enforce=changed:Connect(function() if label.Text~="Original" then label.Text="Original" end end)
changed.fire();local before=label.writes;menuMasks.flush();assert(label.writes-before==2,"one bounded attempt, not an event feedback loop")
enforce:Disconnect();destroyed.fire();assert(changed.count()==0 and destroyed.count()==0 and menuMasks.entries[label]==nil and menuMasks.pending[label]==nil)
for i=1,500 do
 local item,_,death=object();menuMasks.bind(item,"Text",function() return "x" end);menuMasks.watchRoot(item,function() end);death.fire()
end
assert(next(menuMasks.entries)==nil and next(menuMasks.roots)==nil,"destroyed menus cannot accumulate listeners")
local labels={}
for i=1,100 do local item=object();table.insert(labels,item);menuMasks.bind(item,"Text",function() return "Alias" end) end
menuMasks.flush();local updates=0;for _,item in labels do updates+=item.writes end
assert(updates>0 and updates<=32,"one frame must have bounded work")
menuMasks.clear();assert(next(menuMasks.entries)==nil and next(menuMasks.pending)==nil)
for _,item in labels do assert(item.Text=="Original") end
''')


    def test_charge_reports_success_before_release_decay_and_yields_to_blade_owner(self):
        charge=self.part('          local chargeUntil = function(a1624, a2192)', '          a1593.State.mana = {')
        self.run_luau(r'''
local clock=0;local tick=function() return clock end
local mana={Value=0};local charging=false;local charges=0;local releases=0
local character={FindFirstChildWhichIsA=function() return nil end,FindFirstChild=function(_,key) if key=="Mana" then return mana elseif key=="Charge" then return charging end end}
local LocalPlayer15={Character=character};local a1593={State={}};local canUse=function() return true end
local Toggles7={};local tbl220={false};local flag40=false
local decharge=function() releases+=1;charging=false;mana.Value-=0.7 end
local fn438=function(seconds) clock+=seconds end
local charge=function() charges+=1;charging=true;mana.Value=math.min(95,mana.Value+20);clock+=0.1 end
'''+charge+r'''
assert(chargeUntil(95,function() return true end)==true)
assert(mana.Value<94.9 and releases==1,"success must survive decharge and its delay")
a1593.State.bladeManaOwner=true;mana.Value=0;local before=charges
assert(chargeUntil(95)==false and charges==before,"background calls must yield to Blade")
assert(chargeUntil(95,function() return true end)==true and charges>before,"owned Blade charge is allowed")
a1593.State.bladeManaOwner=false;mana.Value=0
charge=function() charges+=1;charging=true;mana.Value=10;a1593.State.bladeManaOwner=true end
before=charges;assert(chargeUntil(95)==false and charges==before+1,"an already-running background charge must exit on ownership")
''')

    def test_mana_punch_releases_charge_before_four_hits_even_after_mana_decays(self):
        punch=self.part('__L3.bladeManaPunch=function', '__L3.bladeXPShriekers=function')
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end};local __L3={bladeStatus=function() end}
local mana={Value=10};local tool=true;local charging=false;local releaseAt;local cooldown=0;local attacks=0;local charges=0
local hum={UnequipTools=function() tool=false end}
local character={FindFirstChildOfClass=function() return hum end,FindFirstChildWhichIsA=function() return tool end,FindFirstChild=function(_,key) if key=="Mana" then return mana elseif key=="Charge" then return charging end end}
local LocalPlayer21={Character=character};local a1723={State={}}
local fn576=function() return clock<cooldown end
local task={wait=function(seconds) clock+=math.max(0.05,math.ceil((seconds or 0)/0.05)*0.05);if releaseAt and clock>=releaseAt then charging=false;releaseAt=nil end end}
a1723.State.mana={chargeUntil=function(target,active)
 assert(target==95 and active() and a1723.State.bladeManaOwner);charges+=1
 charging=true;mana.Value=94.3;return true -- The real controller reached 95 before releasing/returning.
end,decharge=function() if charging and not releaseAt then releaseAt=clock+0.15 end end}
local fn577=function() assert(not charging and not tool and not fn576() and a1723.State.bladeManaOwner);attacks+=1;cooldown=clock+0.35;mana.Value-=10 end
'''+punch+r'''
assert(__L3.bladeManaPunch(function() return true end) and attacks==4 and charges==1)
assert(not a1723.State.bladeManaOwner)
mana.Value=10;a1723.State.mana.chargeUntil=function() mana.Value=60;return false end
assert(not __L3.bladeManaPunch(function() return true end) and attacks==4 and not a1723.State.bladeManaOwner)
a1723.State.mana.chargeUntil=function() error("charge failed") end
assert(not __L3.bladeManaPunch(function() return true end) and not a1723.State.bladeManaOwner)
''')

    def test_decharge_releases_held_key_even_after_remote_becomes_available(self):
        decharge=self.part('          local decharge = function()', '          local canUse = function()')
        self.run_luau(r'''
local keyHeld=true;local releases=0;local fired=0;local v739="boolean"
local fn436=function() if keyHeld then keyHeld=false;releases+=1 end end
local v738={FireServer=function(_,value) assert(value==false);fired+=1 end}
'''+decharge+r'''
decharge();assert(not keyHeld and releases==1 and fired==1)
decharge();assert(releases==1 and fired==2)
''')


    def test_rot_counts_only_tracked_jail_after_carry_release_and_settles_once(self):
        counter=self.part('        local rotQueueOnCount\n', '        local Maid9 = a1849.Maid')
        ledger=self.part('        rotDelivery.begin=function(', '        local fn703 = function(')
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end};local active=true;local carrying=true;local jail=false
local v1346=0;local saved;local updated=0;local fn692=function() end
local qResult4={set=function(key,value) assert(key=="rotbot_count");saved=value end}
local victim={};local other={};local rotCarriedCharacter=victim
local v1345={HasTag=function(_,character,tag) return character==victim and jail end}
local rotWalkStatus={SetText=function() end};local fn697=function() return active end;local fn699=function() return carrying end
local onWait=function() end;local task={wait=function(dt) clock+=dt;onWait() end}
'''+counter+ledger+r'''
rotQueueOnCount=function() updated+=1 end
local tx=rotDelivery.begin(victim);assert(tx and rotDelivery.begin(other)==nil)
-- A dialogue success and a dropped carry alone are not evidence of prison.
carrying=false;assert(not rotDelivery.await(tx) and v1346==0 and saved==nil)
carrying=true;rotCarriedCharacter=victim;tx=rotDelivery.begin(victim)
local start=clock
onWait=function()
 if clock-start>=2 then tx.jailed=true end -- Jailed event can be transient before rejoin.
 if clock-start>=2.4 then carrying=false end
end
assert(rotDelivery.await(tx) and v1346==1 and saved==1 and updated==1 and clock-start>=2.9)
assert(not rotDelivery.await(tx) and not fn693(victim) and v1346==1,"dialogue replay and duplicate tag cannot count twice")
assert(rotDelivery.begin(victim)==nil)
rotCarriedCharacter=other;carrying=true;local tx2=rotDelivery.begin(other);active=false
assert(not rotDelivery.await(tx2) and v1346==1,"Stop must not presume pending delivery")
assert(rotDelivery.pending==tx2,"menu pause must keep pending delivery evidence")
active=true;carrying=false;tx2.jailed=true;onWait=function() end
assert(rotDelivery.await(tx2) and v1346==2,"confirmed pending delivery is counted once on resume")
''')

    def test_rot_jail_event_does_not_count_master_or_unrelated_players(self):
        counter=self.part('        local rotQueueOnCount\n', '        local Maid9 = a1849.Maid')
        event=self.part('        Maid9:Give(v1345:GetInstanceAddedSignal("Jailed")', '        local fn694 = function()')
        self.run_luau(r'''
local v1346=0;local qResult4={set=function() end};local fn692=function() end
local callback;local localCharacter={};local victim={};local stranger={};local LocalPlayer24={}
local getResult26={GetPlayerFromCharacter=function(_,c) return c==localCharacter and LocalPlayer24 or {} end}
local tbl365={true};local carrier=true;local fn670=function() return carrier end
local v1345={GetInstanceAddedSignal=function() return {Connect=function(_,fn) callback=fn;return {} end} end}
local Maid9={Give=function() end}
'''+counter+event+r'''
rotDelivery.pending={character=victim}
callback(stranger);assert(v1346==0 and not rotDelivery.pending.jailed)
callback(victim);assert(v1346==0 and rotDelivery.pending.jailed,"receiver event only marks its tracked transaction")
callback(localCharacter);assert(v1346==0,"receiver being jailed is not a successful delivery")
carrier=false;callback(stranger);assert(v1346==0,"a supplier cannot count someone else's jail")
callback(localCharacter);callback(localCharacter);assert(v1346==1,"supplier own tag counts once")
''')

    def test_rot_queue_resumes_stage_count_after_menu_without_using_lifetime_total(self):
        join=self.part('        local function queueJoin()', '        local function queueLeave(')
        oncount=self.part('        rotQueueOnCount=function()', '        -- Blade/Sigil P2')
        self.run_luau(r'''
local rotSupplier={};local rotQueueEntry;local savedStage=7;local runId="run-1";local persisted
local a1849={State={bladeRotProgress=function() return savedStage,runId end,onRotDeliveryConfirmed=function(n) savedStage=n end}}
local previous={state="left",jobId="same",runId="run-1",progress=7,joined=10}
local MResult={available=function() return true end,readJson=function() return previous end}
local fn670=function() return true end;local fn672=function() error("unexpected queue error") end
local Library9={Toggles={BlatantMode={Value=true}}};local LocalPlayer24={UserId=1,Name="Receiver"}
local game={JobId="same"};local rotQueuePath="queue.json";local v1346=40
local DateTime={now=function() return {UnixTimestampMillis=100} end};local os={time=function() return 100 end,clock=function() return 100 end}
local queueWrite=function(entry) persisted=table.clone(entry);return true end
local qResult4={set=function() end,remove=function() end};local rotQueueQuietSince=0;local fn692=function() end
local rotQueueOwnerId=1;local rotQueueOnCount
'''+join+oncount+r'''
assert(queueJoin() and rotQueueEntry.progress==7 and rotQueueEntry.baseline==33)
v1346+=1;rotQueueOnCount();assert(rotQueueEntry.progress==8 and savedStage==8 and persisted.progress==8)
previous=table.clone(rotQueueEntry);previous.state="left";rotQueueEntry=nil
assert(queueJoin() and rotQueueEntry.progress==8 and rotQueueEntry.baseline==33,"manual menu resumes 8/16, not zero or lifetime 41")
rotQueueEntry=nil;savedStage=nil;runId="run-2"
assert(queueJoin() and rotQueueEntry.progress==0 and rotQueueEntry.baseline==41,"new runs cannot inherit a previous run's count")
rotQueueEntry=nil;runId="run-1";previous.jobId="other"
assert(queueJoin() and rotQueueEntry.progress==0,"foreign server queue records cannot restore this count")
''')


    def test_blade_core_yields_when_stage_returns_immediately(self):
        loop=self.part('          while tbl303[1] do\n            local phase = tbl308[1].phase', '        __L3.vector318 =')
        loop=loop.rsplit('\n        end',1)[0]
        self.run_luau(r'''
local tbl303={true};local tbl308={{phase="B1_SWORD"}};local attempts=0;local waits=0;local seconds=0
local __L3={bladeEnabled=function() return true end,bladeStep=function(phase) assert(phase=="B1_SWORD");attempts+=1 end}
local task={wait=function(dt) assert(dt>=0.1);waits+=1;seconds+=dt;if waits>=200 then tbl303[1]=false end end}
'''+loop+r'''
assert(attempts==200 and waits==200 and seconds>=19.99,"an immediate retry must yield rather than spin until crash")
''')

    def test_wrap_inspection_cache_expires_is_bounded_and_does_not_retain_captures(self):
        helper=self.part('          local wrapChecks=setmetatable', '          local v140\n')
        self.run_luau(r'''
local clock=0;local os={clock=function() return clock end};local RunService={};local reads=0;local captured={}
local uiRoot={};local packages={};local game={GetService=function() return uiRoot end,FindFirstChild=function() return packages end}
local scriptFor={};local getfenv=function(fn) return {script=scriptFor[fn]} end
local typeof=function(value) return type(value)=="table" and value.instance and "Instance" or type(value) end
local getupvalues=function(fn) reads+=1;return captured[fn] or {} end
'''+helper+r'''
local target=function() end;captured[target]={RunService};assert(wrappedRunServiceOnly(target))
for i=1,1000 do assert(wrappedRunServiceOnly(target)) end;assert(reads==1)
captured[target]={RunService,{large="graph"}};clock=1.1
assert(not wrappedRunServiceOnly(target) and reads==2,"cache must re-evaluate mutable captures")
for i=1,2000 do local fn=function() return i end;captured[fn]={{large="graph"}};assert(not wrappedRunServiceOnly(fn)) end
assert(wrapCheckCount<=512)
for _,entry in wrapChecks do
 assert(type(entry.at)=="number" and type(entry.blocked)=="boolean")
 local n=0;for _ in entry do n+=1 end;assert(n==2,"cache must retain decisions only")
end
local ui=function() end
scriptFor[ui]={instance=true,IsA=function() return false end,IsDescendantOf=function(_,root) return root==uiRoot end}
local before=reads;assert(engineUI(ui) and reads==before,"Roblox UI must bypass expensive capture inspection")
scriptFor[ui]={instance=true,IsA=function(_,class) return class=="CoreScript" end}
assert(engineUI(ui))
scriptFor[ui]={instance=true,IsA=function() return false end,IsDescendantOf=function(_,root) return root==packages end}
assert(engineUI(ui),"CorePackages UI modules must bypass capture inspection too")
scriptFor[ui]=nil;assert(not engineUI(ui))
''')


    def test_ui_queue_is_fair_bounded_reentrant_and_discards_destroyed_work(self):
        queue=self.part('local function __frameWorkQueue()', 'local __UI_FILES = {')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end}
"""+queue+r"""
local q=__frameWorkQueue();local order={}
local hot
hot=function() table.insert(order,"hot");q.push("hot",hot);q.step() end
q.push("hot",hot)
for i=1,100 do q.push(i,function() table.insert(order,i) end) end
q.step();assert(#order==32 and order[1]=="hot" and order[32]==31)
q.step();q.step();q.step()
assert(order[101]==100 and order[102]=="hot","hot properties cannot starve quiet rows")
q.clear();local calls=0
for i=1,1000 do q.push("same",function() calls+=1 end) end
q.step();assert(calls==1 and next(q.entries)==nil)
-- Removing the old tail must not allow newly enqueued work to run in this same frame.
q.push("first",function() q.remove("last");q.push("new",function() calls+=100 end) end)
q.push("last",function() error("removed") end)
q.step();assert(calls==1 and q.entries.new)
q.step();assert(calls==101)
for i=1,1000 do q.push(i,function() error("destroyed work") end);q.remove(i) end
assert(q.head==nil and q.tail==nil and next(q.entries)==nil)
-- File/UI callbacks that yield must not permit a second Heartbeat to enter the same queue.
q.push("slow",function() coroutine.yield();calls+=1 end)
local co=coroutine.create(q.step);assert(coroutine.resume(co));assert(q.busy)
q.push("next",function() calls+=1 end);q.step();assert(calls==101)
assert(coroutine.resume(co));assert(not q.busy and calls==102)
q.step();assert(calls==103)
q.push("bad",function() error("UI replaced while applying") end);q.step();assert(not q.busy)
-- Time limit counts application time, not just the number of entries.
for i=1,10 do q.push(i,function() clock+=0.003;calls+=1 end) end
q.step();assert(calls==104)
q.close();q.push("closed",function() calls+=1 end);q.step();assert(calls==104 and next(q.entries)==nil)
""")

    def test_deferred_text_events_and_stat_names_do_not_chain_writes(self):
        queue=self.part('local function __frameWorkQueue()', 'local __UI_FILES = {')
        masks=self.part('        local menuMasks={', '        a11260.Maid:Give(v2420.Heartbeat:Connect(function()')
        stat=self.part('        local fn1143 = function(a11295)', '        local fn1145 = function()')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local deferred={};local useDeferred=true
local function signal()
 local listeners={};local s={}
 s.Connect=function(_,fn)
  local key={};listeners[key]=fn;return {Disconnect=function() listeners[key]=nil end}
 end
 s.fire=function()
  for key,fn in table.clone(listeners) do
   if useDeferred then table.insert(deferred,function() if listeners[key] then fn() end end)
   elseif listeners[key] then fn() end
  end
 end
 s.count=function() local n=0;for _ in listeners do n+=1 end;return n end
 return s
end
local function drain()
 local passes=0
 while #deferred>0 do
  passes+=1;assert(passes<10,"property events recursively wrote more Text")
  local batch=deferred;deferred={};for _,run in batch do run() end
 end
end
local function label(initial)
 local changed,death,added=signal(),signal(),signal();local text=initial;local writes=0
 local obj={Parent=true,Destroying=death,DescendantAdded=added,GetChildren=function() return {} end,
  IsA=function(_,name) return name=="TextLabel" end,GetPropertyChangedSignal=function() return changed end}
 setmetatable(obj,{__index=function(_,k) if k=="Text" then return text elseif k=="writes" then return writes end end,
  __newindex=function(t,k,v) if k=="Text" then text=v;writes+=1;changed.fire() else rawset(t,k,v) end end})
 return obj,changed,death
end
local flag135=true;local Toggles16={StreamerMode={Value=true}}
local task={wait=function() end}
local fn1137=function(text) return text=="RealUser" end
local fn1123=function() return "Alias" end
"""+queue+masks+stat+r"""
local mine,changed,death=label("RealUser");fn1143(mine)
local other=label("SomeoneElse");fn1143(other)
menuMasks.flush();drain();assert(mine.Text=="Alias" and mine.writes==1 and other.writes==0)
menuMasks.flush();drain();assert(mine.writes==1,"our deferred event must not rewrite unchanged text")
local enforce=changed:Connect(function() if mine.Text~="RealUser" then mine.Text="RealUser" end end)
mine.Text="RealUser";drain()
for i=1,200 do
 local before=mine.writes;menuMasks.flush();drain()
 assert(mine.writes-before==2,"exactly one mask attempt and one engine rewrite per frame")
end
enforce:Disconnect()
local before=mine.writes
mine.Text="RealUser";death.fire();drain();menuMasks.flush()
assert(mine.writes==before+1 and menuMasks.entries[mine]==nil and changed.count()==0)
-- Turning off the feature while a read yields cannot write an obsolete alias later.
local slow=label("RealUser")
menuMasks.bind(slow,"Text",function() coroutine.yield();return "Alias" end)
local worker=coroutine.create(menuMasks.flush);assert(coroutine.resume(worker))
menuMasks.clear();assert(coroutine.resume(worker));assert(slow.Text=="RealUser")
assert(next(menuMasks.pending)==nil and next(menuMasks.entries)==nil)
""")

    def test_esc_reopen_reuses_one_worker_and_does_not_wait_for_rendering(self):
        scan=self.part('        local fn1142 = function()', '        local fn1143 = function(')
        self.run_luau(r"""
local flag134=false;local flag135=false;local Toggles16={StreamerMode={Value=true}}
local scheduled={};local starts=0;local scans=0
local task={wait=function() coroutine.yield() end,spawn=function(fn)
 starts+=1;local co=coroutine.create(fn);table.insert(scheduled,co);assert(coroutine.resume(co))
end}
local v2420={RenderStepped={Wait=function() error("rendering is disabled in background") end}}
local root={FindFirstChild=function(self) return self end};local v2426=root
local fn1136=function() return root end
local fn1138=function() scans+=1 end;local fn1139=function() end;local fn1140=function() end;local fn1141=function() end
"""+scan+r"""
fn1142();assert(starts==1 and flag134 and flag135)
for i=1,200 do
 flag135=false -- MenuClosed
 fn1142() -- reopen before the old worker's next scheduled tick
 assert(starts==1 and flag135)
 assert(coroutine.resume(scheduled[1]))
end
assert(scans==200)
flag135=false;assert(coroutine.resume(scheduled[1]));assert(not flag134)
fn1142();assert(starts==2)
Toggles16.StreamerMode.Value=false;assert(coroutine.resume(scheduled[2]));assert(not flag134)
""")

    def test_scramble_leaderboard_paints_outside_text_callbacks_and_cleans_up(self):
        queue=self.part('local function __frameWorkQueue()', 'local __UI_FILES = {')
        painters=self.part('        local tbl549 = {}', '        a11194.State.leaderboardLabelFor = function(')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local heart;local cleanup={}
local v2233={Heartbeat={Connect=function(_,fn) heart=fn;return {} end}}
local active=true;local LocalPlayer32={};local flag119=false
local a11194={Maid={Give=function(_,v) table.insert(cleanup,v) end},State={
 scrambleOn=function() return active end,maskUser=function() return "AliasUser" end,
 maskRogue=function() return "AliasCharacter" end}}
local fn1036=function() return "RealCharacter" end
local function signal()
 local list={};local s={Connect=function(_,fn) local key={};list[key]=fn;return {Disconnect=function() list[key]=nil end} end}
 s.fire=function() for key,fn in table.clone(list) do if list[key] then fn() end end end
 s.count=function() local n=0;for _ in list do n+=1 end;return n end
 return s
end
local changed,death=signal(),signal();local text="RealCharacter";local writes=0
local label={Parent=true,MouseEnter=signal(),MouseLeave=signal(),Destroying=death,GetPropertyChangedSignal=function() return changed end}
setmetatable(label,{__index=function() return text end,__newindex=function(_,k,v) assert(k=="Text");text=v;writes+=1;changed.fire() end})
"""+queue+painters+r"""
fn1059({},label);assert(writes==0);heart();assert(text=="AliasCharacter")
label.MouseEnter.fire();heart();assert(text=="AliasUser")
label.MouseLeave.fire();heart();assert(text=="AliasCharacter")
local enforce=changed:Connect(function() if text~="RealCharacter" then label.Text="RealCharacter" end end)
label.Text="RealCharacter"
for i=1,100 do local n=writes;heart();assert(writes-n<=2) end
enforce:Disconnect();death.fire();heart()
assert(changed.count()==0 and label.MouseEnter.count()==0 and tbl549[label]==nil and next(leaderboardPaint.entries)==nil)
""")

    def test_coroutine_inspection_uses_scalar_reads_and_survives_executor_reentry(self):
        core=self.part('local fn44 = function()', '    tbl44.f = function()')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local __bootSession={};local tbl44={};local hooks={}
local fire=function() end;local destroy=function() end;local workspace={Destroy=destroy}
local Instance={new=function() return {FireServer=fire} end};local RunService={}
local services={Players={LocalPlayer={CharacterAdded={Connect=function() return {Disconnect=function() end} end}}},RunService=RunService}
tbl44.a=function() return services end;tbl44.e=function() return {keyHandlerEnabled=function() return false end} end
local getgenv=function() return {} end;local checkcaller=function() return false end
local newcclosure=function(fn) return fn end;local islclosure=function() return true end
local hookfunction=function(target,replacement) local old=hooks[target] or target;hooks[target]=replacement;return old end
local task={spawn=function(fn) fn() end,wait=function() end}
local captured={};local sizes={};local infoReads=0;local scalarReads=0;local bulkReads=0;local reenter=false;local throw=false
local getupvalues=function(fn) bulkReads+=1;return captured[fn] or {} end
local debug={info=function() return "caller" end,getinfo=function(fn)
 infoReads+=1
 if reenter then local nested=hooks[coroutine.wrap](function() return "nested" end);assert(nested()=="nested") end
 if throw then error("executor unavailable") end
 return {nups=sizes[fn] or 0}
end,getupvalue=function(fn,index) scalarReads+=1;return captured[fn][index] end}
local game={GetService=function() return {} end,FindFirstChild=function() return {} end}
local getfenv=function() return {} end
"""+core+r"""
fn44()("Normal")
local target=function() return "blocked body" end;captured[target]={RunService};sizes[target]=1
assert(hooks[coroutine.wrap](target)()==nil)
for i=1,1000 do assert(hooks[coroutine.wrap](target)()==nil) end
assert(infoReads==1 and scalarReads==1 and bulkReads==0)
local ordinary=function() return "ordinary" end;sizes[ordinary]=10000
assert(hooks[coroutine.wrap](ordinary)()=="ordinary" and scalarReads==1 and bulkReads==0)
clock=2;captured[target]={{}};assert(hooks[coroutine.wrap](target)()=="blocked body")
clock=4;reenter=true;assert(hooks[coroutine.wrap](ordinary)()=="ordinary");reenter=false
clock=6;throw=true;assert(hooks[coroutine.wrap](ordinary)()=="ordinary" and bulkReads==1)
throw=false;clock=8;assert(hooks[coroutine.wrap](ordinary)()=="ordinary","inspection failure cannot leave the reentry lock stuck")
__bootSession.coreCleanup();assert(hooks[coroutine.wrap]==coroutine.wrap)
""")

    def test_legacy_progression_stages_yield_on_immediate_failure_too(self):
        loop=self.part('          while tbl303[1] do\n            local phase = tbl308[1].phase', '        __L3.vector318 =')
        loop=loop[:loop.rfind('        end')]
        self.run_luau(r"""
local tbl303={true};local tbl308={{phase="P6"}};local calls=0;local waits=0
local __L3={bladeEnabled=function() return true end,fn633=function() calls+=1 end}
local task={wait=function(dt) assert(dt==0.1);waits+=1;if waits==100 then tbl303[1]=false end end}
"""+loop+r"""
assert(waits==100 and calls==100)
""")

    def test_leaderboard_scan_is_single_flight_budgeted_and_cancellable(self):
        scan=self.part('        local fn1067 = function()', '        local fn1068 = function()')
        guard=self.part('        local flag124 = false', '        local fn1071 = function()')
        self.run_luau(r"""
local scans=0;local inspected=0;local waits=0;local scheduled={};local flag119=false;local stop=false
local task={wait=function()
 waits+=1;if stop then flag119=true end
 coroutine.yield()
end,spawn=function(fn) local co=coroutine.create(fn);table.insert(scheduled,co);assert(coroutine.resume(co)) end}
local gui={Parent=true,WaitForChild=function(self) return self end}
local LocalPlayer32={FindFirstChildOfClass=function() return gui end}
local getreg_=function() scans+=1;local t={};for i=1,2000 do t[i]=function() return i end end;return t end
local v2238=function() return {} end;local v2242=function() end
local getfenv_=function() inspected+=1;return {} end;local v2239=function() return true end
local v2241=function() return {} end;local v2240
local collectgarbage=function() error("must not force a full heap collection for leaderboard lookup") end
"""+scan+guard+r"""
fn1070();for i=1,100 do fn1070() end;assert(#scheduled==1 and flag124)
local co=scheduled[1]
while coroutine.status(co)~="dead" do
 local before=inspected;assert(coroutine.resume(co));assert(inspected-before<=64,"scan must yield between bounded batches")
end
assert(scans==1 and inspected==2000 and waits>20 and not flag124)
stop=true;fn1070();local cancelled=scheduled[2]
while coroutine.status(cancelled)~="dead" do assert(coroutine.resume(cancelled)) end
assert(not flag124 and inspected==2000,"unload stops the scan before inspecting more closures")
""")
        startup=self.part('        local fn1071 = function()', '        a11194.Maid:Give(function()\n          flag119 = true')
        self.assertNotIn('pcall(fn1067)',startup)

    def test_presence_refresh_does_not_stack_when_executor_file_write_yields(self):
        service=self.part('      tbl358.localClients=function()', '      tbl358.channel = function(')
        self.run_luau(r"""
local tbl358={};local LocalPlayer23={UserId=1};local game={JobId="job",PlaceId=1}
local getResult25={GetPlayers=function() return {LocalPlayer23} end};local pending=false;local writes=0;local fail=false
local v1317={Heartbeat={Connect=function(_,fn) return {fire=fn,Disconnect=function() end} end}}
local readJson=function() return nil end
local writeJson=function() writes+=1;if pending then coroutine.yield() end;if fail then error("disk error") end;return true end
"""+service+r"""
local clients=tbl358.localClients();assert(writes==1)
pending=true;local co=coroutine.create(clients.tick);assert(coroutine.resume(co))
assert(clients.busy)
for i=1,200 do clients.connection.fire(1) end
assert(writes==2,"only one executor write may remain in flight")
pending=false;assert(coroutine.resume(co));assert(not clients.busy)
fail=true;assert(not pcall(clients.tick));assert(not clients.busy)
fail=false;clients.tick();assert(writes==4)
""")

    def test_blade_autosave_has_one_inflight_write_and_recovers_after_error(self):
        save=self.part('        bladePrefs.save=function()', '        bladePrefs.restore=function()')
        self.run_luau(r"""
local bladePrefs={ready=true,file="settings",snapshot=function() return {} end}
local a11542={State={}};local version=1;local writes=0;local pause=true;local fail=false
local game={GetService=function() return {JSONEncode=function() return tostring(version) end} end}
local writefile=function() writes+=1;if pause then coroutine.yield() end;if fail then error("disk") end end
local warn=function() end
"""+save+r"""
local co=coroutine.create(bladePrefs.save);assert(coroutine.resume(co));assert(bladePrefs.saving)
for i=1,200 do bladePrefs.save() end;assert(writes==1)
pause=false;assert(coroutine.resume(co));assert(not bladePrefs.saving and bladePrefs.last=="1")
version=2;fail=true;assert(not bladePrefs.save() and not bladePrefs.saving and bladePrefs.last=="1")
fail=false;assert(bladePrefs.save() and bladePrefs.last=="2")
bladePrefs.save();assert(writes==3,"unchanged settings should not be rewritten")
""")

    def test_own_leaderboard_alias_is_idempotent_and_preserves_hover_name_changes(self):
        binding=self.part('                menuMasks.bind(v2585,"Text",function()', '                local fn1260=')
        self.run_luau(r"""
local alias="RealUser 100%";local LocalPlayer33={Name="RealUser",DisplayName="Real Display"}
local v2585={Text="@RealUser [rank]"};local fn1123=function() return alias end
local reader;local menuMasks={entries={[v2585]={}},bind=function(_,_,read) reader=read end}
"""+binding+r"""
local function flush() local value=reader();if value then v2585.Text=value end end
for i=1,1000 do flush() end
assert(v2585.Text=="@RealUser 100% [rank]","alias containing username cannot grow on every change event")
alias="Next";flush();assert(v2585.Text=="@Next [rank]","changing alias updates the last rendered name")
v2585.Text=alias;flush();alias="Third";flush();assert(v2585.Text=="Third","hovered name must follow alias changes too")
v2585.Text="Real Display";flush();assert(v2585.Text=="Third")
v2585.Text="Character Name";flush();assert(v2585.Text=="Character Name","unrelated character text stays unchanged")
""")


    def test_rot_pickup_prioritizes_nearest_eligible_alt_without_p14_detour(self):
        collect=self.part('        local function rotCollectSelected()', '        local rotWalkElapsed =')
        self.run_luau(VEC+r"""
local clock=10;local os={clock=function() return clock end};local active=true;local carrying=false
local fn697=function() return active end;local fn699=function() return carrying end
local rotDelivery={counted={},await=function() error("no pending transaction") end}
local rotPickupRetry=setmetatable({}, {__mode="k"});local players={};local names={}
local function add(name,id,distance,opts)
 opts=opts or {};local tags={Unconscious=opts.down~=false,Jailed=opts.jailed}
 local character={tags=tags,FindFirstChild=function(_,key) if key=="Carried" then return opts.carried end end}
 local p={Name=name,UserId=id,Character=character,Parent=true,distance=distance}
 players[name]=p;table.insert(names,name);return p
end
local far=add("Far",1,30);local jailed=add("Jailed",2,1,{jailed=true})
local near=add("Near",3,3);local carried=add("Carried",4,1,{carried={IsA=function() return false end}})
local asleep=add("Awake",5,1,{down=false});local counted=add("Counted",6,1,{jailed=true})
local queued=add("Receiver",7,1);rotDelivery.counted[counted.Character]=true
local queueRoster=function() return {{userId=7}} end
local fn698=function() return names end
local rotTargetDown=function(c) return c and c.tags.Unconscious end
local v1345={HasTag=function(_,c,tag) return c.tags[tag] end}
local MResult={playerByName=function(name) return players[name] end,distanceTo=function(p) return p.distance end,
 rootOf=function(p) return {Position=Vector3.new(p.distance,0,0)} end}
local a1849={State={bladeRunAlts={},bladeReceiverAtP14=true}}
local rotSupplier={receiverPoint=Vector3.new(0,0,0)};local sResult10={root=function() return {Position=Vector3.new(10,0,0)} end}
local picked={};local delivered={};local walks=0;local failPickup=false
local fn702=function(p) table.insert(picked,p.Name);carrying=not failPickup;return not failPickup end
local fn703=function(name) table.insert(delivered,name);carrying=false end
local rotWalkStatus={SetText=function() end}
local rotWalkTo=function(destination,allowed)
 walks+=1;assert(allowed());local position=destination()
 for _,p in players do if position.X==p.distance then p.distance=3 end end
 return true
end
"""+collect+r"""
rotCollectSelected();assert(picked[1]=="Near" and delivered[1]=="Near" and walks==0,"near downed alt takes priority over return to P14")
-- A failed nearest pickup yields the next attempt to another ready target.
failPickup=true;rotCollectSelected();assert(rotPickupRetry[near.Character]==12)
failPickup=false;rotCollectSelected();assert(delivered[2]=="Far" and walks==1)
-- With no ready victim, return to P14 so suppliers can see the receiver again.
for _,p in players do p.Character.tags.Unconscious=false end
rotCollectSelected();assert(walks==2)
""")

    def test_rot_carry_polls_confirmation_quickly_without_spamming_remote(self):
        pickup=self.part('        local fn702 = function(', '        local rotWalkStatus =')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local active=true;local grabbing=false;local sent={}
local character={tags={Unconscious=true},FindFirstChild=function() end};local player={Parent=true,Character=character}
local rotDelivery={begin=function() end};local rotCarriedCharacter;local fn697=function() return active end;local fn699=function() return grabbing end
local v1345={HasTag=function(_,c,tag) return c.tags[tag] end};local distance=3
local MResult={distanceTo=function() return distance end}
local fn700=function() return {FireServer=function() table.insert(sent,clock) end} end
local onWait=function() if clock>=0.1 then grabbing=true end end
local task={wait=function(dt) clock+=dt;onWait() end}
"""+pickup+r"""
assert(fn702(player) and clock<=0.11 and #sent==1 and rotCarriedCharacter==character)
clock=0;grabbing=false;sent={};onWait=function() end
assert(not fn702(player) and #sent<=17)
for i=2,#sent do assert(sent[i]-sent[i-1]>=0.2499,"carry remote retry interval must stay at least 250ms") end
-- Respawning during pickup must not bind a newly spawned victim to the old carry.
clock=0;sent={};onWait=function() player.Character={};grabbing=true end
assert(not fn702(player) and #sent==1)
player.Character=character;grabbing=false;clock=0;sent={};onWait=function() end
character.tags.Unconscious=false;assert(not fn702(player) and #sent==0)
character.tags.Unconscious=true;distance=5;assert(not fn702(player) and #sent==0)
""")

    def test_rot_dialogue_finishes_on_authoritative_jail_without_waiting_for_silence(self):
        delivery=self.part('        local fn703 = function(', '        local function rotTargetDown(')
        self.run_luau(VEC+r"""
local clock=0;local os={clock=function() return clock end};local active=true;local carrying=true;local jail=false
local root={Parent=true,Position=Vector3.new(0,0,0)};local officer={Name="Bounty Officer",GetFullName=function() return "Renova" end,
 FindFirstChild=function() return root end,FindFirstChildWhichIsA=function() return {} end}
local fn701=function() return officer,0 end;local sResult10={root=function() return root end};local num407=9
local rotWalkStatus={SetText=function() end};local rotDestinationMarker={};local fireclickdetector_5=true
local fn697=function() return active end;local fn699=function() return carrying end
local victim={};local rotCarriedCharacter=victim;local tx={character=victim,jailed=false}
local v1345={HasTag=function(_,c) assert(c==victim);return jail end}
local closed=0;local confirmed=0;local tbl364={};local str52="looking for a job"
local fn672=function() end;local print=function() end
local rotDelivery={begin=function(c) assert(c==victim);return tx end,
 await=function(t) assert(t==tx and t.jailed and not carrying);confirmed+=1;return true end}
local FResult3={close=function() closed+=1 end,run=function(npc,answers,opts)
 assert(npc==officer and opts.holdPosition==false and opts.shouldRun())
 jail=true;assert(opts.shouldRun(),"Jailed alone must not finish while carry is still active")
 carrying=false;assert(not opts.shouldRun(),"confirmed prison and carry release should end the dialogue immediately")
 return true
end}
"""+delivery+r"""
assert(fn703("Victim") and confirmed==1 and closed==2)
-- Positive marker is the sixth run result, i.e. seventh value in the pcall tuple.
tx.jailed=false;carrying=true;jail=false
FResult3.run=function()
 carrying=false;victim.Parent=nil
 return false,false,nil,true,{},true
end
rotDelivery.await=function(t) assert(t.dialogueSucceeded==true and not t.jailed);confirmed+=1;return true end
assert(fn703("Victim") and confirmed==2)
""")


    def test_four_rot_alts_can_each_confirm_four_deliveries_without_character_dedup_loss(self):
        counter=self.part('        local rotQueueOnCount\n', '        local Maid9 = a1849.Maid')
        ledger=self.part('        rotDelivery.begin=function(', '        local fn703 = function(')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local active=true;local carrying=true
local fn697=function() return active end;local fn699=function() return carrying end
local fn692=function() end;local saved=0;local v1346=0;local rotCarriedCharacter
local qResult4={set=function(_,value) saved=value end};local rotWalkStatus={SetText=function() end}
local players={};local tags={};local v1345={HasTag=function(_,c) return tags[c]==true end}
local getResult26={GetPlayerFromCharacter=function(_,c) return players[c] end}
local task={wait=function(dt) clock+=dt end}
"""+counter+ledger+r"""
local alts={}
for i=1,4 do local c={Parent=true};players[c]={Character=c};table.insert(alts,c) end
local updates=0;rotQueueOnCount=function() updates+=1 end
for round=1,4 do
 for _,character in alts do
  character.Parent=true;players[character].Character=character;tags[character]=false
  carrying=true;rotCarriedCharacter=character
  local tx=rotDelivery.begin(character,true);assert(tx,"each new confirmed pickup has its own transaction")
  -- Existing NPC lookup uses the already armed transaction rather than creating another one.
  assert(rotDelivery.begin(character)==tx)
  if round==4 then
   -- Fast wipe/rejoin can remove the model before the receiver observes its Jailed tag.
   tx.dialogueSucceeded=true;character.Parent=nil;players[character].Character={}
  else
   tx.jailed=true -- latches a transient Jailed event from this pickup even if the tag is gone now
  end
  carrying=false;local before=clock
  assert(rotDelivery.await(tx) and clock-before>=0.5)
  assert(not fn693(character,tx) and not rotDelivery.await(tx),"duplicate callbacks cannot count a delivery twice")
  character.Parent=true;players[character].Character=character
  assert(rotDelivery.begin(character)==nil,"NPC/dialogue replay alone cannot rearm a counted delivery")
 end
end
assert(v1346==16 and saved==16 and updates==16,"four deliveries for each of four alts must produce sixteen")
""")

    def test_rot_respawn_fallback_requires_positive_npc_ack_and_release(self):
        counter=self.part('        local rotQueueOnCount\n', '        local Maid9 = a1849.Maid')
        ledger=self.part('        rotDelivery.begin=function(', '        local fn703 = function(')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local carrying=true
local fn697=function() return true end;local fn699=function() return carrying end
local fn692=function() end;local v1346=0;local qResult4={set=function() end}
local character={Parent=true};local player={Character=character}
local getResult26={GetPlayerFromCharacter=function() return player end}
local v1345={HasTag=function() return false end};local rotWalkStatus={SetText=function() end}
local task={wait=function(dt) clock+=dt end};local rotCarriedCharacter
"""+counter+ledger+r"""
local tx=rotDelivery.begin(character,true);tx.dialogueSucceeded=true;carrying=false
assert(not rotDelivery.await(tx) and v1346==0,"NPC success alone plus dropping carry is insufficient while victim stays present")
tx=rotDelivery.begin(character,true);player.Character={}
assert(not rotDelivery.await(tx) and v1346==0,"respawn alone without positive NPC acknowledgement is insufficient")
player.Character=character;tx=rotDelivery.begin(character,true);tx.dialogueSucceeded=true;player.Character={};carrying=true
assert(not rotDelivery.await(tx) and v1346==0,"positive acknowledgement and respawn cannot count before carry is released")
carrying=false;assert(rotDelivery.await(tx) and v1346==1)
""")

    def test_plain_punch_owns_mana_waits_for_tool_and_charge_and_cleans_up_on_failure(self):
        plain=self.part('__L3.bladePlainPunch=function', '__L3.bladeManaPunch=function')
        self.run_luau(r"""
local clock=0;local os={clock=function() return clock end};local __L3={bladeStatus=function() end}
local tool=true;local charging=true;local active=true;local attacks=0;local fail=false
local hum={UnequipTools=function() end}
local character={FindFirstChildOfClass=function() return hum end,
 FindFirstChildWhichIsA=function() return tool end,FindFirstChild=function(_,name) return name=="Charge" and charging end}
local LocalPlayer21={Character=character};local a1723={State={mana={decharge=function() end,
 chargeUntil=function() error("ordinary punches must not charge") end}}}
local landedAt
local fn577=function()
 assert(not tool and not charging and a1723.State.bladeManaOwner)
 if fail then error("temporary input failure") end
 attacks+=1;landedAt=clock+0.1
end
local task={wait=function(dt)
 assert(a1723.State.bladeManaOwner,"Auto Charge must stay excluded throughout tool release and hit confirmation")
 clock+=dt
 if clock>=0.4 then tool=false end
 if clock>=0.6 then charging=false end
 if landedAt and clock>=landedAt then __L3.bladeUnlockAwaiting=false;landedAt=nil end
end}
"""+plain+r"""
for i=1,3 do
 assert(__L3.bladePlainPunch(function() return active end))
 assert(a1723.State.bladeManaOwner==nil and __L3.bladeUnlockAwaiting==nil)
end
assert(attacks==3)
fail=true;assert(not __L3.bladePlainPunch(function() return active end))
assert(a1723.State.bladeManaOwner==nil and __L3.bladeUnlockAwaiting==nil)
fail=false;assert(__L3.bladePlainPunch(function() return active end) and attacks==4,"a transient input failure must permit a later retry")
""")

    def test_displaced_unlock_farm_walks_back_without_restarting_hp_gate(self):
        attack=self.part('        __L3.bladeAttack=function(', '        a1723.Maid:Give(function() if __L3.bladeCombatCleanup')
        self.run_luau(VEC+r"""
local clock=0;local os={clock=function() return clock end};local tbl303={true};local hits=0;local returns=0
local anchor=Vector3.new(0,0,0);local root={Parent=true,Position=Vector3.new(5,0,0)}
local hum={Parent=true,Health=100,AutoRotate=true,MoveTo=function(_,position)
 if (position-anchor).Magnitude<0.01 and (root.Position-anchor).Magnitude>4 then returns+=1 end
 root.Position=position
end}
local character={FindFirstChild=function() return root end,FindFirstChildOfClass=function() return hum end}
local LocalPlayer21={Character=character}
local __L3={bladeFarmAssigned="shriekers",bladeCombatMode="unlock",bladeAimLabel={SetText=function() end},
 bladeCellBounds=function() return {},anchor,Vector3.new(0,0,1) end,
 bladeValue=function(_,fallback) return fallback end,
 bladeAimPlan=function(_,current) return {count=1,position=current,direction=Vector3.new(0,0,1)} end,
 bladePlainPunch=function() hits+=1;return true end}
local fn536=function() end;local fn576=function() return false end
local RaycastParams={new=function() return {} end};local Enum={RaycastFilterType={Exclude=true}}
local v966={FindFirstChild=function() end,Raycast=function(_,position,direction)
 if direction.Y==-9 then return {Position=Vector3.new(position.X,0,position.Z),Normal=Vector3.new(0,1,0)} end
end}
local CFrame={lookAt=function() return {} end}
local task={wait=function(dt) clock+=dt;assert(clock<10,"displaced farm cannot idle indefinitely") end}
"""+attack+r"""
__L3.bladeAttack(function() return hits==3 end,function() return {} end,{})
assert(returns==1 and hits==3 and hum.AutoRotate and __L3.bladeCombatCleanup==nil)
""")


    def test_blade_ultra_skips_dash_training_and_handoff_does_not_require_dash(self):
        ultra=self.part('        __L3.fn638 = function()', '        __L3.fn639 = function()')
        finish=self.part('        __L3.fn636 = function()', '          tbl308[1] = tbl308[1] or {}')+'          return true\n        end\n'
        self.run_luau(r"""
local __L3={bladeEnabled=function() return true end};local tbl303={true};local tbl308={{p7dash=true,p7side=2}}
local confirmed=true;local purchase=true;local visited=true;local approached=true;local finishes=0;local saves=0;local releases=0
local fn534=function() end;local fn546=function() end;local fn542=function() saves+=1 end
local Vector3={new=function() return {} end};local __L2={tbl282={},fn503=function() return confirmed end,fn504=function() return confirmed end}
local fn492=function() error("Blade handoff must not inspect or wait for Mana Dash") end
local task={spawn=function(fn) fn() end}
local Toggles8={ProgGoToKhei={Value=true}}
local a1723={State={mana={chargeUntil=function() error("must not charge after Ultra") end,decharge=function() releases+=1 end}}}
__L3.bladeDraugVisit=function() return visited end
__L3.bladeTrainerApproach=function() return approached end
__L3.bladeTrainPurchase=function() return purchase end
__L3.bladeTrainWait=function() end
"""+finish+r"""
local finishGuard=__L3.fn636
__L3.fn636=function() assert(finishGuard());finishes+=1 end
"""+ultra+r"""
__L3.fn638();assert(finishes==1 and releases==1 and tbl308[1].p7dash==nil and tbl308[1].p7side==nil and saves==1)
confirmed=false;__L3.fn638();assert(finishes==1,"Ultra confirmation remains required")
confirmed=true;purchase=false;__L3.fn638();assert(finishes==1,"failed purchase cannot advance")
purchase=true;visited=false;__L3.fn638();assert(finishes==1,"Draug visit remains required")
visited=true;tbl303[1]=false;__L3.fn638();assert(finishes==1,"stopped bot cannot hand off")
""")


    def test_manual_stage_selection_preserves_counters_and_checks_stop_and_world(self):
        selector=self.part('        __L3.bladeStartStages={', '        __L3.bladeCount=function(')
        self.run_luau(r"""
local __L3={};local tbl303={false};local num274=2;local game={PlaceId=1}
local saved={phase="DONE",bladeDamage=6704,bladeFistDamage=144,bladeUnlockHits=3,
 bladeRotCount=11,bladeTraining={jagen={confirmed=1}},boundInn="Castle Sanctuary",runId="old"}
local fn541=function() return table.clone(saved) end;local tbl308={};local writes=0;local removed={}
local fn542=function() writes+=1;saved=tbl308[1] end
local qResult3={remove=function(key) removed[key]=true end}
"""+selector+r"""
assert(not __L3.bladeSelectStart("Resume") and writes==0)
assert(__L3.bladeSelectStart("7 - Draug e Ultra (Jagen)"))
assert(saved.phase=="P7" and saved.bladePhase=="P7" and saved.bladeStartSpawnDone and saved.bladeSpawnTransitionAllowed)
assert(saved.bladeDamage==6704 and saved.bladeFistDamage==144 and saved.bladeUnlockHits==3 and saved.bladeRotCount==11)
assert(saved.bladeTraining.jagen.confirmed==1 and saved.boundInn=="Castle Sanctuary" and saved.runId=="old")
assert(removed.prog_pathpoint and removed.prog_lastpos)
for _,key in {"bladeCoreRunning","bladeMenuPause"} do
 __L3[key]=true;assert(not pcall(__L3.bladeSelectStart,"1 - Alana: Silver e itens"));__L3[key]=nil
end
tbl303[1]=true;assert(not pcall(__L3.bladeSelectStart,"1 - Alana: Silver e itens"));tbl303[1]=false
assert(writes==1)
assert(not pcall(__L3.bladeSelectStart,"Khei - retomar sequencia") and writes==1)
assert(__L3.bladeSelectStart("P5 (zombie scrooms)") and saved.phase=="B1_XP","old saved selector values remain compatible")
assert(__L3.bladeSelectStart("1 - Alana: Silver e itens") and not saved.bladeStartSpawnDone and not saved.bladeSpawnTransitionAllowed)
assert(saved.bladeDamage==6704 and saved.bladeRotCount==11,"selecting a stage must not silently erase confirmed progress")
game.PlaceId=2
assert(not pcall(__L3.bladeSelectStart,"7 - Draug e Ultra (Jagen)"))
assert(__L3.bladeSelectStart("Khei - retomar sequencia") and saved.phase=="KHEI")
assert(not pcall(__L3.bladeSelectStart,"unknown stage"))
""")

    def test_manual_stage_is_consumed_only_after_start_and_training_needs_no_rot_alts(self):
        click=self.part('        __L3.progStartClick=function()', '        v1012 = progressionTab:AddButton(')
        validation=self.part('        __L3.bladeValidateSetup=function(', '        a1723.Maid:Give(__L3.bladeReleaseSetup)')
        self.run_luau(r"""
local __L3={bladeSetupReady=true,num326=-math.huge,progStatusLabel={SetText=function() end}}
local tbl303={false};local selected=0;local started=0;local value="7 - Draug e Ultra (Jagen)";local fail=false
local Options8={ProgStartPhase={Value=value,SetValue=function(self,v) self.Value=v end}}
local a1723={};local iResult5={allow=function() return true end};local tick=function() return 10 end
__L3.bladeSelectStart=function(v) assert(v==value);selected+=1;return true end
__L3.fn648=function() started+=1;if fail then error("missing capability") end;tbl303[1]=true end
local fn535=function() end;local fn534=function() end;local v1009=function() tbl303[1]=false end
__L3.bladeReleaseSetup=function() end
local fn531=function() end;local fn532=function() end;local qResult3={remove=function() end}
local newResult61={DoCleaning=function() end}
"""+click+r"""
__L3.progStartClick();assert(selected==1 and started==1 and Options8.ProgStartPhase.Value=="Resume")
tbl303[1]=false;__L3.num326=-math.huge;Options8.ProgStartPhase.Value=value;fail=true
__L3.progStartClick();assert(Options8.ProgStartPhase.Value==value and not tbl303[1],"failed start must keep the selected stage available")
local game={PlaceId=1};local num274=2;local firetouchinterest=true;local fireclickdetector=true
local Toggles8={AutoBag={}};Options8.BagRange={}
__L3.bladeRoute=table.create(14,true);__L3.bladeCellBounds=function() return {} end
__L3.bladeIO={available=function() return true end};a1723.State={}
"""+validation+r"""
local run={BladeOrderly="Rots",BladeFarm="Shriekers",BladeSpeed=100,alts={}}
assert(pcall(__L3.bladeValidateSetup,run,"P7") and pcall(__L3.bladeValidateSetup,run,"B3_TRAIN"))
assert(not pcall(__L3.bladeValidateSetup,run,"B1_XP"),"XP/ROT requirements still apply to earlier stages")
""")
        self.assertIn('progressionTab:AddDropdown("ProgStartPhase"',self.source)
        self.assertNotIn('__L3.hiddenSetup:AddDropdown("ProgStartPhase"',self.source)

if __name__ == '__main__':
    unittest.main()
