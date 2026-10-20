local factory=require('../CoreBridge')
local calls={}
local function control(value)
 return {Value=value,SetValue=function(self,v) self.Value=v;table.insert(calls,v) end}
end
local fall,kill=control(false),control(true)
local now=1
local state={}
local b=factory({no_fall=fall,no_killbrick=kill},state,function()return now end)
b.step();assert(not fall.Value)
state.noFallUntil=5;b.step();assert(fall.Value)
now=6;b.step();assert(not fall.Value)
fall.Value=true;state.scroomNoFallOverride=true;b.step();assert(not fall.Value)
state.scroomNoFallOverride=false;b.step();assert(fall.Value)
b.setKillbricks(true);assert(kill.Value);b.setKillbricks(false);assert(kill.Value)
kill.Value=false;b.setKillbricks(true);assert(kill.Value);b.cleanup();assert(not kill.Value)
b.cleanup();assert(fall.Value)
state.noFallUntil=999;b.step();assert(fall.Value)
print('PASS: new bot guards delegate to original Hydroxide toggles; temporary protection, scroom fall bypass and original preferences restore on release/unload')
