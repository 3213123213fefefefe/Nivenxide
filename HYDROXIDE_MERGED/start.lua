-- Combined entry; do not start alongside another active Hydroxide client.
if not game:IsLoaded() then game.Loaded:Wait() end
local fn,err=loadstring(readfile("HYDROXIDE_MERGED/standard.lua"),"@HYDROXIDE_MERGED/standard.lua")
assert(fn,err)
return fn()
