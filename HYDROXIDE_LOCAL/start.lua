-- Run from the executor workspace. This entry matches the user's Rogue loader.
local started = os.clock()
print("[HXD LOCAL] Lendo arquivos do PC...")
local ok, err = pcall(function()
    assert(type(readfile) == "function", "Executor sem readfile")
    local path = "HYDROXIDE_LOCAL/ROGUE/rogue_ui.lua"
    assert(not isfile or isfile(path), "Extraia HYDROXIDE_LOCAL dentro da pasta workspace do executor")
    local fn, compileErr = loadstring(readfile(path), "@HYDROXIDE_LOCAL/ROGUE/rogue_ui.lua")
    assert(fn, compileErr)
    fn()
end)
if not ok then
    warn("[HXD LOCAL] " .. tostring(err))
else
    print(string.format("[HXD LOCAL] Execucao do script retornou em %.2fs; confira a interface e eventuais erros internos.", os.clock() - started))
end
