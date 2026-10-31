        -- Event-driven resource controls: no render/heartbeat loop just to limit rendering.
        local performance=Settings:AddLeftGroupbox("Desempenho Lite")
        local perf={active=false,focused=true,last=nil}
        local runService=aResult38.RunService
        local inputService=aResult38.UserInputService
        local function applyPerformance()
          if Library23.Unloaded or not Library23.Toggles.LiteThrottle then return end
          local enabled=Library23.Toggles.LiteThrottle.Value
          if not enabled then
            if perf.active then
              perf.active=false;perf.last=nil
              if setfpscap and perf.savedCap then pcall(setfpscap,perf.savedCap) end
              if perf.savedQuality then pcall(function() settings().Rendering.QualityLevel=perf.savedQuality end) end
              pcall(function() runService:Set3dRenderingEnabled(true) end)
            end
            return
          end
          if not (Library23.Options.LiteFocusedFps and Library23.Options.LiteBackgroundFps and Library23.Toggles.LiteHideBackground) then return end
          if not perf.active then
            perf.active=true
            if getfpscap then pcall(function() perf.savedCap=getfpscap() end) end
            pcall(function() perf.savedQuality=settings().Rendering.QualityLevel end)
          end
          local fps=tonumber((perf.focused and Library23.Options.LiteFocusedFps or Library23.Options.LiteBackgroundFps).Value) or 20
          local render=perf.focused or not Library23.Toggles.LiteHideBackground.Value
          local state=tostring(fps)..":"..tostring(render)
          if perf.last==state then return end
          perf.last=state
          if setfpscap then pcall(setfpscap,fps) end
          pcall(function() settings().Rendering.QualityLevel=Enum.QualityLevel.Level01 end)
          pcall(function() runService:Set3dRenderingEnabled(render) end)
        end
        performance:AddToggle("LiteThrottle",{Text="Reduzir uso do cliente",Default=true,Callback=applyPerformance})
        performance:AddSlider("LiteFocusedFps",{Text="FPS com janela ativa",Default=20,Min=15,Max=120,Rounding=0,Callback=applyPerformance})
        performance:AddSlider("LiteBackgroundFps",{Text="FPS em segundo plano",Default=15,Min=15,Max=60,Rounding=0,Callback=applyPerformance})
        performance:AddToggle("LiteHideBackground",{Text="Pausar renderizacao 3D em segundo plano",Default=true,Callback=applyPerformance})
        performance:AddLabel("O bot continua executando com a janela em segundo plano. Ajuste o FPS se necessario.",true)
        local windowActive=isrbxactive or iswindowactive or isgameactive
        if windowActive then pcall(function() perf.focused=windowActive()~=false end) end
        a11542.Maid:Give(inputService.WindowFocused:Connect(function() perf.focused=true;applyPerformance() end))
        a11542.Maid:Give(inputService.WindowFocusReleased:Connect(function() perf.focused=false;applyPerformance() end))
        a11542.Maid:Give(function()
          if not perf.active then return end
          perf.active=false;perf.last=nil
          if setfpscap and perf.savedCap then pcall(setfpscap,perf.savedCap) end
          if perf.savedQuality then pcall(function() settings().Rendering.QualityLevel=perf.savedQuality end) end
          pcall(function() runService:Set3dRenderingEnabled(true) end)
        end)
        task.defer(applyPerformance)
