#!/usr/bin/env python3
"""Build the optional Blade-only runtime from the full runtime without editing it.
Requires the official luau-ast binary (LUAU_AST or --ast). No minifier/obfuscator.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def section(text,start,end):
    a=text.index(start);return text[a:text.index(end,a)]

def change(text,old,new):
    assert old in text,old[:120]
    return text.replace(old,new,1)

def ast(text,binary):
    with tempfile.TemporaryDirectory() as folder:
        path=Path(folder)/'input.luau';path.write_text(text)
        out=Path(folder)/'ast.json'
        with out.open('w') as f:
            p=subprocess.run([binary,str(path)],stdout=f,stderr=subprocess.PIPE,text=True)
        if p.returncode: raise RuntimeError(p.stderr)
        return json.loads(out.read_text(errors="replace"))['root']

def nodes(value):
    if isinstance(value,dict):
        yield value
        for child in value.values(): yield from nodes(child)
    elif isinstance(value,list):
        for child in value: yield from nodes(child)

def span(text,location):
    data=text.encode();lines=data.splitlines(keepends=True)
    a,b,c,d=map(int,re.findall(r'\d+',location))
    return sum(map(len,lines[:a]))+b,sum(map(len,lines[:c]))+d

def snippet(text,location):
    a,b=span(text,location);return text.encode()[a:b].decode()

def getter(name,fn):
    return f'''    tbl44.{name} = function()
      local value=tbl44.cache.{name}
      if not value then value={{c={fn}()}};tbl44.cache.{name}=value end
      return value.c
    end
'''

def build(binary):
    full=(ROOT/'sentinel.lua').read_text()
    loader=(ROOT/'loader.lua').read_text()
    core=section(full,'__modules.m356b75b2d82b = function()','    loadstring(')
    starts=list(re.finditer(r'^    local (fn\d+) = function\(\)',core,re.M))
    mods={}
    for i,m in enumerate(starts):
        body=core[m.start():starts[i+1].start() if i+1<len(starts) else len(core)]
        name=re.search(r'^    tbl44\.(\w+) = function\(\)',body,re.M)
        assert name,m[1]
        mods[name[1]]=body
    original=mods.copy()
    # Item classifiers are shared by AutoIngredient/AutoTrinket; no ESP renderer is needed.
    c=mods['p']
    head=section(c,'    local fn54 = function()','      local fn211 = function(')
    for line in ('      local mResult = tbl44.m()\n','      local nResult = tbl44.n()\n','      local oResult = tbl44.o()\n','      local dResult6 = tbl44.d()\n','      local cResult3 = tbl44.c()\n'):
        head=head.replace(line,'')
    body=section(c,'      local fn211 = function(','      return function(a1320)')
    folder=section(c,'        local v370\n','        local res94, v371 =')
    mods['p']=head+body+'      return function(a1320)\n'+folder+'      end\n    end\n'+getter('p','fn54')
    # The display-name helpers are used in Blade alerts, independently of the leaderboard.
    c=mods['Y']
    mods['Y']='''    local fn89 = function()
      local v2245=game.PlaceId==5208655184 or game.PlaceId==109732117428502
      local v2243=game.PlaceId==3541987450 or game.PlaceId==14341521240
'''+section(c,'      local fn1036 = function(','      return function(a11194)')+'''      return function(a11194)
        a11194.State.getRogueName=fn1036
        a11194.State.getFirstName=fn1037
        local iResult10=tbl44.i()
        local addTabResult=a11194.Tabs.Automation:AddLeftGroupbox("Bard e dialogos")
'''+section(c,'        addTabResult:AddToggle("AutoDialogue"','        local v2261\n')+'''      end
    end
'''+getter('Y','fn89')
    # Keep the exact moderator predicate and callbacks which the Blade safety watcher consumes.
    c=mods['V']
    mods['V']='''    local fn86 = function()
      return function(a1962)
'''+section(c,'        local tbl435 =','        local fn835 =')+'''      end
    end
'''+getter('V','fn86')
    # Retain ally selection, same-PC integration, anti-idle and the victim's fall remote.
    c=mods['Z']
    head=section(c,'    local fn90 = function()','      local tbl562 =')
    body=section(c,'      local fn1101 = function(','        local newResult84 =')
    fall=section(c,'        local v2436\n','        addLeftGroupboxResult17:AddButton({\n          Text = "Knock Self"')
    # Only remove the delayed debug print, not the down remote or its NoFall bypass.
    fall=fall[:fall.index('          task.spawn(function()')]+'''          return true
        end
'''
    mods['Z']=head+body+fall+'      end\n    end\n'+getter('Z','fn90')
    mods['Z']=change(mods['Z'],'        local v2436\n','        Toggles16.AntiAfk:SetValue(true)\n        local v2436\n')
    # E retains mana, pickup, dialogue and training engines, all used by the original route.
    c=mods['E']
    c=change(c,'''        local addLeftTabboxResult = Automation:AddLeftTabbox()
''','')
    c=change(c,section(c,'        if v731 then\n          a1593.State.gripsTab','        local tbl221 ='),'''        a1593.State.rotBotTab = blade23Tabbox:AddTab("Rot")
        if v731 then a1593.State.rotBotTab.Button.Visible=false end
''')
    c=change(c,section(c,'        local addRightGroupboxResult17 = Automation:AddRightGroupbox("Auto Crafting")','        local addRightGroupboxResult18 ='),'')
    c=change(c,section(c,'      local tbl214 =','      local tbl219 ='),'      local v731 = game.PlaceId == 3541987450 or game.PlaceId == 14341521240\n')
    c=change(c,section(c,'        local newResult58 =','        local v744\n'),'')
    c=change(c,section(c,'        local num205 = 64','      end\n    end\n    tbl44.E ='),'')
    c=c.replace('        a1593.State.healerTab = Automation:AddLeftGroupbox("Healer")\n','')
    mods['E']=c
    # Manual freecam/waypoint flight and the independent Safe Server bot are not route engines.
    mods['A']=mods['A'].replace('      local zResult = tbl44.z()\n','').replace('        zResult.attach(a1544, World)\n','')
    # Settings keep the full verified persistence implementation, without chat/toy/inventory UI.
    c=mods['af']
    imports=section(c,'    local fn97 = function()','      local num767 =')
    imports=imports.replace('      local aeResult = tbl44.ae()\n','').replace('      local yResult2 = tbl44.y()\n','')
    helper=section(c,'      local fn1383 = function(','      local fn1386 = function(')
    setup=section(c,'      return function(a11542)','        local tbl719 =')
    essentials=section(c,'        addLeftGroupboxResult19:AddToggle("PersistentConfigs"','        local Players10 =')
    webhook=section(c,'        local Callback16 = function()','        local State = a11542.State')
    settings=section(c,'        Library23:SetKeybindFrameVisible(false)','    tbl44.af = function()')
    parts=(ROOT/'lite'/'parts')
    mods['af']=imports+'      local tbl708={}\n'+helper+setup+'''        addLeftGroupboxResult19:AddToggle("RiskyMode",{Text="Risky Mode",Default=false,Callback=Callback14})
        addLeftGroupboxResult19:AddToggle("Notifications",{Text="Notifications",Default=true})
'''+essentials+(parts/'performance.lua').read_text()+webhook+'''        addRightGroupboxResult28:AddInput("WebhookAlertPing",{Text="Bot Alerts",Default="@everyone",Finished=true,Callback=Callback16})
        a11542.State.syncWebhook=Callback16
'''+(parts/'detections.lua').read_text()+settings+getter('af','fn97')
    # Separate profiles/autosave from the full edition; seed a new Lite install read-only.
    mods['af']=mods['af'].replace('SaveManager:SetFolder("sentinel")','SaveManager:SetFolder("sentinel/blade23_lite")')
    mods['af']=mods['af'].replace('ThemeManager:SetFolder("sentinel")','ThemeManager:SetFolder("sentinel/blade23_lite")')
    mods['c']=change(mods['c'],'tbl49.CACHE .. "/keybinds.json"','tbl49.CACHE .. "/blade23_lite_keybinds.json"')
    mods['af']=change(mods['af'],'        local fn1410 = function()', '''        local legacyKeybinds=cResult11.CACHE.."/keybinds.json"
        if isfile and readfile and writefile and not isfile(cResult11.KEYBINDS) and isfile(legacyKeybinds) then
          pcall(function() cResult11.ensureFor(cResult11.KEYBINDS);writefile(cResult11.KEYBINDS,readfile(legacyKeybinds)) end)
        end
        local fn1410 = function()''')
    mods['af']=mods['af'].replace('blade23_settings_','blade23_lite_settings_')
    seed='''        local legacyPrefs="sentinel/.cache/blade23_settings_"..tostring(game:GetService("Players").LocalPlayer.UserId)..".json"
        if isfile and not isfile(bladePrefs.file) then
          local data=SaveManager:ReadConfig(legacyPrefs,1)
          if data then
            pcall(function() SaveManager:WriteConfig(bladePrefs.file,game:GetService("HttpService"):JSONEncode(data)) end)
          end
        end
'''
    mods['af']=change(mods['af'],'        bladePrefs.restore()\n',seed+'        bladePrefs.restore()\n')
    mods['af']=change(mods['af'],'        local bladePrefs={','''        local liteEssentials={AntiAfk=true,BlatantMode=true,RiskyMode=true,Notifications=true,PersistentConfigs=true,
          ExecuteOnServerhop=true,MenuKeybind=true,UnloadKeybind=true,LiteThrottle=true,LiteFocusedFps=true,
          LiteBackgroundFps=true,LiteHideBackground=true,WebhookUrl=true,WebhookUsername=true,
          WebhookShowUsername=true,WebhookPrefix=true,WebhookAlertPing=true}
        local bladePrefs={''')
    mods['af']=change(mods['af'],'and instance and instance:IsDescendantOf(tab.Container) then controls[key]=control end',
        'and instance and (instance:IsDescendantOf(tab.Container) or liteEssentials[key]) then controls[key]=control end')
    # Lite must resume Lite, including the ROT supplier after wipe/rejoin.
    mods['D']=mods['D'].replace('/main/blade23/loader.lua','/main/blade23/lite/loader.lua')
    # Session intent and optional settings must not auto-start the other edition on a manual switch.
    mods['q']=change(mods['q'],'local ok70, result72 = pcall(item27, MemStorageService, ...)',
        'local args={...};args[1]="blade23_lite:"..tostring(args[1])\n        local ok70, result72 = pcall(item27, MemStorageService, table.unpack(args))')
    # Progress and local coordination keep the proven shared paths; only ally preferences are isolated.
    mods['Z']=change(mods['Z'],'local FRIENDS = cResult8.FRIENDS','''local FRIENDS = cResult8.BIN.."/friends_lite.json"
      if isfile and readfile and writefile and not isfile(FRIENDS) and isfile(cResult8.FRIENDS) then
        pcall(function() cResult8.ensureFor(FRIENDS);writefile(FRIENDS,readfile(cResult8.FRIENDS)) end)
      end''')
    startup=['p','A','E','K','N','V','Y','Z','af']
    keep=set(startup)|set('abcd ef'.replace(' ',''))
    while True:
        deps=set(x for name in keep for x in re.findall(r'tbl44\.(\w+)\(',mods[name]))
        if deps<=keep: break
        keep|=deps
    chunks=''.join(body for name,body in mods.items() if name in keep)
    # Preserve the bot modules byte-for-byte; their shared helpers are retained by dependency closure.
    for name in ['K','N','F','G','H','I','J','L','M']:
        assert mods[name]==original[name],name
    boot=section(full,'    loadstring(', 'local __entry = requireModule("m356b75b2d82b")')
    assert boot.endswith('  end\nend\n')
    boot=boot[:-len('  end\nend\n')]+'end\n'
    a=boot.index('      __bootMark("module:l")');b=boot.index('      __bootMark("ready")',a)
    boot=boot[:a]+''.join(f'      __bootMark("module:{name}")\n      task.wait()\n      tbl44.{name}()(tbl743)\n' for name in startup)+boot[b:]
    boot=change(boot,section(boot,'      do\n        local diagnostic=','      tbl743.State.moderatorIds'), '')
    boot=boot.replace('ShowCustomCursor = true','ShowCustomCursor = false').replace('Title = "sentinel.bz",\n        Center','Title = "Blade 23 Lite - teste",\n        Center')
    boot=change(boot,section(boot,'        Tabs = {','      cResult.migrate()'),'''        Tabs = {
          Blade23 = CreateWindowResult:AddTab("blade 23"),
          World = CreateWindowResult:AddTab("Protecoes"),
          Automation = CreateWindowResult:AddTab("Mana e coleta"),
          Player = CreateWindowResult:AddTab("Aliados e anti-AFK"),
          Settings = CreateWindowResult:AddTab("Settings"),
        },
      }
''')
    # Remove periodic RAM sampling entirely in this edition; only boot progress is tracked.
    # Explicit splice avoids depending on comments after the boot journal.
    prefix=full[:full.index('__bootSession.report=')]+'''local function __bootMark(phase,sampleOnly)
  if __bootSession.cancelled and phase~="unloaded" then
    if sampleOnly then return end
    error("carregamento cancelado",0)
  end
  if not sampleOnly then __bootSession.phase=phase;__bootSession.updated=os.clock() end
end
__bootMark("runtime-entry")

'''+section(full,'-- Coalesce UI work','local __UI_FILES =')
    ui={name:re.sub(r'[ \t]+(?=\n)','',body) for name,body in re.findall(r'\b(lib|theme|save) = \[=\[(.*?)\]=\]',full,re.S)}
    lib=ui['lib'];tree=ast(lib,binary);cuts=[]
    methods={'CreatePlayerList','CreateChatLog','CreateMacroCreator','CreatePathEditor','CreateAutoBlockBuilder','CreateStatusList'}
    for n in tree['body']:
        if n['type']=='AstStatFunction' and n['name'].get('index') in methods:
            cuts.append(span(lib,n['location']))
    assert len(cuts)==len(methods),(len(cuts),methods)
    data=lib.encode()
    for a,b in sorted(cuts,reverse=True): data=data[:a]+data[b:]
    lib=data.decode()
    # Lite has no custom cursor; showing the menu does not need a render callback.
    cursor=section(lib,'\t\tif Library.Toggled then\n\t\t\tlocal binding = Library.ShowCursorBinding','\t\telse\n\t\t\tTooltipFrame.Visible = false')
    lib=change(lib,cursor,'''\t\tif Library.Toggled then
\t\t\tpcall(RunService.UnbindFromRenderStep, RunService, Library.ShowCursorBinding)
\t\t\tUserInputService.MouseIconEnabled = true
\t\t\tdrawCursor(false)
''')
    lib=change(lib,'\t\telse\n\t\t\tTooltipFrame.Visible = false','\t\telse\n\t\t\tUserInputService.MouseIconEnabled = OriginalMouseIconEnabled\n\t\t\tTooltipFrame.Visible = false')
    ui['lib']=lib
    ui_code='local __UI_FILES = {\n'+''.join(f'{name} = [=[{body}]=],\n' for name,body in ui.items())+'}\n'
    tail=full[full.index('local __ok, __err = pcall(__entry, __cap)'):].replace('pcall(__entry, __cap)','pcall(__entry, {})')
    body='local function __entry(a1163)\n    __bootMark("bootstrap-services")\n    local tbl44 = { cache = {} }\n'+chunks+boot+tail
    native_code=section(full,'local __NATIVE = {','local __modules =')
    native_tree=ast(native_code,binary)
    items=native_tree['body'][0]['values'][0]['items']
    used={int(x) for x in re.findall(r'__NATIVE\[(\d+)\]',body)}
    selected={i:snippet(native_code,items[i-1]['value']['location']) for i in used}
    assert not any('__NATIVE' in text for text in selected.values()),'transitive native dependency needs closure'
    natives='local __NATIVE = {\n'+''.join(f'[{i}] = {text},\n' for i,text in sorted(selected.items()))+'}\n'
    output=(prefix+ui_code+natives+body).rstrip()+'\n'
    assert 'requireModule(' not in output and 'nativeRequire(' not in output
    # Loader uses the same lifecycle gate and the small alternative runtime.
    loader=loader.replace('/main/blade23/sentinel.lua','/main/blade23/lite/sentinel.lua')
    a=loader.index('session.report=');b=loader.index('checkpoint("download")',a)
    loader=loader[:a]+'''local function checkpoint(phase)
    session.phase=phase;session.updated=os.clock()
end
'''+loader[b:]
    loader=loader.replace('    session.report.error=tostring(result):sub(1,300)\n','')
    # Compare unresolved globals to catch sliced-out local dependencies.
    base_globals={n['global'] for n in nodes(ast(full,binary)) if n.get('type')=='AstExprGlobal'}
    new_globals={n['global'] for n in nodes(ast(output,binary)) if n.get('type')=='AstExprGlobal'}
    unexpected=new_globals-base_globals
    assert not unexpected,sorted(unexpected)
    target=ROOT/'lite';target.mkdir(exist_ok=True)
    (target/'sentinel.lua').write_text(output);(target/'loader.lua').write_text(loader)
    manifest={'source_sha256':hashlib.sha256(full.encode()).hexdigest(),'full_bytes':len(full.encode()),'lite_bytes':len(output.encode()),
        'startup_modules':startup,'retained_modules':sorted(keep),'removed_modules':sorted(set(mods)-keep),'native_count':len(used),
        'protected_modules':{name:hashlib.sha256(original[name].encode()).hexdigest() for name in ['K','N','F','G','H','I','J','L','M']},
        'output_sha256':hashlib.sha256(output.encode()).hexdigest()}
    (target/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({k:manifest[k] for k in ['full_bytes','lite_bytes','native_count','startup_modules','removed_modules']}))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--ast',default=os.getenv('LUAU_AST','luau-ast'))
    build(parser.parse_args().ast)
