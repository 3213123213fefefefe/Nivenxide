local factory=require('../ExtrasEngine')
local engine=factory()
assert(type(engine.modules)=='table' and type(engine.ui)=='table')
assert(type(engine.ui.lib)=='string' and #engine.ui.lib>100000)
assert(not string.find(engine.ui.lib,'getgenv().Library:Unload()',1,true))
for _,id in {'l','p','r','w','A','E','K','N','O','P','T','U','V','X','Y','Z','_','aa','ab','ac','af'} do
 assert(type(engine.modules[id])=='function',id)
end
assert(engine.modules.ad==nil and engine.modules.ae==nil,'Unrelated device integration must be absent')
assert(engine.modules.cache and next(engine.modules.cache)==nil,'Factory construction must not attach game hooks')
print('PASS: extracted UI and 21 feature families construct without game/executor APIs, no account/session entrypoint or device modules')
