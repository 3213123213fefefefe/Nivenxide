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
local character={FindFirstChildOfClass=function() return hum end,FindFirstChild=function() return mana end,FindFirstChildWhichIsA=function() return tool end}
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
        flight=self.part('rotSupplier.flyTo=function', '        local fn703 =')
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
local character={FindFirstChildOfClass=function() return hum end,FindFirstChildWhichIsA=function() return tool end}
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
assert(attacks==3 and releases==3 and __L3.bladeUnlockAwaiting==nil)
land=false;assert(not __L3.bladePlainPunch(function() return true end) and clock<2.1)
assert(not __L3.bladePlainPunch(function() return false end) and attacks==4)
''')

if __name__ == '__main__':
    unittest.main()
