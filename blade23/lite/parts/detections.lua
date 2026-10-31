        -- Preserve name-based moderator detection used by Blade safety, without artifact/ESP watchers.
        local detected={};local queued={};local lichNames={};local detectionMaid=dResult24.new()
        a11542.Maid:Give(detectionMaid)
        local function alive() return not Library23.Unloaded and not a11542.State.unloading end
        local function detect(player)
          if not alive() or player==LocalPlayer38 or not player.Parent or not a11542.State.notificationsReady then return end
          local first=a11542.State.getFirstName and a11542.State.getFirstName(player)
          if first and lichNames[first] and a11542.State.flagModerator then a11542.State.flagModerator(player,"has Lich name ["..first.."]") end
          local reason=a11542.State.moderatorInfo and a11542.State.moderatorInfo(player)
          if not alive() or not reason or detected[player.UserId] then return end
          detected[player.UserId]=true
          if Library23.Toggles.Notifications.Value then
            Library23:Notify({Title="Moderator detected",Description=player.Name.." "..reason,Time=25})
          end
        end
        local function scheduleDetection(player)
          if not alive() or queued[player] then return end
          queued[player]=true
          task.spawn(function() pcall(detect,player);queued[player]=nil end)
        end
        local function watchName(player)
          if player==LocalPlayer38 or not alive() then return end
          local key="name_"..player.UserId
          local maid=dResult24.new();detectionMaid[key]=maid
          maid:Give(player:GetAttributeChangedSignal("FirstName"):Connect(function() scheduleDetection(player) end))
          local function bindStats(stats)
            local function bindName(value)
              if value.Name~="FirstName" then return end
              maid.value=value:GetPropertyChangedSignal("Value"):Connect(function() scheduleDetection(player) end)
              scheduleDetection(player)
            end
            local value=stats:FindFirstChild("FirstName");if value then bindName(value) end
            maid.addName=stats.ChildAdded:Connect(bindName)
          end
          local stats=player:FindFirstChild("leaderstats");if stats then bindStats(stats) end
          maid:Give(player.ChildAdded:Connect(function(child) if child.Name=="leaderstats" then bindStats(child) end end))
          scheduleDetection(player)
        end
        local function scanDetections()
          if not alive() then return end
          for _,player in aResult38.Players:GetPlayers() do scheduleDetection(player) end
        end
        task.spawn(function()
          pcall(function()
            local info=aResult38.ReplicatedStorage:FindFirstChild("Info")
            local generator=info and info:FindFirstChild("NameGenerator")
            local lich=generator and generator:FindFirstChild("Lich")
            local names=lich and require(lich)
            if type(names)=="table" then for _,name in names do lichNames[name]=true end end
          end)
          scanDetections()
        end)
        for _,player in aResult38.Players:GetPlayers() do watchName(player) end
        detectionMaid:Give(aResult38.Players.PlayerAdded:Connect(watchName))
        detectionMaid:Give(aResult38.Players.PlayerRemoving:Connect(function(player)
          detectionMaid["name_"..player.UserId]=nil;detected[player.UserId]=nil;queued[player]=nil
        end))
        a11542.State.onModeratorsLoaded=scanDetections
        a11542.State.onNotificationsReady=scanDetections
        a11542.State.tickNewDetections=scanDetections
