local path
if game.GameId == 7359098240 then
    path = "HYDROXIDE_LOCAL/ROGUE_BATTLEGROUNDS/rlb.lua"
elseif game.GameId == 1087859240 then
    path = "HYDROXIDE_LOCAL/ROGUE/rogue_ui.lua"
else
    warn("[HXD LOCAL] Jogo nao reconhecido pelo loader de teleporte")
    return
end
local fn, err = loadstring(readfile(path), "@" .. path)
assert(fn, err)
fn()
