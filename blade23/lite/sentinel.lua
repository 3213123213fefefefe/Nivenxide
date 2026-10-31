-- A live interface owns the session; a stale flag alone must never block a retry.
local __bootEnv=(getgenv and getgenv()) or shared
local function __bladeSession(runtime)
  local previous=__bootEnv.__BLADE23_SESSION
  local same=type(previous)=="table" and previous.jobId==game.JobId
    and (previous.gameRef==nil or previous.gameRef==game)
    and (previous.placeId==nil or previous.placeId==game.PlaceId)
  local inherited
  local legacyHandoff=same and previous.phase=="execute" and previous.thread==nil and not previous.executing
  if same and previous.state=="loading" and runtime and (previous.runtimeHandoff or legacyHandoff) and not previous.cancelled then
    previous.runtimeHandoff=nil;previous.executing=true
    if type(previous.abort)=="function" then return previous end
    inherited=previous;previous=nil;same=false -- Upgrade a loader cached before this lifecycle version.
  end
  if same then
    local live=false
    if previous.state=="running" then
      pcall(function()
        local lib=previous.library
        live=lib~=nil and not lib.Unloaded and lib.ScreenGui~=nil and lib.ScreenGui.Parent~=nil
      end)
    elseif previous.state=="loading" and not previous.cancelled then
      local age=os.clock()-(previous.updated or previous.started or 0)
      local dead=previous.thread and coroutine.status(previous.thread)=="dead"
      live=not dead and age>=0 and age<90
    elseif previous.state=="unloading" then
      local age=os.clock()-(previous.updated or 0)
      live=age>=0 and age<15
    end
    if live then
      warn("[blade 23] Ja existe uma instancia carregando, ativa ou encerrando. Aguarde ou use Config > Unload.")
      return nil
    end
  end
  if type(previous)=="table" then
    if same and type(previous.abort)=="function" then
      pcall(previous.abort,"sessao anterior incompleta")
    else
      previous.cancelled=true;previous.executing=false
      if same then
        if previous.library and previous.library.Unload then pcall(function() previous.library:Unload() end) end
        if previous.coreCleanup then pcall(previous.coreCleanup) end
      elseif __bootEnv.Library==previous.library then
        __bootEnv.Library=nil -- Do not invoke old-world hooks from the next DataModel.
      end
    end
  end
  local session=inherited or {state="loading",jobId=game.JobId,started=os.clock()}
  session.gameRef=game;session.placeId=game.PlaceId;session.updated=os.clock();session.thread=coroutine.running()
  __bootEnv.__BLADE23_SESSION=session
  session.abort=function(reason)
    if session.state=="unloaded" then return end
    local loading=session.state=="loading"
    local unloading=session.state=="unloading"
    session.cancelled=true;session.executing=false;session.error=tostring(reason)
    for _,thread in {loading and session.thread or nil,unloading and session.unloadThread or nil} do
      if thread and thread~=coroutine.running() and task and task.cancel then pcall(task.cancel,thread) end
    end
    if session.library and session.library.Unload then
      session.library.Unloading=false -- The abandoned cleanup coroutine has been cancelled above.
      pcall(function() session.library:Unload() end)
    end
    if session.cleanup then pcall(session.cleanup) end
    if session.coreCleanup then pcall(session.coreCleanup);session.coreCleanup=nil end
    if session.guardKey and __bootEnv[session.guardKey]==session then __bootEnv[session.guardKey]=nil end
    if session.state~="unloaded" then session.state="failed" end
  end
  if task and task.spawn and task.wait then
    task.spawn(function()
      while __bootEnv.__BLADE23_SESSION==session and session.state=="loading" and not session.cancelled do
        task.wait(1)
        if session.state=="loading" and os.clock()-session.updated>=90 then
          session.abort("tempo limite no carregamento: "..tostring(session.phase))
          warn("[blade 23] Carregamento interrompido; execute o loader novamente. Etapa: "..tostring(session.phase))
          break
        end
      end
    end)
  end
  return session
end
local __bootSession=__bladeSession(true)
if not __bootSession then return false end
__bootSession.executing=true
local function __bootMark(phase,sampleOnly)
  if __bootSession.cancelled and phase~="unloaded" then
    if sampleOnly then return end
    error("carregamento cancelado",0)
  end
  if not sampleOnly then __bootSession.phase=phase;__bootSession.updated=os.clock() end
end
__bootMark("runtime-entry")

-- Coalesce UI work by object and process it outside property-change callbacks.
-- A linked FIFO lets Destroying remove pending work immediately without retaining dead UI.
local function __frameWorkQueue()
  local queue={entries={},head=nil,tail=nil,busy=false,closed=false,generation=0,sequence=0}
  queue.remove=function(key)
    local entry=queue.entries[key]
    if not entry then return end
    queue.entries[key]=nil
    if entry.previous then entry.previous.next=entry.next else queue.head=entry.next end
    if entry.next then entry.next.previous=entry.previous else queue.tail=entry.previous end
    entry.previous=nil;entry.next=nil
    return entry
  end
  queue.push=function(key,run)
    if queue.closed then return end
    local entry=queue.entries[key]
    if entry then entry.run=run;return end
    queue.sequence+=1
    entry={key=key,run=run,previous=queue.tail,sequence=queue.sequence}
    if queue.tail then queue.tail.next=entry else queue.head=entry end
    queue.tail=entry;queue.entries[key]=entry
  end
  queue.clear=function()
    queue.generation+=1
    table.clear(queue.entries);queue.head=nil;queue.tail=nil
  end
  queue.close=function() queue.closed=true;queue.clear() end
  queue.step=function()
    if queue.busy or queue.closed or not queue.head then return end
    queue.busy=true
    local generation=queue.generation
    local lastSequence=queue.tail.sequence
    local started=os.clock()
    local count=0
    repeat
      local entry=queue.head
      if not entry or entry.sequence>lastSequence then break end
      queue.remove(entry.key)
      pcall(entry.run)
      count+=1
      -- Newly queued work, including our own deferred change events, belongs to the next frame.
      if count>=32 or os.clock()-started>=0.002 then break end
    until queue.closed or queue.generation~=generation
    queue.busy=false
  end
  return queue
end

local __UI_FILES = {
lib = [=[
--!nonstrict

if getgenv and getgenv().Library and getgenv().Library.Unload then
	pcall(function()
		getgenv().Library:Unload()
	end)
end

local cloneref = cloneref or clonereference or function(instance)
	return instance
end
local Services = setmetatable({}, {
	__index = function(self, name)
		local success, result = pcall(game.GetService, game, name)
		if success then
			local service = cloneref(result)
			rawset(self, name, service)
			return service
		end
		warn("Invalid Service: " .. tostring(name))
	end,
})

local UserInputService = Services.UserInputService
local RunService = Services.RunService
local TweenService = Services.TweenService
local Players = Services.Players
local TextService = Services.TextService
local GuiService = Services.GuiService

local getgenv = getgenv or function()
	return shared
end
local protectgui = protectgui or function() end
local gethui = gethui or function()
	return Services.CoreGui
end
local setclipboard = setclipboard or function() end

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Mouse = cloneref(LocalPlayer:GetMouse())
local OriginalMouseIconEnabled = UserInputService.MouseIconEnabled

local PIXEL_FONT = "rbxassetid://12187371840"
local DEFAULT_FONT = "Jura"
local FONT = Font.fromEnum(Enum.Font[DEFAULT_FONT])

local Scheme = {
	Border = Color3.fromRGB(0, 0, 0),
	Outline = Color3.fromRGB(10, 10, 10),
	Accent = Color3.fromRGB(195, 33, 72),
	Body = Color3.fromRGB(20, 20, 20),
	Inline = Color3.fromRGB(30, 30, 30),
	FontColor = Color3.fromRGB(200, 200, 200),
	DimColor = Color3.fromRGB(170, 170, 170),
	Dark = Color3.fromRGB(8, 8, 8),
	DarkBorder = Color3.fromRGB(19, 19, 19),
	Element = Color3.fromRGB(38, 38, 38),
	ElementBorder = Color3.fromRGB(56, 56, 56),
	ElementFill = Color3.fromRGB(22, 22, 22),
	Pop = Color3.fromRGB(50, 50, 50),
	White = Color3.fromRGB(255, 255, 255),
	Divider = Color3.fromRGB(32, 32, 38),
	-- semantic warning colors; deliberately not in MasterShades so they stay constant across theme swaps
	Red = Color3.fromRGB(225, 65, 65),
	Orange = Color3.fromRGB(235, 145, 40),

	MainColor = Color3.fromRGB(38, 38, 38),
	AccentColor = Color3.fromRGB(195, 33, 72),
	BackgroundColor = Color3.fromRGB(20, 20, 20),
	OutlineColor = Color3.fromRGB(56, 56, 56),
}

local ColorProps = {
	BackgroundColor3 = true,
	TextColor3 = true,
	BorderColor3 = true,
	ScrollBarImageColor3 = true,
	ImageColor3 = true,
	PlaceholderColor3 = true,
	Color = true,
}

local MasterShades = {
	{ "Accent", "AccentColor", 0, 0, 0 },
	{ "FontColor", "FontColor", 0, 0, 0 },
	{ "DimColor", "FontColor", -30, -30, -30 },
	{ "Body", "BackgroundColor", 0, 0, 0 },
	{ "Dark", "BackgroundColor", -12, -12, -12 },
	{ "Inline", "BackgroundColor", 10, 10, 10 },
	{ "Outline", "BackgroundColor", -10, -10, -10 },
	{ "ElementFill", "BackgroundColor", 2, 2, 2 },
	{ "DarkBorder", "BackgroundColor", -1, -1, -1 },
	{ "Element", "MainColor", 0, 0, 0 },
	{ "Pop", "MainColor", 12, 12, 12 },
	{ "Border", "OutlineColor", -56, -56, -56 },
	{ "ElementBorder", "OutlineColor", 0, 0, 0 },
	{ "Divider", "OutlineColor", -24, -24, -18 },
}
local function byteOf(channel)
	return math.floor(channel * 255 + 0.5)
end
local function deriveScheme()
	for _, d in MasterShades do
		local master = Scheme[d[2]]
		if typeof(master) == "Color3" then
			Scheme[d[1]] = Color3.fromRGB(
				math.clamp(byteOf(master.R) + d[3], 0, 255),
				math.clamp(byteOf(master.G) + d[4], 0, 255),
				math.clamp(byteOf(master.B) + d[5], 0, 255)
			)
		end
	end
end

local Library = {
	Version = "1.0.0",
	Scheme = Scheme,
	Toggled = false,
	Unloaded = false,
	IsRobloxFocused = true,

	ToggleKeybind = Enum.KeyCode.RightControl,
	ShowCustomCursor = false,
	NotifySide = "Left",

	TweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),

	Toggles = {},
	Options = {},

	Registry = {},
	Signals = {},
	UnloadSignals = {},

	Tabs = {},
	ActiveTab = nil,

	KeybindRows = {},

	SearchIndex = {},
	SearchBoxes = {},
	Searching = false,

	ScreenGui = nil,
	GuiScale = 1,
	ShowCursorBinding = string.sub(tostring({}), 8),
}

local Templates = {
	Frame = { BorderSizePixel = 0 },
	ScrollingFrame = { BorderSizePixel = 0 },
	ImageLabel = { BackgroundTransparency = 1, BorderSizePixel = 0 },
	TextLabel = { BorderSizePixel = 0, FontFace = FONT, RichText = false, TextSize = 12 },
	TextButton = { BorderSizePixel = 0, FontFace = FONT, AutoButtonColor = false, TextSize = 12 },
	TextBox = { BorderSizePixel = 0, FontFace = FONT, TextSize = 12, ClearTextOnFocus = false },
	UIListLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
}

local function FillInstance(instance, props)
	local themeProps = Library.Registry[instance]
	for key, value in props do
		if key == "Parent" then
			continue
		end
		if ColorProps[key] and typeof(value) == "string" then
			themeProps = themeProps or {}
			themeProps[key] = value
			value = Scheme[value]
		end
		instance[key] = value
	end
	if themeProps then
		Library.Registry[instance] = themeProps
	end
end

local function New(class, props)
	local instance = Instance.new(class)
	if Templates[class] then
		FillInstance(instance, Templates[class])
	end
	if props then
		FillInstance(instance, props)
		if props.Parent then
			instance.Parent = props.Parent
		end
	end
	return instance
end

function Library:AddToRegistry(instance, properties)
	Library.Registry[instance] = properties
end

function Library:RemoveFromRegistry(instance)
	Library.Registry[instance] = nil
end

function Library:UpdateColorsUsingRegistry()
	deriveScheme()
	for instance, properties in Library.Registry do
		for property, key in properties do
			local value = Scheme[key]
			if value ~= nil then
				pcall(function()
					instance[property] = value
				end)
			end
		end
	end
end

function Library:SetAccent(color)
	Scheme.AccentColor = color
	Library:UpdateColorsUsingRegistry()
end

function Library:SetFont(font)
	if type(font) == "string" then
		if font == "Sentinel" then
			font = Font.new(PIXEL_FONT)
		else
			local ok, resolved = pcall(function()
				return Font.fromEnum(Enum.Font[font])
			end)
			font = ok and resolved or nil
		end
	elseif typeof(font) == "EnumItem" then
		font = Font.fromEnum(font)
	end
	if typeof(font) ~= "Font" then
		return
	end
	Library.Font = font
	Templates.TextLabel.FontFace = font
	Templates.TextButton.FontFace = font
	Templates.TextBox.FontFace = font
	if not Library.ScreenGui then
		return
	end
	for _, inst in Library.ScreenGui:GetDescendants() do
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			pcall(function()
				inst.FontFace = font
			end)
		end
	end
end

-- rows, buttons and headers are all fixed pixel heights, so past the middle teens the glyphs simply outgrow them; GUI Scale is what makes the whole menu bigger
function Library:SetFontSize(size)
	size = math.clamp(math.floor(tonumber(size) or 12), 8, 16)
	Library.FontSize = size
	Templates.TextLabel.TextSize = size
	Templates.TextButton.TextSize = size
	Templates.TextBox.TextSize = size
	if not Library.ScreenGui then
		return
	end
	for _, inst in Library.ScreenGui:GetDescendants() do
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			pcall(function()
				inst.TextSize = size
			end)
		end
	end
end

local ScaleRoots = {}

-- one UIScale per top level window rather than one over everything, since a UIScale does not touch its own frame's Position and dragging stays in screen pixels
local function ScaleRoot(frame)
	local scale = New("UIScale", { Parent = frame, Scale = Library.GuiScale or 1 })
	table.insert(ScaleRoots, scale)
	return scale
end

function Library:SetGuiScale(scale)
	scale = math.clamp(tonumber(scale) or 1, 0.5, 2)
	Library.GuiScale = scale
	for i = #ScaleRoots, 1, -1 do
		local root = ScaleRoots[i]
		if root.Parent == nil then
			table.remove(ScaleRoots, i)
		else
			root.Scale = scale
		end
	end
	return scale
end

local function IsMouseInput(input, includeM2)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or (includeM2 == true and input.UserInputType == Enum.UserInputType.MouseButton2)
		or input.UserInputType == Enum.UserInputType.Touch
end
local function IsClickInput(input, includeM2)
	return IsMouseInput(input, includeM2)
		and input.UserInputState == Enum.UserInputState.Begin
		and Library.IsRobloxFocused
end
local function IsHoverInput(input)
	return (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
		and input.UserInputState == Enum.UserInputState.Change
end
local function IsDragInput(input)
	return IsMouseInput(input)
		and (input.UserInputState == Enum.UserInputState.Begin or input.UserInputState == Enum.UserInputState.Change)
		and Library.IsRobloxFocused
end

local function Round(value, rounding)
	rounding = rounding or 0
	if rounding == 0 then
		return math.floor(value + 0.5)
	end
	local mult = 10 ^ rounding
	return math.floor(value * mult + 0.5) / mult
end

local function Trim(text)
	return text:match("^%s*(.-)%s*$")
end

local DISABLED_TEXT_FADE = 0.6
local DISABLED_FILL_FADE = 0.65

-- recolor by scheme key and repoint the registry so the color survives theme swaps
local function SetSchemeText(label, key, fallbackKey)
	key = key or fallbackKey
	local color = Scheme[key]
	if color == nil then
		return
	end
	label.TextColor3 = color
	local reg = Library.Registry[label]
	if not reg then
		reg = {}
		Library.Registry[label] = reg
	end
	reg.TextColor3 = key
end

-- greys via transparency only (never color props) so it can't fight the theme registry; fully reversible
local function MakeDisableable(handle, fades, setInteractive)
	handle.Disabled = handle.Disabled == true
	function handle:SetDisabled(state)
		state = state and true or false
		self.Disabled = state
		for _, f in fades do
			pcall(function()
				f[1][f[2]] = state and f[3] or f[4]
			end)
		end
		if setInteractive then
			setInteractive(not state)
		end
	end
end

local function MakeRecolorable(handle, label, defaultKey)
	handle.TextLabel = label
	handle.DefaultTextKey = defaultKey or "FontColor"
	function handle:SetTextColorKey(key)
		SetSchemeText(label, key, self.DefaultTextKey)
	end
end

function Library:GiveSignal(connection)
	local t = typeof(connection)
	if connection and (t == "RBXScriptConnection" or t == "RBXScriptSignal") then
		table.insert(Library.Signals, connection)
	end
	return connection
end

function Library:SafeCallback(func, ...)
	if typeof(func) ~= "function" then
		return
	end
	local args = { ... }
	local ok, err = pcall(function()
		return func(table.unpack(args))
	end)
	if not ok then
		warn("[Sentinel] callback error: " .. tostring(err))
	end
end

function Library:MouseIsOverFrame(frame, position)
	local pos, size = frame.AbsolutePosition, frame.AbsoluteSize
	return position.X >= pos.X
		and position.X <= pos.X + size.X
		and position.Y >= pos.Y
		and position.Y <= pos.Y + size.Y
end

function Library:Validate(table_, template)
	if typeof(table_) ~= "table" then
		table_ = {}
	end
	for key, value in template do
		if typeof(key) == "number" then
			continue
		end
		if typeof(value) == "table" then
			table_[key] = Library:Validate(table_[key], value)
		elseif table_[key] == nil then
			table_[key] = value
		end
	end
	return table_
end

local KeyShortNames = {
	[Enum.KeyCode.LeftControl] = "lc",
	[Enum.KeyCode.RightControl] = "rc",
	[Enum.KeyCode.LeftShift] = "ls",
	[Enum.KeyCode.RightShift] = "rs",
	[Enum.KeyCode.LeftAlt] = "la",
	[Enum.KeyCode.RightAlt] = "ra",
	[Enum.KeyCode.Space] = "space",
	[Enum.UserInputType.MouseButton1] = "mb1",
	[Enum.UserInputType.MouseButton2] = "mb2",
	[Enum.UserInputType.MouseButton3] = "mb3",
}
function Library:GetKeyString(key)
	if KeyShortNames[key] then
		return KeyShortNames[key]
	end
	if typeof(key) == "EnumItem" then
		return key.Name:lower()
	end
	return tostring(key):lower()
end

local WindowShells = {}
local function MakeWindowShell(parent, size, position, titleText)
	local Outline = New("Frame", {
		Parent = parent,
		BackgroundColor3 = "Outline",
		BorderColor3 = "Border",
		Position = position or UDim2.fromOffset(0, 0),
		Size = size,
	})
	if parent == Library.ScreenGui then
		ScaleRoot(Outline)
		table.insert(WindowShells, Outline)
	end
	local Accent = New("Frame", {
		Parent = Outline,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
	})
	local Body = New("Frame", {
		Parent = Accent,
		BackgroundColor3 = "Body",
		BorderColor3 = "Border",
		BackgroundTransparency = 0.76,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
	})
	New("UIPadding", {
		Parent = Body,
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 4),
	})
	local Title
	if titleText then
		Title = New("TextLabel", {
			Parent = Body,
			Name = "Title",
			Text = titleText,
			TextColor3 = "FontColor",
			TextStrokeTransparency = 0,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.fromOffset(0, 2),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Interactable = false,
		})
	end
	return { Outline = Outline, Accent = Accent, Body = Body, Title = Title }
end

local function MakePanel(parent, size, position)
	local Outline = New("Frame", {
		Parent = parent,
		BackgroundColor3 = "Outline",
		BorderColor3 = "Border",
		Size = size,
		Position = position or UDim2.fromOffset(0, 0),
	})
	local Inline = New("Frame", {
		Parent = Outline,
		BackgroundColor3 = "Inline",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		ZIndex = 2,
	})
	local Body = New("Frame", {
		Parent = Inline,
		BackgroundColor3 = "Body",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
	})
	return Outline, Inline, Body
end

local function ParentUI(ui)
	pcall(protectgui, ui)
	local ok = pcall(function()
		ui.Parent = gethui()
	end)
	if not (ok and ui.Parent) then
		ui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
end

local ScreenGui = New("ScreenGui", {
	Name = "\0" .. string.rep(" ", 6),
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	ResetOnSpawn = false,
	DisplayOrder = 999,
})
ParentUI(ScreenGui)
Library.ScreenGui = ScreenGui

Library:GiveSignal(ScreenGui.DescendantRemoving:Connect(function(instance)
	if Library.Registry[instance] then
		Library.Registry[instance] = nil
	end
end))

-- Drawing-based cursor in true screen space; the tip (PointA) lands exactly on the OS cursor
local Cursor, CursorOutline
do
	if Drawing then
		Cursor = Drawing.new("Triangle")
		Cursor.Filled = true
		Cursor.Thickness = 1
		Cursor.Color = Color3.fromRGB(255, 255, 255)
		Cursor.Visible = false
		Cursor.ZIndex = 11000
		CursorOutline = Drawing.new("Triangle")
		CursorOutline.Filled = false
		CursorOutline.Thickness = 1
		CursorOutline.Color = Color3.fromRGB(0, 0, 0)
		CursorOutline.Visible = false
		CursorOutline.ZIndex = 11001
	end
end
Library.Cursor = Cursor

local function drawCursor(visible)
	if not Cursor then
		return
	end
	if visible then
		local m = UserInputService:GetMouseLocation()
		local a = Vector2.new(m.X, m.Y)
		local b = Vector2.new(m.X + 14, m.Y + 5)
		local c = Vector2.new(m.X + 5, m.Y + 14)
		Cursor.PointA, Cursor.PointB, Cursor.PointC = a, b, c
		if CursorOutline then
			CursorOutline.PointA, CursorOutline.PointB, CursorOutline.PointC = a, b, c
		end
	end
	Cursor.Visible = visible
	if CursorOutline then
		CursorOutline.Visible = visible
	end
end

function Library:MakeDraggable(ui, dragFrame, isMainWindow)
	local startPos, framePos
	local dragging = false
	local changed

	dragFrame.InputBegan:Connect(function(input)
		if not IsClickInput(input) then
			return
		end
		startPos = input.Position
		framePos = ui.Position
		dragging = true
		changed = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				if changed then
					changed:Disconnect()
					changed = nil
				end
			end
		end)
	end)

	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if (isMainWindow and not Library.Toggled) or not (ScreenGui and ScreenGui.Parent) then
			dragging = false
			return
		end
		if dragging and IsHoverInput(input) then
			local delta = input.Position - startPos
			ui.Position = UDim2.new(
				framePos.X.Scale,
				framePos.X.Offset + delta.X,
				framePos.Y.Scale,
				framePos.Y.Offset + delta.Y
			)
		end
	end))
end

-- drag a corner handle to resize `ui`, clamped to min/max; returns a clamped setSize(w, h)
function Library:MakeResizable(ui, handle, minSize, maxSize)
	minSize = minSize or Vector2.new(120, 80)
	maxSize = maxSize or Vector2.new(800, 600)

	local function setSize(w, h)
		w = math.clamp(w, minSize.X, maxSize.X)
		h = math.clamp(h, minSize.Y, maxSize.Y)
		ui.Size = UDim2.fromOffset(w, h)
		return w, h
	end

	local startPos, startSize
	local resizing = false
	local changed

	handle.InputBegan:Connect(function(input)
		if not IsClickInput(input) then
			return
		end
		startPos = input.Position
		startSize = ui.Size
		resizing = true
		changed = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				resizing = false
				if changed then
					changed:Disconnect()
					changed = nil
				end
			end
		end)
	end)

	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if not (ScreenGui and ScreenGui.Parent) then
			resizing = false
			return
		end
		if resizing and IsHoverInput(input) then
			local delta = input.Position - startPos
			setSize(startSize.X.Offset + delta.X, startSize.Y.Offset + delta.Y)
		end
	end))

	return setSize
end

-- the grip lives inside the window it scales, so the drag is measured against the unscaled size: pulling the corner out a tenth of the width is a tenth more scale
function Library:MakeScalable(ui, handle)
	local startPos, startScale
	local scaling = false
	local changed

	handle.InputBegan:Connect(function(input)
		if not IsClickInput(input) then
			return
		end
		startPos = input.Position
		startScale = Library.GuiScale or 1
		scaling = true
		changed = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				scaling = false
				if changed then
					changed:Disconnect()
					changed = nil
				end
			end
		end)
	end)

	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if not (ScreenGui and ScreenGui.Parent) then
			scaling = false
			return
		end
		if not (scaling and IsHoverInput(input)) then
			return
		end
		local width, height = ui.Size.X.Offset, ui.Size.Y.Offset
		if width <= 0 or height <= 0 then
			return
		end
		local delta = input.Position - startPos
		local applied = Library:SetGuiScale(startScale + (delta.X / width + delta.Y / height) / 2)
		if Library.Options.MenuGuiScale then
			Library.Options.MenuGuiScale:SetValue(applied)
		end
	end))
end

local CurrentMenu
function Library:MouseIsOverWindow(position)
	for i = #WindowShells, 1, -1 do
		local outline = WindowShells[i]
		if not outline.Parent then
			table.remove(WindowShells, i)
		elseif outline.Visible and self:MouseIsOverFrame(outline, position) then
			return true
		end
	end
	return CurrentMenu ~= nil and CurrentMenu.Menu.Visible and self:MouseIsOverFrame(CurrentMenu.Menu, position)
end

function Library:AddContextMenu(holder, size, offset, list)
	local Menu
	if list then
		Menu = New("ScrollingFrame", {
			Parent = ScreenGui,
			BackgroundTransparency = 1,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.fromOffset(0, 0),
			ScrollBarThickness = 0,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = typeof(size) == "function" and size() or size,
			Visible = false,
			ZIndex = 50,
		})
	else
		Menu = New("Frame", {
			Parent = ScreenGui,
			BackgroundTransparency = 1,
			Size = typeof(size) == "function" and size() or size,
			Visible = false,
			ZIndex = 50,
		})
	end
	ScaleRoot(Menu)

	local Table = { Active = false, Holder = holder, Menu = Menu, Signal = nil, Size = size }

	local function reposition()
		local o = typeof(offset) == "function" and offset() or offset
		Menu.Position = UDim2.fromOffset(
			math.floor(holder.AbsolutePosition.X + o[1]),
			math.floor(holder.AbsolutePosition.Y + o[2])
		)
	end

	function Table:Open()
		if CurrentMenu == Table then
			return
		elseif CurrentMenu then
			CurrentMenu:Close()
		end
		CurrentMenu = Table
		Table.Active = true
		Menu.Size = typeof(Table.Size) == "function" and Table.Size() or Table.Size
		reposition()
		Menu.Visible = true
		Table.Signal = holder:GetPropertyChangedSignal("AbsolutePosition"):Connect(reposition)
	end

	function Table:Close()
		if CurrentMenu ~= Table then
			return
		end
		Menu.Visible = false
		if Table.Signal then
			Table.Signal:Disconnect()
			Table.Signal = nil
		end
		Table.Active = false
		CurrentMenu = nil
	end

	function Table:Toggle()
		if Table.Active then
			Table:Close()
		else
			Table:Open()
		end
	end

	function Table:SetSize(newSize)
		Table.Size = newSize
		Menu.Size = typeof(newSize) == "function" and newSize() or newSize
	end

	return Table
end

Library:GiveSignal(UserInputService.InputBegan:Connect(function(input)
	if Library.Unloaded then
		return
	end
	if IsClickInput(input, true) and CurrentMenu then
		local pos = input.Position
		if
			not (
				Library:MouseIsOverFrame(CurrentMenu.Menu, pos)
				or Library:MouseIsOverFrame(CurrentMenu.Holder, pos)
			)
		then
			CurrentMenu:Close()
		end
	end
end))

local TooltipFrame = New("Frame", {
	Parent = ScreenGui,
	BackgroundColor3 = "Dark",
	BorderColor3 = "DarkBorder",
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	Visible = false,
	ZIndex = 60,
})
ScaleRoot(TooltipFrame)
New("UIPadding", {
	Parent = TooltipFrame,
	PaddingTop = UDim.new(0, 1),
	PaddingBottom = UDim.new(0, 1),
	PaddingLeft = UDim.new(0, 1),
	PaddingRight = UDim.new(0, 1),
})
local TooltipInner = New("Frame", {
	Parent = TooltipFrame,
	BackgroundColor3 = "Element",
	BorderColor3 = "ElementBorder",
	BorderSizePixel = 1,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	ZIndex = 60,
})
New("UIPadding", {
	Parent = TooltipInner,
	PaddingTop = UDim.new(0, 2),
	PaddingBottom = UDim.new(0, 4),
	PaddingLeft = UDim.new(0, 4),
	PaddingRight = UDim.new(0, 4),
})
local TooltipLabel = New("TextLabel", {
	Parent = TooltipInner,
	Text = "",
	TextColor3 = "FontColor",
	TextStrokeTransparency = 0,
	BackgroundTransparency = 1,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 14),
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 61,
})
local CurrentHover
function Library:AddTooltip(infoStr, hoverInstance)
	if typeof(infoStr) ~= "string" then
		return
	end
	local tip = { Signals = {} }
	local function doHover()
		if CurrentHover == hoverInstance or (CurrentMenu and Library:MouseIsOverFrame(CurrentMenu.Menu, Mouse)) then
			return
		end
		if not (Library.Toggled and Library:MouseIsOverFrame(hoverInstance, Mouse)) then
			return
		end
		CurrentHover = hoverInstance
		TooltipLabel.Text = infoStr
		while
			Library.Toggled
			and Library:MouseIsOverFrame(hoverInstance, Mouse)
			and not (CurrentMenu and Library:MouseIsOverFrame(CurrentMenu.Menu, Mouse))
		do
			TooltipFrame.Visible = true
			TooltipFrame.Position = UDim2.fromOffset(Mouse.X + 14, Mouse.Y + 12)
			RunService.RenderStepped:Wait()
		end
		TooltipFrame.Visible = false
		CurrentHover = nil
	end
	table.insert(tip.Signals, hoverInstance.MouseEnter:Connect(doHover))
	table.insert(tip.Signals, hoverInstance.MouseMoved:Connect(doHover))
	table.insert(
		tip.Signals,
		hoverInstance.MouseLeave:Connect(function()
			if CurrentHover == hoverInstance then
				TooltipFrame.Visible = false
				CurrentHover = nil
			end
		end)
	)
	function tip:Destroy()
		for _, c in tip.Signals do
			if c.Connected then
				c:Disconnect()
			end
		end
	end
	Library:OnUnload(function()
		tip:Destroy()
	end)
	return tip
end

local NotifyHolder, NotifyLayout
local function notifyOnLeft()
	-- lenient: "Left"/"left"/"LeftSide" all count as left, anything else is right
	return tostring(Library.NotifySide):lower():sub(1, 1) == "l"
end
local function positionNotifyHolder()
	if not NotifyHolder then
		return
	end
	local left = notifyOnLeft()
	NotifyHolder.AnchorPoint = Vector2.new(left and 0 or 1, 0)
	NotifyHolder.Position = left and UDim2.fromOffset(16, 16) or UDim2.new(1, -16, 0, 16)
	NotifyLayout.HorizontalAlignment = left and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Right
end
function Library:SetNotifySide(side)
	Library.NotifySide = side
	positionNotifyHolder()
end
function Library:Notify(info, time)
	local title, body, persist
	local richText = false
	if typeof(info) == "table" then
		title = info.Title
		body = info.Description
		persist = info.Persist == true
		richText = info.RichText == true
		if info.Time ~= nil then
			time = info.Time
		end
	else
		title = tostring(info)
	end
	-- a lone Description (no Title) renders as the single line
	if title == nil and body ~= nil then
		title, body = body, nil
	end
	title = title or ""

	if time == nil then
		time = 3
	end
	if type(time) ~= "number" or time <= 0 then
		persist = true
	end

	if not NotifyHolder then
		NotifyHolder = New("Frame", {
			Parent = ScreenGui,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 260, 1, -32),
			ZIndex = 200,
		})
		ScaleRoot(NotifyHolder)
		NotifyLayout = New("UIListLayout", {
			Parent = NotifyHolder,
			Padding = UDim.new(0, 8),
		})
	end
	positionNotifyHolder()
	local onLeft = notifyOnLeft()

	local outer = New("Frame", {
		Parent = NotifyHolder,
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(0, 248, 0, 0),
		ZIndex = 200,
	})
	New("UIPadding", {
		Parent = outer,
		PaddingTop = UDim.new(0, 1),
		PaddingBottom = UDim.new(0, 1),
		PaddingLeft = UDim.new(0, 1),
		PaddingRight = UDim.new(0, 1),
	})
	local inner = New("Frame", {
		Parent = outer,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		-- centered so the 2px slack splits 1px/1px (even dark frame) instead of all landing on the right edge
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, -2, 0, 0),
		ZIndex = 200,
	})
	local content = New("Frame", {
		Parent = inner,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		ZIndex = 201,
	})
	New("UIListLayout", { Parent = content, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) })
	New("UIPadding", {
		Parent = content,
		PaddingTop = UDim.new(0, 7),
		PaddingBottom = UDim.new(0, 9),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	})

	local titleLabel = New("TextLabel", {
		Parent = content,
		Text = title,
		TextColor3 = "FontColor",
		TextStrokeTransparency = 0,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 14,
		RichText = richText,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		LayoutOrder = 1,
		ZIndex = 201,
	})

	local bodyLabel
	if body and body ~= "" then
		bodyLabel = New("TextLabel", {
			Parent = content,
			Text = body,
			TextColor3 = "DimColor",
			TextStrokeTransparency = 0.5,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 12),
			TextSize = 12,
			RichText = richText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			LayoutOrder = 2,
			ZIndex = 201,
		})
	end

	-- anchored to the notify side's edge so the bar empties toward the nearest screen edge
	local bar = New("Frame", {
		Parent = inner,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		AnchorPoint = Vector2.new(onLeft and 0 or 1, 1),
		Position = onLeft and UDim2.new(0, 0, 1, 0) or UDim2.new(1, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 2),
		ZIndex = 202,
	})

	local handle = { Object = outer, Inner = inner, AccentBar = bar, TitleLabel = titleLabel, BodyLabel = bodyLabel }

	if not persist then
		local drain = TweenService:Create(
			bar,
			TweenInfo.new(time, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
			{ Size = UDim2.new(0, 0, 0, 2) }
		)
		local dismissConn
		local function dismiss()
			if dismissConn then
				dismissConn:Disconnect()
				dismissConn = nil
			end
			pcall(function()
				drain:Cancel()
			end)
			pcall(function()
				outer:Destroy()
			end)
		end
		-- these used to go to GiveSignal and OnUnload, so every notification ever shown grew both lists for good and the unload closure held the destroyed frame alive through the tween
		dismissConn = drain.Completed:Connect(dismiss)
		drain:Play()
		handle.Tween = drain
	end

	return handle
end

local Funcs = {}
local BaseAddons = {}

local function applyTooltip(handle, info, instance)
  handle.ConfigInstance=instance
	if info.Tooltip then
		Library:AddTooltip(info.Tooltip, instance)
	end
end

local function indexElement(self, row, text)
	if not (row and self and self.Record) then
		return
	end
	local entry = {
		Text = tostring(text or ""):lower(),
		Row = row,
		Reveal = self.Reveal,
		Tab = self.Tab,
		Record = self.Record,
		Column = self.Column,
		Dimmed = false,
	}
	table.insert(Library.SearchIndex, entry)
	table.insert(self.Record.Entries, entry)
	return entry
end

function Funcs:AddLabel(info, doesWrap)
	if typeof(info) == "string" then
		info = { Text = info, DoesWrap = doesWrap }
	end
	info = Library:Validate(info, { Text = "Label", DoesWrap = false, Visible = true })

	local Holder = New("Frame", {
		Parent = self.Container,
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 12),
		AutomaticSize = info.DoesWrap and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		Visible = info.Visible,
	})
	local TextLabel = New("TextLabel", {
		Parent = Holder,
		Text = info.Text,
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		Size = info.DoesWrap and UDim2.new(1, 0, 0, 12) or UDim2.fromOffset(0, 12),
		AutomaticSize = info.DoesWrap and Enum.AutomaticSize.Y or Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = info.DoesWrap,
	})

	local Label = { Text = info.Text, Type = "Label", TextLabel = TextLabel, Holder = Holder, AddonContainer = nil }
	Label.SearchEntry = indexElement(self, Holder, info.Text)

	local Right = New("Frame", {
		Parent = Holder,
		Name = "RightContainer",
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 1),
		Size = UDim2.fromOffset(0, 12),
	})
	New("UIListLayout", {
		Parent = Right,
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 3),
	})
	Label.AddonContainer = Right

	function Label:SetText(text)
		Label.Text = text
		TextLabel.Text = text
	end
	function Label:SetVisible(v)
		Holder.Visible = v
	end

	MakeRecolorable(Label, TextLabel, "DimColor")
	MakeDisableable(Label, {
		{ TextLabel, "TextTransparency", DISABLED_TEXT_FADE, 0 },
	})

	applyTooltip(Label, info, TextLabel)
	setmetatable(Label, { __index = BaseAddons })
	return Label
end

function Funcs:AddDivider()
	local Holder = New("Frame", {
		Parent = self.Container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 5),
	})
	New("Frame", {
		Parent = Holder,
		BackgroundColor3 = "Divider",
		BorderColor3 = "Border",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 1),
	})
	return { Type = "Divider", Holder = Holder }
end

function Funcs:AddButton(info, func)
	if typeof(info) == "string" then
		info = { Text = info, Func = func }
	end
	info = Library:Validate(info, { Text = "Button", Func = function() end, DoubleClick = false, Disabled = false })

	local Holder = New("Frame", {
		Parent = self.Container,
		Name = "Button",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
	})
	New("UIListLayout", {
		Parent = Holder,
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 3),
	})

	local Button = { Type = "Button", Holder = Holder }
	local bases = {}

	local function makeSub(subInfo)
		local Wrapper = New("Frame", {
			Parent = Holder,
			BackgroundColor3 = "Border",
			BorderColor3 = "DarkBorder",
			Size = UDim2.fromScale(1, 1),
		})
		New("UIFlexItem", { Parent = Wrapper, FlexMode = Enum.UIFlexMode.Fill })
		local Base = New("TextButton", {
			Parent = Wrapper,
			Text = subInfo.Text,
			TextColor3 = "DimColor",
			TextStrokeTransparency = 0,
			BackgroundColor3 = "Element",
			BorderColor3 = "ElementBorder",
			BorderSizePixel = 1,
			Position = UDim2.fromOffset(2, 2),
			Size = UDim2.new(1, -4, 1, -4),
		})

		local Sub = { Text = subInfo.Text, Func = subInfo.Func, Base = Base }
		table.insert(bases, Base)
		local lastClick = 0
		Base.MouseButton1Click:Connect(function()
			if subInfo.Disabled then
				return
			end
			if subInfo.DoubleClick then
				local now = os.clock()
				if now - lastClick > 0.4 then
					lastClick = now
					Base.Text = "are you sure?"
					return
				end
				Base.Text = subInfo.Text
			end
			Library:SafeCallback(Sub.Func)
		end)
		Base.MouseEnter:Connect(function()
			Base.BackgroundColor3 = Library.Scheme.ElementBorder
		end)
		Base.MouseLeave:Connect(function()
			Base.BackgroundColor3 = Library.Scheme.Element
			if subInfo.DoubleClick then
				Base.Text = subInfo.Text
			end
		end)
		function Sub:SetText(text)
			Sub.Text = text
			Base.Text = text
		end
		applyTooltip(Sub, subInfo, Base)
		return Sub
	end

	local main = makeSub(info)
	indexElement(self, Holder, info.Text)
	Button.SetText = function(_, text)
		main:SetText(text)
	end

	MakeRecolorable(Button, main.Base, "DimColor")
	local buttonFades = {}
	for _, b in bases do
		table.insert(buttonFades, { b, "TextTransparency", DISABLED_TEXT_FADE, 0 })
		table.insert(buttonFades, { b, "BackgroundTransparency", DISABLED_FILL_FADE, 0 })
	end
	MakeDisableable(Button, buttonFades, function(on)
		for _, b in bases do
			b.Interactable = on
		end
	end)
	if info.Disabled then
		Button:SetDisabled(true)
	end

	function Button:AddButton(subInfo, subFunc)
		if typeof(subInfo) == "string" then
			subInfo = { Text = subInfo, Func = subFunc }
		end
		subInfo = Library:Validate(subInfo, { Text = "Button", Func = function() end, DoubleClick = false, Disabled = false })
		return makeSub(subInfo)
	end

	return Button
end

function Funcs:AddToggle(idx, info)
	info = Library:Validate(info, {
		Text = "Toggle",
		Default = false,
		Callback = function() end,
		Changed = function() end,
		Disabled = false,
		Visible = true,
	})

	local Toggle = {
		Value = info.Default and true or false,
		Type = "Toggle",
		Text = info.Text,
		Callback = info.Callback,
		Changed = info.Changed,
		Addons = {},
		OnChangedFns = {},
	}

	local Holder = New("TextButton", {
		Parent = self.Container,
		Name = "Toggle",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Visible = info.Visible,
	})

	local Box = New("TextButton", {
		Parent = Holder,
		Text = "",
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Position = UDim2.fromOffset(0, 1),
		Size = UDim2.fromOffset(10, 10),
	})
	local Inner = New("Frame", {
		Parent = Box,
		BackgroundColor3 = "ElementFill",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
	})
	local Fill = New("Frame", {
		Parent = Inner,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		Size = UDim2.fromScale(1, 1),
		Visible = Toggle.Value,
	})

	local Label = New("TextLabel", {
		Parent = Holder,
		Name = "Text",
		Text = info.Text,
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -14, 0, 14),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
	})

	local Right = New("Frame", {
		Parent = Holder,
		Name = "RightContainer",
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 1),
		Size = UDim2.fromScale(0, 1),
	})
	New("UIListLayout", {
		Parent = Right,
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 3),
	})
	Toggle.AddonContainer = Right
	Toggle.TextLabel = Label
	Toggle.Holder = Holder
	Toggle.SearchEntry = indexElement(self, Holder, info.Text)

	function Toggle:Display()
		Fill.Visible = Toggle.Value
	end
	function Toggle:OnChanged(func)
		table.insert(Toggle.OnChangedFns, func)
		Library:SafeCallback(func, Toggle.Value)
	end
	function Toggle:SetValue(value)
		value = value and true or false
		-- features call SetValue(true) to mean "make sure this is on", and re-running the callback on a toggle already on is what stacked a second copy of its loop
		local changed = Toggle.Value ~= value
		Toggle.Value = value
		Toggle:Display()
		if not changed then
			return
		end
		Library:SafeCallback(Toggle.Changed, Toggle.Value)
		Library:SafeCallback(Toggle.Callback, Toggle.Value)
		for _, func in Toggle.OnChangedFns do
			Library:SafeCallback(func, Toggle.Value)
		end
	end
	function Toggle:GetValue()
		return Toggle.Value
	end
	function Toggle:SetText(text)
		Toggle.Text = text
		Label.Text = text
	end
	function Toggle:SetVisible(v)
		Holder.Visible = v
	end

	local function flip()
		if Toggle.Disabled then
			return
		end
		Toggle:SetValue(not Toggle.Value)
	end
	Holder.MouseButton1Click:Connect(flip)
	Box.MouseButton1Click:Connect(flip)

	MakeRecolorable(Toggle, Label, "DimColor")
	-- no setInteractive: the flip guard blocks clicks, but staying Interactable keeps the tooltip working
	MakeDisableable(Toggle, {
		{ Label, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Fill, "BackgroundTransparency", DISABLED_FILL_FADE, 0 },
	})
	if info.Disabled then
		Toggle:SetDisabled(true)
	end

	Toggle:Display()
	applyTooltip(Toggle, info, Holder)
	Library.Toggles[idx] = Toggle
	setmetatable(Toggle, { __index = BaseAddons })
	return Toggle
end

function Funcs:AddInput(idx, info)
	info = Library:Validate(info, {
		Text = "",
		Default = "",
		Placeholder = "type here...",
		Numeric = false,
		Finished = false,
		ClearTextOnFocus = false,
		Callback = function() end,
		Changed = function() end,
		Visible = true,
	})

	local Input = {
		Value = info.Default or "",
		Type = "Input",
		Callback = info.Callback,
		Changed = info.Changed,
		OnChangedFns = {},
	}

	local Caption
	if info.Text and info.Text ~= "" then
		Caption = Funcs.AddLabel(self, { Text = info.Text })
	end

	local Holder = New("Frame", {
		Parent = self.Container,
		Name = "Textbox",
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Size = UDim2.new(1, 0, 0, 16),
		Visible = info.Visible,
	})
	local Box = New("TextBox", {
		Parent = Holder,
		Text = info.Default or "",
		PlaceholderText = info.Placeholder,
		PlaceholderColor3 = Color3.fromRGB(90, 90, 90),
		TextColor3 = "FontColor",
		TextStrokeTransparency = 0.5,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		ClearTextOnFocus = info.ClearTextOnFocus,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	New("UIPadding", { Parent = Box, PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) })

	Input.Holder = Holder
	Input.TextBox = Box
	indexElement(self, Holder, info.Text)

	function Input:OnChanged(func)
		table.insert(Input.OnChangedFns, func)
		Library:SafeCallback(func, Input.Value)
	end
	local function fire()
		Library:SafeCallback(Input.Changed, Input.Value)
		Library:SafeCallback(Input.Callback, Input.Value)
		for _, func in Input.OnChangedFns do
			Library:SafeCallback(func, Input.Value)
		end
	end
	function Input:SetValue(text)
		text = tostring(text)
		if info.Numeric then
			text = text:gsub("[^%d%.%-]", "")
		end
		Input.Value = text
		Box.Text = text
		fire()
	end
	-- the caption is a separate element, so hiding the box alone would leave its label floating
	function Input:SetVisible(v)
		Holder.Visible = v and true or false
		if Caption and Caption.SetVisible then
			Caption:SetVisible(v)
		end
	end
	function Input:GetValue()
		return Input.Value
	end

	Box:GetPropertyChangedSignal("Text"):Connect(function()
		if info.Numeric then
			local cleaned = Box.Text:gsub("[^%d%.%-]", "")
			if cleaned ~= Box.Text then
				Box.Text = cleaned
				return
			end
		end
		if not info.Finished then
			Input.Value = Box.Text
			fire()
		end
	end)
	Box.FocusLost:Connect(function()
		Input.Value = Box.Text
		fire()
	end)

	MakeRecolorable(Input, Box, "FontColor")
	MakeDisableable(Input, {
		{ Box, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Box, "BackgroundTransparency", DISABLED_FILL_FADE, 0 },
	}, function(on)
		Box.TextEditable = on
	end)

	applyTooltip(Input, info, Holder)
	Library.Options[idx] = Input
	return Input
end

function Funcs:AddSlider(idx, info)
	info = Library:Validate(info, {
		Text = "Slider",
		Default = 0,
		Min = 0,
		Max = 100,
		Rounding = 0,
		Prefix = "",
		Suffix = "",
		Callback = function() end,
		Changed = function() end,
		Visible = true,
	})

	local Slider = {
		Value = info.Default,
		Min = info.Min,
		Max = info.Max,
		Rounding = info.Rounding,
		Prefix = info.Prefix,
		Suffix = info.Suffix,
		Type = "Slider",
		Text = info.Text,
		Callback = info.Callback,
		Changed = info.Changed,
		OnChangedFns = {},
	}

	local Holder = New("TextLabel", {
		Parent = self.Container,
		Name = "Slider",
		Text = info.Text,
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Visible = info.Visible,
	})

	local Bar = New("TextButton", {
		Parent = Holder,
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Position = UDim2.new(0.5, 0, 0, 18),
		Size = UDim2.new(1, -26, 0, 8),
	})
	New("Frame", {
		Parent = Bar,
		BackgroundColor3 = "ElementFill",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
	})
	local Fill = New("Frame", {
		Parent = Bar,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(0, 0, 1, -4),
		ZIndex = 2,
	})
	local ValueLabel = New("TextLabel", {
		Parent = Bar,
		Text = "0",
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		TextSize = 12,
	})

	local Minus = New("TextButton", {
		Parent = Bar,
		Text = "-",
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromOffset(-7, 4),
		Size = UDim2.fromOffset(8, 8),
	})
	local Plus = New("TextButton", {
		Parent = Bar,
		Text = "+",
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, 7, 0, 4),
		Size = UDim2.fromOffset(8, 8),
	})

	Slider.Holder = Holder
	indexElement(self, Holder, info.Text)

	function Slider:Display()
		local frac = (Slider.Max - Slider.Min) == 0 and 0 or (Slider.Value - Slider.Min) / (Slider.Max - Slider.Min)
		frac = math.clamp(frac, 0, 1)
		Fill.Size = UDim2.new(frac, frac > 0 and -4 or 0, 1, -4)
		ValueLabel.Text = string.format("%s%s%s", Slider.Prefix, tostring(Slider.Value), Slider.Suffix)
	end
	function Slider:OnChanged(func)
		table.insert(Slider.OnChangedFns, func)
		Library:SafeCallback(func, Slider.Value)
	end
	function Slider:SetValue(value)
		value = math.clamp(Round(value, Slider.Rounding), Slider.Min, Slider.Max)
		Slider.Value = value
		Slider:Display()
		Library:SafeCallback(Slider.Changed, Slider.Value)
		Library:SafeCallback(Slider.Callback, Slider.Value)
		for _, func in Slider.OnChangedFns do
			Library:SafeCallback(func, Slider.Value)
		end
	end
	function Slider:GetValue()
		return Slider.Value
	end
	function Slider:SetMin(v)
		Slider.Min = v
		Slider:SetValue(Slider.Value)
	end
	function Slider:SetMax(v)
		Slider.Max = v
		Slider:SetValue(Slider.Value)
	end
	function Slider:SetVisible(v)
		Holder.Visible = v
	end

	local step = Slider.Rounding == 0 and 1 or 10 ^ -Slider.Rounding
	Minus.MouseButton1Click:Connect(function()
		Slider:SetValue(Slider.Value - step)
	end)
	Plus.MouseButton1Click:Connect(function()
		Slider:SetValue(Slider.Value + step)
	end)

	local dragging = false
	local function moveTo(x)
		local rel = (x - Bar.AbsolutePosition.X) / Bar.AbsoluteSize.X
		Slider:SetValue(Slider.Min + math.clamp(rel, 0, 1) * (Slider.Max - Slider.Min))
	end
	Bar.InputBegan:Connect(function(input)
		if not IsClickInput(input) then
			return
		end
		dragging = true
		moveTo(input.Position.X)
	end)
	Bar.InputEnded:Connect(function(input)
		if IsMouseInput(input) then
			dragging = false
		end
	end)
	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if dragging and IsHoverInput(input) then
			moveTo(input.Position.X)
		end
	end))

	MakeRecolorable(Slider, Holder, "DimColor")
	MakeDisableable(Slider, {
		{ Holder, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ ValueLabel, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Minus, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Plus, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Fill, "BackgroundTransparency", DISABLED_FILL_FADE, 0 },
	}, function(on)
		Bar.Interactable = on
		Minus.Interactable = on
		Plus.Interactable = on
	end)

	Slider:Display()
	applyTooltip(Slider, info, Holder)
	Library.Options[idx] = Slider
	return Slider
end

function Funcs:AddDropdown(idx, info)
	info = Library:Validate(info, {
		Text = "Dropdown",
		Values = {},
		Default = nil,
		Multi = false,
		MaxVisibleDropdownItems = 8,
		Callback = function() end,
		Changed = function() end,
		Visible = true,
	})

	if idx == "FontFace" and not info.Multi then
		local function ensure(name, atFront)
			for _, v in info.Values do
				if v == name then
					return
				end
			end
			table.insert(info.Values, atFront and 1 or #info.Values + 1, name)
		end
		ensure("Sentinel", true)
		ensure(DEFAULT_FONT, false)
		info.Default = DEFAULT_FONT
	end

	local Dropdown = {
		Values = info.Values,
		Value = info.Multi and {} or nil,
		Multi = info.Multi,
		Type = "Dropdown",
		Text = info.Text,
		Callback = info.Callback,
		Changed = info.Changed,
		MaxVisibleDropdownItems = info.MaxVisibleDropdownItems,
		OnChangedFns = {},
	}

	local Holder = New("Frame", {
		Parent = self.Container,
		Name = "Dropdown",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		Visible = info.Visible,
	})
	local TitleLabel = New("TextLabel", {
		Parent = Holder,
		Text = info.Text,
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 12),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local DisplayOuter = New("Frame", {
		Parent = Holder,
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 16),
	})
	local Button = New("TextButton", {
		Parent = DisplayOuter,
		Text = "---",
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	New("UIPadding", { Parent = Button, PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 12) })
	New("TextLabel", {
		Parent = Button,
		Text = "+",
		TextColor3 = "DimColor",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 2, 0.5, 0),
		Size = UDim2.fromOffset(8, 12),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	Dropdown.Holder = Holder
	indexElement(self, Holder, info.Text)

	local Menu = Library:AddContextMenu(DisplayOuter, function()
		return UDim2.fromOffset(DisplayOuter.AbsoluteSize.X, 0)
	end, function()
		return { 0, DisplayOuter.AbsoluteSize.Y + 1 }
	end, 1)

	local ListOuter = New("Frame", {
		Parent = Menu.Menu,
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 50,
	})
	New("UIPadding", {
		Parent = ListOuter,
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 2),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 2),
	})
	local ListInner = New("Frame", {
		Parent = ListOuter,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 50,
	})
	New("UIPadding", {
		Parent = ListInner,
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 2),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 2),
	})
	local ItemList = New("Frame", {
		Parent = ListInner,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 50,
	})
	New("UIListLayout", { Parent = ItemList, Padding = UDim.new(0, 2) })
	New("UIPadding", { Parent = ItemList, PaddingBottom = UDim.new(0, 4) })
	Dropdown.ListBacking = ListOuter

	local ItemButtons = {}

	function Dropdown:GetActiveValues()
		if Dropdown.Multi then
			local out = {}
			for value, state in Dropdown.Value do
				if state then
					table.insert(out, value)
				end
			end
			table.sort(out)
			return out
		end
		return Dropdown.Value
	end

	function Dropdown:Display()
		local text
		if Dropdown.Multi then
			local active = Dropdown:GetActiveValues()
			text = #active > 0 and table.concat(active, ", ") or "---"
		else
			text = Dropdown.Value ~= nil and tostring(Dropdown.Value) or "---"
		end
		Button.Text = text
		for value, btn in ItemButtons do
			local selected
			if Dropdown.Multi then
				selected = Dropdown.Value[value] == true
			else
				selected = Dropdown.Value == value
			end
			btn.TextColor3 = selected and Library.Scheme.FontColor or Library.Scheme.DimColor
			btn.BackgroundTransparency = selected and 0 or 1
		end
	end

	function Dropdown:OnChanged(func)
		table.insert(Dropdown.OnChangedFns, func)
		Library:SafeCallback(func, Dropdown.Value)
	end
	local function fire()
		Library:SafeCallback(Dropdown.Changed, Dropdown.Value)
		Library:SafeCallback(Dropdown.Callback, Dropdown.Value)
		for _, func in Dropdown.OnChangedFns do
			Library:SafeCallback(func, Dropdown.Value)
		end
	end

	function Dropdown:RecalculateListSize()
		local count = #Dropdown.Values
		local visible = math.min(count, Dropdown.MaxVisibleDropdownItems)
		local height = visible * 16 + 8
		Menu:SetSize(UDim2.fromOffset(DisplayOuter.AbsoluteSize.X, height))
	end

	function Dropdown:BuildDropdownList()
		for _, btn in ItemButtons do
			btn:Destroy()
		end
		table.clear(ItemButtons)
		for _, value in Dropdown.Values do
			local Item = New("TextButton", {
				Parent = ItemList,
				Text = tostring(value),
				TextColor3 = "DimColor",
				TextStrokeTransparency = 0.5,
				BackgroundColor3 = "Pop",
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 14),
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 51,
			})
			New("UIPadding", { Parent = Item, PaddingLeft = UDim.new(0, 5) })
			ItemButtons[value] = Item
			Item.MouseButton1Click:Connect(function()
				if Dropdown.Multi then
					Dropdown.Value[value] = not Dropdown.Value[value]
				else
					Dropdown.Value = value
					Menu:Close()
				end
				Dropdown:Display()
				fire()
			end)
		end
		Dropdown:RecalculateListSize()
	end

	function Dropdown:SetValue(value)
		if Dropdown.Multi then
			Dropdown.Value = {}
			if typeof(value) == "table" then
				for k, v in value do
					if type(k) == "number" then
						Dropdown.Value[v] = true
					elseif v then
						Dropdown.Value[k] = true
					end
				end
			end
		else
			Dropdown.Value = value
		end
		Dropdown:Display()
		fire()
	end
	function Dropdown:GetValue()
		return Dropdown.Value
	end
	function Dropdown:SetValues(values)
		Dropdown.Values = values
		Dropdown:BuildDropdownList()
		Dropdown:Display()
	end
	function Dropdown:SetVisible(v)
		Holder.Visible = v
		if not v then
			Menu:Close()
		end
	end

	Button.MouseButton1Click:Connect(function()
		Dropdown:RecalculateListSize()
		Menu:Toggle()
	end)

	Dropdown:BuildDropdownList()

	if info.Default ~= nil then
		if Dropdown.Multi then
			local def = typeof(info.Default) == "table" and info.Default or { info.Default }
			for _, v in def do
				local val = typeof(v) == "number" and Dropdown.Values[v] or v
				if val ~= nil then
					Dropdown.Value[val] = true
				end
			end
		else
			local val = typeof(info.Default) == "number" and Dropdown.Values[info.Default] or info.Default
			Dropdown.Value = val
		end
	end

	MakeRecolorable(Dropdown, TitleLabel, "DimColor")
	MakeDisableable(Dropdown, {
		{ TitleLabel, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Button, "TextTransparency", DISABLED_TEXT_FADE, 0 },
		{ Button, "BackgroundTransparency", DISABLED_FILL_FADE, 0 },
	}, function(on)
		Button.Interactable = on
	end)

	Dropdown:Display()
	applyTooltip(Dropdown, info, Holder)
	Library.Options[idx] = Dropdown
	return Dropdown
end

local SpecialInputs = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
}
local MouseStrings = {
	MB1 = Enum.UserInputType.MouseButton1,
	MB2 = Enum.UserInputType.MouseButton2,
	MB3 = Enum.UserInputType.MouseButton3,
}
local MouseInputToString = {
	[Enum.UserInputType.MouseButton1] = "MB1",
	[Enum.UserInputType.MouseButton2] = "MB2",
	[Enum.UserInputType.MouseButton3] = "MB3",
}
local function ResolveKey(key)
	if typeof(key) == "EnumItem" then
		return key
	end
	if type(key) == "string" then
		if MouseStrings[key] then
			return MouseStrings[key]
		end
		if key == "None" or key == "" then
			return nil
		end
		local ok, code = pcall(function()
			return Enum.KeyCode[key]
		end)
		if ok then
			return code
		end
	end
	return nil
end
local function CanonicalKeyName(bind)
	if bind == nil then
		return "None"
	end
	if MouseInputToString[bind] then
		return MouseInputToString[bind]
	end
	if typeof(bind) == "EnumItem" then
		return bind.Name
	end
	return "None"
end

function BaseAddons:AddKeyPicker(idx, info)
	info = Library:Validate(info, {
		Text = "KeyPicker",
		Default = "None",
		Mode = "Toggle",
		Modes = { "Always", "Toggle", "Hold" },
		SyncToggleState = false,
		NoUI = false,
		Callback = function() end,
		ChangedCallback = function() end,
		Changed = function() end,
	})

	local container = self.AddonContainer
	assert(container, "KeyPicker can only be attached to a Toggle or Label.")

	local KeyPicker = {
		Value = info.Default,
		Mode = info.Mode,
		Modifiers = {},
		Toggled = false,
		Type = "KeyPicker",
		Text = info.Text ~= "KeyPicker" and info.Text or (self.Text or "KeyPicker"),
		Callback = info.Callback,
		ChangedCallback = info.ChangedCallback,
		Changed = info.Changed,
		OnChangedFns = {},
	}

	local function keyLabel()
		return "[" .. (KeyPicker.Value == "None" and "none" or Library:GetKeyString(KeyPicker.Bind or KeyPicker.Value)) .. "]"
	end

	local Picker = New("TextButton", {
		Parent = container,
		Name = "KeybindButton",
		Text = "[none]",
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 16, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local ModeMenu = Library:AddContextMenu(Picker, UDim2.fromOffset(62, 0), function()
		return { Picker.AbsoluteSize.X + 2, 0 }
	end, 1)
	local ModeOuter = New("Frame", {
		Parent = ModeMenu.Menu,
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
	})
	local ModeInner = New("Frame", {
		Parent = ModeOuter,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = 50,
	})
	New("UIListLayout", { Parent = ModeInner, Padding = UDim.new(0, 1) })
	KeyPicker.Bind = ResolveKey(info.Default)

	for _, mode in info.Modes do
		local btn = New("TextButton", {
			Parent = ModeInner,
			Text = mode,
			TextColor3 = "DimColor",
			TextStrokeTransparency = 0.5,
			BackgroundColor3 = "Pop",
			BackgroundTransparency = mode == KeyPicker.Mode and 0 or 1,
			Size = UDim2.new(1, 0, 0, 16),
			ZIndex = 51,
		})
		btn.MouseButton1Click:Connect(function()
			KeyPicker.Mode = mode
			for _, child in ModeInner:GetChildren() do
				if child:IsA("TextButton") then
					child.BackgroundTransparency = child.Text == mode and 0 or 1
				end
			end
			ModeMenu:Close()
			KeyPicker:Update()
		end)
	end

	function KeyPicker:Display()
		Picker.Text = keyLabel()
	end
	function KeyPicker:GetState()
		if KeyPicker.Value == "None" or not KeyPicker.Bind then
			return false
		end
		if KeyPicker.Mode == "Always" then
			return true
		elseif KeyPicker.Mode == "Toggle" then
			return KeyPicker.Toggled
		elseif KeyPicker.Mode == "Hold" then
			if SpecialInputs[KeyPicker.Bind] then
				return UserInputService:IsMouseButtonPressed(KeyPicker.Bind)
			end
			return UserInputService:IsKeyDown(KeyPicker.Bind)
		end
		return false
	end
	function KeyPicker:OnChanged(func)
		table.insert(KeyPicker.OnChangedFns, func)
	end
	function KeyPicker:SetValue(data)
		local key = data
		if type(data) == "table" then
			key = data[1]
			if data[2] then
				KeyPicker.Mode = data[2]
			end
		end
		local bind = ResolveKey(key)
		KeyPicker.Bind = bind
		KeyPicker.Value = CanonicalKeyName(bind)
		KeyPicker:Display()
		KeyPicker:Update()
		Library:SafeCallback(KeyPicker.ChangedCallback, KeyPicker.Value, KeyPicker.Bind)
	end

	local syncToggle = (info.SyncToggleState and self.Type == "Toggle") and self or nil

	local function fireState()
		local state = KeyPicker:GetState()
		Library:SafeCallback(KeyPicker.Callback, state)
		for _, func in KeyPicker.OnChangedFns do
			Library:SafeCallback(func, state)
		end
		Library:UpdateKeybindRow(KeyPicker)
	end

	function KeyPicker:Update()
		Library:UpdateKeybindRow(KeyPicker)
		if KeyPicker.Mode == "Always" then
			fireState()
		end
	end

	local picking = false
	Picker.MouseButton1Click:Connect(function()
		picking = true
		Picker.Text = "[...]"
	end)
	Picker.MouseButton2Click:Connect(function()
		ModeMenu:Toggle()
	end)

	Library:GiveSignal(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if Library.Unloaded or KeyPicker.Disabled then
			return
		end
		if picking then
			if input.UserInputType == Enum.UserInputType.Keyboard then
				if input.KeyCode == Enum.KeyCode.Escape then
					KeyPicker:SetValue("None")
				else
					KeyPicker:SetValue(input.KeyCode)
				end
				picking = false
			elseif SpecialInputs[input.UserInputType] then
				KeyPicker:SetValue(input.UserInputType)
				picking = false
			end
			return
		end

		if gameProcessed or not KeyPicker.Bind or KeyPicker.Value == "None" then
			return
		end
		-- a greyed out toggle is one its gate has refused, and the key it is bound to must not be a way around that
		if KeyPicker.Disabled or (syncToggle and syncToggle.Disabled) then
			return
		end
		local matched = (input.KeyCode == KeyPicker.Bind) or (input.UserInputType == KeyPicker.Bind)
		if not matched then
			return
		end
		if KeyPicker.Mode == "Toggle" then
			KeyPicker.Toggled = not KeyPicker.Toggled
			if syncToggle then
				syncToggle:SetValue(KeyPicker.Toggled)
			else
				fireState()
			end
		elseif KeyPicker.Mode == "Hold" or KeyPicker.Mode == "Press" then
			-- Press: one-shot action fired on key-down (GetState stays false, no toggle state)
			fireState()
		end
	end))
	Library:GiveSignal(UserInputService.InputEnded:Connect(function(input)
		if Library.Unloaded or KeyPicker.Disabled or KeyPicker.Mode ~= "Hold" or not KeyPicker.Bind then
			return
		end
		if (input.KeyCode == KeyPicker.Bind) or (input.UserInputType == KeyPicker.Bind) then
			fireState()
		end
	end))

	MakeRecolorable(KeyPicker, Picker, "DimColor")
	MakeDisableable(KeyPicker, {
		{ Picker, "TextTransparency", DISABLED_TEXT_FADE, 0 },
	}, function(on)
		Picker.Interactable = on
	end)

	if syncToggle then
		syncToggle:OnChanged(function()
			KeyPicker.Toggled = syncToggle.Value
			Library:UpdateKeybindRow(KeyPicker)
		end)
	end

	KeyPicker:SetValue(info.Default)
  KeyPicker.ConfigInstance=Picker
	Library.Options[idx] = KeyPicker
	if not info.NoUI then
		Library:AddKeybindRow(KeyPicker)
	end
	if self.SearchEntry and KeyPicker.Text then
		self.SearchEntry.Text = self.SearchEntry.Text .. " " .. tostring(KeyPicker.Text):lower()
	end
	return self
end

local function HSVToColor(h, s, v)
	return Color3.fromHSV(h, s, v)
end

function BaseAddons:AddColorPicker(idx, info)
	info = Library:Validate(info, {
		Default = Color3.new(1, 1, 1),
		Transparency = 0,
		Title = "Color",
		Callback = function() end,
		Changed = function() end,
	})

	local container = self.AddonContainer
	assert(container, "ColorPicker can only be attached to a Toggle or Label.")

	local ColorPicker = {
		Value = info.Default,
		Transparency = info.Transparency,
		Title = info.Title,
		Type = "ColorPicker",
		Callback = info.Callback,
		Changed = info.Changed,
		OnChangedFns = {},
	}
	local H, S, V = info.Default:ToHSV()
	ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib = H, S, V

	local Display = New("TextButton", {
		Parent = container,
		Name = "ColorpickerButton",
		Text = "",
		BackgroundColor3 = "Border",
		BorderColor3 = "DarkBorder",
		Size = UDim2.fromOffset(16, 10),
		ZIndex = 3,
	})
	local Swatch = New("Frame", {
		Parent = Display,
		BackgroundColor3 = info.Default,
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = 4,
	})

	local Menu = Library:AddContextMenu(Display, UDim2.fromOffset(142, 146), function()
		return { -126, 14 }
	end, false)
	local Shell = MakeWindowShell(Menu.Menu, UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), info.Title)
	Shell.Outline.ZIndex = 50

	local SatOuter = New("Frame", {
		Parent = Shell.Body,
		BackgroundColor3 = "Outline",
		BorderColor3 = "DarkBorder",
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 1, -50),
		ZIndex = 51,
	})
	local SatMap = New("TextButton", {
		Parent = SatOuter,
		Text = "",
		BackgroundColor3 = HSVToColor(H, 1, 1),
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = 51,
	})
	ColorPicker.SatMap = SatMap
	local SatGradientWhite = New("Frame", {
		Parent = SatMap,
		BackgroundColor3 = "White",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 51,
	})
	New("UIGradient", {
		Parent = SatGradientWhite,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
	local SatGradientBlack = New("Frame", {
		Parent = SatMap,
		BackgroundColor3 = Color3.new(0, 0, 0),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 51,
	})
	New("UIGradient", {
		Parent = SatGradientBlack,
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
	local SatCursor = New("Frame", {
		Parent = SatMap,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = "White",
		BorderColor3 = "Border",
		Size = UDim2.fromOffset(3, 3),
		ZIndex = 52,
	})

	local HueOuter = New("Frame", {
		Parent = Shell.Body,
		BackgroundColor3 = "Outline",
		BorderColor3 = "DarkBorder",
		Position = UDim2.new(0, 0, 1, -32),
		Size = UDim2.new(1, 0, 0, 10),
		ZIndex = 51,
	})
	local HueBar = New("TextButton", {
		Parent = HueOuter,
		Text = "",
		BackgroundColor3 = "White",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = 51,
	})
	New("UIGradient", {
		Parent = HueBar,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.667, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
		}),
	})
	local HueCursor = New("Frame", {
		Parent = HueBar,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Color3.fromRGB(204, 41, 41),
		BorderColor3 = Color3.fromRGB(108, 22, 22),
		Size = UDim2.new(0, 1, 1, 0),
		ZIndex = 52,
	})

	local RgbaOuter = New("Frame", {
		Parent = Shell.Body,
		BackgroundColor3 = "Outline",
		BorderColor3 = "DarkBorder",
		Position = UDim2.new(0, 0, 1, -16),
		Size = UDim2.new(1, 0, 0, 14),
		ZIndex = 51,
	})
	local RgbaBox = New("TextBox", {
		Parent = RgbaOuter,
		Text = "",
		PlaceholderText = "r, g, b, a",
		PlaceholderColor3 = Color3.fromRGB(90, 90, 90),
		TextColor3 = "DimColor",
		TextStrokeTransparency = 0.5,
		BackgroundColor3 = "Inline",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		ZIndex = 51,
	})

	function ColorPicker:Display()
		ColorPicker.Value = HSVToColor(ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib)
		Swatch.BackgroundColor3 = ColorPicker.Value
		SatMap.BackgroundColor3 = HSVToColor(ColorPicker.Hue, 1, 1)
		SatCursor.Position = UDim2.fromScale(ColorPicker.Sat, 1 - ColorPicker.Vib)
		HueCursor.Position = UDim2.fromScale(ColorPicker.Hue, 0)
		local c = ColorPicker.Value
		RgbaBox.Text = string.format(
			"%d, %d, %d, %d",
			math.floor(c.R * 255 + 0.5),
			math.floor(c.G * 255 + 0.5),
			math.floor(c.B * 255 + 0.5),
			math.floor((1 - ColorPicker.Transparency) * 255 + 0.5)
		)
	end
	function ColorPicker:OnChanged(func)
		table.insert(ColorPicker.OnChangedFns, func)
		Library:SafeCallback(func, ColorPicker.Value)
	end
	local function fire()
		Library:SafeCallback(ColorPicker.Changed, ColorPicker.Value)
		Library:SafeCallback(ColorPicker.Callback, ColorPicker.Value)
		for _, func in ColorPicker.OnChangedFns do
			Library:SafeCallback(func, ColorPicker.Value)
		end
	end
	function ColorPicker:SetValueRGB(color, transparency)
		ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib = color:ToHSV()
		ColorPicker.Transparency = transparency or ColorPicker.Transparency
		ColorPicker:Display()
		fire()
	end
	function ColorPicker:GetValue()
		return ColorPicker.Value
	end

	Display.MouseButton1Click:Connect(function()
		Menu:Toggle()
	end)

	local satDrag = false
	local function moveSat(pos)
		local rx = math.clamp((pos.X - SatMap.AbsolutePosition.X) / SatMap.AbsoluteSize.X, 0, 1)
		local ry = math.clamp((pos.Y - SatMap.AbsolutePosition.Y) / SatMap.AbsoluteSize.Y, 0, 1)
		ColorPicker.Sat = rx
		ColorPicker.Vib = 1 - ry
		ColorPicker:Display()
		fire()
	end
	SatMap.InputBegan:Connect(function(input)
		if IsClickInput(input) then
			satDrag = true
			moveSat(input.Position)
		end
	end)
	SatMap.InputEnded:Connect(function(input)
		if IsMouseInput(input) then
			satDrag = false
		end
	end)

	local hueDrag = false
	local function moveHue(pos)
		ColorPicker.Hue = math.clamp((pos.X - HueBar.AbsolutePosition.X) / HueBar.AbsoluteSize.X, 0, 1)
		ColorPicker:Display()
		fire()
	end
	HueBar.InputBegan:Connect(function(input)
		if IsClickInput(input) then
			hueDrag = true
			moveHue(input.Position)
		end
	end)
	HueBar.InputEnded:Connect(function(input)
		if IsMouseInput(input) then
			hueDrag = false
		end
	end)

	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if not IsHoverInput(input) then
			return
		end
		if satDrag then
			moveSat(input.Position)
		elseif hueDrag then
			moveHue(input.Position)
		end
	end))

	RgbaBox.FocusLost:Connect(function()
		local nums = {}
		for token in RgbaBox.Text:gmatch("%-?%d+") do
			table.insert(nums, tonumber(token))
		end
		if #nums >= 3 then
			local color = Color3.fromRGB(
				math.clamp(nums[1], 0, 255),
				math.clamp(nums[2], 0, 255),
				math.clamp(nums[3], 0, 255)
			)
			local transparency = ColorPicker.Transparency
			if nums[4] then
				transparency = 1 - math.clamp(nums[4], 0, 255) / 255
			end
			ColorPicker:SetValueRGB(color, transparency)
		else
			ColorPicker:Display()
		end
	end)

	ColorPicker:Display()
  ColorPicker.ConfigInstance=Display
	Library.Options[idx] = ColorPicker
	return self
end

local function MakeGroupbox(side, name, tab)
	local Outline, Inline, Body = MakePanel(side, UDim2.new(1, 0, 0, 0))
	Outline.AutomaticSize = Enum.AutomaticSize.Y
	Body.AutomaticSize = Enum.AutomaticSize.Y

	local Content = New("Frame", {
		Parent = Body,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	New("UIListLayout", { Parent = Content, Padding = UDim.new(0, 8) })
	New("UIPadding", {
		Parent = Content,
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	})

	local titleLabel
	if name then
		titleLabel = New("TextLabel", {
			Parent = Content,
			Text = name,
			TextColor3 = "FontColor",
			TextStrokeTransparency = 0,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = -1,
		})
	end

	local Groupbox = { Container = Content, Holder = Outline, Type = "Groupbox", Tab = tab, Column = side }
	Groupbox.Reveal = function()
		if tab then
			tab:Show()
		end
	end
	-- the column is a list layout, so hiding the outline reflows the rest rather than leaving a hole
	Groupbox.SetVisible = function(_, visible)
		Outline.Visible = visible and true or false
	end
	Groupbox.Record = { Chrome = { Outline, Inline, Body, titleLabel }, Entries = {}, Tab = tab, Dimmed = false }
	table.insert(Library.SearchBoxes, Groupbox.Record)
	return setmetatable(Groupbox, { __index = Funcs })
end

local function MakeTabbox(side, tab)
	local Outline, Inline, Body = MakePanel(side, UDim2.new(1, 0, 0, 0))
	Outline.AutomaticSize = Enum.AutomaticSize.Y
	Body.AutomaticSize = Enum.AutomaticSize.Y

	New("UIPadding", {
		Parent = Body,
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	})

	local Header = New("Frame", {
		Parent = Body,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
	})
	New("UIListLayout", {
		Parent = Header,
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
	local Pages = New("Frame", {
		Parent = Body,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})

	local Tabbox = { Tabs = {}, ActiveTab = nil, Holder = Outline, Body = Body }
	Tabbox.Record = { Chrome = { Outline, Inline, Body }, Entries = {}, Tab = tab, Owner = Tabbox, Dimmed = false }
	table.insert(Library.SearchBoxes, Tabbox.Record)

	function Tabbox:AddTab(name)
		local SelectButton = New("TextButton", {
			Parent = Header,
			Text = name,
			TextColor3 = "DimColor",
			TextStrokeTransparency = 0.5,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local Underline = New("Frame", {
			Parent = SelectButton,
			BackgroundColor3 = "Accent",
			BorderColor3 = "Border",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 1),
			Visible = false,
		})

		local Content = New("Frame", {
			Parent = Pages,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
		})
		New("UIListLayout", { Parent = Content, Padding = UDim.new(0, 8) })
		New("UIPadding", {
			Parent = Content,
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 8),
		})

		local SubTab = { Container = Content, Button = SelectButton, Tab = tab, Record = Tabbox.Record, Column = side }
		SubTab.Reveal = function()
			if tab then
				tab:Show()
			end
			SubTab:Show()
		end
		setmetatable(SubTab, { __index = Funcs })

		function SubTab:Show()
			for _, other in Tabbox.Tabs do
				other.Container.Visible = false
				other.Button.TextColor3 = Library.Scheme.DimColor
				other.Underline.Visible = false
			end
			Content.Visible = true
			SelectButton.TextColor3 = Library.Scheme.FontColor
			-- a lone section is always "active"; its underline conveys nothing, so only show it with 2+
			Underline.Visible = #Tabbox.Tabs > 1
			Tabbox.ActiveTab = SubTab
		end
		SubTab.Underline = Underline

		SelectButton.MouseButton1Click:Connect(function()
			SubTab:Show()
		end)

		table.insert(Tabbox.Tabs, SubTab)
		if not Tabbox.ActiveTab then
			SubTab:Show()
		end
		-- this section may have taken the count from 1 -> 2; refresh the active underline accordingly
		if Tabbox.ActiveTab then
			Tabbox.ActiveTab.Underline.Visible = #Tabbox.Tabs > 1
		end
		return SubTab
	end

	return Tabbox
end

local DIM_FACTOR = 0.62
local DimProps = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency", "ImageTransparency" }
local DimState = {}

local function dimInstance(inst, on)
	if on then
		if DimState[inst] then
			return
		end
		local snap = {}
		for _, prop in DimProps do
			local ok, value = pcall(function()
				return inst[prop]
			end)
			if ok and type(value) == "number" then
				snap[prop] = value
				pcall(function()
					inst[prop] = value + (1 - value) * DIM_FACTOR
				end)
			end
		end
		DimState[inst] = snap
	else
		local snap = DimState[inst]
		if not snap then
			return
		end
		for prop, value in snap do
			pcall(function()
				inst[prop] = value
			end)
		end
		DimState[inst] = nil
	end
end

local function dimTree(root, on)
	if not root then
		return
	end
	dimInstance(root, on)
	for _, child in root:GetChildren() do
		dimTree(child, on)
	end
end

local function dimChrome(record, on)
	record.Dimmed = on
	for _, inst in record.Chrome do
		dimInstance(inst, on)
	end
end

function Library:ResetSearch()
	for _, entry in Library.SearchIndex do
		dimTree(entry.Row, false)
		entry.Dimmed = false
	end
	for _, record in Library.SearchBoxes do
		dimChrome(record, false)
	end
	-- intentionally do NOT restore the pre-search tab/sections; leave the user where they are
	Library.Searching = false
end

-- scroll a matched element's column to it; deferred so a just-revealed tab has settled its layout first
local SEARCH_SCROLL_PAD = 8
local function scrollEntryIntoView(entry)
	if not entry then
		return
	end
	local row = entry.Row
	local column = entry.Column
	if not column and row then
		column = row:FindFirstAncestorOfClass("ScrollingFrame")
	end
	if not (row and column) then
		return
	end
	local function apply()
		local rowPos, rowSize = row.AbsolutePosition, row.AbsoluteSize
		local colPos, colSize = column.AbsolutePosition, column.AbsoluteSize
		if not (rowPos and rowSize and colPos and colSize) then
			return
		end
		local canvas = column.CanvasPosition or Vector2.new(0, 0)
		local rowTop = (rowPos.Y - colPos.Y) + canvas.Y
		-- already fully within the visible window: leave the scroll where it is
		if rowTop >= canvas.Y and (rowTop + rowSize.Y) <= (canvas.Y + colSize.Y) then
			return
		end
		local target = math.max(0, rowTop - SEARCH_SCROLL_PAD)
		column.CanvasPosition = Vector2.new(canvas.X, target)
	end
	if task and task.defer then
		task.defer(apply)
	else
		apply()
	end
end

function Library:UpdateSearch(query, enterPressed)
	query = tostring(query or ""):gsub("^%s*(.-)%s*$", "%1"):lower()

	if query == "" then
		Library:ResetSearch()
		return
	end

	Library.Searching = true

	local firstMatch, activeFirstMatch = nil, nil
	for _, entry in Library.SearchIndex do
		local matched = entry.Text:find(query, 1, true) ~= nil
		entry.Dimmed = not matched
		dimTree(entry.Row, not matched)
		if matched then
			firstMatch = firstMatch or entry
			if entry.Tab == Library.ActiveTab and not activeFirstMatch then
				activeFirstMatch = entry
			end
		end
	end

	for _, record in Library.SearchBoxes do
		local anyMatch = false
		for _, entry in record.Entries do
			if not entry.Dimmed then
				anyMatch = true
				break
			end
		end
		dimChrome(record, not anyMatch)
	end

	-- surface the same match the jump policy targets, then scroll its column to it
	local target
	if firstMatch and ((not activeFirstMatch) or enterPressed) then
		if firstMatch.Reveal then
			firstMatch.Reveal()
		end
		target = firstMatch
	elseif activeFirstMatch then
		target = activeFirstMatch
	end
	if target then
		scrollEntryIntoView(target)
	end
end

function Library:CreateWindow(windowInfo)
	windowInfo = Library:Validate(windowInfo, {
		Title = "Sentinel",
		Footer = "",
		Size = UDim2.fromOffset(582, 502),
		Position = UDim2.fromOffset(100, 100),
		ToggleKeybind = Enum.KeyCode.RightControl,
		ShowCustomCursor = false,
		NotifySide = "Left",
		Resizable = false,
		Center = false,
	})

	Library.ToggleKeybind = windowInfo.ToggleKeybind
	Library.ShowCustomCursor = windowInfo.ShowCustomCursor
	Library.NotifySide = windowInfo.NotifySide

	local Shell = MakeWindowShell(ScreenGui, windowInfo.Size, windowInfo.Position, windowInfo.Title)
	local MainOutline = Shell.Outline
	MainOutline.Visible = false

	if windowInfo.Center then
		local view = workspace.CurrentCamera.ViewportSize
		MainOutline.Position = UDim2.fromOffset(
			math.floor((view.X - windowInfo.Size.X.Offset) / 2),
			math.floor((view.Y - windowInfo.Size.Y.Offset) / 2)
		)
	end

	local DragHandle = New("TextButton", {
		Parent = Shell.Body,
		Text = "",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -165, 0, 16),
		ZIndex = 5,
	})
	Library:MakeDraggable(MainOutline, DragHandle, true)

	local ScaleHandle = New("Frame", {
		Parent = MainOutline,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -1, 1, -1),
		Size = UDim2.fromOffset(10, 10),
		ZIndex = 50,
		Active = true,
	})
	Library:MakeScalable(MainOutline, ScaleHandle)

	if windowInfo.Footer and windowInfo.Footer ~= "" then
		New("TextLabel", {
			Parent = Shell.Body,
			Text = windowInfo.Footer,
			TextColor3 = "DimColor",
			TextStrokeTransparency = 0.5,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 2),
			Size = UDim2.new(0, 100, 0, 12),
			TextXAlignment = Enum.TextXAlignment.Right,
			Interactable = false,
		})
	end

	local SearchOuter = New("Frame", {
		Parent = Shell.Body,
		BackgroundColor3 = "Dark",
		BorderColor3 = "DarkBorder",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -36, 0, 1),
		Size = UDim2.fromOffset(120, 14),
		ZIndex = 6,
	})
	local SearchBox = New("TextBox", {
		Parent = SearchOuter,
		Text = "",
		PlaceholderText = "Search...",
		PlaceholderColor3 = Color3.fromRGB(90, 90, 90),
		TextColor3 = "FontColor",
		TextStrokeTransparency = 0.5,
		BackgroundColor3 = "Element",
		BorderColor3 = "ElementBorder",
		BorderSizePixel = 1,
		ClearTextOnFocus = false,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 12,
		ZIndex = 6,
	})
	New("UIPadding", { Parent = SearchBox, PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 4) })
	Library.SearchBox = SearchBox

	Library:GiveSignal(SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		Library:UpdateSearch(SearchBox.Text)
	end))
	Library:GiveSignal(SearchBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			Library:UpdateSearch(SearchBox.Text, true)
		end
	end))

	local AccentRegion = New("Frame", {
		Parent = Shell.Body,
		BackgroundColor3 = "Accent",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 1, -18),
	})
	local TabOutline = New("Frame", {
		Parent = AccentRegion,
		BackgroundColor3 = "Outline",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
	})
	New("UIPadding", {
		Parent = TabOutline,
		PaddingTop = UDim.new(0, 1),
		PaddingBottom = UDim.new(0, 1),
		PaddingLeft = UDim.new(0, 1),
		PaddingRight = UDim.new(0, 1),
	})

	local TabStrip = New("Frame", {
		Parent = TabOutline,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 19),
	})
	New("UIListLayout", {
		Parent = TabStrip,
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 1),
	})

	local ContentArea = New("Frame", {
		Parent = TabOutline,
		BackgroundColor3 = "Inline",
		BorderColor3 = "Border",
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 1, -20),
	})

	local Window = { Tabs = {} }

	function Window:Toggle(value)
		if typeof(value) == "boolean" then
			Library.Toggled = value
		else
			Library.Toggled = not Library.Toggled
		end
		MainOutline.Visible = Library.Toggled

		if Library.Toggled then
			pcall(RunService.UnbindFromRenderStep, RunService, Library.ShowCursorBinding)
			UserInputService.MouseIconEnabled = true
			drawCursor(false)
		else
			UserInputService.MouseIconEnabled = OriginalMouseIconEnabled
			TooltipFrame.Visible = false
			if CurrentMenu then
				CurrentMenu:Close()
			end
		end
	end
	function Library:Toggle(value)
		Window:Toggle(value)
	end

	function Window:ChangeTitle(title)
		Shell.Title.Text = title
	end

	function Window:AddTab(name)
		local TabButtonHolder = New("Frame", {
			Parent = TabStrip,
			Name = "TabInline",
			BackgroundColor3 = "Inline",
			BorderColor3 = "Border",
			Size = UDim2.new(0, 100, 1, 0),
			ZIndex = -1,
		})
		New("UIFlexItem", { Parent = TabButtonHolder, FlexMode = Enum.UIFlexMode.Fill })
		local TabButton = New("TextButton", {
			Parent = TabButtonHolder,
			Name = "TabBackground",
			Text = name,
			TextColor3 = "FontColor",
			TextStrokeTransparency = 0,
			BackgroundColor3 = "Body",
			BorderColor3 = "Border",
			Position = UDim2.fromOffset(1, 1),
			Size = UDim2.new(1, -2, 1, -2),
			ZIndex = 2,
		})

		local Container = New("Frame", {
			Parent = ContentArea,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
		})
		New("UIPadding", {
			Parent = Container,
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		})
		New("UIListLayout", {
			Parent = Container,
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
		})

		local function makeSide()
			local _, _, body = MakePanel(Container, UDim2.new(0.5, 0, 1, 0))
			New("UIFlexItem", { Parent = body.Parent.Parent, FlexMode = Enum.UIFlexMode.Fill })
			local Scroll = New("ScrollingFrame", {
				Parent = body,
				BackgroundTransparency = 1,
				BorderColor3 = "Border",
				Size = UDim2.fromScale(1, 1),
				CanvasSize = UDim2.fromOffset(0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollBarThickness = 3,
				ScrollBarImageColor3 = "Accent",
				TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
				BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
			})
			New("UIListLayout", { Parent = Scroll, Padding = UDim.new(0, 8) })
			New("UIPadding", {
				Parent = Scroll,
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
			})
			return Scroll
		end

		local LeftSide = makeSide()
		local RightSide = makeSide()

		local Tab = {
			Name = name,
			Container = Container,
			Button = TabButton,
			ButtonHolder = TabButtonHolder,
			LeftSide = LeftSide,
			RightSide = RightSide,
			Groupboxes = {},
		}

		function Tab:Show()
			for _, other in Window.Tabs do
				other.Container.Visible = false
				other.ButtonHolder.BackgroundColor3 = Library.Scheme.Inline
				other.Button.BackgroundTransparency = 0
			end
			Container.Visible = true
			TabButtonHolder.BackgroundColor3 = Library.Scheme.Accent
			TabButton.BackgroundTransparency = 0.76
			Library.ActiveTab = Tab
		end

		function Tab:AddLeftGroupbox(boxName)
			return MakeGroupbox(LeftSide, boxName, Tab)
		end
		function Tab:AddRightGroupbox(boxName)
			return MakeGroupbox(RightSide, boxName, Tab)
		end
		function Tab:AddLeftTabbox()
			return MakeTabbox(LeftSide, Tab)
		end
		function Tab:AddRightTabbox()
			return MakeTabbox(RightSide, Tab)
		end

		TabButton.MouseButton1Click:Connect(function()
			Tab:Show()
		end)

		table.insert(Window.Tabs, Tab)
		Library.Tabs[name] = Tab
		if #Window.Tabs == 1 then
			Tab:Show()
		end
		return Tab
	end

	Library.Window = Window
	return Window
end

function Library:SetWatermarkVisibility(visible)
	if not Library.Watermark then
		local shell = MakeWindowShell(ScreenGui, UDim2.fromOffset(100, 24), UDim2.fromOffset(16, 16))
		shell.Outline.AutomaticSize = Enum.AutomaticSize.X
		shell.Body.AutomaticSize = Enum.AutomaticSize.X
		local label = New("TextLabel", {
			Parent = shell.Body,
			Text = "",
			TextColor3 = "FontColor",
			TextStrokeTransparency = 0,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 0, 12),
			Position = UDim2.fromOffset(0, 2),
			TextXAlignment = Enum.TextXAlignment.Left,
			Interactable = false,
		})
		Library.Watermark = shell.Outline
		Library.WatermarkLabel = label
		Library:MakeDraggable(shell.Outline, shell.Body)
	end
	Library.Watermark.Visible = visible
end
function Library:SetWatermark(text)
	Library:SetWatermarkVisibility(true)
	Library.WatermarkLabel.Text = text
end



-- standalone draggable + corner-resizable chat/log window (not a groupbox component)


-- standalone, domain-neutral macro-creator window: an editable step sequence the consumer drives off GetSequence()


-- standalone, domain-neutral waypoint-path editor: a point is a position + consumer-named kind, every edit routes through callbacks




-- standalone auto-sizing draggable status panel; the consumer feeds it text rows


local KeybindShell, KeybindScroll
local function ensureKeybindList()
	if KeybindShell then
		return
	end
	KeybindShell = MakeWindowShell(ScreenGui, UDim2.fromOffset(240, 200), UDim2.fromOffset(16, 200), "binds")
	Library:MakeDraggable(KeybindShell.Outline, KeybindShell.Body)
	local _, _, body = MakePanel(KeybindShell.Body, UDim2.new(1, 0, 1, -18), UDim2.fromOffset(0, 18))
	KeybindScroll = New("ScrollingFrame", {
		Parent = body,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = "Accent",
	})
	New("UIListLayout", { Parent = KeybindScroll, Padding = UDim.new(0, 4) })
	New("UIPadding", {
		Parent = KeybindScroll,
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 4),
	})
end

function Library:AddKeybindRow(keyPicker)
	ensureKeybindList()
	local Row = New("Frame", {
		Parent = KeybindScroll,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
	})
	New("UIListLayout", { Parent = Row, FillDirection = Enum.FillDirection.Horizontal })
	New("UIPadding", { Parent = Row, PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2) })
	local function col(text, divider)
		local lbl = New("TextLabel", {
			Parent = Row,
			Text = text,
			TextColor3 = Color3.fromRGB(180, 180, 180),
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		New("UIStroke", { Parent = lbl })
		if divider then
			New("Frame", {
				Parent = lbl,
				BackgroundColor3 = "Divider",
				BorderColor3 = "Border",
				Position = UDim2.fromOffset(-10, 0),
				Size = UDim2.fromOffset(1, 12),
			})
		end
		New("UIFlexItem", { Parent = lbl, FlexMode = Enum.UIFlexMode.Fill })
		return lbl
	end
	local nameCol = col(keyPicker.Text, false)
	local keyCol = col("", true)
	local modeCol = col("", true)
	local stateCol = col("", true)
	Library.KeybindRows[keyPicker] = { Name = nameCol, Key = keyCol, Mode = modeCol, State = stateCol }
	Library:UpdateKeybindRow(keyPicker)
end

function Library:UpdateKeybindRow(keyPicker)
	local row = Library.KeybindRows[keyPicker]
	if not row then
		return
	end
	row.Name.Text = keyPicker.Text
	row.Key.Text = keyPicker.Value == "None" and "none" or Library:GetKeyString(keyPicker.Bind or keyPicker.Value)
	row.Mode.Text = keyPicker.Mode:lower()
	row.State.Text = tostring(keyPicker:GetState())
end

function Library:SetKeybindFrameVisible(visible)
	if KeybindShell and KeybindShell.Outline then
		KeybindShell.Outline.Visible = visible
	end
end

function Library:OnUnload(callback)
	table.insert(Library.UnloadSignals, callback)
end

function Library:Unload()
    if Library.UnloadFinished or Library.Unloading then return end
    Library.Unloading=true
    Library.Unloaded=true
    local function clean(fn)
        local ok,err=pcall(fn)
        if not ok then warn("[Sentinel] unload: "..tostring(err)) end
    end
    if Library.BeforeUnload then clean(Library.BeforeUnload) end
    local callbacks=Library.UnloadSignals
    Library.UnloadSignals={}
    for _,callback in callbacks do clean(callback) end
    table.clear(callbacks)
    for index=#Library.Signals,1,-1 do
        local connection=table.remove(Library.Signals,index)
        clean(function() if connection then connection:Disconnect() end end)
    end
    clean(function() RunService:UnbindFromRenderStep(Library.ShowCursorBinding) end)
    clean(function() UserInputService.MouseIconEnabled=OriginalMouseIconEnabled end)
    clean(function() if Cursor then Cursor:Remove() end end)
    clean(function() if CursorOutline then CursorOutline:Remove() end end)
    clean(function() if ScreenGui then ScreenGui:Destroy() end end)
    for _,items in {Library.Toggles,Library.Options,Library.Registry,Library.Tabs,
        Library.KeybindRows,Library.SearchIndex,Library.SearchBoxes,DimState} do
        clean(function() table.clear(items) end)
    end
    Library.Searching=false
    if getgenv().Library==Library then getgenv().Library=nil end
    Library.Unloading=false;Library.UnloadFinished=true
    if Library.AfterUnload then clean(Library.AfterUnload) end
    Library.BeforeUnload=nil;Library.AfterUnload=nil
end

Library:GiveSignal(UserInputService.WindowFocused:Connect(function()
	Library.IsRobloxFocused = true
end))
Library:GiveSignal(UserInputService.WindowFocusReleased:Connect(function()
	Library.IsRobloxFocused = false
end))

Library:GiveSignal(UserInputService.InputBegan:Connect(function(input)
	if Library.Unloaded or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Library.ToggleKeybind and Library.Window then
		Library.Window:Toggle()
	end
end))

getgenv().Library = Library
return Library
]=],
theme = [=[
local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)
local clonefunction = (clonefunction or copyfunction or function(func)
    return func
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local isfolder, isfile, listfiles = isfolder, isfile, listfiles

if typeof(clonefunction) == "function" then
    -- Fix is_____ functions for shitsploits, those functions should never error, only return a boolean.

    local
        isfolder_copy,
        isfile_copy,
        listfiles_copy = clonefunction(isfolder), clonefunction(isfile), clonefunction(listfiles)

    local isfolder_success, isfolder_error = pcall(function()
        return isfolder_copy("test" .. tostring(math.random(1000000, 9999999)))
    end)

    if isfolder_success == false or typeof(isfolder_error) ~= "boolean" then
        isfolder = function(folder)
            local success, data = pcall(isfolder_copy, folder)
            return (if success then data else false)
        end

        isfile = function(file)
            local success, data = pcall(isfile_copy, file)
            return (if success then data else false)
        end

        listfiles = function(folder)
            local success, data = pcall(listfiles_copy, folder)
            return (if success then data else {})
        end
    end
end

local ThemeManager = {}
do
    local ThemeFields = { "FontColor", "MainColor", "AccentColor", "BackgroundColor", "OutlineColor" }
    ThemeManager.Folder = "sentinel"

    ThemeManager.Library = nil
    ThemeManager.AppliedToTab = false
    ThemeManager.BuiltInThemes = {
        ["Obsidian"] = {
            1,
            { FontColor = "ffffff", MainColor = "191919", AccentColor = "7d55ff", BackgroundColor = "0f0f0f", OutlineColor = "282828" },
        },
        ["BBot"] = {
            2,
            { FontColor = "ffffff", MainColor = "1e1e1e", AccentColor = "7e48a3", BackgroundColor = "232323", OutlineColor = "141414" },
        },
        ["Fatality"] = {
            3,
            { FontColor = "ffffff", MainColor = "1e1842", AccentColor = "c50754", BackgroundColor = "191335", OutlineColor = "3c355d" },
        },
        ["Jester"] = {
            4,
            { FontColor = "ffffff", MainColor = "242424", AccentColor = "db4467", BackgroundColor = "1c1c1c", OutlineColor = "373737" },
        },
        ["Mint"] = {
            5,
            { FontColor = "ffffff", MainColor = "242424", AccentColor = "3db488", BackgroundColor = "1c1c1c", OutlineColor = "373737" },
        },
        ["Tokyo Night"] = {
            6,
            { FontColor = "ffffff", MainColor = "191925", AccentColor = "6759b3", BackgroundColor = "16161f", OutlineColor = "323232" },
        },
        ["Ubuntu"] = {
            7,
            { FontColor = "ffffff", MainColor = "3e3e3e", AccentColor = "e2581e", BackgroundColor = "323232", OutlineColor = "191919" },
        },
        ["Quartz"] = {
            8,
            { FontColor = "ffffff", MainColor = "232330", AccentColor = "426e87", BackgroundColor = "1d1b26", OutlineColor = "27232f" },
        },
        ["Nord"] = {
            9,
            { FontColor = "eceff4", MainColor = "3b4252", AccentColor = "88c0d0", BackgroundColor = "2e3440", OutlineColor = "4c566a" },
        },
        ["Dracula"] = {
            10,
            { FontColor = "f8f8f2", MainColor = "44475a", AccentColor = "ff79c6", BackgroundColor = "282a36", OutlineColor = "6272a4" },
        },
        ["Monokai"] = {
            11,
            { FontColor = "f8f8f2", MainColor = "272822", AccentColor = "f92672", BackgroundColor = "1e1f1c", OutlineColor = "49483e" },
        },
        ["Gruvbox"] = {
            12,
            { FontColor = "ebdbb2", MainColor = "3c3836", AccentColor = "fb4934", BackgroundColor = "282828", OutlineColor = "504945" },
        },
        ["Solarized"] = {
            13,
            { FontColor = "839496", MainColor = "073642", AccentColor = "cb4b16", BackgroundColor = "002b36", OutlineColor = "586e75" },
        },
        ["Catppuccin"] = {
            14,
            { FontColor = "d9e0ee", MainColor = "302d41", AccentColor = "f5c2e7", BackgroundColor = "1e1e2e", OutlineColor = "575268" },
        },
        ["One Dark"] = {
            15,
            { FontColor = "abb2bf", MainColor = "282c34", AccentColor = "c678dd", BackgroundColor = "21252b", OutlineColor = "5c6370" },
        },
        ["Cyberpunk"] = {
            16,
            { FontColor = "f9f9f9", MainColor = "262335", AccentColor = "00ff9f", BackgroundColor = "1a1a2e", OutlineColor = "413c5e" },
        },
        ["Oceanic Next"] = {
            17,
            { FontColor = "d8dee9", MainColor = "1b2b34", AccentColor = "6699cc", BackgroundColor = "16232a", OutlineColor = "343d46" },
        },
        ["Material"] = {
            18,
            { FontColor = "eeffff", MainColor = "212121", AccentColor = "82aaff", BackgroundColor = "151515", OutlineColor = "424242" },
        }
    }

    function ThemeManager:SetLibrary(library)
        self.Library = library
    end

    --// Folders \\--
    function ThemeManager:GetPaths()
        local paths = {}

        local parts = self.Folder:split("/")
        for idx = 1, #parts do
            paths[#paths + 1] = table.concat(parts, "/", 1, idx)
        end

        paths[#paths + 1] = self.Folder .. "/themes"

        return paths
    end

    function ThemeManager:BuildFolderTree()
        local paths = self:GetPaths()

        for i = 1, #paths do
            local str = paths[i]
            if isfolder(str) then
                continue
            end
            makefolder(str)
        end
    end

    function ThemeManager:CheckFolderTree()
        if isfolder(self.Folder) then
            return
        end
        self:BuildFolderTree()

        task.wait(0.1)
    end

    function ThemeManager:SetFolder(folder)
        self.Folder = folder
        self:BuildFolderTree()
    end

    --// Apply, Update theme \\--
    function ThemeManager:ApplyTheme(theme)
        local customThemeData = self:GetCustomTheme(theme)
        local data = customThemeData or self.BuiltInThemes[theme]

        if not data then
            return
        end

        local scheme = data[2]
        for idx, val in pairs(customThemeData or scheme) do
            if idx == "VideoLink" then
                continue
            elseif idx == "FontFace" then
                self.Library:SetFont(val)

                if self.Library.Options[idx] then
                    self.Library.Options[idx]:SetValue(val)
                end
            else
                self.Library.Scheme[idx] = Color3.fromHex(val)

                if self.Library.Options[idx] then
                    self.Library.Options[idx]:SetValueRGB(Color3.fromHex(val))
                end
            end
        end

        self:ThemeUpdate()
    end

    function ThemeManager:ThemeUpdate()
        for i, field in ThemeFields do
            if self.Library.Options and self.Library.Options[field] then
                self.Library.Scheme[field] = self.Library.Options[field].Value
            end
        end

        self.Library:UpdateColorsUsingRegistry()
    end

    --// Get, Load, Save, Delete, Refresh \\--
    function ThemeManager:GetCustomTheme(file)
        local path = self.Folder .. "/themes/" .. file .. ".json"
        if not isfile(path) then
            return nil
        end

        local data = readfile(path)
        local success, decoded = pcall(HttpService.JSONDecode, HttpService, data)

        if not success then
            return nil
        end

        return decoded
    end

    function ThemeManager:LoadDefault()
        local theme = "Obsidian"
        local content = isfile(self.Folder .. "/themes/default.txt") and readfile(self.Folder .. "/themes/default.txt")

        local isDefault = true
        if content then
            if self.BuiltInThemes[content] then
                theme = content
            elseif self:GetCustomTheme(content) then
                theme = content
                isDefault = false
            end
        elseif self.BuiltInThemes[self.DefaultTheme] then
            theme = self.DefaultTheme
        end

        if isDefault then
            self.Library.Options.ThemeManager_ThemeList:SetValue(theme)
        else
            self:ApplyTheme(theme)
        end
    end

    function ThemeManager:SaveDefault(theme)
        writefile(self.Folder .. "/themes/default.txt", theme)
    end

    function ThemeManager:SetDefaultTheme(theme)
        assert(self.Library, "Must set ThemeManager.Library first!")
        assert(not self.AppliedToTab, "Cannot set default theme after applying ThemeManager to a tab!")

        local FinalTheme = {}
        local LibraryScheme = {}
        for _, field in ThemeFields do
            if typeof(theme[field]) == "Color3" then
                FinalTheme[field] = "#" .. theme[field]:ToHex()
                LibraryScheme[field] = theme[field]

            elseif typeof(theme[field]) == "string" then
                FinalTheme[field] = if theme[field]:sub(1, 1) == "#" then theme[field] else ("#" .. theme[field])
                LibraryScheme[field] = Color3.fromHex(theme[field])

            else
                FinalTheme[field] = ThemeManager.BuiltInThemes["Obsidian"][2][field]
                LibraryScheme[field] = Color3.fromHex(ThemeManager.BuiltInThemes["Obsidian"][2][field])
            end
        end

        if typeof(theme["FontFace"]) == "EnumItem" then
            FinalTheme["FontFace"] = theme["FontFace"].Name
            LibraryScheme["Font"] = Font.fromEnum(theme["FontFace"])

        elseif typeof(theme["FontFace"]) == "string" then
            FinalTheme["FontFace"] = theme["FontFace"]
            LibraryScheme["Font"] = Font.fromEnum(Enum.Font[theme["FontFace"]])

        else
            FinalTheme["FontFace"] = "Code"
            LibraryScheme["Font"] = Font.fromEnum(Enum.Font.Code)
        end

        for _, field in { "RedColor", "DarkColor", "WhiteColor" } do
            LibraryScheme[field] = self.Library.Scheme[field]
        end

        self.Library.Scheme = LibraryScheme
        self.BuiltInThemes["Obsidian"] = { 1, FinalTheme }

        self.Library:UpdateColorsUsingRegistry()
    end

    function ThemeManager:SaveCustomTheme(file)
        if file:gsub(" ", "") == "" then
            self.Library:Notify("Invalid file name for theme (empty)", 3)
            return
        end

        local theme = {}
        for _, field in ThemeFields do
            theme[field] = self.Library.Options[field].Value:ToHex()
        end
        theme["FontFace"] = self.Library.Options["FontFace"].Value

        writefile(self.Folder .. "/themes/" .. file .. ".json", HttpService:JSONEncode(theme))
    end

    function ThemeManager:Delete(name)
        if not name then
            return false, "no config file is selected"
        end

        local file = self.Folder .. "/themes/" .. name .. ".json"
        if not isfile(file) then
            return false, "invalid file"
        end

        local success = pcall(delfile, file)
        if not success then
            return false, "delete file error"
        end

        return true
    end

    function ThemeManager:ReloadCustomThemes()
        local list = listfiles(self.Folder .. "/themes")

        local out = {}
        for i = 1, #list do
            local file = list[i]
            if file:sub(-5) == ".json" then
                -- i hate this but it has to be done ...

                local pos = file:find(".json", 1, true)
                local start = pos

                local char = file:sub(pos, pos)
                while char ~= "/" and char ~= "\\" and char ~= "" do
                    pos = pos - 1
                    char = file:sub(pos, pos)
                end

                if char == "/" or char == "\\" then
                    table.insert(out, file:sub(pos + 1, start - 1))
                end
            end
        end

        return out
    end

    --// GUI \\--
    function ThemeManager:CreateThemeManager(groupbox)
        groupbox
            :AddLabel("Background color")
            :AddColorPicker("BackgroundColor", { Default = self.Library.Scheme.BackgroundColor })
        groupbox:AddLabel("Main color"):AddColorPicker("MainColor", { Default = self.Library.Scheme.MainColor })
        groupbox:AddLabel("Accent color"):AddColorPicker("AccentColor", { Default = self.Library.Scheme.AccentColor })
        groupbox
            :AddLabel("Outline color")
            :AddColorPicker("OutlineColor", { Default = self.Library.Scheme.OutlineColor })
        groupbox:AddLabel("Font color"):AddColorPicker("FontColor", { Default = self.Library.Scheme.FontColor })
        groupbox:AddSlider("MenuFontSize", {
            Text = "Font Size",
            Tooltip = "Use GUI Scale to make the whole menu bigger",
            Default = 12,
            Min = 8,
            Max = 16,
            Rounding = 0,
            Callback = function(value)
                self.Library:SetFontSize(value)
            end,
        })
        groupbox:AddSlider("MenuGuiScale", {
            Text = "GUI Scale",
            Tooltip = "Same as dragging the bottom right corner",
            Default = 1,
            Min = 0.5,
            Max = 2,
            Rounding = 2,
            Callback = function(value)
                self.Library:SetGuiScale(value)
            end,
        })
        groupbox:AddDropdown("FontFace", {
            Text = "Font Face",
            Default = "Code",
            Values = { "BuilderSans", "Code", "Fantasy", "Gotham", "Jura", "Roboto", "RobotoMono", "SourceSans" },
        })

        local ThemesArray = {}
        for Name, Theme in pairs(self.BuiltInThemes) do
            table.insert(ThemesArray, Name)
        end

        table.sort(ThemesArray, function(a, b)
            return self.BuiltInThemes[a][1] < self.BuiltInThemes[b][1]
        end)

        groupbox:AddDivider()

        groupbox:AddDropdown("ThemeManager_ThemeList", { Text = "Theme list", Values = ThemesArray, Default = 1 })
        groupbox:AddButton("Set as default", function()
            self:SaveDefault(self.Library.Options.ThemeManager_ThemeList.Value)
            self.Library:Notify(
                string.format("Set default theme to %q", self.Library.Options.ThemeManager_ThemeList.Value)
            )
        end)

        self.Library.Options.ThemeManager_ThemeList:OnChanged(function()
            self:ApplyTheme(self.Library.Options.ThemeManager_ThemeList.Value)
        end)

        groupbox:AddDivider()

        groupbox:AddInput("ThemeManager_CustomThemeName", { Text = "Custom theme name" })
        groupbox:AddButton("Create theme", function()
            local name = self.Library.Options.ThemeManager_CustomThemeName.Value

            if name:gsub(" ", "") == "" then
                self.Library:Notify("Invalid theme name (empty)", 2)
                return
            end

            self:SaveCustomTheme(name)

            self.Library:Notify(string.format("Created theme %q", name))
            self.Library.Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
            self.Library.Options.ThemeManager_CustomThemeList:SetValue(nil)
        end)

        groupbox:AddDivider()

        groupbox:AddDropdown(
            "ThemeManager_CustomThemeList",
            { Text = "Custom themes", Values = self:ReloadCustomThemes(), AllowNull = true, Default = 1 }
        )
        groupbox:AddButton("Load theme", function()
            local name = self.Library.Options.ThemeManager_CustomThemeList.Value

            self:ApplyTheme(name)
            self.Library:Notify(string.format("Loaded theme %q", name))
        end)
        groupbox:AddButton("Overwrite theme", function()
            local name = self.Library.Options.ThemeManager_CustomThemeList.Value

            self:SaveCustomTheme(name)
            self.Library:Notify(string.format("Overwrote config %q", name))
        end)
        groupbox:AddButton("Delete theme", function()
            local name = self.Library.Options.ThemeManager_CustomThemeList.Value

            local success, err = self:Delete(name)
            if not success then
                self.Library:Notify("Failed to delete theme: " .. err)
                return
            end

            self.Library:Notify(string.format("Deleted theme %q", name))
            self.Library.Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
            self.Library.Options.ThemeManager_CustomThemeList:SetValue(nil)
        end)
        groupbox:AddButton("Refresh list", function()
            self.Library.Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
            self.Library.Options.ThemeManager_CustomThemeList:SetValue(nil)
        end)
        groupbox:AddButton("Set as default", function()
            if
                self.Library.Options.ThemeManager_CustomThemeList.Value ~= nil
                and self.Library.Options.ThemeManager_CustomThemeList.Value ~= ""
            then
                self:SaveDefault(self.Library.Options.ThemeManager_CustomThemeList.Value)
                self.Library:Notify(
                    string.format("Set default theme to %q", self.Library.Options.ThemeManager_CustomThemeList.Value)
                )
            end
        end)
        groupbox:AddButton("Reset default", function()
            local success = pcall(delfile, self.Folder .. "/themes/default.txt")
            if not success then
                self.Library:Notify("Failed to reset default: delete file error")
                return
            end

            self.Library:Notify("Set default theme to nothing")
            self.Library.Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
            self.Library.Options.ThemeManager_CustomThemeList:SetValue(nil)
        end)

        self:LoadDefault()
        self.AppliedToTab = true

        local function UpdateTheme()
            self:ThemeUpdate()
        end

        self.Library.Options.BackgroundColor:OnChanged(UpdateTheme)
        self.Library.Options.MainColor:OnChanged(UpdateTheme)
        self.Library.Options.AccentColor:OnChanged(UpdateTheme)
        self.Library.Options.OutlineColor:OnChanged(UpdateTheme)
        self.Library.Options.FontColor:OnChanged(UpdateTheme)
        self.Library.Options.FontFace:OnChanged(function(Value)
            self.Library:SetFont(Value)
            self.Library:UpdateColorsUsingRegistry()
        end)
    end

    function ThemeManager:CreateGroupBox(tab)
        assert(self.Library, "Must set ThemeManager.Library first!")
        return tab:AddLeftGroupbox("Themes", "paintbrush")
    end

    function ThemeManager:ApplyToTab(tab)
        assert(self.Library, "Must set ThemeManager.Library first!")
        local groupbox = self:CreateGroupBox(tab)
        self:CreateThemeManager(groupbox)
    end

    function ThemeManager:ApplyToGroupbox(groupbox)
        assert(self.Library, "Must set ThemeManager.Library first!")
        self:CreateThemeManager(groupbox)
    end

    ThemeManager:BuildFolderTree()
end

getgenv().ObsidianThemeManager = ThemeManager
return ThemeManager
]=],
save = [=[
local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)
local clonefunction = (clonefunction or copyfunction or function(func)
    return func
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local isfolder, isfile, listfiles = isfolder, isfile, listfiles

if typeof(clonefunction) == "function" then
    -- Fix is_____ functions for shitsploits, those functions should never error, only return a boolean.

    local
        isfolder_copy,
        isfile_copy,
        listfiles_copy = clonefunction(isfolder), clonefunction(isfile), clonefunction(listfiles)

    local isfolder_success, isfolder_error = pcall(function()
        return isfolder_copy("test" .. tostring(math.random(1000000, 9999999)))
    end)

    if isfolder_success == false or typeof(isfolder_error) ~= "boolean" then
        isfolder = function(folder)
            local success, data = pcall(isfolder_copy, folder)
            return (if success then data else false)
        end

        isfile = function(file)
            local success, data = pcall(isfile_copy, file)
            return (if success then data else false)
        end

        listfiles = function(folder)
            local success, data = pcall(listfiles_copy, folder)
            return (if success then data else {})
        end
    end
end

local SaveManager = {} do
    SaveManager.Folder = "sentinel"
    SaveManager.SubFolder = ""
    SaveManager.Ignore = {}
    SaveManager.Library = nil
    SaveManager.UseLoadingOrder = false
    SaveManager.LoadingOrder = {}
    SaveManager.Parser = {
        Toggle = {
            Save = function(idx, object)
                return { type = "Toggle", idx = idx, value = object.Value }
            end,
            Load = function(idx, data)
                local object = SaveManager.Library.Toggles[idx]
                if object and object.Value ~= data.value then
                    object:SetValue(data.value)
                end
            end,
        },
        Slider = {
            Save = function(idx, object)
                return { type = "Slider", idx = idx, value = tostring(object.Value) }
            end,
            Load = function(idx, data)
                local object = SaveManager.Library.Options[idx]
                if object and object.Value ~= data.value then
                    object:SetValue(data.value)
                end
            end,
        },
        Dropdown = {
            Save = function(idx, object)
                return { type = "Dropdown", idx = idx, value = object.Value, multi = object.Multi }
            end,
            Load = function(idx, data)
                local object = SaveManager.Library.Options[idx]
                if object and object.Value ~= data.value then
                    if (idx=="RotAlts" or idx=="ServerAllies") and type(data.value)=="table" then
                        local values,seen={},{}
                        for _,name in object.Values or {} do
                            if not seen[name] then seen[name]=true;table.insert(values,name) end
                        end
                        for key,on in data.value do
                            local name=type(key)=="number" and on or key
                            if on and type(name)=="string" and not seen[name] then
                                seen[name]=true;table.insert(values,name)
                            end
                        end
                        table.sort(values);object:SetValues(values)
                    end
                    object:SetValue(data.value)
                end
            end,
        },
        ColorPicker = {
            Save = function(idx, object)
                return { type = "ColorPicker", idx = idx, value = object.Value:ToHex(), transparency = object.Transparency }
            end,
            Load = function(idx, data)
                if SaveManager.Library.Options[idx] then
                    SaveManager.Library.Options[idx]:SetValueRGB(Color3.fromHex(data.value), data.transparency)
                end
            end,
        },
        KeyPicker = {
            Save = function(idx, object)
                return { type = "KeyPicker", idx = idx, mode = object.Mode, key = object.Value, modifiers = object.Modifiers }
            end,
            Load = function(idx, data)
                if SaveManager.Library.Options[idx] then
                    SaveManager.Library.Options[idx]:SetValue({ data.key, data.mode, data.modifiers })
                end
            end,
        },
        Input = {
            Save = function(idx, object)
                return { type = "Input", idx = idx, text = object.Value }
            end,
            Load = function(idx, data)
                local object = SaveManager.Library.Options[idx]
                if object and object.Value ~= data.text and type(data.text) == "string" then
                    SaveManager.Library.Options[idx]:SetValue(data.text)
                end
            end,
        },
    }

    function SaveManager:SetLibrary(library)
        self.Library = library
    end

    function SaveManager:SetLoadingOrder(enabled, order)
        self.UseLoadingOrder = enabled

        if typeof(order) == "table" then
            self.LoadingOrder = order
        end
    end

    function SaveManager:IgnoreThemeSettings()
        self:SetIgnoreIndexes({
            "BackgroundColor", "MainColor", "AccentColor", "OutlineColor", "FontColor", "FontFace", -- themes
            "ThemeManager_ThemeList", "ThemeManager_CustomThemeList", "ThemeManager_CustomThemeName", -- themes
        })
    end

    --// Folders \\--
    function SaveManager:CheckSubFolder(createFolder)
        if typeof(self.SubFolder) ~= "string" or self.SubFolder == "" then return false end

        if createFolder == true then
            if not isfolder(self.Folder .. "/configs/" .. self.SubFolder) then
                makefolder(self.Folder .. "/configs/" .. self.SubFolder)
            end
        end

        return true
    end

    function SaveManager:GetPaths()
        local paths = {}

        local parts = self.Folder:split("/")
        for idx = 1, #parts do
            local path = table.concat(parts, "/", 1, idx)
            if not table.find(paths, path) then paths[#paths + 1] = path end
        end

        paths[#paths + 1] = self.Folder .. "/themes"
        paths[#paths + 1] = self.Folder .. "/configs"

        if self:CheckSubFolder(false) then
            local subFolder = self.Folder .. "/configs/" .. self.SubFolder
            parts = subFolder:split("/")

            for idx = 1, #parts do
                local path = table.concat(parts, "/", 1, idx)
                if not table.find(paths, path) then paths[#paths + 1] = path end
            end
        end

        return paths
    end

    function SaveManager:BuildFolderTree()
        local paths = self:GetPaths()

        for i = 1, #paths do
            local str = paths[i]
            if isfolder(str) then continue end

            makefolder(str)
        end
    end

    function SaveManager:CheckFolderTree()
        if isfolder(self.Folder) then return end
        SaveManager:BuildFolderTree()

        task.wait(0.1)
    end

    function SaveManager:SetIgnoreIndexes(list)
        for _, key in pairs(list) do
            self.Ignore[key] = true
        end
    end

    function SaveManager:SetFolder(folder)
        self.Folder = folder
        self:BuildFolderTree()
    end

    function SaveManager:SetSubFolder(folder)
        self.SubFolder = folder
        self:BuildFolderTree()
    end

    -- Keep a verified pending copy until the primary write has been read back.
    function SaveManager:ReadConfig(file, version)
        if not (isfile and readfile) then return nil, "executor sem leitura de arquivos" end
        for _,path in {file, file .. ".pending", file .. ".bak"} do
            local ok, data = pcall(function()
                if not isfile(path) then return end
                return HttpService:JSONDecode(readfile(path))
            end)
            if ok and type(data)=="table" and type(data.objects)=="table"
                and (version==nil or data.version==version) then return data, path end
        end
        return nil, "configuracao ausente ou invalida"
    end

    function SaveManager:WriteConfig(file, encoded)
        local ok, err = pcall(function()
            if not (writefile and readfile) then error("executor sem writefile/readfile",0) end
            local function verified(path, text)
                local result=writefile(path,text)
                if result==false or readfile(path)~=text then error("falha ao verificar "..path,0) end
            end
            verified(file .. ".pending",encoded)
            if isfile and isfile(file) then
                local valid, old = pcall(function()
                    local text=readfile(file)
                    local data=HttpService:JSONDecode(text)
                    if type(data)=="table" and type(data.objects)=="table" then return text end
                end)
                if valid and old then verified(file .. ".bak",old) end
            end
            verified(file,encoded)
            if delfile then pcall(delfile,file .. ".pending") end
        end)
        if not ok then return false,tostring(err) end
        return true
    end

    --// Save, Load, Delete, Refresh \\--
    function SaveManager:Save(name)
        if (not name) then
            return false, "no config file is selected"
        end
        SaveManager:CheckFolderTree()

        local fullPath = self.Folder .. "/configs/" .. name .. ".json"
        if SaveManager:CheckSubFolder(true) then
            fullPath = self.Folder .. "/configs/" .. self.SubFolder .. "/" .. name .. ".json"
        end

        local data = {
            objects = {}
        }

        for idx, toggle in pairs(self.Library.Toggles) do
            if not toggle.Type then continue end
            if not self.Parser[toggle.Type] then continue end
            if self.Ignore[idx] then continue end

            table.insert(data.objects, self.Parser[toggle.Type].Save(idx, toggle))
        end

        for idx, option in pairs(self.Library.Options) do
            if not option.Type then continue end
            if not self.Parser[option.Type] then continue end
            if self.Ignore[idx] then continue end

            table.insert(data.objects, self.Parser[option.Type].Save(idx, option))
        end

        local success, encoded = pcall(HttpService.JSONEncode, HttpService, data)
        if not success then
            return false, "failed to encode data"
        end

        return self:WriteConfig(fullPath, encoded)
    end

    function SaveManager:Load(name)
        if (not name) then
            return false, "no config file is selected"
        end
        SaveManager:CheckFolderTree()

        local file = self.Folder .. "/configs/" .. name .. ".json"
        if SaveManager:CheckSubFolder(true) then
            file = self.Folder .. "/configs/" .. self.SubFolder .. "/" .. name .. ".json"
        end

        local decoded, why = self:ReadConfig(file)
        if not decoded then return false, why end

        if self.UseLoadingOrder == true and typeof(self.LoadingOrder) == "table" then
            table.sort(decoded.objects, function(a, b)
                local aIndex = table.find(self.LoadingOrder, a.type) or math.huge
                local bIndex = table.find(self.LoadingOrder, b.type) or math.huge
                return aIndex < bIndex
            end)
        end

        local budgetStart = os.clock()
        for _, option in decoded.objects do
            if self.Library.Unloaded then return false, "script encerrado durante o carregamento" end
            if type(option)~="table" or not option.type then continue end
            if not self.Parser[option.type] then continue end
            if self.Ignore[option.idx] then continue end

            -- Complete each setter before reporting success or allowing autosave/resume.
            local applied, err = pcall(self.Parser[option.type].Load, option.idx, option)
            if not applied then return false, tostring(option.idx)..": "..tostring(err) end
            if os.clock() - budgetStart >= 0.008 then -- yield ~every 8ms so a big config applies over a few frames instead of one long freeze
                task.wait()
                budgetStart = os.clock()
            end
        end

        return true
    end

    function SaveManager:Delete(name)
        if (not name) then
            return false, "no config file is selected"
        end

        local file = self.Folder .. "/configs/" .. name .. ".json"
        if SaveManager:CheckSubFolder(true) then
            file = self.Folder .. "/configs/" .. self.SubFolder .. "/" .. name .. ".json"
        end

        local found=false
        for _,path in {file,file .. ".pending",file .. ".bak"} do
            if isfile(path) then
                found=true
                local ok,result=pcall(delfile,path)
                if not ok or result==false then return false,"delete file error" end
            end
        end
        if not found then return false,"invalid file" end

        return true
    end

    function SaveManager:RefreshConfigList()
        local success, data = pcall(function()
            SaveManager:CheckFolderTree()

            local list = {}
            local out = {}

            if SaveManager:CheckSubFolder(true) then
                list = listfiles(self.Folder .. "/configs/" .. self.SubFolder)
            else
                list = listfiles(self.Folder .. "/configs")
            end
            if typeof(list) ~= "table" then list = {} end

            for i = 1, #list do
                local file = list[i]
                if file:sub(-5) == ".json" then
                    -- i hate this but it has to be done ...

                    local pos = file:find(".json", 1, true)
                    local start = pos

                    local char = file:sub(pos, pos)
                    while char ~= "/" and char ~= "\\" and char ~= "" do
                        pos = pos - 1
                        char = file:sub(pos, pos)
                    end

                    if char == "/" or char == "\\" then
                        table.insert(out, file:sub(pos + 1, start - 1))
                    end
                end
            end

            return out
        end)

        if (not success) then
            if self.Library then
                self.Library:Notify("Failed to load config list: " .. tostring(data))
            else
                warn("Failed to load config list: " .. tostring(data))
            end

            return {}
        end

        return data
    end

    --// Auto Load \\--
    function SaveManager:GetAutoloadConfig()
        SaveManager:CheckFolderTree()

        local autoLoadPath = self.Folder .. "/configs/autoload.txt"
        if SaveManager:CheckSubFolder(true) then
            autoLoadPath = self.Folder .. "/configs/" .. self.SubFolder .. "/autoload.txt"
        end

        if isfile(autoLoadPath) then
            local successRead, name = pcall(readfile, autoLoadPath)
            if not successRead then
                return "none"
            end

            name = tostring(name)
            return if name == "" then "none" else name
        end

        return "none"
    end

    function SaveManager:LoadAutoloadConfig()
        SaveManager:CheckFolderTree()

        local autoLoadPath = self.Folder .. "/configs/autoload.txt"
        if SaveManager:CheckSubFolder(true) then
            autoLoadPath = self.Folder .. "/configs/" .. self.SubFolder .. "/autoload.txt"
        end

        if isfile(autoLoadPath) then
            local successRead, name = pcall(readfile, autoLoadPath)
            if not successRead then
                self.Library:Notify("Failed to load autoload config: write file error")
                return
            end

            local success, err = self:Load(name)
            if not success then
                self.Library:Notify("Failed to load autoload config: " .. err)
                return
            end

            self.Library:Notify(string.format("Auto loaded config %q", name))
        end
    end

    function SaveManager:SaveAutoloadConfig(name)
        SaveManager:CheckFolderTree()

        local autoLoadPath = self.Folder .. "/configs/autoload.txt"
        if SaveManager:CheckSubFolder(true) then
            autoLoadPath = self.Folder .. "/configs/" .. self.SubFolder .. "/autoload.txt"
        end

        local success = pcall(writefile, autoLoadPath, name)
        if not success then return false, "write file error" end

        return true, ""
    end

    function SaveManager:DeleteAutoLoadConfig()
        SaveManager:CheckFolderTree()

        local autoLoadPath = self.Folder .. "/configs/autoload.txt"
        if SaveManager:CheckSubFolder(true) then
            autoLoadPath = self.Folder .. "/configs/" .. self.SubFolder .. "/autoload.txt"
        end

        local success = pcall(delfile, autoLoadPath)
        if not success then return false, "delete file error" end

        return true, ""
    end

    --// GUI \\--
    function SaveManager:BuildConfigSection(tab, groupbox)
        assert(self.Library, "Must set SaveManager.Library")

        local section = groupbox or tab:AddRightGroupbox("Configuration", "folder-cog")

        section:AddInput("SaveManager_ConfigName",    { Text = "Config name" })
        section:AddButton("Create config", function()
            local name = self.Library.Options.SaveManager_ConfigName.Value

            if name:gsub(" ", "") == "" then
                self.Library:Notify("Invalid config name (empty)", 2)
                return
            end

            local success, err = self:Save(name)
            if not success then
                self.Library:Notify("Failed to create config: " .. err)
                return
            end

            self.Library:Notify(string.format("Created config %q", name))
            self.Library.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
            self.Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        section:AddDivider()

        section:AddDropdown("SaveManager_ConfigList", { Text = "Config list", Values = self:RefreshConfigList(), AllowNull = true })
        section:AddButton("Load config", function()
            local name = self.Library.Options.SaveManager_ConfigList.Value

            local success, err = self:Load(name)
            if not success then
                self.Library:Notify("Failed to load config: " .. err)
                return
            end

            self.Library:Notify(string.format("Loaded config %q", name))
        end)
        section:AddButton("Overwrite config", function()
            local name = self.Library.Options.SaveManager_ConfigList.Value

            local success, err = self:Save(name)
            if not success then
                self.Library:Notify("Failed to overwrite config: " .. err)
                return
            end

            self.Library:Notify(string.format("Overwrote config %q", name))
        end)

        section:AddButton("Delete config", function()
            local name = self.Library.Options.SaveManager_ConfigList.Value

            local success, err = self:Delete(name)
            if not success then
                self.Library:Notify("Failed to delete config: " .. err)
                return
            end

            self.Library:Notify(string.format("Deleted config %q", name))
            self.Library.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
            self.Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        section:AddButton("Refresh list", function()
            self.Library.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
            self.Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        section:AddButton("Set as autoload", function()
            local name = self.Library.Options.SaveManager_ConfigList.Value

            local success, err = self:SaveAutoloadConfig(name)
            if not success then
                self.Library:Notify("Failed to set autoload config: " .. err)
                return
            end

            self.Library:Notify(string.format("Set %q to auto load", name))
            self.AutoloadConfigLabel:SetText("Current autoload config: " .. name)
        end)
        section:AddButton("Reset autoload", function()
            local success, err = self:DeleteAutoLoadConfig()
            if not success then
                self.Library:Notify("Failed to set autoload config: " .. err)
                return
            end

            self.Library:Notify("Set autoload to none")
            self.AutoloadConfigLabel:SetText("Current autoload config: none")
        end)

        self.AutoloadConfigLabel = section:AddLabel("Current autoload config: " .. self:GetAutoloadConfig(), true)

        -- self:LoadAutoloadConfig()
        self:SetIgnoreIndexes({ "SaveManager_ConfigList", "SaveManager_ConfigName" })
    end

    SaveManager:BuildFolderTree()
end

return SaveManager
]=],
}
local __NATIVE = {
[75] = function(X, D, j)
    return function(I, l)
      if not I then
        return
      end
      local Z = os.clock()
      if (I ~= D[1]) or ((Z - X[1]) > 0.5) then
        D[1], X[1] = I, Z
        table.clear(j)
        for g, x in I:GetDescendants() do
          if x:IsA("BasePart") then
            table.insert(j, x)
          end
        end
      end
      for i, y in j do
        if y.Parent then
          y.CanCollide = false
        end
      end
      if l then
        local Q = I:FindFirstChild("HumanoidRootPart")
        if Q then
          Q.AssemblyLinearVelocity = Vector3.zero
          Q.AssemblyAngularVelocity = Vector3.zero
        end
      end
    end
  end,
[76] = function(X, D, j, I, l, Z)
    return function(g, x, i)
      x = (x or 28)
      i = (i or 0.8)
      local y = os.clock()
      if (y - I[1]) < D then
        return
      end
      if l[1] and ((g - l[1]).Magnitude < 3) then
        return
      end
      I[1] = y
      l[1] = g
      local Q = X.Character
      local A = {}
      for F, n in j:GetPartBoundsInRadius(g, x) do
        if (n:IsA("BasePart") and n.CanCollide) and not (Q and n:IsDescendantOf(Q)) then
          if Z[n] == nil then
            Z[n] = n.LocalTransparencyModifier
          end
          n.LocalTransparencyModifier = i
          A[n] = true
        end
      end
      for c, Y in Z do
        if not A[c] then
          if c and c.Parent then
            c.LocalTransparencyModifier = Y
          end
          Z[c] = nil
        end
      end
    end
  end,
[77] = function(X, D, j)
    return function()
      local I = D.Character
      if I then
        X.noclip(I, true)
        X.noFall((I:FindFirstChildOfClass("Humanoid") or j))
      end
    end
  end,
[78] = function(X, D, j, I, l, Z, g)
    return function()
      local x = j.Character
      if (((not l[1]) or not x) or not Z) or not Z.Parent then
        return
      end
      local n, c = pcall(function()
        for i, y in x:GetDescendants() do
          if y:IsA("BasePart") then
            y.CanCollide = false
            if y ~= Z then
              y.RotVelocity = Vector3.new(0, 0, 0)
            end
          end
        end
        X.noFall(g)
        local Q = I.CurrentCamera
        local A = (Q and Q.CFrame.LookVector)
        if not A then
          return
        end
        local F = Vector3.new(A.X, 0, A.Z)
        if F.Magnitude > 0.01 then
          Z.CFrame = CFrame.new(Z.Position, (Z.Position + F.Unit))
        end
      end)
      if not n then
        l[1] = false
        D.log("menutele", ("noclip hold stopped: " .. tostring(c)))
      end
    end
  end,
[79] = function(X, D, j, I, l, Z, g, x, i, y, Q)
    return function(A)
      g[1] += A
      if (g[1] > (I + l)) or Z.startMenu() then
        X[1]:Disconnect()
        return
      end
      local F = j.Character
      local n = (F and F:FindFirstChildOfClass("Humanoid"))
      if n and (n.Health <= 0) then
        x[1] = true
        X[1]:Disconnect()
        return
      end
      if D.tagged() then
        Q[1] = true
        X[1]:Disconnect()
        return
      end
      local Y = (F and F:FindFirstChild("HumanoidRootPart"))
      if Y then
        Y.CFrame = CFrame.new(i)
      end
      if y and (g[1] > l) then
        pcall(function()
          y:InvokeServer()
        end)
      end
    end
  end,
[87] = function(X, D)
    return function(j)
      if (not (j and j:IsA("BasePart"))) or (j.Material == Enum.Material.ForceField) then
        return
      end
      local I = X:FindFirstChild("Thrown")
      if I and j:IsDescendantOf(I) then
        local l = j.Parent
        while l and (l ~= X) do
          if l:IsA("Model") and (l.Name == "EarthPillar") then
            break
          end
          l = l.Parent
        end
        if (l == X) or (l == nil) then
          return
        end
      end
      if not D[j] then
        D[j] = { Material = j.Material, Reflectance = j.Reflectance }
      end
      j.Material = Enum.Material.SmoothPlastic
      j.Reflectance = 0
    end
  end,
[88] = function(X, D)
    return function()
      local I = X:GetDescendants()
      for l = 1, #I, 500 do
        for Z = l, math.min((l + 499), #I) do
          D(I[Z])
        end
        task.wait()
      end
    end
  end,
[89] = function(X, D)
    return function(j)
      if X.NoTextures.Value then
        D(j)
      end
    end
  end,
[90] = function(X, D, j, I, l, Z, g, x, i)
    return function()
      g[1] += 1
      if (g[1] % 6) ~= 0 then
        return
      end
      local y = D.ProximityDistance.Value
      local Q = (X.Character and X.Character:FindFirstChild("HumanoidRootPart"))
      if (y == 0) or not Q then
        i[1].Visible = false
        return
      end
      local A, F
      local allyTest=l.State.bladeSafetyAlly or l.State.isFriendly
      local n = (I.ProximityIgnoreAllies.Value and allyTest)
      for c, Y in j:GetPlayers() do
        local f = (((Y ~= X) and Y.Character) and Y.Character:FindFirstChild("HumanoidRootPart"))
        if (f and not (n and allyTest(Y))) and (not x(Y)) then
          local r = (Q.Position - f.Position).Magnitude
          if (r <= y) and ((not F) or (r < F)) then
            A, F = Y, r
          end
        end
      end
      if A then
        local H = (l.State.getRogueName and l.State.getRogueName(A))
        if l.State.maskRogue then
          H = l.State.maskRogue(A, H)
        end
        local e = (((l.State.maskUser and l.State.maskUser(A)) or A.DisplayName) or A.Name)
        local h = (((((H and (H ~= "")) and (H ~= "nil")) and (H ~= "Unknown")) and string.format("<b>%s</b> (%s)", Z(H), Z(e))) or Z(e))
        i[1].Text = string.format("%s is nearby! [%d]", h, math.floor(F))
        i[1].Visible = true
      else
        i[1].Visible = false
      end
    end
  end,
[91] = function(X)
    return function()
      X[1] += 1
    end
  end,
[92] = function(X, D, j, I, l)
    return function(Z)
      if (not X.Character) or not j then
        return
      end
      I[1] += Z
      if I[1] < 0.1 then
        return
      end
      I[1] = 0
      local g = D.State.identifyTrinket
      for x = #l[1], 1, -1 do
        if (not l[1][x]) or not l[1][x].Parent then
          table.remove(l[1], x)
        end
      end
      for y, Q in l[1] do
        if not (g and (g(Q) == "Azael Horn")) then
          local A = Q:FindFirstChild("ClickDetector", true)
          if A then
            local F = X:DistanceFromCharacter(Q.CFrame.Position)
            if (F > 0) and (F < A.MaxActivationDistance) then
              j(A)
            end
          end
        end
      end
    end
  end,
[94] = function(X, D, j, I, l, Z)
    return function(g)
      local x = tick()
      if (not (l[1] and l[1].Parent)) or ((x - Z[1]) > 1) then
        Z[1] = x
        local i = ((j.State.findIngredientFolder and j.State.findIngredientFolder()) or nil)
        if i ~= l[1] then
          l[1] = i
          D(i)
        end
      end
      table.clear(X)
      for y, Q in I do
        if y.Parent then
          local A = (y.Position - g.Position).Magnitude
          if (A > 0) and (A < (Q.MaxActivationDistance - 2)) then
            table.insert(X, Q)
          end
        else
          I[y] = nil
        end
      end
    end
  end,
[95] = function(X, D, j, I, l, Z, g, x)
    return function()
      local i = D.Character
      local y = (i and i:FindFirstChild("HumanoidRootPart"))
      if (not y) or not I then
        return
      end
      local Q = tick()
      local A = y.Position
      if ((g[1] == nil) or ((Q - Z[1]) > 0.2)) or (((Q - Z[1]) > 0.1) and ((A - g[1]).Magnitude > 2)) then
        Z[1], g[1] = Q, A
        x(y)
      end
      if (Q - l[1]) >= X then
        l[1] = Q
        for F, n in j do
          I(n)
        end
      end
    end
  end,
[96] = function(X, D, j, I, l)
    return function(Z)
      D[1] += Z
      if ((D[1] < 0.1) or I[1]) or not j then
        return
      end
      D[1] = 0
      local g = X.Character
      if not (g and g:FindFirstChild("Head")) then
        return
      end
      for x, i in l do
        if x.Parent == nil then
          l[x] = nil
        elseif X:DistanceFromCharacter(i.part.Position) <= i.range then
          j(i.pickup)
        end
      end
    end
  end,
[97] = function(X, D, j, I, l)
    return function()
      local Z = X.Character
      local g = (Z and Z:FindFirstChild("HumanoidRootPart"))
      if (not g) or not l then
        return
      end
      local x = ((D.BagRange and D.BagRange.Value) or 20)
      for y = #I[1], 1, -1 do
        local Q = I[1][y]
        if not Q:IsDescendantOf(j) then
          table.remove(I[1], y)
        elseif (Q.Position - g.Position).Magnitude <= x then
          l(Q, g, 0)
          l(Q, g, 1)
        end
      end
    end
  end,
[99] = function(X, D)
    return function()
      local j = X.root()
      if j then
        j.CFrame = D
        j.AssemblyLinearVelocity = Vector3.zero
      end
    end
  end,
[100] = function(X, D)
    return function(j, I)
      local l = X.root()
      if not l then
        return nil
      end
      local Z = D((l.Position - j))
      if Z.Magnitude < 0.1 then
        Z = Vector3.new(1, 0, 0)
      end
      local g = Vector3.new(-Z.Unit.Z, 0, Z.Unit.X)
      return (l.Position + (g * (I or X.RANGE.sidestep)))
    end
  end,
[101] = function(X, D, j)
    return function(I, l, Z)
      local g = j:FindFirstChild("Live")
      if not (g and I) then
        return false
      end
      Z = (Z or D.MOB_PATTERNS)
      for x, i in g:GetChildren() do
        if i:IsA("Model") and (not X:GetPlayerFromCharacter(i)) then
          for y, Q in Z do
            if i.Name:find(Q, 1, true) then
              local A = i:FindFirstChild("HumanoidRootPart")
              if A and ((A.Position - I).Magnitude <= l) then
                return true, i.Name
              end
              break
            end
          end
        end
      end
      return false
    end
  end,
[102] = function(X, D)
    return function(j, I)
      I = (I or X.RANGE.shrieker)
      local l = D:FindFirstChild("Live")
      if not (l and j) then
        return false
      end
      for Z, g in l:GetChildren() do
        if g:IsA("Model") and g.Name:match(".Shrieker") then
          local x = g:FindFirstChild("HumanoidRootPart")
          if x and ((x.Position - j).Magnitude <= I) then
            return true
          end
        end
      end
      return false
    end
  end,
[103] = function(X, D, j, I)
    return function()
      local l = D.Character
      if not l then
        return
      end
      for Z, g in l:GetDescendants() do
        if g:IsA("BasePart") then
          g.CanCollide = false
          if g ~= j then
            g.RotVelocity = Vector3.new(0, 0, 0)
          end
        end
      end
      X.noFall(I)
    end
  end,
[104] = function(X, D, j, I, l, Z, g)
    return function()
      g[1] += 1
      local x = g[1]
      table.clear(Z)
      table.clear(l)
      local i = (
        ((((game.PlaceId == 5208655184) and I:FindFirstChild("Map")) or ((game.PlaceId == X) and I)) or I:FindFirstChild("Map")) or I
      )
      for y, Q in i:GetChildren() do
        if Q:IsA("BasePart") and Q:FindFirstChild("TouchInterest") then
          local A = ((not (j[Q.Name] or D[Q.BrickColor.Number])) or (Q.Name == "Fire"))
          if A and Q.CanTouch then
            Q.CanTouch = false
            table.insert(Z, Q)
          end
        end
      end
      local F = (game.PlaceId == X)
      local n = 0
      for c, Y in i:GetDescendants() do
        n += 1
        if (n % 1000) == 0 then
          task.wait()
          if x ~= g[1] then
            return
          end
        end
        if Y:IsA("BasePart") then
          if ((Y.Name == "OrderField") or (Y.Name == "PurityField")) or (Y.Name == "MageField") then
            if Y.CanTouch then
              Y.CanTouch = false
              table.insert(Z, Y)
            end
            if Y.CanCollide then
              Y.CanCollide = false
              table.insert(l, Y)
            end
          elseif (F and (Y.Name == "Bed")) and Y.CanTouch then
            Y.CanTouch = false
            table.insert(Z, Y)
          end
        end
      end
    end
  end,
[105] = function(X, D, j, I, l, Z, g, x, i, y, Q, A, F, n, c, Y, f, r, H, e, h, q, s, proximityDistance)
    return function(u)
      if not H[1] then
        return
      end
      e[1] += u
      if e[1] < 0.05 then
        return
      end
      e[1] = 0
      if (not q[1]) and (tick() >= h[1]) then
        h[1] = (tick() + 2)
        if s() then
          q[1] = true
          y("went super, re-checking everyone for illusionists")
          for O, G in l:GetPlayers() do
            x(G)
          end
        end
      end
      local w = D.Character
      local o = (w and w:FindFirstChild("HumanoidRootPart"))
      if not o then
        return
      end
      local L = (X:HasTag(w, "Danger") and (tick() >= n[1]))
      if L then
        F[1]()
        if not H[1] then
          return
        end
      end
      local t = proximityDistance and proximityDistance() or ((j.ProgProximity and j.ProgProximity.Value) or 0)
      local v = (tick() >= r[1])
      for a, W in l:GetPlayers() do
        if W ~= D then
          local N = W.Character
          local U = (N and N:FindFirstChild("HumanoidRootPart"))
          if U then
            local B = (U.Position - o.Position).Magnitude
            local R = N:FindFirstChild("Pebble")
            if R and R:IsA("Tool") then
              c[W] = tick()
              if ((B <= I) and not L) and (not Q(i, W)) then
                f(string.format("%s holding Pebble (%.0f studs)", A(W), B), o.Position, I)
                return
              end
            end
            if (((t > 0) and v) and (B <= t)) and (not Q(i, W)) then
              f(string.format("%s within %.0f studs", A(W), B), o.Position, t)
              return
            end
            local b = ((B <= Z.RANGE.opalHold) and N:FindFirstChild("Opal Shard"))
            if (((b and b:IsA("Tool")) and (not Q(i, W))) and Z.allowed(j, "opalshard")) and (Y() > Z.OPAL_HOLD_PING) then
              f(string.format("%s holding Opal Shard (%.0f studs, %.0fms ping)", A(W), B, Y()), o.Position, Z.RANGE.opalHold)
              return
            end
          end
        end
      end
    end
  end,
[106] = function(X, D, j)
    return function()
      local I = D.Character
      if j then
        local l = (I and I:FindFirstChildOfClass("Humanoid"))
        if l and (l:GetState() ~= Enum.HumanoidStateType.Running) then
          l:ChangeState(Enum.HumanoidStateType.Running)
        end
        return
      end
      X.noclip(I, true)
    end
  end,
[107] = function(X, D)
    return function()
      while (not X[1]) and D[1] do
        task.wait()
      end
    end
  end,
[108] = function(X, D)
    return function()
      X.noclip(D.Character)
    end
  end,
[109] = function(X, D, j, I, l, Z, g, x, i, Q, A, F)
    return function()
      if (tick() - g[1]) < 0.25 then
        return
      end
      g[1] = tick()
      if (i[1] or not A[1]) or not (F[1] and (F[1].phase == "P5")) then
        x[1] = false
        return
      end
      local n = (Z.Character and Z.Character:FindFirstChild("HumanoidRootPart"))
      if not n then
        return
      end
      local c = n.Position.Y
      if ((c < l) or (c > I)) or ((n.Position - j).Magnitude > D) then
        return
      end
      if Q(j, X) then
        x[1] = true
      end
    end
  end,
[110] = function(X, D)
    return function()
      local j = (X.Character and X.Character:FindFirstChild("HumanoidRootPart"))
      if j then
        j.CFrame = CFrame.new(D)
        j.AssemblyLinearVelocity = Vector3.zero
      end
    end
  end,
[111] = function(X, D, j, I, l)
    return function()
      if not l[1] then
        return
      end
      local Z = D.Character
      local g = (Z and Z:FindFirstChild("HumanoidRootPart"))
      if not g then
        return
      end
      local x, i = I(g)
      if not x then
        return
      end
      X.noclip(Z)
      g.CFrame = CFrame.lookAt((x + (i * (j or 8.5))), x)
      g.AssemblyLinearVelocity = Vector3.zero
    end
  end,
[112] = function(X, D)
    return function()
      local j = (X.Character and X.Character:FindFirstChild("HumanoidRootPart"))
      if j then
        j.CFrame = CFrame.new(D)
        j.AssemblyLinearVelocity = Vector3.zero
      end
    end
  end,
[113] = function(X, D, j, I, l, Z, g)
    return function()
      local x = D.Character
      local i = (x and x:FindFirstChild("HumanoidRootPart"))
      if i and Z.Parent then
        X.noclip(x)
        g()
        local y = ((j and l(i.Position)) or Z.Position)
        i.CFrame = CFrame.lookAt(I(), y)
        i.AssemblyLinearVelocity = Vector3.zero
      end
    end
  end,
[114] = function(X, D, j)
    return function()
      local I = (X.Character and X.Character:FindFirstChild("HumanoidRootPart"))
      if I then
        I.CFrame = D
        I.AssemblyLinearVelocity = Vector3.zero
      end
      j()
    end
  end,
[115] = function(X, D, j, I, l, Z, g)
    return function(x)
      l[1] += x
      if l[1] < 0.25 then
        return
      end
      l[1] = 0
      local i = (j.Character and j.Character:FindFirstChild("HumanoidRootPart"))
      local y = I:FindFirstChild("Live")
      if not (i and y) then
        return
      end
      for Q, A in y:GetChildren() do
        if string.find(A.Name, "Zombie Scroom") and not g[A] then
          local F = A:FindFirstChild("HumanoidRootPart")
          local n = A:FindFirstChildOfClass("Humanoid")
          if (F and n) and ((F.Position - i.Position).Magnitude <= X) then
            g[A] = n
          end
        end
      end
      for c, Y in g do
        if (c.Parent ~= y) or (Y.Health <= D) then
          Z[c] = true
        end
      end
    end
  end,
[116] = function(X, D, j, I, l, Z)
    return function(g)
      X[1] += g
      if X[1] < 1 then
        return
      end
      X[1] = 0
      if I[1] or (D.State and D.State.loadingConfig) then
        return
      end
      local x = l()
      if x ~= j[1] then
        if j[1] ~= nil then
          Z()
        end
        j[1] = x
      end
    end
  end,
[117] = function(X, D)
    return function()
      X.noclip(D.Character, true)
    end
  end,
[118] = function(X, D, j)
    return function()
      local I = D.Character
      if not I then
        return
      end
      j[1] = true
      X.noclip(I, true)
    end
  end,
[120] = function(X, D)
    return function()
      local j = X.root()
      if j then
        j.CFrame = D
        j.AssemblyLinearVelocity = Vector3.zero
      end
    end
  end,
}
local function __entry(a1163)
    __bootMark("bootstrap-services")
    local tbl44 = { cache = {} }
    local fn39 = function()
      local v108 = cloneref or clonereference or function(a1164)
        return a1164
      end
      local obj2 = setmetatable({}, {
        __index = function(a1165, a278)
          local ok47, result51 = pcall(game.GetService, game, a278)
          if ok47 then
            local res43 = v108(result51)
            rawset(a1165, a278, res43)
            return res43
          end
        end,
      })
      obj2.Get = function(a1166, ...)
        local sel3 = select("#", ...)
        local createResult8 = table.create(sel3)
        for i22 = 1, sel3 do
          local sel4 = select(i22, ...)
          if type(sel4) == "string" then
            createResult8[i22] = a1166[sel4]
          else
            createResult8[i22] = sel4
          end
        end
        return table.unpack(createResult8, 1, sel3)
      end
      return obj2
    end
    tbl44.a = function()
      local a = tbl44.cache.a
      if not a then
        a = { c = fn39() }
        tbl44.cache.a = a
      end
      return a.c
    end
    local fn40 = function()
      local HttpService = tbl44.a().HttpService
      local str11 = "https://sentinel.heroinhound.cc/api/v1/product/config"
      local tbl46 = {}
      local fn100 = function()
        return http and http.request or http_request or request
      end
      tbl46.get = function(a1167, a279, a326)
        do return nil end
        local res44 = fn100()
        if not res44 then
          return nil
        end
        local str12 = str11 .. "?product=" .. a1167
        if a326 then
          str12 ..= "&key=" .. a326
        end
        local ok48, result52 = pcall(res44, { Url = str12, Method = "GET", Headers = { ["X-Product-Secret"] = a279 } })
        if not (ok48 and type(result52) == "table") then
          return nil
        end
        local v109 = result52.StatusCode or result52.status_code
        if v109 and v109 ~= 200 then
          return nil
        end
        local v110 = result52.Body or result52.body
        if type(v110) ~= "string" then
          return nil
        end
        local ok49, result53 = pcall(function()
          return HttpService:JSONDecode(v110)
        end)
        local v111 = result53
        if not ok49 then
          return nil
        end
        if type(v111) == "table" then
          if v111.data ~= nil then
            v111 = v111.data
          end
          if type(v111) == "table" and not a326 and type(v111.config) == "table" then
            v111 = v111.config
          end
          if type(v111) == "table" and a326 and v111[a326] ~= nil then
            v111 = v111[a326]
          end
          if type(v111) == "table" and v111.value ~= nil then
            v111 = v111.value
          end
        end
        return v111
      end
      tbl46.numbers = function(a1168)
        local tbl47 = {}
        if type(a1168) == "number" then
          table.insert(tbl47, a1168)
        elseif type(a1168) == "string" then
          local gmatchResult, v112, v113 = string.gmatch(a1168, "[^,%s]+")
          for k24 in gmatchResult, v112, v113 do
            local num44 = tonumber(k24)
            if num44 then
              table.insert(tbl47, num44)
            end
          end
        elseif type(a1168) == "table" then
          for k25, v114 in a1168 do
            local num45 = tonumber(v114)
            if num45 then
              table.insert(tbl47, num45)
            end
          end
        end
        return tbl47
      end
      tbl46.lookup = function(a1169)
        local tbl48 = {}
        local numbersResult, v115, v116 = tbl46.numbers(a1169)
        for k26, v117 in numbersResult, v115, v116 do
          tbl48[v117] = true
        end
        return tbl48
      end
      return tbl46
    end
    tbl44.b = function()
      local b = tbl44.cache.b
      if not b then
        b = { c = fn40() }
        tbl44.cache.b = b
      end
      return b.c
    end
    local fn41 = function()
      local tbl49 = {
        ROOT = "sentinel",
        BIN = "sentinel/bin",
        CACHE = "sentinel/.cache",
        CUSTOMIZATION = "sentinel/customization",
        SKINS = "sentinel/customization/weaponskins",
        CHARACTERS = "sentinel/customization/characters",
      }
      local tbl50 = { "friends.json", "rb_friends.json", "private_servers.json" }
      tbl49.FRIENDS = tbl49.BIN .. "/friends.json"
      tbl49.RB_FRIENDS = tbl49.BIN .. "/rb_friends.json"
      tbl49.PRIVATE_SERVERS = tbl49.BIN .. "/private_servers.json"
      tbl49.RUNECAST = tbl49.BIN .. "/runecast.json"
      tbl49.AAGUNS = tbl49.BIN .. "/aaguns.json"
      tbl49.WATCHED = tbl49.CACHE .. "/watched.rbxm"
      tbl49.KEYBINDS = tbl49.CACHE .. "/blade23_lite_keybinds.json"
      tbl49.EXTRAS = tbl49.CUSTOMIZATION .. "/extras.json"
      tbl49.ensure = function(a1170)
        if not (makefolder and isfolder) or type(a1170) ~= "string" or a1170 == "" then
          return
        end
        local v118
        local gmatchResult2, v119, v120 = a1170:gmatch("[^/]+")
        for k27 in gmatchResult2, v119, v120 do
          v118 = v118 and v118 .. "/" .. k27 or k27
          if not isfolder(v118) then
            pcall(makefolder, v118)
          end
        end
      end
      tbl49.ensureFor = function(a1171)
        local v121 = type(a1171) == "string" and a1171:match("^(.*)/[^/]*$") or nil
        if v121 then
          tbl49.ensure(v121)
        end
      end
      tbl49.moveFile = function(a1172, a280)
        if not (isfile and readfile and writefile) or isfile(a280) or not isfile(a1172) then
          return false
        end
        local ok50, result54 = pcall(readfile, a1172)
        if not (ok50 and type(result54) == "string") then
          return false
        end
        tbl49.ensureFor(a280)
        if not pcall(writefile, a280, result54) then
          return false
        end
        if delfile then
          pcall(delfile, a1172)
        end
        return true
      end
      tbl49.moveFolder = function(a1173, a281)
        if not (listfiles and isfolder and isfolder(a1173)) then
          return false
        end
        tbl49.ensure(a281)
        local ok51, result55 = pcall(listfiles, a1173)
        if not (ok51 and result55) then
          return false
        end
        for k28, v122 in result55 do
          local matchResult = tostring(v122):match("([^/\\]+)$")
          if matchResult then
            tbl49.moveFile(a1173 .. "/" .. matchResult, a281 .. "/" .. matchResult)
          end
        end
        if delfolder then
          pcall(delfolder, a1173)
        end
        return true
      end
      tbl49.migrate = function()
        tbl49.ensure(tbl49.BIN)
        tbl49.ensure(tbl49.CACHE)
        tbl49.ensure(tbl49.CUSTOMIZATION)
        for k29, v123 in tbl50 do
          tbl49.moveFile(tbl49.ROOT .. "/" .. v123, tbl49.BIN .. "/" .. v123)
          tbl49.moveFile(tbl49.CACHE .. "/" .. v123, tbl49.BIN .. "/" .. v123)
        end
        tbl49.moveFile("sentinel/watched.rbxm", tbl49.WATCHED)
        tbl49.moveFile("sentinel/extras.json", tbl49.EXTRAS)
        tbl49.moveFolder("sentinel/bundles", tbl49.CUSTOMIZATION)
        tbl49.moveFolder("sentinel/weaponskins", tbl49.SKINS)
      end
      return tbl49
    end
    tbl44.c = function()
      local c = tbl44.cache.c
      if not c then
        c = { c = fn41() }
        tbl44.cache.c = c
      end
      return c.c
    end
    local fn42 = function()
      local tbl51 = { ClassName = "Maid" }
      local fn101 = function(a1174)
        local typ2 = typeof(a1174)
        if typ2 == "function" then
          a1174()
        elseif typ2 == "RBXScriptConnection" then
          a1174:Disconnect()
        elseif typ2 == "Instance" then
          a1174:Destroy()
        elseif typ2 == "thread" then
          if coroutine.running() ~= a1174 then
            pcall(task.cancel, a1174)
          end -- A cleanup running on this thread must be allowed to finish itself.
        elseif typ2 == "table" and type(a1174.Destroy) == "function" then
          a1174:Destroy()
        end
      end
      tbl51.new = function()
        return setmetatable({ _tasks = {} }, tbl51)
      end
      tbl51.isMaid = function(a1175)
        return type(a1175) == "table" and a1175.ClassName == "Maid"
      end
      tbl51.__index = function(a1176, a282)
        return tbl51[a282] or a1176._tasks[a282]
      end
      tbl51.__newindex = function(a1177, a283, a327)
        if tbl51[a283] ~= nil then
          error(string.format("cannot use %q as a Maid key", tostring(a283)), 2)
        end
        local _tasks = a1177._tasks
        local item6 = _tasks[a283]
        if item6 == a327 then
          return
        end
        _tasks[a283] = a327
        if item6 then
          fn101(item6)
        end
      end
      tbl51.Add = function(a1178, a284)
        assert(a284 ~= nil, "task cannot be nil")
        a1178[#a1178._tasks + 1] = a284
        return a284
      end
      tbl51.Give = tbl51.Add
      tbl51.GiveTask = function(a1179, a285)
        assert(a285 ~= nil, "task cannot be nil")
        local num46 = #a1179._tasks + 1
        a1179[num46] = a285
        return num46
      end
      tbl51.Connect = function(a1180, a286, a328)
        return a1180:Add(a286:Connect(a328))
      end
      tbl51.DoCleaning = function(a1181)
        local _tasks2 = a1181._tasks
        for k30, v124 in _tasks2 do
          if typeof(v124) == "RBXScriptConnection" then
            _tasks2[k30] = nil
            pcall(function() v124:Disconnect() end)
          end
        end
        local nextResult, v125 = next(_tasks2)
        while v125 ~= nil do
          _tasks2[nextResult] = nil
          local cleaned,why=pcall(fn101,v125)
          if not cleaned then warn("[sentinel] cleanup: "..tostring(why)) end
          local nextResult2, v126 = next(_tasks2)
          nextResult = nextResult2
          v125 = v126
        end
      end
      tbl51.Destroy = tbl51.DoCleaning
      return tbl51
    end
    tbl44.d = function()
      local d = tbl44.cache.d
      if not d then
        d = { c = fn42() }
        tbl44.cache.d = d
      end
      return d.c
    end
    local fn43 = function()
      local getResult, v127 = tbl44.a():Get("Players", "ReplicatedStorage")
      local LocalPlayer2 = getResult.LocalPlayer
      local getrawmetatable_ = getrawmetatable
      local getrenv_ = getrenv
      local getsenv_ = getsenv
      local getgenv_ = getgenv
      local oth_ = oth
      local v128
      local v129
      local flag12 = false
      local fn102 = function()
        return getgenv_ ~= nil and getgenv_().SentinelNoKeyHandler == true
      end
      local tbl52 = {
        keyHandlerEnabled = function()
          return not fn102() and v128 ~= nil
        end,
        requestRemote = function(a1182)
          local Requests = v127:FindFirstChild("Requests")
          return Requests and Requests:FindFirstChild(a1182)
        end,
      }
      local tbl53 = {}
      tbl52.blockFire = function(a1183, a287)
        tbl53[a1183] = a287
      end
      tbl52.fireBlocked = function(a1184)
        if next(tbl53) == nil then
          return false
        end
        local Name = a1184.Name
        for k31, v130 in tbl53 do
          if v130[Name] then
            local Parent = a1184.Parent
            return Parent ~= nil and Parent.Name == "Remotes"
          end
        end
        return false
      end
      tbl52.getServerValue = function(a1185)
        local ok52, result56 = pcall(function()
          local Get = v127.Requests.Get
          return Get:InvokeServer(utf8.char(65532) .. "😃", a1185)[a1185]
        end)
        return ok52 and result56 or nil
      end
      local tbl54 = {
        Gaia = {
          PostDialogue = 404.5041892976703,
          SetManaChargeState = 27.81839265298673,
          ApplyFallDamage = 90.32503962905011,
          Tango = 30195.341357415226,
          Dodges = 398.00010021400533,
          SetCurrentArea = "SetCurrentArea",
          PlaceTool = "PlaceTool",
          PlaceMoney = "PlaceMoney",
          Theodora = "Theodora",
          InvisIngredient = "InvisIngredient",
          HideOre = "HideOre",
        },
        Khei = {
          Charge = "Charge",
          FallDamage = "FallDamage",
          SendDialogue = "SendDialogue",
          Dolorosa = "Dolorosa",
          HideIngredient = "HideIngredient",
          HideOre = "HideOre",
          AddClimbing = "AddClimbing",
          ClientFall = "ClientFall",
          ClientSprint = "ClientSprint",
          MoneyBag = "MoneyBag",
          ToolBag = "ToolBag",
          UpdateArea = "UpdateArea",
          Drop = "Drop",
        },
      }
      local fn103 = function()
        oth_.unhook(getrawmetatable_(game).__index)
        local v131
        v131 = oth_.hook(getrawmetatable_(game).__index, function(...)
          if ({ ... })[2] == "HttpGet" then
            return error()
          end
          return v131(...)
        end)
        local v132
        v132 = oth_.hook(error, function(a1186, a288)
          if a1186 == "" then
            return v132("", 0)
          end
          return v132(a1186, a288)
        end)
      end
      local fn104 = function()
        oth_.unhook(error)
        oth_.unhook(getrawmetatable_(game).__index)
      end
      local fn105 = function()
        local ok53, result57 = pcall(function()
          error("", 9)
        end)
        return result57 == ""
      end
      tbl52.preloadKeyHandler = function()
        if v128 or flag12 or fn102() then
          return v128
        end
        flag12 = true
        if not (oth_ and oth_.hook and oth_.unhook and getrawmetatable_ and getrenv_ and getgenv_) then
          print("[sentinel] KeyHandler: missing executor globals?")
          return nil
        end
        fn103()
        if fn105() then
          pcall(function()
            v128 = require(v127.Assets.Modules.KeyHandler)()
            v129 = require(v127.Info.RealmInfo).CurrentWorld
          end)
        end
        fn104()
        print("[sentinel] " .. (v128 and "ready (world=" .. tostring(v129) .. ")" or "not grabbed - using G-press"))
        return v128
      end
      tbl52.getRemote = function(a1187)
        if fn102() or not v128 or not v129 or not (oth_ and getrenv_) then
          return nil
        end
        local v133 = v129
        local v134 = tbl54[v133] and tbl54[v133][a1187]
        if not v134 then
          return nil
        end
        local v135 = v133 == "Gaia" and "plum" or v133 == "Khei" and "apricot"
        if not v135 then
          return nil
        end
        local v136
        fn103()
        pcall(function()
          if v133 == "Khei" then
            oth_.unhook(getrenv_().getfenv)
            oth_.hook(getrenv_().getfenv, function(a1188)
              return getsenv_(game:GetService("Players").LocalPlayer.PlayerScripts.ClientManage)
            end)
          end
          v136 = v133 == "Gaia" and v128[1](v134, v135) or v133 == "Khei" and v128.getKey(v134, v135)
          if v133 == "Khei" then
            oth_.unhook(getrenv_().getfenv)
          end
        end)
        fn104()
        if typeof(v136) ~= "Instance" or not v136:IsDescendantOf(game) then
          return nil
        end
        print(string.format("[sentinel] resolved '%s' -> %s (%s)", a1187, tostring(v136.Name), v133))
        return v136
      end
      return tbl52
    end
    tbl44.e = function()
      local e = tbl44.cache.e
      if not e then
        e = { c = fn43() }
        tbl44.cache.e = e
      end
      return e.c
    end
    local fn44 = function()
      local aResult2 = tbl44.a()
      local eResult = tbl44.e()
      local Players2 = aResult2.Players
      local RunService = aResult2.RunService
      return function(a1189)
        if getgenv().lolololol then
          return
        end
        if not (hookfunction and checkcaller and newcclosure and islclosure and getupvalues) then
          return
        end
        local active=true
        local hooks={}
        local connections={}
        local function install(target,replacement)
          local original=hookfunction(target,replacement)
          table.insert(hooks,{target=target,original=original})
          return original
        end
        local function cleanup()
          if not active then return end
          active=false
          for _,connection in connections do pcall(function() connection:Disconnect() end) end
          table.clear(connections)
          for index=#hooks,1,-1 do
            local entry=hooks[index]
            pcall(hookfunction,entry.target,entry.original)
          end
          table.clear(hooks)
        end
        -- Register each hook immediately so a failure halfway through initialization can clean up.
        __bootSession.coreCleanup=cleanup
        local v137
        v137 = install(workspace.Destroy, function(a1190)
          if not active then return v137(a1190) end
          if not checkcaller() and tostring(a1190) == "CharacterHandler" then
            return
          end
          return v137(a1190)
        end)
        local LocalPlayer3 = Players2.LocalPlayer
        local tbl55 = {}
        local fn106 = function()
          if not eResult.keyHandlerEnabled() then
            return
          end
          if not (tbl55.tango and tbl55.tango.Parent) then
            tbl55.tango = eResult.getRemote("Tango")
          end
          if not (tbl55.theodora and tbl55.theodora.Parent) then
            tbl55.theodora = eResult.getRemote("Theodora")
          end
          if not (tbl55.dolorosa and tbl55.dolorosa.Parent) then
            tbl55.dolorosa = eResult.getRemote("Dolorosa")
          end
          if not (tbl55.drop and tbl55.drop.Parent) then
            tbl55.drop = eResult.getRemote("Drop")
          end
        end
        local fn107 = function()
          task.spawn(function()
            for i23 = 1, 8 do
              if not active then return end
              fn106()
              if tbl55.tango or tbl55.dolorosa then
                return
              end
              task.wait(1)
            end
          end)
        end
        fn107()
        table.insert(connections,LocalPlayer3.CharacterAdded:Connect(fn107))
        local v138
        v138 = install(
          Instance.new("RemoteEvent").FireServer,
          newcclosure(function(a1191, ...)
            if not active then return v138(a1191,...) end
            if not checkcaller() and typeof(a1191) == "Instance" then
              if a1191 == tbl55.dolorosa or a1191 == tbl55.theodora or a1191 == tbl55.drop then
                return
              end
              if eResult.fireBlocked(a1191) then
                return
              end
              if a1191 == tbl55.tango then
                local arg = ...
                local v141 = typeof(arg) == "table" and arg[2]
                if typeof(v141) == "number" and not (v141 >= 2 and v141 <= 4) then
                  return
                end
              end
            end
            return v138(a1191, ...)
          end)
        )
        if a1189 == "Kick" then
          if not (getconstants and getfenv) then
            return
          end
          local v139
          local tbl56 = {}
          v139 = install(
            coroutine.wrap,
            newcclosure(function(a1192, ...)
              if not active then return v139(a1192,...) end
              if not checkcaller() then
                if type(a1192) == "function" and islclosure(a1192) then
                  local getconstantsResult = getconstants(a1192)
                  local getupvaluesResult = getupvalues(a1192)
                  local getfenvResult = getfenv(3)
                  if
                    typeof(getupvaluesResult[2]) == "Instance"
                    and getupvaluesResult[2]:IsA("AnimationTrack")
                    and getupvaluesResult[1] == getupvaluesResult[2].Play
                  then
                    tbl56[getfenvResult] = true
                  end
                  if getconstantsResult[1] == "scr" and getconstantsResult[2] == "Parent" then
                    tbl56[getfenvResult] = true
                  end
                  if
                    getconstantsResult[1] == "coroutine"
                    and getconstantsResult[2] == "create"
                    and table.find(getconstantsResult, "dead")
                  then
                    tbl56[getfenvResult] = true
                  end
                  if getfenvResult and tbl56[getfenvResult] then
                    while true do
                      Players2.LocalPlayer:Kick("Ban Attempt")
                      task.wait()
                    end
                  end
                end
                if tbl56[getfenv(3)] then
                  return function() end
                end
              end
              return v139(a1192, ...)
            end)
          )
        else
          local fn108 = function() end
          local info = debug.info
          local wrapChecks=setmetatable({}, {__mode="k"})
          local wrapCheckCount=0
          local valueAt=(debug and debug.getupvalue) or getupvalue
          local functionInfo=(debug and debug.getinfo) or getinfo
          local wrapInspecting=setmetatable({}, {__mode="k"})
          local uiRoot,packagesRoot
          pcall(function() uiRoot=game:GetService("CoreGui") end)
          pcall(function() packagesRoot=game:FindFirstChild("CorePackages") end)
          local function engineUI(fn)
            if not getfenv then return false end
            local ok,env=pcall(getfenv,fn)
            local script=ok and type(env)=="table" and env.script
            if typeof(script)~="Instance" then return false end
            local coreOk,core=pcall(script.IsA,script,"CoreScript")
            if coreOk and core then return true end
            if uiRoot then
              local insideOk,inside=pcall(script.IsDescendantOf,script,uiRoot)
              if insideOk and inside then return true end
            end
            if packagesRoot then
              local insideOk,inside=pcall(script.IsDescendantOf,script,packagesRoot)
              if insideOk and inside then return true end
            end
            return false
          end
          local function wrappedRunServiceOnly(fn)
            local now=os.clock()
            local cached=wrapChecks[fn]
            if cached and now-cached.at<1 then return cached.blocked end
            local blocked
            if type(valueAt)=="function" and type(functionInfo)=="function" then
              local infoOk,details=pcall(functionInfo,fn)
              local nups=infoOk and type(details)=="table" and details.nups
              if type(nups)=="number" and nups>=0 and nups%1==0 then
                if nups~=1 then blocked=false
                else
                  local valueOk,value=pcall(valueAt,fn,1)
                  if valueOk then blocked=value==RunService end
                end
              end
            end
            if blocked==nil then
              -- Preserve compatibility with executors without the scalar inspection APIs.
              local values=getupvalues(fn)
              blocked=#values==1 and values[1]==RunService
            end
            -- Keep only the decision, never the inspected values/captured object graphs.
            if wrapCheckCount>=512 then table.clear(wrapChecks);wrapCheckCount=0 end
            if not wrapChecks[fn] then wrapCheckCount+=1 end
            wrapChecks[fn]={at=now,blocked=blocked}
            return blocked
          end
          local v140
          v140 = install(
            coroutine.wrap,
            newcclosure(function(a1193)
              if not active then return v140(a1193) end
              if not checkcaller() then
                if type(a1193) == "function" and islclosure(a1193) then
                  local thread=coroutine.running()
                  if wrapInspecting[thread] then return v140(a1193) end
                  wrapInspecting[thread]=true
                  local ok,isUI,blocked=pcall(function()
                    if engineUI(a1193) then return true,false end
                    return false,wrappedRunServiceOnly(a1193)
                  end)
                  wrapInspecting[thread]=nil
                  if not ok or isUI then return v140(a1193) end
                  if blocked then return v140(fn108) end
                end
                if info and info(5, "n") == "pcall" then
                  return
                end
              end
              return v140(a1193)
            end)
          )
        end
      end
    end
    tbl44.f = function()
      local f = tbl44.cache.f
      if not f then
        f = { c = fn44() }
        tbl44.cache.f = f
      end
      return f.c
    end
    local fn47 = function()
      local tbl65 = {}
      local tbl66 = { Risky = "RiskyMode", Blatant = "BlatantMode" }
      local tbl67 = { Risky = "risky", Blatant = "blatant" }
      tbl65.tip = function(a1209, a299)
        return a299 and a299 ~= "" and a1209 .. ": " .. a299 or "Needs " .. a1209 .. " Mode"
      end
      tbl65.risky = function(a1210)
        return tbl65.tip("Risky", a1210)
      end
      tbl65.blatant = function(a1211)
        return tbl65.tip("Blatant", a1211)
      end
      tbl65.on = function(a1212, a2100)
        local v168 = a1212 and a1212.Toggles[tbl66[a2100]]
        return v168 ~= nil and v168.Value == true
      end
      tbl65.allow = function(a1213, a2101, a335)
        if tbl65.on(a1213.Library, a2101) then
          return true
        end
        a1213.Library:Notify({ Title = "sentinel.bz", Description = a335 .. " requires " .. a2101 .. " Mode" })
        return false
      end
      tbl65.blocked = function(a1214, a2102, a336, a411)
        if a1214.State and a1214.State.loadingConfig or tbl65.on(a1214.Library, a2102) then
          return false
        end
        local item9 = a1214.Library.Toggles[a336]
        if item9 then
          item9:SetValue(false)
        end
        a1214.Library:Notify({ Title = "sentinel.bz", Description = a411 .. " requires " .. a2102 .. " Mode" })
        return true
      end
      tbl65.mark = function(a1215, a2103, a337, a412)
        local item10 = tbl67[a2103]
        a1215.State[item10] = a1215.State[item10] or {}
        table.insert(a1215.State[item10], a337)
        local v169 = a412 or a1215.Library.Toggles[a337]
        if v169 and a2103 == "Risky" and v169.SetTextColorKey then
          v169:SetTextColorKey("Orange")
        end
        return v169
      end
      return tbl65
    end
    tbl44.i = function()
      local i26 = tbl44.cache.i
      if not i26 then
        i26 = { c = fn47() }
        tbl44.cache.i = i26
      end
      return i26.c
    end
    local fn49 = function()
      local str16 = "sentinel/.cache/debugging"
      local tbl68 = {}
      local flag14 = false
      local flag15 = false
      local tbl69 = {}
      tbl68.enabled = function()
        return true
      end
      local fn116 = function()
        if flag14 then
          return true
        end
        if flag15 or not tbl68.enabled() then
          return false
        end
        if not (makefolder and isfolder and appendfile) then
          flag15 = true
          return false
        end
        pcall(function()
          if not isfolder("sentinel") then
            makefolder("sentinel")
          end
          if not isfolder("sentinel/.cache") then
            makefolder("sentinel/.cache")
          end
          if not isfolder(str16) then
            makefolder(str16)
          end
        end)
        flag14 = isfolder(str16) == true
        flag15 = not flag14
        return flag14
      end
      tbl68.path = function(a1216)
        return str16 .. "/" .. tostring(a1216) .. ".log"
      end
      tbl68.log = function(a1217, a2104)
        if not tbl68.enabled() or not fn116() then
          return false
        end
        local pathResult = tbl68.path(a1217)
        if not tbl69[a1217] then
          tbl69[a1217] = true
          pcall(
            appendfile,
            pathResult,
            string.format(
              "\n=== %s | place %s | job %s ===\n",
              os.date("!%Y-%m-%d %H:%M:%SZ"),
              tostring(game.PlaceId),
              tostring(game.JobId)
            )
          )
        end
        return pcall(appendfile, pathResult, os.date("!%H:%M:%S ") .. tostring(a2104) .. "\n")
      end
      return tbl68
    end
    tbl44.k = function()
      local k40 = tbl44.cache.k
      if not k40 then
        k40 = { c = fn49() }
        tbl44.cache.k = k40
      end
      return k40.c
    end
    local fn54 = function()
      local aResult7 = tbl44.a()
      local getResult4, v354, v355, v356, v357, v358 =
        aResult7:Get("Players", "Workspace", "RunService", "UserInputService", "Lighting", "CollectionService")
      local LocalPlayer6 = getResult4.LocalPlayer
      local v359 = gethiddenproperty or function()
        return ""
      end
      local tbl112 = {
        none = { ZIndex = 1, Color = Color3.fromRGB(40, 40, 40) },
        common = { ZIndex = 2, Color = Color3.fromRGB(189, 97, 29) },
        rare = { ZIndex = 3, Color = Color3.fromRGB(60, 150, 150) },
        event = { ZIndex = 4, Color = Color3.fromRGB(0, 255, 0) },
        artifact = { ZIndex = 5, Color = Color3.fromRGB(160, 100, 160) },
        mythic = { ZIndex = 6, Color = Color3.fromRGB(255, 0, 80) },
      }
      local tbl113 = { "None", "Common", "Rare", "Event", "Artifact", "Mythic" }
      local tbl114 = {
        "135210454467508",
        "130937394581985",
        "110718109649132",
        "78990214596147",
        "77406341502228",
        "118090092039844",
      }
      local tbl115 = {
        ["3293218896"] = "Desert Mist",
        ["2773353559"] = "Blood Thorn",
        ["2960178471"] = "Snowscroom",
        ["2577691737"] = "Lava Flower",
        ["2618765559"] = "Glow Scroom",
        ["2575167210"] = "Moss Plant",
        ["2620905234"] = "Scroom",
        ["2766925289"] = "Trote",
        ["2766925320"] = "Polar Plant",
        ["2766802713"] = "Periashroom",
        ["2766802766"] = "Strange Tentacle",
        ["2766925228"] = "Tellbloom",
        ["2766802731"] = "Dire Flower",
        ["2573998175"] = "Freeleaf",
        ["2766925214"] = "Crown Flower",
        ["3215371492"] = "Potato",
        ["2766925304"] = "Vile Seed",
        ["3049345298"] = "Zombie Scroom",
        ["2766802752"] = "Orcher Leaf",
        ["2766925267"] = "Creely",
        ["2889328388"] = "Ice Jar",
        ["3049928758"] = "Canewood",
        ["3049556532"] = "Acorn Light",
        ["2766925245"] = "Uncanny Tentacle",
        ["9858299042"] = "Evoflower",
        ["3173538809"] = "Sky Orchid",
        ["2889328423"] = "Frost Princess",
      }
      local fn211 = function(a1314, a2127)
        for k89, v361 in a1314 do
          if v361 == a2127 then
            return true
          end
        end
        return false
      end
      local fn212 = function(a1315)
        local ok65, result67 = pcall(v359, a1315, "AssetId")
        return ok65 and type(result67) == "string" and result67:gsub("%%20", ""):match("%d+") or nil
      end
      local fn213 = function(a1316)
        if a1316.ClassName == "UnionOperation" and fn212(a1316) == "2765613127" then
          return "Idol of the Forgotten", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "UnionOperation" and fn212(a1316) == "15583017412" then
          return "Ornament", tbl112.event.Color, tbl112.event.ZIndex
        end
        if a1316.ClassName == "UnionOperation" and fn212(a1316) == "15611175305" then
          return "Present", tbl112.event.Color, tbl112.event.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5196782997" then
          return "Old Ring", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5196776695" then
          return "Ring", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5204003946" then
          return "Goblet", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5196577540" then
          return "Old Amulet", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5196551436" then
          return "Amulet", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "Part" and a1316:FindFirstChildWhichIsA("SpecialMesh") and a1316:FindFirstChild("OrbParticle") then
          return "???", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316.ClassName == "Part"
          and a1316:FindFirstChildWhichIsA("SpecialMesh")
          and a1316:FindFirstChild("ParticleEmitter")
          and a1316:FindFirstChildWhichIsA("SpecialMesh").MeshId == ""
          and a1316:FindFirstChildWhichIsA("SpecialMesh").MeshType == Enum.MeshType.Sphere
        then
          return "Opal", tbl112.common.Color, tbl112.common.ZIndex
        end
        if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://5204453430" then
          return "Scroll", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316:FindFirstChild("Mesh")
          and a1316.Mesh.MeshId == "rbxassetid://%202877143560%20"
          and a1316:FindFirstChild("ParticleEmitter")
          and string.match(tostring(a1316.ParticleEmitter.Color), "0 1 1 1 0 1 1 1 1 0")
          and a1316.ClassName == "Part"
          and tostring(a1316.Color) == "0.643137, 0.733333, 0.745098"
        then
          return "Diamond", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316:FindFirstChild("Mesh")
          and a1316.Mesh.MeshId == "rbxassetid://%202877143560%20"
          and a1316:FindFirstChild("ParticleEmitter")
          and string.match(tostring(a1316.ParticleEmitter.Color), "0 1 1 1 0 1 1 1 1 0")
          and a1316.ClassName == "Part"
          and a1316.Color.G > a1316.Color.R
          and a1316.Color.G > a1316.Color.B
        then
          return "Emerald", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316:FindFirstChild("Mesh")
          and a1316.Mesh.MeshId == "rbxassetid://%202877143560%20"
          and a1316:FindFirstChild("ParticleEmitter")
          and string.match(tostring(a1316.ParticleEmitter.Color), "0 1 1 1 0 1 1 1 1 0")
          and a1316.ClassName == "Part"
          and a1316.Color.R > a1316.Color.G
          and a1316.Color.R > a1316.Color.B
        then
          return "Ruby", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316:FindFirstChild("Mesh")
          and a1316.Mesh.MeshId == "rbxassetid://%202877143560%20"
          and a1316:FindFirstChild("ParticleEmitter")
          and string.match(tostring(a1316.ParticleEmitter.Color), "0 1 1 1 0 1 1 1 1 0")
          and a1316.ClassName == "Part"
          and a1316.Color.B > a1316.Color.G
          and a1316.Color.B > a1316.Color.R
        then
          return "Sapphire", tbl112.rare.Color, tbl112.rare.ZIndex
        end
        if
          a1316.ClassName == "Part"
          and a1316:FindFirstChild("ParticleEmitter")
          and not string.match(tostring(a1316.ParticleEmitter.Color), "0 1 1 1 0 1 1 1 1 0")
        then
          return "Rift Gem", tbl112.mythic.Color, tbl112.mythic.ZIndex
        end
        if
          a1316.ClassName == "MeshPart"
          and a1316:FindFirstChild("ParticleEmitter")
          and string.match(tostring(a1316.ParticleEmitter.Color), "0 0.635294 0 1 0 1 0.635294 0 1 0")
        then
          return "Rift Gem", tbl112.mythic.Color, tbl112.mythic.ZIndex
        end
        if
          a1316.ClassName == "MeshPart"
          and a1316.MeshId == "rbxassetid://5197099782"
          and a1316:FindFirstChild("MeshPart")
          and a1316.MeshPart.MeshId == "rbxassetid://5197111525"
        then
          return "Amulet of the White King", tbl112.artifact.Color, tbl112.artifact.ZIndex
        end
        if
          a1316.ClassName == "MeshPart"
          and a1316.MeshId == "rbxassetid://5196963069"
          and a1316:FindFirstChild("MeshPart")
          and a1316.MeshPart.MeshId == "rbxassetid://5196975152"
        then
          return "Lannis Amulet", tbl112.artifact.Color, tbl112.artifact.ZIndex
        end
        if
          a1316:FindFirstChild("Attachment")
          and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter")
          and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter").Rate == 3
        then
          return "Mysterious Artifact", tbl112.mythic.Color, tbl112.mythic.ZIndex
        end
        if a1316:IsA("MeshPart") and a1316.MeshId == "rbxassetid://4103271893" then
          return "Candy", tbl112.event.Color, tbl112.event.ZIndex
        end
        if a1316.ClassName == "UnionOperation" then
          if fn211(tbl114, fn212(a1316)) then
            return "Scary Mask", tbl112.event.Color, tbl112.event.ZIndex
          end
          if fn212(a1316) == "4117970107" then
            return "Pumpkin Centerpiece", tbl112.event.Color, tbl112.event.ZIndex
          end
          if fn212(a1316) == "17590006505" then
            return "Idol of War", tbl112.event.Color, tbl112.event.ZIndex
          end
        else
          if
            a1316:FindFirstChild("Attachment")
            and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter")
            and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter").Rate == 5
            and tostring(a1316.Attachment:FindFirstChildOfClass("ParticleEmitter").Color):split(" ")[3] ~= "0.8"
          then
            return game.PlaceId == 3541987450 and "Phoenix Flower" or "Azael Horn", tbl112.mythic.Color, tbl112.mythic.ZIndex
          end
          if
            a1316:FindFirstChild("Attachment")
            and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter")
            and a1316.Attachment:FindFirstChildOfClass("ParticleEmitter").Rate == 5
            and tostring(a1316.Attachment:FindFirstChildOfClass("ParticleEmitter").Color):split(" ")[3] == "0.8"
          then
            return "Phoenix Down", tbl112.artifact.Color, tbl112.artifact.ZIndex
          end
          if a1316.ClassName == "MeshPart" and a1316.BrickColor.Name == "Black" then
            return "Night Stone", tbl112.artifact.Color, tbl112.artifact.ZIndex
          end
          if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://%202520762076%20" then
            return "Howler Friend", tbl112.artifact.Color, tbl112.artifact.ZIndex
          end
          if
            a1316.ClassName == "Part"
            and a1316:FindFirstChild("OrbParticle")
            and string.match(tostring(a1316.OrbParticle.Color), "0 0.105882 0.596078 0.596078 0 1 0.105882 0.596078 0.596078 0 ")
          then
            return "Ice Essence", tbl112.rare.Color, tbl112.rare.ZIndex
          end
        end
        if game.PlaceId == 3541987450 then
          if a1316.ClassName == "MeshPart" and a1316.MeshId == "rbxassetid://4027112893" and a1316:FindFirstChild("Part") then
            return "Bound Book", tbl112.rare.Color, tbl112.rare.ZIndex
          end
          if
            a1316.ClassName == "MeshPart"
            and a1316.MeshId == "rbxassetid://%202877143560%20"
            and a1316.Color.B < a1316.Color.G
            and a1316.Color.B > a1316.Color.R
          then
            return "Emerald", tbl112.rare.Color, tbl112.rare.ZIndex
          end
          if
            a1316.ClassName == "MeshPart"
            and a1316.MeshId == "rbxassetid://%202877143560%20"
            and a1316.Color.R > a1316.Color.G
            and a1316.Color.R > a1316.Color.B
          then
            return "Ruby", tbl112.rare.Color, tbl112.rare.ZIndex
          end
          if
            a1316.ClassName == "MeshPart"
            and a1316.MeshId == "rbxassetid://%202877143560%20"
            and a1316.Color.B > a1316.Color.R
            and a1316.Color.B > a1316.Color.G
          then
            return "Sapphire", tbl112.rare.Color, tbl112.rare.ZIndex
          end
          if
            a1316.ClassName == "MeshPart"
            and a1316.MeshId == "rbxassetid://%202877143560%20"
            and tostring(a1316.Color) == "0.643137, 0.733333, 0.745098"
          then
            return "Diamond", tbl112.rare.Color, tbl112.rare.ZIndex
          end
        end
        return "Opal", tbl112.none.Color, tbl112.none.ZIndex
      end
      local fn214 = function(a1317)
        return tbl115[fn212(a1317)]
      end
      local str22 = "Other"
      local tbl116 = {}
      local tbl117 = {}
      for k88, v360 in tbl115 do
        if not tbl117[v360] then
          tbl117[v360] = true
          table.insert(tbl116, v360)
        end
      end
      table.sort(tbl116)
      table.insert(tbl116, str22)
      local fn215 = function(a1318)
        return a1318:IsA("BasePart") and a1318:FindFirstChild("ClickDetector") ~= nil and a1318:FindFirstChild("Blacklist") ~= nil
      end
      local fn216 = function(a1319)
        local AreaMarkers = v354:FindFirstChild("AreaMarkers")
        if not AreaMarkers then
          return "None"
        end
        local str23 = "None"
        local huge2 = math.huge
        local Position2 = a1319.Position
        local getChildrenResult10, v362, v363 = AreaMarkers:GetChildren()
        for k90, v364 in getChildrenResult10, v362, v363 do
          local num82 = Position2 - v364.Position
          local num83 = num82.X * num82.X + num82.Y * num82.Y + num82.Z * num82.Z
          if num83 < huge2 then
            str23 = v364.Name
            huge2 = num83
          end
        end
        return str23
      end
      return function(a1320)
        local v370
        local findIngredientFolder = function()
          if v370 and v370.Parent then
            return v370
          end
          v370 = nil
          local getChildrenResult14, v409, v410 = v354:GetChildren()
          for k100, v411 in getChildrenResult14, v409, v410 do
            if v411.ClassName == "Folder" then
              local getChildrenResult15, v412, v413 = v411:GetChildren()
              for k101, v414 in getChildrenResult15, v412, v413 do
                if v414.ClassName == "UnionOperation" and v414:FindFirstChild("ClickDetector") and v414:FindFirstChild("Blacklist") then
                  v370 = v411
                  return v411
                end
              end
            end
          end
          return nil
        end
        a1320.State.identifyTrinket = fn213
        a1320.State.trinketArea = fn216
        a1320.State.findIngredientFolder = findIngredientFolder
        a1320.State.identifyIngredient = fn214
      end
    end
    tbl44.p = function()
      local value=tbl44.cache.p
      if not value then value={c=fn54()};tbl44.cache.p=value end
      return value.c
    end
    local fn55 = function()
      local aResult8 = tbl44.a()
      local MemStorageService = aResult8.MemStorageService
      local HttpService2 = aResult8.HttpService
      local tbl142 = {}
      local fn290 = function(a1422, ...)
        if not MemStorageService then
          return nil
        end
        local item27 = MemStorageService[a1422]
        if not item27 then
          return nil
        end
        local args={...};args[1]="blade23_lite:"..tostring(args[1])
        local ok70, result72 = pcall(item27, MemStorageService, table.unpack(args))
        if ok70 then
          return result72
        end
        return nil
      end
      tbl142.has = function(a1423)
        return fn290("HasItem", a1423) == true
      end
      tbl142.get = function(a1424)
        if tbl142.has(a1424) then
          return fn290("GetItem", a1424)
        end
        return nil
      end
      tbl142.set = function(a1425, a2139)
        fn290("SetItem", a1425, tostring(a2139))
      end
      tbl142.remove = function(a1426)
        fn290("RemoveItem", a1426)
      end
      tbl142.getJSON = function(a1427)
        local getResult7 = tbl142.get(a1427)
        if type(getResult7) ~= "string" then
          return nil
        end
        local ok71, result73 = pcall(function()
          return HttpService2:JSONDecode(getResult7)
        end)
        return ok71 and result73 or nil
      end
      tbl142.setJSON = function(a1428, a2140)
        local ok72, result74 = pcall(function()
          return HttpService2:JSONEncode(a2140)
        end)
        if ok72 then
          tbl142.set(a1428, result74)
        end
      end
      return tbl142
    end
    tbl44.q = function()
      local q = tbl44.cache.q
      if not q then
        q = { c = fn55() }
        tbl44.cache.q = q
      end
      return q.c
    end
    local fn57 = function()
      local aResult10 = tbl44.a()
      local kResult2 = tbl44.k()
      local getResult9, v486 = aResult10:Get("Players", "Workspace")
      local LocalPlayer8 = getResult9.LocalPlayer
      local replicatesignal_ = replicatesignal
      local tbl145 = {
        kill = function()
          if replicatesignal_ then
            pcall(function()
              replicatesignal_(LocalPlayer8.Kill)
            end)
            return
          end
          local Character5 = LocalPlayer8.Character
          if Character5 then
            pcall(function()
              Character5:BreakJoints()
            end)
          end
        end,
        LOADING_PAD = Vector3.new(-3, -102, 141),
        LOADING_PAD_RANGE = 80,
      }
      tbl145.onLoadingPad = function()
        local Character6 = LocalPlayer8.Character
        local v488 = Character6 and Character6:FindFirstChild("HumanoidRootPart")
        if not (v488 and v488.Parent) then
          return true
        end
        return (v488.Position - tbl145.LOADING_PAD).Magnitude <= tbl145.LOADING_PAD_RANGE
      end
      tbl145.awaitPlaced = function(a1440, a2145, a350)
        if not tbl145.onLoadingPad() then
          return true
        end
        if a350 then
          a350()
        end
        local num107 = os.clock() + (a2145 or 25)
        while os.clock() < num107 do
          if a1440 and not a1440() then
            return false
          end
          if not tbl145.onLoadingPad() then
            return true
          end
          task.wait(0.15)
        end
        return false
      end
      tbl145.root = function()
        local Character7 = LocalPlayer8.Character
        return Character7 and Character7:FindFirstChild("HumanoidRootPart")
      end
      tbl145.rootPos = function()
        local rootResult = tbl145.root()
        return rootResult and rootResult.Position or nil
      end
      tbl145.humanoid = function()
        local Character8 = LocalPlayer8.Character
        return Character8 and Character8:FindFirstChildOfClass("Humanoid")
      end
      tbl145.ready = function()
        local Character9 = LocalPlayer8.Character
        local v489 = Character9 and Character9:FindFirstChildOfClass("Humanoid")
        if
          not (
            Character9
            and v489
            and v489.Health > 0
            and Character9:FindFirstChild("HumanoidRootPart")
            and Character9:FindFirstChild("FakeHumanoid", true)
          )
        then
          return nil
        end
        return Character9, v489
      end
      tbl145.near = function(a1441, a2146)
        local rootResult2 = tbl145.root()
        return rootResult2 ~= nil and (rootResult2.Position - a1441).Magnitude <= a2146
      end
      tbl145.noclip = __NATIVE[75]({ 0 }, { nil }, {})
      tbl145.reclip = function(a1442)
        if not a1442 then
          return
        end
        local getDescendantsResult5, v490, v491 = a1442:GetDescendants()
        for k135, v492 in getDescendantsResult5, v490, v491 do
          if v492:IsA("BasePart") then
            v492.CanCollide = v492.Name == "Head" or v492.Name == "Torso"
          end
        end
      end
      tbl145.noFall = function(a1443)
        if not a1443 then
          return
        end
        a1443:SetStateEnabled(5, false)
        a1443:ChangeState(3)
      end
      local tbl146 = {}
      local tbl147 = { nil }
      tbl145.veilNearby = __NATIVE[76](LocalPlayer8, 0.1, v486, { 0 }, tbl147, tbl146)
      local v487
      local flag22 = false
      local fn300 = function()
        if flag22 or v487 then
          return not flag22
        end
        local ok74, result76 = pcall(function()
          local overlapparams = OverlapParams.new()
          overlapparams.FilterType = Enum.RaycastFilterType.Exclude
          return overlapparams
        end)
        if ok74 and result76 then
          v487 = result76
          return true
        end
        flag22 = true
        kResult2.log("character", "overlap query unavailable, settling on a timer instead: " .. tostring(result76))
        return false
      end
      tbl145.awaitClear = function(a1444, a2147, a351)
        local num108 = tick() + (a1444 or 0)
        local num109 = tick() + (a2147 or 3)
        repeat
          task.wait()
          if a351 and not a351() then
            return false
          end
          local Character10 = LocalPlayer8.Character
          local v493 = Character10 and Character10:FindFirstChild("HumanoidRootPart")
          if not v493 then
            return false
          end
          local ok75 = true
          if fn300() then
            local ok76, result77 = pcall(function()
              v487.FilterDescendantsInstances = { Character10 }
              return v486:GetPartsInPart(v493, v487)
            end)
            if not ok76 then
              flag22 = true
              kResult2.log("character", "overlap query failed, settling on a timer instead: " .. tostring(result77))
            else
              ok75 = #result77 == 0
            end
          end
          if ok75 and tick() >= num108 then
            return true
          end
        until tick() >= num109
        return false
      end
      tbl145.clearVeil = function()
        for k136, v494 in tbl146 do
          if k136 and k136.Parent then
            k136.LocalTransparencyModifier = v494
          end
          tbl146[k136] = nil
        end
        tbl147[1] = nil
      end
      return tbl145
    end
    tbl44.s = function()
      local s = tbl44.cache.s
      if not s then
        s = { c = fn57() }
        tbl44.cache.s = s
      end
      return s.c
    end
    local fn58 = function()
      local getResult10, v495, v496 = tbl44.a():Get("Players", "CollectionService", "RunService")
      local LocalPlayer9 = getResult10.LocalPlayer
      local tbl148 = {
        tagged = function()
          local Character11 = LocalPlayer9.Character
          return Character11 ~= nil and v495:HasTag(Character11, "Danger")
        end,
      }
      local fn301 = function(a1445)
        local v497 = a1445 and a1445.Toggles.IgnoreDanger
        return v497 ~= nil and v497.Value == true
      end
      tbl148.hold = function(a1446, a2148)
        if fn301(a1446) or not tbl148.tagged() then
          return
        end
        if a2148 then
          a2148()
        end
        repeat
          v496.Heartbeat:Wait()
          local cond7 = not tbl148.tagged()
          if cond7 then
            continue
          end
          cond7 = fn301(a1446)
        until cond7
      end
      return tbl148
    end
    tbl44.t = function()
      local t2 = tbl44.cache.t
      if not t2 then
        t2 = { c = fn58() }
        tbl44.cache.t = t2
      end
      return t2.c
    end
    local fn59 = function()
      local setfpscap_ = setfpscap
      local getfpscap_ = getfpscap
      local tbl149 = {}
      local num110 = 60
      local num111 = 30
      local num112 = 240
      local v498
      local tbl150 = {}
      local num113 = 0
      local fn302 = function()
        if getfpscap_ then
          local ok77, result78 = pcall(getfpscap_)
          if ok77 and type(result78) == "number" and result78 > 0 then
            return result78
          end
        end
        return nil
      end
      tbl149.available = function()
        return setfpscap_ ~= nil
      end
      tbl149.parse = function(a1447)
        local num114 = tonumber(a1447)
        if not num114 or num114 <= 0 then
          return nil
        end
        return math.clamp(math.floor(num114), 1, 999)
      end
      local fn303 = function()
        local v499
        for k137, v500 in tbl150 do
          if not v499 or v500 < v499 then
            v499 = v500
          end
        end
        return v499
      end
      local fn304 = function()
        if not setfpscap_ then
          return
        end
        local res121 = fn303()
        if res121 then
          if v498 == nil then
            local res122 = fn302()
            v498 = res122 and res122 >= num111 and res122 or num110
          end
          pcall(setfpscap_, num113 > 0 and num112 or res121)
        elseif v498 then
          pcall(setfpscap_, v498)
          v498 = nil
        end
      end
      tbl149.set = function(a1448, a2149)
        tbl150[a1448] = a2149 and tbl149.parse(a2149) or nil
        fn304()
      end
      tbl149.lift = function()
        num113 += 1
        fn304()
        local flag23 = false
        return function()
          if flag23 then
            return
          end
          flag23 = true
          num113 -= 1
          fn304()
        end
      end
      tbl149.current = function()
        return fn303()
      end
      return tbl149
    end
    tbl44.u = function()
      local u = tbl44.cache.u
      if not u then
        u = { c = fn59() }
        tbl44.cache.u = u
      end
      return u.c
    end
    local fn60 = function()
      local sResult = tbl44.s()
      local aResult11 = tbl44.a()
      local eResult2 = tbl44.e()
      local tResult = tbl44.t()
      local kResult3 = tbl44.k()
      local uResult = tbl44.u()
      local getResult11, v501, v502, v503 = aResult11:Get("Players", "Workspace", "RunService", "ReplicatedStorage")
      local LocalPlayer10 = getResult11.LocalPlayer
      local firesignal_ = firesignal
      local replicatesignal_2 = replicatesignal
      local num115 = 20
      local num116 = 25
      local num117 = 0.4
      local num118 = 2
      local num119 = 30
      local num120 = 100
      local num121 = 3
      local v504
      local tbl151 = {
        setTeleportGuard = function(a1449)
          v504 = a1449
        end,
        serverType = function()
          local ok78, result79 = pcall(function()
            local ServerType = v503:FindFirstChild("ServerType")
            return ServerType and ServerType.Value
          end)
          return ok78 and result79 or nil
        end,
      }
      tbl151.isPrivateServer = function()
        return tbl151.serverType() == "Private"
      end
      tbl151.startMenu = function()
        local PlayerGui3 = LocalPlayer10:FindFirstChildOfClass("PlayerGui")
        return PlayerGui3 and PlayerGui3:FindFirstChild("StartMenu")
      end
      tbl151.clickPlay = function()
        local startMenuResult = tbl151.startMenu()
        local v505 = startMenuResult and startMenuResult:FindFirstChild("Choices")
        local v506 = v505 and v505:FindFirstChild("Play")
        if not v506 then
          return false
        end
        if firesignal_ then
          pcall(firesignal_, v506.MouseButton1Click)
        end
        if replicatesignal_2 then
          pcall(replicatesignal_2, v506.MouseButton1Click)
        end
        return firesignal_ ~= nil or replicatesignal_2 ~= nil
      end
      local fn305 = function()
        return true
      end
      local fn306 = function()
        local PlayerGui4 = LocalPlayer10:FindFirstChildOfClass("PlayerGui")
        local v507 = PlayerGui4 and PlayerGui4:FindFirstChild("MenuReturnGui")
        local v508 = v507 and (v507:FindFirstChild("Menu") or v507:FindFirstChild("Menu", true))
        return v508 ~= nil and v508.Visible
      end
      tbl151.safeToMenu = function()
        return sResult.ready() ~= nil and fn306()
      end
      tbl151.waitMenuReady = function(a1450, a2150)
        local num122 = tick() + (a1450 or 10)
        while tick() < num122 do
          if fn306() and (not a2150 or sResult.ready() ~= nil) then
            return true
          end
          task.wait(0.1)
        end
        return false
      end
      tbl151.returnToMenu = function(a1451)
        local requestRemoteResult = eResult2.requestRemote("ReturnToMenu")
        if not requestRemoteResult then
          return false
        end
        local num123 = 0
        local v509 = a1451 or 3
        repeat
          if tbl151.safeToMenu() then
            pcall(function()
              requestRemoteResult:InvokeServer()
            end)
          end
          task.wait(0.35)
          num123 += 0.35
          local startMenuResult2 = tbl151.startMenu()
          if startMenuResult2 then
            continue
          end
          startMenuResult2 = num123 >= v509
        until startMenuResult2
        return tbl151.startMenu() ~= nil
      end
      tbl151.park = function(a1452, a2151)
        local Character12 = LocalPlayer10.Character
        local v510 = Character12 and Character12:FindFirstChildOfClass("Humanoid")
        if not (Character12 and Character12:FindFirstChild("HumanoidRootPart")) then
          return false
        end
        local connectResult3 = v502.RenderStepped:Connect(__NATIVE[77](sResult, LocalPlayer10, v510))
        local num124 = 0
        local v511 = a2151 or 3
        while num124 < v511 do
          local v512 = LocalPlayer10.Character and LocalPlayer10.Character:FindFirstChild("HumanoidRootPart")
          if not v512 then
            break
          end
          v512.CFrame = CFrame.new(a1452)
          task.wait(0.1)
          num124 += 0.1
        end
        connectResult3:Disconnect()
        return true
      end
      tbl151.forceMenu = function(a1453, a2152)
        local __ml
        local v513 = a1453 or fn305
        while v513() do
          if tbl151.startMenu() then
            return true
          end
          if tResult.tagged() then
            repeat
              v502.Heartbeat:Wait()
              local cond8 = not v513()
              if cond8 then
                continue
              end
              cond8 = not tResult.tagged()
            until cond8
            task.wait(0.5)
          else
            if a2152 then
              tbl151.park(a2152)
            end
            tbl151.waitMenuReady(6, true)
            if not v513() then return false end
            if tbl151.returnToMenu(4) then
              return true
            end
            local num125 = 0
            local randomResult = math.random(12, 47)
            repeat
              task.wait(0.1)
              num125+=0.1
              if num125 < randomResult and v513() then
              else
                __ml = 1
                break
              end
            until tbl151.startMenu()
            if __ml == 1 then
              __ml = nil
              continue
            end
            return true
          end
        end
        return false
      end
      local fn307 = function()
        local Character13 = LocalPlayer10.Character
        return Character13 ~= nil and Character13:FindFirstChild("HumanoidRootPart") ~= nil
      end
      local fn308 = function(a1454, a2153)
        local num126 = 0
        while true do
          if not (not sResult.ready() and num126 < a2153 and a1454()) then
            break
          end
          task.wait(0.25)
          num126 += 0.25
        end
        return sResult.ready() ~= nil
      end
      local fn309 = function(a1455)
        return math.max(a1455 - os.clock(), 0)
      end
      local fn310 = function(a1456, a2154)
        local num127 = os.clock() + (a2154 or 20)
        while true do
          if not (not fn307() and fn309(num127) > 0 and a1456()) then
            break
          end
          if tbl151.startMenu() then
            tbl151.clickPlay()
          end
          task.wait(0.4)
        end
        sResult.awaitPlaced(a1456, math.max(fn309(num127), 8))
        fn308(a1456, fn309(num127))
        return fn307()
      end
      local fn311 = function(a1457, a2155)
        if not fn310(a2155) then
          kResult3.log("menutele", "did not start: never finished spawning")
          return false
        end
        local v514 = LocalPlayer10.Character and LocalPlayer10.Character:FindFirstChildOfClass("Humanoid")
        if not (v514 and v514.Health > 0) then
          kResult3.log("menutele", "did not start: on a corpse or a body with no humanoid")
          return false
        end
        local Character14 = LocalPlayer10.Character
        local num128 = 0
        repeat
          num128 += task.wait()
          local v515 = not tResult.tagged() or num128 > 10
          if v515 then
            continue
          end
          v515 = not a2155()
        until v515
        if tResult.tagged() then
          kResult3.log("menutele", "did not start: still combat tagged after waiting it out")
          return false
        end
        local waitMenuReadyResult = tbl151.waitMenuReady(num116, true)
        if not waitMenuReadyResult then
          kResult3.log("menutele", "did not start: the menu button never came up")
          return false
        end
        local v516 = LocalPlayer10.Character and LocalPlayer10.Character:FindFirstChild("HumanoidRootPart")
        local v517 = LocalPlayer10.Character and LocalPlayer10.Character:FindFirstChildOfClass("Humanoid")
        if not v516 then
          kResult3.log("menutele", "did not start: no root part")
          return false
        end
        local Position4 = v516.Position
        pcall(function()
          local v521 = v516
          v521.Position += Vector3.new(0, 50, 0)
        end)
        local RenderStepped2 = v502.RenderStepped
        local ConnectResult = RenderStepped2:Connect(__NATIVE[78](sResult, kResult3, LocalPlayer10, v501, { true }, v516, v517))
        task.wait(0.25)
        local tbl152 = { 0 }
        local tbl153 = { false }
        local tbl154 = { false }
        local requestRemoteResult2 = eResult2.requestRemote("ReturnToMenu")
        local tbl155 = { nil }
        tbl155[1] = v502.Heartbeat:Connect(
          __NATIVE[79](tbl155, tResult, LocalPlayer10, num118, num117, tbl151, tbl152, tbl153, a1457, requestRemoteResult2, tbl154)
        )
        repeat
          task.wait()
          local v518 = tbl152[1] > num118 + num117 or tbl153[1] or tbl154[1] or tbl151.startMenu()
          if v518 then
            continue
          end
          v518 = not a2155()
        until v518
        pcall(function()
          tbl155[1]:Disconnect()
        end)
        ConnectResult:Disconnect()
        if not (tbl153[1] or tbl151.startMenu()) then
          local rootResult3 = sResult.root()
          if rootResult3 then
            pcall(function()
              rootResult3.CFrame = CFrame.new(Position4)
              rootResult3.AssemblyLinearVelocity = Vector3.zero
            end)
          end
        end
        local num129 = 0
        repeat
          task.wait(0.1)
          num129 += 0.1
          local v519 = tbl151.startMenu() or num129 > 5
          if v519 then
            continue
          end
          v519 = not a2155()
        until v519
        local cond9 = tbl151.startMenu() ~= nil
        fn310(a2155)
        local v520 = LocalPlayer10.Character ~= nil and LocalPlayer10.Character ~= Character14
        if not v520 then
          local rootResult4 = sResult.root()
          if rootResult4 then
            pcall(function()
              rootResult4.CFrame = CFrame.new(Position4)
              rootResult4.AssemblyLinearVelocity = Vector3.zero
            end)
          end
          sResult.reclip(LocalPlayer10.Character)
        end
        local rootResult5 = sResult.root()
        kResult3.log(
          "menutele",
          string.format(
            "to %.0f,%.0f,%.0f from %.0f,%.0f,%.0f | menuUp=%s died=%s tagged=%s sawMenu=%s fresh=%s held=%.1fs landedAt=%s",
            a1457.X,
            a1457.Y,
            a1457.Z,
            Position4.X,
            Position4.Y,
            Position4.Z,
            tostring(waitMenuReadyResult),
            tostring(tbl153[1]),
            tostring(tbl154[1]),
            tostring(cond9),
            tostring(v520),
            tbl152[1],
            rootResult5
                and string.format(
                  "%.0f,%.0f,%.0f (%.0f off)",
                  rootResult5.Position.X,
                  rootResult5.Position.Y,
                  rootResult5.Position.Z,
                  (rootResult5.Position - a1457).Magnitude
                )
              or "no character"
          )
        )
        return v520, tbl153[1]
      end
      local fn312 = function(a1458, a2156, a352)
        local flag24 = false
        local num130 = 0
        for i32 = 1, a352 or num121 do
          if not a2156() then
            kResult3.log("menutele", string.format("caller stopped us before attempt %d", i32))
            break
          end
          if i32 > 1 and not fn308(a2156, num115) then
            break
          end
          local v522 = typeof(a1458) == "function" and a1458() or a1458
          if typeof(v522) ~= "Vector3" then
            break
          end
          num130 = i32
          local res123, v523 = fn311(v522, a2156)
          if res123 and sResult.near(v522, num120) then
            flag24 = true
            break
          end
          if v523 then
            kResult3.log("menutele", "stopping: the attempt ended in a death rather than a menu")
            break
          end
        end
        kResult3.log("menutele", string.format("%s after %d attempt(s)", flag24 and "landed" or "gave up", num130))
        return flag24
      end
      tbl151.menuTele = function(a1459, a2157, a353)
        local v524 = v504 and v504(num119)
        local liftResult = uResult.lift()
        local ok79, result80 = pcall(fn312, a1459, a2157 or fn305, a353)
        liftResult()
        if v524 then
          v524()
        end
        if not ok79 then
          error(result80, 0)
        end
        return result80
      end
      return tbl151
    end
    tbl44.v = function()
      local v525 = tbl44.cache.v
      if not v525 then
        v525 = { c = fn60() }
        tbl44.cache.v = v525
      end
      return v525.c
    end
    local fn62 = function()
      local aResult13 = tbl44.a()
      local HttpService3 = aResult13.HttpService
      local Players4 = aResult13.Players
      local v587 = http_request or request or http and http.request
      local tbl181 = {}
      local str29 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
      local fn350 = function()
        local tbl182 = {}
        for i33 = 1, 8 do
          local randomResult2 = math.random(1, #str29)
          tbl182[i33] = str29:sub(randomResult2, randomResult2)
        end
        return table.concat(tbl182)
      end
      tbl181.config = { url = "", username = "sentinel", showUsername = true, prefix = "", runId = fn350() }
      tbl181.setRunId = function(a1502)
        tbl181.config.runId = type(a1502) == "string" and a1502 ~= "" and a1502 or fn350()
        return tbl181.config.runId
      end
      local fn351 = function(a1503)
        local prefix = tbl181.config.prefix
        if type(prefix) ~= "string" or prefix == "" then
          return a1503
        end
        if type(a1503) == "string" and prefix:find("<@") then
          a1503 = a1503:gsub("@everyone%s*", ""):gsub("@here%s*", "")
        end
        if a1503 == nil or a1503 == "" then
          return prefix
        end
        return prefix .. "\n" .. a1503
      end
      local fn352 = function(a1504)
        local alertPing = tbl181.config.alertPing
        if type(a1504) ~= "string" or type(alertPing) ~= "string" then
          return a1504
        end
        local v588 = alertPing == "" and "%s*" or ""
        return a1504
          :gsub("@everyone" .. v588, function()
            return alertPing
          end)
          :gsub("@here" .. v588, function()
            return alertPing
          end)
      end
      tbl181.setConfig = function(a1505)
        if type(a1505) ~= "table" then
          return
        end
        if a1505.url ~= nil then
          tbl181.config.url = a1505.url
        end
        if a1505.username ~= nil and a1505.username ~= "" then
          tbl181.config.username = a1505.username
        end
        if a1505.showUsername ~= nil then
          tbl181.config.showUsername = a1505.showUsername
        end
        if a1505.prefix ~= nil then
          tbl181.config.prefix = a1505.prefix
        end
        if a1505.alertPing ~= nil then
          tbl181.config.alertPing = a1505.alertPing or nil
        end
      end
      tbl181.available = function()
        return v587 ~= nil and tbl181.config.url ~= ""
      end
      local num145 = 0
      local num146 = 0.4
      local num147 = 5
      tbl181.sendTo = function(a1506, a2163)
        if not v587 or type(a1506) ~= "string" or a1506 == "" then
          return false
        end
        local sel5 = select(
          2,
          pcall(function()
            return HttpService3:JSONEncode(a2163)
          end)
        )
        if type(sel5) ~= "string" then
          return false
        end
        local tbl183 = { Url = a1506, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = sel5 }
        local num148 = num146 - (os.clock() - num145)
        if num148 > 0 then
          task.wait(num148)
        end
        local ok83, result84 = pcall(v587, tbl183)
        num145 = os.clock()
        if (ok83 and type(result84) == "table" and (result84.StatusCode or result84.status_code) or nil) == 429 then
          local num149 = 2
          pcall(function()
            local v589 = result84.Body or result84.body
            local v590 = v589 and HttpService3:JSONDecode(v589)
            if v590 and v590.retry_after then
              num149 = tonumber(v590.retry_after) or num149
            end
          end)
          task.wait(math.clamp(num149, 0.5, 10) + 0.2)
          ok83 = pcall(v587, tbl183)
          num145 = os.clock()
        end
        return ok83
      end
      local fn353 = function(a1507)
        local runId = tbl181.config.runId
        if not (runId and runId ~= "") then
          return a1507
        end
        if type(a1507.content) == "string" and a1507.content ~= "" then
          a1507.content = "`" .. runId .. "` " .. a1507.content
        end
        local ipairsResult, v591, v592 = ipairs(a1507.embeds or {})
        for k149, v593 in ipairsResult, v591, v592 do
          v593.footer = v593.footer or {}
          local text3 = v593.footer.text
          v593.footer.text = type(text3) == "string" and text3 ~= "" and text3 .. " | run " .. runId or "run " .. runId
        end
        return a1507
      end
      local fn354 = function(a1508)
        if not (a1508 and a1508 ~= "" and tbl181.config.showUsername) then
          return a1508
        end
        return "||[**" .. (Players4.LocalPlayer and Players4.LocalPlayer.Name or "?") .. "**]|| " .. a1508
      end
      local fn355 = function(a1509)
        local tbl184 = {
          url = function()
            return a1509()
          end,
          available = function()
            return v587 ~= nil and a1509() ~= ""
          end,
          send = function(a1510)
            local res143 = a1509()
            if res143 == "" then
              return false
            end
            return tbl181.sendTo(res143, fn353(a1510))
          end,
        }
        tbl184.text = function(a1511)
          return tbl184.send({ username = tbl181.config.username, content = fn351(fn354(fn352(a1511))) })
        end
        tbl184.textBounded = function(a1512, a2164)
          local flag26 = false
          task.spawn(function()
            pcall(tbl184.text, a1512)
            flag26 = true
          end)
          local num150 = os.clock() + (tonumber(a2164) or num147)
          while true do
            if not (not flag26 and os.clock() < num150) then
              break
            end
            task.wait(0.05)
          end
          return flag26
        end
        tbl184.embed = function(a1513)
          return tbl184.send({ username = tbl181.config.username, content = fn351(nil), embeds = { a1513 } })
        end
        tbl184.embedWith = function(a1514, a2165)
          return tbl184.send({ username = tbl181.config.username, content = fn351(fn354(fn352(a1514))), embeds = { a2165 } })
        end
        return tbl184
      end
      local res142 = fn355(function()
        return tbl181.config.url
      end)
      local send = res142.send
      local text2 = res142.text
      local textBounded = res142.textBounded
      tbl181.send = send
      tbl181.text = text2
      tbl181.textBounded = textBounded
      local embed = res142.embed
      local embedWith = res142.embedWith
      tbl181.embed = embed
      tbl181.embedWith = embedWith
      tbl181.scoped = function(a1515)
        return fn355(function()
          local v594 = type(a1515) == "function" and a1515() or a1515
          return type(v594) == "string" and v594 ~= "" and v594 or tbl181.config.url
        end)
      end
      return tbl181
    end
    tbl44.x = function()
      local x = tbl44.cache.x
      if not x then
        x = { c = fn62() }
        tbl44.cache.x = x
      end
      return x.c
    end
    local fn65 = function()
      local aResult16 = tbl44.a()
      local eResult3 = tbl44.e()
      local dResult10 = tbl44.d()
      local iResult3 = tbl44.i()
      local vResult3 = tbl44.v()
      local getResult14, v631, v632, v633 = aResult16:Get("Players", "Workspace", "RunService", "ReplicatedStorage")
      local LocalPlayer13 = getResult14.LocalPlayer
      local num163 = 3541987450
      local fn379 = function(a1542)
        return tostring(a1542):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
      end
      local fn380 = function(a1543)
        local Character17 = a1543.Character
        if not (Character17 and Character17:FindFirstChild("Carried")) then
          return false
        end
        local Character18 = LocalPlayer13.Character
        local v634 = Character18 and Character18:FindFirstChild("HumanoidRootPart")
        local HumanoidRootPart6 = Character17:FindFirstChild("HumanoidRootPart")
        return v634 ~= nil and HumanoidRootPart6 ~= nil and (v634.Position - HumanoidRootPart6.Position).Magnitude <= 1
      end
      local tbl195 = {
        Fire = true,
        OrderField = true,
        PoisonField = true,
        SolanBall = true,
        SolansGate = true,
        BaalField = true,
        Elevator = true,
        MageField = true,
        TeleportIn = true,
        TeleportOut = true,
      }
      local tbl196 = { ["Reddish brown"] = true, Copper = true, Magenta = true }
      local num164 = 30
      return function(a1544)
        local Library7 = a1544.Library
        local Toggles6 = Library7.Toggles
        local Options6 = Library7.Options
        local World = a1544.Tabs.World
        iResult3.mark(a1544, "Blatant", "NoKillBricks")
        iResult3.mark(a1544, "Blatant", "NoFall")
        local addLeftGroupboxResult11 = World:AddLeftGroupbox("World Settings")
        local addRightGroupboxResult16 = World:AddRightGroupbox("Proximity")
        local setKillbricks = function(a1545)
          local getChildrenResult24, v642, v643 = (
            game.PlaceId == 5208655184 and v631:FindFirstChild("Map")
            or game.PlaceId == 3541987450 and v631
            or v631:FindFirstChild("Map")
            or v631
          ):GetChildren()
          for k160, v644 in getChildrenResult24, v642, v643 do
            if
              v644:IsA("BasePart")
              and v644:FindFirstChild("TouchInterest")
              and not (tbl195[v644.Name] or tbl196[v644.BrickColor.Name])
            then
              v644.CanTouch = not a1545
            end
          end
        end
        a1544.State.setKillbricks = setKillbricks
        local num165 = 0
        local flag29 = false
        local flag30 = false
        local refreshGuards = function(a1546)
          if flag29 then
            a1544.State.noFallUntil = math.max(a1544.State.noFallUntil or 0, tick() + (a1546 or num164))
          end
        end
        local holdGuards = function(a1547)
          num165 += 1
          if not (Toggles6.NoFall and Toggles6.NoFall.Value) then
            flag29 = true
            refreshGuards(a1547)
          end
          if not (Toggles6.NoKillBricks and Toggles6.NoKillBricks.Value) and not flag30 then
            flag30 = true
            pcall(setKillbricks, true)
          end
          local flag31 = false
          return function()
            if flag31 then
              return
            end
            flag31 = true
            num165 -= 1
            if num165 > 0 then
              return
            end
            if flag29 then
              flag29 = false
              a1544.State.noFallUntil = 0
            end
            if flag30 then
              flag30 = false
              pcall(setKillbricks, false)
            end
          end
        end
        a1544.State.holdGuards = holdGuards
        a1544.State.refreshGuards = refreshGuards
        vResult3.setTeleportGuard(holdGuards)
        a1544.Maid:Give(function()
          if Toggles6.NoKillBricks and Toggles6.NoKillBricks.Value then
            setKillbricks(false)
          end
        end)
        local Callback5 = function(a1548)
          local v645 = v631:FindFirstChild("MonstersSpawns") or v631:FindFirstChild("MonsterSpawns")
          local v646 = v645 and v645:FindFirstChild("Triggers")
          if not v646 then
            return
          end
          local getDescendantsResult10, v647, v648 = v646:GetDescendants()
          for k161, v649 in getDescendantsResult10, v647, v648 do
            if v649:IsA("BasePart") then
              pcall(function()
                v649.CanTouch = not a1548
              end)
            end
          end
        end
        local v635 = addLeftGroupboxResult11
        v635:AddToggle("NoMobTrigger", { Text = "No Mob Trigger", Default = false, Callback = Callback5 })
        a1544.Maid:Give(function()
          if Toggles6.NoMobTrigger and Toggles6.NoMobTrigger.Value then
            Callback5(false)
          end
        end)
        local tbl197 = {}
        local Callback6 = function(a1549)
          if a1549 then
            local getDescendantsResult11, v650, v651 = (
              game.PlaceId == 5208655184 and v631:FindFirstChild("Map")
              or game.PlaceId == 3541987450 and v631
              or v631:FindFirstChild("Map")
              or v631
            ):GetDescendants()
            for k162, v652 in getDescendantsResult11, v650, v651 do
              if v652:IsA("BasePart") and (v652.Name == "OrderField" or v652.Name == "PurityField" or v652.Name == "MageField") then
                table.insert(tbl197, v652)
                pcall(function()
                  v652.CanTouch = false
                  v652.CanCollide = false
                end)
              end
            end
          else
            for k163, v653 in tbl197 do
              if v653 and v653.Parent then
                pcall(function()
                  v653.CanTouch = true
                  v653.CanCollide = true
                end)
              end
            end
            table.clear(tbl197)
          end
        end
        addLeftGroupboxResult11:AddToggle(
          "NoOrderlyBarriers",
          { Text = "No Orderly Barriers", Default = false, Tooltip = iResult3.risky(), Callback = Callback6 }
        )
        iResult3.mark(a1544, "Risky", "NoOrderlyBarriers")
        a1544.Maid:Give(function()
          if Toggles6.NoOrderlyBarriers and Toggles6.NoOrderlyBarriers.Value then
            Callback6(false)
          end
        end)
        local num166 = 0
        a1544.State.addFireBlocker = function(a1550)
          a1544.State.fireServerBlockers = a1544.State.fireServerBlockers or {}
          table.insert(a1544.State.fireServerBlockers, a1550)
        end
        if hookfunction then
          local v636
          local fn381 = function(a1551, ...)
            local fireServerObservers = a1544.State.fireServerObservers
            if fireServerObservers then
              for k164, v654 in fireServerObservers do
                pcall(v654, a1551, ...)
              end
            end
            local fireServerBlockers2 = a1544.State.fireServerBlockers
            if fireServerBlockers2 then
              for k165, v655 in fireServerBlockers2 do
                local ok89, result90 = pcall(v655, a1551, ...)
                if ok89 and result90 then
                  return
                end
              end
            end
            local tbl203 = { ... }
            local Character19 = LocalPlayer13.Character
            local v656 = Character19 and Character19:FindFirstChild("CharacterHandler")
            local v657 = v656 and v656:FindFirstChild("Remotes")
            if
              (Toggles6.NoFall and Toggles6.NoFall.Value or a1544.State.noFallUntil and tick() < a1544.State.noFallUntil)
              and v657
              and a1551.Parent == v657
              and #tbl203 == 2
              and typeof(tbl203[2]) == "table"
              and not (a1544.State and a1544.State.fallDamageBypassUntil and tick() < a1544.State.fallDamageBypassUntil)
              and not (a1544.State and a1544.State.scroomNoFallOverride)
            then
              return
            end
            if
              Toggles6.FallDamageReducer
              and Toggles6.FallDamageReducer.Value
              and v657
              and a1551.Parent == v657
              and #tbl203 == 2
              and typeof(tbl203[1]) == "table"
              and typeof(tbl203[2]) == "table"
              and next(tbl203[2]) == nil
            then
              local item31 = tbl203[1]
              local v658 = game.PlaceId == num163 and #item31 == 1 and typeof(item31[1]) == "number" and 1
                or #item31 == 2 and typeof(item31[1]) == "number" and typeof(item31[2]) == "number" and 2
                or nil
              if v658 then
                local item32 = item31[v658]
                item31[v658] = item32
                  * (1 - math.clamp(Options6.FallDamageReduction and Options6.FallDamageReduction.Value or 0, 0, 100) / 100)
                local res151 = v636(a1551, table.unpack(tbl203))
                item31[v658] = item32
                return res151
              end
            end
            if
              Toggles6.TemperatureLock
              and Toggles6.TemperatureLock.Value
              and #tbl203 == 1
              and typeof(tbl203[1]) == "string"
              and tbl203[1] ~= "Castle Rock"
            then
              local Requests4 = v633:FindFirstChild("Requests")
              if Requests4 and a1551.Parent == Requests4 and a1551.Name ~= "ClearTrinket" then
                return os.clock() < num166 and "Sea of Dust" or "Oresfall"
              end
            end
            return v636(a1551, ...)
          end
          v636 = hookfunction(Instance.new("RemoteEvent").FireServer, newcclosure and newcclosure(fn381) or fn381)
          a1544.Maid:Give(function()
            pcall(hookfunction, Instance.new("RemoteEvent").FireServer, v636)
          end)
          local tbl198 = { GeliFreezing = true, IceCase = true, FlightOk = true }
          local fn382 = function(a1552)
            if not (a1552 and Toggles6.TemperatureLock and Toggles6.TemperatureLock.Value) then
              return
            end
            if a1552:FindFirstChild("GeliFreezing") and a1552:FindFirstChild("IceCase") and a1552:FindFirstChild("FlightOk") then
              num166 = os.clock() + math.random(60, 85)
            end
          end
          local newResult52 = dResult10.new()
          a1544.Maid:Give(newResult52)
          local fn383 = function(a1553)
            newResult52:DoCleaning()
            if not a1553 then
              return
            end
            newResult52:Connect(a1553.ChildAdded, function(a1554)
              if tbl198[a1554.Name] then
                fn382(a1553)
              end
            end)
            fn382(a1553)
          end
          fn383(LocalPlayer13.Character)
          local Maid4 = a1544.Maid
          Maid4:Give(LocalPlayer13.CharacterAdded:Connect(fn383))
        end
        addLeftGroupboxResult11:AddToggle(
          "TemperatureLock",
          { Text = "Temperature Lock", Default = false, Tooltip = "Keeps your temperature normal" }
        )
        local newResult53 = dResult10.new()
        a1544.Maid:Give(newResult53)
        local tbl199 = {}
        a1544.Maid:Give(function()
          for k166, v659 in tbl199 do
            if k166 and k166.Parent then
              k166.Material = v659.Material
              k166.Reflectance = v659.Reflectance
            end
          end
          table.clear(tbl199)
        end)
        local res150 = __NATIVE[87](v631, tbl199)
        addLeftGroupboxResult11:AddToggle("NoTextures", {
          Text = "No Textures",
          Default = false,
          Callback = function(a1555)
            if game.PlaceId == 3541987450 then
              return
            end
            if a1555 then
              task.spawn(__NATIVE[88](v631, res150))
              local v660 = newResult53
              v660:Connect(v631.DescendantAdded, __NATIVE[89](Toggles6, res150))
              newResult53:Connect(v631.DescendantRemoving, function(a1556)
                tbl199[a1556] = nil
              end)
            else
              newResult53:DoCleaning()
              for k167, v661 in tbl199 do
                if k167 and k167.Parent then
                  k167.Material = v661.Material
                  k167.Reflectance = v661.Reflectance
                end
              end
              table.clear(tbl199)
            end
          end,
        })
        local v637
        local tbl200 = {}
        local newResult54 = dResult10.new()
        a1544.Maid:Give(newResult54)
        local fn384 = function()
          if not v637 then
            v637 = Instance.new("Folder")
            v637.Name = "SentinelWeatherStash"
            v637.Parent = aResult16.CoreGui
          end
          return v637
        end
        local fn385 = function(a1557)
          if tbl200[a1557] or a1557.Parent == v637 then
            return
          end
          tbl200[a1557] = a1557.Parent
          pcall(function()
            a1557.Parent = fn384()
          end)
        end
        local fn386 = function()
          local Thrown2 = v631:FindFirstChild("Thrown")
          if not Thrown2 then
            return
          end
          local getChildrenResult25, v662, v663 = Thrown2:GetChildren()
          for k168, v664 in getChildrenResult25, v662, v663 do
            if v664.Name == "WeatherEffect" then
              fn385(v664)
            end
          end
        end
        local fn387 = function()
          local Thrown3 = v631:FindFirstChild("Thrown")
          local pairsResult, v665, v666 = pairs(tbl200)
          for k169, v667 in pairsResult, v665, v666 do
            if k169 and k169.Parent == v637 then
              pcall(function()
                k169.Parent = v667 and v667.Parent and v667 or Thrown3
              end)
            end
            tbl200[k169] = nil
          end
        end
        addLeftGroupboxResult11:AddToggle("DisableSnow", {
          Text = "Disable Snow",
          Default = false,
          Callback = function(a1558)
            if a1558 then
              fn386()
              local v668 = newResult54
              v668:Give(task.spawn(function()
                while true do
                  if not (Toggles6.DisableSnow and Toggles6.DisableSnow.Value) then
                    break
                  end
                  fn386()
                  task.wait(0.25)
                end
              end))
            else
              newResult54:DoCleaning()
              fn387()
            end
          end,
        })
        a1544.Maid:Give(function()
          fn387()
          if v637 then
            v637:Destroy()
          end
        end)
        addLeftGroupboxResult11:AddDivider()
        local v638 = addLeftGroupboxResult11
        v638:AddToggle("NoKillBricks", { Text = "No Kill Bricks", Default = false, Tooltip = iResult3.blatant(), Callback = setKillbricks })
        local v639 = addLeftGroupboxResult11
        v639:AddToggle("NoFall", { Text = "No Fall Damage", Default = false, Tooltip = iResult3.blatant() })
        local v640 = addLeftGroupboxResult11
        iResult3.mark(
          a1544,
          "Risky",
          "FallDamageReducer",
          v640:AddToggle("FallDamageReducer", {
            Text = "Fall Damage Reducer",
            Default = false,
            Tooltip = iResult3.risky("lowers fall damage instead of blocking it"),
          })
        )
        addLeftGroupboxResult11:AddSlider(
          "FallDamageReduction",
          { Text = "Reduction", Default = 95, Min = 0, Max = 95, Rounding = 0, Suffix = "%" }
        )
        local newResult55 = dResult10.new()
        a1544.Maid:Give(newResult55)
        local v641
        local tbl201 = { nil }
        local tbl202 = { 0 }
        local fn388 = function()
          if v641 then
            return
          end
          v641 = Instance.new("ScreenGui")
          v641.ResetOnSpawn = false
          if not pcall(function()
            v641.Parent = gethui and gethui() or game:GetService("CoreGui")
          end) then
            v641.Parent = LocalPlayer13:FindFirstChildOfClass("PlayerGui")
          end
          tbl201[1] = Instance.new("TextLabel")
          tbl201[1].Size = UDim2.new(0, 400, 0, 50)
          tbl201[1].Position = UDim2.new(0.5, -200, 0, 150)
          tbl201[1].BackgroundTransparency = 1
          tbl201[1].TextColor3 = Color3.fromRGB(255, 255, 255)
          tbl201[1].TextStrokeTransparency = 0
          tbl201[1].TextSize = 32
          tbl201[1].Font = Enum.Font.SourceSansBold
          tbl201[1].RichText = true
          tbl201[1].Text = ""
          tbl201[1].Visible = false
          tbl201[1].Parent = v641
        end
        local fn389 = function()
          fn388()
          newResult55.loop =
            v632.Heartbeat:Connect(__NATIVE[90](LocalPlayer13, Options6, getResult14, Toggles6, a1544, fn379, tbl202, fn380, tbl201))
        end
        local fn390 = function()
          newResult55:DoCleaning()
          if tbl201[1] then
            tbl201[1].Visible = false
          end
        end
        a1544.Maid:Give(function()
          if v641 then
            v641:Destroy()
          end
        end)
        addRightGroupboxResult16:AddToggle("ProximityNotifier", {
          Text = "Proximity Notifier",
          Default = false,
          Callback = function(a1559)
            if a1559 then
              fn389()
            else
              fn390()
            end
          end,
        })
        addRightGroupboxResult16:AddToggle("ProximityIgnoreAllies", { Text = "Ignore Allies", Default = false })
        addRightGroupboxResult16:AddSlider(
          "ProximityDistance",
          { Text = "Distance Threshold", Min = 0, Max = 1000, Default = 100, Rounding = 0, Suffix = " studs" }
        )
      end
    end
    tbl44.A = function()
      local A = tbl44.cache.A
      if not A then
        A = { c = fn65() }
        tbl44.cache.A = A
      end
      return A.c
    end
    local fn66 = function()
      local getResult15, v669 = tbl44.a():Get("UserInputService", "RunService")
      local setfpscap_2 = setfpscap
      local getfpscap_2 = getfpscap
      local v670 = isrbxactive or iswindowactive or isgameactive
      local tbl204 = { 30, 60, 75, 90, 120, 144, 165, 180, 240, 360 }
      local num167 = 0.5
      local num168 = 0.4
      local num169 = 999
      local tbl205 = {}
      local tbl206 = { active = false, hdMode = false, savedQuality = nil, savedCap = nil }
      local v671
      local v672
      local fn391 = function(a1560)
        if setfpscap_2 then
          pcall(setfpscap_2, a1560)
        end
      end
      local fn392 = function(a1561)
        pcall(function()
          settings().Rendering.QualityLevel = a1561
        end)
      end
      local fn393 = function()
        local tbl207 = { 0 }
        local connectResult4 = v669.RenderStepped:Connect(__NATIVE[91](tbl207))
        local clockResult4 = os.clock()
        while true do
          task.wait()
          if os.clock() - clockResult4 >= num168 then
            break
          end
        end
        pcall(function()
          connectResult4:Disconnect()
        end)
        local num170 = tbl207[1] / math.max(os.clock() - clockResult4, 0.01)
        for k170, v673 in tbl204 do
          if num170 <= v673 + num167 then
            return v673
          end
        end
        return num169
      end
      local fn394 = function()
        if getfpscap_2 then
          local ok90, result91 = pcall(getfpscap_2)
          if ok90 and type(result91) == "number" and result91 > 0 then
            return result91
          end
        end
        return fn393()
      end
      local fn395 = function(a1562)
        pcall(function()
          v669:Set3dRenderingEnabled(a1562)
        end)
      end
      tbl205.setHdMode = function(a1563)
        tbl206.hdMode = a1563 == true
      end
      tbl205.start = function()
        if tbl206.active then
          return
        end
        tbl206.active = true
        pcall(function()
          tbl206.savedQuality = settings().Rendering.QualityLevel
        end)
        tbl206.savedCap = fn394()
        local fn396 = function()
          if not tbl206.active then
            return
          end
          fn391(tbl206.hdMode and 50 or 20)
          fn392(tbl206.savedQuality or Enum.QualityLevel.Automatic)
          fn395(true)
        end
        local fn397 = function()
          if not tbl206.active then
            return
          end
          fn391(15)
          fn392(Enum.QualityLevel.Level01)
          fn395(false)
        end
        local ok91 = true
        if v670 then
          local ok92, result92 = pcall(v670)
          ok91 = not ok92 or result92 ~= false
        end
        if ok91 then
          fn396()
        else
          fn397()
        end
        v671 = select(
          2,
          pcall(function()
            return getResult15.WindowFocused:Connect(fn396)
          end)
        )
        v672 = select(
          2,
          pcall(function()
            return getResult15.WindowFocusReleased:Connect(fn397)
          end)
        )
      end
      tbl205.stop = function()
        if not tbl206.active then
          return
        end
        tbl206.active = false
        if v671 then
          pcall(function()
            v671:Disconnect()
          end)
          v671 = nil
        end
        if v672 then
          pcall(function()
            v672:Disconnect()
          end)
          v672 = nil
        end
        fn391(tbl206.savedCap or num169)
        fn392(tbl206.savedQuality or Enum.QualityLevel.Automatic)
        fn395(true)
      end
      return tbl205
    end
    tbl44.B = function()
      local B = tbl44.cache.B
      if not B then
        B = { c = fn66() }
        tbl44.cache.B = B
      end
      return B.c
    end
    local fn67 = function()
      local HttpService4 = tbl44.a().HttpService
      local v674 = http_request or request or http and http.request
      local __index6 = {}
      __index6.__index = __index6
      local num171 = 7963
      local str33 = ""
      __index6.setPort = function(a1564)
        num171 = tonumber(a1564) or num171
      end
      __index6.setPassword = function(a1565)
        str33 = tostring(a1565 or "")
      end
      local fn398 = function(a1566, a2171, a358)
        if not v674 then
          return nil
        end
        local formatResult = string.format("http://localhost:%d/%s?Account=%s", num171, a1566, HttpService4:UrlEncode(a2171))
        local ipairsResult2, v675, v676 = ipairs(a358 or {})
        for k171, v677 in ipairsResult2, v675, v676 do
          formatResult ..= "&" .. v677
        end
        if str33 ~= "" and #str33 >= 6 then
          formatResult ..= "&Password=" .. HttpService4:UrlEncode(str33)
        end
        local ok93, result93 = pcall(v674, { Url = formatResult, Method = "GET" })
        if not ok93 or type(result93) ~= "table" then
          return nil
        end
        local v678 = result93.StatusCode or result93.status_code
        if v678 and v678 ~= 200 then
          return nil
        end
        return result93.Body or result93.body
      end
      __index6.new = function(a1567, a2172)
        if not a1567 or a1567 == "" then
          return nil
        end
        if not a2172 then
          local res152 = fn398("GetCSRFToken", a1567)
          if not res152 or res152 == "Invalid Account" then
            return nil
          end
        end
        return setmetatable({ username = a1567 }, __index6)
      end
      local fn399 = function(a1568)
        if type(a1568) == "number" then
          return a1568
        end
        if typeof(a1568) == "Instance" and a1568:IsA("Player") then
          return a1568.UserId
        end
        return tonumber(a1568)
      end
      __index6.blockUser = function(a1569, a2173)
        local res153 = fn399(a2173)
        if not res153 then
          return nil
        end
        return fn398("BlockUser", a1569.username, { "UserId=" .. tostring(res153) })
      end
      __index6.unblockUser = function(a1570, a2174)
        local res154 = fn399(a2174)
        if not res154 then
          return nil
        end
        return fn398("UnblockUser", a1570.username, { "UserId=" .. tostring(res154) })
      end
      __index6.unblockEveryone = function(a1571)
        return fn398("UnblockEveryone", a1571.username)
      end
      __index6.getBlockedList = function(a1572)
        return fn398("GetBlockedList", a1572.username)
      end
      __index6.getCSRFToken = function(a1573)
        return fn398("GetCSRFToken", a1573.username)
      end
      return __index6
    end
    tbl44.C = function()
      local C = tbl44.cache.C
      if not C then
        C = { c = fn67() }
        tbl44.cache.C = C
      end
      return C.c
    end
    local fn68 = function()
      local CResult = tbl44.C()
      local vResult4 = tbl44.v()
      local qResult2 = tbl44.q()
      local aResult17 = tbl44.a()
      local kResult4 = tbl44.k()
      local getResult16, v679, v680, v681, v682 =
        aResult17:Get("Players", "ReplicatedStorage", "TeleportService", "CollectionService", "HttpService")
      local LocalPlayer14 = getResult16.LocalPlayer
      local v683 = http_request or request or http and http.request
      local num172 = 25
      local str34 = "sentinel/loader.lua"
      local str35 = "https://sentinel.heroinhound.cc/loader"
      local num173 = 3016661674
      local num174 = 3
      local num175 = 1.5
      local num176 = 6
      local num177 = 15
      local num178 = 12
      local tbl208 = {}
      local fn400 = function(a1574)
        local Requests5 = v679:FindFirstChild("Requests")
        return Requests5 and Requests5:FindFirstChild(a1574)
      end
      local fn401 = function(a1575)
        return "RecentServers_" .. tostring(a1575 or game.PlaceId)
      end
      tbl208.visited = function(a1576)
        return qResult2.getJSON(fn401(a1576)) or {}
      end
      tbl208.markVisited = function(a1577)
        if not a1577 then
          return
        end
        local res155 = fn401(game.PlaceId)
        local v689 = qResult2.getJSON(res155) or {}
        for i36 = #v689, 1, -1 do
          if v689[i36] == a1577 then
            table.remove(v689, i36)
          end
        end
        table.insert(v689, 1, a1577)
        while #v689 > 35 do
          table.remove(v689)
        end
        qResult2.setJSON(res155, v689)
      end
      tbl208.clearVisited = function(a1578)
        qResult2.setJSON(fn401(a1578), {})
      end
      tbl208.blockCurrentPlayers = function()
        local newResult56 = CResult.new(LocalPlayer14.Name)
        if not newResult56 then
          return false
        end
        local getPlayersResult15, v690, v691 = getResult16:GetPlayers()
        for k172, v692 in getPlayersResult15, v690, v691 do
          if v692 ~= LocalPlayer14 then
            local blockUserResult = newResult56:blockUser(v692.UserId)
            if blockUserResult and tostring(blockUserResult):find('"success":false', 1, true) then
              newResult56:unblockEveryone()
            end
          end
        end
        return true
      end
      local fn402 = function(a1579)
        if not v683 then
          return nil, "no http_request on this executor"
        end
        local formatResult2 =
          string.format("https://games.roblox.com/v1/games/%d/servers/0?sortOrder=2&excludeFullGames=true&limit=100", a1579)
        local v693
        for i37 = 1, num174 do
          local ok94, result94 = pcall(v683, { Url = formatResult2, Method = "GET", Headers = { Accept = "application/json" } })
          local v694 = ok94 and type(result94) == "table" and (result94.StatusCode or result94.status_code) or nil
          local v695 = ok94 and type(result94) == "table" and (result94.Body or result94.body) or nil
          if not ok94 or type(result94) ~= "table" then
            v693 = "the executor's http request threw"
          elseif v694 and v694 ~= 200 then
            v693 = v694 == 429 and "roblox is rate limiting the server list (429)"
              or string.format("roblox returned HTTP %d for the server list", v694)
          elseif type(v695) ~= "string" or v695 == "" then
            v693 = "roblox sent an empty server list"
          else
            local sel6 = select(
              2,
              pcall(function()
                return v682:JSONDecode(v695)
              end)
            )
            if type(sel6) == "table" and type(sel6.data) == "table" then
              return sel6.data
            end
            v693 = "the server list came back in a shape we could not read"
          end
          if i37 < num174 then
            task.wait(num175 * i37)
          end
        end
        return nil, v693
      end
      local fn403 = function()
        local ServerInfo = v679:FindFirstChild("ServerInfo")
        if not ServerInfo then
          return nil
        end
        local tbl209 = {}
        local getChildrenResult26, v696, v697 = ServerInfo:GetChildren()
        for k173, v698 in getChildrenResult26, v696, v697 do
          local Players5 = v698:FindFirstChild("Players")
          local Lifespan = v698:FindFirstChild("Lifespan")
          local num181 = 0
          if Players5 then
            local sel7 = select(
              2,
              pcall(function()
                return v682:JSONDecode(Players5.Value)
              end)
            )
            if type(sel7) == "table" then
              num181 = #sel7
            end
          end
          table.insert(tbl209, { id = v698.Name, playing = num181, maxPlayers = 23, lifespan = Lifespan and Lifespan.Value or 0 })
        end
        return tbl209
      end
      tbl208.pickServer = function(a1580)
        local v699 = a1580 or {}
        local v700 = v699.placeId or game.PlaceId
        local v701 = v699.minPlayers or 0
        local v702 = v699.maxPlayers or 22
        local v703 = v699.strategy or "random"
        local res156, str36
        if v703 == "oldest" or v703 == "newest" then
          res156 = fn403()
          str36 = "this realm publishes no ServerInfo to sort by age"
        else
          local res157, v704 = fn402(v700)
          res156 = res157
          str36 = v704
          if not res156 then
            local res158 = fn403()
            if res158 and #res158 > 0 then
              res156 = res158
            end
          end
        end
        if not res156 then
          return nil, str36 or "server list request failed"
        end
        if #res156 == 0 then
          return nil, "server list came back empty"
        end
        local visitedResult = tbl208.visited(v700)
        local fn407 = function(a1581)
          for k175, v707 in visitedResult do
            if v707 == a1581 then
              return true
            end
          end
          return false
        end
        local v705 = v699.avoid or {}
        local tbl210 = {}
        local num182 = 0
        local num183 = 0
        local num184 = 0
        local num185 = 0
        for k174, v706 in res156 do
          if v706.id and v706.id ~= game.JobId then
            num182 += 1
            if v705[v706.id] then
              num185 += 1
            elseif not v699.ignoreVisited and fn407(v706.id) then
              num183 += 1
            elseif not (v706.playing >= v701 and v706.playing <= v702 and v706.playing < (v706.maxPlayers or 23)) then
              num184 += 1
            else
              table.insert(tbl210, v706)
            end
          end
        end
        if #tbl210 == 0 then
          return nil,
            string.format(
              "%d listed, %d already visited, %d outside %d-%d players, %d held by your other bots",
              num182,
              num183,
              num184,
              v701,
              v702,
              num185
            ),
            num183
        end
        if v703 == "oldest" then
          table.sort(tbl210, function(a1582, a2175)
            return (a1582.lifespan or 0) > (a2175.lifespan or 0)
          end)
          return tbl210[1].id
        end
        if v703 == "newest" then
          table.sort(tbl210, function(a1583, a2176)
            return (a1583.lifespan or 0) < (a2176.lifespan or 0)
          end)
          return tbl210[1].id
        end
        if v703 == "smallest" then
          table.sort(tbl210, function(a1584, a2177)
            return (a1584.playing or 0) < (a2177.playing or 0)
          end)
          return tbl210[1].id
        end
        if v703 == "largest" then
          table.sort(tbl210, function(a1585, a2178)
            return (a1585.playing or 0) > (a2178.playing or 0)
          end)
          return tbl210[1].id
        end
        return tbl210[math.random(1, #tbl210)].id
      end
      local flag32 = false
      local v684
      local flag33 = false
      local v685
      local v686
      local fn404 = function()
        if not v685 then
          local ok95, result95 = pcall(function()
            return v680.TeleportInitFailed:Connect(function(a1586, a2179, a359)
              flag32 = true
              v684 = a359
            end)
          end)
          v685 = ok95 and result95 or nil
        end
        if v686 then
          return
        end
        pcall(function()
          v686 = LocalPlayer14.OnTeleport:Connect(function(a1587)
            if a1587 == Enum.TeleportState.Failed then
              flag32 = true
              v684 = v684 or "the teleport failed"
            else
              flag33 = true
            end
          end)
        end)
      end
      local fn405 = function(a1588)
        fn404()
        flag32 = false
        v684 = nil
        flag33 = false
        local res159 = fn400("JoinPublicServer")
        if not res159 then
          return false, "JoinPublicServer remote missing"
        end
        local JobId = game.JobId
        res159:FireServer(a1588)
        local num186 = 0
        local v708 = num176
        while num186 < v708 do
          if flag32 then
            return false, v684
          end
          if game.JobId ~= JobId then
            return true
          end
          if flag33 then
            v708 = num177
          end
          task.wait(0.1)
          num186 += 0.1
        end
        if flag33 then
          return false, v684 or "the teleport started but never landed"
        end
        return false, v684 or "the server did not act on the join"
      end
      local flag34 = false
      local v687 = getgenv and getgenv()
      if v687 and rawget(v687, "SENTINEL_RESUMED_FROM_HOP") == true then
        flag34 = true
        v687.SENTINEL_RESUMED_FROM_HOP = nil
      end
      tbl208.resumedFromHop = function()
        return flag34
      end
      tbl208.claimResume = function(a1589)
        if flag34 then
          return true
        end
        for k176, v709 in type(a1589) == "table" and a1589 or {} do
          qResult2.remove(v709)
        end
        return false
      end
      -- Rejoin always reloads the current Blade 23 build from the user's GitHub.
      local fn406 = function()
        return [=[
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(1)
local url = "https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/lite/loader.lua"
local ok, code = pcall(function() return game:HttpGet(url .. "?resume=" .. tostring(os.time()) .. tostring(math.random(100000,999999)), true) end)
if not ok or type(code) ~= "string" or code == "" then
  return warn("[blade 23] Retomada: nao foi possivel baixar o loader do GitHub: " .. tostring(code))
end
local fn, err = loadstring(code)
if not fn then return warn("[blade 23] Retomada: " .. tostring(err)) end
getgenv().SENTINEL_RESUMED_FROM_HOP = true
local ran, rerr = pcall(fn)
if not ran then getgenv().SENTINEL_RESUMED_FROM_HOP = nil; warn("[blade 23] Retomada: " .. tostring(rerr)) end
]=]
      end
      tbl208.shouldResume = function()
        return qResult2.get("botstarted") == "true"
          or qResult2.get("dayfarming") == "true"
          or qResult2.get("progression_active") == "true"
          or qResult2.get("rotbot_active") == "true"
          or qResult2.get("khei_run") == "true"
          or qResult2.get("castlerock_active") == "true"
          or qResult2.get("execute_on_serverhop") == "true"
      end
      local flag35 = false
      local v688
      tbl208.resumeQueueFunction = function()
        for _,candidate in {queueteleport,queue_on_teleport,queueonteleport,
          syn and syn.queue_on_teleport,fluxus and fluxus.queue_on_teleport} do
          if type(candidate)=="function" then return candidate end
        end
      end
      tbl208.queueResume = function(force)
        if tbl208.beforeResume then
          local ok,saved,why=pcall(tbl208.beforeResume)
          if not ok or saved==false then return false,"configuracao nao salva: "..tostring(ok and why or saved) end
        end
        if not force and tbl208.resumeQueuedJob==game.JobId then return true end
        local queue=tbl208.resumeQueueFunction()
        if not queue then return false,"executor sem queue_on_teleport" end
        local code=fn406()
        if not code then return false,"loader de retomada indisponivel" end
        local clear=clearteleportqueue or clear_teleport_queue or clearqueueonteleport
        if type(clear)=="function" then pcall(clear) end
        local ok,result=pcall(queue,code)
        if not ok or result==false then
          tbl208.resumeQueuedJob=nil
          return false,tostring(result)
        end
        tbl208.resumeQueuedJob=game.JobId
        return true
      end
      local setupResume = function()
        if flag35 then return true end
        if not tbl208.resumeQueueFunction() then return false end
        local ok,connection=pcall(function()
          return LocalPlayer14.OnTeleport:Connect(function(state)
            if state==Enum.TeleportState.Failed then tbl208.resumeQueuedJob=nil;return end
            if tbl208.shouldResume() then tbl208.queueResume() end
          end)
        end)
        if not ok or not connection then return false end
        v688=connection;flag35=true
        return true
      end
      tbl208.setupResume = setupResume
      tbl208.teardown = function()
        if v688 then
          pcall(function()
            v688:Disconnect()
          end)
          v688 = nil
        end
        for k177, v712 in { v685, v686 } do
          pcall(function()
            v712:Disconnect()
          end)
        end
        v685 = nil
        v686 = nil
        flag35 = false
        tbl208.resumeQueuedJob=nil
      end
      tbl208.canResume = function()
        return tbl208.resumeQueueFunction()~=nil
      end
      local num179 = 10
      local num180 = 12
      tbl208.hop = function(a1590)
        local v713 = a1590 or {}
        setupResume()
        if v713.reason then
          local str37 = "[sentinel] serverhop: " .. tostring(v713.reason)
          print(str37)
          kResult4.log("serverhop", str37)
        end
        local tbl211 = {}
        task.spawn(function()
          local pickServerResult2, v722, v723 = tbl208.pickServer(v713)
          tbl211.jobId = pickServerResult2
          tbl211.why = v722
          tbl211.wasVisited = v723
          tbl211.done = true
        end)
        if v713.waitDanger ~= false then
          local num187 = os.clock() + (tonumber(v713.dangerTimeout) or num179)
          local Character20 = LocalPlayer14.Character
          while true do
            if not (Character20 and v681:HasTag(Character20, "Danger") and os.clock() < num187) then
              break
            end
            task.wait(0.1)
            Character20 = LocalPlayer14.Character
          end
        end
        local flag36 = false
        if v713.block then
          pcall(function()
            flag36 = tbl208.blockCurrentPlayers()
          end)
        end
        if qResult2.get("botstarted") == "true" then
          qResult2.set("serverhop_count", (tonumber(qResult2.get("serverhop_count")) or 0) + 1)
        end
        tbl208.markVisited(game.JobId)
        if flag36 then
          if pcall(function()
            v680:Teleport(num173)
          end) then
            return true, nil
          end
        end
        if v713.returnToMenu ~= false and not vResult4.startMenu() then
          local res161 = fn400("ReturnToMenu")
          if res161 then
            if v713.menuWait ~= false then
              vResult4.waitMenuReady(num172, true)
            end
            if vResult4.safeToMenu() then
              pcall(function()
                res161:InvokeServer()
              end)
              task.wait(0.5)
            end
          end
        end
        local ok96 = true
        task.spawn(function()
          while ok96 do
            if vResult4.safeToMenu() then
              local res163 = fn400("ReturnToMenu")
              if res163 then
                pcall(function()
                  res163:InvokeServer()
                end)
              end
            end
            task.wait(2)
          end
        end)
        local v714 = v713.placeId or game.PlaceId
        local avoid = v713.avoid
        local flag37 = false
        local str38 = "no joinable server"
        for i38 = 1, num180 do
          local v715 = v713
          if flag37 then
            local strategy = v713.strategy
            if strategy == "oldest" or strategy == "newest" then
              strategy = "random"
            end
            v715 = {
              placeId = v713.placeId,
              minPlayers = v713.minPlayers,
              maxPlayers = v713.maxPlayers,
              strategy = strategy,
              avoid = avoid,
              ignoreVisited = v713.ignoreVisited,
            }
          end
          local v716
          local v717
          local v718
          if i38 == 1 then
            local num188 = os.clock() + num178
            while true do
              if not (not tbl211.done and os.clock() < num188) then
                break
              end
              task.wait(0.05)
            end
            local jobId = tbl211.jobId
            local why = tbl211.why
            local wasVisited = tbl211.wasVisited
            v716 = jobId
            v717 = why
            v718 = wasVisited
          end
          if not (v716 or v717) then
            local pickServerResult, v719, v720 = tbl208.pickServer(v715)
            v716 = pickServerResult
            v717 = v719
            v718 = v720
          end
          if v716 then
            tbl208.markVisited(v716)
            if v713.onPick then
              pcall(v713.onPick, v716)
            end
            local res162, v721 = fn405(v716)
            if res162 then
              ok96 = false
              return true, v716
            end
            str38 = tostring(v721 or "teleport rejected")
            if v713.ignoreVisited then
              avoid = table.clone(avoid or {})
              avoid[v716] = true
            end
            local formatResult3 = string.format(
              "[sentinel] serverhop%s: attempt %d/%d rejected (%s)",
              v713.reason and " (" .. tostring(v713.reason) .. ")" or "",
              i38,
              num180,
              str38
            )
            print(formatResult3)
            kResult4.log("serverhop", formatResult3)
            flag37 = true
            task.wait(0.5)
          else
            str38 = v717 or "no joinable server"
            local formatResult4 = string.format("[sentinel] serverhop: attempt %d/%d found nothing - %s", i38, num180, str38)
            print(formatResult4)
            kResult4.log("serverhop", formatResult4)
            if v718 and v718 > 0 then
              tbl208.clearVisited(v714)
              kResult4.log("serverhop", "cleared the visited history, every listed server was in it")
            end
            task.wait(2)
          end
        end
        ok96 = false
        return false, nil, str38
      end
      return tbl208
    end
    tbl44.D = function()
      local D = tbl44.cache.D
      if not D then
        D = { c = fn68() }
        tbl44.cache.D = D
      end
      return D.c
    end
    local fn69 = function()
      local BResult = tbl44.B()
      local sResult4 = tbl44.s()
      local DResult = tbl44.D()
      local aResult18 = tbl44.a()
      local eResult4 = tbl44.e()
      local dResult11 = tbl44.d()
      local iResult4 = tbl44.i()
      local getResult17, v724, v725, v726, v727, v728, v729, v730 = aResult18:Get(
        "Players",
        "Workspace",
        "RunService",
        "ReplicatedStorage",
        "CollectionService",
        "TweenService",
        "HttpService",
        "UserInputService"
      )
      local LocalPlayer15 = getResult17.LocalPlayer
      local num189 = 3
      local num190 = 1.5
      local num191 = 0.25
      local num192 = 0.1
      local tbl212 = { add = "Water", concoct = "Ladle", empty = "Bucket", settle = 0.5 }
      local tbl213 = { add = "Material", concoct = "Hammer", empty = "Trash" }
      local num193 = 1500
      local num194 = 1.2
      local num195 = 3
      local num196 = 3
      local num197 = 10
      local num198 = 0.15
      local v731 = game.PlaceId == 3541987450 or game.PlaceId == 14341521240
      local tbl219 = {
        Armis = { { 40, 60 }, { 70, 80 } },
        Trickstus = { { 30, 70 }, { 30, 50 } },
        Scrupus = { { 30, 100 }, { 30, 100 } },
        Celeritas = { { 70, 90 }, { 70, 80 } },
        Ignis = { { 80, 95 }, { 53, 57 } },
        Gelidus = { { 80, 95 }, { 85, 100 } },
        Viribus = { { 23, 35 }, { 60, 70 } },
        ["Sagitta Sol"] = { { 50, 65 }, { 40, 60 } },
        Tenebris = { { 90, 100 }, { 40, 60 } },
        Nocere = { { 70, 85 }, { 70, 85 } },
        Hystericus = { { 75, 90 }, { 15, 35 } },
        Shrieker = { { 30, 50 }, { 30, 50 } },
        Verdien = { { 75, 100 }, { 75, 85 } },
        Contrarium = { { 80, 95 }, { 70, 90 } },
        Floresco = { { 90, 100 }, { 80, 95 } },
        Perflora = { { 70, 90 }, { 30, 50 } },
        ["Manus Dei"] = { { 90, 95 }, { 50, 60 } },
        ["Fons Vitae"] = { { 75, 100 }, { 75, 100 } },
        Trahere = { { 75, 85 }, { 75, 85 } },
        Furantur = { { 60, 80 }, { 60, 80 } },
        Inferi = { { 10, 30 }, { 10, 30 } },
        Howler = { { 60, 80 }, { 60, 80 } },
        Secare = { { 90, 95 }, { 90, 95 } },
        Ligans = { { 63, 80 }, { 63, 80 } },
        Reditus = { { 50, 100 }, { 50, 100 } },
        Fimbulvetr = { { 86, 90 }, { 70, 80 } },
        Gate = { { 75, 83 }, { 75, 83 } },
        Snarvindur = { { 60, 75 }, { 20, 30 } },
        Hoppa = { { 40, 60 }, { 50, 60 } },
        Percutiens = { { 60, 70 }, { 70, 80 } },
        Dominus = { { 50, 100 }, { 50, 100 } },
        Custos = { { 45, 65 }, { 45, 65 } },
        Claritum = { { 90, 100 }, { 90, 100 } },
        Globus = { { 70, 100 }, { 70, 100 } },
        Intermissum = { { 70, 100 }, { 70, 100 } },
        Sraunus = { { 1, 50 }, { 1, 50 } },
        Nosferatus = { { 95, 100 }, { 95, 100 } },
        Gourdus = { { 80, 90 }, { 80, 90 } },
        Telorum = { { 80, 90 }, { 75, 85 } },
        Velo = { { 0, 100 }, { 50, 60 } },
      }
      local fn408 = function()
        local ok97, result96 = pcall(function()
          return game:GetService("Stats"):WaitForChild("PerformanceStats"):WaitForChild("Ping"):GetValue()
        end)
        return ok97 and result96 or 0
      end
      local fn409 = function(a1591)
        if a1591 then
          local num199 = 0.025 + fn408() / 1000
          return num199 > 0.35 and 0.35 or num199
        end
        local num200 = math.random(25, 350) / 1000
        local num201 = math.random() * 0.05
        if math.random() < 0.2 then
          num200 += math.random() * 0.1
        end
        local num202 = num200 + num201
        if num202 < 0.025 then
          num202 = 0.025
        end
        if num202 > 0.35 then
          num202 = 0.35
        end
        return num202
      end
      local vector34 = Vector3.new(0, -60, 0)
      local fn410 = function(a1592, a2180)
        local ok98, result97 = pcall(function()
          return a1592:Connect(a2180)
        end)
        return ok98 and result97 or nil
      end
      return function(a1593)
        local Library8 = a1593.Library
        local Toggles7 = Library8.Toggles
        local Options7 = Library8.Options
        local Automation = a1593.Tabs.Automation
        local fireclickdetector_ = fireclickdetector
        local firetouchinterest_ = firetouchinterest
        local firesignal_2 = firesignal
        local replicatesignal_3 = replicatesignal
        local hookfunction_ = hookfunction
        local tbl220 = { false }
        local newResult57 = dResult11.new()
        a1593.Maid:Give(newResult57)
        a1593.Maid:Give(function()
          tbl220[1] = true
        end)
        a1593.State.Serverhop = DResult
        a1593.State.CpuThrottle = BResult
        a1593.State.spellCost = tbl219
        a1593.Maid:Give(function()
          BResult.stop()
        end)
        local fn411 = function(a1594)
          Library8:Notify({ Title = "sentinel.bz", Description = a1594 })
        end
        local blade23Tabbox = a1593.Tabs.Blade23:AddLeftTabbox()
        a1593.State.progressionTab = blade23Tabbox:AddTab("Blade / Sigil")
        a1593.State.bladeQueueTab=blade23Tabbox:AddTab("Filas")
        a1593.State.rotBotTab = blade23Tabbox:AddTab("Rot")
        if v731 then a1593.State.rotBotTab.Button.Visible=false end
        local tbl221 = {
          Doctor = true,
          Engineer = true,
          ["Miner John"] = true,
          ["Mysterious Stranger"] = true,
          Vinifera = true,
          Gary = true,
          Yeti = true,
          ["Inn Keeper"] = true,
          Fallion = true,
          Kyley = true,
          Innkeeper = true,
          Esterina = true,
        }
        local v734
        local v735
        local tbl222 = {}
        local fn412 = function(a1595)
          if not (Toggles7.AutoDialogue and Toggles7.AutoDialogue.Value) then
            return
          end
          local Character21 = LocalPlayer15.Character
          if not Character21 or not Character21:FindFirstChild("InDialogue") then
            return
          end
          local speaker = a1595.speaker
          local msg = a1595.msg
          local v749 = type(msg) == "string" and msg:find("Obelisk", 1, true) ~= nil
          if not v749 then
            if not speaker or speaker == "" or speaker:match("^%s*$") then
              return
            end
            if speaker == "..." then
              local choices = a1595.choices
              if not (msg and msg:find("drop back to your inn") and choices and choices[1] == "Take me away.") then
                return
              end
            elseif not tbl221[speaker] then
              return
            end
          end
          task.wait(0.1)
          if not v734 then
            return
          end
          if not v749 then
            if not a1595.choices or #a1595.choices == 0 then
              v734:FireServer({ exit = true })
            else
              local v750 = v734
              v750:FireServer({ choice = a1595.choices[1] })
            end
            return
          end
          local v751
          for k180, v752 in a1595.choices or {} do
            if type(v752) == "string" and v752:lower() == "resonate" then
              v751 = v752
              break
            end
          end
          if v751 then
            v734:FireServer({ choice = v751 })
          else
            v734:FireServer({ exit = true })
          end
        end
        local fn413 = function(a1596, a2181)
          local pairsResult2, v753, v754 = pairs(a1596)
          for k181 in pairsResult2, v753, v754 do
            if typeof(k181) == "string" and k181:lower() == a2181 then
              return true
            end
          end
          return false
        end
        local fn414 = function(a1597)
          v734 = a1597
          if v735 then
            v735:Disconnect()
          end
          v735 = fn410(a1597.OnClientEvent, fn412)
        end
        local autoDialogueTeardown = function()
          for k182, v755 in tbl222 do
            pcall(function()
              v755:Disconnect()
            end)
          end
          tbl222 = {}
          if v735 then
            v735:Disconnect()
            v735 = nil
          end
          v734 = nil
        end
        newResult57:Give(autoDialogueTeardown)
        a1593.State.autoDialogueSetup = function()
          if v734 then
            return
          end
          local Requests6 = v726:FindFirstChild("Requests")
          if not Requests6 then
            return
          end
          local Dialogue = Requests6:FindFirstChild("Dialogue")
          if Dialogue and Dialogue:IsA("RemoteEvent") then
            fn414(Dialogue)
            return
          end
          local getChildrenResult27, v756, v757 = Requests6:GetChildren()
          for k183, v758 in getChildrenResult27, v756, v757 do
            if v758:IsA("RemoteEvent") then
              local res165 = fn410(v758.OnClientEvent, function(a1598)
                if typeof(a1598) == "table" and (fn413(a1598, "choices") or fn413(a1598, "speaker")) and not v734 then
                  fn414(v758)
                  fn412(a1598)
                end
              end)
              if res165 then
                table.insert(tbl222, res165)
              end
            end
          end
        end
        a1593.State.autoDialogueTeardown = autoDialogueTeardown
        local tbl223 = {}
        local autoBardClear = function()
          for k184, v759 in tbl223 do
            pcall(function()
              v759:Disconnect()
            end)
          end
          tbl223 = {}
        end
        local fn415 = function()
          return replicatesignal_3 ~= nil or firesignal_2 ~= nil
        end
        local fn416 = function(a1599)
          if replicatesignal_3 then
            pcall(replicatesignal_3, a1599.MouseButton1Down)
          end
          if firesignal_2 then
            pcall(firesignal_2, a1599.MouseButton1Down)
          end
        end
        local fn417 = function(a1600)
          local res166 = fn410(a1600.ChildAdded, function(a1601)
            if not (Toggles7.AutoBard and Toggles7.AutoBard.Value) or not fn415() then
              return
            end
            if a1601:IsA("ImageButton") and a1601.Name == "Button" then
              a1601.Parent.Enabled = true
              task.wait(0.9 + math.random(3, 11) / 100)
              fn416(a1601)
            end
          end)
          if res166 then
            table.insert(tbl223, res166)
          end
        end
        newResult57:Give(autoBardClear)
        a1593.State.autoBardSetup = function()
          autoBardClear()
          if not fn415() then
            fn411("Auto Bard needs replicatesignal or firesignal (unsupported executor)")
            return
          end
          local PlayerGui5 = LocalPlayer15:FindFirstChildOfClass("PlayerGui")
          if not PlayerGui5 then
            return
          end
          local BardGui = PlayerGui5:FindFirstChild("BardGui")
          if BardGui then
            fn417(BardGui)
          end
          local res167 = fn410(PlayerGui5.ChildAdded, function(a1602)
            if a1602.Name == "BardGui" and Toggles7.AutoBard and Toggles7.AutoBard.Value then
              fn417(a1602)
            end
          end)
          if res167 then
            table.insert(tbl223, res167)
          end
        end
        a1593.State.autoBardClear = autoBardClear
        local addRightGroupboxResult18 = Automation:AddRightGroupbox("Mana & Training")
        addRightGroupboxResult18:AddToggle("AutoCharge", { Text = "Auto Mana Charge", Default = false })
        addRightGroupboxResult18:AddSlider(
          "AutoChargeThreshold",
          { Text = "Charge To", Default = 100, Min = 1, Max = 100, Rounding = 0, Suffix = "%" }
        )
        addRightGroupboxResult18:AddToggle(
          "SnapTrain",
          { Text = "Snap Train", Tooltip = "Casts your held spell to train it", Default = false }
        )
        addRightGroupboxResult18:AddToggle("TrainClimb", { Text = "Train Climb", Default = false })
        local v737 = addRightGroupboxResult18
        v737:AddToggle("LoopOrderly", {
          Text = "Loop Gain Orderly",
          Tooltip = iResult4.risky("uses Tespian Elixirs to farm Orderly"),
          Default = false,
        })
        iResult4.mark(a1593, "Risky", "LoopOrderly")
        if not (hookfunction_ or eResult4.keyHandlerEnabled()) then
          addRightGroupboxResult18:AddLabel("Mana engine needs hookfunction or KeyHandler")
        else
          local v738
          local v739
          local v740
          local fn434 = function()
            if not v740 then
              local ok103, result101 = pcall(function()
                return Instance.new("VirtualInputManager")
              end)
              v740 = ok103 and result101 or nil
            end
            return v740
          end
          local flag40 = false
          local fn435 = function(a1621)
            local res175 = fn434()
            if not res175 then
              return false
            end
            return pcall(function()
              res175:SendKeyEvent(a1621, Enum.KeyCode.G, false, game)
            end)
          end
          local fn436 = function()
            if flag40 then
              fn435(false)
              flag40 = false
            end
          end
          local charge = function()
            if not v738 then
              if not flag40 then
                flag40 = fn435(true)
              end
              return
            end
            if v739 == "table" then
              local v787 = v738
              v787:FireServer({ math.random(1, 10), math.random() })
            else
              v738:FireServer(true)
            end
          end
          local decharge = function()
            fn436() -- Release a held G even if the remote became available while charging.
            if not v738 then return end
            if v739 == "table" then
              v738:FireServer()
            else
              v738:FireServer(false)
            end
          end
          local canUse = function()
            local Character24 = LocalPlayer15.Character
            if not Character24 then
              return false
            end
            for k195, v788 in { "Grabbed", "Climbing", "ClimbCoolDown", "ManaStop", "SpellBlocking", "ActiveCast", "Stun" } do
              if Character24:FindFirstChild(v788) then
                return false
              end
            end
            if v727:HasTag(Character24, "Knocked") or v727:HasTag(Character24, "Unconscious") then
              return false
            end
            return true
          end
          local fn437 = function()
            local Character25 = LocalPlayer15.Character
            local v789 = Character25 and Character25:FindFirstChild("CharacterHandler")
            local v790 = v789 and v789:FindFirstChild("Remotes")
            local v791 = v790 and v790:FindFirstChild("LeftClick")
            if v791 then
              pcall(function()
                local v792 = v791
                v792:FireServer({ math.random(1, 10), tonumber("0." .. math.random(1000000000000000, 9000000000000000)) })
              end)
            end
          end
          local num203 = 0
          local fn438 = function(a1622, a2190)
            task.wait(a1622 + num203 / 1000 * (a2190 or 1))
          end
          local fn439 = function(a1623, a2191)
            task.wait(a1623 + math.min(num203, 150) / 2000 * (a2191 or 1))
          end
          local chargeUntil = function(a1624, a2192)
            if a1593.State.bladeManaOwner and not a2192 then return false end
            local Character26 = LocalPlayer15.Character
            if not Character26 or Character26:FindFirstChildWhichIsA("ForceField") or not canUse() then
              return
            end
            local Mana4 = Character26:FindFirstChild("Mana")
            if not Mana4 then
              return
            end
            if Character26:FindFirstChild("Charge") or flag40 then
              decharge()
              if not (Toggles7.SnapTrain and Toggles7.SnapTrain.Value) then
                fn438(0.2, 1)
              end
            end
            local tickResult4 = tick()
            local Value5 = Mana4.Value
            while true do
              if not (not tbl220[1] and Mana4.Value < math.clamp(a1624, 0, 98) and (not a2192 or a2192()) and (a2192 or not a1593.State.bladeManaOwner)) then
                break
              end
              if Mana4.Value > Value5 then
                local tickResult5 = tick()
                local Value6 = Mana4.Value
                tickResult4 = tickResult5
                Value5 = Value6
              elseif tick() - tickResult4 > 4 then
                break
              end
              charge()
              if Toggles7.SnapTrain and Toggles7.SnapTrain.Value then
                fn438(0.03, 0.5)
              else
                fn438(0.1, 1.2)
              end
            end
            local reached=Mana4.Value>=math.clamp(a1624,0,98)
            if Character26:FindFirstChild("Charge") or flag40 then
              decharge()
              if not (Toggles7.SnapTrain and Toggles7.SnapTrain.Value) then
                fn438(0.3, 1)
              end
            end
            return reached -- Preserve success before release delay and passive mana decay.
          end
          a1593.State.mana = {
            chargeUntil = chargeUntil,
            charge = charge,
            decharge = decharge,
            canUse = canUse,
            available = function()
              return v738 ~= nil or fn434() ~= nil
            end,
            usingKeyPress = function()
              return v738 == nil
            end,
          }
          a1593.Maid:Give(fn436)
          a1593.State.fireServerObservers = a1593.State.fireServerObservers or {}
          table.insert(a1593.State.fireServerObservers, function(a1625, ...)
            if v738 then
              return
            end
            local Character27 = LocalPlayer15.Character
            local v793 = Character27 and Character27:FindFirstChild("CharacterHandler")
            local v794 = v793 and v793:FindFirstChild("Remotes")
            if not (v794 and a1625.Parent == v794) then
              return
            end
            local tbl239 = { ... }
            local Name3 = a1625.Name
            if Name3 == "SetManaChargeState" then
              v738 = a1625
              v739 = "bool"
            elseif
              Name3:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
              and #tbl239 == 1
              and typeof(tbl239[1]) == "boolean"
            then
              v738 = a1625
              v739 = "bool"
            elseif Name3:sub(1, 4) == "M0ai" and #tbl239 == 1 and typeof(tbl239[1]) == "table" then
              local item34 = tbl239[1]
              local num212 = 0
              local pairsResult3, v795, v796 = pairs(item34)
              for k196 in pairsResult3, v795, v796 do
                num212 += 1
              end
              local item35 = item34[1]
              local item36 = item34[2]
              if num212 == 2 and typeof(item35) == "number" and typeof(item36) == "number" and item36 % 1 ~= 0 then
                v738 = a1625
                v739 = "table"
              end
            end
          end)
          a1593.State.getRemote = a1593.State.getRemote or eResult4.getRemote
          local fn440 = function(a1626)
            v738 = nil
            fn436()
            if getgenv and getgenv().SentinelNoMana then
              return
            end
            if a1626:WaitForChild("Humanoid", 5) == nil then
              return
            end
            local CharacterHandler2 = a1626:WaitForChild("CharacterHandler", 5)
            if not CharacterHandler2 then
              return
            end
            if CharacterHandler2:WaitForChild("Remotes", 5) == nil then
              return
            end
            local ForceField = a1626:FindFirstChildOfClass("ForceField")
            if ForceField then
              while true do
                if not (not tbl220[1] and ForceField and ForceField:IsDescendantOf(game)) then
                  break
                end
                task.wait(0.5)
              end
            end
            task.wait(0.3)
            local v797
            if eResult4.keyHandlerEnabled() then
              pcall(function()
                v797 = eResult4.getRemote("SetManaChargeState") or eResult4.getRemote("Charge")
              end)
            end
            if v797 then
              v738 = v797
              v739 = tostring(v797.Name):sub(1, 4) == "M0ai" and "table" or "bool"
              pcall(function()
                a1593.State.dialogueRemote = eResult4.getRemote("PostDialogue")
                  or eResult4.getRemote("SendDialogue")
                  or a1593.State.dialogueRemote
              end)
              return
            end
            if fn435(true) then
              task.wait(0.15)
              fn435(false)
              task.wait(0.2)
            end
            if not v738 then
              print("[sentinel] mana: no charge remote resolved, holding G instead")
            end
          end
          task.spawn(function()
            while not tbl220[1] do
              num203 = math.clamp(num203 * 0.3 + fn408() * 0.7, 0, 300)
              task.wait(0.25)
            end
          end)
          local v741
          local fn441 = function(a1627)
            pcall(task.cancel, v741)
            v741 = task.spawn(function()
              local Mana5 = a1627:WaitForChild("Mana", 30)
              if not Mana5 then
                return
              end
              local v798
              while not tbl220[1] do
                if Toggles7.SnapTrain and Toggles7.SnapTrain.Value then
                  task.wait(0.01)
                else
                  task.wait(fn409(true))
                end
                if not LocalPlayer15.Character or LocalPlayer15.Character ~= a1627 then
                  break
                end
                local Character28 = LocalPlayer15.Character
                if a1593.State.bladeManaOwner then continue end
                local Value7 = Mana5.Value
                if Toggles7.SnapTrain and Toggles7.SnapTrain.Value then
                  if Toggles7.AutoCharge and Toggles7.AutoCharge.Value then
                    Toggles7.AutoCharge:SetValue(false)
                  end
                  local Tool6 = Character28:FindFirstChildOfClass("Tool")
                  if Tool6 and Tool6:FindFirstChild("Spell") and not v798 then
                    v798 = Tool6
                  end
                  if v798 and tbl219[v798.Name] then
                    local item37 = tbl219[v798.Name][1]
                    local item38 = item37[1]
                    local item39 = item37[2]
                    local num213 = (item38 + item39) / 2
                    local minResult2 = math.min(3, math.floor((item39 - item38) / 3))
                    if minResult2 < 1 then
                      minResult2 = 0
                    end
                    if Value7 < num213 - 1 then
                      chargeUntil(num213)
                    end
                    if Value7 >= item38 + minResult2 and Value7 <= item39 - minResult2 and not v727:HasTag(Character28, "Casting") then
                      local Backpack13 = LocalPlayer15:FindFirstChildOfClass("Backpack")
                      if Character28:FindFirstChildOfClass("Tool") ~= v798 and v798.Parent == Backpack13 then
                        Character28.Humanoid:EquipTool(v798)
                        fn439(0.01)
                      end
                      fn437()
                      local num214 = 0
                      repeat
                        task.wait(0.005)
                        num214 += 1
                        local hasTagResult = v727:HasTag(Character28, "Casting")
                        if hasTagResult then
                          continue
                        end
                        hasTagResult = num214 > 20
                      until hasTagResult
                      if v727:HasTag(Character28, "Casting") then
                        Character28.Humanoid:UnequipTools()
                        local num215 = 0
                        repeat
                          task.wait(0.01)
                          num215 += 1
                          local cond13 = not v727:HasTag(Character28, "Casting")
                          if cond13 then
                            continue
                          end
                          cond13 = num215 > 100
                        until cond13
                        task.wait(fn409(true))
                        if v798.Parent == LocalPlayer15:FindFirstChildOfClass("Backpack") then
                          Character28.Humanoid:EquipTool(v798)
                        end
                      end
                    end
                  end
                else
                  v798 = nil
                end
                if
                  Toggles7.AutoCharge
                  and Toggles7.AutoCharge.Value
                  and v738
                  and Value7 <= Options7.AutoChargeThreshold.Value
                  and not v727:HasTag(Character28, "Casting")
                then
                  if Toggles7.TrainClimb and Toggles7.TrainClimb.Value then
                    Toggles7.TrainClimb:SetValue(false)
                  end
                  chargeUntil(Options7.AutoChargeThreshold.Value)
                end
                if Toggles7.TrainClimb and Toggles7.TrainClimb.Value then
                  if Toggles7.AutoCharge and Toggles7.AutoCharge.Value then
                    Toggles7.AutoCharge:SetValue(false)
                  end
                  chargeUntil(100)
                  local res176 = fn434()
                  repeat
                    if res176 then
                      res176:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                      fn439(0.05)
                      res176:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
                      fn439(0.05)
                    else
                      task.wait(0.1)
                    end
                    local v799 = a1593.State.bladeManaOwner or Mana5.Value == 0 or not (Toggles7.TrainClimb and Toggles7.TrainClimb.Value)
                    if v799 then
                      continue
                    end
                    v799 = tbl220[1]
                  until v799
                end
              end
            end)
          end
          if LocalPlayer15.Character then
            task.spawn(function()
              fn440(LocalPlayer15.Character)
            end)
            fn441(LocalPlayer15.Character)
          end
          newResult57:Give(LocalPlayer15.CharacterAdded:Connect(function(a1628)
            task.spawn(function()
              fn440(a1628)
            end)
            fn441(a1628)
          end))
          task.spawn(function()
            while not tbl220[1] do
              task.wait(0.6)
              local Character29 = LocalPlayer15.Character
              local Backpack14 = LocalPlayer15:FindFirstChildOfClass("Backpack")
              if
                Backpack14
                and Character29
                and not v727:HasTag(Character29, "Danger")
                and Toggles7.LoopOrderly
                and Toggles7.LoopOrderly.Value
              then
                local findFirstChildResult5 = Backpack14:FindFirstChild("Tespian Elixir")
                if findFirstChildResult5 then
                  Character29.Humanoid:EquipTool(findFirstChildResult5)
                  task.wait(0.1)
                  local findFirstChildResult6 = Character29:FindFirstChild("Tespian Elixir")
                  local v800 = findFirstChildResult6 and findFirstChildResult6:FindFirstChild("RemoteEvent")
                  if v800 then
                    local v801 = v800
                    v801:FireServer(Character29.HumanoidRootPart.CFrame, "Part", "Self")
                    task.wait(1.5)
                    sResult4.kill()
                    repeat
                      task.wait(0.5)
                      local v802 = LocalPlayer15.Character and LocalPlayer15.Character:FindFirstChild("Immortal")
                      if v802 then
                        continue
                      end
                      v802 = tbl220[1]
                    until v802
                  end
                end
              end
            end
          end)
        end
        local addLeftGroupboxResult12 = Automation:AddLeftGroupbox("Auto Pickup")
        local v742
        local v743
        local tbl224 = { {} }
        local fn442 = function(a1629)
          return a1629.Name == "Part" and a1629:FindFirstChild("ID") ~= nil
        end
        local fn443 = function()
          if v742 then
            return
          end
          tbl224[1] = {}
          local getChildrenResult30, v803, v804 = v724:GetChildren()
          for k197, v805 in getChildrenResult30, v803, v804 do
            if fn442(v805) then
              table.insert(tbl224[1], v805)
            end
          end
          v743 = fn410(v724.ChildAdded, function(a1630)
            if fn442(a1630) then
              table.insert(tbl224[1], a1630)
            end
          end)
          v742 = fn410(v725.Heartbeat, __NATIVE[92](LocalPlayer15, a1593, fireclickdetector_, { 0 }, tbl224))
        end
        local fn444 = function()
          if v742 then
            v742:Disconnect()
            v742 = nil
          end
          if v743 then
            v743:Disconnect()
            v743 = nil
          end
          tbl224[1] = {}
        end
        newResult57:Give(fn444)
        addLeftGroupboxResult12
          :AddToggle("AutoTrinket", {
            Text = "Auto Trinket",
            Default = false,
            Callback = function(a1631)
              if a1631 then
                fn443()
              else
                fn444()
              end
            end,
          })
          :AddKeyPicker("AutoTrinketKeybind", { Default = "None", Mode = "Toggle", Text = "Auto Trinket", SyncToggleState = true })
        local v744
        local tbl226 = { nil }
        local tbl227 = { 0 }
        local tbl228 = {}
        local tbl229 = { 0 }
        local tbl230 = { nil }
        local tbl231 = {}
        local tbl232 = { 0 }
        local newResult59 = dResult11.new()
        newResult57:Give(newResult59)
        local fn449 = function(a1635)
          local ClickDetector2 = a1635:FindFirstChild("ClickDetector")
          if not ClickDetector2 or a1593.State.identifyIngredient and a1593.State.identifyIngredient(a1635) == "Blood Thorn" then
            return
          end
          tbl231[a1635] = ClickDetector2
        end
        local res164 = __NATIVE[94](tbl228, function(a1636)
          newResult59:DoCleaning()
          table.clear(tbl231)
          if not a1636 then
            return
          end
          local getChildrenResult32, v823, v824 = a1636:GetChildren()
          for k200, v825 in getChildrenResult32, v823, v824 do
            fn449(v825)
          end
          newResult59:Give(a1636.ChildAdded:Connect(fn449))
          newResult59:Give(a1636.ChildRemoved:Connect(function(a1637)
            tbl231[a1637] = nil
          end))
        end, a1593, tbl231, tbl226, tbl227)
        local fn450 = function()
          if v744 then
            return
          end
          tbl226[1] = nil
          tbl227[1] = 0
          tbl230[1] = nil
          tbl232[1] = 0
          table.clear(tbl228)
          v744 = fn410(v725.Heartbeat, __NATIVE[95](num198, LocalPlayer15, tbl228, fireclickdetector_, tbl232, tbl229, tbl230, res164))
        end
        local fn451 = function()
          if v744 then
            pcall(function()
              v744:Disconnect()
            end)
            v744 = nil
          end
          newResult59:DoCleaning()
          table.clear(tbl231)
          table.clear(tbl228)
          tbl226[1] = nil
        end
        newResult57:Give(fn451)
        addLeftGroupboxResult12
          :AddToggle("AutoIngredient", {
            Text = "Auto Ingredient",
            Default = false,
            Callback = function(a1638)
              if a1638 then
                fn450()
              else
                fn451()
              end
            end,
          })
          :AddKeyPicker("AutoIngredientKeybind", { Default = "None", Mode = "Toggle", Text = "Auto Ingredient", SyncToggleState = true })
        local newResult60 = dResult11.new()
        newResult57:Give(newResult60)
        local tbl233 = {}
        local fn452 = function(a1639)
          local ClickDetector3 = a1639:FindFirstChild("ClickDetector")
          if not (ClickDetector3 and a1639:FindFirstChild("Prop")) then
            return
          end
          local v826 = a1639:IsA("Model") and a1639:FindFirstChildWhichIsA("BasePart") or a1639
          if v826:IsA("BasePart") then
            tbl233[a1639] = { part = v826, pickup = ClickDetector3, range = ClickDetector3.MaxActivationDistance - 2 }
          end
        end
        local num204 = 0
        local fn453 = function()
          num204 += 1
          newResult60:DoCleaning()
          table.clear(tbl233)
        end
        newResult57:Give(fn453)
        local fn454 = function()
          fn453()
          local v827 = num204
          newResult60:Give(task.spawn(function()
            local ok105, result102 = pcall(function()
              return v724:FindFirstChild("Thrown") or v724:WaitForChild("Thrown", 30)
            end)
            if not ok105 or not result102 or v827 ~= num204 then
              return
            end
            local getChildrenResult33, v828, v829 = result102:GetChildren()
            for k201, v830 in getChildrenResult33, v828, v829 do
              fn452(v830)
            end
            for k202, v831 in
              {
                fn410(result102.ChildAdded, function(a1640)
                  task.delay(1, function()
                    if a1640.Parent == result102 then
                      fn452(a1640)
                    end
                  end)
                end),
                fn410(result102.ChildRemoved, function(a1641)
                  tbl233[a1641] = nil
                end),
                fn410(v725.Heartbeat, __NATIVE[96](LocalPlayer15, { 0 }, fireclickdetector_, tbl220, tbl233)),
              }
            do
              if v831 then
                newResult60:Give(v831)
              end
            end
          end))
        end
        addLeftGroupboxResult12
          :AddToggle("AutoWeapon", {
            Text = "Auto Weapon",
            Default = false,
            Callback = function(a1642)
              if a1642 then
                fn454()
              else
                fn453()
              end
            end,
          })
          :AddKeyPicker("AutoWeaponKeybind", { Default = "None", Mode = "Toggle", Text = "Auto Weapon", SyncToggleState = true })
        local fn455 = function(a1643)
          for k203, v832 in { LocalPlayer15:FindFirstChildOfClass("Backpack"), LocalPlayer15.Character } do
            if v832 then
              local getChildrenResult34, v833, v834 = v832:GetChildren()
              for k204, v835 in getChildrenResult34, v833, v834 do
                if v835:IsA("Tool") then
                  for k205, v836 in a1643 do
                    if v835.Name == v836 then
                      return v835
                    end
                  end
                end
              end
            end
          end
          return nil
        end
        local fn456 = function(a1644)
          local Character32 = LocalPlayer15.Character
          if not (Character32 and a1644) then
            return
          end
          local Humanoid9 = Character32:FindFirstChildOfClass("Humanoid")
          if not Humanoid9 then
            return
          end
          Humanoid9:UnequipTools()
          local Backpack15 = LocalPlayer15:FindFirstChildOfClass("Backpack")
          if Backpack15 and a1644.Parent == Backpack15 then
            Humanoid9:EquipTool(a1644)
          end
          if not Character32:FindFirstChild(a1644.Name) then
            a1644.AncestryChanged:Wait()
          end
          task.wait(0.025)
          local findFirstChildResult7 = Character32:FindFirstChild(a1644.Name)
          if findFirstChildResult7 then
            findFirstChildResult7:Activate()
          end
        end
        addLeftGroupboxResult12:AddToggle("AutoResurrection", { Text = "Auto Resurrection", Default = false })
        local ok100, result98 = pcall(function()
          return v727:GetInstanceAddedSignal("Unconscious")
        end)
        if ok100 and result98 then
          newResult57:Give(fn410(result98, function(a1645)
            if a1645 == LocalPlayer15.Character and Toggles7.AutoResurrection and Toggles7.AutoResurrection.Value then
              task.spawn(function()
                task.wait(fn409())
                local res177 = fn455({ "Resurrection", "Dragon Awakening", "Dragon Resurrection" })
                if res177 then
                  fn456(res177)
                end
              end)
            end
          end))
        end
        addLeftGroupboxResult12:AddDivider()
        local v745
        local v746
        local v747
        local tbl234 = { {} }
        local fn457 = function(a1646)
          return a1646:IsA("BasePart") and a1646.Name:find("Bag") ~= nil
        end
        local fn458 = function()
          if v745 then
            return
          end
          local Thrown4 = v724:FindFirstChild("Thrown")
          if not Thrown4 then
            return
          end
          tbl234[1] = {}
          local getChildrenResult35, v837, v838 = Thrown4:GetChildren()
          for k206, v839 in getChildrenResult35, v837, v838 do
            if fn457(v839) then
              table.insert(tbl234[1], v839)
            end
          end
          v746 = fn410(Thrown4.ChildAdded, function(a1647)
            if fn457(a1647) then
              table.insert(tbl234[1], a1647)
            end
          end)
          v747 = fn410(Thrown4.ChildRemoved, function(a1648)
            for i46 = #tbl234[1], 1, -1 do
              if tbl234[1][i46] == a1648 then
                table.remove(tbl234[1], i46)
                break
              end
            end
          end)
          v745 = fn410(v725.Heartbeat, __NATIVE[97](LocalPlayer15, Options7, v724, tbl234, firetouchinterest_))
        end
        local fn459 = function()
          for k207, v840 in { v745, v746, v747 } do
            pcall(function()
              v840:Disconnect()
            end)
          end
          v745 = nil
          v746 = nil
          v747 = nil
          tbl234[1] = {}
        end
        newResult57:Give(fn459)
        addLeftGroupboxResult12
          :AddToggle("AutoBag", {
            Text = "Auto Bag",
            Default = false,
            Callback = function(a1649)
              if not firetouchinterest_ and a1649 then
                fn411("Auto Bag needs firetouchinterest (unsupported executor)")
              end
              if a1649 then
                fn458()
              else
                fn459()
              end
            end,
          })
          :AddKeyPicker("AutoBagKeybind", { Default = "None", Mode = "Toggle", Text = "Auto Bag", SyncToggleState = true })
        addLeftGroupboxResult12:AddSlider("BagRange", { Text = "Bag Range", Default = 80, Min = 1, Max = 80, Rounding = 0 })
      end
    end
    tbl44.E = function()
      local E = tbl44.cache.E
      if not E then
        E = { c = fn69() }
        tbl44.cache.E = E
      end
      return E.c
    end
    local fn70 = function()
      local sResult5 = tbl44.s()
      local eResult5 = tbl44.e()
      local getResult18, v843, v844, v845 = tbl44.a():Get("Players", "RunService", "ReplicatedStorage", "Stats")
      local LocalPlayer16 = getResult18.LocalPlayer
      local fn463 = function()
        local ok107, result104 = pcall(function()
          return v845.PerformanceStats.Ping:GetValue()
        end)
        if ok107 and type(result104) == "number" and result104 > 0 then
          return math.clamp(result104 / 1000, 0.05, 1.5)
        end
        return 0.15
      end
      local fireclickdetector_2 = fireclickdetector
      local tbl241 = {}
      local v846
      tbl241.inDialogue = function()
        local Character33 = LocalPlayer16.Character
        return Character33 ~= nil and Character33:FindFirstChild("InDialogue") ~= nil
      end
      -- Nonblocking exit used by ROT while it also waits for jail/carry replication.
      tbl241.requestClose = function(remote)
        remote=remote or v846 or eResult5.getRemote("PostDialogue") or eResult5.getRemote("SendDialogue")
        if not remote then return false end
        local now=tick()
        if tbl241.lastCloseRemote==remote and now-(tbl241.lastCloseAt or -math.huge)<0.5 then return false end
        tbl241.lastCloseRemote=remote;tbl241.lastCloseAt=now
        return pcall(function() remote:FireServer({exit=true}) end)
      end
      tbl241.close = function(a1651)
        if not tbl241.inDialogue() then
          return true
        end
        local v847 = v846 or (eResult5.getRemote("PostDialogue") or eResult5.getRemote("SendDialogue"))
        if not v847 then
          return false
        end
        local num220 = tick() + (a1651 or 4)
        while true do
          if not (tbl241.inDialogue() and tick() < num220) then
            break
          end
          pcall(function()
            v847:FireServer({ exit = true })
          end)
          local num221 = 0
          while true do
            if not (tbl241.inDialogue() and num221 < 0.8 and tick() < num220) then
              break
            end
            task.wait(0.1)
            num221 += 0.1
          end
        end
        return not tbl241.inDialogue()
      end
      tbl241.listen = function()
        local tbl242 = { conns = {} }
        local Requests7 = v844:FindFirstChild("Requests")
        if Requests7 then
          local getChildrenResult36, v848, v849 = Requests7:GetChildren()
          for k210, v850 in getChildrenResult36, v848, v849 do
            if v850:IsA("RemoteEvent") then
              table.insert(
                tbl242.conns,
                v850.OnClientEvent:Connect(function(a1652)
                  if tbl242.msg == nil and type(a1652) == "table" and (a1652.choices ~= nil or a1652.speaker ~= nil) then
                    local speaker2 = a1652.speaker
                    local msg2 = a1652.msg
                    tbl242.speaker = speaker2
                    tbl242.msg = msg2
                  end
                end)
              )
            end
          end
        end
        tbl242.wait = function(a1653, a2193)
          local num222 = tick() + (a2193 or 6)
          while true do
            if not (a1653.msg == nil and tick() < num222) then
              break
            end
            task.wait(0.1)
          end
          return a1653.msg, a1653.speaker
        end
        tbl242.stop = function(a1654)
          for k211, v851 in a1654.conns do
            pcall(function()
              v851:Disconnect()
            end)
          end
          table.clear(a1654.conns)
        end
        return tbl242
      end
      local fn464 = function()
        return true
      end
      tbl241.run = function(a1655, a2194, a365)
        local v852 = a365 or {}
        local v853 = v852.shouldRun or fn464
        local res178 = fn463()
        local v854 = v852.timeout or 15 + res178 * 10
        local v855 = v852.openWait or 0.35
        local v856 = v852.minHold or 0
        local v857 = v852.answerDelay or 0.25
        local v858 = v852.silence or 8 + res178 * 4
        local v859 = v852.reopenAfter or 3 + res178 * 4
        local v860 = v852.maxReplays or 4
        local log = v852.log
        local fn465 = function(a1656, ...)
          if not log then
            return
          end
          local ok109, result106 = pcall(string.format, a1656, ...)
          log("  dlg " .. (ok109 and result106 or tostring(a1656)))
        end
        local fn466 = function(a1657, a2195)
          if not a1657 then
            return not tbl241.inDialogue()
          end
          local num229 = 0
          while true do
            if not (v853() and tbl241.inDialogue() and num229 < 4) then
              break
            end
            fn465("out exit (%s, attempt %d)", a2195, num229 + 1)
            pcall(function()
              a1657:FireServer({ exit = true })
            end)
            local num230 = 0
            while true do
              if not (v853() and tbl241.inDialogue() and num230 < 0.8) then
                break
              end
              task.wait(0.1)
              num230 += 0.1
            end
            num229 += 1
          end
          return not tbl241.inDialogue()
        end
        local fn467 = function(a1658)
          if type(a1658) ~= "table" or #a1658 == 0 then
            return "none"
          end
          local tbl245 = {}
          for k214, v870 in a1658 do
            table.insert(tbl245, string.format("%q", tostring(v870)))
          end
          return table.concat(tbl245, " | ")
        end
        if not v853() then
          return false
        end
        local rootResult8 = sResult5.root()
        local v861 = rootResult8 and CFrame.new(rootResult8.Position)
        local v862 = v861 and v852.holdPosition ~= false and v843.RenderStepped:Connect(__NATIVE[99](sResult5, v861))
        local tickResult6 = tick()
        local Requests8 = v844:FindFirstChild("Requests")
        local v863 = a1655 and (a1655:IsA("ClickDetector") and a1655 or a1655:FindFirstChildWhichIsA("ClickDetector", true))
        local num223 = 1
        local num224 = 0
        local flag47 = false
        local flag48 = false
        local num225 = 0
        local num226 = 0
        local v864
        local num227 = 0
        local flag49 = false
        local num228 = 0
        local flag50 = false
        local tbl243 = {}
        local tbl244 = {}
        local flag51 = false
        local flag52 = false
        if not (Requests8 and fireclickdetector_2 and v863) then
          if log then
            log(
              string.format(
                "dialogue %s: requests=%s fcd=%s cd=%s",
                tostring(a1655 and a1655.Name),
                tostring(Requests8 ~= nil),
                tostring(fireclickdetector_2 ~= nil),
                tostring(v863 ~= nil)
              )
            )
          end
        else
          local v865
          local fn468 = function(a1659, a2196)
            if flag51 then
              return
            end
            if not v853() then
              return
            end
            if type(a2196) ~= "table" or a2196.choices == nil and a2196.speaker == nil then
              return
            end
            num228 = tick()
            if not flag49 then
              fn465("(before arm, ignored) speaker=%s msg=%q", tostring(a2196.speaker), tostring(a2196.msg))
              return
            end
            num224 = tick()
            flag47 = true
            num226 += 1
            v865 = a1659
            v846 = a1659
            fn465(
              "in  #%d speaker=%s msg=%q choices=[%s] endchoice=%s",
              num226,
              tostring(a2196.speaker),
              tostring(a2196.msg),
              fn467(a2196.choices),
              tostring(a2196.endchoice)
            )
            if v852.successWhen and not flag52 and type(a2196.msg) == "string" then
              for k215, v871 in v852.successWhen do
                if string.find(a2196.msg, v871, 1, true) then
                  flag52 = true
                  fn465("success marker seen: %q", v871)
                  break
                end
              end
            end
            if v852.stopOnSuccess and flag52 then
              flag50=true
              tbl241.requestClose(a1659)
              return -- No sleeping response task survives this successful transaction.
            end
            if v852.doneWhen and num226 == 1 and type(a2196.msg) == "string" then
              local gsubResult3 = a2196.msg:gsub("^%s+", ""):gsub("%s+$", "")
              local cond14 = not (type(a2196.choices) == "table" and #a2196.choices > 0)
              for k216, v872 in v852.doneWhen do
                local v873
                if type(v872) == "table" then
                  v873 = v872.exact ~= nil and gsubResult3 == v872.exact and (cond14 or not v872.terminal)
                else
                  v873 = string.find(a2196.msg, v872, 1, true) ~= nil
                end
                if v873 then
                  flag48 = true
                  fn465("out exit (opened on its done line)")
                  task.wait(v857)
                  if flag51 or not v853() then return end
                  pcall(function()
                    a1659:FireServer({ exit = true })
                  end)
                  return
                end
              end
            end
            local v874 = type(a2196.choices) == "table" and a2196.choices or nil
            if v874 and #v874 > 0 then
              v864 = table.concat(v874, " / ")
            end
            if v852.answerAll then
              if not (v874 and #v874 > 0) then
                flag50 = true
                fn465("out exit (all: nothing left to pick)")
                task.wait(v857)
                if flag51 or not v853() then return end
                pcall(function()
                  a1659:FireServer({ exit = true })
                end)
                return
              end
              task.wait(v857)
              if flag51 or not v853() then return end
              num227 += 1
              fn465("out choice %q (all)", tostring(v874[1]))
              if pcall(function()
                a1659:FireServer({ choice = v874[1] })
              end) then
                table.insert(tbl243, v874[1])
              else
                fn465("out FAILED to send %q", tostring(v874[1]))
              end
              num224 = tick()
              num227 -= 1
              return
            end
            if not v874 or #v874 == 0 then
              flag50 = true
              fn465("out exit (choiceless line, the talk stays open until we close it)")
              task.wait(v857)
              if flag51 or not v853() then return end
              pcall(function()
                a1659:FireServer({ exit = true })
              end)
              return
            end
            local item41 = a2194[num223]
            if type(item41) == "table" and item41.index == 0 then
              num223 += 1
              flag50 = true
              fn465("out exit ([0] asked for it)")
              task.wait(v857)
              if flag51 or not v853() then return end
              pcall(function()
                a1659:FireServer({ exit = true })
              end)
              return
            end
            if type(v874) ~= "table" then
              return
            end
            local fn469 = function(a1660, a2197)
              -- Reserve a guarded answer before yielding, so duplicate dialogue events cannot pay twice.
              if v852.allowAnswer and not v852.allowAnswer(a1660) then return end
              if v852.beforeAnswer then
                pcall(v852.beforeAnswer, a1660, a2196.msg)
              end
              task.wait(v857)
              if flag51 or not v853() then return end
              num223 = a2197 + 1
              num227 += 1
              fn465("out choice %q (want #%d)", a1660, a2197)
              if pcall(function()
                a1659:FireServer({ choice = a1660 })
              end) then
                table.insert(tbl243, a1660)
              else
                fn465("out FAILED to send %q", a1660)
              end
              num224 = tick()
              num227 -= 1
            end
            local fn470 = function(a1661, a2198)
              for i48 = a1661, a2198 do
                local item42 = a2194[i48]
                if type(item42) == "table" and item42.any and type(v874[1]) == "string" then
                  fn469(v874[1], i48)
                  return true
                end
                if type(item42) == "table" and item42.index then
                  local item43 = v874[item42.index]
                  if type(item43) == "string" then
                    fn469(item43, i48)
                    return true
                  end
                end
                for k217, v875 in type(item42) == "table" and item42 or { item42 } do
                  for k218, v876 in v874 do
                    if type(v876) == "string" and type(v875) == "string" and v876:lower() == v875:lower() then
                      fn469(v876, i48)
                      return true
                    end
                  end
                end
              end
              return false
            end
            if fn470(num223, #a2194) then
              return
            end
            if num223 > 1 and num225 < v860 and fn470(1, num223 - 1) then
              num225 += 1
              fn465("he repeated an earlier line, answering it again (%d/%d)", num225, v860)
              return
            end
            flag50 = true
            fn465("out exit (nothing we planned is on offer)")
            task.wait(v857)
            if flag51 or not v853() then return end
            pcall(function()
              a1659:FireServer({ exit = true })
            end)
          end
          local getChildrenResult37, v866, v867 = Requests8:GetChildren()
          for k212, v868 in getChildrenResult37, v866, v867 do
            if v868:IsA("RemoteEvent") then
              table.insert(
                tbl244,
                v868.OnClientEvent:Connect(function(a1662)
                  fn468(v868, a1662)
                end)
              )
            end
          end
          local ok108, result105 = pcall(function()
            task.wait(v855)
            if tbl241.inDialogue() then
              fn465("a dialogue is still open from before, a click would do nothing until it closes")
              fn466(v846, "clearing a talk left open")
            end
            local num231 = 0
            while true do
              if not (v853() and tbl241.inDialogue() and num231 < 3) then
                break
              end
              task.wait(0.1)
              num231 += 0.1
            end
            local num232 = 0
            local quietPeriod=v852.quietPeriod or 0.4
            while true do
              if not (v853() and num232 < quietPeriod) then
                break
              end
              num232 = tick() - num228 < 0.25 and 0 or num232 + 0.1
              task.wait(0.1)
            end
            num223 = 1
            num226 = 0
            flag48 = false
            v864 = nil
            num227 = 0
            flag50 = false
            num225 = 0
            table.clear(tbl243)
            flag52 = false
            flag47 = false
            flag49 = true
            local flag53 = false
            local num233 = 0
            local num234 = 2 + res178 * 4
            while true do
              if not (v853() and not flag53 and num233 < 5) then
                break
              end
              fireclickdetector_2(v863)
              local num235 = 0
              while true do
                if not (v853() and not tbl241.inDialogue() and not flag47 and num235 < num234) then
                  break
                end
                task.wait(0.1)
                num235 += 0.1
              end
              flag53 = tbl241.inDialogue() or flag47
              num233 += 1
            end
            fn465(
              "opened=%s after %d click%s (tag=%s, sawEvent=%s, %dms ping)",
              tostring(flag53),
              num233,
              num233 == 1 and "" or "s",
              tostring(tbl241.inDialogue()),
              tostring(flag47),
              math.floor(res178 * 1000)
            )
            if flag53 then
              local tickResult7 = tick()
              local v877 = tickResult7
              local str39, str40, v878, tostring_, num236, v879, v880, v881, num237
              while true do
                -- Opt-in for transactional callers: the positive server line ends the talk promptly.
                -- The caller still verifies its own authoritative delivery evidence afterwards.
                if v852.stopOnSuccess and flag52 then return end
                if not (v853() and not flag48 and tick() - tickResult7 < v854) then
                  str39 = tostring(flag48)
                  str40 = tostring(flag50)
                  v878 = num226
                  tostring_ = tostring
                  fn465(
                    "closing: sent %d/%d, doneEarly=%s, closing=%s, events=%d, tag=%s",
                    #tbl243,
                    #a2194,
                    str39,
                    str40,
                    v878,
                    tostring_(tbl241.inDialogue())
                  )
                  num236 = 0
                  while true do
                    v879 = v853()
                      and tbl241.inDialogue()
                      and num236 < 1
                      and tbl241.inDialogue()
                      and num236 < 1
                      and tbl241.inDialogue()
                      and num236 < 1
                    if not v879 then
                      break
                    end
                    task.wait(0.1)
                    num236 += 0.1
                  end
                  if tbl241.inDialogue() then
                    v880 = fn466
                    v881 = v865 or v846 or v846 or v846
                    v880(v881, "talk did not close on its own")
                  end
                  return
                end
                task.wait(0.1)
                if flag50 and not tbl241.inDialogue() then
                  str39 = tostring(flag48)
                  str40 = tostring(flag50)
                  v878 = num226
                  tostring_ = tostring
                  fn465(
                    "closing: sent %d/%d, doneEarly=%s, closing=%s, events=%d, tag=%s",
                    #tbl243,
                    #a2194,
                    str39,
                    str40,
                    v878,
                    tostring_(tbl241.inDialogue())
                  )
                  num236 = 0
                  while true do
                    v879 = v853()
                      and tbl241.inDialogue()
                      and num236 < 1
                      and tbl241.inDialogue()
                      and num236 < 1
                      and tbl241.inDialogue()
                      and num236 < 1
                    if not v879 then
                      break
                    end
                    task.wait(0.1)
                    num236 += 0.1
                  end
                  if tbl241.inDialogue() then
                    v880 = fn466
                    v881 = v865 or v846 or v846 or v846
                    v880(v881, "talk did not close on its own")
                  end
                  return
                end
                num237 = tick() - num224
                if not flag50 and num226 > 0 and num227 == 0 and num237 > v859 and tick() - v877 > v859 then
                  fn465("no reply for %.1fs, clicking again", num237)
                  fireclickdetector_2(v863)
                  v877 = tick()
                  continue
                end
                if num226 > 0 and num227 == 0 and num237 > v858 then
                  break
                end
              end
              fn465("silent %.1fs after line #%d, ending", num237, num226)
              str39 = tostring(flag48)
              str40 = tostring(flag50)
              v878 = num226
              tostring_ = tostring
              fn465(
                "closing: sent %d/%d, doneEarly=%s, closing=%s, events=%d, tag=%s",
                #tbl243,
                #a2194,
                str39,
                str40,
                v878,
                tostring_(tbl241.inDialogue())
              )
              num236 = 0
              while true do
                v879 = v853()
                  and tbl241.inDialogue()
                  and num236 < 1
                  and tbl241.inDialogue()
                  and num236 < 1
                  and tbl241.inDialogue()
                  and num236 < 1
                if not v879 then
                  break
                end
                task.wait(0.1)
                num236 += 0.1
              end
              if tbl241.inDialogue() then
                v880 = fn466
                v881 = v865 or v846 or v846 or v846
                v880(v881, "talk did not close on its own")
              end
            elseif log then
              log(
                string.format(
                  "dialogue %s: clicked %dx, InDialogue never appeared - name/dialogue wrong",
                  tostring(a1655 and a1655.Name),
                  num233
                )
              )
            end
          end)
          if not ok108 and log then
            log("dialogue error: " .. tostring(result105))
          end
        end
        flag51 = true
        for k213, v869 in tbl244 do
          pcall(function()
            v869:Disconnect()
          end)
        end
        table.clear(tbl244)
        while true do
          if not (v853() and tick() - tickResult6 < v856) then
            break
          end
          task.wait(0.1)
        end
        if v862 then
          v862:Disconnect()
        end
        return #a2194 > 0 and num223 > #a2194 or v852.answerAll == true and (flag50 or #tbl243 > 0) or flag48,
          flag48,
          v864,
          flag50,
          tbl243,
          flag52
      end
      return tbl241
    end
    tbl44.F = function()
      local F = tbl44.cache.F
      if not F then
        F = { c = fn70() }
        tbl44.cache.F = F
      end
      return F.c
    end
    local fn71 = function()
      local getResult19, v882, v883 = tbl44.a():Get("Players", "Workspace", "ReplicatedStorage")
      local LocalPlayer17 = getResult19.LocalPlayer
      local tbl246 = {
        RANGE = {
          glassmask = 300,
          projectile = 300,
          tenebris = 200,
          celeritas = 567,
          pebbleHold = 700,
          pebbleThrow = 1000,
          caster = 1000,
          shrieker = 150,
          opal = 60,
          opalClear = 85,
          opalHold = 1000,
          iceDragon = 330,
          roster = 700,
          sidestep = 40,
        },
        LABELS = {
          glassmask = "Glass Mask",
          opalshard = "Opal Shard",
          armis = "Armis",
          daggerthrow = "Dagger Throw",
          tenebris = "Glass Mask",
          celeritas = "Celeritas",
          pebble = "Pebble",
        },
        DETECTIONS = { "Armis", "Celeritas", "Dagger Throw", "Glass Mask", "Opal Shard" },
        OPAL_HOLD_PING = 160,
        labelAllowed = function(a1663, a2199)
          local v884 = a1663 and a1663.BotDetections and a1663.BotDetections.Value
          if not (v884 and a2199) then
            return true
          end
          return v884[a2199] == true
        end,
      }
      tbl246.allowed = function(a1664, a2200)
        return tbl246.labelAllowed(a1664, tbl246.LABELS[a2200])
      end
      local num238 = 0.1
      local num239 = 0.25
      local num240 = 15
      local tbl247 = { "Manus Dei", "Fimbulvetr" }
      local fn471 = function(a1665)
        for k219, v885 in tbl247 do
          if a1665:find(v885, 1, true) then
            return true
          end
        end
        return false
      end
      local fromRGBResult22 = Color3.fromRGB(25, 227, 73)
      local fromRGBResult23 = Color3.fromRGB(49, 214, 20)
      local tbl248 = {
        { keyword = "Armis", kind = "armis", label = "Armis", range = "projectile" },
        { keyword = "DaggerThrow", kind = "daggerthrow", label = "Dagger Throw", range = "projectile" },
        { keyword = "TenebrisBlueFast", kind = "tenebris", label = "Snap Fimbulvetr", range = "tenebris" },
      }
      local fn472 = function(a1666, a2201)
        return typeof(a1666) == "Color3"
          and math.abs(a1666.R - a2201.R) < 0.02
          and math.abs(a1666.G - a2201.G) < 0.02
          and math.abs(a1666.B - a2201.B) < 0.02
      end
      tbl246.root = function()
        local Character34 = LocalPlayer17.Character
        return Character34 and Character34:FindFirstChild("HumanoidRootPart")
      end
      local fn473 = function(a1667)
        return Vector3.new(a1667.X, 0, a1667.Z)
      end
      tbl246.sidestep = __NATIVE[100](tbl246, fn473)
      tbl246.flatDistance = function(a1668, a2202)
        return fn473(a1668 - a2202).Magnitude
      end
      tbl246.outOfColumn = function(a1669, a2203)
        local rootResult9 = tbl246.root()
        if not rootResult9 then
          return nil
        end
        local res179 = fn473(rootResult9.Position - a1669)
        if res179.Magnitude < 0.1 then
          res179 = Vector3.new(1, 0, 0)
        end
        return Vector3.new(a1669.X, rootResult9.Position.Y, a1669.Z) + res179.Unit * (a2203 or tbl246.RANGE.opalClear)
      end
      tbl246.roster = function(a1670, a2204, a366, a423)
        if not a1670 or not a2204 or a2204 <= 0 then
          return {}
        end
        local tbl249 = {}
        local getPlayersResult16, v886, v887 = getResult19:GetPlayers()
        for k220, v888 in getPlayersResult16, v886, v887 do
          if v888 ~= LocalPlayer17 and not (a423 and a423(v888)) then
            local v889 = v888.Character and v888.Character:FindFirstChild("HumanoidRootPart")
            local v890 = v889 and (v889.Position - a1670).Magnitude
            if v890 and v890 <= a2204 then
              local v891 = a366 and a366(v888)
              if not v891 or v891 == "" or v891 == "nil" or v891 == "Unknown" then
                v891 = v888.DisplayName or v888.Name
              end
              table.insert(tbl249, { name = v891, user = v888.Name, dist = v890 })
            end
          end
        end
        if #tbl249 == 0 then
          return {}
        end
        table.sort(tbl249, function(a1671, a2205)
          return a1671.dist < a2205.dist
        end)
        local tbl250 = { string.format("**Within %.0f studs** (%d)", a2204, #tbl249) }
        for k221, v892 in tbl249 do
          table.insert(tbl250, string.format("- **%s** `%s` - %.0f studs", v892.name, v892.user, v892.dist))
        end
        return tbl250
      end
      tbl246.liveCharacter = function(a1672)
        if not a1672 then
          return nil
        end
        if a1672.Character then
          return a1672.Character
        end
        local Live9 = v882:FindFirstChild("Live")
        return Live9 and Live9:FindFirstChild(a1672.Name)
      end
      tbl246.isIllusionist = function(a1673)
        local liveCharacterResult = tbl246.liveCharacter(a1673)
        local v893 = liveCharacterResult and liveCharacterResult:FindFirstChild("HumanoidRootPart")
        local v894 = v893 and v893:FindFirstChild("MindMage")
        return v894 ~= nil and v894:IsA("ParticleEmitter") and v894.Enabled
      end
      tbl246.MOB_PATTERNS = { "Shrieker", "Snake", "Serpent", "Ice Dragon" }
      tbl246.detectMob = __NATIVE[101](getResult19, tbl246, v882)
      tbl246.detectShrieker = __NATIVE[102](tbl246, v882)
      tbl246.watch = function(a1674)
        local v895 = a1674.active or function()
          return true
        end
        local report = a1674.report
        local isFriend = a1674.isFriend
        local allow = a1674.allow
        local tbl251 = {}
        local fn474 = function(a1675, a2206)
          table.insert(tbl251, a1675:Connect(a2206))
        end
        local num244 = 0
        local v896
        local fn475 = function(a1676)
          if v896 then
            pcall(function()
              v896:Disconnect()
            end)
            v896 = nil
          end
          if not a1676 then
            return
          end
          local getChildrenResult38, v899, v900 = a1676:GetChildren()
          for k222, v901 in getChildrenResult38, v899, v900 do
            if fn471(v901.Name) then
              num244 = tick()
            end
          end
          v896 = a1676.ChildAdded:Connect(function(a1677)
            if fn471(a1677.Name) then
              num244 = tick()
            end
          end)
        end
        fn475(LocalPlayer17.Character)
        fn474(LocalPlayer17.CharacterAdded, fn475)
        local fn476 = function()
          return tick() - num244 < num240
        end
        local fn477 = function(a1678, a2207, a367, a424, a59, a66)
          if not v895() then
            return
          end
          if allow and not allow(a1678) then
            return
          end
          report({ kind = a1678, label = a2207, position = a367, range = a424, caster = a59, dodge = a66 })
        end
        local fn478 = function(a1679)
          if not (a1679:IsA("BasePart") and v895()) or fn476() then
            return
          end
          task.wait(num238)
          if fn476() then
            return
          end
          local rootResult10 = tbl246.root()
          if not (rootResult10 and v895()) then
            return
          end
          if (a1679.Position - rootResult10.Position).Magnitude > tbl246.RANGE.glassmask then
            return
          end
          fn477("glassmask", "Fimbulvetr/Manus Dei detected", a1679.Position, tbl246.RANGE.roster)
        end
        local v897
        local fn479 = function(a1680)
          if not (a1680:IsA("BasePart") and a1680.Anchored and v895()) then
            return
          end
          if not (a1680:FindFirstChildOfClass("Beam") or a1680:WaitForChild("Beam", num239)) then
            return
          end
          local rootResult11 = tbl246.root()
          if not (rootResult11 and a1680.Parent and v895()) then
            return
          end
          local flatDistanceResult = tbl246.flatDistance(a1680.Position, rootResult11.Position)
          if flatDistanceResult > tbl246.RANGE.opal then
            return
          end
          local v902
          local v903
          local v904 = v897 and v897.Parent and v897
          for k223, v905 in v904 and getResult19:GetPlayers() or {} do
            local v906 = v905 ~= LocalPlayer17 and v905.Character and v905.Character:FindFirstChild("HumanoidRootPart")
            local v907 = v906 and (v906.Position - v904.Position).Magnitude
            if v907 and v907 <= 40 and (not v903 or v907 < v903) then
              v902 = v905.Name
              v903 = v907
            end
          end
          fn477(
            "opalshard",
            string.format("Opal Shard strike marked %.0f studs from the bot%s", flatDistanceResult, v902 and " by " .. v902 or ""),
            a1680.Position,
            tbl246.RANGE.roster,
            v902,
            tbl246.outOfColumn(a1680.Position)
          )
        end
        local fn480 = function(a1681)
          local Name4 = a1681.Name
          local v908
          for k224, v909 in tbl248 do
            if Name4:find(v909.keyword, 1, true) then
              v908 = v909
              break
            end
          end
          if not v908 or Name4:find(LocalPlayer17.Name, 1, true) then
            return
          end
          local item44 = tbl246.RANGE[v908.range]
          task.spawn(function()
            while true do
              if not (a1681.Parent and v895()) then
                break
              end
              local v910 = a1681:IsA("BasePart") and a1681 or a1681:FindFirstChildWhichIsA("BasePart")
              local rootResult12 = tbl246.root()
              local v911 = v910 and rootResult12 and (v910.Position - rootResult12.Position).Magnitude
              if v911 and v911 <= item44 then
                local matchResult5 = Name4:match("^(.-)" .. v908.keyword)
                if matchResult5 == "" then
                  matchResult5 = nil
                end
                fn477(
                  v908.kind,
                  matchResult5 and string.format("%s from %s (%.0f studs)", v908.label, matchResult5, v911)
                    or string.format("%s (%.0f studs)", v908.label, v911),
                  v910.Position,
                  item44,
                  matchResult5
                )
                return
              end
              task.wait()
            end
          end)
        end
        local fn481 = function(a1682, a2208)
          if not v895() or a1682 ~= "General_Snap" or type(a2208) ~= "table" or a2208.ver ~= "Snap" then
            return
          end
          if not (fn472(a2208.ltColor, fromRGBResult22) and fn472(a2208.ptlColor, fromRGBResult23)) then
            return
          end
          local targRoot = a2208.targRoot
          local v912 = typeof(targRoot) == "Instance" and targRoot.Parent
          local v913 = v912 and getResult19:GetPlayerFromCharacter(v912)
          if not v913 or v913 == LocalPlayer17 or isFriend and isFriend(v913) then
            return
          end
          local rootResult13 = tbl246.root()
          local v914 = rootResult13 and (targRoot.Position - rootResult13.Position).Magnitude
          if not v914 or v914 > tbl246.RANGE.celeritas then
            return
          end
          fn477(
            "celeritas",
            string.format("%s snapped Celeritas (%.0f studs)", v913.Name, v914),
            targRoot.Position,
            tbl246.RANGE.celeritas,
            v913
          )
        end
        local fn482 = function(a1683)
          if not v895() then
            return
          end
          if a1683.Name == "GlassMask" then
            task.spawn(fn478, a1683)
          elseif a1683.Name == "Handle" then
            v897 = a1683
          elseif a1683.Name == "Point" then
            task.spawn(fn479, a1683)
          else
            fn480(a1683)
          end
        end
        local flag54 = false
        local fn483 = function(a1684)
          if flag54 then
            return
          end
          flag54 = true
          fn474(a1684.ChildAdded, fn482)
        end
        fn474(v882.ChildAdded, function(a1685)
          if a1685.Name == "Thrown" then
            fn483(a1685)
            return
          end
          fn482(a1685)
        end)
        local Thrown5 = v882:FindFirstChild("Thrown")
        if Thrown5 then
          fn483(Thrown5)
        end
        local Requests9 = v883:FindFirstChild("Requests")
        local v898 = Requests9 and Requests9:FindFirstChild("ClientVFX")
        if v898 then
          fn474(v898.OnClientEvent, fn481)
        end
        return function()
          for k225, v915 in tbl251 do
            pcall(function()
              v915:Disconnect()
            end)
          end
          table.clear(tbl251)
          if v896 then
            pcall(function()
              v896:Disconnect()
            end)
            v896 = nil
          end
        end,
          v898 ~= nil
      end
      local num241 = 6
      local num242 = 0.05
      local num243 = 0.6
      tbl246.tracksToward = function(a1686, a2209, a368)
        local num245 = 0
        local num246 = 0
        local v916
        for i49 = 1, num241 do
          if not a1686.Parent or a368 and not a368() then
            return false
          end
          local res180 = a2209()
          if not res180 then
            return false
          end
          local Magnitude9 = (a1686.Position - res180).Magnitude
          if v916 then
            num245 += 1
            if Magnitude9 < v916 then
              num246 += 1
            end
          end
          v916 = Magnitude9
          task.wait(num242)
        end
        if num245 == 0 or num246 < num245 then
          return false
        end
        local res181 = a2209()
        if not (res181 and a1686.Parent) then
          return false
        end
        local num247 = res181 - a1686.Position
        local AssemblyLinearVelocity = a1686.AssemblyLinearVelocity
        if AssemblyLinearVelocity.Magnitude < 1 or num247.Magnitude < 1 then
          return true
        end
        return AssemblyLinearVelocity.Unit:Dot(num247.Unit) >= num243
      end
      return tbl246
    end
    tbl44.G = function()
      local G2 = tbl44.cache.G
      if not G2 then
        G2 = { c = fn71() }
        tbl44.cache.G = G2
      end
      return G2.c
    end
    local fn72 = function()
      local sResult6 = tbl44.s()
      local aResult19 = tbl44.a()
      local eResult6 = tbl44.e()
      local uResult3 = tbl44.u()
      local getResult20, v917, v918, v919 = aResult19:Get("Players", "Workspace", "RunService", "CollectionService")
      local LocalPlayer18 = getResult20.LocalPlayer
      local fireclickdetector_3 = fireclickdetector
      local tbl252 = {}
      local fn484 = function()
        return true
      end
      tbl252.nearestModel = function(a1687, a2210, a369)
        if not a1687 then
          return nil
        end
        local v920
        local v921
        local getChildrenResult39, v922, v923 = a1687:GetChildren()
        for k226, v924 in getChildrenResult39, v922, v923 do
          if v924.Name == a2210 then
            local v925 = v924:FindFirstChild("HumanoidRootPart") or v924:IsA("BasePart") and v924 or v924:FindFirstChildWhichIsA("BasePart")
            if v925 then
              local Magnitude10 = (v925.Position - a369).Magnitude
              if not v921 or Magnitude10 < v921 then
                v920 = v924
                v921 = Magnitude10
              end
            end
          end
        end
        return v920, v921
      end
      tbl252.nearestNPC = function(a1688, a2211)
        return tbl252.nearestModel(v917:FindFirstChild("NPCs"), a1688, a2211)
      end
      tbl252.INN_ANCHORS = {
        Renova = { Vector3.new(-2122, 609, -712), 150 },
        Oresfall = { Vector3.new(2964, 317, -25), 175 },
        Santorini = { Vector3.new(1354, 431, 2985), 175 },
        ["Southern Sanctuary"] = { Vector3.new(-1294, 142, 397), 150 },
        ["Central Sanctuary"] = { Vector3.new(1909, 240, -786), 175 },
        ["Castle Sanctuary"] = { Vector3.new(6183, 1344, 109), 175 },
        ["Wayside Inn"] = { Vector3.new(1349, 239, 871), 275 },
        ["Flowerlight Town"] = { Vector3.new(3311, 205, -2523), 250 },
      }
      tbl252.KHEI_INNS = {
        ["Cavern Sanctuary"] = { keeper = "Esterina" },
        ["Frostfall Range"] = { keeper = "Innkeeper", at = Vector3.new(-1826, 984, -482) },
        ["Shallow Mire"] = { keeper = "Innkeeper", at = Vector3.new(-2093, 523, -35) },
        ["Morokh Reservoir"] = { keeper = "Innkeeper", at = Vector3.new(-1692, 506, 1073) },
      }
      local tbl253 = { ["Flowerlight Town"] = "Ria", Scroomville = "Fungkeeper", ["Central Sanctuary"] = "Orodin" }
      local tbl254 = {
        "Renova",
        "Oresfall",
        "Alana",
        "Santorini",
        "Southern Sanctuary",
        "Central Sanctuary",
        "Castle Sanctuary",
        "Wayside Inn",
        "Flowerlight Town",
        "Scroomville",
        "Sleeping Snail",
      }
      local tbl255 = { "Cavern Sanctuary", "Frostfall Range", "Shallow Mire", "Morokh Reservoir" }
      tbl252.innNames = function(a1689)
        return a1689 and tbl255 or tbl254
      end
      local fn485 = function(a1690, a2212)
        return type(a1690) == "string" and type(a2212) == "string" and a1690:lower() == a2212:lower()
      end
      tbl252.canonicalInn = function(a1691)
        if type(a1691) ~= "string" then
          return nil
        end
        local matchResult6 = a1691:match("^%s*(.-)%s*$")
        for k227, v926 in { tbl252.KHEI_INNS, tbl253, tbl252.INN_ANCHORS } do
          local pairsResult4, v927, v928 = pairs(v926 or {})
          for k228 in pairsResult4, v927, v928 do
            if fn485(k228, matchResult6) then
              return k228
            end
          end
        end
        local NPCs = v917:FindFirstChild("NPCs")
        for k229, v929 in NPCs and NPCs:GetChildren() or {} do
          if v929.Name == "Inn Keeper" then
            local Location = v929:FindFirstChild("Location")
            if Location and fn485(Location.Value, matchResult6) then
              return Location.Value
            end
          end
        end
        return matchResult6
      end
      tbl252.innKeeper = function(a1692)
        local NPCs2 = v917:FindFirstChild("NPCs")
        if not NPCs2 then
          return nil
        end
        local v930 = tbl252.canonicalInn(a1692) or a1692
        local item45 = tbl252.KHEI_INNS[v930]
        if item45 then
          if not item45.at then
            return NPCs2:FindFirstChild(item45.keeper)
          end
          local nearestModelResult, v931 = tbl252.nearestModel(NPCs2, item45.keeper, item45.at)
          return v931 and v931 <= 200 and nearestModelResult or nil
        end
        local item46 = tbl253[v930]
        if item46 then
          return NPCs2:FindFirstChild(item46)
        end
        local getChildrenResult40, v932, v933 = NPCs2:GetChildren()
        for k230, v934 in getChildrenResult40, v932, v933 do
          if v934.Name == "Inn Keeper" then
            local Location2 = v934:FindFirstChild("Location")
            if Location2 and fn485(Location2.Value, v930) then
              return v934
            end
          end
        end
        return nil
      end
      local tbl256 = { Ria = "A room, please.", Orodin = "May I reserve a room?", Esterina = "Yes.", Innkeeper = "Yes." }
      tbl252.safeInnPosition = function(character, keeperRoot)
        local root=character and character:FindFirstChild("HumanoidRootPart")
        local hum=character and character:FindFirstChildOfClass("Humanoid")
        if not root or not hum or not keeperRoot then return nil end
        local excluded={character}
        for _,name in {"NPCs","Live"} do
          local folder=v917:FindFirstChild(name)
          if folder then table.insert(excluded,folder) end
        end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances=excluded;params.RespectCanCollide=true
        local overlap=OverlapParams.new()
        overlap.FilterType=Enum.RaycastFilterType.Exclude
        overlap.FilterDescendantsInstances=excluded;overlap.RespectCanCollide=true
        local height=math.max(3,hum.HipHeight+root.Size.Y/2)
        for _,radius in {3.5,5,7} do
          for index=0,7 do
            local angle=index*math.pi/4
            local origin=keeperRoot.Position+Vector3.new(math.cos(angle)*radius,2,math.sin(angle)*radius)
            local hit=v917:Raycast(origin,Vector3.new(0,-14,0),params)
            if hit and hit.Normal.Y>=0.75 and math.abs(hit.Position.Y-keeperRoot.Position.Y)<=6 then
              local supported=true
              for _,offset in {Vector3.new(-1,2,-1),Vector3.new(-1,2,1),Vector3.new(1,2,-1),Vector3.new(1,2,1)} do
                local edge=v917:Raycast(hit.Position+offset,Vector3.new(0,-4,0),params)
                if not edge or edge.Normal.Y<0.75 or math.abs(edge.Position.Y-hit.Position.Y)>0.5 then supported=false;break end
              end
              if supported then
                for _,part in v917:GetPartBoundsInBox(CFrame.new(hit.Position+Vector3.new(0,2.75,0)),Vector3.new(2.4,5,2.4),overlap) do
                  if part.CanCollide then supported=false;break end
                end
              end
              if supported then return hit.Position+Vector3.new(0,height+0.15,0) end
            end
          end
        end
        return nil
      end
      local fn486 = function(a1693)
        if not a1693 then
          return
        end
        -- Release inn noclip without carrying downward momentum into the landing.
        local root=a1693:FindFirstChild("HumanoidRootPart")
        if root then root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end
        local Humanoid10 = a1693:FindFirstChildOfClass("Humanoid")
        if Humanoid10 then
          Humanoid10:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
        end
        local getDescendantsResult12, v935, v936 = a1693:GetDescendants()
        for k231, v937 in getDescendantsResult12, v935, v936 do
          if v937:IsA("BasePart") and v937.Name ~= "HumanoidRootPart" then
            v937.CanCollide = v937.Name == "Head" or v937.Name == "Torso"
          end
        end
      end
      tbl252.waitSettled = function(a1694, a2213)
        if not a1694 then
          return true
        end
        local v938
        local num248 = 0
        local num249 = 0
        while true do
          if not (a2213() and num249 < 12) then
            break
          end
          local rootResult14 = sResult6.root()
          if rootResult14 and sResult6.near(a1694[1], a1694[2]) then
            if v938 and (rootResult14.Position - v938).Magnitude < 3 then
              num248 += 0.3
              if num248 >= 2 then
                return true
              end
            else
              num248 = 0
            end
            v938 = rootResult14.Position
          else
            num248 = 0
            v938 = nil
          end
          task.wait(0.3)
          num249 += 0.3
        end
        return sResult6.near(a1694[1], a1694[2])
      end
      local fn487 = function()
        local Character35 = LocalPlayer18.Character
        local v939 = Character35 and Character35:FindFirstChildOfClass("Humanoid")
        local v940 = Character35 and Character35:FindFirstChild("HumanoidRootPart")
        if v940 and v939 and v939.Health > 0 then
          return Character35, v939, v940
        end
        return nil
      end
      local fn488 = function(a1695, a2214)
        local __ml
        local v941 = a2214 or {}
        local v942 = v941.shouldRun or fn484
        local num250 = 0
        while true do
          if not (v942() and not fn487() and num250 < 25) then
            break
          end
          task.wait(0.3)
          num250 += 0.3
        end
        if not fn487() then
          return false
        end
        if eResult6.getServerValue("Lives") == 0 then
          return false
        end
        local v943 = tbl252.canonicalInn(a1695) or a1695
        local innKeeperResult = tbl252.innKeeper(v943)
        local v944 = innKeeperResult and innKeeperResult:FindFirstChild("HumanoidRootPart")
        if not v944 then
          if v941.log then
            v941.log(v943)
          end
          return false
        end
        local ClickDetector4 = innKeeperResult:FindFirstChildWhichIsA("ClickDetector", true)
        local v945 = eResult6.getRemote("PostDialogue") or eResult6.getRemote("SendDialogue")
        local tbl257 = { tbl256[innKeeperResult.Name] or "Sure.", "Yes.", "Sure." }
        local v946 = tbl252.INN_ANCHORS[v943] or { v944.Position, 250 }
        local CurrentCamera9 = v917.CurrentCamera
        local fn489 = function()
          local PlayerGui6 = LocalPlayer18:FindFirstChildOfClass("PlayerGui")
          local v953 = PlayerGui6 and PlayerGui6:FindFirstChild("DialogueGui")
          local v954 = v953 and v953:FindFirstChild("DialogueFrame")
          return v954 ~= nil and v954.Visible
        end
        local num251 = 0
        while true do
          if not (v942() and LocalPlayer18.Character and v919:HasTag(LocalPlayer18.Character, "Danger") and num251 < 150) then
            break
          end
          task.wait(0.3)
          num251 += 0.3
        end
        if LocalPlayer18.Character and v919:HasTag(LocalPlayer18.Character, "Danger") then
          return false
        end
        for i50 = 1, v941.attempts or 1 do
          if not v942() then
            break
          end
          local num252 = 0
          while true do
            if not (v942() and not fn487() and num252 < 25) then
              break
            end
            task.wait(0.3)
            num252 += 0.3
          end
          local res182, v947, v948 = fn487()
          if not res182 then
            break
          end
          local landing=v941.safeLanding and tbl252.safeInnPosition(res182,v944)
          if v941.safeLanding and not landing then
            if v941.log then v941.log(v943.." (sem chao livre e seguro perto do innkeeper)") end
            return false
          end
          local holdFrame=landing and CFrame.new(landing)
          if v941.protectFall then v941.protectFall() end
          local nativeInnStep=__NATIVE[103](sResult6, LocalPlayer18, v948, v947)
          local connectResult5 = v918.RenderStepped:Connect(function(...)
            if LocalPlayer18.Character~=res182 or not v948.Parent then return end
            nativeInnStep(...)
            if holdFrame then
              v948.CFrame=holdFrame
              v948.AssemblyLinearVelocity=Vector3.zero;v948.AssemblyAngularVelocity=Vector3.zero
              if v941.protectFall then v941.protectFall() end
            end
          end)
          local released=false
          local function releaseInnHold()
            if released then return end
            released=true
            connectResult5:Disconnect()
            if LocalPlayer18.Character==res182 and v948.Parent then
              if holdFrame then v948.CFrame=holdFrame end
              if v941.protectFall then v941.protectFall() end
              fn486(res182)
            end
          end
          v941.releaseInnHold=releaseInnHold
          local flag55 = false
          local flag56 = false
          local num253 = 0
          local v949, Character36, num254, v951, v952
          while true do
            if not (v942() and num253 < 2 and fn487()) then
              if flag56 then
                if v945 then
                  for i51 = 1, 2 do
                    v949 = ClickDetector4 and fireclickdetector_3 and fireclickdetector_3
                    if v949 then
                      pcall(function()
                        fireclickdetector_3(ClickDetector4)
                      end)
                    end
                    for k232, v950 in tbl257 do
                      pcall(function()
                        v945:FireServer({ choice = v950 })
                      end)
                    end
                    task.wait(0.2)
                  end
                end
                if not v942() then releaseInnHold();return false end
                if v941.onBeforeBreak then
                  v941.onBeforeBreak()
                end
                if v941.breakJoints == false then
                  releaseInnHold()
                  return true
                end
                releaseInnHold()
                Character36 = LocalPlayer18.Character
                sResult6.kill()
                num254 = 0
                repeat
                  task.wait(0.1)
                  num254 += 0.1
                  v951 = (
                    LocalPlayer18.Character
                      and LocalPlayer18.Character ~= Character36
                      and LocalPlayer18.Character:FindFirstChild("HumanoidRootPart")
                    or num254 > 12
                  )
                      and LocalPlayer18.Character ~= Character36
                      and LocalPlayer18.Character:FindFirstChild("HumanoidRootPart")
                    or num254 > 12
                  if v951 then
                    continue
                  end
                  v951 = not v942()
                until v951
                v952 = v941.verify == false or tbl252.waitSettled(v946, v942) or tbl252.waitSettled(v946, v942)
                if v952 then
                  return true
                end
              end
              __ml = 1
              break
            end
            local rootResult15 = sResult6.root()
            if rootResult15 and v944.Parent then
              rootResult15.CFrame = holdFrame or (v944.CFrame + Vector3.new(0, 5, 0))
            end
            if CurrentCamera9 then
              CurrentCamera9.CFrame = CFrame.new(CurrentCamera9.CFrame.Position, v944.Position)
            end
            if not flag55 and v945 then
              task.spawn(function()
                for k233, v955 in tbl257 do
                  pcall(function()
                    v945:FireServer({ choice = v955 })
                  end)
                end
                pcall(function()
                  v945.OnClientEvent:Wait()
                end)
                flag55 = true
              end)
            end
            if ClickDetector4 and fireclickdetector_3 then
              pcall(function()
                fireclickdetector_3(ClickDetector4)
              end)
            end
            if fn489() then
              break
            end
            num253 += task.wait()
          end
          if __ml == 1 then
            releaseInnHold()
            __ml = nil
            continue
          end
          flag56 = true
          if flag56 then
            if v945 then
              for i51 = 1, 2 do
                v949 = ClickDetector4 and fireclickdetector_3 and fireclickdetector_3
                if v949 then
                  pcall(function()
                    fireclickdetector_3(ClickDetector4)
                  end)
                end
                for k232, v950 in tbl257 do
                  pcall(function()
                    v945:FireServer({ choice = v950 })
                  end)
                end
                task.wait(0.2)
              end
            end
            if not v942() then releaseInnHold();return false end
            if v941.onBeforeBreak then
              v941.onBeforeBreak()
            end
            if v941.breakJoints == false then
              releaseInnHold()
              return true
            end
            releaseInnHold()
            Character36 = LocalPlayer18.Character
            sResult6.kill()
            num254 = 0
            repeat
              task.wait(0.1)
              num254 += 0.1
              v951 = (
                LocalPlayer18.Character
                  and LocalPlayer18.Character ~= Character36
                  and LocalPlayer18.Character:FindFirstChild("HumanoidRootPart")
                or num254 > 12
              )
                  and LocalPlayer18.Character ~= Character36
                  and LocalPlayer18.Character:FindFirstChild("HumanoidRootPart")
                or num254 > 12
              if v951 then
                continue
              end
              v951 = not v942()
            until v951
            v952 = v941.verify == false or tbl252.waitSettled(v946, v942) or tbl252.waitSettled(v946, v942)
            if v952 then
              return true
            end
          end
        end
        fn486(LocalPlayer18.Character)
        return false
      end
      tbl252.setInn = function(a1696, a2215)
        local liftResult2 = uResult3.lift()
        local options=table.clone(a2215 or {})
        local ok110, result107 = pcall(fn488, a1696, options)
        local cleaned,cleanupError=true,nil
        if options.releaseInnHold then cleaned,cleanupError=pcall(options.releaseInnHold) end
        liftResult2()
        if ok110 and not cleaned then error(cleanupError,0) end
        if not ok110 then
          error(result107, 0)
        end
        return result107
      end
      return tbl252
    end
    tbl44.H = function()
      local H = tbl44.cache.H
      if not H then
        H = { c = fn72() }
        tbl44.cache.H = H
      end
      return H.c
    end
    local fn73 = function()
      local aResult20 = tbl44.a()
      local cResult4 = tbl44.c()
      local getResult21, v956 = aResult20:Get("HttpService", "Players")
      local LocalPlayer19 = v956.LocalPlayer
      local str41 = cResult4.CACHE .. "/bots"
      local num255 = 600
      local tbl258 = {}
      local fn490 = function(a1697)
        return str41 .. "/" .. tostring(a1697) .. ".json"
      end
      tbl258.claim = function(a1698)
        if not (writefile and type(a1698) == "string" and a1698 ~= "") then
          return
        end
        pcall(function()
          cResult4.ensure(str41)
          writefile(
            fn490(LocalPlayer19.UserId),
            getResult21:JSONEncode({ job = a1698, place = game.PlaceId, at = os.time(), name = LocalPlayer19.Name })
          )
        end)
      end
      tbl258.release = function()
        pcall(function()
          if delfile and isfile and isfile(fn490(LocalPlayer19.UserId)) then
            delfile(fn490(LocalPlayer19.UserId))
          end
        end)
      end
      tbl258.others = function()
        local tbl259 = {}
        if not (listfiles and readfile and isfolder) then
          return tbl259
        end
        local ok111, result108 = pcall(function()
          return isfolder(str41) and listfiles(str41) or {}
        end)
        if not ok111 then
          return tbl259
        end
        local timeResult2 = os.time()
        for k234, v957 in result108 do
          local num256 = tonumber(tostring(v957):match("(%d+)%.json$"))
          if num256 and num256 ~= LocalPlayer19.UserId then
            local ok112, result109 = pcall(function()
              return getResult21:JSONDecode(readfile(v957))
            end)
            if ok112 and type(result109) == "table" and type(result109.at) == "number" and timeResult2 - result109.at <= num255 then
              tbl259[num256] = result109
            end
          end
        end
        return tbl259
      end
      tbl258.takenJobs = function()
        local tbl260 = {}
        local othersResult, v958, v959 = tbl258.others()
        for k235, v960 in othersResult, v958, v959 do
          if type(v960.job) == "string" then
            tbl260[v960.job] = true
          end
        end
        return tbl260
      end
      tbl258.twinHere = function()
        local othersResult2 = tbl258.others()
        local getPlayersResult17, v961, v962 = v956:GetPlayers()
        for k236, v963 in getPlayersResult17, v961, v962 do
          if v963 ~= LocalPlayer19 and othersResult2[v963.UserId] and v963.UserId < LocalPlayer19.UserId then
            return v963
          end
        end
        return nil
      end
      return tbl258
    end
    tbl44.I = function()
      local I = tbl44.cache.I
      if not I then
        I = { c = fn73() }
        tbl44.cache.I = I
      end
      return I.c
    end
    local fn74 = function()
      local aResult21 = tbl44.a()
      local kResult5 = tbl44.k()
      local getResult22, v964 = aResult21:Get("Stats", "Players")
      local LocalPlayer20 = v964.LocalPlayer
      local num257 = 0.2
      local num258 = 5
      local num259 = 0.05
      local num260 = 3
      local num261 = 500
      local num262 = 700
      local num263 = 3
      local tbl261 = {
        read = function()
          local ok113, result110 = pcall(function()
            return getResult22.PerformanceStats.Ping:GetValue()
          end)
          if ok113 and type(result110) == "number" and result110 > 0 then
            return result110
          end
          local ok114, result111 = pcall(function()
            return LocalPlayer20:GetNetworkPing()
          end)
          return ok114 and type(result111) == "number" and result111 > 0 and result111 * 2000 or nil
        end,
      }
      tbl261.watch = function(a1699)
        local ok115 = true
        task.spawn(function()
          local v965
          local num264 = 0
          local clockResult5 = os.clock()
          while ok115 do
            task.wait(num257)
            local readResult = tbl261.read()
            if readResult then
              if not v965 then
                v965 = readResult
              elseif
                os.clock() - clockResult5 >= num258
                and readResult >= num262
                and readResult >= v965 * num260
                and readResult - v965 >= num261
              then
                num264 += 1
                if num264 >= num263 and ok115 then
                  num264 = 0
                  kResult5.log("pingwatch", string.format("spike: %.0fms against a %.0fms baseline", readResult, v965))
                  a1699(readResult, v965)
                end
              else
                num264 = 0
                v965 += (readResult - v965) * num259
              end
            end
          end
        end)
        return function()
          ok115 = false
        end
      end
      return tbl261
    end
    tbl44.J = function()
      local J = tbl44.cache.J
      if not J then
        J = { c = fn74() }
        tbl44.cache.J = J
      end
      return J.c
    end
    local fn75 = function()
      local __L2 = {}
      local sResult7 = tbl44.s()
      local DResult2 = tbl44.D()
      local FResult = tbl44.F()
      local qResult3 = tbl44.q()
      local aResult22 = tbl44.a()
      local xResult2 = tbl44.x()
      local eResult7 = tbl44.e()
      local kResult6 = tbl44.k()
      local dResult12 = tbl44.d()
      local GResult = tbl44.G()
      local vResult5 = tbl44.v()
      local HResult = tbl44.H()
      local iResult5 = tbl44.i()
      local IResult = tbl44.I()
      local JResult = tbl44.J()
      local getResult23, v966, v967, v968, v969, v970 =
        aResult22:Get("Players", "Workspace", "RunService", "TweenService", "CollectionService", "ReplicatedStorage")
      local LocalPlayer21 = getResult23.LocalPlayer
      local pebbleHold = GResult.RANGE.pebbleHold
      local pebbleThrow = GResult.RANGE.pebbleThrow
      local num265 = 2.5
      local num266 = 5
      local vector35 = Vector3.new(2000.60046, 143.362045, -2276.92163)
      local num267 = 141.129
      local num268 = 4
      local num269 = 14
      local num270 = 30
      local num271 = 30
      local num272 = 120
      local tbl262 = {
        {
          spot = Vector3.new(6762, 1465, -130),
          entry = Vector3.new(6841, 1465, -130),
          path = {
            Vector3.new(6847, 1416, -161),
            Vector3.new(6818, 1402, -161),
            Vector3.new(6802, 1402, -161),
            Vector3.new(6801, 1402, -102),
            Vector3.new(6818, 1465, -129),
            Vector3.new(6762, 1465, -130),
          },
        },
        {
          spot = Vector3.new(6762, 1465, -192),
          entry = Vector3.new(6836, 1465, -192),
          path = {
            Vector3.new(6847, 1416, -161),
            Vector3.new(6803, 1402, -160),
            Vector3.new(6801, 1402, -221),
            Vector3.new(6808, 1465, -193),
            Vector3.new(6762, 1465, -192),
          },
        },
      }
      local fn491 = function(a1700)
        local num317 = tonumber(a1700.p7side)
        if num317 and tbl262[num317] then
          return tbl262[num317], false
        end
        local randomResult3 = math.random(1, #tbl262)
        a1700.p7side = randomResult3
        return tbl262[randomResult3], true
      end
      local fn492 = function()
        local Character37 = LocalPlayer21.Character
        local v974 = Character37 and Character37:FindFirstChild("ManaAbilities")
        return v974 ~= nil and v974:FindFirstChild("ManaDash") ~= nil
      end
      local num273 = 141
      local fn493 = function()
        local v975 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
        if not v975 then
          return false
        end
        return v975.FloorMaterial == Enum.Material.Air
      end
      local Stats2 = game:GetService("Stats")
      local fn494 = function()
        local ok116, result112 = pcall(function()
          return Stats2.PerformanceStats.Ping:GetValue()
        end)
        if ok116 and result112 then
          return result112
        end
        local ok117, result113 = pcall(function()
          return LocalPlayer21:GetNetworkPing() * 1000
        end)
        return ok117 and result113 or 0
      end
      local num274 = 3541987450
      local num275 = 6
      local num276 = 3
      local num277 = 20
      local num278 = 5
      local num279 = 6
      local num280 = 20
      local num281 = 30
      local num282 = 4
      local num283 = 160
      local num284 = 0.5
      local num285 = 10
      local num286 = 900
      local num287 = 3
      local num288 = 6
      local num289 = 3
      local num290 = 30
      local num291 = 1.1
      local num292 = 0.9
      local tbl263 = {}
      pcall(function()
        tbl263[BrickColor.new("Reddish brown").Number] = true
        tbl263[BrickColor.new("Copper").Number] = true
        tbl263[BrickColor.new("Magenta").Number] = true
      end)
      local tbl264 = {}
      local tbl265 = {}
      local tbl266 = { 0 }
      local res183 = __NATIVE[104](num274, tbl263, {
        Fire = true,
        OrderField = true,
        PurityField = true,
        MageField = true,
        SolanBall = true,
        SolansGate = true,
        BaalField = true,
        Elevator = true,
        TeleportIn = true,
        TeleportOut = true,
      }, v966, tbl265, tbl264, tbl266)
      local fn495 = function()
        tbl266[1] += 1
        for k237, v976 in tbl264 do
          if v976 and v976.Parent then
            pcall(function()
              v976.CanTouch = true
            end)
          end
        end
        for k238, v977 in tbl265 do
          if v977 and v977.Parent then
            pcall(function()
              v977.CanCollide = true
            end)
          end
        end
        table.clear(tbl264)
        table.clear(tbl265)
      end
      local vector36 = Vector3.new(-1540, 620, 1874)
      local vector37 = Vector3.new(-1528, 621, 1852)
      local fn496 = function()
        local leaderstats2 = LocalPlayer21:FindFirstChild("leaderstats")
        local v978 = leaderstats2 and leaderstats2:FindFirstChild("UberTitle")
        return (v978 and tostring(v978.Value) or ""):gsub("^%s+", ""):gsub("%s+$", "")
      end
      local tbl267 = { Ungrab = true, NoJump = true, FreezeRoot = true, NoLocationSave = true }
      local num293 = 25
      local num294 = 3600
      local num295 = 200
      local num296 = 2
      local num297 = 24
      local num298 = 300
      local num299 = 60
      local num300 = 20
      local num301 = 10
      local fn497 = function()
        local Character38 = LocalPlayer21.Character
        local v979 = Character38 and Character38:FindFirstChildOfClass("Humanoid")
        if
          not (
            Character38
            and v979
            and v979.Health > 0
            and Character38:FindFirstChild("HumanoidRootPart")
            and Character38:FindFirstChild("FakeHumanoid", true)
          )
        then
          return nil
        end
        return Character38, v979
      end
      local fn498 = function()
        local tbl298 = { seen = false }
        local v980
        local v981
        local fn530 = function()
          if v980 then
            v980:Disconnect()
            v980 = nil
          end
          local Character39 = LocalPlayer21.Character
          if not Character39 then
            return
          end
          tbl298.seen = tbl298.seen or Character39:FindFirstChildOfClass("ForceField") ~= nil
          v980 = Character39.ChildAdded:Connect(function(a1701)
            if a1701:IsA("ForceField") then
              tbl298.seen = true
            end
          end)
        end
        tbl298.up = function()
          local Character40 = LocalPlayer21.Character
          return Character40 ~= nil and Character40:FindFirstChildOfClass("ForceField") ~= nil
        end
        tbl298.stop = function()
          v981:Disconnect()
          if v980 then
            v980:Disconnect()
          end
        end
        v981 = LocalPlayer21.CharacterAdded:Connect(fn530)
        fn530()
        return tbl298
      end
      local fn499 = function(a1702)
        if not a1702 then
          return
        end
        local getDescendantsResult13, v982, v983 = a1702:GetDescendants()
        for k239, v984 in getDescendantsResult13, v982, v983 do
          if v984:IsA("BasePart") and v984.Name ~= "HumanoidRootPart" then
            v984.CanCollide = v984.Name == "Head" or v984.Name == "Torso"
          end
        end
      end
      local fn500 = function(a1703)
        local v985 = a1703 and a1703.Parent
        if not v985 then
          return true
        end
        local Live10 = v966:FindFirstChild("Live")
        return Live10 ~= nil and v985.Parent ~= Live10
      end
      local vector38 = Vector3.new(2855, 288, 17)
      local vector39 = Vector3.new(2780, 576, -67)
      local vector310 = Vector3.new(2000, 143, -2277)
      local num302 = 300
      local num303 = 600
      local num304 = 140
      local num305 = 155
      local tbl268 = {
        Vector3.new(1981, 143, -2252),
        Vector3.new(2000, 459, -2260),
        Vector3.new(1999, 461, -2127),
        Vector3.new(1994, 387, -2121),
        Vector3.new(2118, 387, -1888),
        Vector3.new(2136, 155, -1891),
      }
      local num306 = 2
      local num307 = 150
      local num308 = 140
      local tbl269 = { 0 }
      local tbl270 = { false }
      local tbl271 = { "Pommel Strike", "Action Surge", "Plate Training", "MercenaryCarry" }
      local tbl272 = { { exact = "Ma'am, thank you." }, { exact = "Sir, thank you." } }
      local tbl273 = { "Thanks for the help earlier." }
      local tbl274 = { "Thank you for the potion." }
      local tbl275 = { "Oh, bless your soul!" }
      __L2.tbl276 = { "Desert Mist! Of course!" }
      __L2.tbl277 = { "Again, thank you. Now, to test the recipe" }
      __L2.tbl278 = { "Welcome back to Castle Sanctuary" }
      __L2.num309 = 65
      __L2.tbl279 = { "Thunder Charge", "Flame Charge", "Ice Charge" }
      __L2.tbl280 = { 0 }
      __L2.tbl281 = { false }
      __L2.tbl282 = { "MythicStability", "Charged Blow", "Hyper Body", "ChargeMastery" }
      __L2.tbl283 = { { exact = "...", terminal = true } }
      __L2.tbl284 = { "Oh, Reynauld, you fool" }
      __L2.tbl285 = { "goes unresponsive" }
      __L2.tbl286 = { "your resolve is wavering" }
      __L2.tbl287 = {
        "p6_reynauld",
        "p6_hespe",
        "p6_brom",
        "p6_fir",
        "p6_dormin",
        "p6_alana",
        "p6_lachesis",
        "p6_kothe",
        "p7_hendrick",
        "p7_dormin",
        "p7_lerase",
        "p7_rita",
        "p7_reneri",
        "p7_fanari",
        "p7_ria",
        "p7_lilin",
      }
      __L2.tbl288 = { { exact = "Ria..." }, "Thank you for your help." }
      __L2.tbl289 = { "Oh," }
      __L2.num310 = 6
      __L2.tbl290 = { "Fir should be in the town up ahead" }
      __L2.tbl291 = { "Brom, hm? I hope he arrives soon." }
      __L2.tbl292 = {
        Vector3.new(3319, 202, -2481),
        Vector3.new(3291, 202, -2502),
        Vector3.new(3239, 202, -2502),
        Vector3.new(3225, 207, -2502),
        Vector3.new(3193, 161, -2499),
        Vector3.new(3199, 127, -2513),
        Vector3.new(3219, 128, -2514),
        Vector3.new(3224, 128, -2516),
      }
      __L2.tbl293 = { Vector3.new(3223, 128, -2517), Vector3.new(3223, 142, -2519), Vector3.new(3227, 148, -2521) }
      __L2.tbl294 = { Vector3.new(3225, 142, -2520), Vector3.new(3221, 142, -2517), Vector3.new(3223, 128, -2518) }
      __L2.vector311 = Vector3.new(3224, 128, -2516)
      __L2.vector312 = Vector3.new(3227, 148, -2521)
      __L2.tbl295 = { "Why am I still here" }
      __L2.tbl296 = { { exact = "Mmm..." } }
      __L2.fn501 = function(a1704)
        return tostring(a1704):lower():gsub("[^%w]", "")
      end
      __L2.fn502 = function(a1705)
        local tbl299 = {}
        for k240, v986 in { LocalPlayer21:FindFirstChildOfClass("Backpack"), LocalPlayer21.Character } do
          if v986 then
            local getChildrenResult41, v987, v988 = v986:GetChildren()
            for k241, v989 in getChildrenResult41, v987, v988 do
              tbl299[__L2.fn501(v989.Name)] = true
            end
          end
        end
        local tbl300 = {}
        for k242, v990 in a1705 do
          if not tbl299[__L2.fn501(v990)] then
            table.insert(tbl300, v990)
          end
        end
        return tbl300
      end
      __L2.fn503 = function(a1706)
        return #__L2.fn502(a1706) < #a1706
      end
      __L2.fn504 = function(a1707, a2216)
        local num318 = 0
        local v991 = a2216 or num288
        while true do
          if not (num318 < v991 and not (fn497() and __L2.fn503(a1707))) then
            break
          end
          task.wait(0.25)
          num318 += 0.25
        end
        return __L2.fn503(a1707)
      end
      __L2.tbl297 = { [""] = true, ["Name Unidentified"] = true, ["Unknown Region"] = true, Unknown = true }
      __L2.fn505 = function()
        local str44 = ""
        local str45 = ""
        local PlayerGui7 = LocalPlayer21:FindFirstChildOfClass("PlayerGui")
        local v992 = PlayerGui7 and PlayerGui7:FindFirstChild("ServerStatsGui")
        local v993 = v992 and v992:FindFirstChild("Frame")
        local v994 = v993 and v993:FindFirstChild("Stats")
        if v994 then
          local ServerName = v994:FindFirstChild("ServerName")
          if ServerName then
            str44 = ServerName.Text:match("Server Name: (.+)") or ""
          end
          local ServerRegion = v994:FindFirstChild("ServerRegion")
          if ServerRegion then
            str45 = ServerRegion.Text:match("Server Region: (.+)") or ""
          end
        end
        return str44, str45
      end
      __L2.fn506 = function(a1708)
        local num319 = tick() + (a1708 or 0)
        local res184, v995 = __L2.fn505()
        while true do
          if not (__L2.tbl297[res184] and tick() < num319) then
            break
          end
          task.wait(0.25)
          local res185, v996 = __L2.fn505()
          res184 = res185
          v995 = v996
        end
        return res184 ~= "" and res184 or "Unknown", v995 ~= "" and v995 or "Unknown"
      end
      __L2.str42 = ""
      __L2.scopedResult = xResult2.scoped(function()
        return __L2.str42
      end)
      __L2.fn507 = function()
        if xResult2.config.showUsername then
          return string.format("Players: %d/23 | %s | Job: %s", #getResult23:GetPlayers(), LocalPlayer21.Name, game.JobId)
        end
        return string.format("Players: %d/23 | Job: %s", #getResult23:GetPlayers(), game.JobId)
      end
      __L2.fn508 = function(a1709)
        local maxResult4 = math.max(0, math.floor(tonumber(a1709) or 0))
        local floorResult3 = math.floor(maxResult4 / 3600)
        local floorResult4 = math.floor(maxResult4 % 3600 / 60)
        local num320 = maxResult4 % 60
        if floorResult3 > 0 then
          return string.format("%dh %dm %ds", floorResult3, floorResult4, num320)
        end
        return string.format("%dm %ds", floorResult4, num320)
      end
      __L2.fn509 = function(a1710)
        return "```ini\n" .. table.concat(a1710, "\n") .. "\n```"
      end
      __L2.fn510 = function(a1711, a2217)
        if not a1711 then
          return __L2.fn509({ "[+] Total  unknown" })
        end
        local timeResult3 = os.time()
        local tbl301 = { string.format("[+] %-6s %s", "Total", __L2.fn508(timeResult3 - a1711)) }
        if a2217 then
          table.insert(tbl301, string.format("[+] %-6s %s", "Gaia", __L2.fn508(a2217 - a1711)))
          table.insert(tbl301, string.format("[+] %-6s %s", "Khei", __L2.fn508(timeResult3 - a2217)))
        end
        return __L2.fn509(tbl301)
      end
      __L2.fn511 = function(a1712, a2218)
        local tbl302 = {
          string.format("[+] %-6s %s", "Start", a1712 and tostring(a1712) or "unknown"),
          string.format("[+] %-6s %s", "End", a2218 and tostring(a2218) or "unknown"),
        }
        if a1712 and a2218 then
          local num321 = a1712 - a2218
          table.insert(tbl302, string.format("[+] %-6s %s", num321 >= 0 and "Spent" or "Gained", tostring(math.abs(num321))))
        end
        return __L2.fn509(tbl302)
      end
      __L2.fn512 = function(a1713, a2219)
        if not a2219 then return false end
        local state=a1713.State
        if state.blade23Enabled and state.blade23Enabled() then return true end
        if state.bladeLocalClients and state.bladeLocalClients.isAlly(a2219) then return true end
        if state.isFriend and state.isFriend(a2219) then return true end
        local alts=state.bladeRunAlts or (a1713.Library.Options.RotAlts and a1713.Library.Options.RotAlts.Value) or {}
        if alts[a2219.Name] or alts[tostring(a2219.UserId)] or alts[a2219.UserId] then return true end
        if state.bladeTeam and state.bladeTeam[a2219.UserId] then return true end
        if a1713.State.isFriendly then
          return a1713.State.isFriendly(a2219) == true
        end
        return a1713.State.isFriend ~= nil and a1713.State.isFriend(a2219) == true
      end
      __L2.fn513 = function(a1714, a2220, a370, a425)
        return GResult.roster(a370, a425, a2220, function(a1715)
          return __L2.fn512(a1714, a1715)
        end)
      end
      __L2.num311 = 0
      __L2.fn514 = function()
        while tick() - __L2.num311 < 2 do
          task.wait(0.1)
        end
      end
      __L2.fn515 = function()
        local PlayerGui8 = LocalPlayer21:FindFirstChild("PlayerGui")
        local v997 = PlayerGui8 and PlayerGui8:FindFirstChild("MenuReturnGui")
        local v998 = v997 and (v997:FindFirstChild("Menu") or v997:FindFirstChild("Menu", true))
        return v998 ~= nil and v998.Visible
      end
      __L2.fn516 = function()
        __L2.fn514()
        local num322 = tick() + num293
        while tick() < num322 do
          if fn497() and __L2.fn515() then
            return true
          end
          task.wait(0.1)
        end
        return false
      end
      __L2.fn517 = function()
        if not __L2.fn516() then
          return
        end
        local requestRemoteResult3 = eResult7.requestRemote("ReturnToMenu")
        if requestRemoteResult3 then
          pcall(function()
            requestRemoteResult3:InvokeServer()
          end)
        end
      end
      __L2.num312 = 15105570
      __L2.num313 = 15548997
      __L2.num314 = 5793266
      __L2.num315 = 5763719
      __L2.fn518 = function(a1716, a2221, a371, a426)
        local res186, v999 = __L2.fn506()
        local fields2 = {
          { name = "Server", value = string.format("`%s`\n`%s`", res186, v999), inline = true },
          { name = "Job", value = string.format("`%s`", tostring(game.JobId)), inline = true },
        }
        if a426 and #a426 > 0 then
          local str46 = "Nearby"
          local v1000 = a426
          if #a426 > 1 and a426[1]:find("Within", 1, true) then
            str46 = a426[1]:gsub("%*%*", "")
            v1000 = { table.unpack(a426, 2) }
          end
          table.insert(fields2, { name = str46, value = table.concat(v1000, "\n"), inline = false })
        end
        return {
          title = a1716,
          description = a371,
          color = a2221,
          fields = fields2,
          footer = { text = __L2.fn507() },
          timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
      end
      __L2.fn519 = function(a1717, a2222, a372, a427)
        local res187 = __L2.fn518(a427 and string.format("Serverhop [%s]", tostring(a427)) or "Serverhop", __L2.num312, a1717, a2222)
        if a372 then
          pcall(__L2.scopedResult.embedWith, a372, res187)
        else
          pcall(__L2.scopedResult.embed, res187)
        end
      end
      __L2.fn520 = function(a1718, a2223)
        pcall(__L2.scopedResult.embedWith, "@everyone", __L2.fn518("Stopped", __L2.num313, a1718, a2223))
      end
      __L2.fn521 = function(a1719)
        pcall(__L2.scopedResult.embed, __L2.fn518("Stopped", __L2.num313, a1719))
      end
      __L2.fn522 = function(a1720)
        pcall(__L2.scopedResult.embed, __L2.fn518("Skipped", __L2.num314, a1720))
      end
      __L2.v971 = nil
      __L2.fn523 = function(a1721)
        __L2.v971 = a1721
      end
      __L2.fn524 = function(a1722, a2224)
        pcall(__L2.scopedResult.embed, __L2.fn518(a1722, __L2.num315, a2224))
      end
      __L2.fn525 = function()
        local PlayerGui9 = LocalPlayer21:FindFirstChild("PlayerGui")
        local v1001 = PlayerGui9 and PlayerGui9:FindFirstChild("StatGui")
        local v1002 = v1001 and v1001:FindFirstChild("LeftContainer")
        return v1002 ~= nil and v1002.Visible
      end
      __L2.fn526 = function()
        local Character41 = LocalPlayer21.Character
        local v1003 = Character41 and Character41:FindFirstChild("ManaAbilities")
        return __L2.fn525() and v1003 ~= nil and v1003:FindFirstChild("CanClimb") ~= nil
      end
      __L2.str43 = "rbxassetid://2986649587"
      __L2.num316 = 1.7
      __L2.v972 = nil
      __L2.v973 = nil
      __L2.fn527 = function()
        local Character42 = LocalPlayer21.Character
        local v1004 = Character42 and Character42:FindFirstChildOfClass("Humanoid")
        local v1005 = v1004 and v1004:FindFirstChildOfClass("Animator")
        if not v1005 then
          return
        end
        if not __L2.v972 or __L2.v973 ~= Character42 then
          __L2.v973 = Character42
          local animation = Instance.new("Animation")
          animation.AnimationId = __L2.str43
          local ok118, result114 = pcall(function()
            return v1005:LoadAnimation(animation)
          end)
          __L2.v972 = ok118 and result114 or nil
          if __L2.v972 then
            __L2.v972.Looped = true
            pcall(function()
              __L2.v972.Priority = Enum.AnimationPriority.Action4
            end)
          end
        end
        if __L2.v972 then
          __L2.v972:Play(0)
          __L2.v972.TimePosition = __L2.num316
          __L2.v972:AdjustSpeed(0)
        end
      end
      __L2.fn528 = function()
        if LocalPlayer21.Character ~= __L2.v973 then
          __L2.fn527()
          return
        end
        local v1006 = __L2.v972
        if not v1006 then
          return
        end
        if not v1006.IsPlaying then
          v1006:Play(0)
          v1006.TimePosition = __L2.num316
          v1006:AdjustSpeed(0)
          return
        end
        if v1006.Speed ~= 0 then
          v1006:AdjustSpeed(0)
        end
        if math.abs(v1006.TimePosition - __L2.num316) > 0.02 then
          v1006.TimePosition = __L2.num316
        end
      end
      __L2.fn529 = function()
        if __L2.v972 then
          pcall(function()
            __L2.v972:Stop()
          end)
        end
      end
      return function(a1723)
        local __L3 = {}
        a1723.State.offsetStart = __L2.fn527
        a1723.State.offsetHold = __L2.fn528
        a1723.State.offsetStop = __L2.fn529
        local progressionTab = a1723.State.progressionTab
        if not progressionTab then
          return
        end
        local Toggles8 = a1723.Library.Toggles
        local Options8 = a1723.Library.Options
        a1723.State.bladeLocalClients=tbl44.M().localClients()
        a1723.Maid:Give(function()
          if a1723.State.bladeLocalClients then a1723.State.bladeLocalClients.stop();a1723.State.bladeLocalClients=nil end
        end)
        __L3.bladeThreatDistance=function()
          local key=game.PlaceId==num274 and "ProgKheiProximity" or "ProgProximity"
          return math.max(0,tonumber(Options8[key] and Options8[key].Value) or 0)
        end
        a1723.State.bladeSafetyAlly=function(player) return __L2.fn512(a1723,player) end
        __L3.bladeStayHere=function()
          local key=game.PlaceId==num274 and "ProgKheiStayInServer" or "ProgStayInServer"
          return Toggles8[key] and Toggles8[key].Value==true
        end
        a1723.State.blade23Enabled=function()
          if game.PlaceId~=5208655184 then return false end -- 23 is exclusive to Gaia, including saved runs.
          local run=__L3.bladeRunConfig
          if run and run.Blade23Mode~=nil then return run.Blade23Mode==true end
          return Toggles8.Blade23Mode and Toggles8.Blade23Mode.Value==true
        end
        __L3.bladeEnabled=function()
          return true -- Merged Blade/Sigil GUI; original routines remain available internally.
        end
        local tbl303 = { false }
        local tbl304 = { false }
        local tbl305 = { 0 }
        local tbl306 = {}
        local tbl307 = {}
        local v1007
        local v1008
        local newResult61 = dResult12.new()
        a1723.Maid:Give(newResult61)
        a1723.Maid:Give(function()
          tbl303[1] = false
          __L2.fn529()
          fn495()
          qResult3.remove("progression_active")
          qResult3.remove("khei_run")
        end)
        local fn531 = function(a1724)
          if __L3.progStatusLabel then
            __L3.progStatusLabel:SetText(a1724 and "Sigil: em execucao" or "Sigil: parado")
          end
          if v1007 and v1007.Holder then
            v1007.Holder.Visible = a1724
          end
        end
        local fn532 = function(a1725)
          if v1008 and v1008.Holder then
            v1008.Holder.Visible = a1725
          end
        end
        local fn533 = function()
          fn531(false)
          fn532(true)
        end
        local tbl308 = { nil }
        local v1009
        local tbl309 = { nil }
        local tbl310 = {}
        local v1010
        local flag57 = false
        local flag58 = false
        local tbl311 = {}
        local v1011
        local str47 = "sentinel/.cache"
        local HttpService5 = game:GetService("HttpService")
        local fn534 = function(a1726, ...)
          if not kResult6.enabled() then
            return
          end
          local ok119, result115 = pcall(string.format, a1726, ...)
          local str48 = "[auto-sigil] " .. (ok119 and result115 or tostring(a1726))
          print(str48)
          kResult6.log("auto-sigil", str48)
        end
        local fn535 = function(a1727)
          a1723.Library:Notify({ Title = "sentinel.bz", Description = a1727 })
        end
        local fn536 = function(a1728)
          flag58 = a1728
        end
        local fn537 = function()
          local Character43 = LocalPlayer21.Character
          return Character43 ~= nil and v969:HasTag(Character43, "Danger")
        end
        local fn538 = function()
          local v1016 = __L3.bladeThreatDistance()
          if v1016 <= 0 then
            return false
          end
          local v1017 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not v1017 then
            return false
          end
          local getPlayersResult18, v1018, v1019 = getResult23:GetPlayers()
          for k243, v1020 in getPlayersResult18, v1018, v1019 do
            local v1021 = v1020 ~= LocalPlayer21 and v1020.Character and v1020.Character:FindFirstChild("HumanoidRootPart")
            if v1021 and not __L2.fn512(a1723,v1020) and (v1021.Position - v1017.Position).Magnitude <= v1016 then
              return true
            end
          end
          return false
        end
        local fn539 = function()
          -- This reserved combat farm must be able to enter while Shriekers keep Danger active.
          if __L3.bladeRunConfig and __L3.bladeFarmAssigned=="shriekers"
            and tbl308[1] and tbl308[1].phase=="B1_XP" then return end
          while true do
            if not (tbl303[1] and fn537() and fn538()) then
              break
            end
            task.wait(0.5)
          end
        end
        local fn540 = function()
          return str47 .. "/" .. tostring(LocalPlayer21.UserId) .. ".json"
        end
        local fn541 = function()
          local ok120, result116 = pcall(function()
            if isfile and isfile(fn540()) then
              return HttpService5:JSONDecode(readfile(fn540()))
            end
          end)
          local v1022 = ok120 and type(result116) == "table" and result116 or nil
          local getJSONResult2 = qResult3.getJSON("prog_stamps")
          if type(getJSONResult2) == "table" then
            for k244, v1023 in getJSONResult2 do
              v1022 = v1022 or {}
              if v1022[k244] == nil then
                v1022[k244] = v1023
              end
            end
          end
          return v1022
        end
        local fn542 = function()
          if not tbl308[1] then
            return
          end
          qResult3.setJSON("prog_stamps", {
            startClock = tbl308[1].startClock,
            kheiClock = tbl308[1].kheiClock,
            startSilver = tbl308[1].startSilver,
            runId = tbl308[1].runId,
          })
          pcall(function()
            if makefolder then
              pcall(makefolder, "sentinel")
              pcall(makefolder, str47)
            end
            if writefile then
              writefile(fn540(), HttpService5:JSONEncode(tbl308[1]))
            end
          end)
        end
        local fn543 = function(a1729, a2225)
          if not tbl303[1] then
            return
          end
          tbl308[1] = tbl308[1] or {}
          tbl308[1].phase = a1729
          tbl308[1].step = a2225 or 0
          fn542()
          fn534("phase -> %s (step %s)", tostring(a1729), tostring(tbl308[1].step))
        end
        local fn544 = function(a1730)
          if not tbl303[1] then
            fn534("stopped by hand, skipping the kick for: %s", tostring(a1730))
            return
          end
          if __L3.bladeStayHere() then
            if __L3.bladePauseForMenu then __L3.bladePauseForMenu(a1730) end
            return
          end
          fn534("HARD STOP: %s", tostring(a1730))
          fn542()
          tbl303[1] = false
          fn531(false)
          qResult3.remove("progression_active")
          IResult.release()
          qResult3.remove("khei_run")
          qResult3.remove("khei_handoff_servers")
          newResult61:DoCleaning()
          if __L2.fn516() then
            vResult5.returnToMenu()
          end
          if a1723.State.safeTerminate then
            a1723.State.safeTerminate("auto-sigil: " .. tostring(a1730))
          else
            pcall(function()
              LocalPlayer21:Kick("auto-sigil: " .. tostring(a1730))
            end)
          end
        end
        local fn545 = function(a1731, a2226)
          tbl308[1] = tbl308[1] or {}
          tbl308[1].done = tbl308[1].done or {}
          if tbl308[1].done[a1731] then
            return
          end
          __L2.v971 = nil
          local res189 = a2226()
          if not tbl303[1] then
            return
          end
          if res189 ~= false then
            tbl308[1].done[a1731] = true
            if tbl308[1].skips then
              tbl308[1].skips[a1731] = nil
            end
            fn542()
            return
          end
          tbl308[1].skips = tbl308[1].skips or {}
          local num327 = (tbl308[1].skips[a1731] or 0) + 1
          tbl308[1].skips[a1731] = num327
          fn542()
          fn534("step %s did not take (attempt %d): %s", a1731, num327, __L2.v971 or "no reason recorded")
          if num327 == num289 then
            __L2.fn522(string.format("%s has not taken after %d tries: %s", a1731, num327, __L2.v971 or "no reason recorded"))
          end
        end
        local fn546 = function()
          tbl308[1] = tbl308[1] or {}
          tbl308[1].done = tbl308[1].done or {}
          local flag60 = false
          for k245, v1024 in __L2.tbl287 do
            if not tbl308[1].done[v1024] then
              tbl308[1].done[v1024] = true
              flag60 = true
            end
          end
          if flag60 then
            fn534("orderly quests marked done, the Jagen training is already held")
            fn542()
          end
        end
        local v1012
        local tbl312 = { 0 }
        local fn547 = function()
          tbl312[1] = tick() + 8
        end
        local fn548 = function(a1732)
          if v1012 and v1012.Holder then
            v1012.Holder.Visible = a1732
          end
        end
        local fn549 = function(a1733)
          local v1025 = a1723.State.getRogueName and a1723.State.getRogueName(a1733)
          if not v1025 or v1025 == "" or v1025 == "nil" or v1025 == "Unknown" then
            v1025 = a1733.DisplayName or a1733.Name
          end
          return v1025
        end
        local fn550 = function()
          if not tbl303[1] then
            return
          end
          if __L3.bladeStayHere() then
            if tbl308[1] then tbl308[1].boundInn=nil end
            fn542()
            if __L3.bladePauseForMenu then __L3.bladePauseForMenu("bot morreu; aguardando Play manual") end
            return
          end
          tbl303[1] = false
          if tbl308[1] then
            tbl308[1].boundInn = nil
          end
          qResult3.remove("progression_active")
          fn542()
          local v1026 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          __L2.fn520(
            string.format("the bot died on **%s**", tostring(tbl308[1] and tbl308[1].phase or "?")),
            __L2.fn513(a1723, fn549, v1026 and v1026.Position, 700)
          )
          __L2.fn516()
          pcall(function()
            LocalPlayer21:Kick("auto-sigil: bot died - stopped")
          end)
        end
        local fn551 = function(a1734)
          if not a1734 then
            return
          end
          local tbl336 = {}
          local num328 = 0
          newResult61.aaWatch = a1734.ChildAdded:Connect(function(a1735)
            if not tbl303[1] or not tbl267[a1735.Name] then
              return
            end
            if tick() < tbl312[1] then
              return
            end
            local tickResult8 = tick()
            if tickResult8 - num328 > 2 then
              tbl336 = {}
              num328 = tickResult8
            end
            tbl336[a1735.Name] = true
            local num329 = 0
            for k246 in tbl336 do
              num329 += 1
            end
            if num329 < 3 then
              return
            end
            tbl336 = {}
            local hasTagResult2 = v969:HasTag(a1734, "Danger")
            fn547()
            task.spawn(function()
              local num330 = 0
              while num330 < 15 do
                fn547()
                if LocalPlayer21.Character and LocalPlayer21.Character ~= a1734 then
                  break
                end
                task.wait(0.25)
                num330 += 0.25
              end
              if not (LocalPlayer21.Character and LocalPlayer21.Character ~= a1734) then
                fn534("AA markers seen but nothing died within 5s, treating as a false positive")
                return
              end
              tbl308[1] = tbl308[1] or {}
              tbl308[1].aaGunned = true
              if hasTagResult2 then
                fn542()
                __L2.fn520("AA gunned while in Danger, kicking")
                fn544("AA gunned while in Danger")
                return
              end
              fn542()
              __L2.fn520("AA gunned, menuing and kicking")
              fn544("AA gunned")
            end)
          end)
        end
        local fn552 = function(a1736)
          local v1027 = a1736 and a1736:FindFirstChildOfClass("Humanoid")
          if not v1027 then
            return
          end
          tbl305[1] = math.max(tbl305[1], tick() + 2)
          fn551(a1736)
          newResult61.deathWatch = v1027.Died:Connect(function()
            if not tbl303[1] or tick() < tbl312[1] then
              return
            end
            fn550()
          end)
        end
        local fn553 = function(player)
          local character=player and player.Character
          local backpack=player and player:FindFirstChildOfClass("Backpack")
          return (character~=nil and (character:FindFirstChild("Observe")~=nil or character:FindFirstChild("Observing")~=nil))
            or (backpack~=nil and backpack:FindFirstChild("Observe")~=nil)
        end
        local getServerValue = eResult7.getServerValue
        a1723.State.getServerValue = getServerValue
        if LocalPlayer21.Character then
          __L2.num311 = tick()
        end
        local Maid5 = a1723.Maid
        Maid5:Give(LocalPlayer21.CharacterAdded:Connect(function()
          __L2.num311 = tick()
        end))
        local fn554 = function()
          return "Auto-" .. (Options8.ProgClass and Options8.ProgClass.Value or "Sigil")
        end
        local fn555 = function(a1738, a2227, a373, a428)
          local res190, v1028 = __L2.fn506()
          table.insert(a373, 1, string.format("**Server:** `%s (%s)`", res190, v1028))
          return {
            title = a1738 .. " | " .. (game.PlaceId == num274 and "KHEI" or "GAIA"),
            description = table.concat(a373, "\n"),
            color = a2227,
            fields = a428,
            footer = { text = __L2.fn507() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          }
        end
        local fn556 = function(a1739, a2228)
          local num331 = tick() + (a1739 or 8)
          while true do
            if not ((tbl303[1] or tbl304[1]) and tick() < num331) then
              break
            end
            if not LocalPlayer21.Character then
              if not a2228 then
                return true
              end
              task.wait(0.1)
            elseif a2228 and not fn497() then
              task.wait(0.1)
            else
              local PlayerGui10 = LocalPlayer21:FindFirstChild("PlayerGui")
              local v1029 = PlayerGui10 and PlayerGui10:FindFirstChild("MenuReturnGui")
              local v1030 = v1029 and (v1029:FindFirstChild("Menu") or v1029:FindFirstChild("Menu", true))
              if v1030 and v1030.Visible then
                return true
              end
              task.wait(0.1)
            end
          end
          return false
        end
        local fn557 = function(a1740, a2229, a374, a429)
          if __L3.bladeStayHere() then
            return __L3.bladePauseForMenu and __L3.bladePauseForMenu(a1740) or false
          end
          if tbl304[1] then
            return false
          end
          tbl304[1] = true
          tbl303[1] = false
          __L2.fn506(5)
          local v1031 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          local tbl337 = {}
          for k247, v1032 in roster and #roster > 0 and roster or __L2.fn513(a1723, fn549, a2229 or v1031 and v1031.Position, a374 or 700) do
            table.insert(tbl337, v1032)
          end
          __L2.fn519(a1740, tbl337, a429, tbl308[1] and tbl308[1].phase or "?")
          local v1033 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if v1033 then
            qResult3.setJSON("prog_lastpos", { x = v1033.Position.X, y = v1033.Position.Y, z = v1033.Position.Z })
          end
          if tbl308[1] and tbl308[1].phase == "P5" then
            qResult3.remove("prog_pathpoint")
          end
          fn533()
          fn547()
          __L2.fn516()
          local hopResult = DResult2.hop({
            strategy = tbl308[1] and tbl308[1].phase == "P3" and "largest" or "smallest",
            minPlayers = Options8.MinPlayerCount and Options8.MinPlayerCount.Value or 0,
            reason = a1740,
            returnToMenu = not fn493(),
            avoid = (Toggles8.AvoidOtherBots == nil or Toggles8.AvoidOtherBots.Value) and IResult.takenJobs() or nil,
            onPick = IResult.claim,
          })
          if not hopResult then
            __L2.fn520(fn554() .. " serverhop failed, no joinable server")
            __L2.fn516()
            LocalPlayer21:Kick("sentinel: " .. fn554() .. " serverhop failed")
          end
          return hopResult
        end
        local v1013
        local fn558 = function(a1741, a2230, a375, a430, a510)
          if not tbl303[1] or tbl304[1] then return false end
          if __L3.bladeStayHere() then
            if __L3.bladePauseForMenu then return __L3.bladePauseForMenu(a1741) end
            return false
          end
          if game.PlaceId~=num274 and __L3.bladeEnabled() and not __L3.bladeValue("BladeAllowHop",false) then return false end
          return fn557(a1741, a2230, a375, a430) and true or false
        end
        local fn559 = function()
          local v1034 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
          if not v1034 then
            return
          end
          local num332 = 0
          while true do
            if not (num332 < 1.5 and v1034.FloorMaterial == Enum.Material.Air) then
              break
            end
            task.wait(0.1)
            num332 += 0.1
          end
        end
        local fn560 = function(a1742, a2231, a376)
          if __L3.bladeStayHere() then return fn558(a1742,a2231,a376) end
          if game.PlaceId~=num274 and __L3.bladeEnabled() and not __L3.bladeValue("BladeAllowHop",false) then return false end
          fn559()
          return fn557(a1742, a2231, a376)
        end
        local fn561 = function(a1743)
          if __L3.bladeStayHere() then
            fn558("Moderator " .. a1743.Name .. " present")
            return
          end
          local str49 = "moderator_encounter_" .. a1743.Name
          local num333 = (tonumber(qResult3.get(str49)) or 0) + 1
          qResult3.set(str49, num333)
          fn534("moderator %s detected (encounter %d)", a1743.Name, num333)
          local Character45 = LocalPlayer21.Character
          local v1035 = Character45 and Character45:FindFirstChild("HumanoidRootPart")
          local v1036 = Character45 ~= nil and v969:HasTag(Character45, "Danger")
          if num333 >= 3 or v1036 then
            tbl303[1] = false
            fn542()
            qResult3.remove("progression_active")
            __L2.fn520(string.format("moderator %s%s, kicking", a1743.Name, v1036 and " (in danger)" or " encountered 3x"))
            __L2.fn516()
            LocalPlayer21:Kick("auto-sigil: moderator encountered")
          else
            fn558("Moderator " .. a1743.Name .. " present", v1035 and v1035.Position, 700)
          end
        end
        local fn562 = function()
          return game.PlaceId == num274 or tbl308[1] ~= nil and tbl308[1].aaGunned == true or #__L2.fn502(__L2.tbl279) < #__L2.tbl279
        end
        local fn563 = function(a1744, a2232)
          if not tbl303[1] or a1744 == LocalPlayer21 then
            return false
          end
          if not a2232 and a1723.State.isModerator and a1723.State.isModerator(a1744) then
            fn561(a1744)
            return false
          end
          if __L2.fn512(a1723,a1744) then return false end
          local khei=game.PlaceId==num274
          local skipKey=khei and "ProgKheiSkipIllusionist" or "ProgSkipIllusionist"
          local skip=Toggles8[skipKey] and Toggles8[skipKey].Value
          local menu=not khei and Toggles8.ProgMenuIllusionistSuper and Toggles8.ProgMenuIllusionistSuper.Value and fn562()
          local illusion=fn553(a1744) or GResult.isIllusionist(a1744)
          if not illusion or not fn562() or not (skip or menu) then return false end
          if menu and __L3.bladePauseForMenu then
            return __L3.bladePauseForMenu("Illusionist "..fn549(a1744).." (Super)")
          end
          local v1037 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          return fn558(
            "Illusionist " .. fn549(a1744),
            v1037 and v1037.Position,
            __L3.bladeThreatDistance()
          )==true
        end
        local fn564 = function(a1745, a2233)
          if not a2233 then
            return
          end
          newResult61["char_" .. a1745.UserId] = a2233.ChildAdded:Connect(function(a1746)
            if a1746.Name == "Observing" or a1746.Name == "Observe" then
              fn563(a1745)
            end
          end)
          if a2233:FindFirstChild("Observing") or a2233:FindFirstChild("Observe") then
            fn563(a1745)
          end
        end
        local fn565 = function(a1747)
          if a1747 == LocalPlayer21 then
            return
          end
          fn563(a1747)
          fn564(a1747, a1747.Character)
          newResult61["cadd_" .. a1747.UserId] = a1747.CharacterAdded:Connect(function(a1748)
            fn564(a1747, a1748)
          end)
        end
        local res188 = __NATIVE[105](
          v969,
          LocalPlayer21,
          Options8,
          pebbleHold,
          getResult23,
          GResult,
          Toggles8,
          fn563,
          a1723,
          fn534,
          __L2.fn512,
          fn549,
          tbl309,
          tbl312,
          tbl306,
          fn494,
          fn558,
          tbl305,
          tbl303,
          { 0 },
          __L2.tbl280,
          __L2.tbl281,
          fn562,
          __L3.bladeThreatDistance
        )
        local fn566 = function(a1749)
          local Character46 = LocalPlayer21.Character
          local v1038 = Character46 and Character46:FindFirstChild("HumanoidRootPart")
          local v1039
          local v1040
          for k248, v1041 in tbl306 do
            if k248 ~= LocalPlayer21 and tick() - v1041 <= num265 and not __L2.fn512(a1723, k248) then
              local v1042 = k248.Character and k248.Character:FindFirstChild("HumanoidRootPart")
              if v1042 then
                local v1043 = v1038 and (v1042.Position - v1038.Position).Magnitude or 0
                if not v1040 or v1043 < v1040 then
                  v1039 = k248
                  v1040 = v1043
                end
              end
            end
          end
          if v1039 and (not v1038 or v1040 <= pebbleThrow) then
            fn558(string.format("%s threw Pebble (%.0f studs)", fn549(v1039), v1040), v1038 and v1038.Position, pebbleThrow)
          end
        end
        local v1014
        local v1015
        local fn567 = function()
          if v1014 then
            v1014()
          end
          local watchResult, v1044 = GResult.watch({
            active = function()
              return tbl303[1] and not tbl304[1]
            end,
            isFriend = function(a1750)
              return __L2.fn512(a1723, a1750)
            end,
            allow = function(a1751)
              return GResult.allowed(Options8, a1751)
            end,
            report = function(a1752)
              local v1045 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              if a1752.kind ~= "glassmask" and a1752.kind ~= "celeritas" then
                local v1046 = a1752.dodge or GResult.sidestep(a1752.position)
                if v1046 then
                  v1013(v1046)
                end
              end
              fn558(a1752.label, v1045 and v1045.Position, a1752.range, a1752.kind == "glassmask" and "@everyone" or nil)
            end,
          })
          v1014 = watchResult
          v1015 = v1044
          if not v1015 then
            fn534("arm: ClientVFX missing, snap Celeritas detection is off")
          end
        end
        local fn568 = function()
          newResult61:DoCleaning()
          __L2.tbl280[1] = 0
          __L2.tbl281[1] = false
          table.clear(tbl306)
          tbl305[1] = tick() + num266
          local getPlayersResult19, v1047, v1048 = getResult23:GetPlayers()
          for k249, v1049 in getPlayersResult19, v1047, v1048 do
            fn565(v1049)
          end
          newResult61:Connect(v967.Heartbeat, res188)
          newResult61:Connect(v966.ChildAdded, function(a1753)
            if tbl303[1] and a1753:IsA("MeshPart") and a1753.Name == "pebble" then
              fn566(a1753)
            end
          end)
          fn567()
          newResult61:Give(function()
            if v1014 then
              v1014()
              v1014 = nil
            end
          end)
          task.spawn(res183)
          newResult61:Connect(getResult23.PlayerAdded, fn565)
          do
            newResult61:Give(task.spawn(function()
              while tbl303[1] do
                task.wait(1)
                local getPlayersResult20, v1050, v1051 = getResult23:GetPlayers()
                for k250, v1052 in getPlayersResult20, v1050, v1051 do
                  if not tbl303[1] or tbl304[1] or fn563(v1052, true) then
                    break
                  end
                end
              end
            end))
          end
          if a1723.State.onModeratorFlagged then
            newResult61.flagged = a1723.State.onModeratorFlagged(function(a1754)
              if tbl303[1] then
                fn561(a1754)
              end
            end)
          end
          newResult61:Connect(getResult23.PlayerRemoving, function(a1755)
            newResult61["char_" .. a1755.UserId] = nil
            newResult61["cadd_" .. a1755.UserId] = nil
          end)
          fn552(LocalPlayer21.Character)
          newResult61:Connect(LocalPlayer21.CharacterAdded, fn552)
          newResult61:Give(task.spawn(function()
            local res191 = fn494()
            local v1053
            while tbl303[1] do
              task.wait(num284)
              res191 = res191 * 0.8 + fn494() * 0.2
              local v1054 = Options8.ProgPing and Options8.ProgPing.Value or 0
              if v1054 <= 0 or res191 <= v1054 or tbl304[1] or __L3.bladeStayHere() then
                v1053 = nil
              end
              if not v1053 then
                v1053 = os.clock()
              end
              if os.clock() - v1053 >= num285 then
                v1053 = nil
                fn534("ping %.0fms over the %.0fms limit for %ds, hopping", res191, v1054, num285)
                task.spawn(fn558, string.format("%.0fms ping over the %.0fms limit", res191, v1054))
              end
            end
          end))
          newResult61:Give(JResult.watch(function(a1756, a2234)
            if tbl303[1] and not tbl304[1] then
              task.spawn(fn558, string.format("ping spiked to %.0fms from %.0fms", a1756, a2234))
            end
          end))
          newResult61:Give(task.spawn(function()
            while tbl303[1] do
              task.wait(60)
              if tbl303[1] and not tbl304[1] then
                IResult.claim(game.JobId)
              end
            end
          end))
          newResult61:Connect(getResult23.PlayerAdded, function(a1757)
            task.wait(1)
            local v1055 = Toggles8.AvoidOtherBots == nil or Toggles8.AvoidOtherBots.Value
            if tbl303[1] and v1055 and not __L2.fn512(a1723,a1757) and IResult.twinHere() == a1757 then
              fn558("another of your bots (" .. a1757.Name .. ") joined")
            end
          end)
        end
        v1013 = function(a1758, a2235, a377)
          local Character47 = LocalPlayer21.Character
          local v1056 = Character47 and Character47:FindFirstChild("HumanoidRootPart")
          local num334 = 0
          while true do
            if not (tbl303[1] and not v1056 and num334 < 8) then
              break
            end
            task.wait(0.1)
            num334 += 0.1
            Character47 = LocalPlayer21.Character
            v1056 = Character47 and Character47:FindFirstChild("HumanoidRootPart")
          end
          if not v1056 then
            return
          end
          local num335 = os.clock() + 15
          while true do
            if not (tbl303[1] and os.clock() < num335) then
              break
            end
            local v1057 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            if v1057 and v1057.Parent and (v1057.Position - Vector3.new(-2, -102, 133)).Magnitude > 100 then
              break
            end
            task.wait(0.15)
          end
          if not (LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart") or v1056) then
            return
          end
          local Position6
          if typeof(a1758) == "CFrame" then
            Position6 = a1758.Position
          elseif typeof(a1758) == "Vector3" then
            Position6 = a1758
          else
            if not (typeof(a1758) == "Instance" and a1758:IsA("BasePart")) then
              return
            end
            Position6 = a1758.Position
          end
          local Humanoid11 = Character47:FindFirstChildOfClass("Humanoid")
          if Humanoid11 and not a377 then
            Humanoid11:SetStateEnabled(5, false)
            Humanoid11:ChangeState(3)
          end
          if a377 then
            fn499(Character47)
          end
          local connectResult6 = v967.RenderStepped:Connect(__NATIVE[106](sResult7, LocalPlayer21, a377))
          local v1058 = a2235 or (__L3.bladeEnabled() and __L3.bladeValue("BladeSpeed",100)) or Options8.TrinketBotSpeed and Options8.TrinketBotSpeed.Value or 100
          local fn651 = function(a1759)
            local v1060 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            if not v1060 then
              return
            end
            local CreateResult2 = v968:Create(
              v1060,
              TweenInfo.new((a1759 - v1060.Position).Magnitude / v1058, Enum.EasingStyle.Linear),
              { CFrame = CFrame.new(a1759) }
            )
            tbl307.tween = CreateResult2
            local tbl338 = { false }
            local completedConnection = CreateResult2.Completed:Connect(function()
              tbl338[1] = true
            end)
            CreateResult2:Play()
            __NATIVE[107](tbl338, tbl303)()
            if not tbl303[1] then
              CreateResult2:Cancel()
            else
              local v1061 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              if v1061 and (v1061.Position - a1759).Magnitude > 8 then
                v1061.CFrame = CFrame.new(a1759)
              end
            end
            completedConnection:Disconnect()
            CreateResult2:Destroy()
            tbl307.tween = nil
          end
          while tbl303[1] do
            local v1059 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            if not v1059 then
              break
            end
            if (Position6 - v1059.Position).Magnitude <= 1400 then
              fn651(Position6)
              break
            end
            fn651(v1059.Position + (Position6 - v1059.Position).Unit * 1400)
          end
          if Humanoid11 and not a377 then
            Humanoid11:SetStateEnabled(5, true)
            Humanoid11:ChangeState(5)
          end
          connectResult6:Disconnect()
          sResult7.clearVeil()
          tbl307.tween = nil
          tbl307.connection = nil
        end
        a1723.State.progWaitDanger = function()
          local Character48 = LocalPlayer21.Character
          if not (Character48 and v969:HasTag(Character48, "Danger")) then
            return true
          end
          local HumanoidRootPart8 = Character48:FindFirstChild("HumanoidRootPart")
          if HumanoidRootPart8 and (HumanoidRootPart8.Position - vector38).Magnitude <= 380 then
            fn534("danger near the Oresfall approach, perching until it clears")
            v1013(vector39)
          end
          local num336 = 0
          while num336 < 150 do
            local Character49 = LocalPlayer21.Character
            if not Character49 or not v969:HasTag(Character49, "Danger") then
              return true
            end
            task.wait(0.5)
            num336 += 0.5
          end
          return false
        end
        a1723.State.progKillWhenClear = function()
          local Character50 = LocalPlayer21.Character
          if Character50 and v969:HasTag(Character50, "Danger") then
            local HumanoidRootPart9 = Character50:FindFirstChild("HumanoidRootPart")
            if HumanoidRootPart9 and (HumanoidRootPart9.Position - vector38).Magnitude <= 380 then
              fn534("danger near the Oresfall approach, perching until it clears")
              v1013(vector39)
            end
            fn534("kill held until Danger drops")
            repeat
              v967.Heartbeat:Wait()
              local Character51 = LocalPlayer21.Character
              local cond15 = not tbl303[1]
              if cond15 then
                continue
              end
              cond15 = not (Character51 and v969:HasTag(Character51, "Danger"))
            until cond15
            task.wait(0.5)
          end
          local Character52 = LocalPlayer21.Character
          if not tbl303[1] or not Character52 then
            return nil
          end
          fn547()
          pcall(sResult7.kill)
          return Character52
        end
        local requestRemote = eResult7.requestRemote
        local fn569 = function()
          local tbl339 = {}
          if not fireclickdetector then
            table.insert(tbl339, "fireclickdetector")
          end
          if not firesignal then
            table.insert(tbl339, "firesignal")
          end
          if not firetouchinterest then
            table.insert(tbl339, "firetouchinterest")
          end
          if not (writefile and readfile) then
            table.insert(tbl339, "writefile/readfile")
          end
          return tbl339
        end
        local tbl313 = {
          "NoKillBricks",
          "NoFall",
          "NoOrderlyBarriers",
          "AutoIngredient",
          "AutoTrinket",
          "AutoBard",
          "AntiAfk",
        }
        local fn570 = function(a1760, a2236)
          local item47 = Toggles8[a1760]
          if item47 then
            pcall(function()
              item47:SetValue(a2236)
            end)
          end
        end
        local flag59 = false
        local fn571 = function()
          if flag59 then
            return
          end
          flag59 = true
          for k251, v1062 in tbl313 do
            local item48 = Toggles8[v1062]
            if item48 then
              pcall(function()
                item48:OnChanged(function()
                  if tbl303[1] and not item48.Value then
                    fn570(v1062, true)
                  end
                end)
              end)
            end
          end
        end
        local fn572 = function()
          tbl311 = {}
          for k252, v1063 in tbl313 do
            local item49 = Toggles8[v1063]
            if item49 then
              tbl311[v1063] = item49.Value
              fn570(v1063, true)
            end
          end
          local NoMobTrigger = Toggles8.NoMobTrigger
          if NoMobTrigger then
            tbl311.NoMobTrigger = NoMobTrigger.Value
            fn570("NoMobTrigger", false)
          end
          fn571()
        end
        local fn573 = function()
          for k253, v1064 in tbl311 do
            fn570(k253, v1064)
          end
          tbl311 = {}
        end
        local fn574 = function(a1761)
          local Character53 = LocalPlayer21.Character
          local v1065 = Character53 and Character53:FindFirstChild("CharacterHandler")
          local v1066 = v1065 and v1065:FindFirstChild("Remotes")
          return v1066 and v1066:FindFirstChild(a1761)
        end
        local fn575 = function()
          if not v1011 then
            local ok121, result117 = pcall(Instance.new, "VirtualInputManager")
            v1011 = ok121 and result117 or nil
          end
          return v1011
        end
        local fn576 = function()
          local Character54 = LocalPlayer21.Character
          return Character54 ~= nil and Character54:FindFirstChild("LightAttack") ~= nil
        end
        local fn577 = function()
          local res192 = fn575()
          if res192 then
            task.spawn(function()
              pcall(function()
                res192:SendMouseButtonEvent(0, 0, 0, true, game, 1)
                task.wait(math.random(1, 15) / 1000)
                res192:SendMouseButtonEvent(0, 0, 0, false, game, 1)
              end)
            end)
          end
          local res193 = fn574("LeftClick")
          if res193 then
            pcall(function()
              res193:FireServer({ math.random(1, 10), tonumber("0." .. math.random(1000000000000000, 9000000000000000)) })
            end)
          end
        end
        local fn578 = function(a1762)
          for i52 = 1, a1762 or 1 do
            if not tbl303[1] then
              return
            end
            local num337 = 0
            while true do
              if not (tbl303[1] and fn576() and num337 < 1.5) then
                break
              end
              task.wait(0.03)
              num337 += 0.03
            end
            if not tbl303[1] then
              return
            end
            fn577()
            task.wait(0.1)
          end
        end
        local fn579 = function(a1763, a2237)
          if a2237 then
            local v1067 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            local v1068 = v1067 and (v1067.Position - a1763).Magnitude or math.huge
            if v1068 > 300 then
              fn534("goTo: %.0f studs from target - out of position, recovering instead of teleporting", v1068)
              a2237()
              return false
            end
          end
          v1013(a1763)
          return true
        end
        local fn580 = function(a1764)
          tbl310 = a1764
          local str50 = #a1764 .. "|" .. tostring(a1764[1]) .. "|" .. tostring(a1764[#a1764])
          local num338 = 1
          if v1010 and v1010.sig == str50 then
            num338 = math.max(1, math.min(v1010.idx or 1, #a1764))
            v1010 = nil
          end
          for i53 = num338, #a1764 do
            if not tbl303[1] then
              return false
            end
            fn539()
            v1013(a1764[i53])
            qResult3.setJSON("prog_pathpoint", { sig = str50, idx = i53 })
            task.wait(0.02)
          end
          qResult3.remove("prog_pathpoint")
          return true
        end
        local near = sResult7.near
        local fn581 = function(a1765, a2238, a378)
          local num339 = 0
          while true do
            if not (tbl303[1] and not near(a1765, a2238) and num339 < (a378 or 8)) then
              break
            end
            task.wait(0.1)
            num339 += 0.1
          end
          return near(a1765, a2238)
        end
        local fn582 = function(a1766)
          local Character55 = LocalPlayer21.Character
          if not (Character55 and Character55:FindFirstChild("HumanoidRootPart")) then
            return
          end
          local num340 = os.clock() + 15
          while true do
            if not (tbl303[1] and os.clock() < num340) then
              break
            end
            local v1069 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            if v1069 and v1069.Parent and (v1069.Position - Vector3.new(-2, -102, 133)).Magnitude > 100 then
              break
            end
            task.wait(0.15)
          end
          local Character56 = LocalPlayer21.Character
          local v1070 = Character56 and Character56:FindFirstChild("HumanoidRootPart")
          if not v1070 then
            return
          end
          local Humanoid12 = Character56:FindFirstChildOfClass("Humanoid")
          if Humanoid12 then
            Humanoid12:SetStateEnabled(5, false)
            Humanoid12:ChangeState(3)
          end
          local connectResult7 = v967.RenderStepped:Connect(__NATIVE[108](sResult7, LocalPlayer21))
          local v1071 = v968
          local CreateResult3 = v1071:Create(
            v1070,
            TweenInfo.new(
              (a1766 - v1070.Position).Magnitude / (__L3.bladeEnabled() and __L3.bladeValue("BladeSpeed",100) or (Options8.TrinketBotSpeed and Options8.TrinketBotSpeed.Value or 100)),
              Enum.EasingStyle.Linear
            ),
            { CFrame = CFrame.new(a1766) }
          )
          local flag61 = false
          CreateResult3.Completed:Connect(function()
            flag61 = true
          end)
          CreateResult3:Play()
          local num341 = 0
          while true do
            if not (not flag61 and num341 < 5) then
              break
            end
            num341 += task.wait()
          end
          connectResult7:Disconnect()
        end
        local fn583 = function(a1767, a2239)
          local getPlayersResult21, v1072, v1073 = getResult23:GetPlayers()
          for k254, v1074 in getPlayersResult21, v1072, v1073 do
            if v1074 ~= LocalPlayer21 and not __L2.fn512(a1723, v1074) then
              local v1075 = v1074.Character and v1074.Character:FindFirstChild("HumanoidRootPart")
              if v1075 and (v1075.Position - a1767).Magnitude <= a2239 then
                return true
              end
            end
          end
          return false
        end
        local fn584 = function(a1768, a2240)
          local v1076
          local v1077
          local getPlayersResult22, v1078, v1079 = getResult23:GetPlayers()
          for k255, v1080 in getPlayersResult22, v1078, v1079 do
            if v1080 ~= LocalPlayer21 and not __L2.fn512(a1723, v1080) then
              local v1081 = v1080.Character and v1080.Character:FindFirstChild("HumanoidRootPart")
              if v1081 then
                local Magnitude11 = (v1081.Position - a1768).Magnitude
                if Magnitude11 <= a2240 and (not v1077 or Magnitude11 < v1077) then
                  v1076 = v1080
                  v1077 = Magnitude11
                end
              end
            end
          end
          return v1076
        end
        local Maid6 = a1723.Maid
        Maid6:Give(
          v967.Heartbeat:Connect(
            __NATIVE[109](num302, num303, vector310, num305, num304, LocalPlayer21, tbl269, tbl270, tbl304, fn583, tbl303, tbl308)
          )
        )
        a1723.State.a2FleeDue = function()
          return tbl270[1]
        end
        local fn585 = function(a1769)
          local v1082 = a1769.Character and a1769.Character:FindFirstChild("HumanoidRootPart")
          local v1083 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          local v1084 = tbl310
          if not (v1082 and v1083 and v1084 and #v1084 > 0) then
            return false
          end
          local num342 = 1
          local huge3 = math.huge
          for k256, v1085 in v1084 do
            local Magnitude12 = (v1085 - v1083.Position).Magnitude
            if Magnitude12 < huge3 then
              huge3 = Magnitude12
              num342 = k256
            end
          end
          local cond16 = (v1084[1] - v1082.Position).Magnitude > (v1084[#v1084] - v1082.Position).Magnitude
          local v1086 = cond16 and -1 or 1
          for i54 = num342 + v1086, cond16 and 1 or #v1084, v1086 do
            local item50 = v1084[i54]
            if item50 then
              if fn583(item50, 90) then
                break
              end
              fn582(item50)
              task.wait(0.2)
              local Character57 = LocalPlayer21.Character
              if Character57 and not v969:HasTag(Character57, "Danger") then
                return true
              end
            end
          end
          local Character58 = LocalPlayer21.Character
          return Character58 ~= nil and not v969:HasTag(Character58, "Danger")
        end
        tbl309[1] = function()
          -- Stay In Server must reach the normal proximity/menu action, never this forced-hop escape.
          if __L3.bladeStayHere() then return end
          if flag57 or tick() < tbl312[1] then
            return
          end
          local v1087 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not v1087 then
            return
          end
          local v1088 = __L3.bladeThreatDistance()
          if v1088 <= 0 then
            return
          end
          local res194 = fn584(v1087.Position, v1088 * 0.4)
          if not res194 then
            return
          end
          flag57 = true
          tbl303[1] = false
          fn531(false)
          local res195 = fn549(res194)
          local v1089 = tbl308[1] ~= nil and tbl308[1].phase == "P5" and (v1087.Position - vector310).Magnitude <= num303
          task.spawn(function()
            newResult61.attachLock = nil
            __L2.fn529()
            if v1089 then
              local item51 = tbl268[num306]
              fn582(item51)
              local connectResult8 = v967.RenderStepped:Connect(__NATIVE[110](LocalPlayer21, item51))
              local num343 = 0
              while true do
                if not (fn537() and num343 < num307) then
                  break
                end
                task.wait(0.5)
                num343 += 0.5
              end
              connectResult8:Disconnect()
              tbl308[1].a2resume = true
              fn542()
              fn557("went up to the perch away from " .. res195 .. " while combat-locked")
            elseif fn585(res194) then
              fn557("escaped " .. res195 .. " while combat-locked")
            else
              fn557("could not break away from " .. res195 .. ", hopping out", nil, nil, "@here")
            end
            flag57 = false
          end)
        end
        local fn586 = function(a1770, a2241)
          local progKillWhenClearResult = a1723.State.progKillWhenClear()
          if not progKillWhenClearResult then
            fn534("reset aborted, no character to reset")
            return false
          end
          local num344 = 0
          repeat
            fn547()
            task.wait(0.3)
            num344 += 0.3
            local v1090 = LocalPlayer21.Character
                and LocalPlayer21.Character ~= progKillWhenClearResult
                and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              or num344 > 20
            if v1090 then
              continue
            end
            v1090 = not tbl303[1]
          until v1090
          if not a1770 then
            return true
          end
          return fn581(a1770, a2241 or 150, 10)
        end
        local nearestModel = HResult.nearestModel
        local nearestNPC = HResult.nearestNPC
        local fn587 = function(a1771, a2242, a379, a431, a511, a67)
          if not tbl303[1] then
            return false
          end
          fn536(true)
          local runResult, v1091, v1092, v1093, v1094, v1095 = FResult.run(a1771, a2242, {
            shouldRun = function()
              return tbl303[1]
            end,
            timeout = a379,
            doneWhen = a431,
            successWhen = a511,
            beforeAnswer = a67,
            minHold = 0.5,
            log = function(a1772)
              fn534("%s", a1772)
            end,
          })
          fn536(false)
          return runResult, v1091, v1092, v1093, v1094, v1095
        end
        local fn588 = function(a1773, a2243, a380, a432, a512, a68)
          if not tbl303[1] then
            return false
          end
          local res196 = nearestNPC(a1773, a2243)
          if not res196 then
            fn534("talk %s: not found near the anchor", a1773)
            return false
          end
          local tickResult9 = tick()
          local num345 = 1
          local res197, v1096, v1097, v1098, v1099, v1100 = fn587(res196, a380, nil, a432, a512, a68)
          if not res197 and tbl303[1] then
            num345 = 2
            local res198, v1101, v1102, v1103, v1104, v1105 = fn587(res196, a380, nil, a432, a512, a68)
            res197 = res198
            v1096 = v1101
            v1097 = v1102
            v1098 = v1103
            v1099 = v1104
            v1100 = v1105
          end
          local num346 = tick() - tickResult9
          local v1106 = v1099 and #v1099 > 0 and table.concat(v1099, " > ") or "nothing"
          local formatResult5 = string.format("[%.1fs, %d run%s]", num346, num345, num345 == 1 and "" or "s")
          if v1096 then
            fn534("talk %s: opened on its already-done line %s", a1773, formatResult5)
          elseif res197 then
            fn534("talk %s: sent %d/%d [%s] %s", a1773, v1099 and #v1099 or 0, #a380, v1106, formatResult5)
          elseif #a380 == 0 then
            fn534("talk %s: confirm click, not on his finished line yet %s", a1773, formatResult5)
          else
            fn534(
              "talk %s: sent %d/%d [%s] | last offered: %s | %s %s",
              a1773,
              v1099 and #v1099 or 0,
              #a380,
              v1106,
              v1097 or "nothing",
              v1098 and "he closed on a choiceless line" or "timed out",
              formatResult5
            )
          end
          return res197, v1096, v1100, v1097
        end
        local fn589 = function(a1774, a2244, a381, a433, a513, a69)
          for i55 = 1, a513 or 4 do
            if not tbl303[1] then
              return false
            end
            local res199, v1107 = fn588(a1774, a2244, a381, a433, nil, a69)
            if v1107 then
              return true
            end
            task.wait(1)
            local res200, v1108 = fn588(a1774, a2244, {}, a433)
            if v1108 then
              fn534("talk %s: confirmed on his finished line", a1774)
              return true
            end
            fn534("talk %s: no confirmation, running it again", a1774)
            task.wait(1.5)
          end
          __L2.fn523(a1774 .. " never confirmed the quest")
          return false
        end
        local fn590 = function()
          local num347 = 0
          local Backpack17 = LocalPlayer21:FindFirstChildOfClass("Backpack")
          if not Backpack17 then
            return 0
          end
          local getChildrenResult42, v1109, v1110 = Backpack17:GetChildren()
          for k257, v1111 in getChildrenResult42, v1109, v1110 do
            local SilverValue = v1111:FindFirstChild("SilverValue")
            if SilverValue then
              num347 += SilverValue.Value
            end
          end
          return num347
        end
        local fn591 = function(a1775)
          local Backpack18 = LocalPlayer21:FindFirstChildOfClass("Backpack")
          local Character59 = LocalPlayer21.Character
          return Backpack18 ~= nil and Backpack18:FindFirstChild(a1775) ~= nil
            or Character59 ~= nil and Character59:FindFirstChild(a1775) ~= nil
        end
        local fn592 = function(a1776, a2245, a382)
          local Live11 = v966:FindFirstChild("Live")
          if not Live11 then
            return {}
          end
          local tbl340 = {}
          local getChildrenResult43, v1112, v1113 = Live11:GetChildren()
          for k258, v1114 in getChildrenResult43, v1112, v1113 do
            if string.find(v1114.Name, "Zombie Scroom") then
              local HumanoidRootPart10 = v1114:FindFirstChild("HumanoidRootPart")
              local Humanoid13 = v1114:FindFirstChildOfClass("Humanoid")
              if HumanoidRootPart10 and Humanoid13 and Humanoid13.Health > 0 then
                local Magnitude13 = (HumanoidRootPart10.Position - a1776.Position).Magnitude
                if Magnitude13 <= a2245 then
                  table.insert(tbl340, { hrp = HumanoidRootPart10, dist = Magnitude13 })
                end
              end
            end
          end
          table.sort(tbl340, function(a1777, a2246)
            return a1777.dist < a2246.dist
          end)
          local tbl341 = {}
          for i56 = 1, math.min(a382, #tbl340) do
            table.insert(tbl341, tbl340[i56].hrp)
          end
          return tbl341
        end
        local fn593 = function(a1778, a2247)
          local fn652 = function(a1779)
            local res202 = a1778(a1779)
            if #res202 == 0 then
              return nil
            end
            local zero4 = Vector3.zero
            local zero5 = Vector3.zero
            for k259, v1118 in res202 do
              zero4 += v1118.Position
              zero5 += v1118.CFrame.LookVector
            end
            local vector320 = Vector3.new(zero5.X, 0, zero5.Z)
            return zero4 / #res202, vector320.Magnitude < 0.01 and Vector3.new(0, 0, -1) or vector320.Unit
          end
          local v1115 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if v1115 then
            local res201, v1116 = fn652(v1115)
            if res201 then
              v1013(res201 + v1116 * (a2247 or 8.5))
            end
          end
          local v1117 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
          if v1117 then
            v1117:SetStateEnabled(5, false)
            v1117:ChangeState(3)
          end
          return v967.Stepped:Connect(__NATIVE[111](sResult7, LocalPlayer21, a2247, fn652, tbl303))
        end
        __L3.fn594 = function(a1780, a2248, a383, a434, a514)
          fn536(true)
          local res203 = fn593(a383, a434)
          while true do
            if not (tbl303[1] and not a1780()) then
              break
            end
            if a514 then
              local v1119 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
              if v1119 and v1119.Health < num270 and fn537() then
                pcall(function()
                  res203:Disconnect()
                end)
                a514()
                res203 = fn593(a383, a434)
              end
            end
            fn578(5)
            task.wait(a2248 or 2.5)
          end
          pcall(function()
            res203:Disconnect()
          end)
          fn536(false)
        end
        __L3.INN_ANCHORS = HResult.INN_ANCHORS
        __L3.setInn = function(a1781, a2249)
          if not tbl303[1] then
            return false
          end
          if __L3.bladeRunConfig and game.PlaceId~=num274 and a1781~="Alana" and not (tbl308[1] and tbl308[1].bladeSpawnTransitionAllowed) then
            local destination=__L3.INN_ANCHORS[a1781]
            if not destination then
              local keeper=HResult.innKeeper(a1781)
              local part=keeper and keeper:FindFirstChild("HumanoidRootPart")
              if part then destination={part.Position,150} end
            end
            if not destination then
              __L3.bladeStatus("Destino indisponivel: "..tostring(a1781).."; spawn mantido em Alana")
              return false
            end
            if not near(destination[1],destination[2]) then fn580({destination[1]}) end
            return tbl303[1] and near(destination[1],destination[2])
          end
          fn534("setInn -> %s", tostring(a1781))
          local item52 = __L3.INN_ANCHORS[a1781]
          local v1120 = __L3.bladeThreatDistance()
          if item52 and v1120 > 0 then
            local getPlayersResult23, v1121, v1122 = getResult23:GetPlayers()
            for k260, v1123 in getPlayersResult23, v1121, v1122 do
              if v1123 ~= LocalPlayer21 and not __L2.fn512(a1723, v1123) then
                local v1124 = v1123.Character and v1123.Character:FindFirstChild("HumanoidRootPart")
                if v1124 and (v1124.Position - item52[1]).Magnitude <= v1120 then
                  fn558(string.format("%s at the %s inn", fn549(v1123), a1781), item52[1], v1120)
                  return false
                end
              end
            end
          end
          if getServerValue("Lives") == 0 then
            return false
          end
          local item53 = __L3.INN_ANCHORS[a1781]
          if tbl308[1] and tbl308[1].boundInn == a1781 and item53 and near(item53[1], item53[2]) then
            fn534("setInn: already bound+near %s, settling", tostring(a1781))
            HResult.waitSettled(item53, function()
              return tbl303[1]
            end)
            return true
          end
          a1723.State.progWaitDanger()
          local num348 = 0
          while true do
            if not (tbl303[1] and not fn497() and num348 < 45) then
              break
            end
            task.wait(0.3)
            num348 += 0.3
          end
          if not tbl303[1] then
            return false
          end
          if not fn556(30, true) then
            fn534("setInn: character never finished spawning, not binding %s", tostring(a1781))
            return false
          end
          fn536(true)
          local setInnResult = HResult.setInn(a1781, {
            shouldRun = function()
              return tbl303[1]
            end,
            breakJoints = game.PlaceId~=num274,
            safeLanding = game.PlaceId==num274,
            protectFall = game.PlaceId==num274 and function()
              a1723.State.noFallUntil=math.max(a1723.State.noFallUntil or 0,tick()+2)
            end or nil,
            onBeforeBreak = game.PlaceId~=num274 and fn547 or nil,
            attempts = 4,
            log = function(a1782)
              fn534("setInn: no keeper found for %s", tostring(a1782))
            end,
          })
          fn536(false)
          if setInnResult then
            if tbl308[1] then
              tbl308[1].boundInn = a1781
              fn542()
            end
            return true
          end
          if tbl308[1] then
            tbl308[1].boundInn = nil
            fn542()
          end
          if not a2249 and tbl303[1] and fn494() > 250 then
            fn560(string.format("setInn(%s) failed + %.0fms ping - hopping", tostring(a1781), fn494()))
          end
          return false
        end
        a1723.State.setInn = __L3.setInn
        a1723.State.progActive = function()
          return tbl303[1]
        end
        __L3.fn595 = function(a1783)
          fn536(true)
          for i57 = 1, a1783 do
            if not tbl303[1] then
              break
            end
            while true do
              if not (tbl303[1] and LocalPlayer21.Character and v969:HasTag(LocalPlayer21.Character, "Danger")) then
                break
              end
              task.wait(0.3)
            end
            local num349 = 0
            local v1125
            local v1126
            local v1127
            while true do
              if not (tbl303[1] and num349 < 25) then
                break
              end
              local res204, v1128 = fn497()
              v1125 = res204
              v1126 = v1128
              local Backpack19 = LocalPlayer21:FindFirstChildOfClass("Backpack")
              v1127 = Backpack19 and Backpack19:FindFirstChild("Tespian Elixir")
              if v1125 and v1126 and v1127 then
                break
              end
              task.wait(0.3)
              num349 += 0.3
            end
            if not (v1125 and v1126) then
              v1125 = LocalPlayer21.Character
              v1126 = v1125 and v1125:FindFirstChildOfClass("Humanoid")
              local Backpack20 = LocalPlayer21:FindFirstChildOfClass("Backpack")
              v1127 = Backpack20 and Backpack20:FindFirstChild("Tespian Elixir")
            end
            if not (v1125 and v1126 and v1127 and v1126.Health > 0) then
              fn534("loopOrderly: no live character holding a Tespian Elixir after %.0fs, stopping the cycle", num349)
              break
            end
            v1126:EquipTool(v1127)
            task.wait(1.4)
            fn556(25, true)
            local Character60 = LocalPlayer21.Character
            local v1129 = Character60 and Character60:FindFirstChild("Tespian Elixir")
            local v1130 = v1129 and v1129:FindFirstChild("RemoteEvent")
            local v1131 = Character60 and Character60:FindFirstChild("HumanoidRootPart")
            if not (v1130 and v1131) then
              fn534("loopOrderly: the elixir never reached the character, retrying")
            else
              v1130:FireServer(v1131.CFrame, "Part", "Self")
              task.wait(1.5)
              if not a1723.State.progKillWhenClear() then
                fn534("tespian: no character to reset this cycle")
                break
              end
              local num350 = 0
              repeat
                fn547()
                task.wait(0.5)
                num350 += 0.5
                local v1132 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("Immortal") or num350 > 20
                if v1132 then
                  continue
                end
                v1132 = not tbl303[1]
              until v1132
            end
          end
          fn536(false)
        end
        __L3.tbl314 = {
          ["Health Potion"] = true,
          ["Liquid Wisdom"] = true,
          ["Ice Protection"] = true,
          ["Tespian Elixir"] = true,
        }
        __L3.fn596 = function(a1784)
          return a1784:IsA("BasePart") and a1784 or a1784:FindFirstChildWhichIsA("BasePart")
        end
        __L3.fn597 = function(a1785)
          v1013(a1785.Position)
          local v1133 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if firetouchinterest and v1133 then
            pcall(function()
              firetouchinterest(a1785, v1133, 0)
              firetouchinterest(a1785, v1133, 1)
            end)
          end
          task.wait(0.2)
        end
        __L3.fn598 = function()
          fn534("P1: scanning Thrown for bags within 50")
          local v1134 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          local Thrown6 = v966:FindFirstChild("Thrown")
          if v1134 and Thrown6 then
            local Position7 = v1134.Position
            local getChildrenResult44, v1135, v1136 = Thrown6:GetChildren()
            for k261, v1137 in getChildrenResult44, v1135, v1136 do
              if v1137.Name == "ToolBag" then
                local BillboardGui = v1137:FindFirstChild("BillboardGui")
                local v1138 = BillboardGui and BillboardGui:FindFirstChild("Tool")
                local res205 = __L3.fn596(v1137)
                if v1138 and __L3.tbl314[v1138.Text] and res205 and (res205.Position - Position7).Magnitude <= 50 then
                  fn534("P1: collecting ToolBag %s", tostring(v1138.Text))
                  __L3.fn597(res205)
                end
              end
            end
            local getChildrenResult45, v1139, v1140 = Thrown6:GetChildren()
            for k262, v1141 in getChildrenResult45, v1139, v1140 do
              if v1141.Name == "MoneyBag" then
                local res206 = __L3.fn596(v1141)
                if res206 and (res206.Position - Position7).Magnitude <= 50 then
                  fn534("P1: collecting MoneyBag")
                  __L3.fn597(res206)
                end
              end
            end
            v1013(Position7)
          end
          local tbl342 = {}
          for k263, v1142 in { "Liquid Wisdom", "Health Potion", "Ice Protection", "Tespian Elixir" } do
            if not fn591(v1142) then
              table.insert(tbl342, v1142)
            end
          end
          if not (#tbl342 > 0) then
            fn543("P2")
            return
          end
          fn535("Auto-Sigil stopped - needs " .. table.concat(tbl342, ", "))
          __L2.fn520("missing potions: " .. table.concat(tbl342, ", ") .. ". give them, then Start again")
          if v1009 then
            v1009()
          end
        end
        __L3.fn599 = function()
          if fn591("Tespian Elixir") then
            __L3.fn595(5)
          end
          fn543("P3")
        end
        __L3.tbl315 = { Opal = true, Ruby = true, Sapphire = true, Diamond = true, Emerald = true }
        __L3.fn600 = function(a1786)
          local Backpack21 = LocalPlayer21:FindFirstChildOfClass("Backpack")
          if not Backpack21 then
            return false
          end
          local getChildrenResult46, v1143, v1144 = Backpack21:GetChildren()
          for k264, v1145 in getChildrenResult46, v1143, v1144 do
            if a1786(v1145) then
              return true
            end
          end
          return false
        end
        __L3.fn601 = function()
          return __L3.fn600(function(a1787)
            return string.find(a1787.Name, "Scroll") ~= nil
          end)
        end
        __L3.fn602 = function()
          return __L3.fn600(function(a1788)
            return __L3.tbl315[a1788.Name] == true
          end)
        end
        __L3.tbl316 = {
          Vector3.new(-2115, 591, -704),
          Vector3.new(-1915, 595, -791),
          Vector3.new(-1524, 642, -584),
          Vector3.new(-1165, 632, -509),
          Vector3.new(-1173, 583, -463),
          Vector3.new(-1020, 541, -420),
          Vector3.new(-696, 504, -275),
          Vector3.new(-539, 532, -335),
          Vector3.new(-378, 532, -343),
          Vector3.new(-356, 448, -344),
          Vector3.new(-246, 448, -661),
          Vector3.new(-233, 382, -662),
          Vector3.new(50, 382, -671),
        }
        __L3.tbl317 = {
          Vector3.new(51, 382, -670),
          Vector3.new(171, 382, -1188),
          Vector3.new(199, 363, -1197),
          Vector3.new(556, 363, -1199),
          Vector3.new(556, 198, -1174),
          Vector3.new(557, 363, -1199),
          Vector3.new(199, 363, -1196),
          Vector3.new(171, 382, -1186),
          Vector3.new(51, 382, -671),
        }
        __L3.num323 = 5
        __L3.vector313 = Vector3.new(300, 290, -922)
        __L3.vector314 = Vector3.new(51, 382, -670)
        __L3.tbl318 = { Vector3.new(1352, 405, 2969), Vector3.new(1580, 356, 2857), Vector3.new(1593, 442, 2860) }
        __L3.tbl319 = {
          Vector3.new(1600, 420, 2864),
          Vector3.new(1586, 383, 2865),
          Vector3.new(1464, 401, 2760),
          Vector3.new(1473, 423, 2747),
        }
        __L3.fn603 = function(a1789, a2250)
          local fn653 = function()
            local v1151 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
            return v1151 and v1151.Position or a2250
          end
          local res207 = nearestNPC(a1789, fn653())
          local num351 = 0
          while true do
            if not (tbl303[1] and not res207 and num351 < 6) then
              break
            end
            task.wait(0.5)
            num351 += 0.5
            res207 = nearestNPC(a1789, fn653())
          end
          local res208 = fn653()
          if res207 then
            local v1146 = res207:FindFirstChild("HumanoidRootPart") or res207:FindFirstChildWhichIsA("BasePart")
            if v1146 then
              fn534(
                "%s part (%.1f,%.1f,%.1f) | bot (%.1f,%.1f,%.1f) | %.1f studs apart",
                a1789,
                v1146.Position.X,
                v1146.Position.Y,
                v1146.Position.Z,
                res208.X,
                res208.Y,
                res208.Z,
                (v1146.Position - res208).Magnitude
              )
            end
          else
            fn534("%s not found near (%.0f,%.0f,%.0f) - nearby NPCs:", a1789, res208.X, res208.Y, res208.Z)
            local NPCs3 = v966:FindFirstChild("NPCs")
            if NPCs3 then
              local getChildrenResult47, v1147, v1148 = NPCs3:GetChildren()
              for k265, v1149 in getChildrenResult47, v1147, v1148 do
                local v1150 = v1149:FindFirstChild("HumanoidRootPart") or v1149:FindFirstChildWhichIsA("BasePart")
                if v1150 and (v1150.Position - res208).Magnitude < 90 then
                  fn534("  %s (%.0f studs)", v1149.Name, (v1150.Position - res208).Magnitude)
                end
              end
            end
          end
          return res207
        end
        __L3.fn604 = function(a1790, a2251)
          local res209 = fn590()
          local num352 = 0
          repeat
            fn587(a1790, a2251)
            num352 += 1
            local v1152 = fn590() < res209 or num352 >= 3
            if v1152 then
              continue
            end
            v1152 = not tbl303[1]
          until v1152
          if fn590() >= res209 then
            fn534("sale via %s did not reduce inventory (%d) - name/dialogue may be wrong", a1790.Name, fn590())
          end
        end
        __L3.fn605 = function(a1791)
          return a1791.Name == "Part" and a1791:FindFirstChild("ID") ~= nil
        end
        __L3.fn606 = function(a1792, a2252, a384)
          while tbl303[1] do
            local Character61 = LocalPlayer21.Character
            local v1153 = Character61 and Character61:FindFirstChild("HumanoidRootPart")
            if not v1153 then
              break
            end
            local tbl343 = {}
            local getChildrenResult48, v1154, v1155 = v966:GetChildren()
            for k266, v1156 in getChildrenResult48, v1154, v1155 do
              if __L3.fn605(v1156) and v1156.Parent then
                local ID = v1156:FindFirstChild("ID")
                local v1157 = ID and ID.Value
                if not (v1157 and a384[v1157]) and (v1156.Position - a1792).Magnitude <= a2252 then
                  table.insert(tbl343, { obj = v1156, d = (v1156.Position - v1153.Position).Magnitude, id = v1157 })
                end
              end
            end
            if #tbl343 == 0 then
              break
            end
            table.sort(tbl343, function(a1793, a2253)
              return a1793.d < a2253.d
            end)
            for k267, v1158 in tbl343 do
              if not tbl303[1] then
                break
              end
              if v1158.obj.Parent then
                v1013(v1158.obj.Position)
                task.wait(0.18)
                local ClickDetector5 = v1158.obj:FindFirstChild("ClickDetector", true)
                if ClickDetector5 and fireclickdetector then
                  fireclickdetector(ClickDetector5)
                end
                task.wait(0.18)
              end
              if v1158.id then
                a384[v1158.id] = true
              end
            end
          end
        end
        __L3.fn607 = function(a1794, a2254)
          local connectResult9 = v967.RenderStepped:Connect(__NATIVE[112](LocalPlayer21, a1794))
          local num353 = 0
          while true do
            if not (tbl303[1] and num353 < a2254) then
              break
            end
            task.wait(0.25)
            num353 += 0.25
          end
          connectResult9:Disconnect()
        end
        __L3.fn608 = function()
          local v1159 = getServerValue("Silver") or 0
          if v1159 >= 484 then
            if not fn591("Sword") then
              __L3.setInn("Santorini")
            end
            fn543("P4")
            return
          end
          if v1159 + fn590() < 500 then
            fn570("NoMobTrigger", true)
            if not near(__L3.vector314, 200) then
              if near(__L3.vector313, 600) then
                v1013(__L3.vector314)
                if tbl303[1] and v1159 + fn590() < 500 then
                  fn542()
                  fn560("crypt: spawned in trinket zone, re-hopping")
                  return
                end
              else
                __L3.setInn("Renova")
                fn580(__L3.tbl316)
              end
            end
          end
          local tbl344 = {}
          tbl310 = __L3.tbl317
          while true do
            local v1160, res210, res211
            if not (tbl303[1] and v1159 + fn590() < 500) then
              fn570("NoMobTrigger", false)
              __L3.setInn("Santorini")
              if not tbl303[1] then
                return
              end
              fn580(__L3.tbl318)
              v1160 = __L3.fn601() or __L3.fn602() or __L3.fn602()
              if v1160 then
                res210 = __L3.fn603("Antiquarian", Vector3.new(1593, 442, 2860))
                if res210 then
                  if __L3.fn601() then
                    __L3.fn604(res210, { "Can I sell in bulk?", "Scrolls.", "It's a deal." })
                  end
                  if __L3.fn602() then
                    __L3.fn604(res210, { "Can I sell in bulk?", "Gemstones.", "It's a deal." })
                  end
                end
              end
              fn580(__L3.tbl319)
              res211 = __L3.fn603("Merchant", Vector3.new(1464, 401, 2760))
              if res211 then
                __L3.fn604(res211, { "Can I sell in bulk?", "Trinkets.", "It's a deal." })
              end
              if not tbl303[1] then
                return
              end
              if not fn591("Sword") then
                fn579(Vector3.new(1615, 423, 2783))
              end
              fn543("P4")
              return
            end
            for k268, v1161 in __L3.tbl317 do
              if not tbl303[1] then
                break
              end
              v1013(v1161)
              if k268 == __L3.num323 then
                __L3.fn607(v1161, 8.5)
                __L3.fn606(v1161, 500, tbl344)
              end
            end
            if not tbl303[1] then
              return
            end
            if v1159 + fn590() >= 500 then
              fn570("NoMobTrigger", false)
              __L3.setInn("Santorini")
              if not tbl303[1] then
                return
              end
              fn580(__L3.tbl318)
              v1160 = __L3.fn601() or __L3.fn602() or __L3.fn602()
              if v1160 then
                res210 = __L3.fn603("Antiquarian", Vector3.new(1593, 442, 2860))
                if res210 then
                  if __L3.fn601() then
                    __L3.fn604(res210, { "Can I sell in bulk?", "Scrolls.", "It's a deal." })
                  end
                  if __L3.fn602() then
                    __L3.fn604(res210, { "Can I sell in bulk?", "Gemstones.", "It's a deal." })
                  end
                end
              end
              fn580(__L3.tbl319)
              res211 = __L3.fn603("Merchant", Vector3.new(1464, 401, 2760))
              if res211 then
                __L3.fn604(res211, { "Can I sell in bulk?", "Trinkets.", "It's a deal." })
              end
              if not tbl303[1] then
                return
              end
              if not fn591("Sword") then
                fn579(Vector3.new(1615, 423, 2783))
              end
              fn543("P4")
              return
            end
            if not (__L3.bladeStayHere()) then
              break
            end
            fn534("P3: stay-in-server, looping crypt in 600s")
            task.wait(600)
          end
          fn542()
          fn534("P3: serverhopping for fresh crypt loot (%d silver + %d inv value)", v1159, fn590())
          fn560("fresh crypt loot")
        end
        __L3.tbl320 = { Vector3.new(1353, 412, 2992), Vector3.new(1630, 415, 2983), Vector3.new(1615, 423, 2782) }
        __L3.fn609 = function()
          if __L3.bladeEnabled() then
            if __L3.bladeBuySword() and tbl303[1] then __L3.bladePhase("B1_XP") end
            return
          end
          if fn591("Sword") then
            fn543("P5")
            return
          end
          local vector321 = Vector3.new(1615, 423, 2783)
          if not near(vector321, 40) then
            if not near(Vector3.new(1354, 431, 2985), 175) then
              __L3.setInn("Santorini")
              if not tbl303[1] then
                return
              end
            end
            fn580(__L3.tbl320)
          end
          local res212 = __L3.fn603("BronzeSword", vector321)
          if res212 then
            local flag62 = false
            local Backpack22 = LocalPlayer21:FindFirstChildOfClass("Backpack")
            local v1162
            if Backpack22 then
              v1162 = Backpack22.ChildAdded:Connect(function(a1795)
                if a1795:IsA("Tool") and a1795.Name == "Sword" then
                  flag62 = true
                end
              end)
            end
            local num354 = 0
            repeat
              fn587(res212, { "I'll buy it." })
              task.wait(1)
              num354 += 1
              local v1163 = flag62 or fn591("Sword") or num354 > 5
              if v1163 then
                continue
              end
              v1163 = not tbl303[1]
            until v1163
            if v1162 then
              v1162:Disconnect()
            end
          end
          if fn591("Sword") then
            fn543("P5")
          else
            fn544("could not buy the bronze sword")
          end
        end
        __L3.fn610 = function()
          local v1164 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
          local Backpack23 = LocalPlayer21:FindFirstChildOfClass("Backpack")
          local v1165 = Backpack23 and Backpack23:FindFirstChild("Sword")
          if v1164 and v1165 then
            v1164:EquipTool(v1165)
          end
        end
        __L3.fn611 = function(a1796, a2255, a385)
          local num355 = 0
          local Live12 = v966:FindFirstChild("Live")
          if not Live12 then
            return 0
          end
          local getChildrenResult49, v1166, v1167 = Live12:GetChildren()
          for k269, v1168 in getChildrenResult49, v1166, v1167 do
            if string.find(v1168.Name, "Zombie Scroom") then
              local HumanoidRootPart11 = v1168:FindFirstChild("HumanoidRootPart")
              local Humanoid14 = v1168:FindFirstChildOfClass("Humanoid")
              if
                HumanoidRootPart11
                and Humanoid14
                and Humanoid14.Health > 0
                and (HumanoidRootPart11.Position - a1796).Magnitude <= a2255
                and (not a385 or math.abs(HumanoidRootPart11.Position.Y - a385) <= num268)
              then
                num355 += 1
              end
            end
          end
          return num355
        end
        __L3.fn612 = function(a1797)
          local Live13 = v966:FindFirstChild("Live")
          if not Live13 then
            return nil
          end
          local v1169
          local v1170
          local getChildrenResult50, v1171, v1172 = Live13:GetChildren()
          for k270, v1173 in getChildrenResult50, v1171, v1172 do
            if string.find(v1173.Name, "Zombie Scroom") then
              local HumanoidRootPart12 = v1173:FindFirstChild("HumanoidRootPart")
              local Humanoid15 = v1173:FindFirstChildOfClass("Humanoid")
              if HumanoidRootPart12 and Humanoid15 and Humanoid15.Health > 0 then
                local Magnitude14 = (HumanoidRootPart12.Position - a1797).Magnitude
                if not v1170 or Magnitude14 < v1170 then
                  v1169 = HumanoidRootPart12.Position
                  v1170 = Magnitude14
                end
              end
            end
          end
          return v1169
        end
        __L3.fn613 = function(a1798, a2256, a386, a435)
          if not a1798.Parent then
            return
          end
          local fn654 = function()
            local LookVector2 = a1798.CFrame.LookVector
            local vector322 = Vector3.new(LookVector2.X, 0, LookVector2.Z)
            return a1798.Position + (vector322.Magnitude > 0.01 and vector322.Unit or Vector3.new(0, 0, -1)) * a2256
          end
          v1013(fn654(), a435)
          local v1174 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
          if v1174 then
            v1174:SetStateEnabled(5, false)
            v1174:ChangeState(3)
          end
          newResult61.attachLock =
            v967.RenderStepped:Connect(__NATIVE[113](sResult7, LocalPlayer21, a386, fn654, __L3.fn612, a1798, __L2.fn528))
        end
        __L3.fn614 = function()
          newResult61.attachLock = nil
        end
        __L3.fn615 = function(a1799, a2257, a387, a436)
          __L3.fn613(a1799, a2257, true, a436)
          local num356 = 0
          while true do
            if not (tbl303[1] and num356 < a387) then
              break
            end
            if not a1799.Parent or math.abs(a1799.Position.Y - num267) > num268 then
              break
            end
            task.wait(0.05)
            num356 += 0.05
          end
          __L3.fn614()
        end
        __L3.fn616 = function()
          local res213 = fn574("Block")
          if res213 then
            pcall(function()
              res213:FireServer(false)
            end)
          end
        end
        __L3.fn617 = function()
          local res214 = fn574("Unblock")
          if res214 then
            pcall(function()
              res214:FireServer({})
            end)
          end
        end
        __L3.fn618 = function(a1800, a2258)
          local num357 = 0
          while true do
            if not (tbl303[1] and __L3.fn611(a1800, a2258) == 0 and num357 < 30) then
              break
            end
            task.wait(0.5)
            num357 += 0.5
          end
          local Live14 = v966:FindFirstChild("Live")
          if not Live14 then
            return
          end
          local num358 = 0
          local num359 = 0
          local v1175
          local getChildrenResult51, v1176, v1177 = Live14:GetChildren()
          for k271, v1178 in getChildrenResult51, v1176, v1177 do
            if string.find(v1178.Name, "Zombie Scroom") then
              local HumanoidRootPart13 = v1178:FindFirstChild("HumanoidRootPart")
              local Humanoid16 = v1178:FindFirstChildOfClass("Humanoid")
              if
                HumanoidRootPart13
                and Humanoid16
                and Humanoid16.Health > 0
                and math.abs(HumanoidRootPart13.Position.Y - num267) <= num268
              then
                num358 += 1
                local Magnitude15 = (HumanoidRootPart13.Position - a1800).Magnitude
                if not v1175 or Magnitude15 < v1175 then
                  v1175 = Magnitude15
                end
                if Magnitude15 <= a2258 then
                  num359 += 1
                end
              end
            end
          end
          fn534("gather: %d live scrooms, %d within %d studs (nearest %.0f)", num358, num359, a2258, v1175 or -1)
          local tbl345 = {}
          local getChildrenResult52, v1179, v1180 = Live14:GetChildren()
          for k272, v1181 in getChildrenResult52, v1179, v1180 do
            if string.find(v1181.Name, "Zombie Scroom") then
              local HumanoidRootPart14 = v1181:FindFirstChild("HumanoidRootPart")
              local Humanoid17 = v1181:FindFirstChildOfClass("Humanoid")
              if
                HumanoidRootPart14
                and Humanoid17
                and Humanoid17.Health > 0
                and (HumanoidRootPart14.Position - a1800).Magnitude <= a2258
                and math.abs(HumanoidRootPart14.Position.Y - num267) <= num268
              then
                table.insert(tbl345, HumanoidRootPart14)
              end
            end
          end
          local tbl346 = {}
          local v1182 = a1800
          while true do
            if not (#tbl346 < 4 and #tbl345 > 0) then
              break
            end
            local v1183
            local huge4 = math.huge
            for k273, v1184 in tbl345 do
              local Magnitude16 = (v1184.Position - v1182).Magnitude
              if Magnitude16 < huge4 then
                huge4 = Magnitude16
                v1183 = k273
              end
            end
            if not v1183 then
              break
            end
            local removeResult = table.remove(tbl345, v1183)
            table.insert(tbl346, removeResult)
            v1182 = removeResult.Position
          end
          table.sort(tbl346, function(a1801, a2259)
            return (a1801.Position - vector35).Magnitude > (a2259.Position - vector35).Magnitude
          end)
          fn534("gather: pulling %d scrooms", #tbl346)
          __L2.fn527()
          __L3.fn616()
          for k274, v1185 in tbl346 do
            if not tbl303[1] then
              break
            end
            if v1185.Parent and math.abs(v1185.Position.Y - num267) <= num268 then
              __L3.fn615(v1185, 18.5, 1.8, k274 == 1 and num272 or num271)
            end
          end
          __L3.fn617()
          return tbl346
        end
        __L3.tbl321 = {
          Vector3.new(6102, 1289, 127),
          Vector3.new(5925, 1287, 407),
          Vector3.new(5832, 1287, 663),
          Vector3.new(5816, 1241, 907),
          Vector3.new(5812, 1132, 937),
        }
        __L3.fn619 = function(a1802)
          return function(a1803)
            local tbl347 = {}
            local Live15 = v966:FindFirstChild("Live")
            if not Live15 then
              return tbl347
            end
            local getChildrenResult53, v1186, v1187 = Live15:GetChildren()
            for k275, v1188 in getChildrenResult53, v1186, v1187 do
              if string.find(v1188.Name, "Shrieker") then
                local MonsterInfo2 = v1188:FindFirstChild("MonsterInfo")
                local v1189 = MonsterInfo2 and MonsterInfo2:FindFirstChild("Master")
                local HumanoidRootPart15 = v1188:FindFirstChild("HumanoidRootPart")
                local Humanoid18 = v1188:FindFirstChildOfClass("Humanoid")
                if v1189 and v1189.Value == a1802 and HumanoidRootPart15 and Humanoid18 and Humanoid18.Health > 0 then
                  table.insert(tbl347, HumanoidRootPart15)
                end
              end
            end
            return tbl347
          end
        end
        __L3.fn620 = function(a1804)
          local Live16 = v966:FindFirstChild("Live")
          if not Live16 then
            return true
          end
          local getChildrenResult54, v1190, v1191 = Live16:GetChildren()
          for k276, v1192 in getChildrenResult54, v1190, v1191 do
            if string.find(v1192.Name, "Shrieker") then
              local MonsterInfo3 = v1192:FindFirstChild("MonsterInfo")
              local v1193 = MonsterInfo3 and MonsterInfo3:FindFirstChild("Master")
              local Humanoid19 = v1192:FindFirstChildOfClass("Humanoid")
              if v1193 and v1193.Value == a1804 and Humanoid19 and Humanoid19.Health >= 10 then
                return false
              end
            end
          end
          return true
        end
        __L3.fn621 = function()
          local Live17 = v966:FindFirstChild("Live")
          if not Live17 then
            return nil
          end
          local v1194 = __L3.bladeStayHere()
          local getPlayersResult24, v1195, v1196 = getResult23:GetPlayers()
          for k277, v1197 in getPlayersResult24, v1195, v1196 do
            if v1197 ~= LocalPlayer21 and (v1194 or __L2.fn512(a1723, v1197)) then
              local Character62 = v1197.Character
              local Backpack24 = v1197:FindFirstChildOfClass("Backpack")
              if
                (Character62 and Character62:FindFirstChild("Vocare") or Backpack24 and Backpack24:FindFirstChild("Vocare")) and Character62
              then
                local getChildrenResult55, v1198, v1199 = Live17:GetChildren()
                for k278, v1200 in getChildrenResult55, v1198, v1199 do
                  if string.find(v1200.Name, "Shrieker") then
                    local MonsterInfo4 = v1200:FindFirstChild("MonsterInfo")
                    local v1201 = MonsterInfo4 and MonsterInfo4:FindFirstChild("Master")
                    local Variables = v1200:FindFirstChild("Variables")
                    local v1202 = Variables and Variables:FindFirstChild("Command")
                    local HumanoidRootPart16 = v1200:FindFirstChild("HumanoidRootPart")
                    if
                      v1201
                      and v1201.Value == Character62
                      and v1202
                      and v1202.Value == "HALT"
                      and HumanoidRootPart16
                      and (HumanoidRootPart16.Position - Vector3.new(5781, 1132, 909)).Magnitude <= 300
                    then
                      return v1197
                    end
                  end
                end
              end
            end
          end
          return nil
        end
        __L3.fn622 = function(a1805)
          fn534("P5: section A1 (allied necro shriekers)")
          local Character63 = a1805.Character
          __L3.setInn("Castle Sanctuary")
          fn580(__L3.tbl321)
          -- Entry gate only: after it passes, damage never restarts this wait.
          local farmCenter = Vector3.new(5781, 1132, 909)
          local reportedWait = false
          while tbl303[1] do
            local live = v966:FindFirstChild("Live")
            local nearbyCount = 0
            local allFull = true
            if live then
              for _, mob in live:GetChildren() do
                if string.find(mob.Name, "Shrieker") then
                  local root = mob:FindFirstChild("HumanoidRootPart")
                  local humanoid = mob:FindFirstChildOfClass("Humanoid")
                  if root and (root.Position - farmCenter).Magnitude <= 300 then
                    nearbyCount += 1
                    if not humanoid or humanoid.MaxHealth <= 0 or humanoid.Health < humanoid.MaxHealth then
                      allFull = false
                    end
                  end
                end
              end
            end
            if nearbyCount > 0 and allFull then
              fn534("P5: all %d nearby shriekers are full HP, starting farm", nearbyCount)
              break
            end
            if not reportedWait then
              reportedWait = true
              fn534("P5: waiting for nearby shriekers to reach full HP before starting")
              fn535("Waiting for all nearby Shriekers to reach full HP")
            end
            task.wait(0.25)
          end
          if not tbl303[1] then
            return false
          end
          __L3.fn610()
          __L3.fn594(function()
            return __L3.fn620(Character63)
          end, 1.8, __L3.fn619(Character63), 3.5)
          return tbl303[1] and __L3.fn620(Character63)
        end
        __L3.tbl322 = {
          Vector3.new(2951, 264, -39),
          Vector3.new(2964, 221, -149),
          Vector3.new(2871, 233, -578),
          Vector3.new(2852, 286, -621),
          Vector3.new(2848, 361, -632),
          Vector3.new(2786, 361, -742),
          Vector3.new(2760, 399, -736),
          Vector3.new(2618, 399, -1152),
          Vector3.new(2285, 398, -1457),
          Vector3.new(2223, 387, -1720),
        }
        __L3.vector315 = Vector3.new(2084, 155, -2299)
        __L3.vector316 = Vector3.new(2086, 175, -2258)
        __L3.fn623 = function()
          return CFrame.new(
            2000.60046,
            143.362045,
            -2276.92163,
            0.999785006,
            5.48514656e-08,
            -0.0207340494,
            -5.39884475e-08,
            1,
            4.21831174e-08,
            0.0207340494,
            -4.10546477e-08,
            0.999785006
          )
        end
        __L3.tbl323 = {
          { Vector3.new(2118, num273, -2276), 1.2 },
          { Vector3.new(2098, num273, -2282), 1.2 },
          { Vector3.new(2080, num273, -2334), 1.2 },
          { Vector3.new(2002, num273, -2339), 1.2 },
        }
        __L3.vector317 = Vector3.new(2128, 155, -1889)
        __L3.tbl324 = { Vector3.new(2120, 141, -2087), Vector3.new(2117, 175, -2143), Vector3.new(2081, 175, -2244) }
        __L3.tbl325 = {
          Vector3.new(2017, 147, -2244),
          Vector3.new(2094, 141, -2104),
          Vector3.new(2133, 141, -1966),
          Vector3.new(2111, 172, -1974),
          Vector3.new(2135, 155, -1889),
        }
        __L3.tbl326 = {
          Vector3.new(2144, 160, -1938),
          Vector3.new(2120, 141, -2087),
          Vector3.new(2117, 180, -2090),
          Vector3.new(2117, 175, -2143),
          Vector3.new(2126, 175, -2189),
          Vector3.new(2127, 175, -2226),
          Vector3.new(2081, 175, -2244),
        }
        __L3.fn624 = function()
          if not near(vector35, 600) then
            fn534("A2: retreat skipped, we are nowhere near the pit")
            return
          end
          fn579(Vector3.new(1976, 437, -2253))
          repeat
            task.wait(0.3)
            local v1203 = LocalPlayer21.Character
              and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
              and LocalPlayer21.Character.Humanoid.Health > 75
            if v1203 then
              continue
            end
            v1203 = not tbl303[1]
          until v1203
          local vector323 = Vector3.new(1991, num267, -2311)
          v1013(vector323)
          fn499(LocalPlayer21.Character)
          local v1204 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
          if v1204 then
            local v1205 = v1204
            v1205:ChangeState(Enum.HumanoidStateType.Running)
          end
          __L3.fn607(vector323, 3)
          v1013(__L3.fn623())
        end
        a1723.State.progA2Fallen = function()
          local v1206 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not v1206 or v1206.Position.Y >= num308 then
            return false
          end
          fn534("A2: dropped to Y %.0f, under the pit floor - climbing back to re-pull", v1206.Position.Y)
          v1013(__L3.fn623())
          fn499(LocalPlayer21.Character)
          __L3.fn607(vector35, 1)
          return true
        end
        __L3.fn625 = function(a1806, a2260)
          local Live18 = v966:FindFirstChild("Live")
          if not Live18 then
            return false
          end
          local getChildrenResult56, v1207, v1208 = Live18:GetChildren()
          for k279, v1209 in getChildrenResult56, v1207, v1208 do
            if string.find(v1209.Name, "Zombie Scroom") then
              local HumanoidRootPart17 = v1209:FindFirstChild("HumanoidRootPart")
              local Humanoid20 = v1209:FindFirstChildOfClass("Humanoid")
              if
                HumanoidRootPart17
                and Humanoid20
                and Humanoid20.Health > 0
                and math.abs(HumanoidRootPart17.Position.Y - num267) <= num268
              then
                local num360 = HumanoidRootPart17.Position - a1806.Position
                if num360.Magnitude > 0 and num360.Magnitude <= a2260 and num360.Unit:Dot(a1806.LookVector) < -0.3 then
                  return true
                end
              end
            end
          end
          return false
        end
        __L3.fn626 = function(a1807, a2261, a388)
          fn536(true)
          __L2.fn527()
          local fn655 = function()
            newResult61.standLock = v967.RenderStepped:Connect(__NATIVE[114](LocalPlayer21, a1807, __L2.fn528))
          end
          fn655()
          local tickResult10 = tick()
          local v1210
          local flag63 = false
          while true do
            if not (tbl303[1] and not a1723.State.a2FleeDue() and tick() - tickResult10 < 200) then
              break
            end
            if __L3.fn611(a1807.Position, 20, num267) == 0 then
              v1210 = v1210 or tick()
              if tick() - v1210 > 1.5 then
                break
              end
            else
              v1210 = nil
            end
            if __L3.fn625(a1807, 15) then
              newResult61.standLock = nil
              v1013(Vector3.new(2002, 155, -2339))
              __L3.fn607(Vector3.new(2002, 155, -2339), 1.5)
              fn655()
            end
            if a2261 and tick() - tickResult10 > 4 then
              local v1211 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
              if v1211 and v1211.Health < num270 and fn537() then
                newResult61.standLock = nil
                a2261()
                fn655()
              end
            end
            if not flag63 and __L3.fn611(a1807.Position, num269, num267) > 0 then
              flag63 = true
            end
            if __L2.fn526() then
              if a388 then
                a388 = false
                fn534("P5: CanClimb reached, switching to the sword")
              end
              __L3.fn610()
            end
            if a388 then
              local Character64 = LocalPlayer21.Character
              local v1212 = Character64 and Character64:FindFirstChildOfClass("Humanoid")
              if v1212 and Character64:FindFirstChildOfClass("Tool") then
                v1212:UnequipTools()
              end
              local v1213 = Character64 and Character64:FindFirstChild("Mana")
              local mana4 = a1723.State.mana
              if __L2.fn525() and v1213 ~= nil and mana4 ~= nil and mana4.available() and v1213.Value <= 2 then
                mana4.chargeUntil(100, function()
                  return tbl303[1] and not __L2.fn526()
                end)
              end
              if flag63 then
                fn578(3)
              end
            elseif flag63 then
              fn578(3)
            end
            local num361 = 0
            while true do
              if not (tbl303[1] and num361 < 0.5) then
                break
              end
              task.wait(0.1)
              num361 += 0.1
            end
          end
          newResult61.standLock = nil
          __L2.fn529()
          fn536(false)
        end
        __L3.fn627 = function(a1808, a2262, a389, a437)
          v1013(a1808, a389, not a437)
          fn499(LocalPlayer21.Character)
          __L3.fn607(a1808, a2262)
        end
        __L3.fn628 = function(a1809)
          local res215 = __L3.fn618(__L3.vector316, a1809)
          if not tbl303[1] then
            return res215
          end
          local num362 = 0
          for k280, v1214 in res215 or {} do
            if not fn500(v1214) and math.abs(v1214.Position.Y - num267) <= num268 then
              num362 += 1
            end
          end
          if num362 == 0 then
            fn534("A2: nothing survived the pull, skipping the lead")
            return {}
          end
          for k281, v1215 in __L3.tbl323 do
            if not tbl303[1] then
              return
            end
            if a1723.State.progA2Fallen() then
              return {}
            end
            __L3.fn627(v1215[1], v1215[2], num271, k281 == 1)
          end
          if not tbl303[1] then
            return
          end
          __L3.fn627(Vector3.new(2000, num273, -2312), 3, num271)
          return res215
        end
        __L3.fn629 = function(a1810, a2263)
          local res216 = __L3.fn623()
          local num363 = 0
          local num364 = 0
          local tbl348 = {}
          for i58 = 1, 4 do
            if not tbl303[1] or a1723.State.a2FleeDue() then
              return num363, num364
            end
            a1723.State.progA2Fallen()
            local num365 = 0
            while true do
              if not (tbl303[1] and __L3.fn611(__L3.vector316, a1810, num267) == 0 and num365 < 1.5) then
                break
              end
              task.wait(0.15)
              num365 += 0.15
            end
            if __L3.fn611(__L3.vector316, a1810, num267) == 0 then
              fn534("A2: nothing in the pit, skipping the gather")
              return num363, num364
            end
            local res217 = __L3.fn628(a1810)
            if not tbl303[1] then
              return num363, num364
            end
            local tbl349 = {}
            local tbl350 = {}
            local connectResult10 = v967.Heartbeat:Connect(__NATIVE[115](num299, num301, LocalPlayer21, v966, { 0 }, tbl350, tbl349))
            local v1216 = a2263 and not __L2.fn526()
            if v1216 then
              local v1217 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
              if v1217 then
                v1217:UnequipTools()
              end
            else
              __L3.fn610()
            end
            __L3.fn626(v1216 and res216 + res216.LookVector * num296 or res216, __L3.fn624, v1216)
            if not (a2263 and not __L2.fn526()) then
              local num366 = 0
              while true do
                if not (tbl303[1] and __L3.fn611(res216.Position, 50, num267) > 0 and num366 < 4) then
                  break
                end
                if __L3.fn611(res216.Position, num300, num267) == 0 then
                  __L3.fn628(a1810)
                end
                if not tbl303[1] then
                  break
                end
                __L3.fn626(res216, __L3.fn624, false)
                num366 += 1
              end
            end
            pcall(function()
              connectResult10:Disconnect()
            end)
            local Live19 = v966:FindFirstChild("Live")
            local num367 = 0
            local num368 = 0
            local tbl351 = {}
            for k282, v1218 in tbl349 do
              num368 += 1
              if tbl350[k282] or k282.Parent ~= Live19 or v1218.Health <= num301 then
                if not tbl348[k282] then
                  tbl348[k282] = true
                  num367 += 1
                end
              else
                table.insert(tbl351, string.format("%.0f", v1218.Health))
              end
            end
            num364 += num368
            num363 += num367
            fn534(
              "A2: round %d engaged %d (picked %d), %d dead, %d alive within 50 (hp left: %s)",
              i58,
              num368,
              res217 and #res217 or 0,
              num367,
              __L3.fn611(res216.Position, 50, num267),
              #tbl351 > 0 and table.concat(tbl351, ", ") or "none"
            )
          end
          return num363, num364
        end
        __L3.fn630 = function(a1811, a2264)
          __L3.fn616()
          local v1219 = a2264 and v966:FindFirstChild("Live")
          local flag64 = false
          local v1220 = v1219
            and v1219.ChildAdded:Connect(function(a1812)
              if string.find(a1812.Name, "Zombie Scroom") then
                flag64 = true
              end
            end)
          local num369 = 0
          while true do
            if not (tbl303[1] and num369 < a1811) then
              if v1220 then
                pcall(function()
                  v1220:Disconnect()
                end)
              end
              __L3.fn617()
              return
            end
            task.wait(0.25)
            num369 += 0.25
            if flag64 then
              flag64 = false
              task.wait(1.5)
              num369 += 1.5
              if __L3.fn611(__L3.vector316, num295, num267) > 0 then
                break
              end
            end
          end
          fn534("A2: scrooms respawned, going down early")
          if v1220 then
            pcall(function()
              v1220:Disconnect()
            end)
          end
          __L3.fn617()
        end
        __L3.fn631 = function()
          fn534("P5: section A2 (zombie scrooms)")
          tbl308[1] = tbl308[1] or {}
          if not tbl308[1].a2resume then
            __L3.setInn("Oresfall")
            local v1221 = tbl308[1].done and tbl308[1].done.p5_dormin
            fn545("p5_dormin", function()
              fn580({ Vector3.new(2955, 257, -26), Vector3.new(2848, 256, 73), Vector3.new(2852, 287, 76) })
              return fn589("Dormin", Vector3.new(2852, 287, 76), { "Of course." }, tbl272, 5)
            end)
            a1723.State.progWaitDanger()
            if not v1221 then
              fn586()
            end
            fn580(__L3.tbl322)
          end
          tbl308[1].a2resume = nil
          if not __L2.fn526() then
            fn534("P5: no CanClimb yet, punching until the bar is up and CanClimb lands (bar %s)", __L2.fn525() and "up" or "hidden")
            __L2.fn522("no CanClimb yet, punching scrooms for mana")
          end
          tbl308[1].a2kills = tonumber(tbl308[1].a2kills) or 0
          local ok122 = true
          local num370 = 0
          local num371 = 0
          local flag65 = false
          local flag66 = false
          while true do
            local item54, tonumber_, v1222
            if not (tbl303[1] and tbl308[1].a2kills < num297) then
              item54 = tbl303[1]
              if item54 then
                tonumber_ = tonumber
                v1222 = tonumber_(tbl308[1].a2kills) or 0 or 0 or 0 or 0
                item54 = v1222 >= num297
              end
              if item54 then
                tbl308[1].a2kills = nil
                fn542()
              end
              return item54
            end
            if a1723.State.a2FleeDue() then
              fn534("P5: players closed in on the pit, going straight up to the perch")
              tbl308[1].a2resume = true
              fn542()
              local res218 = __L2.fn513(a1723, fn549, vector310, num302)
              local item55 = tbl268[num306]
              v1013(item55)
              local num372 = 0
              while true do
                if not (tbl303[1] and fn537() and num372 < num307) then
                  break
                end
                __L3.fn607(item55, 2)
                num372 += 2
              end
              if fn537() then
                fn534("P5: still tagged after %ds on the perch, hopping anyway", num372)
              end
              if not fn558("players closed in on the A2 pit", vector310, num302, "@here", res218) then
                fn534("P5: nothing hopped, coming down the high route to the stage")
                for i59 = num306 + 1, #tbl268 do
                  if not tbl303[1] then
                    break
                  end
                  v1013(tbl268[i59])
                end
                while true do
                  if not (tbl303[1] and a1723.State.a2FleeDue()) then
                    break
                  end
                  task.wait(2)
                end
              end
              return false
            end
            fn534("P5: %d of %d zombie scrooms killed", tbl308[1].a2kills, num297)
            local cond17 = not __L2.fn526()
            local v1223 = ok122
            if ok122 then
              ok122 = false
              fn580({ __L3.vector317 })
              __L3.fn630(flag66 and 16 or 8, flag66)
              if not tbl303[1] then
                item54 = tbl303[1]
                if item54 then
                  tonumber_ = tonumber
                  v1222 = tonumber_(tbl308[1].a2kills) or 0 or 0 or 0 or 0
                  item54 = v1222 >= num297
                end
                if item54 then
                  tbl308[1].a2kills = nil
                  fn542()
                end
                return item54
              end
            else
              fn580(__L3.tbl325)
              __L3.fn630(16, true)
              if not tbl303[1] then
                item54 = tbl303[1]
                if item54 then
                  tonumber_ = tonumber
                  v1222 = tonumber_(tbl308[1].a2kills) or 0 or 0 or 0 or 0
                  item54 = v1222 >= num297
                end
                if item54 then
                  tbl308[1].a2kills = nil
                  fn542()
                end
                return item54
              end
            end
            if not tbl303[1] then
              item54 = tbl303[1]
              if item54 then
                tonumber_ = tonumber
                v1222 = tonumber_(tbl308[1].a2kills) or 0 or 0 or 0 or 0
                item54 = v1222 >= num297
              end
              if item54 then
                tbl308[1].a2kills = nil
                fn542()
              end
              return item54
            end
            if not flag65 then
              flag65 = true
              if fn583(__L3.vector315, num298) then
                fn534("P5: players at the pit, leaving before we descend")
                fn580({ __L3.vector317 })
                tbl308[1].a2resume = true
                fn542()
                if not fn558("players at the A2 pit", __L3.vector315, num298) then
                  fn534("P5: nothing hopped, holding at the stage until the pit clears")
                  while true do
                    if not (tbl303[1] and fn583(__L3.vector315, num298)) then
                      break
                    end
                    task.wait(2)
                  end
                end
                return false
              end
            end
            fn580(v1223 and __L3.tbl324 or __L3.tbl326)
            local res219, v1224 = __L3.fn629(num295, cond17)
            local item56 = tbl308[1]
            item56.a2kills += res219
            fn542()
            if v1224 > 0 and res219 == 0 then
              num371 += 1
              if num371 >= num287 then
                __L2.fn520(string.format("%s pulled scrooms %dx without a kill, check it has a sword", fn554(), num371))
                fn544("A2 dealt no damage for " .. num371 .. " rounds")
                return
              end
            else
              num371 = 0
            end
            if v1224 == 0 then
              num370 += 1
              if num370 >= 2 then
                fn580({ __L3.vector317 })
                tbl308[1].a2resume = true
                fn542()
                if fn558("A2 pit stayed empty") then
                  break
                end
                fn534("P5: nothing hopped, waiting at the stage for the pit to repopulate")
                __L3.fn630(30, true)
                num370 = 0
                ok122 = true
                flag66 = true
              else
                fn534("A2: pit empty, waiting at the stage for a respawn")
                ok122 = true
                flag66 = true
              end
            else
              num370 = 0
              flag66 = false
            end
          end
          return false
        end
        __L3.fn632 = function()
          if not fn591("Sword") then
            fn534("P5: no sword in the pack, dropping back to P4 to buy one")
            fn543("P4")
            return
          end
          local Thrown7 = v966:FindFirstChild("Thrown")
          if Thrown7 then
            local part2 = Instance.new("Part")
            part2.Name = "Part"
            part2.Anchored = true
            part2.CanCollide = true
            part2.Size = Vector3.new(579, 1, 457)
            part2.CFrame = CFrame.new(2078.95801, 110.362061, -2296.52441)
            part2.Color = Color3.fromRGB(0, 0, 255)
            part2.Material = Enum.Material.Neon
            part2.Parent = Thrown7
            newResult61.p5part = part2
          end
          local res220 = __L3.fn621()
          local res221
          if res220 then
            res221 = __L3.fn622(res220)
          else
            res221 = __L3.fn631()
          end
          newResult61.p5part = nil
          if not res221 then
            fn534("P5: the XP farm did not finish, staying on P5")
            return
          end
          fn543("P6")
        end
        __L3.fn633 = function()
          tbl308[1] = tbl308[1] or {}
          tbl308[1].done = tbl308[1].done or {}
          local done = tbl308[1].done
          local tbl352 = {}
          if not done.p6_alana and not fn591("Health Potion") then
            table.insert(tbl352, "Health Potion")
          end
          if not done.p6_kothe and not fn591("Liquid Wisdom") then
            table.insert(tbl352, "Liquid Wisdom")
          end
          if not fn591("Ice Protection") then
            table.insert(tbl352, "Ice Protection")
          end
          if #tbl352 > 0 then
            __L2.fn520("missing " .. table.concat(tbl352, ", ") .. ", give them and Start again")
            __L2.fn516()
            pcall(function()
              local res222 = requestRemote("ReturnToMenu")
              if res222 then
                res222:InvokeServer()
              end
            end)
            fn544("missing potions for P6: " .. table.concat(tbl352, ", "))
            return
          end
          if __L3.bladeEnabled() then
            if not __L3.bladeAlfricTrain() then return end
          else
          local num373 = 0
          while true do
            if not (tbl303[1] and #__L2.fn502(tbl271) > 0 and num373 < 6) then
              break
            end
            task.wait(0.25)
            num373 += 0.25
          end
          if #__L2.fn502(tbl271) == 0 then
            fn534("P6: Alfric already maxed, skipping")
          else
            fn534("P6: Alfric missing %s", table.concat(__L2.fn502(tbl271), ", "))
            if near(vector35, 600) then
              fn580({ Vector3.new(1965, 143, -2283), Vector3.new(1920, 205, -2237) })
            end
            __L3.setInn("Renova")
            fn545("alfric", function()
              fn580({ Vector3.new(-2068, 305, -634), Vector3.new(-1844, 252, -265), Vector3.new(-1805, 315, -227) })
              for i60 = 1, 8 do
                if not tbl303[1] or #__L2.fn502(tbl271) == 0 then
                  break
                end
                fn588("Alfric", Vector3.new(-1805, 315, -227), { "Yeah.", "I'll pay." })
                task.wait(0.4)
              end
              if #__L2.fn502(tbl271) > 0 then
                __L2.fn523("Alfric still owes " .. table.concat(__L2.fn502(tbl271), ", ") .. "")
                return false
              end
              return true
            end)
          end
          end
          if not (done.p6_dormin and done.p6_alana) then
            __L3.setInn("Oresfall")
            fn545("p6_dormin", function()
              fn580({ Vector3.new(2955, 257, -26), Vector3.new(2848, 256, 73), Vector3.new(2852, 287, 76) })
              return fn589("Dormin", Vector3.new(2852, 287, 76), { "Of course." }, tbl272, 5)
            end)
            if fn591("Health Potion") then
              fn545("p6_alana", function()
                fn580({ Vector3.new(2862, 255, 72), Vector3.new(2792, 252, -44), Vector3.new(2809, 303, -33) })
                for i61 = 1, 5 do
                  if not tbl303[1] or not fn591("Health Potion") then
                    break
                  end
                  local res223, v1226 = fn588(
                    "Alana",
                    Vector3.new(2809, 303, -33),
                    { "What's wrong?", "I'm here to help.", "I'm sorry to hear that.", "Of course." },
                    tbl274
                  )
                  if v1226 then
                    break
                  end
                  local res224, v1227, v1228 =
                    fn588("Alana", Vector3.new(2809, 303, -33), { "Would this potion be of any use?" }, tbl274, tbl275)
                  if v1228 then
                    break
                  end
                  if fn591("Health Potion") then
                    task.wait(1.5)
                  end
                end
                if fn591("Health Potion") then
                  __L2.fn523("Alana never took the Health Potion")
                  return false
                end
                return true
              end)
            elseif not done.p6_alana then
              __L2.fn522("skipped Alana: no Health Potion in the pack")
            end
          end
          if not done.p6_lachesis then
            __L3.setInn("Southern Sanctuary")
            fn545("p6_lachesis", function()
              fn580({ Vector3.new(-1291, 143, 323) })
              return fn589(
                "Lachesis",
                Vector3.new(-1291, 143, 323),
                { "What's the matter?", "It's no problem. Can I help?", "Is it a scroom?", "Glad to help." },
                tbl273,
                4
              )
            end)
          end
          local cond18 = #__L2.fn502(__L2.tbl279) == 0
          local vector324 = Vector3.new(1923, 258, -850)
          if done.p6_kothe and cond18 then
            fn534("P6: Kothe done and Frey maxed, skipping Central Sanctuary")
          else
            if not near(vector324, 150) then
              a1723.State.progWaitDanger()
              fn536(true)
              fn556(25, true)
              local menuTeleResult2 = vResult5.menuTele(vector324, function()
                return tbl303[1]
              end)
              fn536(false)
              if not menuTeleResult2 then
                if tbl303[1] then
                  fn558("the menu teleport to Central Sanctuary did not take")
                end
                return
              end
            end
            if not done.p6_kothe then
              local num374 = 0
              while true do
                if not (tbl303[1] and not fn591("Liquid Wisdom") and num374 < 10) then
                  break
                end
                task.wait(0.25)
                num374 += 0.25
              end
              if fn591("Liquid Wisdom") then
                fn545("p6_kothe", function()
                  fn580({ Vector3.new(1923, 258, -850) })
                  for i62 = 1, 5 do
                    if not tbl303[1] or not fn591("Liquid Wisdom") then
                      break
                    end
                    fn588(
                      "Kothe",
                      Vector3.new(1923, 258, -850),
                      { "What's wrong?", "Can I help?", "There's something else I can help with, then?" },
                      __L2.tbl277
                    )
                    local res225, v1229, v1230 = fn588("Kothe", Vector3.new(1923, 258, -850), { "Is this it?" }, __L2.tbl277, __L2.tbl276)
                    if v1230 then
                      break
                    end
                    if fn591("Liquid Wisdom") then
                      task.wait(1.5)
                    end
                  end
                  if fn591("Liquid Wisdom") then
                    __L2.fn523("Kothe never took the Liquid Wisdom")
                    return false
                  end
                  return true
                end)
              else
                __L2.fn522("skipped Kothe: no Liquid Wisdom in the pack")
              end
            end
            if not cond18 then
              fn545("frey", function()
                if __L3.bladeEnabled() then
                  if not __L3.bladeTrainerApproach("frey","Central Sanctuary",{Vector3.new(1921,258,-851),Vector3.new(1926,285,-864),Vector3.new(1905,285,-810),Vector3.new(1913,307,-813),Vector3.new(1955,309,-830)}) then return false end
                  return __L3.bladeTrainPurchase("frey","Frey",Vector3.new(1954,309,-833),{"Is there anything you can teach me?","I'll pay."},__L2.tbl279,3)
                end
                fn580({
                  Vector3.new(1921, 258, -851),
                  Vector3.new(1926, 285, -864),
                  Vector3.new(1905, 285, -810),
                  Vector3.new(1913, 307, -813),
                  Vector3.new(1955, 309, -830),
                })
                for i63 = 1, 8 do
                  if not tbl303[1] or #__L2.fn502(__L2.tbl279) == 0 then
                    break
                  end
                  fn588("Frey", Vector3.new(1954, 309, -833), { "Is there anything you can teach me?", "I'll pay." })
                  task.wait(0.4)
                end
                return #__L2.fn502(__L2.tbl279) == 0
              end)
              if tbl303[1] and #__L2.fn502(__L2.tbl279) > 0 and not (__L3.bladeEnabled() and tbl308[1].bladeTraining and tbl308[1].bladeTraining.frey and tbl308[1].bladeTraining.frey.confirmed>=3) then
                local concatResult2 = table.concat(__L2.fn502(__L2.tbl279), ", ")
                local v1225 = tonumber(getServerValue("Silver")) or 0
                if v1225 >= __L2.num309 then
                  __L2.fn520("Frey still owes " .. concatResult2 .. " (" .. tostring(v1225) .. " silver), hopping")
                  fn558("Frey did not teach " .. concatResult2)
                else
                  __L2.fn520("Frey still owes " .. concatResult2 .. ", only " .. tostring(v1225) .. " silver, stopping")
                  fn544("out of silver for Frey")
                end
                return
              end
            end
          end
          local fn656 = function()
            for k283, v1231 in { LocalPlayer21:FindFirstChildOfClass("Backpack"), LocalPlayer21.Character } do
              if v1231 then
                local getChildrenResult57, v1232, v1233 = v1231:GetChildren()
                for k284, v1234 in getChildrenResult57, v1232, v1233 do
                  if v1234.Name == "Turnip" then
                    return v1234
                  end
                end
              end
            end
            return nil
          end
          local fn657 = function(a1813)
            if fn656() then
              return true
            end
            local Backpack25 = LocalPlayer21:FindFirstChildOfClass("Backpack")
            local flag67 = false
            local v1235 = Backpack25
              and Backpack25.ChildAdded:Connect(function(a1814)
                if a1814.Name == "Turnip" then
                  flag67 = true
                end
              end)
            local num375 = 0
            while true do
              if not (tbl303[1] and not flag67 and num375 < (a1813 or 15)) then
                break
              end
              task.wait(0.2)
              num375 += 0.2
              flag67 = flag67 or fn656() ~= nil
            end
            if v1235 then
              v1235:Disconnect()
            end
            return flag67
          end
          if not (done.p6_draug and done.p6_dorgoth and done.p6_reynauld) then
            __L3.setInn("Castle Sanctuary")
            fn545("p6_draug", function()
              fn580({ Vector3.new(6145, 1344, 118) })
              return fn589("Draug", Vector3.new(6145, 1344, 118), { "Thank you." }, __L2.tbl278, 4)
            end)
            fn545("p6_dorgoth", function()
              local res226 = fn656()
              if res226 then
                fn534("P6: Turnip already held (%s in %s), skipping Dorgoth", res226.ClassName, res226.Parent and res226.Parent.Name or "?")
                return
              end
              fn580({ Vector3.new(6142, 1344, 93) })
              for i64 = 1, 2 do
                if not tbl303[1] or fn656() then
                  break
                end
                fn588("Dorgoth", Vector3.new(6142, 1344, 93), { "Alright." })
                fn657(15)
              end
              if not fn656() then
                __L2.fn523("Dorgoth did not hand over the Turnip")
                return false
              end
              return true
            end)
            fn545("p6_reynauld", function()
              fn580({
                Vector3.new(6380, 1334, -213),
                Vector3.new(6293, 1121, -459),
                Vector3.new(6294, 1039, -756),
                Vector3.new(6122, 1039, -755),
                Vector3.new(6090, 1067, -755),
                Vector3.new(5658, 1067, -1166),
                Vector3.new(5342, 1067, -1108),
                Vector3.new(4921, 1067, -861),
                Vector3.new(4953, 544, -900),
              })
              local res227, v1236, v1237 = fn588("Reynauld", Vector3.new(4953, 544, -900), { "Hello?", "Sir?" }, __L2.tbl283, __L2.tbl285)
              if not (v1237 or v1236) then
                __L2.fn523("Reynauld never collapsed, so the dagger was never handed over")
                return false
              end
              return true
            end)
          end
          if not done.p6_hespe then
            __L3.setInn("Southern Sanctuary")
            fn545("p6_hespe", function()
              fn580({ Vector3.new(-476, 169, 854), Vector3.new(-283, 491, 936) })
              local flag68 = false
              for i65 = 1, 3 do
                if not tbl303[1] then
                  return false
                end
                local res228, v1238, v1239, v1240 =
                  fn588("Hespe", Vector3.new(-283, 491, 936), { "A man told me to bring this to you.", "..." }, __L2.tbl283, __L2.tbl284)
                if v1238 or v1239 then
                  return true
                end
                flag68 = flag68 or v1240 ~= nil
                task.wait(1)
              end
              __L2.fn523(flag68 and "Hespe never gave his closing line" or "no dagger to hand over, Reynauld never gave it")
              return false
            end)
          end
          if not done.p6_brom then
            __L3.setInn("Wayside Inn")
            fn545("p6_brom", function()
              fn580({
                Vector3.new(1355, 144, 921),
                Vector3.new(1334, 146, 1622),
                Vector3.new(1366, 262, 1617),
                Vector3.new(1396, 287, 1710),
              })
              return fn589("Brom", Vector3.new(1396, 287, 1710), { "You're a merchant?", "If I see her." }, __L2.tbl290, 4)
            end)
          end
          fn545("p6_fir", function()
            __L3.setInn("Santorini")
            fn580({
              Vector3.new(1355, 431, 2998),
              Vector3.new(1419, 442, 3006),
              Vector3.new(1446, 456, 3006),
              Vector3.new(1521, 455, 2939),
            })
            return fn589("Fir", Vector3.new(1521, 455, 2939), {
              "What's wrong?",
              "Do you mean Brom?",
              "Yeah, I saw him earlier.",
              "He broke down. There will be a delay.",
            }, __L2.tbl291, 4)
          end)
          fn543("P7")
        end
        __L3.startMenu = vResult5.startMenu
        __L3.clickPlay = vResult5.clickPlay
        __L3.fn634 = function(a1815, a2265)
          a1723.State.progWaitDanger()
          fn536(true)
          local flag69 = false
          for i66 = 1, a2265 or 2 do
            if not tbl303[1] then
              break
            end
            fn556(25, true)
            flag69 = vResult5.menuTele(a1815, function()
              return tbl303[1]
            end)
            if flag69 then
              break
            end
          end
          fn536(false)
          return flag69
        end
        __L3.tbl327 = { Vector3.new(-45, 3777, 141), Vector3.new(155, 3777, 141), Vector3.new(177, 3777, 167) }
        __L3.tbl328 = {
          Vector3.new(215, 3777, 146),
          Vector3.new(351, 3777, 140),
          Vector3.new(351, 3776, 43),
          Vector3.new(351, 3760, 16),
          Vector3.new(415, 3760, 18),
          Vector3.new(416, 3735, -36),
        }
        __L3.tbl329 = {
          Vector3.new(421, 3738, -57),
          Vector3.new(469, 3716, -50),
          Vector3.new(467, 3709, -123),
          Vector3.new(517, 3706, -95),
          Vector3.new(515, 3703, -49),
          Vector3.new(508, 3703, -49),
        }
        __L3.tbl330 = {
          Vector3.new(6382, 1344, 80),
          Vector3.new(6479, 1402, 22),
          Vector3.new(6589, 1402, -141),
          Vector3.new(6754, 1402, -143),
          Vector3.new(6857, 1411, -164),
        }
        __L3.kheiAllowed=function()
          return __L3.kheiManualRequested==true or (Toggles8.ProgGoToKhei and Toggles8.ProgGoToKhei.Value==true) or false
        end
        __L3.fn635 = function(a1816, a2266, a390, shouldRun)
          local active=shouldRun or function() return tbl303[1] end
          local Requests10 = v970:FindFirstChild("Requests")
          local v1241 = a1816 and a1816:FindFirstChildWhichIsA("ClickDetector", true)
          if not (Requests10 and v1241 and fireclickdetector) then
            fn534(
              "spamFirstChoice: unavailable (requests=%s cd=%s fcd=%s)",
              tostring(Requests10 ~= nil),
              tostring(v1241 ~= nil),
              tostring(fireclickdetector ~= nil)
            )
            return
          end
          local num376 = 0
          local num377 = 0
          local tbl353 = {}
          local getChildrenResult58, v1242, v1243 = Requests10:GetChildren()
          for k285, v1244 in getChildrenResult58, v1242, v1243 do
            if v1244:IsA("RemoteEvent") then
              table.insert(
                tbl353,
                v1244.OnClientEvent:Connect(function(a1817)
                  if not active() then return end
                  if type(a1817) ~= "table" or a1817.choices == nil and a1817.speaker == nil then
                    return
                  end
                  num377 = tick()
                  local v1246 = type(a1817.choices) == "table" and a1817.choices[1] or nil
                  local v1247 = type(v1246) == "string" and { choice = v1246 }
                    or type(a1817.endchoice) == "string" and { exit = true }
                    or nil
                  if v1247 then
                    num376 += 1
                    task.delay(num291 + math.random() * num292, function()
                      if not active() then return end
                      pcall(function()
                        v1244:FireServer(v1247)
                      end)
                    end)
                  end
                end)
              )
            end
          end
          fireclickdetector(v1241)
          local tickResult11 = tick()
          while true do
            if not (active() and num376 < (a2266 or 15) and tick() - tickResult11 < (a390 or 25)) then
              break
            end
            task.wait(0.5)
            if active() and tick() - num377 > 3 then
              fireclickdetector(v1241)
              num377 = tick()
            end
          end
          fn534("spamFirstChoice: %d choices answered", num376)
          for k286, v1245 in tbl353 do
            pcall(function()
              v1245:Disconnect()
            end)
          end
        end
        a1723.State.progYaaldaHandoff = function()
          if not __L3.kheiAllowed() or not tbl303[1] then return end
          local token={};__L3.kheiAttempt=token;__L3.kheiHandoffActive=true
          local function active() return tbl303[1] and __L3.kheiAttempt==token and __L3.kheiAllowed() end
          for i67 = 1, num275 do
            if not active() then
              return
            end
            local NPCs4 = v966:FindFirstChild("NPCs")
            local v1248 = NPCs4 and NPCs4:FindFirstChild("Yaalda")
            if v1248 and v1248:FindFirstChild("HumanoidRootPart") then
              fn534("finish: Yaalda handoff attempt %d/%d", i67, num275)
              if
                __L3.fn634(function()
                  local NPCs5 = v966:FindFirstChild("NPCs")
                  local v1249 = NPCs5 and NPCs5:FindFirstChild("Yaalda")
                  local v1250 = v1249 and v1249:FindFirstChild("HumanoidRootPart")
                  return v1250 and v1250.Position or nil
                end, 1)
              then
                if active() then __L3.fn635(v1248, 15, 75,active) end
              else
                fn534("finish: the teleport to Yaalda did not take, not clicking from here")
              end
            else
              fn534("finish: Yaalda not in workspace.NPCs (attempt %d/%d)", i67, num275)
            end
            task.wait(3)
            if i67 >= num282 and fn494() > num283 then
              fn534("finish: %.0fms ping after %d tries - hopping to retry the handoff elsewhere", fn494(), i67)
              if fn558(string.format("%.0fms ping stalling the Khei handoff", fn494())) then
                return
              end
            end
          end
          if not active() then
            return
          end
          __L2.fn521(string.format("Khei: Yaalda never took the handoff after %d tries", num275))
          qResult3.remove("khei_run")
          qResult3.remove("khei_handoff_servers")
          fn533()
          if v1009 then
            v1009()
          end
        end
        a1723.State.progKheiHandoff = function(sameServerResume)
          if not __L3.kheiAllowed() then
            qResult3.remove("khei_run");qResult3.remove("khei_handoff_servers")
            return
          end
          if tbl303[1] then
            return
          end
          local num378 = (tonumber(qResult3.get("khei_handoff_servers")) or 0) + (sameServerResume and 0 or 1)
          qResult3.set("khei_handoff_servers", num378)
          if num378 > num276 then
            fn534("khei: handoff gave up after %d servers", num378 - 1)
            qResult3.remove("khei_run")
            qResult3.remove("khei_handoff_servers")
            task.spawn(function()
              __L2.fn521(string.format("Khei: could not hand off to Yaalda across %d servers", num276))
            end)
            return
          end
          tbl303[1] = true
          tbl304[1] = false
          fn531(true)
          fn532(false)
          fn568()
          __L3.bladeCoreRunning=true
          task.spawn(function()
            local ok,message=pcall(a1723.State.progYaaldaHandoff)
            __L3.bladeCoreRunning=false
            if not ok and not __L3.bladeMenuPause then
              fn534("Yaalda handoff stopped: %s",tostring(message));v1009(true)
            end
          end)
        end
        __L3.fn636 = function()
          if not tbl303[1] then
            return
          end
          if not __L2.fn504(__L2.tbl282, num290) then
            fn534("P7: no Jagen training, refusing to mark DONE")
            task.spawn(function()
              __L2.fn521("no Jagen training, stopped at P7")
            end)
            if v1009 then
              v1009()
            end
            return
          end
          local v1251 = Toggles8.ProgGoToKhei and Toggles8.ProgGoToKhei.Value
          if v1251 and not __L3.bladeEnabled() and not fn492() then
            fn534("P7: no Mana Dash, refusing the Khei handoff")
            task.spawn(function()
              __L2.fn521("no Mana Dash, stopping")
            end)
            if v1009 then
              v1009()
            end
            return
          end
          tbl308[1] = tbl308[1] or {}
          local res229 = getServerValue("Silver")
          if v1251 then
            local res230, v1252 = __L2.fn506(5)
            __L2.fn524("Gaia complete", string.format("%s finished Gaia, heading to Khei via Ya'alda", fn554()))
          else
            pcall(
              __L2.scopedResult.embedWith,
              "@everyone",
              fn555("Auto Progression complete", 5763719, {
                string.format("**Day:** `%s`", tostring(getServerValue("DaysSurvived"))),
                "**Next:** `returning to menu`",
              }, {
                {
                  name = "Time Taken",
                  value = __L2.fn510(tbl308[1].startClock, tbl308[1].kheiClock),
                  inline = true,
                },
                { name = "Silver", value = __L2.fn511(tbl308[1].startSilver, res229), inline = true },
              })
            )
          end
          tbl308[1].phase = "DONE"
          if v1251 then
            tbl308[1].kheiClock = tbl308[1].kheiClock or os.time()
          end
          fn542()
          qResult3.remove("progression_active")
          fn573()
          if v1251 then
            fn534("finish: auto-going to Khei via Yaalda")
            qResult3.set("khei_run", "true")
            a1723.State.progYaaldaHandoff()
            return
          end
          local progKillWhenClearResult2 = a1723.State.progKillWhenClear()
          if not progKillWhenClearResult2 then
            fn534("finish: no character to reset, leaving it standing")
            fn533()
            tbl303[1] = false
            return
          end
          local num379 = 0
          repeat
            task.wait(0.3)
            num379 += 0.3
            local v1253 = LocalPlayer21.Character
                and LocalPlayer21.Character ~= progKillWhenClearResult2
                and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              or num379 > 15
            if v1253 then
              continue
            end
            v1253 = not tbl303[1]
          until v1253
          __L2.fn516()
          local res231 = requestRemote("ReturnToMenu")
          if res231 then
            pcall(function()
              res231:InvokeServer()
            end)
          end
          fn533()
          tbl303[1] = false
        end
        __L3.fn637 = function()
          __L3.setInn("Oresfall")
          fn545("p7_hendrick", function()
            fn580({ Vector3.new(2854, 43, 100), Vector3.new(2426, 26, 450), Vector3.new(2407, 58, 444) })
            if not fn589("Hendrick", Vector3.new(2407, 58, 444), { { "Sure.", "Here it is." } }, __L2.tbl296, 4) then
              return false
            end
            fn586()
            return true
          end)
          fn545("p7_dormin", function()
            fn580({ Vector3.new(2955, 257, -26), Vector3.new(2848, 256, 73), Vector3.new(2852, 287, 76) })
            return fn589("Dormin", Vector3.new(2852, 287, 76), { "Of course." }, tbl272, 4)
          end)
          fn545("p7_lerase", function()
            if not fn591("Ice Protection") then
              __L2.fn523("skipped Lerase: no Ice Protection in the pack")
              return false
            end
            fn580({ Vector3.new(2840, 258, 85), Vector3.new(3022, 265, -43), Vector3.new(3024, 287, -38) })
            for i68 = 1, 5 do
              if not tbl303[1] or not fn591("Ice Protection") then
                break
              end
              fn588("Lerase", Vector3.new(3024, 287, -38), { { "Sure.", "Here it is." } }, __L2.tbl295)
              fn588("Lerase", Vector3.new(3024, 287, -38), { "Here it is." }, __L2.tbl295)
              if fn591("Ice Protection") then
                task.wait(1.5)
              end
            end
            if fn591("Ice Protection") then
              __L2.fn523("Lerase never took the Ice Protection")
              return false
            end
            return true
          end)
          local fn658 = function()
            local fn660 = function()
              local v1256 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              return v1256 ~= nil and v1256.Position.Y > num294
            end
            if fn660() then
              return true
            end
            for i69 = 1, 2 do
              if not tbl303[1] then
                return false
              end
              local NPCs6 = v966:FindFirstChild("NPCs")
              local v1254 = NPCs6 and NPCs6:FindFirstChild("Xenyari")
              if not (v1254 and v1254:FindFirstChild("HumanoidRootPart")) then
                fn534("skycastle: no Xenyari to teleport to")
                return false
              end
              local res232 = __L3.fn634(function()
                local NPCs7 = v966:FindFirstChild("NPCs")
                local v1257 = NPCs7 and NPCs7:FindFirstChild("Xenyari")
                local v1258 = v1257 and v1257:FindFirstChild("HumanoidRootPart")
                return v1258 and v1258.Position or nil
              end, 1)
              if res232 and fn660() then
                return true
              end
              local v1255 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              fn534("skycastle: teleport %s, y is %.0f", res232 and "landed short" or "did not take", v1255 and v1255.Position.Y or -1)
            end
            return false
          end
          local fn659 = function(a1818, a2267)
            if not fn658() then
              __L2.fn523("could not reach the Castle in the Sky")
              return false
            end
            fn580(a1818)
            return a2267()
          end
          fn545("p7_rita", function()
            return fn659(__L3.tbl327, function()
              return fn589("Rita", Vector3.new(177, 3777, 167), { "What are you doing?", "Sure." }, __L2.tbl283, 4)
            end)
          end)
          fn545("p7_reneri", function()
            return fn659(__L3.tbl328, function()
              return fn589("Reneri", Vector3.new(416, 3735, -36), { "Hi.", "What are you doing?", "Yeah." }, __L2.tbl283, 4)
            end)
          end)
          fn545("p7_fanari", function()
            return fn659(__L3.tbl329, function()
              return fn589("Fanari", Vector3.new(508, 3703, -49), { "What is it?", "Sure." }, __L2.tbl288, 4)
            end)
          end)
          fn545("p7_ria", function()
            return __L3.setInn("Flowerlight Town") ~= false
          end)
          fn545("p7_lilin", function()
            if not near(__L2.vector311, 600) and __L3.setInn("Flowerlight Town") == false then
              return false
            end
            if not fn580(__L2.tbl292) then
              return false
            end
            fn588("Lilin", __L2.vector311, {})
            if not (tbl303[1] and fn580(__L2.tbl293)) then
              return false
            end
            fn588("Toilet Hand", __L2.vector312, { "...?" })
            if not (tbl303[1] and fn580(__L2.tbl294)) then
              return false
            end
            fn588("Lilin", __L2.vector311, { "Are you okay?" })
            local res233 = __L2.fn504({ "Love Letter" })
            if not (tbl303[1] and fn580(__L2.tbl293)) then
              return false
            end
            if not res233 then
              local res234, v1259 = fn588("Toilet Hand", __L2.vector312, {}, __L2.tbl289)
              if v1259 then
                return true
              end
              __L2.fn523("Lilin never handed the letter over")
              return false
            end
            local v1260 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
            if v1260 then
              pcall(function()
                v1260:UnequipTools()
              end)
            end
            local fn661 = function()
              local Character65 = LocalPlayer21.Character
              if Character65 and Character65:FindFirstChild("Love Letter") then
                return
              end
              local v1261 = Character65 and Character65:FindFirstChildOfClass("Humanoid")
              local Backpack26 = LocalPlayer21:FindFirstChildOfClass("Backpack")
              local v1262 = Backpack26 and Backpack26:FindFirstChild("Love Letter")
              if v1261 and v1262 then
                v1261:EquipTool(v1262)
              end
            end
            for i70 = 1, 3 do
              if not tbl303[1] then
                return false
              end
              fn588("Toilet Hand", __L2.vector312, { "Here." }, __L2.tbl289, nil, function(a1819)
                if a1819 == "Here." then
                  fn661()
                end
              end)
              local num380 = 0
              while true do
                if not (tbl303[1] and fn591("Love Letter") and num380 < __L2.num310) then
                  break
                end
                task.wait(0.25)
                num380 += 0.25
              end
              if not fn591("Love Letter") then
                return true
              end
            end
            __L2.fn523("the Toilet Hand would not take the letter")
            return false
          end)
        end
        __L3.fn638 = function()
          if __L3.bladeEnabled() then
            if not __L3.bladeDraugVisit() then return end
            if not __L3.bladeTrainerApproach("jagen","Castle Sanctuary",__L3.tbl330) then return end
            if not __L3.bladeTrainPurchase("jagen","Jagen",Vector3.new(6857,1411,-164),{"Please train me.","Here is 350 Silver."},__L2.tbl282,1) then return end
            if not __L2.fn503(__L2.tbl282) then __L3.bladeTrainWait("Jagen: aguardando confirmar skill Ultra");return end
            if not tbl303[1] then return end
            fn546()
            local mana=a1723.State.mana
            if mana and mana.decharge then pcall(mana.decharge) end
            tbl308[1].p7dash=nil;tbl308[1].p7side=nil
            fn542()
            fn534("P7: Ultra confirmada; seguindo sem treino ou espera de Mana Dash")
            __L3.fn636()
            return
          end
          fn534("P7: section 1 (day >= 1)")
          if __L2.fn504(__L2.tbl282) then
            fn546()
            fn534("P7: Jagen training already held, going straight back for Mana Dash")
          elseif not (__L3.bladeEnabled() and tbl308[1].bladeOrderlyDone) then
            __L3.fn637()
            if not tbl303[1] then
              return
            end
          end
          if not __L3.bladeEnabled() then __L3.setInn("Castle Sanctuary") end
          if tbl308[1].p7dash and not fn492() then
            local res235 = fn491(tbl308[1])
            fn542()
            fn534("P7: resumed mid-training, walking the ledge on side %d", tonumber(tbl308[1].p7side) or 0)
            fn580(res235.path)
          else
            if not __L3.bladeEnabled() then fn580(__L3.tbl330) end
          end
          local flag70 = false
          if not (__L3.bladeEnabled() and tbl308[1].bladeTraining and tbl308[1].bladeTraining.jagen and tbl308[1].bladeTraining.jagen.confirmed>=1) and not __L2.fn504(__L2.tbl282) then
            for i71 = 1, 2 do
              if not tbl303[1] or __L2.fn503(__L2.tbl282) then
                break
              end
              local res236, v1263, v1264 =
                fn588("Jagen", Vector3.new(6857, 1411, -164), { "Please train me.", "Here is 350 Silver." }, nil, __L2.tbl286)
              if v1264 then
                local tbl354 = {}
                for k287, v1265 in __L2.tbl287 do
                  if not (tbl308[1].done and tbl308[1].done[v1265]) then
                    table.insert(tbl354, v1265)
                  end
                end
                __L2.fn520(string.format("%s missed an orderly quest, Jagen refused the training", fn554()), {
                  "**Unfinished steps in the cache**",
                  #tbl354 > 0 and table.concat(tbl354, ", ") or "none recorded, so one was marked done without registering",
                })
                __L2.fn517()
                fn544("Jagen refused the training")
                return
              end
              task.wait(0.4)
            end
            flag70 = __L2.fn503(__L2.tbl282)
            if flag70 then
              fn546()
            end
          else
            fn534("P7: Jagen training already held, skipping")
          end
          if not fn492() then
            tbl308[1].p7dash = true
            fn542()
            __L2.fn524(
              "Training",
              (flag70 and "Jagen training bought" or "Jagen training already held")
                .. ", charging mana behind him until Mana Dash comes in for Khei"
            )
          end
          local v1266 = tbl308[1].p7dash and fn491(tbl308[1]) or nil
          if v1266 then
            fn542()
            if tbl303[1] and not near(v1266.spot, 60) then
              fn534("P7: walking the ledge on side %d", tonumber(tbl308[1].p7side) or 0)
              fn580(v1266.path)
            end
          end
          local num381 = tick() + num286
          while true do
            if not (tbl303[1] and v1266 and tbl308[1].p7dash and not fn492() and tick() < num381) then
              break
            end
            if LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("ForceField") then
              v1013(v1266.entry)
              task.wait(1)
            end
            if not near(v1266.spot, 60) then
              v1013(v1266.spot)
            end
            if fn583(v1266.spot, __L3.bladeThreatDistance()) then
              fn558("player near the mana training ledge", v1266.spot, __L3.bladeThreatDistance())
              return
            end
            local mana5 = a1723.State.mana
            if mana5 and mana5.available and mana5.available() then
              mana5.chargeUntil(100, function()
                return tbl303[1] and not fn492()
              end)
            end
            task.wait(0.5)
          end
          if tbl303[1] and not fn492() then
            fn534("P7: Mana Dash never appeared in %ds", num286)
            __L2.fn520(string.format("%s never got Mana Dash after %ds, stopping", fn554(), num286))
            if v1009 then
              v1009()
            end
            return
          end
          if tbl308[1].p7dash then
            tbl308[1].p7dash = nil
            tbl308[1].p7side = nil
            fn542()
          end
          __L3.fn636()
        end
        __L3.fn639 = function()
          fn534("P7: section 2 dayfarm (day 0)")
          __L3.setInn("Santorini")
          fn580({ Vector3.new(1355, 394, 2992), Vector3.new(1331, 121, 3003), Vector3.new(433, 121, 3583) })
          task.spawn(function()
            local res238, v1272 = __L2.fn506(5)
            __L2.fn524("Day farm", "Waiting for day 1 before the sigil run")
          end)
          local flag71 = false
          local res237 = requestRemote("DaysSurvivedChanged")
          if res237 then
            newResult61.dayFarmDay = res237.OnClientEvent:Connect(function(a1820)
              if a1820 and a1820 >= 1 then
                flag71 = true
              end
            end)
          end
          while true do
            if not (tbl303[1] and not flag71) then
              newResult61.dayFarmDay = nil
              return
            end
            if (getServerValue("DaysSurvived") or 0) >= 1 then
              break
            end
            if not (__L3.bladeStayHere()) then
              local v1267 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              if v1267 then
                local getPlayersResult25, v1268, v1269 = getResult23:GetPlayers()
                for k288, v1270 in getPlayersResult25, v1268, v1269 do
                  local v1271 = v1270 ~= LocalPlayer21 and v1270.Character and v1270.Character:FindFirstChild("HumanoidRootPart")
                  if v1271 and not __L2.fn512(a1723,v1270) and (v1271.Position - v1267.Position).Magnitude <= 700 then
                    newResult61.dayFarmDay = nil
                    fn542()
                    fn534("P7: dayfarm hop, %s within 700", v1270.Name)
                    fn560("dayfarm: " .. fn549(v1270) .. " within 700", v1267.Position, 700)
                    return
                  end
                end
              end
            end
            task.wait(1)
          end
          flag71 = true
          newResult61.dayFarmDay = nil
        end
        __L3.fn640 = function()
          if __L3.bladeEnabled() then __L3.fn638();return end
          if (getServerValue("DaysSurvived") or 0) < 1 then
            __L3.fn639()
          end
          if tbl303[1] and (getServerValue("DaysSurvived") or 0) >= 1 then
            __L3.fn638()
          end
        end
        __L3.fn641 = function()
          local fn662 = function()
            return LocalPlayer21.Character ~= nil and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart") ~= nil
          end
          if fn662() then
            return
          end
          task.wait(2)
          local PlayerGui11 = LocalPlayer21:FindFirstChildOfClass("PlayerGui")
          if PlayerGui11 and tbl303[1] and not fn662() then
            PlayerGui11:WaitForChild("StartMenu", 45)
          end
          local num382 = 0
          while true do
            if not (tbl303[1] and not fn662() and __L3.startMenu() and num382 < 30) then
              break
            end
            __L3.clickPlay()
            task.wait(0.5)
            num382 += 0.5
          end
          local num383 = 0
          while true do
            if not (tbl303[1] and not fn662() and num383 < 30) then
              break
            end
            task.wait(0.3)
            num383 += 0.3
          end
          if tbl303[1] and not fn662() then
            task.spawn(function()
              __L2.fn520(fn554() .. " failed to spawn in, no character after Play")
            end)
            fn544("failed to spawn in on new server")
            return
          end
          sResult7.awaitPlaced(function()
            return tbl303[1]
          end, 20)
          task.wait(5)
        end
        -- Blade/Sigil 3-stage route. All per-account progress lives in the existing save.
        __L3.bladeValue=function(name,default)
          if name=="BladeShrCount" then
            local option=Options8.BladeShrCount
            local value=tonumber(option and option.Value) or tonumber(__L3.bladeRunConfig and __L3.bladeRunConfig.BladeShrCount) or default or 50
            return math.clamp(math.floor(value),1,100)
          end
          if name=="BladeDamageGoal" then return 6700 end
          if name=="BladeM1Range" and (__L3.bladeCombatMode=="fist" or __L3.bladeCombatMode=="unlock") then return 5 end
          local run=__L3.bladeRunConfig
          if run and run[name]~=nil then return run[name] end
          local option=Options8[name] or Toggles8[name]
          if option and option.Value~=nil then return option.Value end
          return default
        end
        __L3.bladeSilverGoal=function()
          return __L3.bladeValue("BladeOrderly","Rots")=="Rots" and 100 or 660
        end
        __L3.bladeRoute={
          Vector3.new(2253.157470703125,50.91651916503906,553.6099853515625), -- 1
          Vector3.new(2287.3544921875,52.29716491699219,471.2541198730469), -- 2
          Vector3.new(2287.21240234375,63.67726516723633,471.4124450683594), -- 3
          Vector3.new(2335.185546875,63.5615234375,463.9927978515625), -- 4
          Vector3.new(2286.2138671875,62.293277740478516,432.523193359375), -- 5
          Vector3.new(2285.549072265625,51.02906799316406,430.0901794433594), -- 6
          Vector3.new(2254.485107421875,50.96875762939453,833.3567504882812), -- 7
          Vector3.new(2254.576904296875,67.78270721435547,832.7318115234375), -- 8
          Vector3.new(2255.060791015625,66.78803253173828,785.136962890625), -- 9
          Vector3.new(2262.25439453125,63.63618469238281,750.4935913085938), -- 10
          Vector3.new(2259.805419921875,58.19999694824219,751.3035278320312), -- 11
          Vector3.new(-2093.2568359375,614.87646484375,-720.7349243164062), -- 12
          Vector3.new(-2095.048095703125,620.0502319335938,-793.3778686523438), -- 13
          Vector3.new(-2076.978759765625,615.2067260742188,-759.8974609375), -- 14
        }
        a1723.State.bladeRoutePoints=__L3.bladeRoute
        __L3.bladeStatus=function(text)
          if __L3.bladeLabel and __L3.bladeLastStatus~=text then
            __L3.bladeLastStatus=text;__L3.bladeLabel:SetText(text)
          end
        end
        __L3.bladePhase=function(phase)
          tbl308[1].bladePhase=phase
          fn543(phase)
        end
        __L3.bladeStartStages={
          ["1 - Alana: Silver e itens"]="B1_PREP",
          ["2 - Comprar espada"]="B1_SWORD",
          ["3 - XP: espada e socos"]="B1_XP",
          ["4 - Sair do XP / aguardar Danger"]="B1_EXIT",
          ["5 - Orderly: Rots ou Quests"]="B2_ORDERLY",
          ["6 - Skills de Warrior e Sigil (base/super)"]="B3_TRAIN",
          ["7 - Draug e Ultra (Jagen)"]="P7",
          ["Khei - retomar sequencia"]="KHEI",
        }
        __L3.bladeSelectStart=function(value)
          if not value or value=="Resume" then return false end
          if tbl303[1] or __L3.bladeCoreRunning or __L3.bladeMenuPause then error("Pare o Sigil e aguarde a etapa encerrar antes de trocar.",0) end
          local phase=__L3.bladeStartStages[value]
          if not phase then
            local old=value:match("^P%d")
            phase=({P1="B1_PREP",P2="B2_ORDERLY",P3="B3_TRAIN",P4="B1_SWORD",P5="B1_XP",P6="B2_ORDERLY",P7="P7"})[old]
          end
          if not phase then error("Etapa manual invalida: "..tostring(value),0) end
          if (phase=="KHEI")~=(game.PlaceId==num274) then
            error(phase=="KHEI" and "Entre em Khei antes de selecionar essa etapa." or "Em Khei, selecione Resume ou Khei - retomar sequencia.",0)
          end
          local save=fn541() or {}
          save.phase=phase;save.bladePhase=phase;save.step=0
          -- A manual continuation starts here, without an unrelated trip back to Alana.
          save.bladeStartSpawnDone=phase~="B1_PREP" or nil
          save.bladeSpawnTransitionAllowed=(phase=="B2_ORDERLY" or phase=="B3_TRAIN" or phase=="P7") or nil
          if phase=="B1_PREP" then save.bladeSupplyBound=nil end
          if phase=="B1_EXIT" then save.bladeAtExitP10=nil end
          if phase=="P7" then save.p7dash=nil;save.p7side=nil end
          tbl308[1]=save
          fn542()
          qResult3.remove("prog_pathpoint");qResult3.remove("prog_lastpos")
          return true
        end
        __L3.bladeCount=function(name)
          local count=0
          for _,container in {LocalPlayer21.Character,LocalPlayer21:FindFirstChildOfClass("Backpack")} do
            if container then
              for _,item in container:GetChildren() do
                if item:IsA("Tool") and item.Name==name then count+=1 end
              end
            end
          end
          return count
        end
        __L3.bladePoint=function(key)
          local point=__L3.bladeRunConfig and __L3.bladeRunConfig.points and __L3.bladeRunConfig.points[key]
            or qResult3.getJSON(key)
          if point and tonumber(point.x) and tonumber(point.y) and tonumber(point.z) then
            return Vector3.new(point.x,point.y,point.z)
          end
          return nil
        end
        __L3.bladeMarkPoint=function(key)
          if tbl303[1] then fn535("Pare o Sigil antes de alterar os pontos"); return end
          local root=LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not root then fn535("Character not ready"); return end
          qResult3.setJSON(key,{x=root.Position.X,y=root.Position.Y,z=root.Position.Z})
          fn535("Point saved: "..key)
        end
        __L3.bladeBuySwordLegacy=function()
          if fn591("Sword") then return true end
          local keeper=HResult.innKeeper("Alana")
          local keeperRoot=keeper and (keeper:FindFirstChild("HumanoidRootPart") or keeper:FindFirstChildWhichIsA("BasePart"))
          local anchor=keeperRoot and keeperRoot.Position
            or (__L3.bladeRunConfig and __L3.bladeVector(__L3.bladeRunConfig.alanaAnchor))
            or __L3.bladePoint("blade_supply_point")
          if not anchor then
            __L3.bladeStatus("P1 espada: aguardando Inn Keeper ou ponto de coleta de Alana")
            task.wait(1); return false
          end
          if not near(anchor,250) then
            __L3.bladeStatus("P1 espada: voltando ao spawn de Alana")
            __L3.setInn("Alana")
            return false
          end
          if (tonumber(getServerValue("Silver")) or 0)<10 then
            __L3.bladeStatus("P1 espada: precisa de 10 Silver")
            task.wait(1); return false
          end
          local merchant,distance=HResult.nearestNPC("BronzeSword",anchor)
          local part=merchant and (merchant:FindFirstChild("HumanoidRootPart") or merchant:FindFirstChildWhichIsA("BasePart"))
          if not part or not distance or distance>250 or (part.Position-anchor).Magnitude>250 then
            __L3.bladeStatus("P1 espada: BronzeSword nao encontrado em Alana; aguardando a loja")
            task.wait(1); return false
          end
          __L3.bladeStatus("P1 espada: comprando Bronze Sword em Alana")
          fn580({part.Position+part.CFrame.LookVector*3})
          if not tbl303[1] or not part.Parent then return false end
          if not near(part.Position,15) then
            __L3.bladeStatus("P1 espada: nao chegou a loja de Alana; aguardando")
            task.wait(1); return false
          end
          fn587(merchant,{"I'll buy it."},5,function() return fn591("Sword") end)
          local deadline=os.clock()+6
          while tbl303[1] and not fn591("Sword") and os.clock()<deadline do task.wait(0.2) end
          if fn591("Sword") then return true end
          __L3.bladeStatus("P1 espada: compra em Alana nao confirmada; confira a loja e o Silver")
          return false
        end
        __L3.bladeSupplyRequirements=function()
          if __L3.bladeValue("BladeOrderly","Rots")=="Rots" then return {} end
          return {['Liquid Wisdom']=1,['Health Potion']=1,['Ice Protection']=1,['Tespian Elixir']=5}
        end
        __L3.bladeCollect=function()
          -- Money bags are handled by Sentinel Auto Bag. Never move the account to a bag.
          local root=LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          local thrown=v966:FindFirstChild("Thrown")
          if not root or not thrown or not firetouchinterest then return end
          local requirements=__L3.bladeSupplyRequirements()
          if next(requirements)==nil then return end
          for _,bag in thrown:GetChildren() do
            if not tbl303[1] then return end
            if bag.Name=="ToolBag" then
              local part=__L3.fn596(bag)
              local label=bag:FindFirstChild("BillboardGui")
              local tool=label and label:FindFirstChild("Tool")
              local name=tool and tool.Text
              if part and (part.Position-root.Position).Magnitude<=50
                and name and requirements[name] and __L3.bladeCount(name)<requirements[name] then
                firetouchinterest(part,root,0);firetouchinterest(part,root,1)
              end
            end
          end
        end
        __L3.bladePrepareLegacy=function()
          local save=tbl308[1]
          local supplyInn="Alana"
          if not save.bladeSupplyBound or save.bladeSupplyInn~=supplyInn then
            local supply=__L3.bladePoint("blade_supply_point")
            if not supply then
              __L3.bladeStatus("P1: mark the supply point near Alana before Start")
              task.wait(1)
              return
            end
            __L3.bladeStatus("P1: marcando spawn em "..supplyInn)
            if not __L3.bladeSpawnReady and __L3.setInn(supplyInn)==false then
              __L3.bladeStatus("P1: spawn em "..supplyInn.." nao confirmado; aguardando nova tentativa")
              return
            end
            if not tbl303[1] then return end
            fn580({supply})
            save.bladeSupplyBound=true
            save.bladeSupplyInn=supplyInn
            fn542()
          end
          __L3.bladeCollect()
          if not tbl303[1] then return end
          local missing={}
          for name,needed in pairs(__L3.bladeSupplyRequirements()) do
            local count=__L3.bladeCount(name)
            if count<needed then table.insert(missing,name.." "..count.."/"..needed) end
          end
          local silver=tonumber(getServerValue("Silver")) or 0
          local needed=__L3.bladeSilverGoal()
          if silver<needed then table.insert(missing,"Silver "..silver.."/"..needed) end
          if #missing>0 then
            __L3.bladeStatus("P1 supplies: "..table.concat(missing,", "))
            task.wait(1)
            return
          end
          save.bladePrepared=true
          __L3.bladePhase("B1_SWORD")
        end
        __L3.bladeStanding=function()
          local character=LocalPlayer21.Character
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          return character~=nil and hum~=nil and hum.Health>0
            and not v969:HasTag(character,"Unconscious") and not v969:HasTag(character,"Knocked")
        end
        __L3.bladeWaitPoints={[3]=true,[4]=true,[5]=true,[8]=true,[9]=true,[10]=true,[11]=true,[13]=true,[14]=true}
        __L3.bladeLand=function()
          -- Movement owns its temporary noclip connection; this runs only after it disconnects.
          for _,key in {"Flight","BetterFlight","Noclip"} do
            local toggle=Toggles8[key]
            if toggle and toggle.Value then toggle:SetValue(false) end
          end
          newResult61.attachLock=nil
          sResult7.clearVeil()
          local character=LocalPlayer21.Character
          local root=character and character:FindFirstChild("HumanoidRootPart")
          if root then root.Anchored=false;root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end
          fn499(character)
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          if hum then hum:SetStateEnabled(5,true);hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
        end
        __L3.bladePointReached=function(index)
          local character=LocalPlayer21.Character
          local root=character and character:FindFirstChild("HumanoidRootPart")
          local point=__L3.bladeRoute[index]
          if not root or not point then return false end
          local delta=root.Position-point
          -- Saved arrival survives the small vertical drop from the raised waypoint to the floor.
          if __L3.bladeLandedCharacter==character and __L3.bladeLandedPoint==index then
            return Vector3.new(delta.X,0,delta.Z).Magnitude<=10 and math.abs(delta.Y)<=30
          end
          return delta.Magnitude<=4
        end
        __L3.bladeMovePoint=function(index,standing)
          while tbl303[1] and standing and not __L3.bladeStanding() do
            __L3.bladeStatus("Aguardando levantar antes de P"..index);task.wait(0.25)
          end
          if not tbl303[1] then return false end
          __L3.bladeLocation=({[3]="PE3",[8]="PE8",[11]="PG11",[13]="PE13"})[index] or "P"..index
          __L3.bladeWorker.point=__L3.bladeLocation
          local point=__L3.bladeRoute[index]
          if not __L3.bladePointReached(index) then
            __L3.bladeLandedPoint=nil
            if fn580({point})==false or not tbl303[1] then return false end
            if not near(point,8) then __L3.bladeStatus("Nao chegou a "..__L3.bladeLocation.."; aguardando nova tentativa");task.wait(0.25);return false end
          end
          if __L3.bladeWaitPoints[index] and (__L3.bladeLandedCharacter~=LocalPlayer21.Character or __L3.bladeLandedPoint~=index) then
            __L3.bladeLand()
            __L3.bladeLandedCharacter=LocalPlayer21.Character;__L3.bladeLandedPoint=index
            task.wait(0.25)
          end
          return true
        end
        __L3.bladeBagPickup=function(active)
          if active then
            if __L3.bladeBagActive then return end
            __L3.bladeBagActive=true
            __L3.bladeBagRangeBefore=Options8.BagRange and Options8.BagRange.Value
            if Options8.BagRange then Options8.BagRange:SetValue(50) end
            if Toggles8.AutoBag then Toggles8.AutoBag:SetValue(true) end
          else
            if not __L3.bladeBagActive then return end
            __L3.bladeBagActive=false
            if Toggles8.AutoBag then Toggles8.AutoBag:SetValue(false) end
            if Options8.BagRange and __L3.bladeBagRangeBefore then Options8.BagRange:SetValue(__L3.bladeBagRangeBefore) end
          end
        end
        __L3.bladeSupplyAssignments=function(roster)
          local waiting,running={},{}
          local ordered=function(a,b)
            local x,y=a.supplyJoined or a.joined or 0,b.supplyJoined or b.joined or 0
            if x==y then return a.userId<b.userId end
            return x<y
          end
          for _,entry in roster do
            if entry.stage=="B1_PREP" or entry.supplyState=="running" then
              table.insert(entry.supplyState=="running" and running or waiting,entry)
            end
          end
          table.sort(running,ordered);table.sort(waiting,ordered)
          return running[1] or waiting[1],waiting
        end
        __L3.bladePrepare=function()
          local save=tbl308[1]
          local character=LocalPlayer21.Character
          if __L3.bladeSupplyCharacter~=character then
            __L3.bladeBagPickup(false)
            __L3.bladeSupplyCharacter=character;__L3.bladeAtSupplyWait=false
            __L3.bladeWorker.supplyState=nil
          end
          save.bladeSupplyJoined=save.bladeSupplyJoined or DateTime.now().UnixTimestampMillis
          if not __L3.bladeAtSupplyWait then
            for _,index in {1,2,3} do if not __L3.bladeMovePoint(index,true) then return end end
            __L3.bladeAtSupplyWait=true
          end
          __L3.bladeWorkerTick()
          if __L3.bladeSupplyOwner~=LocalPlayer21.UserId then
            __L3.bladeBagPickup(false)
            __L3.bladeStatus("PE3: aguardando a vez de recolher em P4")
            task.wait(0.3);return
          end
          if __L3.bladeWorker.supplyState~="running" then
            __L3.bladeWorker.supplyState="claiming";__L3.bladeWorkerTick();task.wait(0.6);__L3.bladeWorkerTick()
            if __L3.bladeSupplyOwner~=LocalPlayer21.UserId then return end
            __L3.bladeWorker.supplyState="running";__L3.bladeWorkerTick()
            if not __L3.bladeMovePoint(4,true) then return end
          end
          if not __L3.bladePointReached(4) and not __L3.bladeMovePoint(4,true) then return end
          __L3.bladeBagPickup(true)
          __L3.bladeCollect()
          if not tbl303[1] then return end
          local missing={}
          local needed=__L3.bladeSilverGoal()
          local silver=tonumber(getServerValue("Silver")) or 0
          if silver<needed then table.insert(missing,string.format("Silver %d/%d",silver,needed)) end
          for name,amount in pairs(__L3.bladeSupplyRequirements()) do
            local count=__L3.bladeCount(name)
            if count<amount then table.insert(missing,name.." "..count.."/"..amount) end
          end
          if #missing>0 then __L3.bladeStatus("P4: "..table.concat(missing,", "));task.wait(0.25);return end
          __L3.bladeBagPickup(false)
          if not __L3.bladeMovePoint(5,true) then return end
          __L3.bladeWorker.supplyState=nil
          save.bladePrepared=true;save.bladeSupplyBound=true;save.bladeSupplyInn="Alana"
          __L3.bladePhase("B1_SWORD");__L3.bladeWorkerTick()
        end
        __L3.bladeBuySword=function()
          if fn591("Sword") then return true end
          if __L3.bladeSwordBusy then task.wait(0.25);return false end
          if os.clock()<(__L3.bladeSwordNextAttempt or 0) then task.wait(0.25);return false end
          if not __L3.bladeMovePoint(5,true) then return false end
          local point=__L3.bladeRoute[5]
          local merchant,distance=HResult.nearestNPC("BronzeSword",point)
          if not merchant or not distance or distance>25 then
            __L3.bladeStatus("P5: aguardando BronzeSword no ponto de compra informado");task.wait(1);return false
          end
          local detector=merchant:IsA("ClickDetector") and merchant or merchant:FindFirstChildWhichIsA("ClickDetector",true)
          if not detector then __L3.bladeStatus("P5: aguardando ClickDetector da BronzeSword");task.wait(1);return false end
          if (tonumber(getServerValue("Silver")) or 0)<10 then
            __L3.bladeStatus("P5: aguardando 10 Silver para a espada");task.wait(1);return false
          end
          __L3.bladeStatus("P5: comprando espada de Bronze em Alana")
          __L3.bladeSwordBusy=true
          fn536(true)
          local purchaseDeadline=os.clock()+8
          local ok,err=pcall(function()
            -- doneWhen accepts dialogue text lists, never an inventory predicate.
            -- No position hold: the raised waypoint must settle naturally on the floor.
            FResult.run(merchant,{"I'll buy it."},{
              shouldRun=function() return tbl303[1] and not fn591("Sword") and os.clock()<purchaseDeadline end,
              timeout=5,holdPosition=false,maxReplays=0,minHold=0,
            })
            local deadline=os.clock()+3
            while tbl303[1] and not fn591("Sword") and os.clock()<deadline do task.wait(0.2) end
          end)
          fn536(false)
          __L3.bladeSwordBusy=false
          __L3.bladeSwordNextAttempt=os.clock()+3
          if not ok then __L3.bladeStatus("P5: falha na compra; nova tentativa em 3s");fn534("Blade sword purchase: %s",tostring(err)) end
          return tbl303[1] and fn591("Sword")
        end
        -- Exact XP cell: attack position + two opposite inside corners.
        __L3.bladeCellKey="sentinel/.cache/blade_workers/xp_cell.json"
        __L3.bladeCellDefault=function()
          return {placeId=5208655184,
            cornerA={x=2272.9111328125,y=62.99999237060547,z=791.964599609375},
            cornerB={x=2265.51806640625,y=62.99999237060547,z=776.548583984375},
            attack={position={x=2268.965087890625,y=62.999996185302737,z=783.982666015625},
              look={x=-0.012723248451948166,y=-1.1437127689362115e-8,z=0.999919056892395}}}
        end
        __L3.bladeCellConfig=__L3.bladeCellDefault()
        __L3.bladeCellDirty=qResult3.get("blade_xp_cell_draft")=="true"
        __L3.bladeCellRefresh=0
        __L3.bladeVector=function(value)
          if type(value)~="table" then return nil end
          for _,key in {"x","y","z"} do
            local n=tonumber(value[key])
            if not n or n~=n or math.abs(n)>1000000 then return nil end
          end
          return Vector3.new(tonumber(value.x),tonumber(value.y),tonumber(value.z))
        end
        __L3.bladePackVector=function(v) return {x=v.X,y=v.Y,z=v.Z} end
        __L3.bladeCellBounds=function(cell)
          if type(cell)~="table" or cell.placeId~=game.PlaceId then return nil end
          if type(cell.attack)~="table" then return nil end
          local a,b=__L3.bladeVector(cell.cornerA),__L3.bladeVector(cell.cornerB)
          local point=cell.attack and __L3.bladeVector(cell.attack.position)
          local look=cell.attack and __L3.bladeVector(cell.attack.look)
          if not a or not b or not point or not look then return nil end
          if math.abs(a.X-b.X)<1 or math.abs(a.Z-b.Z)<1
            or (a-b).Magnitude>100 or math.abs(a.Y-b.Y)>12 then return nil end
          local bounds={minX=math.min(a.X,b.X),maxX=math.max(a.X,b.X),
            minZ=math.min(a.Z,b.Z),maxZ=math.max(a.Z,b.Z),
            minY=math.min(a.Y,b.Y)-6,maxY=math.max(a.Y,b.Y)+6}
          if point.X<bounds.minX-4 or point.X>bounds.maxX+4 or point.Z<bounds.minZ-4
            or point.Z>bounds.maxZ+4 or point.Y<bounds.minY or point.Y>bounds.maxY then return nil end
          if Vector3.new(look.X,0,look.Z).Magnitude<0.1 then return nil end
          return bounds,point,Vector3.new(look.X,0,look.Z).Unit
        end
        __L3.bladeInCell=function(position,bounds)
          return position.X>=bounds.minX and position.X<=bounds.maxX
            and position.Z>=bounds.minZ and position.Z<=bounds.maxZ
            and position.Y>=bounds.minY and position.Y<=bounds.maxY
        end
        __L3.bladeCellLoadLegacy=function()
          if __L3.bladeFarmCell then return __L3.bladeFarmCell end
          if __L3.bladeRunConfig and __L3.bladeRunConfig.cell then return __L3.bladeRunConfig.cell end
          if not __L3.bladeCellDirty and __L3.bladeIO and os.clock()>=__L3.bladeCellRefresh then
            __L3.bladeCellRefresh=os.clock()+5
            local ok,record=pcall(__L3.bladeIO.readJson,__L3.bladeCellKey)
            if ok and type(record)=="table" and __L3.bladeCellBounds(record.config) then
              __L3.bladeCellConfig=record.config
              qResult3.setJSON("blade_xp_cell",record.config)
            end
          end
          return __L3.bladeCellConfig
        end
        __L3.bladeCellLoad=function()
          return __L3.bladeFarmCell or (__L3.bladeRunConfig and __L3.bladeRunConfig.cell) or __L3.bladeCellDefault()
        end
        __L3.bladeCellDescribe=function()
          if not __L3.bladeCellLabel then return end
          local cell=type(__L3.bladeCellConfig)=="table" and __L3.bladeCellConfig or {}
          local bounds=__L3.bladeCellBounds(cell)
          if not bounds then
            __L3.bladeCellLabel:SetText("Cela XP: marque ataque + canto A + canto B (mesma cela).")
            return
          end
          local mobs=__L3.bladeShriekers()
          local full=0
          for _,mob in mobs do if __L3.bladeFullHP(mob.hum) then full+=1 end end
          __L3.bladeCellLabel:SetText(string.format("Cela XP: %d Shriekers | %d full HP | %.1f x %.1f studs%s",
            #mobs,full,bounds.maxX-bounds.minX,bounds.maxZ-bounds.minZ,
            __L3.bladeCellDirty and " | rascunho: salvar/compartilhar" or " | salva"))
        end
        __L3.bladeCellMark=function(kind)
          if tbl303[1] then fn535("Pare a progressao antes de mudar a cela XP"); return end
          local root=LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not root then fn535("Aguarde o personagem"); return end
          local cell=type(__L3.bladeCellConfig)=="table" and __L3.bladeCellConfig or {}
          if cell.placeId~=game.PlaceId then cell={} end
          cell.placeId=game.PlaceId
          if kind=="attack" then
            cell.attack={position=__L3.bladePackVector(root.Position),look=__L3.bladePackVector(root.CFrame.LookVector)}
          else cell[kind]=__L3.bladePackVector(root.Position) end
          __L3.bladeCellConfig=cell
          __L3.bladeCellDirty=true
          qResult3.setJSON("blade_xp_cell",cell)
          qResult3.set("blade_xp_cell_draft","true")
          __L3.bladeCellDescribe()
          fn535("Cela: "..kind.." marcado. Marque os dois cantos por dentro da cela.")
        end
        __L3.bladeCellPublish=function()
          if tbl303[1] then fn535("Pare a progressao antes de salvar a cela"); return false end
          local cell=__L3.bladeCellConfig
          if not __L3.bladeCellBounds(cell) then
            fn535("Faltam marcacoes validas: ataque, canto A e canto B na mesma cela")
            return false
          end
          local ok,result=pcall(__L3.bladeIO.writeJson,__L3.bladeCellKey,{kind="xp_cell",config=cell})
          if not ok or not result then
            fn535("Cela salva neste executor. Compartilhamento falhou; confira a rede ou importe o JSON nos outros PCs.")
            return false
          end
          __L3.bladeCellDirty=false
          qResult3.remove("blade_xp_cell_draft")
          __L3.bladeCellRefresh=os.clock()+5
          __L3.bladeCellDescribe()
          fn535("Cela XP salva e compartilhada com as outras contas")
          return true
        end
        __L3.bladeCellUseDefault=function()
          if tbl303[1] then fn535("Pare a progressao antes de mudar a cela XP"); return false end
          local cell=__L3.bladeCellDefault()
          if not __L3.bladeCellBounds(cell) then fn535("A cela padrao Necro e do mapa Gaia (5208655184)."); return false end
          __L3.bladeCellConfig=cell
          __L3.bladeCellDirty=true
          qResult3.setJSON("blade_xp_cell",cell)
          qResult3.set("blade_xp_cell_draft","true")
          __L3.bladeCellDescribe()
          fn535("Cela padrao Necro aplicada neste PC. Use Salvar/compartilhar para enviar as outras contas.")
          return true
        end
        __L3.bladeCellClearVisual=function()
          if __L3.bladeCellVisual then __L3.bladeCellVisual:Destroy(); __L3.bladeCellVisual=nil end
        end
        __L3.bladeCellShow=function()
          __L3.bladeCellClearVisual()
          local cell=__L3.bladeCellLoad()
          local bounds,point,look=__L3.bladeCellBounds(cell)
          if not bounds then fn535("Marque ataque e os dois cantos primeiro"); return end
          local folder=Instance.new("Folder")
          folder.Name="BLADE23_XP_CALIBRACAO"
          folder.Parent=v966
          __L3.bladeCellVisual=folder
          local function marker(name,size,frame,color,transparency)
            local part=Instance.new("Part")
            part.Name=name; part.Size=size; part.CFrame=frame; part.Color=color
            part.Anchored=true; part.CanCollide=false; part.CanTouch=false; part.CanQuery=false
            part.Material=Enum.Material.Neon; part.Transparency=transparency or 0.15; part.Parent=folder
            return part
          end
          local box=marker("Limites da cela",Vector3.new(bounds.maxX-bounds.minX,bounds.maxY-bounds.minY,bounds.maxZ-bounds.minZ),
            CFrame.new((bounds.minX+bounds.maxX)/2,(bounds.minY+bounds.maxY)/2,(bounds.minZ+bounds.maxZ)/2),Color3.fromRGB(0,255,160),0.94)
          local outline=Instance.new("SelectionBox"); outline.Adornee=box; outline.LineThickness=0.05
          outline.Color3=Color3.fromRGB(0,255,160); outline.Parent=folder
          marker("Ponto de M1",Vector3.new(0.6,0.6,0.6),CFrame.new(point),Color3.fromRGB(0,180,255))
          marker("Direcao inicial do M1",Vector3.new(0.2,0.2,4),CFrame.lookAt(point+look*2,point+look*3),Color3.fromRGB(255,220,0))
          for _,mob in __L3.bladeShriekers() do
            local highlight=Instance.new("Highlight")
            highlight.Adornee=mob.model; highlight.FillColor=Color3.fromRGB(0,255,160)
            highlight.FillTransparency=0.7; highlight.OutlineTransparency=0; highlight.Parent=folder
          end
          __L3.bladeCellDescribe()
          fn535("Verde: area/alvos. Azul: ponto de ataque. Amarelo: direcao inicial.")
        end
        __L3.bladeCellReport=function()
          local report={version=1,placeId=game.PlaceId,cell=__L3.bladeCellLoad(),mobs={}}
          for _,mob in __L3.bladeShriekers() do
            table.insert(report.mobs,{name=mob.model.Name,position=__L3.bladePackVector(mob.root.Position),
              hp=mob.hum.Health,maxHp=mob.hum.MaxHealth})
          end
          local json=aResult22.HttpService:JSONEncode(report)
          if writefile then pcall(writefile,"blade23_calibracao_xp.json",json) end
          if setclipboard then setclipboard(json); fn535("Calibracao copiada: cole esse texto na conversa")
          else print("[blade23_calibracao_xp] "..json); fn535("Calibracao impressa no console") end
          return json
        end
        __L3.bladeCellImport=function(json)
          if tbl303[1] then fn535("Pare a progressao antes de importar a cela"); return end
          local ok,report=pcall(aResult22.HttpService.JSONDecode,aResult22.HttpService,json)
          local cell=ok and type(report)=="table" and (report.cell or report) or nil
          if not __L3.bladeCellBounds(cell) then fn535("JSON de calibracao invalido ou de outro mapa"); return end
          __L3.bladeCellConfig=cell; __L3.bladeCellDirty=true
          qResult3.setJSON("blade_xp_cell",cell); qResult3.set("blade_xp_cell_draft","true")
          __L3.bladeCellDescribe()
          fn535("Cela importada. Confira a area e clique Salvar/compartilhar.")
        end
        a1723.Maid:Give(__L3.bladeCellClearVisual)
        __L3.bladeFullHP=function(hum)
          return hum and hum.MaxHealth>0 and hum.Health>0 and hum.MaxHealth-hum.Health<=0.05
        end
        __L3.bladeMobInCell=function(root,bounds)
          -- Accept a mob whose body overlaps the cell edge; never widen the movement bounds.
          local position=root.Position
          local radiusX=math.min(3,math.max(0.5,root.Size.X/2)+1)
          local radiusZ=math.min(3,math.max(0.5,root.Size.Z/2)+1)
          return position.X+radiusX>=bounds.minX and position.X-radiusX<=bounds.maxX
            and position.Z+radiusZ>=bounds.minZ and position.Z-radiusZ<=bounds.maxZ
            and position.Y>=bounds.minY-4 and position.Y<=bounds.maxY+12
        end
        __L3.bladeShriekers=function()
          local result={}
          local report={nearby=0,outside=0,missingHP=0,count=0,full=0,minimum=__L3.bladeValue("BladeShrCount",50)}
          __L3.bladeShrReport=report
          local live=v966:FindFirstChild("Live")
          if not live then report.error="pasta Live indisponivel";return result end
          local bounds,anchor=__L3.bladeCellBounds(__L3.bladeCellLoad())
          if not bounds then report.error="cela invalida ou mapa diferente";return result end
          for _,mob in live:GetChildren() do
            if mob.Name:lower():find("shrieker",1,true) then
              local root=mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
              local hum=mob:FindFirstChildOfClass("Humanoid")
              if root and (root.Position-anchor).Magnitude<=60 then
                report.nearby+=1
                if not hum or hum.MaxHealth<=0 then report.missingHP+=1
                elseif __L3.bladeMobInCell(root,bounds) then
                  table.insert(result,{model=mob,root=root,hum=hum})
                  if __L3.bladeFullHP(hum) then report.full+=1 end
                else report.outside+=1 end
              end
            end
          end
          report.count=#result
          return result
        end
        __L3.bladeXPWaitStatus=function()
          local r=__L3.bladeShrReport or {count=0,full=0,minimum=__L3.bladeValue("BladeShrCount",50),outside=0,missingHP=0}
          if r.error then return "PE8: "..r.error end
          local reason
          if r.count<r.minimum then reason="faltam alvos dentro da cela"
          elseif r.full<r.count then reason="aguardando HP cheio"
          elseif __L3.bladeShrOwner then reason="vaga ocupada por "..__L3.bladeShrOwner
          else reason="sincronizando reserva local" end
          return string.format("PE8: cela %d/%d | full %d/%d | fora %d | sem HP %d | %s",r.count,r.minimum,r.full,r.count,r.outside,r.missingHP,reason)
        end
        __L3.bladeLockSetup=function(active)
          for _,key in {"ProgRoute","BladeOrderly","BladeFarm","BladeDamageGoal","BladeShrCount","BladeSpeed",
            "BladeM1Range","BladeM1Arc","BladeM1Step","BladeAimCamera","BladeAllowHop","Blade23Mode","ProgStartPhase","RotAlts"} do
            local control=Options8[key] or Toggles8[key]
            if control and control.SetDisabled then control:SetDisabled(active) end
          end
        end
        __L3.bladeReleaseSetup=function()
          __L3.bladeBagPickup(false)
          __L3.bladeAtSupplyWait=false;__L3.bladeSupplyCharacter=nil
          __L3.bladeLandedCharacter=nil;__L3.bladeLandedPoint=nil
          __L3.bladeSwordNextAttempt=nil
          __L3.bladeShrApproachCharacter=nil;__L3.bladeRotWaitingCharacter=nil;__L3.bladeRotAtP14Character=nil
          a1723.State.bladeReceiverAtP14=false
          __L3.bladeRunConfig=nil
          __L3.bladeSpawnReady=false
          a1723.State.bladeRunAlts=nil
          __L3.bladeLockSetup(false)
        end
        __L3.bladeCaptureSetup=function(saved)
          if saved and type(saved.bladeRunConfig)=="table" and saved.bladeRunConfig.version==2 then
            local run=table.clone(saved.bladeRunConfig)
            run.BladeShrCount=__L3.bladeValue("BladeShrCount",50)
            run.Blade23Mode=Toggles8.Blade23Mode and Toggles8.Blade23Mode.Value==true or false
            if Options8.RotAlts then
              run.alts={}
              for name,selected in pairs(Options8.RotAlts.Value or {}) do if selected then run.alts[name]=true end end
            end
            return run
          end
          local run={version=2,ProgRoute="Blade/Sigil (3 stages)",points={},alts={}}
          for _,key in {"BladeOrderly","BladeFarm","BladeSpeed","BladeShrCount","BladeM1Range","BladeM1Arc","BladeM1Step"} do
            if Options8[key] then run[key]=Options8[key].Value end
          end
          for _,key in {"BladeAimCamera","BladeAllowHop","Blade23Mode"} do
            if Toggles8[key] then run[key]=Toggles8[key].Value end
          end
          run.cell=__L3.bladeCellDefault()
          run.points.blade_supply_point=__L3.bladePackVector(__L3.bladeRoute[4])
          run.points.blade_wait_point=__L3.bladePackVector(__L3.bladeRoute[8])
          for name,selected in pairs(Options8.RotAlts and Options8.RotAlts.Value or {}) do
            if selected then run.alts[name]=true end
          end
          return run
        end
        __L3.bladeValidateSetup=function(run,phase)
          if game.PlaceId==num274 then return end
          local trainingOnly=phase=="B3_TRAIN" or phase=="P7"
          local missing={}
          if #__L3.bladeRoute~=14 then table.insert(missing,"rota Blade de 14 pontos") end
          if run.BladeOrderly~="Rots" and run.BladeOrderly~="Quests" then table.insert(missing,"metodo Rots ou Quests") end
          if run.BladeFarm~="Automatic" and run.BladeFarm~="Shriekers" and run.BladeFarm~="Zombie Scrooms" then table.insert(missing,"metodo de XP") end
          if type(run.BladeSpeed)~="number" or run.BladeSpeed<20 or run.BladeSpeed>250 then table.insert(missing,"velocidade de 20 a 250") end
          if not firetouchinterest or not Toggles8.AutoBag or not Options8.BagRange then table.insert(missing,"AutoBagPickup e firetouchinterest") end
          if not fireclickdetector then table.insert(missing,"fireclickdetector para comprar espada") end
          if not trainingOnly and run.BladeFarm~="Zombie Scrooms" and not (a1723.State.mana and a1723.State.mana.chargeUntil) then table.insert(missing,"controle de mana para o treino de soco") end
          if run.BladeFarm~="Zombie Scrooms" and not __L3.bladeCellBounds(run.cell) then table.insert(missing,"cela XP para Shriekers/Automatic") end
          if not trainingOnly and (run.BladeOrderly or "Rots")=="Rots" and not run.Blade23Mode and not next(run.alts or {}) then table.insert(missing,"contas fornecedoras em Blade / Sigil > Alts") end
          if not __L3.bladeIO.available() then table.insert(missing,"acesso aos arquivos do executor para as filas locais") end
          if #missing>0 then error("Configure antes de iniciar: "..table.concat(missing,", "),0) end
        end
        a1723.Maid:Give(__L3.bladeReleaseSetup)
        __L3.bladeRoster=function()
          local roster={}
          local folder="sentinel/.cache/blade_workers"
          for _,file in __L3.bladeIO.sharedList(folder) do
            if tostring(file):match("%.json$") then
              local entry=__L3.bladeIO.readJson(file)
              if entry and entry.jobId==game.JobId and type(entry.at)=="number"
                and __L3.bladeIO.sharedNow()-entry.at<=__L3.bladeIO.sharedLease() and entry.active and type(entry.userId)=="number" then
                table.insert(roster,entry)
              end
            end
          end
          local self=__L3.bladeWorker
          if self and self.active and self.jobId==game.JobId then
            for index=#roster,1,-1 do if roster[index].userId==LocalPlayer21.UserId then table.remove(roster,index) end end
            table.insert(roster,self)
          end
          return roster
        end
        __L3.bladeAssignments=function(roster)
          local waiting={}
          local running={}
          local shrAvailable=false
          for _,entry in roster do
            if entry.shrAvailable then shrAvailable=true end
            if entry.stage=="B1_XP" or entry.farmState=="running" then
              if entry.farmState=="running" and (entry.slot=="shriekers" or entry.slot=="scrooms") then
                table.insert(running,entry)
              else table.insert(waiting,entry) end
            end
          end
          local function ordered(a,b)
            local aOrder=a._order or a.joined or 0
            local bOrder=b._order or b.joined or 0
            if aOrder==bOrder then return a.userId<b.userId end
            return aOrder<bOrder
          end
          table.sort(running,ordered); table.sort(waiting,ordered)
          local assignments,occupied={},{}
          for _,entry in running do
            if not occupied[entry.slot] then
              assignments[entry.userId]=entry.slot; occupied[entry.slot]=true
            end
          end
          for _,entry in waiting do
            local slot
            if entry.preference~="Zombie Scrooms" and entry.shrAvailable and not occupied.shriekers then slot="shriekers"
            elseif entry.preference~="Shriekers" and not occupied.scrooms then slot="scrooms" end
            if slot then assignments[entry.userId]=slot; occupied[slot]=true end
          end
          return assignments
        end
        __L3.bladeWorkerPath="sentinel/.cache/blade_workers/"..LocalPlayer21.UserId..".json"
        __L3.bladeIO=tbl44.M()
        __L3.bladeWorker={}
        __L3.bladeWorkerTick=function()
          local active=tbl303[1] and __L3.bladeEnabled()
          local worker=__L3.bladeWorker
          worker.active=active; worker.at=os.time(); worker.userId=LocalPlayer21.UserId
          worker.name=LocalPlayer21.Name; worker.jobId=game.JobId
          if active and tbl308[1] then
            worker.stage=tbl308[1].phase
            worker.joined=tbl308[1].bladeFarmJoined or DateTime.now().UnixTimestampMillis
            worker.preference=__L3.bladeValue("BladeFarm","Automatic")
            worker.supplyJoined=tbl308[1].bladeSupplyJoined
            worker.accountJoined=tbl308[1].bladeAccountJoined
            worker.point=__L3.bladeLocation or "Alana"
            worker.damage=tonumber(tbl308[1].bladeDamage) or 0
            worker.fistDamage=tonumber(tbl308[1].bladeFistDamage) or 0
            local mobs=__L3.bladeShriekers()
            local full=0
            for _,mob in mobs do if __L3.bladeFullHP(mob.hum) then full+=1 end end
            worker.shrAvailable=#mobs>=__L3.bladeValue("BladeShrCount",50) and full==#mobs
            if not __L3.bladeIO.writeJson(__L3.bladeWorkerPath,worker) then
              __L3.bladeFarmAssigned=nil
              error(__L3.bladeIO.net.lastError or "Could not write shared XP queue file")
            end
            local roster=__L3.bladeRoster()
            __L3.bladeShrOwner=nil
            for _,entry in roster do
              if entry.userId~=LocalPlayer21.UserId and entry.farmState=="running" and entry.slot=="shriekers" then __L3.bladeShrOwner=entry.name or tostring(entry.userId);break end
            end
            local supplyOwner=__L3.bladeSupplyAssignments(roster)
            __L3.bladeSupplyOwner=supplyOwner and supplyOwner.userId
            local assignments=__L3.bladeAssignments(roster)
            __L3.bladeFarmAssigned=assignments[LocalPlayer21.UserId]
            if __L3.bladeQueueLabel then
              table.sort(roster,function(a,b) local x,y=a.accountJoined or a.joined or 0,b.accountJoined or b.joined or 0;if x==y then return a.userId<b.userId end;return x<y end)
              local lines={"Coleta P4: "..(supplyOwner and supplyOwner.name or "livre")}
              for index,entry in roster do
                table.insert(lines,string.format("%d. %s | %s | %s | XP %.0f/6700 + %.0f/300",index,entry.name or "?",entry.stage or "?",entry.point or "?",entry.damage or 0,entry.fistDamage or 0))
              end
              __L3.bladeQueueLabel:SetText(table.concat(lines,"\n"))
            end
            a1723.State.bladeTeam=a1723.State.bladeTeam or {}
            table.clear(a1723.State.bladeTeam)
            for _,entry in roster do a1723.State.bladeTeam[entry.userId]=true end
            for _,entry in __L3.bladeIO.channel("rotbot").roster() do
              a1723.State.bladeTeam[entry.userId]=true
            end
          elseif worker.wasActive then
            __L3.bladeIO.writeJson(__L3.bladeWorkerPath,worker)
            __L3.bladeFarmAssigned=nil
            a1723.State.bladeTeam=nil
            if __L3.bladeRotJoined then
              __L3.bladeRotJoined=false
              if a1723.State.leaveRotReceiverQueue then a1723.State.leaveRotReceiverQueue("left") end
              if a1723.Library.Toggles.RotBotEnabled then a1723.Library.Toggles.RotBotEnabled:SetValue(false) end
            end
          end
          worker.wasActive=active
        end
        __L3.bladeRelease=function()
          __L3.bladeWorker.farmState="waiting"
          __L3.bladeWorker.supplyState=nil
          __L3.bladeWorker.slot=nil
          __L3.bladeWorker.at=os.time()
          __L3.bladeWorker.stage="released"
          __L3.bladeIO.writeJson(__L3.bladeWorkerPath,__L3.bladeWorker)
          __L3.bladeFarmAssigned=nil
        end
        __L3.bladeElapsed=0
        a1723.Maid:Give(v967.Heartbeat:Connect(function(dt)
          __L3.bladeElapsed+=dt
          if __L3.bladeElapsed<0.5 then return end
          __L3.bladeElapsed=0
          if __L3.bladeWorkerTickBusy then return end
          __L3.bladeWorkerTickBusy=true
          local ok,err=pcall(__L3.bladeWorkerTick)
          __L3.bladeWorkerTickBusy=false
          if not ok then
            __L3.bladeFarmAssigned=nil
            __L3.bladeStatus("Shared XP queue error: "..tostring(err))
          end
        end))
        a1723.Maid:Give(function()
          __L3.bladeWorker.active=false
          pcall(__L3.bladeIO.writeJson,__L3.bladeWorkerPath,__L3.bladeWorker)
          a1723.State.bladeTeam=nil
        end)
        -- Geometric coverage is an estimate; HP events remain the XP counter.
        __L3.bladeConeCount=function(position,direction,targets,range,halfAngle)
          local count=0
          local cosine=math.cos(halfAngle)
          for _,target in targets do
            local d=target.Position-position
            local flat=Vector3.new(d.X,0,d.Z)
            if flat.Magnitude<=range and
              (flat.Magnitude<0.05 or flat.Unit:Dot(direction)+0.000001>=cosine) then count+=1 end
          end
          return count
        end
        __L3.bladeAimPlan=function(anchor,current,initialLook,targets,bounds,canStand,visible)
          local step=__L3.bladeValue("BladeM1Step",1.5)
          local range=__L3.bladeValue("BladeM1Range",8)
          local halfAngle=math.rad(__L3.bladeValue("BladeM1Arc",110)/2)
          local candidates={current}
          local function add(position)
            for _,existing in candidates do if (position-existing).Magnitude<0.25 then return end end
            if __L3.bladeInCell(position,bounds) and canStand(position) then table.insert(candidates,position) end
          end
          if step>0 then
            add(anchor)
            for index=0,7 do
              local angle=index*math.pi/4
              add(anchor+Vector3.new(math.sin(angle)*step,0,math.cos(angle)*step))
            end
          end
          local best={position=current,direction=initialLook,count=0,score=-math.huge}
          for _,position in candidates do
            local nearby={}
            for _,target in targets do
              local delta=target.Position-position
              if Vector3.new(delta.X,0,delta.Z).Magnitude<=range and visible(position,target.Position) then
                table.insert(nearby,target)
              end
            end
            local bearings={}
            local centered=0
            for _,target in nearby do
              local d=target.Position-position
              if Vector3.new(d.X,0,d.Z).Magnitude<0.05 then centered+=1
              else table.insert(bearings,math.atan2(d.X,-d.Z)%(2*math.pi)) end
            end
            table.sort(bearings)
            local function offer(angle,count)
              local direction=Vector3.new(math.sin(angle),0,-math.cos(angle))
              local score=count*1000-(position-current).Magnitude*10+(direction:Dot(initialLook))*0.01
              if score>best.score then best={position=position,direction=direction,count=count,score=score} end
            end
            offer(math.atan2(initialLook.X,-initialLook.Z),__L3.bladeConeCount(position,initialLook,nearby,range,halfAngle))
            local n=#bearings
            local right=0
            local function angleAt(index) return bearings[(index-1)%n+1]+(index>n and 2*math.pi or 0) end
            for left=1,n do
              right=math.max(right,left-1)
              while right+1<left+n and angleAt(right+1)-bearings[left]<=2*halfAngle+0.0000001 do right+=1 end
              offer(bearings[left]+halfAngle,right-left+1+centered)
            end
          end
          return best
        end
        __L3.bladeAttack=function(done,targetsProvider,cell)
          local bounds,anchor,initialLook=__L3.bladeCellBounds(cell)
          local character=LocalPlayer21.Character
          local root=character and character:FindFirstChild("HumanoidRootPart")
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          if not bounds or not root or not hum then return end
          local oldAuto=hum.AutoRotate
          local camera=v966.CurrentCamera
          local oldCamera=camera and camera.CFrame
          local cameraChanged=false
          local cleaned=false
          local function cleanup()
            if cleaned then return end
            cleaned=true; fn536(false)
            if hum.Parent then hum.AutoRotate=oldAuto end
            if root.Parent and hum.Parent then hum:MoveTo(root.Position) end
            if camera and oldCamera and cameraChanged then camera.CFrame=oldCamera end
            if __L3.bladeAimLabel then __L3.bladeAimLabel:SetText("M1: farm parado") end
          end
          __L3.bladeCombatCleanup=cleanup
          hum.AutoRotate=false
          local params=RaycastParams.new()
          params.FilterType=Enum.RaycastFilterType.Exclude
          local excluded={character}
          local live=v966:FindFirstChild("Live")
          if live then table.insert(excluded,live) end
          if __L3.bladeCellVisual then table.insert(excluded,__L3.bladeCellVisual) end
          params.FilterDescendantsInstances=excluded; params.RespectCanCollide=true
          local function floor(position)
            return v966:Raycast(position+Vector3.new(0,1,0),Vector3.new(0,-9,0),params)
          end
          local baseFloor=floor(anchor)
          local failedSteps={}
          local function canStand(position)
            baseFloor=baseFloor or floor(anchor)
            for index=#failedSteps,1,-1 do
              if os.clock()>=failedSteps[index].untilTime then table.remove(failedSteps,index) end
            end
            for _,entry in failedSteps do
              if os.clock()<entry.untilTime and (entry.position-position).Magnitude<0.4 then return false end
            end
            local hit=floor(position)
            if not baseFloor or not hit or hit.Normal.Y<0.7 or math.abs(hit.Position.Y-baseFloor.Position.Y)>1.2 then return false end
            local delta=position-root.Position
            return delta.Magnitude<0.1 or v966:Raycast(root.Position,delta,params)==nil
          end
          local function visible(position,target)
            return v966:Raycast(position,target-position,params)==nil
          end
          local function running()
            return tbl303[1] and LocalPlayer21.Character==character and root.Parent and hum.Parent
              and hum.Health>0 and __L3.bladeFarmAssigned=="shriekers"
          end
          fn536(true)
          local ok,err=pcall(function()
            local nextPlan=0
            local plan
            while running() and not done() do
              local current=root.Position
              local flatOffset=Vector3.new(current.X-anchor.X,0,current.Z-anchor.Z).Magnitude
              if flatOffset>__L3.bladeValue("BladeM1Step",1.5)+3 then
                __L3.bladeAimLabel:SetText("M1: fora do ponto; procurando um passo seguro para voltar")
                local elevated=current.Y-anchor.Y>4
                local recovery
                local candidates={anchor}
                for _,radius in {2.5,4} do
                  for index=0,7 do
                    local angle=index*math.pi/4
                    table.insert(candidates,anchor+Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius))
                  end
                end
                for _,candidate in candidates do
                  local horizontal=Vector3.new(candidate.X-current.X,0,candidate.Z-current.Z).Magnitude
                  -- Walking toward the point directly underneath a mob pile cannot step off it.
                  if (not elevated or horizontal>=2) and (candidate==anchor or __L3.bladeInCell(candidate,bounds)) and canStand(candidate) then
                    recovery=candidate;break
                  end
                end
                if recovery then
                  hum:MoveTo(recovery)
                  local recoverDeadline=os.clock()+1.5
                  while running() and not done() and (root.Position-recovery).Magnitude>1 and os.clock()<recoverDeadline do task.wait(0.05) end
                  if root.Parent then
                    if (root.Position-recovery).Magnitude>1 then
                      if #failedSteps>=16 then table.remove(failedSteps,1) end
                      table.insert(failedSteps,{position=recovery,untilTime=os.clock()+3})
                    end
                    hum:MoveTo(root.Position)
                  end
                end
                plan=nil;nextPlan=0
                task.wait(0.3)
                continue
              end
              -- Height never pauses M1. Replan from the current position after climbing a mob,
              -- and avoid choosing a floor point just to descend from the pile.
              if plan and math.abs(plan.position.Y-current.Y)>2 then plan=nil end
              if not plan or os.clock()>=nextPlan then
                plan=__L3.bladeAimPlan(anchor,current,initialLook,targetsProvider(),bounds,function(position)
                  return math.abs(position.Y-current.Y)<=2 and canStand(position)
                end,visible)
                nextPlan=os.clock()+1
                if __L3.bladeAimLabel then
                  __L3.bladeAimLabel:SetText(string.format("M1: alcance estimado %d alvos | passo max. %.1f studs",plan.count,__L3.bladeValue("BladeM1Step",1.5)))
                end
              end
              if plan.count==0 then
                if __L3.bladeCombatMode=="unlock" then __L3.bladeAimLabel:SetText("Soco normal: sem alvo visivel ao alcance de 5 studs") end
                task.wait(0.2);continue
              end
              if (root.Position-plan.position).Magnitude>0.5 and canStand(plan.position) then
                hum:MoveTo(plan.position)
                local deadline=os.clock()+0.8
                while running() and not done() and (root.Position-plan.position).Magnitude>0.5 and os.clock()<deadline do task.wait(0.05) end
                if not running() or done() then break end
                hum:MoveTo(root.Position)
                if (root.Position-plan.position).Magnitude>0.75 then
                  if #failedSteps>=16 then table.remove(failedSteps,1) end
                  table.insert(failedSteps,{position=plan.position,untilTime=os.clock()+3})
                  plan=__L3.bladeAimPlan(anchor,root.Position,initialLook,targetsProvider(),bounds,function() return false end,visible)
                  if plan.count==0 then task.wait(0.2); continue end
                end
              end
              root.CFrame=CFrame.lookAt(root.Position,root.Position+plan.direction)
              if camera and __L3.bladeValue("BladeAimCamera",true) then
                cameraChanged=true
                camera.CFrame=CFrame.lookAt(root.Position-plan.direction*10+Vector3.new(0,6,0),root.Position+plan.direction*4)
              end
              local attackDeadline=os.clock()+1.5
              while running() and not done() and fn576() and os.clock()<attackDeadline do task.wait(0.03) end
              if not running() or done() then break end
              if __L3.bladeCombatMode=="unlock" then
                if __L3.bladePlainPunch(running) then task.wait(0.2) else task.wait(0.25) end
              elseif __L3.bladeCombatMode=="fist" then
                if __L3.bladeManaPunch(running) then task.wait(0.2) else task.wait(0.25) end
              else
                __L3.bladeCounting=true;fn577();task.wait(0.15)
              end
            end
          end)
          cleanup()
          __L3.bladeCombatCleanup=nil
          if not ok then error(err) end
        end
        a1723.Maid:Give(function() if __L3.bladeCombatCleanup then __L3.bladeCombatCleanup() end end)
        __L3.bladeXPShriekersLegacy=function()
          local save=tbl308[1]
          local cell=__L3.bladeCellLoad()
          local bounds,attackPoint=__L3.bladeCellBounds(cell)
          if not bounds then
            __L3.bladeStatus("P1: marque a cela em blade 23 > Cela XP antes de farmar Shriekers")
            task.wait(1); return false
          end
          if __L3.setInn("Castle Sanctuary")==false then return false end
          fn580(__L3.tbl321)
          fn580({attackPoint})
          -- This gate is executed once per farm entry, before any attacks.
          while tbl303[1] and __L3.bladeFarmAssigned=="shriekers" do
            local mobs=__L3.bladeShriekers()
            local full=0
            for _,mob in mobs do if __L3.bladeFullHP(mob.hum) then full+=1 end end
            __L3.bladeStatus(string.format("P1 Shriekers: waiting full HP %d/%d (expected %d)",full,#mobs,__L3.bladeValue("BladeShrCount",50)))
            if #mobs>=__L3.bladeValue("BladeShrCount",50) and full==#mobs then break end
            task.wait(0.25)
          end
          if not tbl303[1] or __L3.bladeFarmAssigned~="shriekers" then return false end
          local connections={}
          local watched={}
          local active=true
          local lastSave=0
          save.bladeDamage=tonumber(save.bladeDamage) or 0
          save.bladeMobDamage=save.bladeMobDamage or {}
          local function attach(mob)
            if watched[mob.hum] then return end
            watched[mob.hum]=true
            local previous=mob.hum.Health
            local id=tostring(#connections+1)..":"..mob.model.Name
            table.insert(connections,mob.hum.HealthChanged:Connect(function(value)
              local delta=previous-value
              previous=value -- Healing always updates the baseline, never the total.
              if not active or not tbl303[1] or __L3.bladeFarmAssigned~="shriekers" then return end
              if delta>0 and mob.model.Parent==v966:FindFirstChild("Live")
                and __L3.bladeMobInCell(mob.root,bounds) then
                save.bladeDamage+=delta
                save.bladeMobDamage[id]=(save.bladeMobDamage[id] or 0)+delta
                if os.clock()-lastSave>=0.5 then lastSave=os.clock(); fn542() end
              end
            end))
          end
          for _,mob in __L3.bladeShriekers() do attach(mob) end
          __L3.fn610()
          local ok,err=pcall(function()
            __L3.bladeAttack(function()
              for _,mob in __L3.bladeShriekers() do attach(mob) end
              __L3.bladeStatus(string.format("P1 XP: %.0f/%d damage | %.1f hit equivalents",save.bladeDamage,
                __L3.bladeValue("BladeDamageGoal",6700),save.bladeDamage/8))
              return save.bladeDamage>=__L3.bladeValue("BladeDamageGoal",6700)
                or __L3.bladeFarmAssigned~="shriekers"
            end,function()
              local targets={}
              for _,mob in __L3.bladeShriekers() do
                if mob.hum.Health>=10 then table.insert(targets,mob.root) end
              end
              return targets
            end,cell)
          end)
          active=false
          for _,connection in connections do connection:Disconnect() end
          fn542()
          if not ok then error(err) end
          return tbl303[1] and save.bladeDamage>=__L3.bladeValue("BladeDamageGoal",6700)
        end
        __L3.bladeScroomFarm=function()
          if not fn591("Sword") then fn543("P4"); return end
          local thrown=v966:FindFirstChild("Thrown")
          if thrown then
            local platform=Instance.new("Part")
            platform.Name="BladeScroomFloor"
            platform.Anchored=true; platform.CanCollide=true
            platform.Size=Vector3.new(579,1,457)
            platform.CFrame=CFrame.new(2078.95801,110.362061,-2296.52441)
            platform.Color=Color3.fromRGB(0,0,255); platform.Material=Enum.Material.Neon
            platform.Parent=thrown
            newResult61.p5part=platform
          end
          -- Explicit A2 only: never switch into the already-reserved Shrieker farm.
          local ok,result=pcall(__L3.fn631)
          newResult61.p5part=nil
          if not ok then error(result) end
          if result and tbl303[1] then fn543("P6") end
        end
        __L3.bladeXPLegacy=function()
          local save=tbl308[1]
          if save.bladeXPDone or (tonumber(save.bladeDamage) or 0)>=__L3.bladeValue("BladeDamageGoal",6700) then
            save.bladeXPDone=true
            __L3.bladePhase("B2_ORDERLY")
            return
          end
          if not save.bladeFarmJoined then save.bladeFarmJoined=DateTime.now().UnixTimestampMillis; fn542() end
          if not __L3.bladeIO.available() then
            __L3.bladeStatus("XP queue needs shared files or the remote server")
            task.wait(1); return
          end
          local slot=__L3.bladeFarmAssigned
          if not slot then
            if __L3.bladeValue("BladeFarm","Automatic")=="Shriekers" and not __L3.bladeCellBounds(__L3.bladeCellLoad()) then
              __L3.bladeStatus("P1: marque ataque e cantos em blade 23 > Cela XP")
              task.wait(0.5); return
            end
            if not __L3.bladeAtWaitingPoint then
              local point=__L3.bladePoint("blade_wait_point")
              if point then fn580({point}) end
              __L3.bladeAtWaitingPoint=true
            end
            __L3.bladeStatus("P1: both XP slots busy; waiting turn")
            task.wait(0.5); return
          end
          __L3.bladeAtWaitingPoint=false
          __L3.bladeWorker.farmState="running"; __L3.bladeWorker.slot=slot
          __L3.bladeWorkerTick()
          task.wait(0.6)
          __L3.bladeWorkerTick()
          if __L3.bladeFarmAssigned~=slot then
            __L3.bladeWorker.farmState="waiting"; __L3.bladeWorker.slot=nil
            task.wait(0.5); return
          end
          local ok,finished=pcall(function()
            if slot=="shriekers" then
              __L3.bladeFarmCell=__L3.bladeCellLoad()
              return __L3.bladeXPShriekers()
            end
            __L3.bladeStatus("P1 XP: Zombie Scrooms (existing 24-kill route)")
            return __L3.bladeScroomFarm() -- Explicit A2 with platform and recovery.
          end)
          __L3.bladeFarmCell=nil
          if slot=="scrooms" then
            local needsSword=tbl308[1].phase=="P4"
            finished=ok and tbl303[1] and tbl308[1].phase=="P6"
            if needsSword and tbl303[1] then
              __L3.bladeRelease()
              __L3.bladePhase("B1_SWORD")
              return
            end
            if tbl303[1] then __L3.bladePhase("B1_XP") end
          end
          if finished and tbl303[1] then
            save.bladeXPDone=true
            __L3.bladePhase("B2_ORDERLY")
            -- Leave the occupied farm before freeing it for the next account.
            if slot=="shriekers" then fn580({Vector3.new(5816,1241,907)})
            else fn580({__L3.vector317}) end
          end
          __L3.bladeRelease()
          if not ok then error("Blade XP routine failed: "..tostring(finished)) end
          if not finished then task.wait(1) end
        end
        __L3.bladePlainPunch=function(running)
          local character=LocalPlayer21.Character
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          if not hum or not running() then return false end
          local control=a1723.State.mana
          local previousOwner=a1723.State.bladeManaOwner
          a1723.State.bladeManaOwner=true
          local live=function() return running() and LocalPlayer21.Character==character end
          local ok,result=pcall(function()
            hum:UnequipTools()
            local deadline=os.clock()+2
            while live() and character:FindFirstChildWhichIsA("Tool") and os.clock()<deadline do task.wait(0.05) end
            if not live() or character:FindFirstChildWhichIsA("Tool") then
              __L3.bladeStatus("Soco normal: aguardando desequipar a espada");return false
            end
            if control and control.decharge then control.decharge() end
            deadline=os.clock()+2
            while live() and character:FindFirstChild("Charge") and os.clock()<deadline do task.wait(0.05) end
            if not live() or character:FindFirstChild("Charge") then
              __L3.bladeStatus("Soco normal: aguardando soltar a carga");return false
            end
            __L3.bladeCounting=true;__L3.bladeUnlockAwaiting=true
            fn577()
            deadline=os.clock()+1.5
            while live() and __L3.bladeUnlockAwaiting and os.clock()<deadline do task.wait(0.05) end
            return __L3.bladeUnlockAwaiting==false
          end)
          __L3.bladeUnlockAwaiting=nil
          if control and control.decharge then pcall(control.decharge) end
          a1723.State.bladeManaOwner=previousOwner
          if not ok then __L3.bladeStatus("Soco normal: falha temporaria; tentando novamente: "..tostring(result));return false end
          return result
        end
        __L3.bladeManaPunch=function(running)
          local character=LocalPlayer21.Character
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          local mana=character and character:FindFirstChild("Mana")
          local control=a1723.State.mana
          if not hum or not mana or not control or not control.chargeUntil or not running() then
            __L3.bladeStatus("Soco: aguardando personagem e controle de mana");return false
          end
          local previousOwner=a1723.State.bladeManaOwner
          a1723.State.bladeManaOwner=true
          local ok,result=pcall(function()
            local live=function() return running() and LocalPlayer21.Character==character end
            hum:UnequipTools()
            local weaponDeadline=os.clock()+2
            while live() and character:FindFirstChildWhichIsA("Tool") and os.clock()<weaponDeadline do task.wait(0.05) end
            if not live() or character:FindFirstChildWhichIsA("Tool") then return false end
            local reached=mana.Value>=94.9
            if not reached then
              local chargeDeadline=os.clock()+8
              reached=control.chargeUntil(95,function() return live() and os.clock()<chargeDeadline end)==true or mana.Value>=94.9
            end
            if control.decharge then control.decharge() end
            if not reached then
              __L3.bladeStatus("Soco: carga ainda nao chegou a 95%; tentando novamente")
              return false
            end
            -- Charge is released before M1. Do not demand 95% again after its release delay.
            local releaseDeadline=os.clock()+2
            while live() and character:FindFirstChild("Charge") and os.clock()<releaseDeadline do task.wait(0.05) end
            if not live() or character:FindFirstChild("Charge") then
              __L3.bladeStatus("Soco: aguardando soltar a carga de mana");return false
            end
            for hit=1,4 do
              local deadline=os.clock()+1.5
              while live() and fn576() and os.clock()<deadline do task.wait(0.05) end
              if not live() or fn576() then return false end
              __L3.bladeCounting=true
              fn577()
              task.wait(0.2)
            end
            return true
          end)
          if control.decharge then pcall(control.decharge) end
          a1723.State.bladeManaOwner=previousOwner
          if not ok then __L3.bladeStatus("Soco: erro ao executar sequencia: "..tostring(result));return false end
          return result
        end
        __L3.bladeXPShriekers=function()
          local save=tbl308[1]
          local cell=__L3.bladeCellLoad()
          local bounds,attackPoint=__L3.bladeCellBounds(cell)
          if not bounds then __L3.bladeStatus("Cela XP fixa indisponivel neste mapa");task.wait(0.5);return false end
          -- Full HP and three-second stability are checked only before starting this farm entry.
          local readySince
          while tbl303[1] and __L3.bladeFarmAssigned=="shriekers" do
            local mobs=__L3.bladeShriekers()
            local full=0
            for _,mob in mobs do if __L3.bladeFullHP(mob.hum) then full+=1 end end
            local ready=#mobs>=__L3.bladeValue("BladeShrCount",50) and full==#mobs
            if ready then readySince=readySince or os.clock() else readySince=nil end
            local remaining=readySince and math.max(0,3-(os.clock()-readySince)) or 3
            __L3.bladeStatus(string.format("PE8: cela %d/%d | full %d/%d | iniciar em %.1fs",#mobs,__L3.bladeValue("BladeShrCount",50),full,#mobs,remaining))
            if ready and remaining<=0 and __L3.bladeStanding() then break end
            task.wait(0.25)
          end
          if not tbl303[1] or __L3.bladeFarmAssigned~="shriekers" then return false end
          if not __L3.bladeMovePoint(9,true) then return false end
          if not __L3.bladeStanding() then return false end
          fn580({attackPoint})
          if not tbl303[1] then return false end
          local connections,watched={},{}
          local active=true
          local lastSave=0
          save.bladeDamage=tonumber(save.bladeDamage) or 0
          save.bladeFistDamage=tonumber(save.bladeFistDamage) or 0
          save.bladeUnlockHits=math.clamp(tonumber(save.bladeUnlockHits) or (save.bladeFistDamage>0 and 3 or 0),0,3)
          local function attach(mob)
            if watched[mob.hum] then return end
            watched[mob.hum]=mob
            local previous=mob.hum.Health
            connections[mob.hum]=mob.hum.HealthChanged:Connect(function(value)
              local delta=previous-value;previous=value
              if not active or not tbl303[1] or not __L3.bladeCounting or __L3.bladeFarmAssigned~="shriekers" then return end
              if delta>0 and mob.model.Parent==v966:FindFirstChild("Live") and __L3.bladeMobInCell(mob.root,bounds) then
                if __L3.bladeCombatMode=="sword" then save.bladeDamage+=delta
                elseif __L3.bladeCombatMode=="fist" then save.bladeFistDamage+=delta
                elseif __L3.bladeCombatMode=="unlock" and __L3.bladeUnlockAwaiting then
                  __L3.bladeUnlockAwaiting=false -- One landed M1 counts once, even when it hits many mobs.
                  save.bladeUnlockHits=math.min(3,save.bladeUnlockHits+1);fn542()
                end
                if os.clock()-lastSave>=0.5 then lastSave=os.clock();fn542() end
              end
            end)
          end
          local nextRefresh=0
          local function refresh()
            if os.clock()<nextRefresh then return end
            nextRefresh=os.clock()+0.5
            local live=v966:FindFirstChild("Live")
            for hum,mob in watched do
              if mob.model.Parent~=live then
                connections[hum]:Disconnect();connections[hum]=nil;watched[hum]=nil
              end
            end
            for _,mob in __L3.bladeShriekers() do attach(mob) end
          end
          refresh()
          local targets=function()
            local list={}
            for _,mob in __L3.bladeShriekers() do if mob.hum.Health>=10 then table.insert(list,mob.root) end end
            return list
          end
          local ok,err=pcall(function()
            if save.bladeDamage<6700 then
              __L3.bladeCombatMode="sword";__L3.bladeCounting=false
              __L3.fn610()
              __L3.bladeAttack(function()
                refresh()
                __L3.bladeStatus(string.format("P9: espada %.0f/6700 | soco %.0f/300",save.bladeDamage,save.bladeFistDamage))
                return save.bladeDamage>=6700 or __L3.bladeFarmAssigned~="shriekers"
              end,targets,cell)
            end
            __L3.bladeCounting=false;__L3.bladeCombatMode=nil
            if tbl303[1] and __L3.bladeFarmAssigned=="shriekers" and save.bladeDamage>=6700 and save.bladeFistDamage<300 then
              -- Let pending sword events settle before attributing any fist damage.
              task.wait(1)
              __L3.bladeCombatMode="unlock"
              local hum=LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChildOfClass("Humanoid")
              if hum then hum:UnequipTools() end
              if save.bladeUnlockHits<3 then
                __L3.bladeAttack(function()
                  refresh()
                  __L3.bladeStatus(string.format("P9: desbloqueando mana | socos sem mana %d/3",save.bladeUnlockHits))
                  return save.bladeUnlockHits>=3 or __L3.bladeFarmAssigned~="shriekers"
                end,targets,cell)
              end
              __L3.bladeUnlockAwaiting=nil
              if not tbl303[1] or __L3.bladeFarmAssigned~="shriekers" or save.bladeUnlockHits<3 then return end
              __L3.bladeCounting=false;__L3.bladeCombatMode="fist"
              __L3.bladeAttack(function()
                refresh()
                __L3.bladeStatus(string.format("P9: espada %.0f/6700 | mana punch %.0f/300",save.bladeDamage,save.bladeFistDamage))
                return save.bladeFistDamage>=300 or __L3.bladeFarmAssigned~="shriekers"
              end,targets,cell)
            end
          end)
          active=false;__L3.bladeCounting=false;__L3.bladeCombatMode=nil;__L3.bladeUnlockAwaiting=nil
          if a1723.State.mana and a1723.State.mana.decharge then pcall(a1723.State.mana.decharge) end
          for _,connection in connections do connection:Disconnect() end
          fn542()
          if not ok then error(err) end
          return tbl303[1] and save.bladeDamage>=6700 and save.bladeFistDamage>=300
        end
        __L3.bladeXP=function()
          local save=tbl308[1]
          if save.bladeXPDone or (save.bladeDamage or 0)>=6700 and (save.bladeFistDamage or 0)>=300 then
            save.bladeXPDone=true;__L3.bladePhase("B1_EXIT");return
          end
          if not save.bladeFarmJoined then save.bladeFarmJoined=DateTime.now().UnixTimestampMillis;fn542() end
          __L3.bladeWorkerTick()
          local slot=__L3.bladeFarmAssigned
          local preference=__L3.bladeValue("BladeFarm","Automatic")
          if preference~="Zombie Scrooms" and slot~="scrooms" and __L3.bladeShrApproachCharacter~=LocalPlayer21.Character then
            for _,index in {6,7,8} do if not __L3.bladeMovePoint(index,true) then return end end
            __L3.bladeShrApproachCharacter=LocalPlayer21.Character
          end
          if not slot then
            __L3.bladeStatus(preference=="Zombie Scrooms" and "P5: aguardando vaga nos Zombie Scrooms" or __L3.bladeXPWaitStatus())
            task.wait(0.3);return
          end
          __L3.bladeWorker.farmState="running";__L3.bladeWorker.slot=slot
          __L3.bladeWorkerTick();task.wait(0.6);__L3.bladeWorkerTick()
          if __L3.bladeFarmAssigned~=slot then __L3.bladeWorker.farmState="waiting";__L3.bladeWorker.slot=nil;return end
          local ok,finished=pcall(function()
            if slot=="shriekers" then
              __L3.bladeFarmCell=__L3.bladeCellLoad()
              return __L3.bladeXPShriekers()
            end
            __L3.bladeLocation="Zombie Scrooms"
            __L3.bladeScroomFarm()
            return tbl303[1] and tbl308[1].phase=="P6"
          end)
          __L3.bladeFarmCell=nil
          if slot=="scrooms" and tbl303[1] then
            if tbl308[1].phase=="P4" then __L3.bladeRelease();__L3.bladePhase("B1_SWORD");return end
            __L3.bladePhase("B1_XP")
          end
          if not ok then __L3.bladeRelease();error("Falha no XP: "..tostring(finished)) end
          if finished and tbl303[1] then
            save.bladeXPDone=true;save.bladeXPMethod=slot
            __L3.bladePhase("B1_EXIT")
          else __L3.bladeRelease();task.wait(0.3) end
        end
        __L3.bladeExitXP=function()
          local save=tbl308[1]
          if not save.bladeAtExitP10 then
            if save.bladeXPMethod=="shriekers" or save.bladeXPMethod==nil then
              if not __L3.bladeMovePoint(10,true) then return end
            else fn580({__L3.vector317});__L3.bladeLocation="Saida Zombie Scrooms" end
            save.bladeAtExitP10=true;fn542()
          end
          __L3.bladeRelease()
          if fn537() or not __L3.bladeStanding() then __L3.bladeStatus("P10: aguardando sair de Danger e levantar");task.wait(0.3);return end
          save.bladeSpawnTransitionAllowed=true;fn542()
          __L3.bladePhase("B2_ORDERLY")
        end
        __L3.bladeUseTespian=function()
          local save=tbl308[1]
          save.bladeTespianUsed=tonumber(save.bladeTespianUsed) or 0
          while tbl303[1] and save.bladeTespianUsed<5 do
            local before=__L3.bladeCount("Tespian Elixir")
            if before==0 then __L3.bladeStatus("P2: waiting for Tespian Elixir"); task.wait(1); return false end
            __L3.fn595(1)
            if not tbl303[1] then return false end
            if __L3.bladeCount("Tespian Elixir")<before then
              save.bladeTespianUsed+=1; fn542()
            else __L3.bladeStatus("P2: elixir consumption not confirmed"); task.wait(1); return false end
          end
          return save.bladeTespianUsed>=5
        end
        __L3.bladeOrderlyLegacy=function()
          local save=tbl308[1]
          if save.bladeOrderlyDone then __L3.bladePhase("B3_TRAIN"); return end
          if __L3.bladeValue("BladeOrderly","Rots")=="Quests" then
            if not __L3.bladeUseTespian() then return end
            __L3.bladePhase("B2_QUESTS1")
            return
          end
          if not save.bladeRotAtRenova then
            if __L3.setInn("Renova")==false then return end
            fn580({Vector3.new(-2126,609,-709)})
            save.bladeRotAtRenova=true; fn542()
          end
          if not a1723.State.joinRotReceiverQueue then
            __L3.bladeStatus("P2: waiting for Rot module to initialize"); task.wait(1); return
          end
          if not __L3.bladeRotJoined and save.bladeRotWasJoined and a1723.State.rotReceiverQueueComplete
            and a1723.State.rotReceiverQueueComplete() then
            save.bladeOrderlyDone=true; save.bladeRotCount=16
            __L3.bladePhase("B3_TRAIN")
            return
          end
          if not __L3.bladeRotJoined then
            if not a1723.State.joinRotReceiverQueue() then
              __L3.bladeStatus("P2: choose supplier accounts in blade 23 > Rot e filas > Alts and enable Blatant Mode")
              task.wait(1); return
            end
            __L3.bladeRotJoined=true
            save.bladeRotWasJoined=true
            fn542()
          end
          __L3.bladeStatus("P2: automatic Rot queue active; see Rot e filas for Master and progress")
          if a1723.State.rotReceiverQueueComplete and a1723.State.rotReceiverQueueComplete() then
            save.bladeOrderlyDone=true; save.bladeRotCount=16; fn542()
            __L3.bladePhase("B3_TRAIN")
          else task.wait(0.5) end
        end
        a1723.State.bladeRotProgress=function()
          local save=tbl308[1]
          if not save or save.phase~="B2_ORDERLY" then return nil,nil end
          return tonumber(save.bladeRotCount),save.runId
        end
        a1723.State.onRotDeliveryConfirmed=function(progress)
          local save=tbl308[1]
          if save and save.phase=="B2_ORDERLY" then
            save.bladeRotCount=math.clamp(progress,0,16);fn542()
          end
        end
        __L3.bladeOrderly=function()
          local save=tbl308[1]
          if save.bladeOrderlyDone then a1723.State.bladeReceiverAtP14=false;__L3.bladePhase("B3_TRAIN");return end
          if __L3.bladeValue("BladeOrderly","Rots")=="Quests" then
            save.bladeSpawnTransitionAllowed=true
            if not __L3.bladeUseTespian() then return end
            __L3.bladePhase("B2_QUESTS1");return
          end
          if not save.bladeRotAtRenova then
            if fn537() then __L3.bladeStatus("P10: aguardando Danger antes de PG11");task.wait(0.25);return end
            if not __L3.bladeMovePoint(11,true) then return end
            save.bladeSpawnTransitionAllowed=true
            if __L3.setInn("Renova")==false then return end
            save.bladeRotAtRenova=true;fn542()
          end
          if __L3.bladeRotWaitingCharacter~=LocalPlayer21.Character then
            for _,index in {12,13} do if not __L3.bladeMovePoint(index,true) then return end end
            __L3.bladeRotWaitingCharacter=LocalPlayer21.Character
            __L3.bladeRotAtP14Character=nil;a1723.State.bladeReceiverAtP14=false
          end
          if not a1723.State.joinRotReceiverQueue then __L3.bladeStatus("PE13: aguardando inicializacao da fila Rot");task.wait(0.25);return end
          if not __L3.bladeRotJoined then
            if not a1723.State.joinRotReceiverQueue() then __L3.bladeStatus("PE13: aguardando fila Rot local");task.wait(0.25);return end
            __L3.bladeRotJoined=true;save.bladeRotWasJoined=true;fn542()
          end
          if a1723.State.rotReceiverQueueComplete and a1723.State.rotReceiverQueueComplete() then
            save.bladeOrderlyDone=true;save.bladeRotCount=16
            a1723.State.bladeReceiverAtP14=false
            __L3.bladePhase("B3_TRAIN");return
          end
          local turn=a1723.State.rotReceiverHasTurn and a1723.State.rotReceiverHasTurn()
          if turn then
            if __L3.bladeRotAtP14Character~=LocalPlayer21.Character then
              if not __L3.bladeMovePoint(14,true) then return end
              if not __L3.bladePointReached(14) then return end
              __L3.bladeRotAtP14Character=LocalPlayer21.Character
              a1723.State.bladeReceiverAtP14=true
            end
            __L3.bladeStatus("P14: receptora ativa; coletando 16 Rots (veja Filas)")
          else
            a1723.State.bladeReceiverAtP14=false
            __L3.bladeStatus("PE13: aguardando a receptora anterior concluir 16 Rots")
          end
          task.wait(0.3)
        end
        __L3.bladeQuestReady=function(prefix)
          for _,key in __L2.tbl287 do
            if key:sub(1,#prefix)==prefix and not (tbl308[1].done and tbl308[1].done[key]) then return false end
          end
          return true
        end
        -- The Blade route buys these three base skills only. MercenaryCarry
        -- is deliberately not a completion requirement for this route.
        __L3.bladeWarriorSkills={"Pommel Strike","Action Surge","Plate Training"}
        __L3.bladeDraugVisit=function()
          local save=tbl308[1]
          save.done=save.done or {}
          if save.bladeDraugDone or save.done.p6_draug then return true end
          local point=Vector3.new(6145,1344,118)
          if save.boundInn~="Castle Sanctuary" or not near(point,25) then
            if __L3.setInn("Castle Sanctuary")==false then return false end
            if not fn580({point}) then return false end
            __L3.bladeLand()
          end
          local npc=HResult.nearestNPC("Draug",point)
          if not npc then __L3.bladeTrainWait("Draug: NPC indisponivel");return false end
          __L3.bladeStatus("Castle Sanctuary: falando com Draug antes da Ultra")
          local deadline=os.clock()+10
          local ok,accepted=pcall(FResult.run,npc,{"Thank you."},{
            shouldRun=function() return tbl303[1] and os.clock()<deadline end,
            doneWhen=__L2.tbl278,holdPosition=false,timeout=6,maxReplays=0,minHold=0,
          })
          if not ok or not accepted then __L3.bladeTrainWait("Draug: dialogo nao confirmado");return false end
          save.bladeDraugDone=true;save.done.p6_draug=true;fn542()
          return true
        end
        __L3.bladeTrainingCount=function(skills)
          return #skills-#__L2.fn502(skills)
        end
        __L3.bladeTrainWait=function(name,confirmed)
          __L3.bladeStatus(name..": aguardando Silver/Orderly/XP; nova tentativa em 15s")
          -- Touch dropped Silver without moving away from the trainer.
          __L3.bladeBagPickup(true)
          local deadline=os.clock()+15
          while tbl303[1] and os.clock()<deadline do
            if confirmed and confirmed() then break end
            task.wait(0.25)
          end
          __L3.bladeBagPickup(false)
        end
        __L3.bladeTrainPurchase=function(key,npc,anchor,answers,skills,limit)
          local save=tbl308[1]
          save.bladeTraining=save.bladeTraining or {}
          local progress=save.bladeTraining[key] or {confirmed=0}
          save.bladeTraining[key]=progress
          while tbl303[1] do
            local observed=__L3.bladeTrainingCount(skills)
            progress.confirmed=math.max(progress.confirmed or 0,observed)
            if progress.pending and ((tonumber(getServerValue("Silver")) or 0)<progress.pending.silver or observed>progress.pending.observed) then
              progress.confirmed=math.max(progress.confirmed,(progress.pending.confirmed or 0)+1)
              progress.pending=nil;fn542()
            end
            if progress.confirmed>=limit then progress.pending=nil;fn542();return true end
            local character=LocalPlayer21.Character
            if not __L3.bladeStanding() then task.wait(0.25);continue end
            local merchant=HResult.nearestNPC(npc,anchor)
            if not merchant or not near(anchor,25) then return false end
            local before=tonumber(getServerValue("Silver")) or 0
            progress.pending={silver=before,observed=observed,confirmed=progress.confirmed}
            fn542()
            __L3.bladeStatus(npc..": comprando skill "..(progress.confirmed+1).."/"..limit)
            local deadline=os.clock()+10
            local paymentSent=false
            local ok,err=pcall(function()
              FResult.run(merchant,answers,{
                allowAnswer=function(answer)
                  if answer==answers[#answers] then
                    if paymentSent then return false end
                    paymentSent=true
                  end
                  return true
                end,
                shouldRun=function() return tbl303[1] and LocalPlayer21.Character==character and os.clock()<deadline end,
                holdPosition=false,timeout=6,maxReplays=0,minHold=0,
              })
            end)
            if not ok then fn534("Trainer %s: %s",npc,tostring(err)) end
            -- Check all delayed results before another purchase, keeping exactly one in flight.
            __L3.bladeTrainWait(npc,function()
              return (tonumber(getServerValue("Silver")) or 0)<before or __L3.bladeTrainingCount(skills)>observed
            end)
          end
          return false
        end
        __L3.bladeTrainerApproach=function(key,inn,path)
          __L3.bladeTrainerCharacters=__L3.bladeTrainerCharacters or {}
          local character=LocalPlayer21.Character
          if __L3.bladeTrainerCharacters[key]==character and near(path[#path],25) then return true end
          if not near(path[#path],25) then
            if __L3.setInn(inn)==false then return false end
            if not fn580(path) then return false end
          end
          __L3.bladeLand()
          __L3.bladeTrainerCharacters[key]=LocalPlayer21.Character
          return tbl303[1]
        end
        __L3.bladeAlfricTrain=function()
          local progress=tbl308[1].bladeTraining and tbl308[1].bladeTraining.alfric
          if math.max(progress and progress.confirmed or 0,__L3.bladeTrainingCount(tbl271))>=3 then return true end
          if not __L3.bladeTrainerApproach("alfric","Renova",{Vector3.new(-2068,305,-634),Vector3.new(-1844,252,-265),Vector3.new(-1805,315,-227)}) then return false end
          return __L3.bladeTrainPurchase("alfric","Alfric",Vector3.new(-1805,315,-227),{"Yeah.","I'll pay."},tbl271,3)
        end
        __L3.bladeTrain=function()
          __L3.bladeStatus("P3: Alfric (limite de 3 skills) e Frey")
          if not __L3.bladeAlfricTrain() then return end
          local progress=tbl308[1].bladeTraining and tbl308[1].bladeTraining.frey
          if math.max(progress and progress.confirmed or 0,__L3.bladeTrainingCount(__L2.tbl279))<3 then
            if not __L3.bladeTrainerApproach("frey","Central Sanctuary",{Vector3.new(1921,258,-851),Vector3.new(1926,285,-864),Vector3.new(1905,285,-810),Vector3.new(1913,307,-813),Vector3.new(1955,309,-830)}) then return end
            if not __L3.bladeTrainPurchase("frey","Frey",Vector3.new(1954,309,-833),{"Is there anything you can teach me?","I'll pay."},__L2.tbl279,3) then return end
          end
          __L3.bladeStatus("P3: base e super confirmadas; seguindo para Jagen")
          __L3.bladePhase("P7")
        end
        __L3.bladeStep=function(phase)
          if phase=="B1_PREP" then __L3.bladePrepare()
          elseif phase=="B1_SWORD" then
            if __L3.bladeBuySword() and tbl303[1] then __L3.bladePhase("B1_XP") end
          elseif phase=="B1_XP" then __L3.bladeXP()
          elseif phase=="B1_EXIT" then __L3.bladeExitXP()
          elseif phase=="B2_ORDERLY" then __L3.bladeOrderly()
          elseif phase=="B2_QUESTS1" then
            __L3.bladeStatus("P2: existing quest route, first group")
            __L3.fn633()
            if tbl303[1] then
              __L3.bladePhase(__L3.bladeQuestReady("p6_") and "B2_QUESTS2" or "B2_QUESTS1")
            end
          elseif phase=="B2_QUESTS2" then
            if (tonumber(getServerValue("DaysSurvived")) or 0)<1 then __L3.fn639(); return end
            __L3.bladeStatus("P2: existing quest route, second group")
            __L3.fn637()
            if tbl303[1] and __L3.bladeQuestReady("p7_") then
              tbl308[1].bladeOrderlyDone=true
              __L3.bladePhase("B3_TRAIN")
            else task.wait(1) end
          elseif phase=="B3_TRAIN" then __L3.bladeTrain()
          else __L3.bladeStatus("Unknown Blade phase: "..tostring(phase)); task.wait(1) end
        end
        __L3.fn642 = function()
          if not tbl308[1] then
            tbl308[1] = fn541() or { phase = "P0", step = 0 }
          end
          if not tbl308[1].phase or tbl308[1].phase == "" then
            tbl308[1].phase = "P0"
          end
          if __L3.bladeEnabled() and game.PlaceId~=num274 then
            while tbl303[1] and not __L3.bladeSpawnReady and not tbl308[1].bladeStartSpawnDone do
              __L3.bladeStatus("Inicio: marcando spawn fixo em Alana")
              if __L3.setInn("Alana") then __L3.bladeSpawnReady=true;tbl308[1].bladeStartSpawnDone=true;fn542()
              else task.wait(1) end
            end
            if not tbl303[1] then return end
          end
          fn534("runCore: starting at phase %s", tostring(tbl308[1].phase))
          local huge5 = math.huge
          for i72 = 1, 5 do
            local res239 = fn494()
            if res239 and res239 > 0 then
              huge5 = math.min(huge5, res239)
            end
            task.wait(0.4)
          end
          local v1273 = Options8.ProgPing and Options8.ProgPing.Value or 0
          if
            tbl303[1]
            and v1273 > 0
            and huge5 < math.huge
            and huge5 > v1273
          then
            fn534("runCore: %.0fms ping here, hopping for a closer server", huge5)
            if fn558(string.format("%.0fms ping on arrival", huge5)) then
              return
            end
          end
          local v1274 = not __L3.bladeEnabled() and (Toggles8.AvoidOtherBots == nil or Toggles8.AvoidOtherBots.Value) and IResult.twinHere()
          if tbl303[1] and v1274 and fn558("another of your bots (" .. v1274.Name .. ") is already here") then
            return
          end
          IResult.claim(game.JobId)
          if not __L3.bladeSameServerResume then tbl308[1].boundInn = nil end
          __L3.bladeSameServerResume=nil
          local getJSONResult3 = qResult3.getJSON("prog_lastpos")
          if getJSONResult3 and tbl303[1] then
            task.wait(1.5)
            local v1275 = __L3.bladeThreatDistance()
            if v1275 > 0 and tbl303[1] then
              local vector325 = Vector3.new(getJSONResult3.x, getJSONResult3.y, getJSONResult3.z)
              local getPlayersResult26, v1276, v1277 = getResult23:GetPlayers()
              for k289, v1278 in getPlayersResult26, v1276, v1277 do
                if v1278 ~= LocalPlayer21 and not __L2.fn512(a1723, v1278) then
                  local v1279 = v1278.Character and v1278.Character:FindFirstChild("HumanoidRootPart")
                  if v1279 and (v1279.Position - vector325).Magnitude <= v1275 then
                    fn534("resume spot occupied by %s - hopping", v1278.Name)
                    if fn558("player at resume spot", vector325, v1275) then
                      return
                    end
                    break
                  end
                end
              end
            end
          end
          if tbl308[1].phase == "P5" and tbl303[1] and fn583(__L3.vector315, num298) then
            fn534("P5: pit occupied on arrival, hopping again")
            tbl308[1].a2resume = true
            fn542()
            if fn558("A2 pit occupied on arrival", __L3.vector315, num298) then
              return
            end
          end
          qResult3.remove("prog_lastpos")
          __L3.fn641()
          if __L2.fn503(__L2.tbl282) then
            fn546()
          end
          if tbl308[1].startSilver == nil then
            tbl308[1].startSilver = getServerValue("Silver")
            fn542()
          end
          while tbl303[1] do
            local phase = tbl308[1].phase
            if phase == "DONE" then
              fn534("progression complete")
              break
            end
            if __L3.bladeEnabled() and phase:sub(1,1)=="B" then
              __L3.bladeStep(phase)
            elseif phase == "P0" then
              fn543("P1")
            elseif phase == "P1" then
              __L3.fn598()
            elseif phase == "P2" then
              __L3.fn599()
            elseif phase == "P3" then
              __L3.fn608()
            elseif phase == "P4" then
              __L3.fn609()
            elseif phase == "P5" then
              __L3.fn632()
            elseif phase == "P6" then
              __L3.fn633()
            elseif phase == "KHEI" then
              if game.PlaceId ~= num274 then
                fn534("phase KHEI but this is not Khei, restarting from P0")
                tbl308[1].kheiStep = nil
                fn543("P0")
              else
                if not a1723.State.kheiSequence then
                  break
                end
                a1723.State.kheiSequence()
              end
            elseif phase == "P7" then
              __L3.fn640()
            else
              fn534("phase %s not yet implemented - idling", tostring(phase))
              while true do
                if not (tbl303[1] and tbl308[1].phase == phase) then
                  break
                end
                task.wait(1)
              end
            end
            -- Covers both Blade steps and the legacy ultra/Khei steps they hand off to.
            task.wait(0.1)
          end
        end
        __L3.vector318 = Vector3.new(-3622, 1220, 2241)
        __L3.vector319 = Vector3.new(-1539, 621, 1888)
        __L3.tbl331 = { "What do you mean?", "How?" }
        __L3.num324 = 3
        __L3.num325 = 6
        __L3.tbl332 = {
          Vector3.new(-1552, 248, 1876),
          Vector3.new(-632, 237, 1894),
          Vector3.new(-614, 281, 1646),
          Vector3.new(-255, 302, 1634),
          Vector3.new(-241, 505, 1618),
        }
        __L3.fn643 = function(a1821)
          local NPCs8 = v966:FindFirstChild("NPCs")
          if not NPCs8 then
            return nil
          end
          local nearestModelResult2, v1280 = HResult.nearestModel(NPCs8, "Purity", __L3.vector318)
          if not nearestModelResult2 or not v1280 or v1280 > (a1821 or 20) then
            return nil
          end
          return nearestModelResult2, nearestModelResult2:FindFirstChild("HumanoidRootPart")
        end
        __L3.fn644 = function()
          local v1281 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not (v1281 and firetouchinterest) then
            return false
          end
          local v1282
          local getDescendantsResult14, v1283, v1284 = v966:GetDescendants()
          for k290, v1285 in getDescendantsResult14, v1283, v1284 do
            if v1285.Name == "LookIntoMirror" and v1285:IsA("BasePart") then
              v1282 = v1285
              break
            end
          end
          if not v1282 then
            fn534("khei: LookIntoMirror not found")
            return false
          end
          pcall(function()
            firetouchinterest(v1282, v1281, 0)
            firetouchinterest(v1282, v1281, 1)
          end)
          return true
        end
        __L3.fn645 = function()
          local Character66 = LocalPlayer21.Character
          local flag72 = false
          local num384 = 0
          while true do
            if not (tbl303[1] and num384 < 40) then
              break
            end
            fn547()
            local Character67 = LocalPlayer21.Character
            if Character67 and v969:HasTag(Character67, "Spired") then
              flag72 = true
            end
            if Character67 and Character67 ~= Character66 and Character67:FindFirstChild("HumanoidRootPart") then
              return flag72
            end
            task.wait(0.3)
            num384 += 0.3
          end
          return flag72
        end
        __L3.fn646 = function(a1822)
          tbl308[1] = tbl308[1] or {}
          tbl308[1].phase = "KHEI"
          tbl308[1].kheiStep = a1822
          fn542()
        end
        a1723.State.kheiSequence = function()
          tbl308[1] = tbl308[1] or fn541() or {}
          tbl308[1].startClock = tbl308[1].startClock or os.time()
          tbl308[1].kheiClock = tbl308[1].kheiClock or os.time()
          tbl308[1].runId = xResult2.setRunId(tbl308[1].runId)
          fn542()
          local v1286 = tbl308[1].kheiStep or "inn"
          fn534("khei: starting spire run at step %s", v1286)
          __L3.fn641()
          if not tbl303[1] then
            return
          end
          local leaderstats3 = LocalPlayer21:WaitForChild("leaderstats", 15)
          if leaderstats3 then
            leaderstats3:WaitForChild("UberTitle", 5)
          end
          local res240 = fn496()
          if res240 ~= "" then
            fn534("khei: already titled %s, not going back to the spire", res240)
            tbl308[1].kheiStep = nil
            tbl308[1].phase = "DONE"
            fn542()
            __L2.fn524("Already an uber", string.format("%s already holds %s, stopping", fn554(), res240))
            if v1009 then
              v1009()
            end
            return
          end
          if v1286 == "inn" then
            local flag73 = false
            for i73 = 1, num277 do
              if not tbl303[1] then
                return
              end
              fn556(25, true)
              fn534("Khei: binding Cavern Sanctuary, attempt %d/%d", i73, num277)
              if __L3.setInn("Cavern Sanctuary", true) then
                flag73 = true
                break
              end
              if i73 >= num282 and fn494() > num283 then
                fn534("Khei: %.0fms ping after %d inn tries - hopping to retry in a closer server", fn494(), i73)
                fn558(string.format("%.0fms ping stalling the Cavern Sanctuary bind", fn494()))
                return
              end
              task.wait(2)
            end
            if not flag73 then
              __L2.fn521(string.format("Khei: could not bind Cavern Sanctuary after %d tries", num277))
              if v1009 then
                v1009()
              end
              return
            end
            __L3.fn646("spire")
            v1286 = "spire"
          end
          if v1286 == "spire" and tbl308[1].spireGiven then
            fn534("khei: the sacrifice was already given, moving on rather than spending a second life")
            __L3.fn646("valter")
            v1286 = "valter"
          end
          if v1286 == "spire" then
            local flag74 = false
            for i74 = 1, num278 do
              if not tbl303[1] then
                fn534("Khei: stopped while reaching the spire")
                return
              end
              fn534("Khei: reaching Flagellant's Spire, attempt %d/%d", i74, num278)
              local fn663 = function()
                local res247, v1296 = __L3.fn643(60)
                return v1296 and v1296.Position or nil
              end
              if fn663() then
                if __L3.fn634(fn663, 1) then
                  flag74 = true
                  break
                end
              end
              if i74 >= num282 and fn494() > num283 then
                fn534("Khei: %.0fms ping after %d spire tries - hopping to retry elsewhere", fn494(), i74)
                fn558(string.format("%.0fms ping stalling the spire teleport", fn494()))
                return
              end
              task.wait(num279)
            end
            if not flag74 then
              __L2.fn521(string.format("Khei: could not reach Flagellant's Spire after %d tries", num278))
              if v1009 then
                v1009()
              end
              return
            end
            local res241 = __L3.fn643(30)
            if not res241 then
              __L2.fn521("Khei: no Purity NPC at the spire, stopping")
              if v1009 then
                v1009()
              end
              return
            end
            local res242 = fn498()
            local num385 = tick() + num280
            while true do
              if not (tbl303[1] and tick() < num385 and not (fn497() and res242.seen)) then
                break
              end
              task.wait(0.2)
            end
            fn534(
              "Khei: at the spire, spawned=%s sawForcefield=%s up=%s",
              tostring(fn497() ~= nil),
              tostring(res242.seen),
              tostring(res242.up())
            )
            local v1287
            if not fn497() then
              v1287 = string.format("never finished spawning at the spire (%ds)", num280)
            elseif not res242.seen then
              v1287 = string.format("no spawn forcefield seen at the spire (%ds), not talking", num280)
            else
              for i75 = 1, 3 do
                if not tbl303[1] or not res242.up() then
                  break
                end
                v1013(Vector3.new(-3626, 1340, 2244))
                task.wait(1)
                v1013(Vector3.new(-3622, 1218, 2248))
                task.wait(1.5)
              end
              if res242.up() then
                v1287 = "forcefield would not drop at the spire"
              end
            end
            res242.stop()
            if not tbl303[1] then
              return
            end
            if v1287 then
              __L2.fn521("Khei: " .. v1287)
              if v1009 then
                v1009()
              end
              return
            end
            fn547()
            local Character68 = LocalPlayer21.Character
            tbl308[1].spireGiven = true
            fn542()
            local res243 = fn588(
              "Purity",
              res241:FindFirstChild("HumanoidRootPart") and res241.HumanoidRootPart.Position or __L3.vector318,
              { "I give myself.", "I give my life." }
            )
            if not __L3.fn645() then
              if not res243 and LocalPlayer21.Character == Character68 then
                fn534("khei: nothing was sent and the body is untouched, so the sacrifice is still owed")
                tbl308[1].spireGiven = nil
                fn542()
              end
              __L2.fn521("Khei: sacrificed but no Spired tag, stopping")
              if v1009 then
                v1009()
              end
              return
            end
            __L3.fn646("valter")
          end
          if not tbl303[1] then
            fn534("Khei: stopped right after the spire, before the Valter leg")
            return
          end
          task.wait(2)
          if not near(__L3.vector319, 150) then
            fn534("Khei: not at the spire exit yet, waiting for the respawn to settle")
            local num386 = tick() + num281
            while true do
              if not (tbl303[1] and tick() < num386 and not near(__L3.vector319, 150)) then
                break
              end
              task.wait(1)
            end
          end
          if tbl303[1] and not near(__L3.vector319, 150) then
            fn534("Khei: still away from the spire exit - teleporting back rather than stopping the run")
            __L3.fn634(__L3.vector319)
            task.wait(2)
          end
          if not tbl303[1] then
            fn534("Khei: stopped while returning to the spire exit")
            return
          end
          fn580(__L3.tbl332)
          if not tbl303[1] then
            fn534("Khei: stopped while pathing to Valter")
            return
          end
          local res244 = nearestNPC("Valter", __L3.tbl332[#__L3.tbl332])
          local v1288 = res244 and res244:FindFirstChild("HumanoidRootPart")
          local v1289 = LocalPlayer21.Character and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
          if not (v1288 and v1289 and (v1288.Position - v1289.Position).Magnitude <= 10) then
            __L2.fn521("Khei: Valter out of reach, stopping")
            if v1009 then
              v1009()
            end
            return
          end
          local Position8 = v1288.Position
          local res245 = fn588("Valter", Position8, __L3.tbl331)
          if not tbl303[1] then
            fn534("Khei: stopped after talking to Valter")
            return
          end
          if not res245 then
            fn534("Khei: Valter took none of the dialogue, running it once more before the mirror")
            task.wait(1.5)
            fn588("Valter", Position8, __L3.tbl331)
            if not tbl303[1] then
              return
            end
          end
          if not __L3.fn644() then
            __L2.fn521("Khei: could not touch the mirror, stopping")
            if v1009 then
              v1009()
            end
            return
          end
          task.wait(3)
          if not tbl303[1] then
            fn534("Khei: stopped after touching the mirror")
            return
          end
          local res246 = fn496()
          for i76 = 1, __L3.num324 do
            if res246 ~= "" or not tbl303[1] then
              break
            end
            fn534("Khei: no uber title after the mirror, talking to Valter again (%d/%d)", i76, __L3.num324)
            fn588("Valter", Position8, __L3.tbl331)
            local num387 = tick() + __L3.num325
            while true do
              if not (tbl303[1] and res246 == "" and tick() < num387) then
                break
              end
              task.wait(0.5)
              res246 = fn496()
            end
          end
          if not tbl303[1] then
            fn534("Khei: stopped while waiting on the uber title")
            return
          end
          tbl308[1].kheiStep = nil
          tbl308[1].phase = "DONE"
          fn542()
          local v1290 = LocalPlayer21.Character ~= nil and v969:HasTag(LocalPlayer21.Character, "Danger")
          pcall(
            __L2.scopedResult.embedWith,
            "@everyone",
            fn555(res246 ~= "" and "Auto Progression complete" or "Auto Progression failed", res246 ~= "" and 5763719 or 15548997, {
              string.format("**Uber:** `%s`", res246 ~= "" and res246 or "still blank, something went wrong"),
              string.format("**Day:** `%s`", tostring(getServerValue("DaysSurvived"))),
            }, {
              {
                name = "Time Taken",
                value = __L2.fn510(tbl308[1].startClock, tbl308[1].kheiClock),
                inline = true,
              },
              {
                name = "Silver",
                value = __L2.fn511(tbl308[1].startSilver, getServerValue("Silver")),
                inline = true,
              },
            })
          )
          if res246 == "" then
            __L2.fn521("Khei: no uber title, stopping")
            if v1009 then
              v1009()
            end
            return
          end
          if v1290 or LocalPlayer21.Character and v969:HasTag(LocalPlayer21.Character, "Danger") then
            fn534("khei: tagged Danger after Valter, staying put instead of leaving")
            if v1009 then
              v1009()
            end
            return
          end
          local flag75 = false
          local getPlayersResult27, v1291, v1292 = getResult23:GetPlayers()
          for k291, v1293 in getPlayersResult27, v1291, v1292 do
            if v1293 ~= LocalPlayer21 and not __L2.fn512(a1723, v1293) then
              local v1294 = v1293.Character and v1293.Character:FindFirstChild("HumanoidRootPart")
              if v1294 and (v1294.Position - vector36).Magnitude <= 300 then
                flag75 = true
                break
              end
            end
          end
          if flag75 then
            fn534("khei: player near the exit, menuing from Valter")
            __L2.fn517()
            if v1009 then
              v1009()
            end
            return
          end
          local progKillWhenClearResult3 = a1723.State.progKillWhenClear()
          if not progKillWhenClearResult3 then
            fn534("khei: no character at the exit, stopping")
            if v1009 then
              v1009()
            end
            return
          end
          local num388 = 0
          repeat
            fn547()
            task.wait(0.3)
            num388 += 0.3
            local v1295 = LocalPlayer21.Character
                and LocalPlayer21.Character ~= progKillWhenClearResult3
                and LocalPlayer21.Character:FindFirstChild("HumanoidRootPart")
              or num388 > 20
            if v1295 then
              continue
            end
            v1295 = not tbl303[1]
          until v1295
          task.wait(2)
          if near(vector36, 150) then
            fn580({ vector37 })
          else
            fn534("khei: respawned away from the exit, menuing from here")
          end
          __L2.fn517()
          if v1009 then
            v1009()
          end
        end
        __L3.fn647 = function()
          if tbl303[1] then
            return
          end
          tbl303[1] = true
          tbl304[1] = false
          fn531(true)
          fn532(false)
          fn568()
          __L3.bladeCoreRunning=true
          task.spawn(function()
            local ok123, result118 = pcall(a1723.State.kheiSequence)
            __L3.bladeCoreRunning=false
            if not ok123 and not __L3.bladeMenuPause then
              fn534("khei sequence stopped on an error: %s", tostring(result118))
              xResult2.textBounded("@everyone Auto-Sigil stopped in Khei on an error: **" .. tostring(result118) .. "**")
              v1009()
            end
          end)
        end
        __L3.fn648 = function(a1823)
          if tbl303[1] then
            return
          end
          if a1823 then
            local res248 = fn541()
            if res248 and res248.phase == "DONE" then
              fn534("start: resumed onto a finished run, not starting another")
              qResult3.remove("progression_active")
              qResult3.remove("khei_run")
              return
            end
          end
          local resumeSave=a1823 and fn541() or nil
          if __L3.bladeEnabled() or (resumeSave and type(resumeSave.bladeRunConfig)=="table") then
            local run=__L3.bladeCaptureSetup(resumeSave)
            local planned=resumeSave or fn541()
            local phase=planned and planned.phase~="DONE" and (planned.bladePhase or planned.phase) or nil
            __L3.bladeValidateSetup(run,phase)
            __L3.bladeRunConfig=run
            a1723.State.bladeRunAlts=run.alts
            __L3.bladeSpawnReady=false
            __L3.bladeLockSetup(true)
          end
          tbl303[1] = true
          __L3.bladeRotJoined=false
          __L3.bladeAtWaitingPoint=false
          if Toggles8.ProximityNotifier then
            Toggles8.ProximityNotifier:SetValue(true)
          end
          if Toggles8.ProximityIgnoreAllies then
            Toggles8.ProximityIgnoreAllies:SetValue(true)
          end
          if Options8.ProximityDistance then
            Options8.ProximityDistance:SetValue(1000)
          end
          tbl304[1] = false
          fn531(true)
          fn532(false)
          tbl308[1] = fn541()
          if not tbl308[1] or tbl308[1].phase == "DONE" then
            tbl308[1] = {
              phase = "P0",
              step = 0,
              startDay = getServerValue("DaysSurvived"),
              startClock = os.time(),
              startSilver = getServerValue("Silver"),
              serverhops = 0,
            }
          end
          if game.PlaceId == num274 then
            tbl308[1].phase = "KHEI"
            tbl308[1].kheiStep = tbl308[1].kheiStep or "inn"
            tbl308[1].kheiClock = tbl308[1].kheiClock or os.time()
          elseif tbl308[1].phase == "KHEI" then
            fn534("start: stale Khei state on Gaia, beginning a fresh run")
            tbl308[1] = {
              phase = "P0",
              step = 0,
              startDay = getServerValue("DaysSurvived"),
              startClock = os.time(),
              startSilver = getServerValue("Silver"),
              serverhops = 0,
            }
          end
          if __L3.bladeEnabled() and game.PlaceId~=num274 then
            tbl308[1].phase=tbl308[1].bladePhase or "B1_PREP"
            tbl308[1].bladePhase=tbl308[1].phase
            tbl308[1].bladeRunConfig=__L3.bladeRunConfig
            tbl308[1].bladeAccountJoined=tbl308[1].bladeAccountJoined or DateTime.now().UnixTimestampMillis
            if tbl308[1].phase~="B2_ORDERLY" then
              if a1723.State.leaveRotReceiverQueue then a1723.State.leaveRotReceiverQueue("left") end
              if a1723.Library.Toggles.RotBotEnabled and a1723.Library.Toggles.RotBotEnabled.Value then
                a1723.Library.Toggles.RotBotEnabled:SetValue(false)
              end
            end
          end
          tbl308[1].startClock = tbl308[1].startClock or os.time()
          tbl308[1].runId = xResult2.setRunId(tbl308[1].runId)
          fn542()
          v1010 = nil
          if a1823 then
            local getJSONResult4 = qResult3.getJSON("prog_pathpoint")
            if getJSONResult4 and getJSONResult4.sig then
              v1010 = getJSONResult4
            end
          else
            qResult3.remove("prog_pathpoint")
            qResult3.remove("prog_lastpos")
          end
          fn548(true)
          local res249 = fn569()
          if #res249 > 0 then
            fn535("Auto-Sigil missing: " .. table.concat(res249, ", "))
            fn534("missing capabilities: %s", table.concat(res249, ", "))
          end
          fn572()
          qResult3.set("progression_active", "true")
          qResult3.set("progression_class", Options8.ProgClass and Options8.ProgClass.Value or "Sigil")
          IResult.claim(game.JobId)
          fn568()
          __L3.bladeCoreRunning=true
          task.spawn(function()
            local ok124, result119 = pcall(__L3.fn642)
            __L3.bladeCoreRunning=false
            if not tbl303[1] then __L3.bladeLockSetup(false) end
            if not ok124 and not __L3.bladeMenuPause then
              fn534("run stopped on an error: %s", tostring(result119))
              xResult2.textBounded("@everyone Auto-Sigil stopped on an error: **" .. tostring(result119) .. "**")
              v1009(true)
              if __L3.progStatusLabel then __L3.progStatusLabel:SetText("Sigil parado: "..tostring(result119)) end
              fn535("Sigil parado: "..tostring(result119))
            end
          end)
        end
        v1009 = function(a1824)
          if __L3.bladeMenuPause and not __L3.bladePausing and a1824~=true then return end
          __L3.kheiHandoffActive=false;__L3.kheiAttempt=nil
          if not __L3.bladePausing then __L3.kheiManualRequested=nil;qResult3.remove("khei_manual") end
          if a1824==true and __L3.bladeTerminalMenu then
            __L3.bladeTerminalMenu=nil;a1723.State.bladeManualMenu=false
          end
          if __L3.bladeMenuPause and not __L3.bladePausing then
            if a1824~=true then return end -- An unwinding stage must not cancel the requested pause.
            __L3.bladeMenuPause=nil;a1723.State.bladeManualMenu=false
            fn531(false);fn532(true)
          end
          if not tbl303[1] then
            return
          end
          tbl303[1] = false
          fn531(false)
          fn532(true)
          qResult3.remove("progression_active")
          IResult.release()
          qResult3.remove("khei_run")
          qResult3.remove("khei_handoff_servers")
          fn573()
          fn542()
          fn548(true)
          if __L3.bladeEnabled() then
            __L3.bladeRelease()
            __L3.bladeWorker.active=false
            __L3.bladeIO.writeJson(__L3.bladeWorkerPath,__L3.bladeWorker)
            __L3.bladeRotJoined=false
            if a1723.State.leaveRotReceiverQueue then a1723.State.leaveRotReceiverQueue("left") end
            if a1723.Library.Toggles.RotBotEnabled then a1723.Library.Toggles.RotBotEnabled:SetValue(false) end
          end
          __L3.bladeReleaseSetup()
          __L2.fn529()
          fn495()
          newResult61:DoCleaning()
          if a1824 then
            return
          end
          task.spawn(function()
            if __L3.bladeStayHere() then
              if a1723.State.bladeMenuInsteadOfLeave then
                a1723.State.bladeMenuInsteadOfLeave("execucao encerrada",true)
              end
              return
            end
            __L2.fn516()
            if a1723.State.safeTerminate then
              a1723.State.safeTerminate("auto-sigil: run stopped on its own")
            else
              pcall(function()
                LocalPlayer21:Kick("auto-sigil: run stopped on its own")
              end)
            end
          end)
        end
        __L3.bladePauseForMenu=function(reason)
          if __L3.bladeMenuPause or not tbl303[1] then return false end
          local pause={reason=reason,jobId=game.JobId,handoff=game.PlaceId~=num274 and qResult3.get("khei_run")=="true"}
          __L3.bladeMenuPause=pause;a1723.State.bladeManualMenu=true
          -- Run outside the watcher Maid: stopping must not cancel the callback doing the cleanup.
          task.spawn(function()
          if __L3.bladeMenuPause~=pause then return end
          __L3.bladePausing=true
          v1009(true)
          __L3.bladePausing=false
          if tbl307.tween then pcall(function() tbl307.tween:Cancel() end) end
          if a1723.State.mana and a1723.State.mana.decharge then a1723.State.mana.decharge() end
          fn531(true);fn532(false)
          __L3.progStatusLabel:SetText("Sigil: pausado; indo ao menu | "..tostring(reason))
            while __L3.bladeMenuPause==pause and __L3.bladeCoreRunning do task.wait(0.1) end
            if __L3.bladeMenuPause~=pause then return end
            fn542()
            fn531(true);fn532(false)
            if tbl308[1] and tbl308[1].phase=="DONE" and game.PlaceId~=num274 and Toggles8.ProgGoToKhei and Toggles8.ProgGoToKhei.Value then pause.handoff=true end
            pcall(__L3.bladeLand)
            -- forceMenu waits for Danger to clear; it never presses Play or hops.
            local ok,entered=pcall(vResult5.forceMenu,function() return __L3.bladeMenuPause==pause end)
            if __L3.bladeMenuPause~=pause then return end
            if not ok or not entered then
              __L3.bladeMenuPause=nil;a1723.State.bladeManualMenu=false
              fn531(false);fn532(true)
              __L3.progStatusLabel:SetText("Sigil pausado: nao foi possivel abrir o menu; Iniciar retoma o progresso")
              return
            end
            __L3.progStatusLabel:SetText("Sigil: no menu; aguardando Play manual para retomar")
            repeat task.wait(0.25) until __L3.bladeMenuPause~=pause or (not vResult5.startMenu() and fn497())
            if __L3.bladeMenuPause~=pause then return end
            __L3.bladeMenuPause=nil;a1723.State.bladeManualMenu=false
            __L3.bladeSameServerResume=game.PlaceId~=num274
            local resumed,message
            if pause.handoff and __L3.kheiAllowed() then
              qResult3.set("khei_run","true")
              resumed,message=pcall(a1723.State.progKheiHandoff,true)
            else resumed,message=pcall(__L3.fn648,true) end
            if not resumed then
              pcall(v1009,true);fn531(false);fn532(true)
              __L3.progStatusLabel:SetText("Sigil: erro ao retomar: "..tostring(message))
            end
          end)
          return true
        end
        -- Shared safety exit used by termination and the ROT supplier; never rejoins or presses Play.
        a1723.State.rotSafetyExit=function(reason)
          if not tbl303[1] then return false end
          if not __L3.bladeStayHere() and a1723.Library.Toggles.RotBotEnabled then a1723.Library.Toggles.RotBotEnabled:SetValue(false) end
          return fn557(reason)
        end
        a1723.State.bladeStayHere=__L3.bladeStayHere
        a1723.State.bladeMenuInsteadOfLeave=function(reason,terminal)
          if not __L3.bladeStayHere() then return false end
          if __L3.bladeMenuPause or __L3.bladeTerminalMenu then return true end
          if tbl303[1] and not terminal then return __L3.bladePauseForMenu(reason) end
          if tbl303[1] then v1009(true) end
          local token={};__L3.bladeTerminalMenu=token;a1723.State.bladeManualMenu=true
          task.spawn(function()
            local function active() return __L3.bladeTerminalMenu==token end
            local ok,entered=pcall(vResult5.forceMenu,active)
            if active() and ok and entered then
              if __L3.progStatusLabel then __L3.progStatusLabel:SetText("Sigil: no menu; aguardando Play manual | "..tostring(reason)) end
              repeat task.wait(0.25) until not active() or (not vResult5.startMenu() and fn497())
            end
            if active() then __L3.bladeTerminalMenu=nil;a1723.State.bladeManualMenu=false end
          end)
          return true
        end
        a1723.Maid:Give(function()
          __L3.bladeMenuPause=nil;__L3.bladeTerminalMenu=nil;a1723.State.bladeManualMenu=false
          a1723.State.bladeMenuInsteadOfLeave=nil;a1723.State.bladeStayHere=nil
        end)
        a1723.State.registerBot({
          name = "Auto Sigil",
          running = function()
            return tbl303[1] == true or __L3.bladeMenuPause~=nil
          end,
          stop = function()
            v1009(true)
          end,
        })
        __L3.tbl333 = { "ProgSkipIllusionist", "ProgMenuIllusionistSuper", "ProgStayInServer", "ProgKheiSkipIllusionist", "ProgKheiStayInServer", "ProgGoToKhei", "BladeAllowHop", "BladeAimCamera", "Blade23Mode" }
        __L3.tbl334 = { "ProgProximity", "ProgKheiProximity", "ProgPing", "ProgClass", "ProgRoute", "ProgStartPhase", "ProgWebhook", "BladeOrderly", "BladeFarm", "BladeSpeed", "BladeDamageGoal", "BladeShrCount", "BladeM1Range", "BladeM1Arc", "BladeM1Step" }
        __L3.tbl335 = { false }
        __L3.fn649 = function()
          local tbl355 = { toggles = {}, options = {} }
          for k292, v1297 in __L3.tbl333 do
            local item57 = Toggles8[v1297]
            if item57 then
              tbl355.toggles[v1297] = item57.Value
            end
          end
          for k293, v1298 in __L3.tbl334 do
            local item58 = Options8[v1298]
            if item58 then
              tbl355.options[v1298] = item58.Value
            end
          end
          return tbl355
        end
        __L3.fn650 = function()
          if a1723.State.bladeProfileLoaded then return end
          local getJSONResult5 = qResult3.getJSON("progression_settings")
          if type(getJSONResult5) ~= "table" then
            return
          end
          fn534(
            "restoreProgSettings: applying skipIllu=%s",
            tostring(getJSONResult5.toggles and getJSONResult5.toggles.ProgSkipIllusionist)
          )
          __L3.tbl335[1] = true
          if type(getJSONResult5.toggles) == "table" then
            for k294, v1299 in getJSONResult5.toggles do
              local item59 = Toggles8[k294]
              if item59 then
                pcall(function()
                  item59:SetValue(v1299)
                end)
              end
            end
          end
          if type(getJSONResult5.options) == "table" then
            for k295, v1300 in getJSONResult5.options do
              local item60 = Options8[k295]
              if item60 then
                pcall(function()
                  item60:SetValue(v1300)
                end)
              end
            end
          end
          __L3.tbl335[1] = false
        end
        __L3.hiddenSetup=a1723.Tabs.Blade23:AddRightGroupbox("Configuracao interna")
        __L3.hiddenSetup:SetVisible(false)
        __L3.bladeQueueLabel=a1723.State.bladeQueueTab:AddLabel("Filas locais: aguardando contas",true)
        __L3.progStatusLabel=progressionTab:AddLabel("Sigil: parado | escolha a rota e clique Iniciar Sigil",true)
        v1008=progressionTab:AddButton({Text="Iniciar Sigil",Tooltip=iResult5.blatant(),Func=function()
          if __L3.progStartClick then __L3.progStartClick()
          else __L3.progStatusLabel:SetText("Sigil: aguarde o carregamento das opcoes") end
        end})
        v1007=progressionTab:AddButton({Text="Parar Sigil",Func=function() v1009(true) end})
        fn531(false)
        __L3.hiddenSetup:AddButton({Text="Tudo neste PC (sem servidor)",Func=function()
          local ok,message=pcall(function()
            if not a1723.State.bladeUseLocal then error("Aguarde o carregamento do Sentinel",0) end
            return a1723.State.bladeUseLocal()
          end)
          __L3.progStatusLabel:SetText(ok and message or tostring(message))
        end})
        __L3.hiddenSetup:AddDropdown("ProgRoute", {Text="Progression route",Values={"Original","Blade/Sigil (3 stages)"},Default="Blade/Sigil (3 stages)",Multi=false})
        progressionTab:AddToggle("Blade23Mode", {Text="23",Default=false,
          Tooltip="Somente em Gaia: todos do servidor viram aliados salvos. Na etapa ROT, pega a conta downada livre mais proxima em ate 30 studs, sem selecionar Alts.",
          Callback=function()
            if a1723.State.bladeAddServerAllies then a1723.State.bladeAddServerAllies() end
          end})
        progressionTab:AddDropdown("BladeOrderly", {Text="Blade P2 Orderly method",Values={"Rots","Quests"},Default="Rots",Multi=false,Callback=function()
          if __L3.bladeSupplyLabel then __L3.bladeSupplyLabel:SetText(__L3.bladeSilverGoal()==100 and "Inicio Alana | Rots: 100 Silver, sem pocoes" or "Inicio Alana | Quests: 660 Silver + pocoes") end
        end})
        progressionTab:AddDropdown("BladeFarm", {Text="Blade XP preference",Values={"Automatic","Shriekers","Zombie Scrooms"},Default="Automatic",Multi=false})
        __L3.bladeSupplyLabel=progressionTab:AddLabel("Inicio Alana | Rots: 100 Silver, sem pocoes",true)
        progressionTab:AddLabel("Configure metodo, farm, velocidade, minimo de Shriekers e Alts (ou 23) antes de Iniciar. Filas locais; pontos e cela ja definidos.",true)
        __L3.hiddenSetup:AddSlider("BladeDamageGoal", {Text="Shrieker damage goal",Min=6400,Max=12000,Default=6700,Rounding=0})
        progressionTab:AddSlider("BladeSpeed",{Text="Velocidade de movimentacao",Min=20,Max=250,Default=100,Rounding=0})
        progressionTab:AddSlider("BladeShrCount", {Text="Minimum Shriekers before entry",Min=1,Max=100,Default=50,Rounding=0})
        progressionTab:AddToggle("BladeAllowHop", {Text="Allow hops during Blade route",Default=false,Tooltip="Off keeps all accounts and shared queues in the same server"})
        __L3.hiddenSetup:AddButton({Text="Mark supply point (stand near Alana)",Func=function() __L3.bladeMarkPoint("blade_supply_point") end})
        __L3.hiddenSetup:AddButton({Text="Mark waiting point",Func=function() __L3.bladeMarkPoint("blade_wait_point") end})
        __L3.bladeLabel=progressionTab:AddLabel("Rota de 14 pontos pronta | espada 6700 + mana punch 300 | configure e Inicie",true)
        __L3.hiddenSetup:AddButton({Text="Copy Blade progress",Func=function()
          local report={save=tbl308[1],worker=__L3.bladeWorker,route=__L3.bladeValue("ProgRoute","Original")}
          local json=aResult22.HttpService:JSONEncode(report)
          if setclipboard then setclipboard(json); fn535("Blade progress copied") else print(json) end
        end})
        __L3.bladeCellTab=__L3.hiddenSetup
        __L3.bladeCellTab:AddLabel("1. Fique no ponto de M1 e olhe para os mobs. 2. Marque dois cantos opostos POR DENTRO da cela. 3. Confira a area verde e salve.",true)
        __L3.bladeCellTab:AddButton({Text="Usar cela padrao (Necro)",Func=__L3.bladeCellUseDefault})
        __L3.bladeCellTab:AddButton({Text="Marcar ponto de M1 + direcao",Func=function() __L3.bladeCellMark("attack") end})
        __L3.bladeCellTab:AddButton({Text="Marcar canto A (dentro da cela)",Func=function() __L3.bladeCellMark("cornerA") end})
        __L3.bladeCellTab:AddButton({Text="Marcar canto B (oposto ao A)",Func=function() __L3.bladeCellMark("cornerB") end})
        __L3.bladeCellLabel=__L3.bladeCellTab:AddLabel("Cela XP: padrao Necro disponivel",true)
        __L3.bladeCellDescribe()
        __L3.bladeCellTab:AddButton({Text="Ver area e alvos da cela",Func=__L3.bladeCellShow})
        __L3.bladeCellTab:AddButton({Text="Ocultar marcacoes",Func=__L3.bladeCellClearVisual})
        __L3.bladeCellTab:AddButton({Text="Salvar/compartilhar cela XP",Func=__L3.bladeCellPublish})
        __L3.bladeCellTab:AddButton({Text="Copiar calibracao da cela",Func=__L3.bladeCellReport})
        __L3.bladeCellTab:AddInput("BladeCellImport",{Text="JSON da cela (para importar)",Default="",Finished=true})
        __L3.bladeCellTab:AddButton({Text="Importar calibracao",Func=function() __L3.bladeCellImport(Options8.BladeCellImport.Value) end})
        __L3.bladeCellTab:AddDivider()
        __L3.bladeCellTab:AddSlider("BladeM1Step",{Text="Passo maximo a partir do ponto",Min=0,Max=3,Default=1.5,Rounding=1,Suffix=" studs"})
        __L3.bladeCellTab:AddSlider("BladeM1Range",{Text="Alcance estimado do M1",Min=3,Max=12,Default=8,Rounding=1,Suffix=" studs"})
        __L3.bladeCellTab:AddSlider("BladeM1Arc",{Text="Arco estimado do M1",Min=30,Max=180,Default=110,Rounding=0,Suffix=" graus"})
        __L3.bladeCellTab:AddToggle("BladeAimCamera",{Text="Acompanhar mira com a camera",Default=true})
        __L3.bladeAimLabel=__L3.bladeCellTab:AddLabel("M1: alcance/angulo sao estimativas; XP continua confirmado pelo HP de cada mob.",true)
        progressionTab:AddDropdown("ProgClass", { Text = "Class", Values = { "Sigil" }, Multi = false, Default = "Sigil" })
        progressionTab:AddDropdown("ProgStartPhase", {
          Text = "Etapa ao iniciar (manual)",
          Values = {"Resume","1 - Alana: Silver e itens","2 - Comprar espada","3 - XP: espada e socos",
            "4 - Sair do XP / aguardar Danger","5 - Orderly: Rots ou Quests",
            "6 - Skills de Warrior e Sigil (base/super)","7 - Draug e Ultra (Jagen)","Khei - retomar sequencia"},
          Multi = false, Default = "Resume",
          Tooltip = "Pare o Sigil, escolha a etapa e clique Iniciar. Preserva XP, Rots e skills confirmados; etapas concluidas podem avancar automaticamente. Resume usa o progresso salvo.",
        })
        progressionTab:AddLabel("Etapa manual: Pare Sigil > escolha acima > Iniciar Sigil. A escolha vale uma vez; depois volta para Resume.",true)
        progressionTab:AddToggle("ProgSkipIllusionist", {
          Text = "Skip Illusionist Server (Gaia)",
          Default = false,
          Tooltip = "Ao ter Super, reage a Illusionist nao aliado. Stay In Server usa menu; caso contrario segue Allow Hops",
        })
        progressionTab:AddSlider("ProgProximity", {
          Text = "Proximity Check (Gaia)",
          Default = 300,
          Min = 0,
          Max = 1000,
          Rounding = 0,
          Suffix = " studs",
          Tooltip = "Distancia de nao aliados; Stay In Server pausa no menu. 0 desliga",
        })
        progressionTab:AddSlider("ProgPing", {
          Text = "Hop Above Ping",
          Default = 250,
          Min = 0,
          Max = 500,
          Rounding = 0,
          Suffix = " ms",
          Tooltip = "0 = off",
        })
        progressionTab:AddToggle("ProgStayInServer", {
          Text="Stay In Server (Gaia)",Default=false,
          Tooltip="Ameacas pausam no menu; aguarda Play manual e retoma o progresso salvo",
        })
        progressionTab:AddToggle("ProgMenuIllusionistSuper", {
          Text="Menu por Illusionist quando Super (Gaia)",Default=false,
          Tooltip="Ao ter Super, pausa no menu se detectar Illusionist nao aliado; aguarda Play manual",
        })
        progressionTab:AddDivider("Khei: protecoes separadas")
        progressionTab:AddSlider("ProgKheiProximity",{Text="Proximity Check (Khei)",Default=300,Min=0,Max=1000,Rounding=0,Suffix=" studs",Tooltip="0 desliga. Em Khei, Stay In Server usa menu; desligado troca de servidor. Independe de Allow hops da rota Gaia."})
        progressionTab:AddToggle("ProgKheiSkipIllusionist",{Text="Skip Illusionist Server (Khei)",Default=false,Tooltip="Detecta Observe na mochila/personagem, Observing ou MindMage. Stay In Server usa menu; desligado troca de servidor, sem depender de Allow hops de Gaia."})
        progressionTab:AddToggle("ProgKheiStayInServer",{Text="Stay In Server (Khei)",Default=false,Tooltip="Pausa no menu e aguarda Play manual, em vez de trocar de servidor"})
        progressionTab:AddInput("ProgWebhook", {
          Text = "Progression Webhook",
          Tooltip = "Empty = your normal webhook",
          Placeholder = "https://discord.com/api/webhooks/...",
          Default = "",
          Finished = true,
          Callback = function(a1826)
            __L2.str42 = a1826 or ""
            if
              not (
                __L2.str42 == ""
                or __L2.str42:match("^https://discord%.com/api/webhooks/%d+/%S+$") ~= nil
                or __L2.str42:match("^https://discordapp%.com/api/webhooks/%d+/%S+$") ~= nil
              )
            then
              fn535("That doesn't look like a Discord webhook URL")
            end
          end,
        })
        __L2.str42 = Options8.ProgWebhook and Options8.ProgWebhook.Value or ""
        progressionTab:AddToggle("ProgGoToKhei", {
          Text="Auto Go To Khei",Default=false,Tooltip="Segue para Khei ao concluir Gaia; protecoes de Khei sao independentes",
          Callback=function(value)
            if not value and __L3.kheiHandoffActive and not __L3.kheiManualRequested then v1009(true) end
          end,
        })
        progressionTab:AddButton({Text="Go To Khei / Parar tentativa",Func=function()
          if __L3.kheiManualRequested or __L3.kheiHandoffActive then
            __L3.kheiManualRequested=nil;qResult3.remove("khei_manual")
            v1009(true)
            return
          end
          if game.PlaceId==num274 then fn535("A conta ja esta em Khei");return end
          if not iResult5.allow(a1723,"Blatant","Go To Khei") then return end
          for _,bot in a1723.State.bots or {} do if bot.name=="Rot Bot" then pcall(bot.stop) end end
          if tbl303[1] then v1009(true) end
          qResult3.remove("progression_active");qResult3.remove("khei_handoff_servers")
          __L3.kheiManualRequested=true;qResult3.set("khei_manual","true");qResult3.set("khei_run","true")
          DResult2.setupResume()
          task.spawn(function()
            while __L3.kheiManualRequested and (__L3.bladeCoreRunning or (a1723.State.rotWorkerRunning and a1723.State.rotWorkerRunning())) do task.wait(0.1) end
            if __L3.kheiManualRequested then a1723.State.progKheiHandoff(true) end
          end)
        end})
        __L3.Maid7 = a1723.Maid
        __L3.Maid7:Give(v967.Heartbeat:Connect(__NATIVE[116]({ 0 }, a1723, { nil }, __L3.tbl335, function()
          local res250 = __L3.fn649()
          local ok125, result120 = pcall(function()
            return aResult22.HttpService:JSONEncode(res250)
          end)
          return ok125 and result120 or nil
        end, function()
          if __L3.tbl335[1] or a1723.State and a1723.State.loadingConfig then
            return
          end
          local res251 = __L3.fn649()
          qResult3.setJSON("progression_settings", res251)
          fn534("saveProgSettings: skipIllu=%s", tostring(res251.toggles.ProgSkipIllusionist))
        end)))
        __L3.num326 = -math.huge
        __L3.progStartClick=function()
          if not __L3.bladeSetupReady then
            __L3.progStatusLabel:SetText("Sigil: aguarde carregar a configuracao salva antes de iniciar")
            return
          end
          if __L3.bladeMenuPause or __L3.bladeCoreRunning then
            __L3.progStatusLabel:SetText("Sigil: aguardando Play manual ou finalizacao da pausa")
            return
          end
          if tbl303[1] then
            __L3.progStatusLabel:SetText("Sigil: ja esta em execucao")
            return
          end
          if tick()-__L3.num326<2 then return end
          __L3.num326=tick()
          if not iResult5.allow(a1723,"Blatant","Auto-Sigil") then
            __L3.progStatusLabel:SetText("Sigil: ative Blatant Mode para iniciar")
            return
          end
          __L3.progStatusLabel:SetText("Sigil: iniciando...")
          local ok,message=pcall(function()
            local v1301=Options8.ProgStartPhase and Options8.ProgStartPhase.Value
            local manual=__L3.bladeSelectStart(v1301)
            __L3.fn648(false)
            if manual and tbl303[1] then
              pcall(function() Options8.ProgStartPhase:SetValue("Resume") end)
              fn535("Sigil iniciado na etapa selecionada; progresso confirmado preservado")
            end
          end)
          if not ok then
            pcall(v1009,true)
            tbl303[1]=false
            __L3.bladeReleaseSetup()
            fn531(false); fn532(true)
            pcall(qResult3.remove,"progression_active")
            pcall(function() newResult61:DoCleaning() end)
            local text="Sigil: erro ao iniciar: "..tostring(message)
            __L3.progStatusLabel:SetText(text)
            fn535(text)
            fn534("start failed: %s",tostring(message))
          end
        end
        v1012 = progressionTab:AddButton({
          Text = "Reset Progress",
          DoubleClick = true,
          Func = function()
            if tbl303[1] or __L3.bladeMenuPause or __L3.bladeCoreRunning then
              fn535("stop the bot first")
              return
            end
            pcall(function()
              if delfile and isfile and isfile(fn540()) then
                delfile(fn540())
              end
            end)
            qResult3.remove("prog_stamps")
            tbl308[1] = nil
            fn548(false)
            fn535("auto-sigil progress reset")
          end,
        })
        fn548((function()
          return isfile and isfile(fn540()) or tbl308[1] ~= nil
        end)())
        task.spawn(function()
          while not a1723.State.notificationsReady do
            if a1723.Library.Unloaded or a1723.State.unloading then return end
            task.wait(0.1)
          end
          if a1723.Library.Unloaded or a1723.State.unloading then return end
          __L3.fn650()
          if not a1723.State.bladeProfileLoaded and qResult3.get("blade_setup_fluid_v1")~="true" then
            Options8.ProgRoute:SetValue("Blade/Sigil (3 stages)")
            qResult3.setJSON("progression_settings",__L3.fn649())
            qResult3.set("blade_setup_fluid_v1","true")
          end
          __L3.bladeSupplyLabel:SetText(__L3.bladeSilverGoal()==100 and "Inicio Alana | Rots: 100 Silver, sem pocoes" or "Inicio Alana | Quests: 660 Silver + pocoes")
          if not a1723.State.bladeProfileLoaded then
            Options8.ProgRoute:SetValue("Blade/Sigil (3 stages)")
            Options8.BladeDamageGoal:SetValue(6700)
            Options8.ProgStartPhase:SetValue("Resume")
          end
          __L3.bladeSetupReady=true
          if qResult3.get("progression_active") == "true" then
            if DResult2.claimResume({ "progression_active" }) then
              __L3.fn648(true)
            end
          elseif qResult3.get("khei_run") == "true" then
            __L3.kheiManualRequested=qResult3.get("khei_manual")=="true" and DResult2.resumedFromHop()
            if not __L3.kheiAllowed() then
              qResult3.remove("khei_run");qResult3.remove("khei_handoff_servers");qResult3.remove("khei_manual")
              return
            end
            if game.PlaceId == num274 then
              qResult3.remove("khei_run")
              qResult3.remove("khei_handoff_servers")
              task.spawn(__L3.fn647)
            else
              task.spawn(a1723.State.progKheiHandoff)
            end
          end
        end)
      end
    end
    tbl44.K = function()
      local K = tbl44.cache.K
      if not K then
        K = { c = fn75() }
        tbl44.cache.K = K
      end
      return K.c
    end
    local fn76 = function()
      local sResult8 = tbl44.s()
      local FResult2 = tbl44.F()
      local getResult24, v1303, v1304 = tbl44.a():Get("Players", "Workspace", "ReplicatedStorage")
      local LocalPlayer22 = getResult24.LocalPlayer
      local fireclickdetector_4 = fireclickdetector
      local tbl356 = { Vector3.new(-7164, 274, 2772), Vector3.new(-7143, 274, 2771) }
      local fn664 = function(a1828, a2268)
        local num390 = 0
        while true do
          if not (a2268() and num390 < 12) then
            break
          end
          local rootResult16 = sResult8.root()
          if rootResult16 and (rootResult16.Position - a1828).Magnitude < 6 then
            return true
          end
          local humanoidResult = sResult8.humanoid()
          if humanoidResult then
            humanoidResult:MoveTo(a1828)
          end
          task.wait(0.2)
          num390 += 0.2
        end
        return false
      end
      local fn665 = function(a1829, a2269)
        local ClickDetector6 = a1829:FindFirstChildWhichIsA("ClickDetector", true)
        local Requests11 = v1304:FindFirstChild("Requests")
        if not (ClickDetector6 and fireclickdetector_4 and Requests11) then
          return false
        end
        local Character69 = LocalPlayer22.Character
        local v1305
        local tbl357 = {}
        local getChildrenResult59, v1306, v1307 = Requests11:GetChildren()
        for k296, v1308 in getChildrenResult59, v1306, v1307 do
          if v1308:IsA("RemoteEvent") then
            table.insert(
              tbl357,
              v1308.OnClientEvent:Connect(function(a1830)
                if type(a1830) == "table" and type(a1830.choices) == "table" and #a1830.choices > 0 then
                  v1305 = { remote = v1308, choices = a1830.choices }
                end
              end)
            )
          end
        end
        local num391 = 0
        while true do
          if not (a2269() and not FResult2.inDialogue() and num391 < 5) then
            break
          end
          pcall(function()
            fireclickdetector_4(ClickDetector6)
          end)
          task.wait(0.3)
          num391 += 0.3
        end
        local tickResult12 = tick()
        while true do
          if not (a2269() and tick() - tickResult12 < 8) then
            break
          end
          if LocalPlayer22.Character and LocalPlayer22.Character ~= Character69 then
            break
          end
          local v1309 = v1305
          if v1309 then
            local v1310
            for k297, v1311 in v1309.choices do
              if v1311 == "New Character\n(free)" or v1311 == "New Character (free)" then
                v1310 = v1311
                break
              end
            end
            pcall(function()
              local remote = v1309.remote
              remote:FireServer({ choice = v1310 or v1309.choices[1] })
            end)
          elseif not FResult2.inDialogue() then
            pcall(function()
              fireclickdetector_4(ClickDetector6)
            end)
          end
          task.wait(0.25)
        end
        for k298, v1312 in tbl357 do
          pcall(function()
            v1312:Disconnect()
          end)
        end
        return true
      end
      local fn666 = function(a1831, a2270, a391)
        local num392 = 0
        repeat
          task.wait(0.3)
          num392 += 0.3
          local v1313 = LocalPlayer22.Character
              and LocalPlayer22.Character ~= a1831
              and LocalPlayer22.Character:FindFirstChild("HumanoidRootPart")
            or num392 > (a391 or 20)
          if v1313 then
            continue
          end
          v1313 = not a2270()
        until v1313
      end
      return {
        wipe = function(a1832, a2271)
          local v1314 = a2271 or {}
          for k299, v1315 in tbl356 do
            if not a1832() then
              return
            end
            fn664(v1315, a1832)
          end
          local NPCs9 = v1303:FindFirstChild("NPCs")
          local v1316 = NPCs9 and NPCs9:FindFirstChild("Ferryman")
          if not v1316 then
            if v1314.notify then
              v1314.notify("Ferryman not found")
            end
            return
          end
          local HumanoidRootPart18 = v1316:FindFirstChild("HumanoidRootPart")
          if HumanoidRootPart18 then
            fn664(HumanoidRootPart18.Position, a1832)
          end
          local Character70 = LocalPlayer22.Character
          fn665(v1316, a1832)
          fn666(Character70, a1832, 20)
        end,
      }
    end
    tbl44.L = function()
      local L = tbl44.cache.L
      if not L then
        L = { c = fn76() }
        tbl44.cache.L = L
      end
      return L.c
    end
    local fn77 = function()
      local aResult23 = tbl44.a()
      local sResult9 = tbl44.s()
      local cResult5 = tbl44.c()
      local getResult25, v1317, v1318, v1319, v1320 =
        aResult23:Get("Players", "RunService", "CollectionService", "HttpService", "TweenService")
      local LocalPlayer23 = getResult25.LocalPlayer
      local num393 = 8
      local num394 = 120
      local num395 = 12
      local num396 = 0.5
      local num397 = 90
      local num398 = 1400
      local num399 = 12
      local num400 = 8
      local tbl358 = { STALE = num393, ARRIVE = num400 }
      local readJson = function(a1833)
        if tbl358.isRemote and tbl358.isRemote(a1833) then return tbl358.sharedGet(a1833) end
        if not (isfile and isfile(a1833)) then
          return nil
        end
        local ok126, result121 = pcall(readfile, a1833)
        if not (ok126 and type(result121) == "string") then
          return nil
        end
        local ok127, result122 = pcall(function()
          return v1319:JSONDecode(result121)
        end)
        return ok127 and type(result122) == "table" and result122 or nil
      end
      local writeJson = function(a1834, a2272)
        if tbl358.isRemote and tbl358.isRemote(a1834) then return tbl358.sharedPut(a1834,a2272) end
        if not writefile then
          return false
        end
        cResult5.ensureFor(a1834)
        local ok128, result123 = pcall(function()
          return v1319:JSONEncode(a2272)
        end)
        return ok128 and pcall(writefile, a1834, result123) == true
      end
      -- Shared transport: only coordination records may leave the local executor.
      tbl358.net={config={mode="Local files",url="",token=""},items={},lists={},offset=0,lastError=nil}
      tbl358.sharedKey=function(path)
        local key=tostring(path):gsub("\\","/"):gsub("/+","/"):gsub("/$","")
        for _,prefix in {"sentinel/.cache/blade_workers","sentinel/.cache/rot_receiver_queue","sentinel/.cache/altlink/rotbot"} do
          if key==prefix or key:sub(1,#prefix+1)==prefix.."/" then return key,prefix end
        end
        return nil
      end
      tbl358.isRemote=function(path)
        return tbl358.net.config.mode=="Remote HTTP" and tbl358.sharedKey(path)~=nil
      end
      tbl358.sharedNow=function() return os.time()+tbl358.net.offset end
      tbl358.sharedLease=function() return tbl358.net.config.mode=="Remote HTTP" and 12 or 8 end
      tbl358.sharedRequest=function(method,endpoint,payload,overrideConfig)
        local config=overrideConfig or tbl358.net.config
        local requestFn=request or http_request or (http and http.request) or (syn and syn.request)
        if not requestFn then error("Executor HTTP request function unavailable") end
        local url=tostring(config.url or ""):gsub("/+$","")
        if not url:match("^https?://[^/]+") then error("Set the Blade 23 server URL") end
        if #(config.token or "")<16 then error("Set the Blade 23 access key") end
        local options={Url=url..endpoint,Method=method,Timeout=5,
          Headers={Authorization="Bearer "..config.token,["Content-Type"]="application/json"}}
        if payload then options.Body=v1319:JSONEncode(payload) end
        local ok,response=pcall(requestFn,options)
        if not ok then error("Blade 23 server unreachable; check address, server and firewall") end
        local status=response and tonumber(response.StatusCode or response.Status)
        if not status or status<200 or status>=300 then
          error("Blade 23 server HTTP "..tostring(status or "invalid response"))
        end
        local decodedOk,decoded=pcall(v1319.JSONDecode,v1319,response.Body or "")
        if not decodedOk or type(decoded)~="table" then error("Invalid Blade 23 server response") end
        if not overrideConfig and type(decoded.serverTime)=="number" then tbl358.net.offset=decoded.serverTime-os.time() end
        tbl358.net.lastError=nil
        return decoded
      end
      tbl358.sharedPut=function(path,value)
        local key,prefix=tbl358.sharedKey(path)
        local ok,result=pcall(tbl358.sharedRequest,"POST","/v1/item",{key=key,value=value})
        if not ok then tbl358.net.lastError=tostring(result); return false end
        if type(result.value)=="table" then
          for field,entry in result.value do value[field]=entry end
          tbl358.net.items[key]={value=result.value,at=os.clock()}
        end
        tbl358.net.lists[prefix]=nil
        return true
      end
      tbl358.sharedGet=function(path)
        local key=tbl358.sharedKey(path)
        local cached=tbl358.net.items[key]
        if cached and os.clock()-cached.at<0.5 then return cached.value end
        local response=tbl358.sharedRequest("GET","/v1/item?key="..v1319:UrlEncode(key))
        tbl358.net.items[key]={value=response.value,at=os.clock()}
        return response.value
      end
      tbl358.sharedList=function(folder)
        if not tbl358.isRemote(folder) then
          if not (listfiles and isfolder and isfolder(folder)) then return {} end
          return listfiles(folder)
        end
        local key=tbl358.sharedKey(folder)
        local cached=tbl358.net.lists[key]
        if cached and os.clock()-cached.at<0.5 then return cached.files end
        local response=tbl358.sharedRequest("GET","/v1/list?prefix="..v1319:UrlEncode(key))
        local files={}
        for _,entry in response.entries or {} do
          table.insert(files,entry.key)
          tbl358.net.items[entry.key]={value=entry.value,at=os.clock()}
        end
        tbl358.net.lists[key]={files=files,at=os.clock()}
        return files
      end
      tbl358.sharedDelete=function(path)
        if tbl358.isRemote(path) then
          local key,prefix=tbl358.sharedKey(path)
          tbl358.sharedRequest("DELETE","/v1/item?key="..v1319:UrlEncode(key))
          tbl358.net.items[key]=nil; tbl358.net.lists[prefix]=nil
        elseif delfile and isfile and isfile(path) then delfile(path) end
      end
      tbl358.sharedTrim=function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
      tbl358.sharedURL=function(value)
        local url=tbl358.sharedTrim(value):gsub("/+$","")
        if not url:match("^https?://") then url="http://"..url end
        if not url:match("^https?://[%w%.:%[%]%-]+$") then error("Endereco invalido. Copie o convite inteiro do PC principal.",0) end
        return url
      end
      tbl358.sharedPublicRequest=function(url,endpoint,payload)
        local requestFn=request or http_request or (http and http.request) or (syn and syn.request)
        if not requestFn then error("O executor nao oferece a funcao HTTP request.",0) end
        local options={Url=tbl358.sharedURL(url)..endpoint,Method="POST",Timeout=5,
          Headers={["Content-Type"]="application/json"},Body=v1319:JSONEncode(payload or {})}
        local ok,response=pcall(requestFn,options)
        if not ok then error("Sem resposta. Abra o iniciador no PC principal e confira se os PCs estao na mesma rede.",0) end
        local status=response and tonumber(response.StatusCode or response.Status)
        if not status or status==0 then error("Sem resposta. Abra o iniciador no PC principal e confira a rede.",0) end
        local decodedOk,decoded=pcall(v1319.JSONDecode,v1319,response and response.Body or "")
        if status==401 and decodedOk and type(decoded)=="table" and decoded.error=="Invalid access key" then
          error("Servidor antigo. Feche a janela Python e abra o iniciador atualizado do GitHub.",0)
        end
        if not status or status<200 or status>=300 then
          local message=decodedOk and type(decoded)=="table" and decoded.error
          error(type(message)=="string" and message or "Nao foi possivel conectar. HTTP "..tostring(status or "sem resposta"),0)
        end
        if not decodedOk or type(decoded)~="table" or decoded.service~="blade23" or (tonumber(decoded.version) or 0)<2
          or type(decoded.token)~="string" or #decoded.token<16 then error("Esse endereco nao oferece o pareamento do Blade 23. Atualize o servidor.",0) end
        return decoded
      end
      tbl358.sharedInvite=function(text)
        local value=tbl358.sharedTrim(text):gsub("^[Cc]onvite:%s*","")
        local url,code=value:match("^B23|([^|]+)|([%w%-]+)$")
        if not url or not code then error("Cole o convite inteiro, comecando por B23|. Use Copiar convite no PC principal.",0) end
        code=code:gsub("%-",""):upper()
        if #code~=8 or not code:match("^[A-Z2-9]+$") then error("Codigo do convite invalido. Copie novamente.",0) end
        return tbl358.sharedURL(url),code
      end
      tbl358.sharedConfigValue=function(config)
        if type(config)~="table" then error("Configuracao de rede invalida.",0) end
        local nextConfig={mode=config.mode=="Remote HTTP" and "Remote HTTP" or "Local files",
          url=tbl358.sharedTrim(config.url):gsub("/+$",""),token=tbl358.sharedTrim(config.token)}
        if nextConfig.mode=="Remote HTTP" then
          nextConfig.url=tbl358.sharedURL(nextConfig.url)
          if #nextConfig.token<16 then error("Use Conectar neste PC ou cole um convite para obter a chave automaticamente.",0) end
        end
        return nextConfig
      end
      tbl358.sharedConfigure=function(config,persist)
        local nextConfig=tbl358.sharedConfigValue(config)
        if persist~=false and not writeJson("sentinel/.cache/blade23_network.json",nextConfig) then
          return false,"Nao consegui salvar a conexao na pasta do executor."
        end
        tbl358.net.config=nextConfig
        tbl358.net.items={}; tbl358.net.lists={}; tbl358.net.offset=0; tbl358.net.lastError=nil
        return true
      end
      tbl358.sharedUseLocal=function(mayApply)
        if mayApply and not mayApply() then error("Pare os bots e saia das filas antes de selecionar Tudo neste PC.",0) end
        if not (writefile and readfile and isfile and listfiles and isfolder) then
          error("O modo neste PC precisa do acesso a arquivos do executor para coordenar as contas.",0)
        end
        local saved,message=tbl358.sharedConfigure({mode="Local files",url="",token=""})
        if not saved then error(message,0) end
        return "Tudo neste PC salvo | sem Python, servidor ou teste de conexao"
      end
      tbl358.sharedTest=function(config)
        local started=os.clock()
        local response=tbl358.sharedRequest("GET","/v1/health",nil,config)
        if response.service~="blade23" then error("O endereco nao e um servidor Blade 23.",0) end
        return math.floor((os.clock()-started)*1000)
      end
      tbl358.sharedConnect=function(invite,localPC,mayApply)
        local url,code
        if localPC then url="http://127.0.0.1:8787"
        else url,code=tbl358.sharedInvite(invite) end
        local response=tbl358.sharedPublicRequest(url,localPC and "/v1/local-connect" or "/v1/pair",localPC and {} or {code=code})
        local config={mode="Remote HTTP",url=url,token=response.token}
        local elapsed=tbl358.sharedTest(config)
        if mayApply and not mayApply() then error("Pare os bots antes de aplicar a conexao.",0) end
        local saved,message=tbl358.sharedConfigure(config)
        if not saved then error(message,0) end
        return elapsed
      end
      tbl358.sharedLoadSaved=function()
        local saved=readJson("sentinel/.cache/blade23_network.json")
        if type(saved)~="table" then return false end
        local nextConfig=tbl358.sharedConfigValue(saved)
        if tbl358.localOnly and nextConfig.mode~="Local files" then return false end
        local current=tbl358.net.config
        if nextConfig.mode==current.mode and nextConfig.url==current.url and nextConfig.token==current.token then return false end
        tbl358.sharedConfigure(nextConfig,false)
        return true
      end
      do
        pcall(tbl358.sharedLoadSaved)
        -- This version coordinates only through the common executor folder.
        tbl358.localOnly=true
        tbl358.net.config={mode="Local files",url="",token=""}
        pcall(tbl358.sharedConfigure,tbl358.net.config)
      end
      tbl358.readJson = readJson
      tbl358.writeJson = writeJson
      tbl358.available = function()
        if tbl358.net.config.mode=="Remote HTTP" then return true end
        return (writefile and readfile and isfile and listfiles and isfolder) ~= nil
      end
      tbl358.knocked = function(a1835)
        return a1835 ~= nil and v1318:HasTag(a1835, "Unconscious")
      end
      tbl358.rootOf = function(a1836)
        local v1321 = a1836 and a1836.Character
        return v1321 and v1321:FindFirstChild("HumanoidRootPart") or nil
      end
      tbl358.distanceTo = function(a1837)
        local rootResult17 = sResult9.root()
        local rootOfResult = tbl358.rootOf(a1837)
        if not (rootResult17 and rootOfResult) then
          return nil
        end
        return (rootOfResult.Position - rootResult17.Position).Magnitude
      end
      tbl358.playerByName = function(a1838)
        local getPlayersResult28, v1322, v1323 = getResult25:GetPlayers()
        for k300, v1324 in getPlayersResult28, v1322, v1323 do
          if v1324.Name == a1838 then
            return v1324
          end
        end
        return nil
      end
      tbl358.match = function(a1839)
        local lowerResult4 = tostring(a1839 or ""):lower()
        if lowerResult4 == "" then
          return nil
        end
        local v1325
        local v1326
        local getPlayersResult29, v1327, v1328 = getResult25:GetPlayers()
        for k301, v1329 in getPlayersResult29, v1327, v1328 do
          if v1329 ~= LocalPlayer23 then
            local lowerResult5 = v1329.Name:lower()
            local lowerResult6 = (v1329.DisplayName or ""):lower()
            if lowerResult5 == lowerResult4 or lowerResult6 == lowerResult4 then
              return v1329
            end
            if not v1325 and (lowerResult5:sub(1, #lowerResult4) == lowerResult4 or lowerResult6:sub(1, #lowerResult4) == lowerResult4) then
              v1325 = v1329
            end
            if not v1326 and (lowerResult5:find(lowerResult4, 1, true) or lowerResult6:find(lowerResult4, 1, true)) then
              v1326 = v1329
            end
          end
        end
        return v1325 or v1326
      end
      tbl358.awaitSpawn = function(a1840, a2273)
        local num401 = tick() + (a2273 or 30)
        while true do
          if not (a1840() and tick() < num401) then
            break
          end
          if sResult9.ready() then
            return true
          end
          task.wait(0.3)
        end
        return sResult9.ready() ~= nil
      end
      tbl358.knock = function(a1841, a2274, a392)
        local num402 = 0
        while true do
          if not (a2274() and num402 < num395) then
            break
          end
          local Character71 = LocalPlayer23.Character
          if tbl358.knocked(Character71) then
            return true
          end
          local v1330 = Character71 and Character71:FindFirstChildOfClass("Humanoid")
          if not (v1330 and v1330.Health > 0) then
            return tbl358.knocked(Character71)
          end
          if a1841 then
            a1841(2.39, a392 or "altlink")
          end
          task.wait(num396)
          num402 += num396
        end
        return tbl358.knocked(LocalPlayer23.Character)
      end
      local fn667 = function(a1842, a2275, a393)
        local rootResult18 = sResult9.root()
        if not rootResult18 then
          return false
        end
        local v1331 = (a1842 - rootResult18.Position).Magnitude <= num398 and a1842
          or rootResult18.Position + (a1842 - rootResult18.Position).Unit * num398
        local v1332 = v1320
        local CreateResult4 = v1332:Create(
          rootResult18,
          TweenInfo.new(math.max((v1331 - rootResult18.Position).Magnitude / (a2275 or num397), 0.05), Enum.EasingStyle.Linear),
          { CFrame = CFrame.new(v1331) }
        )
        local flag76 = false
        CreateResult4.Completed:Connect(function()
          flag76 = true
        end)
        CreateResult4:Play()
        local num403 = 0
        while true do
          if not (not flag76 and a393() and num403 < num399) then
            break
          end
          task.wait(0.05)
          num403 += 0.05
        end
        if not flag76 then
          pcall(function()
            CreateResult4:Cancel()
          end)
        end
        return flag76
      end
      tbl358.travelTo = function(a1843, a2276, a394, a438)
        local v1333 = a438 or num400
        local connectResult11 = v1317.RenderStepped:Connect(__NATIVE[117](sResult9, LocalPlayer23))
        local num404 = tick() + num399
        while true do
          if not (a2276() and tick() < num404) then
            break
          end
          local rootResult19 = sResult9.root()
          local v1334 = typeof(a1843) == "function" and a1843() or a1843
          if not (rootResult19 and typeof(v1334) == "Vector3") or (rootResult19.Position - v1334).Magnitude <= v1333 then
            break
          end
          fn667(v1334, a394, a2276)
        end
        connectResult11:Disconnect()
        sResult9.reclip(LocalPlayer23.Character)
        task.wait(0.4)
        local rootResult20 = sResult9.root()
        local v1335 = typeof(a1843) == "function" and a1843() or a1843
        if not (rootResult20 and typeof(v1335) == "Vector3") then
          return nil
        end
        return (rootResult20.Position - v1335).Magnitude
      end
      tbl358.travel = function(a1844, a2277, a395)
        tbl358.travelTo(function()
          local rootOfResult2 = tbl358.rootOf(a1844)
          return rootOfResult2 and rootOfResult2.Position or nil
        end, a2277, a395)
        return tbl358.distanceTo(a1844)
      end
      tbl358.localClients=function()
        local clients={members={},checked={},elapsed=0,closed=false,lease=8,
          file="sentinel/.cache/blade_local_clients/p_"..tostring(LocalPlayer23.UserId)..".json"}
        clients.valid=function(record,userId)
          if type(record)~="table" or record.version~=1 or record.active~=true or record.userId~=userId
            or record.jobId~=game.JobId or record.placeId~=game.PlaceId or type(record.at)~="number" then return false end
          local age=os.time()-record.at
          return age>=-2 and age<=clients.lease
        end
        clients.isAlly=function(player)
          if clients.closed or not player then return false end
          local id=player.UserId
          if type(id)~="number" or id<=0 or id%1~=0 then return false end
          local record=clients.members[id]
          if clients.valid(record,id) then return true end
          local now=os.clock()
          if clients.checked[id] and now-clients.checked[id]<0.25 then return false end
          clients.checked[id]=now
          -- readJson below bypasses the optional HTTP transport: these records are local only.
          record=readJson("sentinel/.cache/blade_local_clients/p_"..tostring(id)..".json")
          if clients.valid(record,id) then clients.members[id]=record;return true end
          clients.members[id]=nil
          return false
        end
        clients.tick=function()
          if clients.closed or clients.busy then return end
          clients.busy=true
          local ok,err=pcall(function()
            local written=writeJson(clients.file,{version=1,active=true,userId=LocalPlayer23.UserId,jobId=game.JobId,placeId=game.PlaceId,at=os.time()})
            if not written and not clients.writeFailed then warn("[blade 23] Nao consegui anunciar esta conta no PC. Confira o acesso a pasta de arquivos do executor.") end
            clients.writeFailed=not written
            local present={}
            for _,player in getResult25:GetPlayers() do
              local id=player.UserId
              present[id]=true
              clients.checked[id]=nil
              clients.members[id]=nil
              clients.isAlly(player)
            end
            for id in clients.checked do if not present[id] then clients.checked[id]=nil;clients.members[id]=nil end end
          end)
          clients.busy=false
          if not ok then error(err,0) end
        end
        clients.stop=function()
          if clients.closed then return end
          clients.closed=true
          if clients.connection then clients.connection:Disconnect();clients.connection=nil end
          pcall(writeJson,clients.file,{version=1,active=false,userId=LocalPlayer23.UserId,jobId=game.JobId,placeId=game.PlaceId,at=os.time()})
          table.clear(clients.members);table.clear(clients.checked)
        end
        pcall(clients.tick)
        clients.connection=v1317.Heartbeat:Connect(function(dt)
          clients.elapsed+=dt
          if clients.elapsed<1 or clients.closed then return end
          clients.elapsed=0
          pcall(clients.tick)
        end)
        return clients
      end
      tbl358.channel = function(a1845)
        local str51 = cResult5.CACHE .. "/altlink/" .. a1845
        local tbl359 = {}
        local fn668 = function(a1846)
          return string.format("%s/p_%s.json", str51, tostring(a1846))
        end
        local fn669 = function()
          return str51 .. "/cmd.json"
        end
        tbl359.beacon = function(a1847)
          local Character72 = LocalPlayer23.Character
          local v1336 = Character72 and Character72:FindFirstChild("HumanoidRootPart")
          local tbl360 = {
            name = LocalPlayer23.Name,
            display = LocalPlayer23.DisplayName,
            userId = LocalPlayer23.UserId,
            jobId = game.JobId,
            at = os.time(),
            down = tbl358.knocked(Character72),
            y = v1336 and math.floor(v1336.Position.Y) or 0,
          }
          for k302, v1337 in a1847 or {} do
            tbl360[k302] = v1337
          end
          writeJson(fn668(LocalPlayer23.UserId), tbl360)
        end
        tbl359.roster = function()
          local tbl361 = {}
          if not tbl358.available() then return tbl361 end
          local result124 = tbl358.sharedList(str51)
          local timeResult4 = tbl358.sharedNow()
          for k303, v1338 in result124 do
            local v1339 = tostring(v1338):match("[^/\\]+$") or ""
            if v1339:sub(1, 2) == "p_" and v1339:sub(-5) == ".json" then
              local res252 = readJson(v1338)
              if type(res252) == "table" then
                local num405 = timeResult4 - (tonumber(res252.at) or 0)
                if num405 > num394 then
                  pcall(tbl358.sharedDelete, v1338)
                end
                if res252.jobId == game.JobId and tonumber(res252.userId) ~= LocalPlayer23.UserId and num405 <= tbl358.sharedLease() then
                  table.insert(tbl361, res252)
                end
              end
            end
          end
          return tbl361
        end
        tbl359.setCommand = function(a1848)
          writeJson(fn669(), {
            master = LocalPlayer23.UserId,
            masterName = LocalPlayer23.Name,
            jobId = game.JobId,
            targets = a1848 or {},
            at = os.time(),
          })
        end
        tbl359.clearCommand = function()
          local res253 = readJson(fn669())
          if type(res253) == "table" and tonumber(res253.master) ~= LocalPlayer23.UserId then
            return
          end
          pcall(tbl358.sharedDelete,fn669())
        end
        tbl359.orderedMaster = function()
          local res254 = readJson(fn669())
          if
            type(res254) ~= "table"
            or res254.jobId ~= game.JobId
            or tbl358.sharedNow() - (tonumber(res254.at) or 0) > tbl358.sharedLease()
            or type(res254.targets) ~= "table"
          then
            return nil
          end
          for k304, v1340 in res254.targets do
            if tonumber(v1340) == LocalPlayer23.UserId then
              return tbl358.playerByName(tostring(res254.masterName))
            end
          end
          return nil
        end
        tbl359.dropBeacon = function()
          pcall(tbl358.sharedDelete,fn668(LocalPlayer23.UserId))
        end
        return tbl359
      end
      return tbl358
    end
    tbl44.M = function()
      local M = tbl44.cache.M
      if not M then
        M = { c = fn77() }
        tbl44.cache.M = M
      end
      return M.c
    end
    local fn78 = function()
      local sResult10 = tbl44.s()
      local qResult4 = tbl44.q()
      local DResult3 = tbl44.D()
      local FResult3 = tbl44.F()
      local LResult = tbl44.L()
      local aResult24 = tbl44.a()
      local eResult8 = tbl44.e()
      local vResult6 = tbl44.v()
      local HResult2 = tbl44.H()
      local iResult6 = tbl44.i()
      local MResult = tbl44.M()
      local getResult26, v1341, v1342, v1343, v1344, v1345 =
        aResult24:Get("Players", "Workspace", "RunService", "TweenService", "ReplicatedStorage", "CollectionService")
      local LocalPlayer24 = getResult26.LocalPlayer
      local fireclickdetector_5 = fireclickdetector
      local num406 = 110
      local tbl362 = {
        Vector3.new(1342, 401, 2992),
        Vector3.new(1343, 121, 2910),
        Vector3.new(1378, 122, 2699),
        Vector3.new(1416, 121, 1974),
        Vector3.new(1407, 314, 1975),
        Vector3.new(1391, 310, 1784),
        Vector3.new(1397, 287, 1711),
      }
      local tbl363 = { Vector3.new(1354, 418, 2970), Vector3.new(1517, 422, 2943), Vector3.new(1522, 449, 2940) }
      local vector326 = Vector3.new(1354, 418, 2970)
      local vector327 = Vector3.new(-2126, 609, -709)
      local vector328 = Vector3.new(-7184, 274, 2793)
      local vector329 = Vector3.new(-2070.62060546875, 609.3539428710938, -752.966064453125)
      local num407 = 9
      local num408 = 40
      local num409 = 1.2
      local num410 = 3.15
      local num411 = 45
      local num412 = 16
      local num413 = 2
      local tbl364 = { "make the realm just a bit safer" }
      local str52 = "looking for a job"
      return function(a1849)
        local Library9 = a1849.Library
        local Options9 = Library9.Options
        local rotBotTab = a1849.State.rotBotTab
        local rotQueueTab=a1849.State.bladeQueueTab
        local rotReceiverTab=a1849.State.progressionTab
        local rotHidden=a1849.Tabs.Blade23:AddRightGroupbox("Rot interno")
        rotHidden:SetVisible(false)
        local v1346 = tonumber(qResult4.get("rotbot_count")) or 0
        local v1347
        if not rotBotTab then
          return
        end
        local channelResult = MResult.channel("rotbot")
        local rotSupplier={settings=qResult4.getJSON("blade23_rot_supplier") or {},owner=nil,seen=0,stopped=false}
        rotSupplier.status=rotBotTab:AddLabel("Fornecedor: detecta quem estiver no ponto P14 em Renova",true)
        rotSupplier.waitPoint=Vector3.new(-2085.454589844,609.353881836,-754.801147461)
        rotSupplier.receiverPoint=Vector3.new(-2076.978759765625,615.2067260742188,-759.8974609375)
        rotSupplier.masterReadyQueued=function(expectedId)
          local owner=rotSupplier.owner
          if not owner or os.clock()-rotSupplier.seen>4 or owner.ready~=true
            or owner.state~="waiting" or (tonumber(owner.progress) or 16)>=16
            or (expectedId and owner.userId~=expectedId) then return nil end
          local player=getResult26:GetPlayerByUserId(owner.userId)
          local character=player and player.Character
          local root=character and character:FindFirstChild("HumanoidRootPart")
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          if not root or not hum or hum.Health<=0 or (root.Position-rotSupplier.receiverPoint).Magnitude>12
            or character:FindFirstChild("Grabbing") or v1345:HasTag(character,"Unconscious")
            or v1345:HasTag(character,"Knocked") or v1345:HasTag(character,"Jailed") then return nil end
          return player,root
        end
        rotSupplier.presenceRadius=6
        rotSupplier.masterReady=function(expectedId)
          -- The other PC does not announce itself: use replicated character presence at P14.
          if os.clock()>=(rotSupplier.supplierRefresh or 0) then
            rotSupplier.supplierRefresh=os.clock()+0.5
            rotSupplier.supplierIds={}
            for _,entry in channelResult.roster() do
              if entry.rotSupplier then rotSupplier.supplierIds[entry.userId]=true end
            end
          end
          local best,bestRoot,bestDistance
          for _,player in getResult26:GetPlayers() do
            if player~=LocalPlayer24 and (not expectedId or player.UserId==expectedId)
              and not (rotSupplier.supplierIds and rotSupplier.supplierIds[player.UserId]) then
              local character=player.Character
              local root=character and character:FindFirstChild("HumanoidRootPart")
              local hum=character and character:FindFirstChildOfClass("Humanoid")
              if root and hum and hum.Health>0 and not character:FindFirstChild("Grabbing")
                and not v1345:HasTag(character,"Unconscious") and not v1345:HasTag(character,"Knocked")
                and not v1345:HasTag(character,"Jailed") then
                local delta=root.Position-rotSupplier.receiverPoint
                local distance=Vector3.new(delta.X,0,delta.Z).Magnitude
                if distance<=rotSupplier.presenceRadius and math.abs(delta.Y)<=12 then
                  if player.UserId==rotSupplier.presenceMasterId then return player,root end
                  if not best or distance<bestDistance or (distance==bestDistance and player.UserId<best.UserId) then
                    best,bestRoot,bestDistance=player,root,distance
                  end
                end
              end
            end
          end
          if best then rotSupplier.presenceMasterId=best.UserId
          elseif not expectedId then rotSupplier.presenceMasterId=nil end
          return best,bestRoot
        end
        rotSupplier.saveSettings=function()
          local resume=Library9.Toggles.RotSupplierResume
          local key=Options9.RotSupplierStopKey
          if resume then rotSupplier.settings.resume=resume.Value end
          if key then rotSupplier.settings.stopKey=key.Value end
          qResult4.setJSON("blade23_rot_supplier",rotSupplier.settings)
        end
        local fn670 = function()
          if rotSupplier.explicitSupplier and not a1849.State.bladeRunAlts then return false end
          if a1849.State.blade23Enabled and a1849.State.blade23Enabled() then return true end
          local pairsResult5, v1350, v1351 = pairs(a1849.State.bladeRunAlts or (Options9.RotAlts and Options9.RotAlts.Value or {}))
          for k305, v1352 in pairsResult5, v1350, v1351 do
            if v1352 then
              return true
            end
          end
          return false
        end
        local fn671 = function()
          if fn670() then
            return nil
          end
          return rotSupplier.masterReady()
        end
        iResult6.mark(a1849, "Blatant", "RotBotEnabled")
        local tbl365 = { false }
        local num414 = 8
        local num415 = 6
        local num416 = 3
        local tbl366 = { false }
        local rotNotice={at=-math.huge,message=nil}
        local fn672 = function(a1850)
          local now=os.clock()
          if now-rotNotice.at<1 or (rotNotice.message==a1850 and now-rotNotice.at<5) then return false end
          rotNotice.at=now;rotNotice.message=a1850
          Library9:Notify({ Title = "sentinel.bz", Description = a1850 })
          return true
        end
        local v1348
        local flag77 = false
        local fn673 = function()
          v1348 = eResult8.getRemote("ApplyFallDamage") or eResult8.getRemote("FallDamage")
          return v1348
        end
        local fn674 = function()
          if a1849.State.fireFall then
            return a1849.State.fireFall(2.39, "rotbot")
          end
          if not flag77 then
            flag77 = true
            fn672("Rot Bot: ApplyFallDamage unavailable (KeyHandler off?)")
          end
          return false
        end
        local Maid8 = a1849.Maid
        Maid8:Give(LocalPlayer24.CharacterAdded:Connect(function()
          v1348 = nil
          if not tbl365[1] then
            return
          end
          task.spawn(function()
            for i77 = 1, 10 do
              if not tbl365[1] or v1348 and v1348.Parent then
                return
              end
              if fn673() then
                return
              end
              task.wait(0.4)
            end
          end)
        end))
        local num417 = 0
        local v1349
        local fn675 = function()
          if tick() - num417 > 1 then
            num417 = tick()
            v1349 = a1849.State.getServerValue and a1849.State.getServerValue("Lives")
          end
          return v1349
        end
        local fn676 = function()
          sResult10.noFall(sResult10.humanoid())
          return v1342.RenderStepped:Connect(__NATIVE[118](sResult10, LocalPlayer24, tbl366))
        end
        local fn677 = function(a1851, a2278)
          if
            not sResult10.awaitPlaced(
              function()
                return tbl365[1]
              end,
              25,
              function()
                fn672("Waiting for the character to be placed")
              end
            )
          then
            return
          end
          while tbl365[1] do
            if fn675() == 0 then
              return
            end
            local rootResult21 = sResult10.root()
            if not rootResult21 then
              return
            end
            local v1353 = (a1851 - rootResult21.Position).Magnitude <= 1400 and a1851
              or rootResult21.Position + (a1851 - rootResult21.Position).Unit * 1400
            local CreateResult5 = v1343:Create(
              rootResult21,
              TweenInfo.new(math.max((v1353 - rootResult21.Position).Magnitude / (a2278 or num406), 0.05), Enum.EasingStyle.Linear),
              { CFrame = CFrame.new(v1353) }
            )
            local tbl370 = { false }
            local completedConnection=CreateResult5.Completed:Connect(function()
              tbl370[1] = true
            end)
            CreateResult5:Play()
            while tbl365[1] and not tbl370[1] do
              if rotSupplier.jailBlocked and rotSupplier.jailBlocked() then break end
              task.wait(0.05)
            end
            local jailed=rotSupplier.jailBlocked and rotSupplier.jailBlocked()
            if not tbl365[1] or jailed then CreateResult5:Cancel() end
            completedConnection:Disconnect();CreateResult5:Destroy()
            if not tbl365[1] or jailed then return false end
            if v1353 == a1851 then
              return
            end
          end
        end
        local fn678 = function(a1852, a2279)
          local res255 = fn676()
          for k306, v1354 in a1852 do
            if not tbl365[1] then
              break
            end
            fn677(v1354, a2279)
          end
          return res255
        end
        local fn679 = function(a1853, a2280, a396, a439)
          local v1355 = a439 or {}
          local res256 = fn678(a1853, v1355.speed)
          local NPCs10 = v1341:FindFirstChild("NPCs")
          local v1356 = NPCs10 and NPCs10:FindFirstChild(a2280)
          local v1357 = v1356 and v1356:FindFirstChild("HumanoidRootPart")
          local rootResult22 = sResult10.root()
          local v1358 = v1357 ~= nil and rootResult22 ~= nil and (rootResult22.Position - v1357.Position).Magnitude <= (v1355.range or 20)
          if v1358 then
            rootResult22.AssemblyLinearVelocity = Vector3.zero
            tbl366[1] = true
            local v1359
            if v1355.anchor then
              rootResult22.Anchored = true
            else
              v1359 = v1342.RenderStepped:Connect(__NATIVE[120](sResult10, CFrame.new(rootResult22.Position)))
            end
            if tbl365[1] then
              task.wait(v1355.settle or 0.25)
            end
            FResult3.run(v1356, a396, {
              shouldRun = function()
                return tbl365[1]
              end,
              minHold = 0,
              openWait = 0,
            })
            if v1359 then
              v1359:Disconnect()
            else
              local rootResult23 = sResult10.root()
              if rootResult23 then
                rootResult23.Anchored = false
              end
            end
          end
          res256:Disconnect()
          sResult10.clearVeil()
          return v1358
        end
        local fn680 = function(a1854, a2281)
          local num418 = 0
          repeat
            task.wait(0.3)
            num418 += 0.3
            local v1360 = LocalPlayer24.Character
                and LocalPlayer24.Character ~= a1854
                and LocalPlayer24.Character:FindFirstChild("HumanoidRootPart")
              or num418 > (a2281 or 20)
            if v1360 then
              continue
            end
            v1360 = not tbl365[1]
          until v1360
        end
        rotSupplier.jailBlocked=function()
          if rotSupplier.jailCharacter then return true end
          local character=LocalPlayer24.Character
          if character and v1345:HasTag(character,"Jailed") then
            rotSupplier.jailCharacter=character
            return true
          end
          return false
        end
        rotSupplier.recoverJail=function()
          if not rotSupplier.jailBlocked() then return true end
          local old=rotSupplier.jailCharacter
          local nextReset=0
          local stable
          while tbl365[1] do
            local current=LocalPlayer24.Character
            local root=current and current:FindFirstChild("HumanoidRootPart")
            local hum=current and current:FindFirstChildOfClass("Humanoid")
            if current and current~=old and root and hum and hum.Health>0 and not v1345:HasTag(current,"Jailed") then
              stable=stable or os.clock()
              if os.clock()-stable>=0.5 then rotSupplier.jailCharacter=nil;return true end
            else
              stable=nil
              if current and (current==old or v1345:HasTag(current,"Jailed")) and os.clock()>=nextReset then
                nextReset=os.clock()+3
                sResult10.clearVeil()
                if not hum or hum.Health>0 then pcall(sResult10.kill) end
              end
            end
            rotSupplier.status:SetText("Fornecedor: jail detectada; aguardando reset e NOVO personagem")
            task.wait(0.1)
          end
          return false -- Stop keeps the latch; restarting must finish this recovery before flying.
        end
        local fn681 = function()
          local Character73 = LocalPlayer24.Character
          sResult10.kill()
          fn680(Character73, 20)
        end
        local fn682 = function(a1855)
          local Toggles9 = Library9.Toggles
          local cond19 = not (Toggles9.NoFall and Toggles9.NoFall.Value)
          local v1361 = a1849.State.setKillbricks ~= nil and not (Toggles9.NoKillBricks and Toggles9.NoKillBricks.Value)
          local ok130 = true
          if cond19 then
            task.spawn(function()
              while ok130 do
                a1849.State.noFallUntil = tick() + num414
                task.wait(1)
              end
            end)
          end
          if v1361 then
            pcall(a1849.State.setKillbricks, true)
          end
          local setInnResult2 = HResult2.setInn(a1855, {
            shouldRun = function()
              return tbl365[1]
            end,
            breakJoints = true,
            attempts = 4,
          })
          ok130 = false
          if cond19 then
            a1849.State.noFallUntil = 0
          end
          if v1361 then
            pcall(a1849.State.setKillbricks, false)
          end
          return setInnResult2
        end
        local fn683 = function(a1856, a2282, a397)
          local num419 = 0
          while true do
            if not (tbl365[1] and not sResult10.near(a1856, a2282) and num419 < (a397 or 25)) then
              break
            end
            task.wait(0.3)
            num419 += 0.3
          end
          return sResult10.near(a1856, a2282)
        end
        local fn684 = function()
          local res257 = fn671()
          local v1362 = res257 and res257.Character and res257.Character:FindFirstChild("HumanoidRootPart")
          return v1362 ~= nil and (v1362.Position - vector327).Magnitude <= 225, res257, v1362
        end
        local fn685 = function()
          local requestRemoteResult4 = eResult8.requestRemote("ReturnToMenu")
          local num420 = 0
          while true do
            if not (tbl365[1] and not vResult6.startMenu() and num420 < 10) then
              break
            end
            if requestRemoteResult4 and vResult6.safeToMenu() then
              pcall(function()
                requestRemoteResult4:InvokeServer()
              end)
            end
            task.wait(0.4)
            num420 += 0.4
          end
          return vResult6.startMenu() ~= nil
        end
        local fn686 = function()
          while tbl365[1] and a1849.State.bladeManualMenu do task.wait(0.25) end
          if not tbl365[1] then return false end
          fn685()
          while true do
            if not (tbl365[1] and not fn684()) then
              break
            end
            task.wait(0.5)
          end
          if not tbl365[1] then
            return false
          end
          local num421 = 0
          while true do
            if not (tbl365[1] and vResult6.startMenu() and num421 < 12) then
              break
            end
            while tbl365[1] and a1849.State.bladeManualMenu do task.wait(0.25) end
            if not tbl365[1] then return false end
            if not vResult6.startMenu() then break end
            vResult6.clickPlay()
            task.wait(0.5)
            num421 += 0.5
          end
          local num422 = 0
          while true do
            if not (tbl365[1] and not sResult10.root() and num422 < 15) then
              break
            end
            task.wait(0.3)
            num422 += 0.3
          end
          return sResult10.root() ~= nil
        end
        rotSupplier.ensurePlaying=function()
          local deadline=os.clock()+60
          while tbl365[1] and a1849.State.bladeManualMenu do
            rotSupplier.status:SetText("Fornecedor: no menu; aguardando Play manual")
            task.wait(0.25);deadline=os.clock()+60
          end
          while tbl365[1] and (vResult6.startMenu() or not sResult10.root()) and os.clock()<deadline do
            if a1849.State.bladeManualMenu then return false end
            rotSupplier.status:SetText("Fornecedor: entrando no jogo (Play)")
            vResult6.clickPlay();task.wait(0.5)
          end
          return tbl365[1] and not vResult6.startMenu() and sResult10.root()~=nil
        end
        local fn687 = function(master)
          return rotSupplier.approach and rotSupplier.approach(master) or false
        end
        local fn688 = function(afterWipe)
          -- The supplier's explicit post-wipe restart is an exception to Stay in Server.
          -- Safety/proximity menu actions and receiver bots keep their existing policy.
          if not afterWipe and a1849.State.bladeMenuInsteadOfLeave and a1849.State.bladeMenuInsteadOfLeave("ROT: rejoin substituido por menu",true) then
            rotSupplier.rejoining=false
            return false
          end
          if not tbl365[1] or rotSupplier.stopped then return false end
          if not (Library9.Toggles.RotSupplierResume and Library9.Toggles.RotSupplierResume.Value) then
            rotSupplier.status:SetText("Fornecedor: ative Retomar fornecedor apos hop/rejoin para reiniciar apos wipe")
            return false
          end
          qResult4.set("rotbot_active","true")
          qResult4.set("rotbot_target",Options9.RotMaster and Options9.RotMaster.Value or "")
          DResult3.setupResume()
          local queued,queueError=DResult3.queueResume(true)
          if not queued then
            rotSupplier.status:SetText("Fornecedor: retomada nao preparada; "..tostring(queueError))
            return false
          end
          if not fn685() or not tbl365[1] then
            rotSupplier.status:SetText("Fornecedor: aguardando menu para rejoin apos wipe")
            return false
          end
          local remote=eResult8.requestRemote("JoinPublicServer")
          if not remote then
            rotSupplier.status:SetText("Fornecedor: aguardando JoinPublicServer para rejoin apos wipe")
            return false
          end
          rotSupplier.rejoining=true
          local sourceJob=game.JobId
          local started,failed=false,false
          local connections={}
          local function onFailed() failed=true end
          local ok,result=pcall(function()
            table.insert(connections,LocalPlayer24.OnTeleport:Connect(function(state)
              if state==Enum.TeleportState.Failed then failed=true else started=true end
            end))
            local service=game:GetService("TeleportService")
            table.insert(connections,service.TeleportInitFailed:Connect(function(player)
              if player==LocalPlayer24 then onFailed() end
            end))
            for attempt=1,num416 do
              if not tbl365[1] or rotSupplier.stopped then return false end
              if attempt>1 then
                local ready,why=DResult3.queueResume(true)
                if not ready then rotSupplier.status:SetText("Fornecedor: falha ao preparar retomada: "..tostring(why));return false end
              end
              started=false;failed=false
              rotSupplier.status:SetText("Fornecedor: rejoin apos wipe (tentativa "..attempt.."/"..num416..")")
              local sent=pcall(function() remote:FireServer(sourceJob) end)
              if not sent then failed=true end
              local deadline=os.clock()+num415
              local extended=false
              while tbl365[1] and not rotSupplier.stopped and not failed and os.clock()<deadline do
                if game.JobId~=sourceJob then return true end
                if started and not extended then
                  extended=true;deadline=math.max(deadline,os.clock()+25)
                end
                task.wait(0.1)
              end
              -- A successful rejoin replaces this Lua VM. If it is still running here,
              -- Started/InProgress alone is not proof of success: retry instead of ending the bot.
              if tbl365[1] and not rotSupplier.stopped then task.wait(1) end
            end
            return false
          end)
          for _,connection in connections do pcall(function() connection:Disconnect() end) end
          if ok and result then return true end
          rotSupplier.rejoining=false
          if tbl365[1] and not rotSupplier.stopped then
            rotSupplier.status:SetText("Fornecedor: rejoin nao concluiu; mantendo reinicio apos wipe para tentar novamente")
          end
          return false
        end
        local fn689 = function()
          return fn671() ~= nil
        end
        rotSupplier.refreshLife=function(manual)
          if Library9.Unloaded or not tbl365[1] or fn670() or rotSupplier.stopped or a1849.State.bladeManualMenu then return false end
          local character=LocalPlayer24.Character
          local root=character and character:FindFirstChild("HumanoidRootPart")
          local hum=character and character:FindFirstChildOfClass("Humanoid")
          if not root or not hum then return false end
          local now=os.clock()
          if rotSupplier.refreshCharacter~=character then
            rotSupplier.refreshCharacter=character;rotSupplier.refreshSince=now;rotSupplier.refreshPending=nil;rotSupplier.refreshRequested=nil
          end
          local lives=tonumber(a1849.State.getServerValue and a1849.State.getServerValue("Lives"))
          local pending=rotSupplier.refreshPending
          if pending then
            if not pending.confirmed and pending.lives and lives and lives<pending.lives then
              pending.confirmed=true
              rotSupplier.status:SetText("Fornecedor: perda de vida confirmada")
            end
            if pending.confirmed or hum.Health<=0 then return true end
          end
          if hum.Health<=0 then return false end
          if (root.Position-rotSupplier.receiverPoint).Magnitude>20 or character:FindFirstChild("Carried") or v1345:HasTag(character,"Jailed") then
            rotSupplier.refreshSince=now;rotSupplier.refreshRequested=nil;rotSupplier.refreshPending=nil;return false
          end
          if manual then rotSupplier.refreshRequested=true end
          if not pending and not manual and not rotSupplier.refreshRequested and (not rotSupplier.settings.refreshLife or now-(rotSupplier.refreshSince or now)<(tonumber(rotSupplier.settings.refreshSeconds) or 120)) then return false end
          if lives and lives<=0 then return false end
          rotSupplier.refreshRequested=nil
          -- Use the same force reset as jail/combat recovery. A missing or delayed Danger/Lives
          -- replication must not prevent the request. Retry only while this character is alive;
          -- a changed character or confirmed life loss ends this request.
          pending=pending or {lives=lives,nextAttempt=0}
          rotSupplier.refreshPending=pending
          if now<pending.nextAttempt then return true end
          pending.nextAttempt=now+3
          rotSupplier.status:SetText("Fornecedor: force reset solicitado; aguardando resposta do servidor")
          pcall(sResult10.clearVeil)
          local ok=pcall(sResult10.kill)
          if not ok then rotSupplier.status:SetText("Fornecedor: force reset falhou; nova tentativa em 3 segundos") end
          return true
        end
        local fn690 = function()
          local v1364
          local v1365
          local fn704 = function(a1859, a2283)
            if a1859 ~= v1364 then
              v1364 = a1859
              fn672("Rot Bot: " .. a2283)
            end
          end
          while tbl365[1] do
            if rotSupplier.jailBlocked() then
              if not rotSupplier.recoverJail() then return nil end
              continue
            end
            if sResult10.near(vector328, 75) and (fn675() or 0) <= 0 then
              return "ferryman"
            end
            if rotSupplier.refreshLife(false) then task.wait(0.25);continue end
            local Character74 = LocalPlayer24.Character
            local v1366 = Character74 and Character74:FindFirstChild("HumanoidRootPart")
            local v1367 = v1366 ~= nil and sResult10.near(vector327, 100)
            if v1367 then
              v1365 = nil
            end
            if not v1366 then
              task.wait(0.3)
            elseif v1345:HasTag(Character74, "Jailed") then
              rotSupplier.jailCharacter=Character74
              if not rotSupplier.recoverJail() then return nil end
            elseif v1345:HasTag(Character74, "Unconscious") or v1345:HasTag(Character74,"Knocked") then
              task.wait(0.4)
            elseif not v1367 then
              v1365 = v1365 or tick()
              if tick() - v1365 > 10 then
                fn704("away", "not at the Renova inn, waiting to be back there")
              end
              task.wait(0.4)
            elseif fn670() then
              fn704("carrier", "you picked alts, so this account carries and waits at Renova for them")
              task.wait(0.4)
            else
              local master,masterRoot=rotSupplier.masterReady()
              if not master then
                fn704("waiting","aguardando uma pessoa livre perto do ponto P14, sem depender de fila compartilhada")
                rotSupplier.status:SetText("Fornecedor: esperando alguem livre a ate 6 studs de P14")
                if (v1366.Position-rotSupplier.waitPoint).Magnitude>5 then
                  if rotSupplier.flyTo then rotSupplier.flyTo(rotSupplier.waitPoint+Vector3.new(0,2,0)) end
                end
                task.wait(0.3)
                continue
              end
              fn704("going:"..master.UserId,"voando ate "..master.Name.." para fornecer Rot")
              rotSupplier.status:SetText("Fornecedor: receptora "..master.Name.." pronta")
              fn687(master)
              local ready,readyRoot=rotSupplier.masterReady(master.UserId)
              local supplierRoot=sResult10.root()
              if ready and supplierRoot and (supplierRoot.Position-readyRoot.Position).Magnitude<=10 then
                local deadline=os.clock()+5
                while tbl365[1] and os.clock()<deadline do
                  local character=LocalPlayer24.Character
                  if not character or rotSupplier.jailBlocked() or v1345:HasTag(character,"Unconscious") or v1345:HasTag(character,"Knocked") then break end
                  local current,currentRoot=rotSupplier.masterReady(master.UserId)
                  local root=sResult10.root()
                  if not current or not root or (root.Position-currentRoot.Position).Magnitude>10 then break end
                  rotSupplier.status:SetText("Fornecedor: se downando para "..master.Name)
                  fn674()
                  task.wait(0.5)
                end
              end
              task.wait(0.4)
            end
          end
          return nil
        end
        local fn691 = function()
          LResult.wipe(function()
            return tbl365[1]
          end, {
            notify = function(a1860)
              fn672("Rot Bot: " .. a1860)
            end,
          })
        end
        local rotQueueEntry
        local fn692 = function()
          if v1347 then
            pcall(function()
              local v1372 = v1347
              v1372:SetText(rotQueueEntry and string.format("Rots da etapa: %d/16 | total: %d",rotQueueEntry.progress,v1346) or ("Rots confirmados (total): "..v1346))
            end)
          end
        end
        local rotQueueOnCount
        local rotDelivery={pending=nil,counted=setmetatable({}, {__mode="k"})}
        local fn693 = function(character,transaction)
          if not character then return false end
          if transaction then
            if transaction.character~=character or transaction.counted then return false end
            transaction.counted=true -- Deduplicate this delivery, not every delivery of this character forever.
          elseif rotDelivery.counted[character] then return false end
          rotDelivery.counted[character]=true
          v1346 += 1
          qResult4.set("rotbot_count", v1346)
          if rotQueueOnCount then rotQueueOnCount() end
          fn692()
          return true
        end
        local Maid9 = a1849.Maid
        Maid9:Give(v1345:GetInstanceAddedSignal("Jailed"):Connect(function(a1861)
          local pending=rotDelivery.pending
          if pending and pending.character==a1861 then pending.jailed=true end
          if not tbl365[1] or fn670() then return end
          -- A supplier can count its own prison event, never another receiver's event.
          if getResult26:GetPlayerFromCharacter(a1861)==LocalPlayer24 then
            rotSupplier.refreshSince=os.clock();rotSupplier.refreshPending=nil
            rotSupplier.jailCharacter=a1861 -- Latch even if lag removes Jailed before the supplier loop polls it.
            fn693(a1861)
          end
        end))
        local fn694 = function()
          while tbl365[1] do
            local res260 = rotSupplier.routeStage=="wipe" and "ferryman" or fn690()
            if not tbl365[1] then
              return
            end
            if res260 == "ferryman" then
              rotSupplier.routeStage="wipe"
              local lives=a1849.State.getServerValue and tonumber(a1849.State.getServerValue("Lives"))
              if not lives or lives<=0 then fn691() end
              local retryWipeAt=os.clock()+15
              -- Stay in this phase until the new life is confirmed and rejoin succeeds.
              -- Never fall back to waiting for ROT in Renova after a failed teleport.
              while tbl365[1] and not rotSupplier.stopped do
                local lives=a1849.State.getServerValue and tonumber(a1849.State.getServerValue("Lives"))
                if lives and lives>0 then
                  rotSupplier.jailCharacter=nil
                  if fn688(true) then return "teleporting" end
                  if tbl365[1] and not rotSupplier.stopped then task.wait(2) end
                else
                  rotSupplier.status:SetText("Fornecedor: aguardando wipe concluir e vidas do novo personagem")
                  if lives==0 and os.clock()>=retryWipeAt and sResult10.near(vector328,75) then
                    fn691();retryWipeAt=os.clock()+15
                  end
                  task.wait(0.25)
                end
              end
              return
            else
              if res260 ~= "menu" then
                return
              end
              if not fn686() then
                return
              end
            end
          end
        end
        local fn695 = function()
          while tbl365[1] do
            local stage=rotSupplier.routeStage or "Santorini"
            local nextStage
            if stage=="Santorini" then
              if fn682("Santorini") then nextStage="Brom" end
            elseif stage=="Brom" then
              if fn679(tbl362,"Brom",{"You're a merchant?","If I see her."},{settle=0.25,range=30,anchor=true,speed=100}) then nextStage="reset" end
            elseif stage=="reset" then
              rotSupplier.routeStage="travel" -- The reset must not be repeated after a safety pause.
              fn681();nextStage="travel"
            elseif stage=="travel" then
              fn683(vector326,100);nextStage="Fir"
            elseif stage=="Fir" then
              if fn679(tbl363,"Fir",{"What's wrong?","Do you mean Brom?","Yeah, I saw him earlier.","I saw him napping on the job."}) then nextStage="Renova" end
            elseif stage=="Renova" then
              if fn682("Renova") then nextStage="collect" end
            elseif stage=="collect" or stage=="wipe" then
              if fn694()=="teleporting" then return end
              if not tbl365[1] then return end
              task.wait(0.5)
            else error("Etapa ROT desconhecida: "..tostring(stage)) end
            if not tbl365[1] then return end
            if nextStage then rotSupplier.routeStage=nextStage
            elseif stage~="collect" and stage~="wipe" then
              fn672("Rot Bot: "..stage.." indisponivel; nova tentativa")
              task.wait(2)
            end
          end
        end
        local fn696 = function()
          if not tbl366[1] then
            return
          end
          tbl366[1] = false
          a1849.State.fallDamageBypassUntil = 0
          a1849.State.noFallUntil = 0
          sResult10.clearVeil()
          local Character75 = LocalPlayer24.Character
          if not Character75 then
            return
          end
          local HumanoidRootPart19 = Character75:FindFirstChild("HumanoidRootPart")
          if HumanoidRootPart19 then
            HumanoidRootPart19.Anchored = false
          end
          local getDescendantsResult15, v1373, v1374 = Character75:GetDescendants()
          for k307, v1375 in getDescendantsResult15, v1373, v1374 do
            if v1375:IsA("BasePart") and v1375.Name ~= "HumanoidRootPart" then
              v1375.CanCollide = v1375.Name == "Head" or v1375.Name == "Torso"
            end
          end
          local Humanoid21 = Character75:FindFirstChildOfClass("Humanoid")
          if Humanoid21 then
            Humanoid21:SetStateEnabled(5, true)
            Humanoid21:ChangeState(5)
          end
        end
        a1849.Maid:Give(function()
          tbl365[1] = false
          fn696()
        end)
        v1347 = rotQueueTab:AddLabel("Rots confirmados (total): " .. v1346)
        rotBotTab:AddButton({
          Text = "Reset Rot Count",
          Func = function()
            if tbl365[1] or rotQueueEntry or rotDelivery.pending then
              fn672("Pare os bots e saia da fila antes de zerar o contador Rot")
              return
            end
            v1346 = 0
            qResult4.set("rotbot_count", 0)
            fn692()
          end,
        })
        local tbl367 = { false }
        a1849.Maid:Give(function()
          tbl367[1] = true
          channelResult.clearCommand()
          channelResult.dropBeacon()
        end)
        rotBotTab:AddDivider()
        rotHidden:AddInput("RotMaster", {
          Text = "Master",
          Default = "",
          Placeholder = "who carries you",
          Finished = true,
          Tooltip = "Receptora atual da fila. O fornecedor espera a confirmacao de que ela chegou e esta livre.",
          Callback = function(a1862)
            local matchResult7 = MResult.match(a1862)
            if matchResult7 and matchResult7.Name ~= a1862 then
              Options9.RotMaster:SetValue(matchResult7.Name)
            end
          end,
        })
        rotReceiverTab:AddLabel("Rots: selecione Alts ou ative 23 para pegar downados livres em ate 30 studs. Master e fila sao automaticos.", true)
        if not MResult.available() then
          rotBotTab:AddLabel("This executor has no file access, so alts cannot be listed", true)
        end
        rotReceiverTab:AddDropdown("RotAlts", {
          Text = "Selecionar Alts fornecedoras",
          Values = {},
          Multi = true,
          Default = {},
          Tooltip = "Select accounts in this server; targets do not need Sentinel",
        })
        local rotQueueCanRun = function() return true end
        local fn697 = function()
          return not tbl367[1] and tbl365[1] and rotQueueCanRun()
        end
        local tbl368 = {}
        local tbl369 = {}
        local fn698 = function()
          local tbl371 = {}
          if a1849.State.blade23Enabled and a1849.State.blade23Enabled() then
            for _,player in getResult26:GetPlayers() do
              if player~=LocalPlayer24 then table.insert(tbl371,player.Name) end
            end
            return tbl371
          end
          local pairsResult6, v1376, v1377 = pairs(a1849.State.bladeRunAlts or (Options9.RotAlts and Options9.RotAlts.Value or {}))
          for k308, v1378 in pairsResult6, v1376, v1377 do
            if v1378 then
              table.insert(tbl371, k308)
            end
          end
          return tbl371
        end
        local fn699 = function()
          local Character76 = LocalPlayer24.Character
          local marker=Character76 and Character76:FindFirstChild("Grabbing")
          if not marker then return false end
          if marker:IsA("ObjectValue") then return marker.Value~=nil end
          if marker:IsA("BoolValue") then return marker.Value end
          return true
        end
        local fn700 = function()
          local Character77 = LocalPlayer24.Character
          local v1379 = Character77 and Character77:FindFirstChild("CharacterHandler")
          local v1380 = v1379 and v1379:FindFirstChild("Remotes")
          return v1380 and v1380:FindFirstChild("Carry") or nil
        end
        local rotOfficerLock
        local fn701 = function()
          local npcs = v1341:FindFirstChild("NPCs")
          local carrierRoot = sResult10.root()
          if not npcs or not carrierRoot then return nil end
          if rotOfficerLock and rotOfficerLock.Parent then
            local lockedRoot=rotOfficerLock:FindFirstChild("HumanoidRootPart") or rotOfficerLock.PrimaryPart
            if lockedRoot then return rotOfficerLock, (lockedRoot.Position-carrierRoot.Position).Magnitude end
          end
          -- Renova inn: (-2126,609,-709). Officer desk: vector329.
          -- Match the exact NPC and its desk, never a nearby Bounty Hunter.
          local closest, bestDeskDistance
          for _, npc in npcs:GetDescendants() do
            if npc:IsA("Model") and npc.Name == "Bounty Officer" then
              local root = npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart
              local detector = npc:FindFirstChildWhichIsA("ClickDetector", true)
              if root and detector then
                local deskDistance = (root.Position-vector329).Magnitude
                local innDistance = (root.Position-vector327).Magnitude
                if deskDistance <= 40 and innDistance <= 150
                  and math.abs(root.Position.Y-vector327.Y) <= 25
                  and (not bestDeskDistance or deskDistance < bestDeskDistance) then
                  closest, bestDeskDistance = npc, deskDistance
                end
              end
            end
          end
          if not closest then return nil end
          rotOfficerLock = closest
          local root = closest:FindFirstChild("HumanoidRootPart") or closest.PrimaryPart
          return closest, (root.Position-carrierRoot.Position).Magnitude
        end
        rotDelivery.activeMarker=function(marker)
          if not marker then return false end
          if marker:IsA("BoolValue") then return marker.Value end
          if marker:IsA("ObjectValue") then return marker.Value~=nil end
          return true
        end
        rotDelivery.snapshotCarried=function()
          local snapshot={}
          for _,player in getResult26:GetPlayers() do
            local character=player.Character
            if character and rotDelivery.activeMarker(character:FindFirstChild("Carried")) then snapshot[character]=true end
          end
          return snapshot
        end
        rotDelivery.identify=function()
          local own=LocalPlayer24.Character
          if not own then return nil end
          local players=getResult26:GetPlayers()
          local function characterOf(value)
            if typeof(value)~="Instance" then return nil end
            for _,player in players do
              local character=player.Character
              if character and (value==player or value==character or value:IsDescendantOf(character)) then return character end
            end
          end
          local grabbing=own:FindFirstChild("Grabbing")
          if grabbing and grabbing:IsA("ObjectValue") then
            local character=characterOf(grabbing.Value)
            if character and character~=own then return character end
          end
          for _,player in players do
            local character=player.Character
            local carried=character and character:FindFirstChild("Carried")
            if character~=own and carried and carried:IsA("ObjectValue") and characterOf(carried.Value)==own then return character end
          end
          -- Carry has no target argument. Resolve the actual replicated attachment, not the requested alt.
          for _,joint in own:GetDescendants() do
            if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
              local first,second=characterOf(joint.Part0),characterOf(joint.Part1)
              if first==own and second and second~=own then return second end
              if second==own and first and first~=own then return first end
            end
          end
          local root=own:FindFirstChild("HumanoidRootPart")
          local snapshot=rotDelivery.pickupSnapshot
          if not root or not snapshot then return nil end
          local candidate
          for _,player in players do
            local character=player.Character
            local part=character and character:FindFirstChild("HumanoidRootPart")
            if character and character~=own and not snapshot[character] and part
              and rotDelivery.activeMarker(character:FindFirstChild("Carried")) and (part.Position-root.Position).Magnitude<=6 then
              if candidate then return nil end -- Ambiguous: wait for an attachment instead of attributing the wrong jail.
              candidate=character
            end
          end
          return candidate
        end
        local rotCarriedCharacter
        local fn702 = function(a1863)
          local character=a1863 and a1863.Character
          if not character then return false end
          if not fn699() then rotDelivery.pickupSnapshot=rotDelivery.snapshotCarried() end
          local function confirmCarry()
            if not fn699() then return false end
            local actual=rotDelivery.identify()
            if not actual or not rotDelivery.begin(actual,true) then return false end
            rotCarriedCharacter=actual
            return true
          end
          local started=os.clock()
          local ping=0.4
          pcall(function() ping=math.clamp(tonumber(LocalPlayer24:GetNetworkPing()) or ping,0,1.5) end)
          local retryDelay=math.clamp(ping*3+0.4,0.8,3)
          local deadline=started+math.max(4,retryDelay*3)
          local nextAttempt=0
          local attempts=0
          while fn697() and os.clock()<deadline do
            if a1863.Character~=character or not a1863.Parent then return false end
            if fn699() then
              if confirmCarry() then return true end
              task.wait(0.05)
              continue -- A carry exists; do not toggle it while the victim identity is still replicating.
            end
            local carried=character:FindFirstChild("Carried")
            local beingCarried=carried and (not carried:IsA("BoolValue") or carried.Value)
              and (not carried:IsA("ObjectValue") or carried.Value~=nil)
            if beingCarried and attempts==0 then return false end
            if v1345:HasTag(character,"Jailed") then return false end
            if beingCarried then
              -- The victim's marker may replicate before our Grabbing marker: wait, never toggle Carry again.
              deadline=math.max(deadline,started+8)
            else
              local down=v1345:HasTag(character,"Unconscious") or v1345:HasTag(character,"Knocked")
              local distance=MResult.distanceTo(a1863)
              if attempts==0 and (not down or not distance or distance>4) then return false end
              if down and distance and distance<=4 and attempts<3 and os.clock()>=nextAttempt then
                local remote=fn700()
                if remote then
                  attempts+=1
                  pcall(function() remote:FireServer() end)
                  nextAttempt=os.clock()+retryDelay
                else nextAttempt=os.clock()+0.25 end
                if confirmCarry() then return true end
              end
            end
            task.wait(0.05)
          end
          if a1863.Character==character and fn697() and confirmCarry() then return true end
          return false
        end
        local rotWalkStatus = rotQueueTab:AddLabel("Walk: disabled (select Alts, then enable)")
        local rotDestinationMarker = Instance.new("Part")
        rotDestinationMarker.Name = "ROT_RENOVA_DESTINATION"
        rotDestinationMarker.Size = Vector3.new(1,1,1)
        rotDestinationMarker.Anchored = true
        rotDestinationMarker.CanCollide = false
        rotDestinationMarker.CanTouch = false
        rotDestinationMarker.CanQuery = false
        rotDestinationMarker.Material = Enum.Material.Neon
        rotDestinationMarker.Color = Color3.fromRGB(0,255,180)
        rotDestinationMarker.Transparency = 1
        rotDestinationMarker.Parent = v1341
        a1849.Maid:Give(rotDestinationMarker)
        -- Carrier navigation uses Humanoid movement only, never Tween/CFrame.
        local function rotWalkTo(destination, keepGoing, range)
          range = range or 4
          local character=LocalPlayer24.Character
          local humanoid=character and character:FindFirstChildOfClass("Humanoid")
          if not humanoid then return false end
          local deadline=os.clock()+45
          local blockedConnection,moveConnection,activePath
          local function releasePath()
            if moveConnection then moveConnection:Disconnect();moveConnection=nil end
            if blockedConnection then blockedConnection:Disconnect();blockedConnection=nil end
            if activePath then activePath:Destroy();activePath=nil end
          end
          local function targetPosition()
            return type(destination)=="function" and destination() or destination
          end
          local function closeEnough(a,b,r)
            local horizontal=Vector3.new(a.X-b.X,0,a.Z-b.Z).Magnitude
            return horizontal<=r and math.abs(a.Y-b.Y)<=6
          end
          local function groundPosition(position)
            local excluded={rotDestinationMarker}
            local npcs=v1341:FindFirstChild("NPCs")
            if npcs then table.insert(excluded,npcs) end
            for _,player in getResult26:GetPlayers() do
              if player.Character then table.insert(excluded,player.Character) end
            end
            local params=RaycastParams.new()
            params.FilterType=Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances=excluded
            params.RespectCanCollide=true
            local hit=v1341:Raycast(position+Vector3.new(0,1,0),Vector3.new(0,-12,0),params)
            return hit and hit.Position+Vector3.new(0,0.1,0) or position
          end
          local function active()
            return fn697() and keepGoing() and LocalPlayer24.Character==character
              and humanoid.Parent and humanoid.Health>0 and os.clock()<deadline
          end
          local success=false
          local ok,err=pcall(function()
            local failures=0
            while active() and failures<8 do
              local root=sResult10.root()
              local target=targetPosition()
              if not root or typeof(target)~="Vector3" then break end
              if closeEnough(root.Position,target,range) then success=true; break end
              local path=game:GetService("PathfindingService"):CreatePath({
                AgentRadius=2, AgentHeight=5, AgentCanJump=true,
                AgentCanClimb=true, WaypointSpacing=3,
              })
              activePath=path
              rotWalkStatus:SetText("Walk: calculating route around obstacles")
              path:ComputeAsync(groundPosition(root.Position),groundPosition(target))
              if not active() then break end
              if path.Status~=Enum.PathStatus.Success then
                failures+=1
                rotWalkStatus:SetText("Walk: no route; retry "..failures.."/8")
                releasePath()
                task.wait(0.25)
                continue
              end
              local waypoints=path:GetWaypoints()
              local waypointIndex=2
              local blocked=false
              blockedConnection=path.Blocked:Connect(function(index)
                if index>=waypointIndex then blocked=true end
              end)
              local replan=false
              for index=2,#waypoints do
                waypointIndex=index
                if not active() then break end
                local point=waypoints[index]
                if point.Action==Enum.PathWaypointAction.Jump then humanoid.Jump=true end
                local reached=false
                if humanoid.MoveToFinished then
                  moveConnection=humanoid.MoveToFinished:Connect(function(success)
                    local current=sResult10.root()
                    if success and current and closeEnough(current.Position,point.Position,3) then reached=true end
                  end)
                end
                humanoid:MoveTo(point.Position)
                local stepDeadline=math.min(deadline,os.clock()+5)
                local lastProgress=os.clock()
                local bestDistance=math.huge
                while active() do
                  root=sResult10.root()
                  local currentTarget=targetPosition()
                  if not root or typeof(currentTarget)~="Vector3" then replan=true; break end
                  if closeEnough(root.Position,currentTarget,range) then success=true; break end
                  if closeEnough(root.Position,point.Position,1.5) or reached then break end
                  local remaining=Vector3.new(root.Position.X-point.Position.X,0,root.Position.Z-point.Position.Z).Magnitude
                  if remaining<bestDistance-0.2 then bestDistance=remaining; lastProgress=os.clock() end
                  if blocked or (currentTarget-target).Magnitude>6 or os.clock()>=stepDeadline
                    or os.clock()-lastProgress>1.5 then
                    replan=true
                    break
                  end
                  task.wait(0.05)
                end
                if moveConnection then moveConnection:Disconnect();moveConnection=nil end
                if success or replan then break end
              end
              releasePath()
              if success then break end
              failures+=1
              rotWalkStatus:SetText("Walk: obstacle or stuck; recalculating "..failures.."/8")
              task.wait(0.1)
            end
          end)
          releasePath()
          local root=sResult10.root()
          if humanoid.Parent and root and LocalPlayer24.Character==character then humanoid:MoveTo(root.Position) end
          if not ok then rotWalkStatus:SetText("Walk navigation error: "..tostring(err)) end
          return ok and success
        end
        rotSupplier.flyTo=function(position)
          if rotSupplier.jailBlocked() then return false end
          local connection=fn676()
          local ok,err=pcall(fn677,position,100)
          connection:Disconnect()
          sResult10.clearVeil()
          local character=LocalPlayer24.Character
          local root=sResult10.root()
          if root then root.Anchored=false;root.AssemblyLinearVelocity=Vector3.zero end
          if character then sResult10.reclip(character) end
          local hum=sResult10.humanoid()
          if hum then hum:SetStateEnabled(5,true);hum:ChangeState(5) end
          if not ok then rotSupplier.status:SetText("Fornecedor: falha no voo "..tostring(err)) end
          return ok and err~=false
        end
        rotSupplier.approach=function(master)
          local ready,root=rotSupplier.masterReady(master.UserId)
          if not ready then return false end
          return rotSupplier.flyTo(root.Position+Vector3.new(0,2,0))
        end
        rotDelivery.closeDialogue=function()
          if not FResult3.inDialogue() then return true end
          FResult3.requestClose() -- Rate-limited by the dialogue helper; no extra worker or blocking wait.
          return not FResult3.inDialogue()
        end
        rotDelivery.begin=function(character,fromPickup)
          local pending=rotDelivery.pending
          if pending then return pending.character==character and pending or nil end
          if not character or (rotDelivery.counted[character] and not fromPickup) or v1345:HasTag(character,"Jailed") then return nil end
          local player=getResult26 and getResult26:GetPlayerFromCharacter(character)
          pending={character=character,player=player,jailed=false,started=os.clock()}
          rotDelivery.pending=pending -- Arm before interacting; the tag can arrive before dialogue returns.
          return pending
        end
        rotDelivery.await=function(pending,retryWhileCarrying)
          if not pending or rotDelivery.pending~=pending then return false end
          if retryWhileCarrying and fn699() and not pending.jailed
            and not pending.dialogueSucceeded and not v1345:HasTag(pending.character,"Jailed") then
            -- A failed/empty dialogue needs a retry, not twelve seconds of waiting for a jail it never sent.
            pending.nextDialogueAt=os.clock()+0.5
            rotWalkStatus:SetText("Walk: Officer nao confirmou; nova tentativa de dialogo em breve")
            return false
          end
          local deadline=os.clock()+12
          local settled
          while fn697() and rotDelivery.pending==pending and os.clock()<deadline do
            rotDelivery.closeDialogue()
            if v1345:HasTag(pending.character,"Jailed") then pending.jailed=true end
            local retired=pending.character.Parent==nil or (pending.player and pending.player.Character~=pending.character)
            local confirmed=pending.jailed or (pending.dialogueSucceeded and retired)
            if confirmed and not fn699() then
              settled=settled or os.clock()
              if os.clock()-settled>=0.1 then
                local counted=fn693(pending.character,pending)
                rotDelivery.pending=nil
                rotDelivery.pickupSnapshot=nil
                if rotCarriedCharacter==pending.character then rotCarriedCharacter=nil end
                if counted then rotWalkStatus:SetText("Walk: Rot confirmado (entrega individual concluida)") end
                return counted
              end
            else settled=nil end
            rotWalkStatus:SetText(pending.jailed and "Walk: prisao confirmada; aguardando soltar a vitima" or "Walk: aguardando o jogo confirmar a prisao da vitima")
            task.wait(0.05)
          end
          if not fn697() then
            rotWalkStatus:SetText("Walk: entrega pendente preservada para a retomada")
            return false
          end
          if pending.jailed or pending.dialogueSucceeded then
            rotWalkStatus:SetText("Walk: resposta recebida; aguardando confirmar a vitima sem descartar a entrega")
            return false
          end
          rotWalkStatus:SetText("Walk: entrega sem confirmacao; contador nao foi alterado")
          if not fn699() then
            if rotCarriedCharacter==pending.character then rotCarriedCharacter=nil end
            if rotDelivery.pending==pending then rotDelivery.pending=nil end
          end
          return false
        end
        local fn703 = function(a1864)
          if fn699() then
            local actual=rotDelivery.identify()
            if not actual or (rotDelivery.pending and rotDelivery.pending.character~=actual) then
              rotWalkStatus:SetText("Walk: aguardando identificar a vitima realmente carregada")
              return false
            end
            rotCarriedCharacter=actual
            rotDelivery.begin(actual,true)
          end
          local pending=rotDelivery.pending
          if pending and pending.nextDialogueAt and os.clock()<pending.nextDialogueAt then return false end
          local res265, officerDistance = fn701()
          if not res265 then
            rotWalkStatus:SetText("Walk: Renova Bounty Officer not found; staying put")
            fn672("Rot Bot: Renova Bounty Officer missing at the Renova desk; staying put")
            return false
          end
          rotWalkStatus:SetText(string.format("Walk: Renova %s (%.1f studs)", res265.Name, officerDistance or 0))
          local HumanoidRootPart20 = res265:FindFirstChild("HumanoidRootPart") or res265.PrimaryPart
          local ClickDetector7 = res265:FindFirstChildWhichIsA("ClickDetector", true)
          if not (HumanoidRootPart20 and ClickDetector7 and fireclickdetector_5) then
            return false
          end
          rotDestinationMarker.Position = HumanoidRootPart20.Position + Vector3.new(0,4,0)
          rotDestinationMarker.Transparency = 0
          print("[Rot destination] " .. res265:GetFullName() .. " at " .. tostring(HumanoidRootPart20.Position) .. " carrying " .. tostring(a1864))
          local rootResult26 = sResult10.root()
          local interactionRange=math.min(6,math.max(3,(tonumber(ClickDetector7.MaxActivationDistance) or num407)-2))
          if rootResult26 and (rootResult26.Position - HumanoidRootPart20.Position).Magnitude > interactionRange then
            local vertical=math.abs(rootResult26.Position.Y-HumanoidRootPart20.Position.Y)
            local approachRange=math.max(1,math.min(4,math.sqrt(math.max(1,interactionRange*interactionRange-vertical*vertical))-1))
            if not rotWalkTo(function()
              return HumanoidRootPart20.Parent and HumanoidRootPart20.Position or nil
            end, function() return fn697() and fn699() end, approachRange) then
              fn672("Rot Bot: could not walk to Renova Officer; waiting to retry")
              return false
            end
          end
          if not fn699() then
            fn672("Rot Bot: the carry dropped before the desk")
            return false
          end
          -- Let Humanoid movement stop before clicking; this can take several frames at 15 FPS.
          local settleDeadline=os.clock()+2
          local settledSince
          while fn697() and fn699() and os.clock()<settleDeadline do
            local current=sResult10.root()
            if not current then return false end
            if (current.Position-HumanoidRootPart20.Position).Magnitude>interactionRange+0.5 then
              rotWalkStatus:SetText("Walk: fora do alcance do Officer; aproximando novamente")
              return false
            end
            local velocity=current.AssemblyLinearVelocity
            if not velocity or velocity.Magnitude<=2 then
              settledSince=settledSince or os.clock()
              if os.clock()-settledSince>=0.2 then break end
            else settledSince=nil end
            task.wait(0.05)
          end
          if not fn697() then return false end
          local transaction=rotDelivery.begin(rotCarriedCharacter)
          if not transaction then
            rotWalkStatus:SetText("Walk: vitima nao identificada ou ja contabilizada; nenhuma nova entrega")
            return false
          end
          -- The dialogue helper opens the NPC itself. Do not pre-click and then
          -- make it close the dialogue it has just opened.
          if not rotDelivery.closeDialogue() then return false end
          rotWalkStatus:SetText("Walk: delivering at Renova (dialogue, no position lock)")
          local dialogueDeadline = os.clock() + 20
          local result = table.pack(pcall(FResult3.run, res265, {}, {
            shouldRun = function()
              if v1345:HasTag(transaction.character,"Jailed") then transaction.jailed=true end
              return fn697() and os.clock()<dialogueDeadline and not (transaction.jailed and not fn699())
            end,
            successWhen = tbl364, stopOnSuccess = true, minHold = 0, openWait = 0, quietPeriod = 0, answerDelay=0.1,
            holdPosition = false, timeout = 12, silence = 6, reopenAfter = 2.5, maxReplays = 1,
            log = function(message) print("[Rot delivery] " .. tostring(message)) end,
          }))
          -- Sixth run return is the server's positive success marker (seventh after pcall).
          if result[1] and result[7]==true then transaction.dialogueSucceeded=true end
          rotDelivery.closeDialogue()
          local confirmed=rotDelivery.await(transaction,true)
          if confirmed then
            fn672("Rot Bot: Rot confirmado de "..tostring(a1864))
            return true
          end
          if not result[1] then
            fn672("Rot Bot: erro no dialogo; nenhuma entrega presumida: "..tostring(result[2]))
            return false
          end
          local _,_,lastMessage=table.unpack(result,2,result.n)
          if lastMessage and tostring(lastMessage):lower():find(str52,1,true) then
            fn672("Rot Bot: "..tostring(a1864).." is not rottable")
          end
          return false
        end
        local function rotTargetDown(character)
          return character ~= nil and (v1345:HasTag(character, "Unconscious")
            or v1345:HasTag(character, "Knocked"))
        end
        local rotWalkBusy = false
        local rotQueueOwner
        local rotQueueOwnerId
        local rotQueueQuietSince = os.clock()
        local rotQueueFolder = "sentinel/.cache/rot_receiver_queue"
        local rotQueuePath = rotQueueFolder .. "/" .. tostring(LocalPlayer24.UserId) .. ".json"
        local rotQueueLabel = rotQueueTab:AddLabel("Queue: not joined | goal: 16 confirmed jails")
        local function queueWrite(entry)
          return MResult.writeJson(rotQueuePath, entry)
        end
        local rotRosterCache={entries={},at=-math.huge,busy=false}
        local function queueRoster()
          if rotRosterCache.busy or os.clock()-rotRosterCache.at<0.5 then return rotRosterCache.entries end
          rotRosterCache.busy=true
          local ok,result=pcall(function()
            local entries={}
            for _, file in MResult.sharedList(rotQueueFolder) do
              local fileUserId=tonumber(tostring(file):match("([^/\\]+)%.json$"))
              if fileUserId and getResult26:GetPlayerByUserId(fileUserId) then
                local e=MResult.readJson(file)
                if type(e)=="table" and e.userId==fileUserId and e.jobId==game.JobId and e.state=="waiting"
                  and type(e.at)=="number" and MResult.sharedNow()-e.at<=MResult.sharedLease()
                  and type(e.joined)=="number" and type(e.userId)=="number"
                  and getResult26:GetPlayerByUserId(e.userId) then
                  table.insert(entries,e)
                end
              end
            end
            table.sort(entries,function(a,b)
              local aOrder=a._order or a.joined
              local bOrder=b._order or b.joined
              if aOrder==bOrder then return a.userId<b.userId end
              return aOrder<bOrder
            end)
            return entries
          end)
          rotRosterCache.busy=false
          if not ok then error(result,0) end
          rotRosterCache.entries=result;rotRosterCache.at=os.clock()
          return result
        end
        local function queueJoin()
          rotSupplier.explicitSupplier=false
          if rotQueueEntry then return true end
          if not MResult.available() then
            fn672("Rot Queue: configure shared files or Remote HTTP")
            return false
          end
          if not fn670() then
            fn672("Rot Queue: select the downed supplier accounts in Alts first")
            return false
          end
          if not (Library9.Toggles.BlatantMode and Library9.Toggles.BlatantMode.Value) then
            fn672("Rot Queue: enable Blatant Mode on the receiver first")
            return false
          end
          local previous=MResult.readJson(rotQueuePath)
          local savedProgress,runId
          if a1849.State.bladeRotProgress then savedProgress,runId=a1849.State.bladeRotProgress() end
          local resumePrevious=previous and previous.jobId==game.JobId and (previous.state=="waiting" or previous.state=="left")
            and (not runId or not previous.runId or previous.runId==runId)
          local progress=tonumber(savedProgress)
          if progress==nil then progress=resumePrevious and tonumber(previous.progress) or 0 end
          progress=math.clamp(progress or 0,0,16)
          rotQueueEntry={userId=LocalPlayer24.UserId,name=LocalPlayer24.Name,jobId=game.JobId,runId=runId,
            joined=DateTime.now().UnixTimestampMillis,at=os.time(),state="waiting",progress=progress,baseline=v1346-progress}
          if resumePrevious then rotQueueEntry.joined=previous.joined or rotQueueEntry.joined end
          if not queueWrite(rotQueueEntry) then
            rotQueueEntry=nil
            fn672("Rot Queue: failed to write queue file")
            return false
          end
          qResult4.set("rot_queue_joined","true")
          qResult4.remove("rot_queue_complete")
          rotQueueQuietSince=os.clock()
          fn692()
          return true
        end
        local function queueLeave(state)
          if not rotQueueEntry then return end
          rotQueueEntry.state=state or "left"
          rotQueueEntry.at=os.time()
          queueWrite(rotQueueEntry)
          rotQueueEntry=nil
          rotQueueOwner=nil
          qResult4.remove("rot_queue_joined")
        end
        a1849.State.rotReceiverHasTurn=function()
          return rotQueueEntry~=nil and rotQueueOwnerId==LocalPlayer24.UserId and rotQueueOwner==LocalPlayer24.Name
            and os.clock()-rotQueueQuietSince>=1.5 and rotQueueEntry.progress<16
        end
        rotQueueCanRun=function()
          if not rotQueueEntry then return true end
          return a1849.State.rotReceiverHasTurn()
            and (not a1849.State.bladeRunAlts or a1849.State.bladeReceiverAtP14==true)
        end
        rotQueueOnCount=function()
          if rotQueueEntry and rotQueueOwnerId==LocalPlayer24.UserId then
            rotQueueEntry.progress=math.clamp(v1346-rotQueueEntry.baseline,0,16)
            rotQueueEntry.at=os.time()
            queueWrite(rotQueueEntry)
            if a1849.State.onRotDeliveryConfirmed then a1849.State.onRotDeliveryConfirmed(rotQueueEntry.progress) end
          end
        end
        -- Blade/Sigil P2 can call this without relying on UI or player guesses.
        a1849.State.joinRotReceiverQueue=function()
          local ok,result=pcall(queueJoin)
          if not ok then
            rotQueueLabel:SetText("Queue connection error: "..tostring(result))
            return false
          end
          return result
        end
        a1849.State.leaveRotReceiverQueue=queueLeave
        a1849.State.rotReceiverQueueComplete=function()
          return qResult4.get("rot_queue_complete")=="true"
        end
        rotHidden:AddToggle("RotReceiverQueue", {
          Text="Join receiver queue (16 Rots)", Default=false,
          Tooltip="Enable on accounts collecting Orderly, not on accounts being jailed",
          Callback=function(value)
            if value then
              if not a1849.State.joinRotReceiverQueue() then
                task.defer(function() Library9.Toggles.RotReceiverQueue:SetValue(false) end)
              end
            else queueLeave("left") end
          end,
        })
        local rotQueueLastAutoMaster
        local function queueTick()
          if tbl365[1] or rotQueueEntry then
            channelResult.beacon({blatant=iResult6.on(Library9,"Blatant"),rotSupplier=not rotQueueEntry})
          end
          if rotQueueEntry then
            rotQueueEntry.at=os.time()
            rotQueueEntry.progress=math.clamp(v1346-rotQueueEntry.baseline,0,16)
            local character=LocalPlayer24.Character
            local root=character and character:FindFirstChild("HumanoidRootPart")
            local hum=character and character:FindFirstChildOfClass("Humanoid")
            rotQueueEntry.ready=rotQueueCanRun() and tbl365[1] and root~=nil and hum~=nil
              and hum.Health>0 and (root.Position-rotSupplier.receiverPoint).Magnitude<=12 and not fn699()
              and not v1345:HasTag(character,"Unconscious") and not v1345:HasTag(character,"Knocked")
              and not v1345:HasTag(character,"Jailed")
            if not queueWrite(rotQueueEntry) then
              rotSupplier.owner=nil
              rotQueueOwnerId=nil
              rotQueueLabel:SetText("Queue paused: "..tostring(MResult.net.lastError or "shared write failed"))
              return
            end
            if rotQueueEntry.progress>=16 and not rotWalkBusy and not fn699() then
              FResult3.close(1)
              queueLeave("done")
              qResult4.set("rot_queue_complete","true")
              if Library9.Toggles.RotBotEnabled then Library9.Toggles.RotBotEnabled:SetValue(false) end
              rotQueueLabel:SetText("Queue: complete 16/16; next receiver may start")
              if a1849.State.onRotReceiverQueueComplete then
                task.spawn(a1849.State.onRotReceiverQueueComplete)
              end
              return
            end
          end
          local roster=queueRoster()
          local owner=roster[1]
          rotSupplier.owner=owner
          rotSupplier.seen=os.clock()
          local ownerId=owner and owner.userId
          if ownerId~=rotQueueOwnerId then
            rotQueueQuietSince=os.clock()
            rotQueueOwnerId=ownerId
          end
          rotQueueOwner=owner and owner.name or nil
          -- Sentinel suppliers follow Master. An unrelated external script must
          -- read this setting itself if it is expected to follow automatically.
          if owner and Options9.RotMaster then
            if Options9.RotMaster.Value~=owner.name then Options9.RotMaster:SetValue(owner.name) end
            rotQueueLastAutoMaster=owner.name
          elseif not owner and rotQueueLastAutoMaster and Options9.RotMaster then
            if Options9.RotMaster.Value==rotQueueLastAutoMaster then Options9.RotMaster:SetValue("") end
            rotQueueLastAutoMaster=nil
          end
          if rotQueueEntry then
            local position=0
            for index,e in roster do if e.userId==LocalPlayer24.UserId then position=index; break end end
            rotQueueLabel:SetText(string.format("Queue: #%d | Master: %s | mine: %d/16",position,
              rotQueueOwner or "waiting",rotQueueEntry.progress))
            if not rotSupplier.safetyToken and not a1849.State.rotManualMenu and rotQueueCanRun() and not tbl365[1] and Library9.Toggles.RotBotEnabled then
              Library9.Toggles.RotBotEnabled:SetValue(true)
            end
          elseif owner then
            rotQueueLabel:SetText("Queue Master: "..owner.name.." | "..tostring(owner.progress or 0).."/16")
          end
        end
        local queueElapsed=0
        a1849.Maid:Give(v1342.Heartbeat:Connect(function(dt)
          queueElapsed+=dt
          if queueElapsed<0.5 then return end
          queueElapsed=0
          if a1849.State.bladeQueueTickBusy then return end
          a1849.State.bladeQueueTickBusy=true
          local ok,err=pcall(queueTick)
          a1849.State.bladeQueueTickBusy=false
          if not ok then
            rotSupplier.owner=nil
            rotQueueOwnerId=nil
            rotQueueLabel:SetText("Queue error: "..tostring(err))
          end
        end))
        a1849.Maid:Give(function() queueLeave("left") end)
        local rotPickupRetry=setmetatable({}, {__mode="k"})
        local function rotRefreshPlayers()
              local tbl372 = {}
              local flag79 = false
              table.clear(tbl369)
              for _, player in getResult26:GetPlayers() do
                if player ~= LocalPlayer24 then
                  table.insert(tbl372, player.Name)
                end
              end
              local seen={}
              for _,name in tbl372 do seen[name]=true end
              for name,on in pairs(Options9.RotAlts and Options9.RotAlts.Value or {}) do
                if on and type(name)=="string" and not seen[name] then
                  seen[name]=true;table.insert(tbl372,name)
                end
              end
              table.sort(tbl372)
              if #tbl372 ~= #tbl368 then
                flag79 = true
              else
                for k311, v1394 in tbl372 do
                  if tbl368[k311] ~= v1394 then
                    flag79 = true
                    break
                  end
                end
              end
              if flag79 then
                tbl368 = tbl372
                if Options9.RotAlts then
                  Options9.RotAlts:SetValues(tbl372)
                end
              end
        end
        local function rotCollectSelected()
          if not rotDelivery.closeDialogue() then
            rotWalkStatus:SetText("Walk: fechando a fala do Officer antes da proxima coleta")
            return false
          end
          if rotDelivery.pending and (rotDelivery.pending.jailed or rotDelivery.pending.dialogueSucceeded or not fn699()) then
            return rotDelivery.await(rotDelivery.pending)
          end
          if fn699() then return fn703("carried account") end
          local function activeMarker(character,name)
            local marker=character and character:FindFirstChild(name)
            if not marker then return false end
            if marker:IsA("BoolValue") then return marker.Value end
            if marker:IsA("ObjectValue") then return marker.Value~=nil end
            return true
          end
          local queuedUsers={}
          for _,entry in queueRoster() do queuedUsers[entry.userId]=true end
          local candidates={}
          for _,name in fn698() do
            local player=MResult.playerByName(name)
            local character=player and player.Character
            if player and player~=LocalPlayer24 and player.Parent and not queuedUsers[player.UserId] and rotTargetDown(character)
              and not activeMarker(character,"Carried") and not v1345:HasTag(character,"Jailed")
              and (rotPickupRetry[character] or 0)<=os.clock() then
              local distance=MResult.distanceTo(player)
              local automatic=a1849.State.blade23Enabled and a1849.State.blade23Enabled()
              if distance and (not automatic or distance<=30) then table.insert(candidates,{player=player,character=character,distance=distance}) end
            end
          end
          table.sort(candidates,function(a,b)
            if a.distance~=b.distance then return a.distance<b.distance end
            return a.player.UserId<b.player.UserId
          end)
          local candidate=candidates[1]
          if not candidate then
            -- Return to P14 to invite the next supplier only when no selected victim is already ready.
            if a1849.State.bladeRunAlts and a1849.State.bladeReceiverAtP14 then
              local root=sResult10.root()
              if root and Vector3.new(root.Position.X-rotSupplier.receiverPoint.X,0,root.Position.Z-rotSupplier.receiverPoint.Z).Magnitude>4 then
                rotWalkTo(function()
                  local current=sResult10.root()
                  return current and Vector3.new(rotSupplier.receiverPoint.X,current.Position.Y,rotSupplier.receiverPoint.Z) or nil
                end,function() return fn697() and not fn699() end,3)
                return
              end
            end
            rotWalkStatus:SetText("Walk: aguardando uma alt selecionada downada e livre")
            return
          end
          local player,character=candidate.player,candidate.character
          local deadline=os.clock()+35
          local function walkingAllowed()
            return fn697() and player.Parent~=nil and player.Character==character and rotTargetDown(character)
              and not activeMarker(character,"Carried") and not v1345:HasTag(character,"Jailed")
              and not fn699() and os.clock()<deadline
          end
          if candidate.distance>4 and walkingAllowed() then
            rotWalkStatus:SetText("Walk: aproximando da alt livre mais proxima: "..player.Name)
            rotWalkTo(function()
              local root=MResult.rootOf(player)
              return root and root.Position or nil
            end,walkingAllowed,3)
          end
          local distance=MResult.distanceTo(player)
          if walkingAllowed() and distance and distance<=4 and fn702(player) then
            rotPickupRetry[character]=nil
            rotWalkStatus:SetText("Walk: carrying; delivery only to Renova Bounty Officer")
            return fn703(player.Name)
          elseif fn697() and not fn699() then
            -- A blocked/broken target must not hold up every other eligible account.
            rotPickupRetry[character]=os.clock()+2
          end
        end
        -- Continue directly to the next ready victim; never overlap carrier workers.
        local function rotCollectBatch()
          for _=1,4 do
            if not fn697() or not fn670() or (rotQueueEntry and rotQueueEntry.progress>=16) then break end
            if rotCollectSelected()~=true then break end
            task.wait() -- one frame between confirmed transactions; recheck Stop/turn/goal above
          end
        end
        local rotWalkElapsed = 0
        local rotRefreshAt = 0
        local rotRetryAt = 0
        local Maid10 = a1849.Maid
        -- One worker owns refresh and collection together, including yielding executor/UI calls.
        Maid10:Give(v1342.Heartbeat:Connect(function(dt)
          rotWalkElapsed += dt
          if rotWalkElapsed < 0.05 or tbl367[1] then return end
          rotWalkElapsed = 0
          if rotWalkBusy or os.clock()<rotRetryAt then return end
          if not fn697() and os.clock()<rotRefreshAt then return end
          rotWalkBusy = true
          task.spawn(function()
            local ok, err = pcall(function()
              if os.clock()>=rotRefreshAt then
                rotRefreshAt=os.clock()+1
                rotRefreshPlayers()
              end
              if not fn697() then return end
              if not fn670() then
                rotWalkStatus:SetText("Walk: select the target account in Alts")
                return
              end
              rotCollectBatch()
            end)
            if not ok then rotRetryAt=os.clock()+1 end
            rotWalkBusy = false
            if not ok then
              local message="Rot Walk error: "..tostring(err)
              rotWalkStatus:SetText(message)
              if fn672(message) then warn("[Rot Walk] "..tostring(err)) end
            end
          end)
        end))
        rotSupplier.stop=function()
          if rotSupplier.cancelSafety then rotSupplier.cancelSafety() end
          rotSupplier.stopped=true
          qResult4.remove("rotbot_safety_stage")
          qResult4.remove("rotbot_active")
          qResult4.remove("rotbot_target")
          queueLeave("left")
          if Library9.Toggles.RotBotEnabled then Library9.Toggles.RotBotEnabled:SetValue(false) end
          rotSupplier.status:SetText("Rot Bot parado; retomada cancelada ate ativar novamente")
        end
        rotBotTab:AddLabel("Vitima: detecta qualquer jogador livre a ate 6 studs de P14. Funciona entre PCs no mesmo servidor; nao precisa anunciar Master.",true)
        rotBotTab:AddToggle("RotSupplierResume",{Text="Retomar fornecedor apos hop/rejoin",
          Default=rotSupplier.settings.resume~=false,Callback=function(value)
            rotSupplier.settings.resume=value
            rotSupplier.saveSettings()
            if not value then qResult4.remove("rotbot_active")
            elseif tbl365[1] and not fn670() then qResult4.set("rotbot_active","true"); DResult3.setupResume() end
          end})
        rotBotTab:AddSlider("RotProximity",{Text="ROT Proximity Check (0 desliga)",Default=tonumber(rotSupplier.settings.proximity) or 0,
          Min=0,Max=2000,Rounding=0,Suffix=" studs",Callback=function(value)
            rotSupplier.settings.proximity=value;rotSupplier.saveSettings()
          end})
        rotBotTab:AddToggle("RotSupplierRefreshLife",{Text="Perder vida se esperar muito por ROT",Default=rotSupplier.settings.refreshLife==true,
          Callback=function(value) rotSupplier.settings.refreshLife=value;rotSupplier.refreshSince=os.clock();rotSupplier.saveSettings() end})
        rotBotTab:AddSlider("RotSupplierRefreshSeconds",{Text="Espera antes de perder vida",Default=tonumber(rotSupplier.settings.refreshSeconds) or 120,
          Min=15,Max=600,Rounding=0,Suffix=" s",Callback=function(value) rotSupplier.settings.refreshSeconds=value;rotSupplier.saveSettings() end})
        rotBotTab:AddButton({Text="Perder 1 vida perto de P14 (vitima)",Func=function() rotSupplier.refreshLife(true) end})
        rotBotTab:AddButton({Text="Parar Rot Bot e cancelar retomada",Func=rotSupplier.stop})
        rotBotTab:AddLabel("Tecla para parar Rot Bot"):AddKeyPicker("RotSupplierStopKey",{
          Default=rotSupplier.settings.stopKey or "F8",Mode="Press",Modes={"Press"},Text="Parar Rot Bot",
          Callback=rotSupplier.stop,ChangedCallback=function() rotSupplier.saveSettings() end})
        rotBotTab:AddButton({Text="Iniciar Rot",Func=function()
          if a1849.State.progActive and a1849.State.progActive() or rotQueueEntry then
            fn672("Pare o Sigil e saia da fila de receptoras antes de iniciar uma fornecedora Rot")
            return
          end
          rotSupplier.explicitSupplier=true
          rotSupplier.routeStage=nil
          Library9.Toggles.RotBotEnabled:SetValue(true)
        end})
        rotHidden:AddToggle("RotBotEnabled", {
          Text = "Iniciar Rot",
          Tooltip = iResult6.blatant(),
          Default = false,
          Callback = function(a1865)
            if not a1865 then
              tbl365[1] = false
              qResult4.remove("rotbot_active")
              channelResult.clearCommand()
              fn696()
              return
            end
            if rotSupplier.safetyToken then
              Library9.Toggles.RotBotEnabled:SetValue(false)
              fn672("ROT pausado: use Play manual ou Parar para cancelar a espera")
              return
            end
            local BlatantMode2 = Library9.Toggles.BlatantMode
            if not (BlatantMode2 and BlatantMode2.Value) then
              Library9.Toggles.RotBotEnabled:SetValue(false)
              fn672("Enable Rot Bot requires Blatant Mode")
              return
            end
            if tbl365[1] then
              return
            end
            tbl365[1] = true
            rotSupplier.stopped=false
            rotSupplier.rejoining=false
            rotSupplier.safetyGraceUntil=os.clock()+5
            if not fn670() and Library9.Toggles.RotSupplierResume.Value then
              qResult4.set("rotbot_active","true")
              DResult3.setupResume()
              if not DResult3.canResume() then fn672("Retomada automatica precisa de queue_on_teleport no executor") end
            end
            if fn670() and (Options9.RotMaster and Options9.RotMaster.Value or "") ~= "" then
              fn672("Rot Bot: this account has alts picked, so it carries and ignores Master. Clear Alts on the accounts being carried")
            end
            if Library9.Toggles.ProximityNotifier then
              Library9.Toggles.ProximityNotifier:SetValue(true)
            end
            if Library9.Toggles.ProximityIgnoreAllies then
              Library9.Toggles.ProximityIgnoreAllies:SetValue(true)
            end
            if Library9.Options.ProximityDistance then
              Library9.Options.ProximityDistance:SetValue(1000)
            end
            rotSupplier.workerRunning=true
            task.spawn(function()
              if fn670() then
                fn672("Rot Bot: carrier walking mode; waiting for selected downed accounts")
                -- The Heartbeat collection loop handles walking, carry and jail.
                -- Do not run the alt's quest/menu/Tween preparation on the carrier.
                while tbl365[1] do task.wait(0.25) end
              else
                local ok,err=pcall(function()
                  if not rotSupplier.ensurePlaying() then
                    if not tbl365[1] then return end
                    error("Play nao gerou personagem em 60s")
                  end
                  fn695()
                end)
                if not ok then
                  rotSupplier.status:SetText("Fornecedor parou: "..tostring(err))
                  warn("[blade 23 Rot] "..tostring(err))
                end
              end
              tbl365[1] = false
              if not rotSupplier.rejoining then qResult4.remove("rotbot_active") end
              channelResult.clearCommand()
              pcall(fn696)
              rotSupplier.workerRunning=false
            end)
          end,
        })
        a1849.State.rotWorkerRunning=function() return rotSupplier.workerRunning or rotWalkBusy end
        rotSupplier.cancelSafety=function()
          if not rotSupplier.safetyToken then return end
          rotSupplier.safetyToken=nil
          a1849.State.rotManualMenu=nil
          a1849.State.bladeManualMenu=false
        end
        rotSupplier.proximityAlly=function(player)
          if player==LocalPlayer24 then return true end
          local state=a1849.State
          if state.bladeSafetyAlly and state.bladeSafetyAlly(player) then return true end
          if state.bladeLocalClients and state.bladeLocalClients.isAlly(player) then return true end
          if state.isFriend and state.isFriend(player) then return true end
          if state.isFriendly and state.isFriendly(player) then return true end
          local alts=state.bladeRunAlts or (Options9.RotAlts and Options9.RotAlts.Value) or {}
          return alts[player.Name]==true or alts[tostring(player.UserId)]==true or alts[player.UserId]==true
        end
        rotSupplier.proximityThreat=function()
          local range=tonumber(Options9.RotProximity and Options9.RotProximity.Value) or 0
          local root=sResult10.root()
          if range<=0 or not root then return nil end
          for _,player in getResult26:GetPlayers() do
            if not rotSupplier.proximityAlly(player) then
              local part=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
              if part and (part.Position-root.Position).Magnitude<=range then return player end
            end
          end
        end
        rotSupplier.pauseForProximity=function(reason)
          if rotSupplier.safetyToken or Library9.Unloaded then return end
          if a1849.State.progActive and a1849.State.progActive() and a1849.State.rotSafetyExit then
            a1849.State.rotSafetyExit(reason)
            return
          end
          local token={};rotSupplier.safetyToken=token
          local supplier=not fn670()
          local stay=a1849.State.bladeStayHere and a1849.State.bladeStayHere()
          if stay then a1849.State.rotManualMenu=true;a1849.State.bladeManualMenu=true end
          Library9.Toggles.RotBotEnabled:SetValue(false)
          task.spawn(function()
            local function active() return rotSupplier.safetyToken==token and not Library9.Unloaded and not rotSupplier.stopped end
            local ok,err=pcall(function()
              while active() and (rotSupplier.workerRunning or rotWalkBusy) do task.wait(0.1) end
              if not active() then return end
              if stay then
                rotSupplier.status:SetText("ROT: indo ao menu por proximidade; "..reason)
                if not vResult6.forceMenu(active) then return end
                rotSupplier.status:SetText("ROT: aguardando Play manual para retomar a etapa")
                repeat task.wait(0.25) until not active() or (not vResult6.startMenu() and sResult10.root())
                if not active() then return end
                rotSupplier.cancelSafety()
                rotSupplier.safetyGraceUntil=os.clock()+5
                Library9.Toggles.RotBotEnabled:SetValue(true)
              else
                if supplier then
                  qResult4.set("rotbot_safety_stage",rotSupplier.routeStage or "Santorini")
                  qResult4.set("rotbot_active","true")
                  DResult3.setupResume()
                  local prepared=DResult3.queueResume(true)
                  if not prepared then error("executor nao preparou a retomada ROT") end
                end
                DResult3.hop({reason=reason,strategy="smallest"})
              end
            end)
            if rotSupplier.safetyToken==token then
              rotSupplier.cancelSafety()
              if not ok then rotSupplier.status:SetText("ROT pausado: "..tostring(err)) end
            end
          end)
        end
        local rotSafety={elapsed=0,busy=false}
        a1849.Maid:Give(v1342.Heartbeat:Connect(function(dt)
          rotSafety.elapsed+=dt
          if rotSafety.elapsed<0.25 or rotSafety.busy then return end
          rotSafety.elapsed=0
          if not tbl365[1] or rotSupplier.safetyToken or a1849.State.bladeManualMenu or os.clock()<(rotSupplier.safetyGraceUntil or 0) then return end
          rotSafety.busy=true
          local ok,err=pcall(function()
            local threat=rotSupplier.proximityThreat()
            if threat and tbl365[1] and not rotSupplier.proximityAlly(threat) then
              rotSupplier.pauseForProximity("player "..threat.Name.." dentro do range ROT")
            end
          end)
          rotSafety.busy=false
          if not ok then rotSupplier.status:SetText("ROT proximity: "..tostring(err)) end
        end))
        a1849.Maid:Give(rotSupplier.cancelSafety)
        local netUI={busy=false,nextCheck=0,elapsed=0}
        netUI.box=a1849.Tabs.Blade23:AddRightGroupbox("Conexao facil")
        netUI.box:AddLabel("Para todas as contas no mesmo computador, use Tudo neste PC. Nao precisa de Python nem iniciar_servidor.bat. Os botoes de servidor/convite sao apenas para dois PCs.",true)
        netUI.status=netUI.box:AddLabel(MResult.net.config.mode=="Local files" and "Tudo neste PC | sem servidor" or "Dois PCs | configuracao salva",true)
        netUI.idle=function()
          return not tbl365[1] and not rotQueueEntry and not (a1849.State.progActive and a1849.State.progActive())
        end
        netUI.pretty=function(errorMessage)
          local message=tostring(errorMessage):gsub("^.-:%d+:%s*","")
          if message:find("HTTP 401",1,true) then return "Chave antiga ou incorreta. Use Servidor neste PC (dois PCs) ou um novo convite." end
          if message:find("server unreachable",1,true) then return "Sem resposta do servidor. Abra o iniciador no PC principal e confira endereco/rede." end
          return message
        end
        netUI.sync=function()
          local config=MResult.net.config
          Options9.Blade23Transport:SetValue(config.mode)
          Options9.Blade23ServerURL:SetValue(config.url)
          Options9.Blade23AccessKey:SetValue(config.token)
        end
        netUI.run=function(action)
          if netUI.busy then netUI.status:SetText("Aguarde a conexao em andamento..."); return end
          if not netUI.idle() then
            netUI.status:SetText("Pare a progressao, o Rot Bot e saia da fila para trocar a conexao.")
            return
          end
          netUI.busy=true
          netUI.status:SetText("Conectando e salvando automaticamente...")
          task.spawn(function()
            local ok,result=pcall(action)
            netUI.busy=false
            if ok then
              netUI.sync()
              netUI.nextCheck=os.clock()+10
              netUI.status:SetText(type(result)=="number" and ("Conectado ao Blade 23 | "..result.." ms | salvo neste PC") or tostring(result))
            else netUI.status:SetText(netUI.pretty(result)) end
          end)
        end
        a1849.State.bladeUseLocal=function()
          if netUI.busy then error("Aguarde a operacao em andamento",0) end
          local message=MResult.sharedUseLocal(netUI.idle)
          netUI.sync()
          netUI.status:SetText(message)
          return message
        end
        netUI.box:AddButton({Text="Tudo neste PC (sem servidor)",Func=function()
          local ok,message=pcall(a1849.State.bladeUseLocal)
          if not ok then netUI.status:SetText(netUI.pretty(message)) end
        end})
        netUI.box:AddButton({Text="Servidor neste PC (dois PCs)",Func=function()
          netUI.run(function() return MResult.sharedConnect(nil,true,netUI.idle) end)
        end})
        netUI.box:AddInput("Blade23Invite",{Text="Convite do PC principal",Default="",Placeholder="B23|http://...|XXXX-XXXX",Finished=false})
        netUI.box:AddButton({Text="Conectar convite",Func=function()
          local invitation=Options9.Blade23Invite.Value
          netUI.run(function() return MResult.sharedConnect(invitation,false,netUI.idle) end)
        end})
        netUI.box:AddToggle("Blade23Advanced",{Text="Mostrar configuracao manual",Default=false,Callback=function(value)
          if netUI.manual then netUI.manual:SetVisible(value) end
        end})
        netUI.manual=a1849.Tabs.Blade23:AddRightGroupbox("Configuracao manual")
        netUI.manual:AddDropdown("Blade23Transport",{Text="Modo",Values={"Local files","Remote HTTP"},Default=MResult.net.config.mode,Multi=false})
        netUI.manual:AddInput("Blade23ServerURL",{Text="Endereco do servidor",Default=MResult.net.config.url,
          Placeholder="http://192.168.1.10:8787",Finished=false})
        netUI.manual:AddInput("Blade23AccessKey",{Text="Chave avancada",Default=MResult.net.config.token,Finished=false})
        netUI.manual:AddButton({Text="Salvar e testar configuracao",Func=function()
          local candidate={mode=Options9.Blade23Transport.Value,url=Options9.Blade23ServerURL.Value,token=Options9.Blade23AccessKey.Value}
          netUI.run(function()
            candidate=MResult.sharedConfigValue(candidate)
            local elapsed=candidate.mode=="Remote HTTP" and MResult.sharedTest(candidate) or nil
            if not netUI.idle() then error("Pare os bots antes de aplicar a conexao.",0) end
            local ok,message=MResult.sharedConfigure(candidate)
            if not ok then error(message,0) end
            return elapsed or "Modo local salvo. As contas precisam compartilhar a pasta do executor."
          end)
        end})
        netUI.manual:SetVisible(false)
        netUI.box:SetVisible(false)
        netUI.sync()
        netUI.box:AddLabel("A conexao fica salva na pasta do executor. Instancias paradas que compartilham essa pasta recebem a configuracao automaticamente. Todas as contas devem estar no mesmo servidor do jogo.",true)
        -- Reuse settings on this PC, without changing a running farm or Rot queue.
        a1849.Maid:Give(v1342.Heartbeat:Connect(function(dt)
          netUI.elapsed+=dt
          if netUI.elapsed<2 or netUI.busy or not netUI.idle() then return end
          netUI.elapsed=0
          netUI.busy=true
          task.spawn(function()
            local ok,changed=pcall(MResult.sharedLoadSaved)
            if not ok then
              netUI.busy=false; netUI.status:SetText(netUI.pretty(changed)); return
            end
            if changed then netUI.sync(); netUI.nextCheck=0 end
            if changed then
              netUI.status:SetText(MResult.net.config.mode=="Local files" and "Tudo neste PC recebido da pasta do executor | sem servidor" or "Configuracao de dois PCs recebida da pasta do executor")
            end
            netUI.busy=false
          end)
        end))
        a1849.State.registerBot({
          name = "Rot Bot",
          running = function()
            return tbl365[1] == true or rotSupplier.safetyToken~=nil
          end,
          stop = function()
            rotSupplier.stop()
          end,
        })
        task.spawn(function()
          if qResult4.get("rotbot_active") ~= "true" then
            return
          end
          if not DResult3.claimResume({ "rotbot_active", "rotbot_target" }) then
            return
          end
          while not a1849.State.notificationsReady do
            if Library9.Unloaded or a1849.State.unloading then return end
            task.wait(0.25)
          end
          if Library9.Unloaded or a1849.State.unloading then return end
          local getResult27 = qResult4.get("rotbot_target")
          if getResult27 and getResult27 ~= "" and Options9.RotMaster then
            Options9.RotMaster:SetValue(getResult27)
          end
          local BlatantMode3 = Library9.Toggles.BlatantMode
          if BlatantMode3 and not BlatantMode3.Value then
            BlatantMode3:SetValue(true)
          end
          task.wait(2)
          if not Library9.Unloaded and not a1849.State.unloading and not rotSupplier.stopped
            and Library9.Toggles.RotSupplierResume.Value then
            rotSupplier.routeStage=qResult4.get("rotbot_safety_stage")
            qResult4.remove("rotbot_safety_stage")
            rotSupplier.explicitSupplier=true
            Library9.Toggles.RotBotEnabled:SetValue(true)
          end
        end)
      end
    end
    tbl44.N = function()
      local N = tbl44.cache.N
      if not N then
        N = { c = fn78() }
        tbl44.cache.N = N
      end
      return N.c
    end
    local fn81 = function()
      local Workspace3 = tbl44.a().Workspace
      local tbl376 = {
        list = {
          { label = "Castle Rock", trigger = "CastleRockSnake" },
          { label = "Deep Sunken", trigger = "evileye2" },
          { label = "Crypt of Kings", trigger = "CryptTrigger" },
          { label = "Temple of Fire", trigger = "MazeSnakes" },
        },
      }
      local tbl377 = {}
      for k319, v1440 in tbl376.list do
        tbl377[v1440.label] = v1440.trigger
      end
      tbl376.labels = function()
        local tbl378 = {}
        for k320, v1441 in tbl376.list do
          table.insert(tbl378, v1441.label)
        end
        return tbl378
      end
      tbl376.minutesSince = function(a1894)
        local v1442 = tbl377[a1894] or a1894
        local MonsterSpawns = Workspace3:FindFirstChild("MonsterSpawns")
        local v1443 = MonsterSpawns and MonsterSpawns:FindFirstChild("Triggers")
        local v1444 = v1443 and v1443:FindFirstChild(v1442)
        local v1445 = v1444 and v1444:FindFirstChild("LastSpawned")
        if not v1445 then
          return nil
        end
        return math.floor((os.time() - v1445.Value) / 60)
      end
      return tbl376
    end
    tbl44.Q = function()
      local Q = tbl44.cache.Q
      if not Q then
        Q = { c = fn81() }
        tbl44.cache.Q = Q
      end
      return Q.c
    end
    local fn86 = function()
      return function(a1962)
        local tbl435 = { [4556484] = "the Rogue Lineage group" }
        local tbl436 = { [281365] = true }
        local tbl437 = {}
        local tbl438 = {}
        local moderatorInfo = function(a1965)
          if tbl437[a1965.UserId] then
            return tbl437[a1965.UserId]
          end
          local moderatorIds = a1962.State.moderatorIds
          if moderatorIds and moderatorIds[a1965.UserId] then
            return "is a Moderator"
          end
          local moderatorGroups = a1962.State.moderatorGroups
          if moderatorGroups then
            for k362, v1616 in moderatorGroups do
              if not tbl436[v1616] then
                local ok146, result138 = pcall(function()
                  return a1965:IsInGroup(v1616)
                end)
                if ok146 and result138 then
                  local ok147, result139 = pcall(function()
                    return a1965:GetRoleInGroup(v1616)
                  end)
                  if ok147 and result139 ~= "Guest" then
                    return "is in " .. (tbl435[v1616] or "group " .. v1616) .. " [" .. result139 .. "]"
                  end
                end
              end
            end
          end
          return nil
        end
        local isModerator = function(a1966)
          return moderatorInfo(a1966) ~= nil
        end
        a1962.State.isModerator = isModerator
        a1962.State.moderatorInfo = moderatorInfo
        a1962.State.flagModerator = function(a1967, a2313)
          if not a1967 or tbl437[a1967.UserId] then
            return
          end
          tbl437[a1967.UserId] = a2313 or "is a Moderator"
          for k363, v1617 in tbl438 do
            task.spawn(v1617, a1967, tbl437[a1967.UserId])
          end
        end
        a1962.State.onModeratorFlagged = function(a1968)
          table.insert(tbl438, a1968)
          return function()
            local findResult3 = table.find(tbl438, a1968)
            if findResult3 then
              table.remove(tbl438, findResult3)
            end
          end
        end
      end
    end
    tbl44.V = function()
      local value=tbl44.cache.V
      if not value then value={c=fn86()};tbl44.cache.V=value end
      return value.c
    end
    local fn89 = function()
      local v2245=game.PlaceId==5208655184 or game.PlaceId==109732117428502
      local v2243=game.PlaceId==3541987450 or game.PlaceId==14341521240
      local fn1036 = function(a11192)
        local ok177, result165 = pcall(function()
          if v2245 then
            local getAttributeResult5 = a11192:GetAttribute("FirstName")
            if not getAttributeResult5 or getAttributeResult5 == "" then
              return "nil"
            end
            local getAttributeResult6 = a11192:GetAttribute("LastName")
            local getAttributeResult7 = a11192:GetAttribute("UberTitle")
            local v2247 = getAttributeResult6 and getAttributeResult6 ~= "" and getAttributeResult5 .. " " .. getAttributeResult6
              or getAttributeResult5
            return getAttributeResult7 and getAttributeResult7 ~= "" and v2247 .. ", " .. getAttributeResult7 or v2247
          end
          if not v2243 then
            return "nil"
          end
          local leaderstats4 = a11192:FindFirstChild("leaderstats")
          local v2248 = leaderstats4 and leaderstats4:FindFirstChild("FirstName")
          if not v2248 then
            return "nil"
          end
          local LastName2 = leaderstats4:FindFirstChild("LastName")
          local v2249 = LastName2 and LastName2.Value or ""
          local UberTitle2 = leaderstats4:FindFirstChild("UberTitle")
          local v2250 = UberTitle2 and UberTitle2.Value or ""
          local v2251 = v2249 ~= "" and v2248.Value .. " " .. v2249 or v2248.Value
          return v2250 ~= "" and v2251 .. ", " .. v2250 or v2251
        end)
        return ok177 and result165 or "Unknown"
      end
      local fn1037 = function(a11193)
        local ok178, result166 = pcall(function()
          if v2245 then
            return a11193:GetAttribute("FirstName")
          end
          if not v2243 then
            return nil
          end
          local leaderstats5 = a11193:FindFirstChild("leaderstats")
          local v2252 = leaderstats5 and leaderstats5:FindFirstChild("FirstName")
          return v2252 and v2252.Value or nil
        end)
        return ok178 and result166 or nil
      end
      return function(a11194)
        a11194.State.getRogueName=fn1036
        a11194.State.getFirstName=fn1037
        local iResult10=tbl44.i()
        local addTabResult=a11194.Tabs.Automation:AddLeftGroupbox("Bard e dialogos")
        addTabResult:AddToggle("AutoDialogue", {
          Text = "Auto Dialogue",
          Tooltip = iResult10.risky("skips through NPC dialogue"),
          Default = false,
          Callback = function(a11235)
            if a11235 and a11194.State.autoDialogueSetup then
              task.spawn(a11194.State.autoDialogueSetup)
            elseif not a11235 and a11194.State.autoDialogueTeardown then
              a11194.State.autoDialogueTeardown()
            end
          end,
        })
        iResult10.mark(a11194, "Risky", "AutoDialogue")
        addTabResult:AddToggle("AutoBard", {
          Text = "Auto Bard",
          Default = false,
          Callback = function(a11236)
            if a11236 and a11194.State.autoBardSetup then
              task.spawn(a11194.State.autoBardSetup)
            elseif not a11236 and a11194.State.autoBardClear then
              a11194.State.autoBardClear()
            end
          end,
        })
      end
    end
    tbl44.Y = function()
      local value=tbl44.cache.Y
      if not value then value={c=fn89()};tbl44.cache.Y=value end
      return value.c
    end
    local fn90 = function()
      local sResult14 = tbl44.s()
      local QResult3 = tbl44.Q()
      local DResult7 = tbl44.D()
      local vResult11 = tbl44.v()
      local qResult9 = tbl44.q()
      local aResult32 = tbl44.a()
      local eResult12 = tbl44.e()
      local iResult11 = tbl44.i()
      local tResult2 = tbl44.t()
      local dResult19 = tbl44.d()
      local cResult8 = tbl44.c()
      local kResult10 = tbl44.k()
      local getResult42, v2419, v2420, v2421, v2422, v2423, v2424, v2425, v2426 = aResult32:Get(
        "Players",
        "Workspace",
        "RunService",
        "UserInputService",
        "CollectionService",
        "ReplicatedStorage",
        "HttpService",
        "GuiService",
        "CoreGui"
      )
      local LocalPlayer33 = getResult42.LocalPlayer
      local FRIENDS = cResult8.BIN.."/friends_lite.json"
      if isfile and readfile and writefile and not isfile(FRIENDS) and isfile(cResult8.FRIENDS) then
        pcall(function() cResult8.ensureFor(FRIENDS);writefile(FRIENDS,readfile(cResult8.FRIENDS)) end)
      end
      local num692 = 1.5
      local fn1093 = function()
        local tbl569 = {}
        if isfile and isfile(FRIENDS) then
          pcall(function()
            local JSONDecodeResult, v2427, v2428 = v2424:JSONDecode(readfile(FRIENDS))
            for k551, v2429 in JSONDecodeResult, v2427, v2428 do
              tbl569[tonumber(k551)] = v2429
            end
          end)
        end
        return tbl569
      end
      local fn1094 = function(a11253)
        if not writefile then
          return
        end
        pcall(function()
          cResult8.ensureFor(FRIENDS)
          local saved={}
          for id,name in a11253 do saved[tostring(id)]=name end
          writefile(FRIENDS, v2424:JSONEncode(saved))
        end)
      end
      local fn1101 = function(a11259)
        local getAttributeResult10 = a11259:GetAttribute("LastName")
        if getAttributeResult10 and getAttributeResult10 ~= "" then
          return getAttributeResult10
        end
        local leaderstats11 = a11259:FindFirstChild("leaderstats")
        local v2435 = leaderstats11 and leaderstats11:FindFirstChild("LastName")
        return v2435 and v2435.Value or nil
      end
      return function(a11260)
        local __L6 = {}
        local Library17 = a11260.Library
        local Toggles16 = Library17.Toggles
        local Options17 = Library17.Options
        local Player = a11260.Tabs.Player
        local fn1102 = function()
          return LocalPlayer33.Character
        end
        local fn1103 = function()
          local PlayerGui32 = LocalPlayer33:FindFirstChildOfClass("PlayerGui")
          return PlayerGui32 and PlayerGui32:FindFirstChild("StatGui")
        end
        local res464 = fn1093()
        a11260.State.isFriendly = function(a11261)
          if not a11261 or a11261 == LocalPlayer33 then
            return false
          end
          if a11260.State.blade23Enabled and a11260.State.blade23Enabled() then return true end
          if Toggles16.IgnoreFriendly and Toggles16.IgnoreFriendly.Value then
            return false
          end
          if res464[a11261.UserId] then
            return true
          end
          if Toggles16.AutoFriendAlly and Toggles16.AutoFriendAlly.Value then
            local ok187, result174 = pcall(function()
              return LocalPlayer33:IsFriendsWith(a11261.UserId)
            end)
            if ok187 and result174 then
              return true
            end
          end
          if Toggles16.AutoHousemateAlly and Toggles16.AutoHousemateAlly.Value then
            local res468 = fn1101(LocalPlayer33)
            if res468 and res468 ~= "" and res468 == fn1101(a11261) then
              return true
            end
          end
          return false
        end
        local alliesUpdating=false
        local fn1104 = function()
          if a11260.State.blade23Enabled and a11260.State.blade23Enabled() then
            local changed=false
            for _,player in getResult42:GetPlayers() do
              if player~=LocalPlayer33 and res464[player.UserId]~=player.Name then
                res464[player.UserId]=player.Name;changed=true
              end
            end
            if changed then fn1094(res464) end
          end
          local tbl598 = {}
          for k557, v2455 in res464 do
            table.insert(tbl598, tostring(v2455))
          end
          table.sort(tbl598)
          if Options17.AllyList then
            Options17.AllyList:SetValues(tbl598)
          end
          if Options17.ServerAllies then
            alliesUpdating=true
            local values,selected,seen={},{},{}
            for id,name in res464 do
              local label=tostring(name).." ["..tostring(id).."]"
              table.insert(values,label);seen[label]=true;selected[label]=true
            end
            for _,player in getResult42:GetPlayers() do
              if player~=LocalPlayer33 then
                local label=player.Name.." ["..tostring(player.UserId).."]"
                if not seen[label] then table.insert(values,label);seen[label]=true end
              end
            end
            table.sort(values)
            Options17.ServerAllies:SetValues(values)
            Options17.ServerAllies:SetValue(selected)
            alliesUpdating=false
          end
        end
        local toggleFriend = function(a11262, a2392)
          if not a11262 or a11262 == LocalPlayer33 then
            return
          end
          if res464[a11262.UserId] then
            res464[a11262.UserId] = nil
            if not a2392 then
              Library17:Notify({ Title = "sentinel.bz", Description = "Removed friend: " .. a11262.Name })
            end
          else
            res464[a11262.UserId] = a11262.Name
            if not a2392 then
              Library17:Notify({ Title = "sentinel.bz", Description = "Added friend: " .. a11262.Name })
            end
          end
          fn1094(res464)
          fn1104()
        end
        a11260.State.bladeAddServerAllies=fn1104
        a11260.State.toggleFriend = toggleFriend
        a11260.State.isFriend = function(a11263)
          return a11263 ~= nil and res464[a11263.UserId] ~= nil
        end
        local getMouseResult3 = LocalPlayer33:GetMouse()
        local fn1105 = function()
          local Target2 = getMouseResult3.Target
          local v2456 = Target2 and Target2:FindFirstAncestorOfClass("Model")
          local v2457 = v2456 and getResult42:GetPlayerFromCharacter(v2456)
          if v2457 and v2457 ~= LocalPlayer33 then
            return v2457
          end
          local v2458 = v2419.CurrentCamera and v2419.CurrentCamera.CameraSubject
          local v2459 = v2458 and v2458.Parent
          local v2460 = v2459 and getResult42:GetPlayerFromCharacter(v2459)
          if v2460 and v2460 ~= LocalPlayer33 then
            return v2460
          end
          return nil
        end
        local addRightGroupboxResult23 = Player:AddRightGroupbox("Friends")
        addRightGroupboxResult23:AddLabel("Mark Friend"):AddKeyPicker("FriendKeybind", {
          Default = "None",
          Mode = "Press",
          Modes = { "Press" },
          Text = "Mark Friend",
          Callback = function()
            toggleFriend(fn1105(), true)
          end,
        })
        addRightGroupboxResult23:AddInput("AddFriend", {
          Text = "Add by Name",
          Placeholder = "username",
          Finished = true,
          Callback = function(a11264)
            if a11264 == "" then
              return
            end
            local v2461
            local getPlayersResult55, v2462, v2463 = getResult42:GetPlayers()
            for k558, v2464 in getPlayersResult55, v2462, v2463 do
              if v2464.Name:lower() == a11264:lower() or v2464.DisplayName:lower() == a11264:lower() then
                v2461 = v2464
                break
              end
            end
            if v2461 then
              toggleFriend(v2461)
            else
              Library17:Notify({ Title = "sentinel.bz", Description = "Player not found: " .. a11264 })
            end
            Options17.AddFriend:SetValue("")
          end,
        })
        addRightGroupboxResult23:AddDropdown("AllyList", { Text = "Allies", Values = {}, Default = nil, Multi = false, AllowNull = true })
        addRightGroupboxResult23:AddButton({
          Text = "Clear Friends",
          Func = function()
            table.clear(res464)
            fn1094(res464)
            fn1104()
            Library17:Notify({ Title = "sentinel.bz", Description = "Cleared friends" })
          end,
        })
        addRightGroupboxResult23:AddToggle(
          "IgnoreFriendly",
          { Text = "Ignore Friendly", Tooltip = "Treat everyone as an enemy", Default = false }
        )
        addRightGroupboxResult23:AddToggle("AutoFriendAlly", { Text = "Auto-Ally Roblox Friends", Default = false })
        addRightGroupboxResult23:AddToggle("AutoHousemateAlly", { Text = "Auto-Ally Housemates", Default = false })
        alliesUpdating=true -- AddDropdown may invoke its default callback during construction.
        local serverAllies=a11260.Tabs.Blade23:AddRightGroupbox("Aliados do servidor")
        serverAllies:AddDropdown("ServerAllies",{Text="Selecionar aliados (salvo por UserId)",Values={},Default={},Multi=true,AllowNull=true,Callback=function(selected)
          if alliesUpdating then return end
          table.clear(res464)
          for label,on in selected do
            if on then
              local name,id=label:match("^(.-) %[(%d+)%]$")
              id=tonumber(id)
              if id and id>0 then res464[id]=name end
            end
          end
          fn1094(res464);fn1104()
        end})
        serverAllies:AddLabel("Toda a aba e salva automaticamente por conta e tambem no Save Config. Aliados e alts offline continuam selecionados.",true)
        serverAllies:AddLabel("Contas com este Sentinel no mesmo PC e servidor sao reconhecidas automaticamente pela pasta compartilhada do executor, mesmo aguardando ou no menu.",true)
        serverAllies:AddButton({Text="Atualizar jogadores",Func=fn1104})
        a11260.Maid:Give(getResult42.PlayerAdded:Connect(fn1104))
        a11260.Maid:Give(getResult42.PlayerRemoving:Connect(function() task.defer(fn1104) end))
        fn1104()
        local addLeftGroupboxResult17 = Player:AddLeftGroupbox("Character")
        addLeftGroupboxResult17:AddToggle("AntiAfk", {
          Text = "Anti AFK",
          Default = false,
          Callback = function(a11265)
            if getconnections then
              pcall(function()
                local getconnectionsResult, v2465, v2466 = getconnections(LocalPlayer33.Idled)
                for k559, v2467 in getconnectionsResult, v2465, v2466 do
                  if a11265 then
                    v2467:Disable()
                  else
                    v2467:Enable()
                  end
                end
              end)
              return
            end
            if a11265 then
              Library17:Notify({ Title = "sentinel.bz", Description = "Anti AFK needs getconnections (unsupported executor)" })
            end
          end,
        })
        a11260.Maid:Give(function()
          if not getconnections then
            return
          end
          pcall(function()
            local getconnectionsResult2, v2468, v2469 = getconnections(LocalPlayer33.Idled)
            for k560, v2470 in getconnectionsResult2, v2468, v2469 do
              v2470:Enable()
            end
          end)
        end)
        Toggles16.AntiAfk:SetValue(true)
        local v2436
        local Maid18 = a11260.Maid
        Maid18:Give(LocalPlayer33.CharacterAdded:Connect(function()
          v2436 = nil
        end))
        local fn1108 = function()
          if not (v2436 and v2436.Parent) then
            v2436 = eResult12.getRemote("ApplyFallDamage") or eResult12.getRemote("FallDamage")
          end
          return v2436
        end
        a11260.State.fireFall = function(a11271, a2393)
          local res469 = fn1108()
          if not res469 then
            return false
          end
          a11260.State.fallDamageBypassUntil = tick() + 0.5
          local Character181 = LocalPlayer33.Character
          local v2475 = Character181 and Character181:FindFirstChildOfClass("Humanoid")
          local v2476 = Character181 and Character181:FindFirstChild("HumanoidRootPart")
          local v2477 = v2475 and v2475.Health
          local v2478 = getthreadidentity and getthreadidentity() or "?"
          local v2479 = checkcaller and checkcaller()
          local v2480 = v2475 and v2475:GetState() and v2475:GetState().Name
          local v2481 = v2476 and v2476.CanCollide
          local v2482 = v2476 and math.floor(v2476.AssemblyLinearVelocity.Magnitude)
          pcall(function()
            if game.PlaceId == 3541987450 then
              res469:FireServer({ 205 + math.random() * 9 }, {})
            else
              res469:FireServer({ math.random(), a11271 }, {})
            end
          end)
          return true
        end
      end
    end
    tbl44.Z = function()
      local value=tbl44.cache.Z
      if not value then value={c=fn90()};tbl44.cache.Z=value end
      return value.c
    end
    local fn97 = function()
      local DResult8 = tbl44.D()
      local qResult11 = tbl44.q()
      local aResult38 = tbl44.a()
      local eResult15 = tbl44.e()
      local xResult6 = tbl44.x()
      local dResult24 = tbl44.d()
      local cResult11 = tbl44.c()
      local LocalPlayer38 = aResult38.Players.LocalPlayer
      local tbl708={}
      local fn1383 = function(a11523)
        return "ArtifactPing" .. tostring(a11523):gsub("[^%w]", "")
      end
      local fn1384 = function(a11524)
        local tbl710 = {}
        local gmatchResult14, v3189, v3190 = tostring(a11524 or ""):gmatch("[^%s,]+")
        for k778 in gmatchResult14, v3189, v3190 do
          if k778:match("^%d+$") then
            table.insert(tbl710, "<@&" .. k778 .. ">")
          end
          if k778 == "@everyone" or k778 == "@here" or k778:match("^<@[&!]?%d+>$") then
            table.insert(tbl710, k778)
          end
          if k778 == "everyone" or k778 == "here" then
            table.insert(tbl710, "@" .. k778)
          end
        end
        return table.concat(tbl710, " ")
      end
      local fn1385 = function(a11525)
        return tostring(a11525):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
      end
      return function(a11542)
        local Library23 = a11542.Library
        local SaveManager = a11542.SaveManager
        local ThemeManager = a11542.ThemeManager
        local Settings = a11542.Tabs.Settings
        local v3227 = a11542.State and a11542.State.blatant or {}
        local v3228 = a11542.State and a11542.State.risky or {}
        local fn1400 = function(a11543, a2475)
          for k795, v3240 in a11543 do
            local item136 = Library23.Toggles[v3240]
            if item136 then
              if a2475 then
                item136:SetDisabled(false)
              else
                if item136.Value then
                  item136:SetValue(false)
                end
                item136:SetDisabled(true)
              end
            end
          end
        end
        local fn1401 = function(a11544)
          fn1400(v3227, a11544)
        end
        local Callback14 = function(a11545)
          fn1400(v3228, a11545)
        end
        local addLeftGroupboxResult19 = Settings:AddLeftGroupbox("Menu")
        addLeftGroupboxResult19:AddToggle("BlatantMode", {
          Text = "Blatant Mode",
          Default = false,
          Callback = function(a11546)
            fn1401(a11546)
            qResult11.set("blatant", a11546 and "true" or "false")
          end,
        })
        addLeftGroupboxResult19:AddToggle("RiskyMode",{Text="Risky Mode",Default=false,Callback=Callback14})
        addLeftGroupboxResult19:AddToggle("Notifications",{Text="Notifications",Default=true})
        addLeftGroupboxResult19:AddToggle("PersistentConfigs", {
          Text = "Persistent Configs",
          Tooltip = "Keeps your config after a hop",
          Default = true,
          Callback = function(a11564)
            if not a11564 then
              qResult11.remove("loaded_config")
            end
          end,
        })
        DResult8.setupResume()
        a11542.Maid:Give(DResult8.teardown)
        addLeftGroupboxResult19:AddToggle("ExecuteOnServerhop", {
          Text = "Execute on Serverhop",
          Tooltip = "Reruns sentinel after a hop",
          Default = false,
          Callback = function(a11565)
            qResult11.set("execute_on_serverhop", a11565 and "true" or "false")
            if a11565 then
              DResult8.setupResume()
            end
          end,
        })
        local legacyKeybinds=cResult11.CACHE.."/keybinds.json"
        if isfile and readfile and writefile and not isfile(cResult11.KEYBINDS) and isfile(legacyKeybinds) then
          pcall(function() cResult11.ensureFor(cResult11.KEYBINDS);writefile(cResult11.KEYBINDS,readfile(legacyKeybinds)) end)
        end
        local fn1410 = function()
          if not (isfile and readfile) or not isfile(cResult11.KEYBINDS) then
            return {}
          end
          local ok236, result220 = pcall(function()
            local HttpService8 = aResult38.HttpService
            return HttpService8:JSONDecode(readfile(cResult11.KEYBINDS))
          end)
          return ok236 and type(result220) == "table" and result220 or {}
        end
        local fn1411 = function(a11566, a2477)
          if not writefile then
            return
          end
          local res645 = fn1410()
          res645[a11566] = a2477
          cResult11.ensureFor(cResult11.KEYBINDS)
          pcall(function()
            writefile(cResult11.KEYBINDS, aResult38.HttpService:JSONEncode(res645))
          end)
        end
        addLeftGroupboxResult19:AddLabel("Menu Keybind"):AddKeyPicker("MenuKeybind", {
          Default = "RightControl",
          Text = "Menu",
          ChangedCallback = function(a11567, a2478)
            Library23.ToggleKeybind = a2478
            fn1411("MenuKeybind", a11567)
          end,
        })
        a11542.State.restoreMenuKeybind = function()
          local MenuKeybind = fn1410().MenuKeybind
          if type(MenuKeybind) == "string" and MenuKeybind ~= "" and Library23.Options.MenuKeybind then
            Library23.Options.MenuKeybind:SetValue(MenuKeybind)
          end
        end
        a11542.State.restoreMenuKeybind()
        addLeftGroupboxResult19:AddLabel("Unload Keybind"):AddKeyPicker("UnloadKeybind", {
          Default = "End",
          Mode = "Press", Modes = {"Press"},
          Text = "Unload",
          Callback = function()
            if Library23.Unloaded or Library23.UnloadQueued then return end
            Library23.UnloadQueued=true
            task.defer(function() Library23:Unload() end)
          end,
        })
        addLeftGroupboxResult19:AddButton({
          Text = "Unload",
          Func = function()
            Library23:Unload()
          end,
        })
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
        local Callback16 = function()
          local Value17 = Library23.Options.WebhookUrl.Value
          local Value18 = Library23.Options.WebhookUsername.Value
          local Value19 = Library23.Toggles.WebhookShowUsername.Value
          local WebhookPrefix = Library23.Options.WebhookPrefix
          local v3305 = WebhookPrefix and WebhookPrefix.Value or ""
          local WebhookAlertPing = Library23.Options.WebhookAlertPing
          local v3306 = WebhookAlertPing and WebhookAlertPing.Value or "@everyone"
          xResult6.setConfig({
            url = Value17,
            username = Value18,
            showUsername = Value19,
            prefix = v3305,
            alertPing = v3306 ~= "@everyone" and fn1384(v3306) or false,
          })
          local artifact_pings = {}
          for k814, v3307 in tbl708 do
            local item140 = Library23.Options[fn1383(v3307)]
            if item140 then
              artifact_pings[v3307] = item140.Value
            end
          end
          qResult11.setJSON("shared_settings", {
            webhook = Value17,
            webhook_username = Value18,
            webhook_show_username = Value19,
            webhook_prefix = v3305,
            webhook_alert_ping = v3306,
            artifact_pings = artifact_pings,
          })
        end
        a11542.State.Webhook = xResult6
        a11542.State.MemStore = qResult11
        local addRightGroupboxResult28 = Settings:AddRightGroupbox("Webhook")
        addRightGroupboxResult28:AddInput("WebhookUrl", {
          Text = "Discord Webhook URL",
          Placeholder = "https://discord.com/api/webhooks/...",
          Finished = true,
          Callback = function(a11583)
            if
              a11583 ~= ""
              and not a11583:match("^https://discord%.com/api/webhooks/%d+/%S+$")
              and not a11583:match("^https://discordapp%.com/api/webhooks/%d+/%S+$")
            then
              Library23:Notify({ Title = "sentinel.bz", Description = "That doesn't look like a Discord webhook URL" })
            end
            Callback16()
          end,
        })
        addRightGroupboxResult28:AddInput(
          "WebhookUsername",
          { Text = "Webhook Username", Default = "sentinel", Finished = true, Callback = Callback16 }
        )
        addRightGroupboxResult28:AddInput("WebhookPrefix", {
          Text = "Custom Message",
          Tooltip = "Pings or text above every webhook",
          Default = "",
          Placeholder = "<@&123456789> heads up",
          Finished = true,
          Callback = Callback16,
        })
        addRightGroupboxResult28:AddButton({
          Text = "Test Webhook",
          Func = function()
            Callback16()
            if not xResult6.available() then
              Library23:Notify({
                Title = "sentinel.bz",
                Description = "Set a webhook URL first (and your executor needs http_request)",
              })
              return
            end
            if xResult6.text("Test message from sentinel.bz") then
              Library23:Notify({ Title = "sentinel.bz", Description = "Webhook sent" })
            else
              Library23:Notify({ Title = "sentinel.bz", Description = "Webhook send failed" })
            end
          end,
        })
        addRightGroupboxResult28:AddToggle("WebhookShowUsername", { Text = "Show My Username", Default = true, Callback = Callback16 })
        addRightGroupboxResult28:AddInput("WebhookAlertPing",{Text="Bot Alerts",Default="@everyone",Finished=true,Callback=Callback16})
        a11542.State.syncWebhook=Callback16
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
        Library23:SetKeybindFrameVisible(false)
        fn1401(Library23.Toggles.BlatantMode.Value)
        Callback14(Library23.Toggles.RiskyMode.Value)
        ThemeManager:SetLibrary(Library23)
        ThemeManager:SetFolder("sentinel/blade23_lite")
        ThemeManager.BuiltInThemes.Sentinel = {
          0,
          {
            FontColor = "c8c8c8",
            MainColor = "262626",
            AccentColor = "c32148",
            BackgroundColor = "141414",
            OutlineColor = "383838",
          },
        }
        ThemeManager.DefaultTheme = "Sentinel"
        ThemeManager:ApplyToGroupbox(Settings:AddLeftGroupbox("Themes"))
        SaveManager:SetLibrary(Library23)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetFolder("sentinel/blade23_lite")
        local tbl732 = {
          "SavedPaths",
          "LoopJoin",
          "BotCustomFPS",
          "BotFPS",
          "StayInServer",
          "CastleStayInServer",
          "GripBotEnabled",
          "GripTargets",
          "GripMaster",
        }
        for i135 = 1, 12 do
          table.insert(tbl732, "MacroTrigger" .. i135)
        end
        SaveManager:SetIgnoreIndexes(tbl732)
        -- Blade preferences contain configuration only; progression saves and worker state stay separate.
        local liteEssentials={AntiAfk=true,BlatantMode=true,RiskyMode=true,Notifications=true,PersistentConfigs=true,
          ExecuteOnServerhop=true,MenuKeybind=true,UnloadKeybind=true,LiteThrottle=true,LiteFocusedFps=true,
          LiteBackgroundFps=true,LiteHideBackground=true,WebhookUrl=true,WebhookUsername=true,
          WebhookShowUsername=true,WebhookPrefix=true,WebhookAlertPing=true}
        local bladePrefs={file="sentinel/.cache/blade23_lite_settings_"..tostring(game:GetService("Players").LocalPlayer.UserId)..".json",elapsed=0,last=nil,ready=false,failed=false}
        bladePrefs.controls=function()
          local controls={}
          local tab=a11542.Tabs.Blade23
          if not tab or not tab.Container then return controls end
          for _,collection in {Library23.Toggles,Library23.Options} do
            for key,control in collection do
              local instance=control.ConfigInstance
              if key~="RotBotEnabled" and key~="RotReceiverQueue" and SaveManager.Parser[control.Type]
                and instance and (instance:IsDescendantOf(tab.Container) or liteEssentials[key]) then controls[key]=control end
            end
          end
          return controls
        end
        bladePrefs.snapshot=function()
          local objects={}
          for key,control in bladePrefs.controls() do
            table.insert(objects,SaveManager.Parser[control.Type].Save(key,control))
          end
          table.sort(objects,function(a,b) return a.idx<b.idx end)
          return {version=1,objects=objects}
        end
        bladePrefs.save=function()
          if not bladePrefs.ready or a11542.State.loadingConfig then return false,"configuracao ainda carregando" end
          if bladePrefs.saving then return false,"gravacao em andamento" end
          bladePrefs.saving=true
          local ok,err=pcall(function()
            local encoded=game:GetService("HttpService"):JSONEncode(bladePrefs.snapshot())
            if encoded==bladePrefs.last then return end
            if not writefile then error("executor sem writefile") end
            if makefolder and isfolder then
              if not isfolder("sentinel") then makefolder("sentinel") end
              if not isfolder("sentinel/.cache") then makefolder("sentinel/.cache") end
            end
            local saved,why=SaveManager:WriteConfig(bladePrefs.file,encoded)
            if not saved then error(why,0) end
            bladePrefs.last=encoded
          end)
          bladePrefs.saving=false
          if not ok and not bladePrefs.failed then warn("[blade 23] Nao foi possivel salvar configuracoes: "..tostring(err)) end
          bladePrefs.failed=not ok
          if not ok then return false,tostring(err) end
          return true
        end
        bladePrefs.flush=function()
          local deadline=os.clock()+5
          while bladePrefs.saving and os.clock()<deadline do task.wait(0.05) end
          if bladePrefs.saving then return false,"gravacao anterior ainda pendente" end
          return bladePrefs.save()
        end
        bladePrefs.restore=function()
          local data,path=SaveManager:ReadConfig(bladePrefs.file,1)
          if not data then
            if isfile and isfile(bladePrefs.file) then warn("[blade 23] Configuracao automatica invalida; arquivo preservado") end
            return false
          end
          if path~=bladePrefs.file then warn("[blade 23] Configuracao recuperada da copia de seguranca") end
          local controls=bladePrefs.controls()
          local wasLoading=a11542.State.loadingConfig
          a11542.State.loadingConfig=true
          for _,saved in data.objects do
            if Library23.Unloaded then a11542.State.loadingConfig=wasLoading;return false end
            local control=type(saved)=="table" and controls[saved.idx]
            if control and control.Type==saved.type then
              local loaded,err=pcall(SaveManager.Parser[saved.type].Load,saved.idx,saved)
              if not loaded then warn("[blade 23] Configuracao "..tostring(saved.idx)..": "..tostring(err)) end
            end
          end
          a11542.State.loadingConfig=wasLoading
          a11542.State.bladeProfileLoaded=true
          return true
        end
        local function allowBladeProfileSettings()
          local tab=a11542.Tabs.Blade23
          if not tab or not tab.Container then return end
          for _,collection in {Library23.Toggles,Library23.Options} do
            for key,control in collection do
              local instance=control.ConfigInstance
              if instance and instance:IsDescendantOf(tab.Container) then SaveManager.Ignore[key]=nil end
            end
          end
          -- Start/stop buttons use hidden operational toggles, not profile settings.
          SaveManager.Ignore.RotBotEnabled=true
          SaveManager.Ignore.RotReceiverQueue=true
        end
        allowBladeProfileSettings()
        local Save = SaveManager.Save
        SaveManager.Save = function(self,name)
          if a11542.State.loadingConfig then return false,"aguarde o carregamento da configuracao" end
          local ok,saved,why=pcall(Save,self,name)
          if not ok then return false,tostring(saved) end
          if not saved then return false,why end
          if bladePrefs.ready then return bladePrefs.flush() end
          return true
        end
        local Load = SaveManager.Load
        SaveManager.Load = function(a11595, a2482)
          if a11542.State.loadingConfig then return false,"outra configuracao ainda esta carregando" end
          a11542.State.loadingConfig = true
          local loaded,res651,v3324 = pcall(Load,a11595,a2482)
          a11542.State.loadingConfig = false
          if not loaded then return false,tostring(res651) end
          if Library23.Unloaded then return false,"script encerrado" end
          if res651 then a11542.State.bladeProfileLoaded=true end
          if a11542.State.restoreMenuKeybind then
            a11542.State.restoreMenuKeybind()
          end
          fn1401(Library23.Toggles.BlatantMode.Value)
          Callback14(Library23.Toggles.RiskyMode.Value)
          qResult11.set("blatant", Library23.Toggles.BlatantMode.Value and "true" or "false")
          if a11542.State.reapplyCustomization then
            pcall(a11542.State.reapplyCustomization)
          end
          if a11542.State.refreshCharLists then
            pcall(a11542.State.refreshCharLists)
          end
          if a11542.State.tickNewDetections then
            pcall(a11542.State.tickNewDetections)
          end
          if res651 and a2482 and Library23.Toggles.PersistentConfigs and Library23.Toggles.PersistentConfigs.Value then
            qResult11.set("loaded_config", a2482)
          end
          if res651 and bladePrefs.ready then
            local saved,why=bladePrefs.flush()
            if not saved then return false,why end
          end
          return res651, v3324
        end
        a11542.Maid:Give(function()
          qResult11.remove("loaded_config")
        end)
        SaveManager:BuildConfigSection(Settings, Settings:AddRightGroupbox("Configuration"))
        local cond50 = qResult11.get("execute_on_serverhop") == "true"
        local getResult53 = qResult11.get("loaded_config")
        local flag162 = false
        if getResult53 and getResult53 ~= "" then
          flag162 = SaveManager:Load(getResult53) == true
        end
        if not flag162 then
          SaveManager:LoadAutoloadConfig()
          if a11542.State.reapplyCustomization then
            pcall(a11542.State.reapplyCustomization)
          end
          if a11542.State.refreshCharLists then
            pcall(a11542.State.refreshCharLists)
          end
        end
        local legacyPrefs="sentinel/.cache/blade23_settings_"..tostring(game:GetService("Players").LocalPlayer.UserId)..".json"
        if isfile and not isfile(bladePrefs.file) then
          local data=SaveManager:ReadConfig(legacyPrefs,1)
          if data then
            pcall(function() SaveManager:WriteConfig(bladePrefs.file,game:GetService("HttpService"):JSONEncode(data)) end)
          end
        end
        bladePrefs.restore()
        bladePrefs.ready=true
        a11542.State.flushBladeSettings=bladePrefs.flush
        DResult8.beforeResume=bladePrefs.flush
        a11542.Maid:Give(game:GetService("RunService").Heartbeat:Connect(function(dt)
          if a11542.State.unloading or Library23.Unloaded then return end
          bladePrefs.elapsed+=dt
          if bladePrefs.elapsed<1 then return end
          bladePrefs.elapsed=0
          bladePrefs.save()
        end))
        a11542.Maid:Give(function()
          bladePrefs.ready=false
          a11542.State.flushBladeSettings=nil
          DResult8.beforeResume=nil
        end)
        if a11542.State.tickNewDetections then
          pcall(a11542.State.tickNewDetections)
        end
        a11542.State.notificationsReady = true
        if a11542.State.onNotificationsReady then
          a11542.State.onNotificationsReady()
        end
        if flag162 then
          Library23:Notify({ Title = "sentinel.bz", Description = "Restored config: " .. getResult53 })
        end
        if cond50 and Library23.Toggles.ExecuteOnServerhop then
          Library23.Toggles.ExecuteOnServerhop:SetValue(true)
        end
        if qResult11.get("bind_backpack_tools") == "true" and Library23.Toggles.BindBackpackTools then
          Library23.Toggles.BindBackpackTools:SetValue(true)
        end
        if Library23.Options.WebhookUrl.Value == "" then
          local getJSONResult10 = qResult11.getJSON("shared_settings")
          if getJSONResult10 and type(getJSONResult10.webhook) == "string" and getJSONResult10.webhook ~= "" then
            Library23.Options.WebhookUrl:SetValue(getJSONResult10.webhook)
            if type(getJSONResult10.webhook_username) == "string" then
              Library23.Options.WebhookUsername:SetValue(getJSONResult10.webhook_username)
            end
            if getJSONResult10.webhook_show_username ~= nil then
              local WebhookShowUsername = Library23.Toggles.WebhookShowUsername
              WebhookShowUsername:SetValue(getJSONResult10.webhook_show_username == true)
            end
            if type(getJSONResult10.webhook_prefix) == "string" then
              Library23.Options.WebhookPrefix:SetValue(getJSONResult10.webhook_prefix)
            end
            if type(getJSONResult10.webhook_alert_ping) == "string" and Library23.Options.WebhookAlertPing then
              Library23.Options.WebhookAlertPing:SetValue(getJSONResult10.webhook_alert_ping)
            end
            for k794, v3239 in type(getJSONResult10.artifact_pings) == "table" and getJSONResult10.artifact_pings or {} do
              local item135 = Library23.Options[fn1383(k794)]
              if item135 and type(v3239) == "string" then
                item135:SetValue(v3239)
              end
            end
          end
        end
        if a11542.State.syncWebhook then
          a11542.State.syncWebhook()
        end
      end
    end
    tbl44.af = function()
      local value=tbl44.cache.af
      if not value then value={c=fn97()};tbl44.cache.af=value end
      return value.c
    end
    loadstring(
      "\r\n\tif not BASIL_OBFUSCATED then BASIL_OBFUSCATED = false end\r\n\tif not BASIL_NO_VIRTUALIZE then function BASIL_NO_VIRTUALIZE(f) return f end end\r\n"
    )()
    local aResult = tbl44.a()
    local bResult = tbl44.b()
    local cResult = tbl44.c()
    local dResult = tbl44.d()
    local Players = aResult.Players
    if not ({ [1087859240] = true, [6281940032] = true })[game.GameId] then
      return
    end
    if not game:IsLoaded() then
      game.Loaded:Wait()
    end
    while true do
      task.wait()
      if Players.LocalPlayer then
        break
      end
    end
    -- The interface must also load at the game's Play menu, before a Backpack exists.
    local res42 = (function(a11596, a2483)
      local v3325 = a2483 or 27
      if not (bit32 and bit32.bxor) then
        return a11596
      end
      local tbl741 = {}
      for i137 = 1, #a11596 do
        tbl741[i137] = string.char(bit32.bxor(string.byte(a11596, i137), v3325 + i137 % 7))
      end
      return table.concat(tbl741)
    end)(
      tostring(game.PlaceId)
        .. "_"
        .. tostring(game.JobId):sub(1, 5)
        .. "_"
        .. tostring(Players.LocalPlayer and Players.LocalPlayer.UserId or 0):sub(-4)
    )
    -- The session gate above owns deduplication. Old per-job flags can survive a failed rejoin.
    __bootSession.guardKey=res42
    getgenv()[res42]=__bootSession
    local flag11 = false
    local tbl45 = {}
    for k22, v106 in
      {
        gaia_hashes = {
          "3a3d31ed3c50b4b9568ec706bb433fb52caea868e49a2fd534008cf50cff2fea1f44c65d18e728ad1c1bb2d36361580e",
          "767c88a596568fc19c4d9c9ae34f1872c875d1f9f6e5d9f4bcfa7e01407f9d79e485427ca33a563dca1d51e3564e3c12",
        },
        khei_hashes = {
          "ad4c2df7e28fbe930c713ae26d97331eff5d24e843bfcb14fe4b4c125ceffa43e122a5ea616df7f5fcf2561da02f3033",
        },
        other_hashes = {
          "a2615f3e2d64f29caadcf57cbd7c79f30d37c8b8545e7d368e39458cba7b77d8bb0f9bac73b856d81dfeb42b61e455ad",
        },
      }
    do
      for k23, v107 in v106 do
        tbl45[v107] = true
      end
    end
    local fn98 = function()
      if identifyexecutor then
        local ok238, result222 = pcall(identifyexecutor)
        if ok238 and result222 then
          return result222
        end
      end
      if getexecutorname then
        local ok239, result223 = pcall(getexecutorname)
        if ok239 and result223 then
          return result223
        end
      end
      return "unknown"
    end
    local fn99 = function()
      local v3326 = getscripthash or get_script_hash
      if not v3326 then
        return nil
      end
      local ok240, result224 = pcall(function()
        return game:GetService("ReplicatedStorage").Assets.Modules.KeyHandler
      end)
      if not ok240 or typeof(result224) ~= "Instance" then
        return nil
      end
      local ok241, result225 = pcall(v3326, result224)
      if ok241 and type(result225) == "string" then
        return result225:lower()
      end
      return nil
    end
    local ok46, result50 = xpcall(function()
      if flag11 then
        local res652 = fn99()
        if res652 and not tbl45[res652] then
          if getgenv()[res42]==__bootSession then getgenv()[res42]=nil end
          warn(
            string.format(
              "[sentinel] hash unrecognised - contact support and send this information | executor=%s placeid=%s placeversion=%s hash=%s",
              fn98(),
              tostring(game.PlaceId),
              tostring(game.PlaceVersion),
              res652
            )
          )
          return
        end
      end
      pcall(function()
        tbl44.e().preloadKeyHandler()
      end)
      __bootMark("core-hooks")
      tbl44.f()("Normal")
      local str149 = "https://git.fable.bz/zyu/sentinel-ui/raw/branch/main/"
      local str150 = "https://stella.heroinhound.cc/stella.lua"
      local tbl742 = {}
      local num774 = 0
      local fn1431 = function(a11597, a2484)
        do return end
        num774 += 1
        task.spawn(function()
          local ok242, result226 = pcall(game.HttpGet, game, a2484)
          tbl742[a11597] = ok242 and type(result226) == "string" and result226 ~= "" and result226 or nil
          num774 -= 1
        end)
      end
      local num775 = 0
      while true do
        if not (num774 > 0 and num775 < 25) then
          break
        end
        num775 += task.wait()
      end
      getgenv().stella_debug = false
      pcall(function()
      end)
      local fn1432 = function(a11598, a2485)
        return __UI_FILES[a11598] or ""
      end
      __bootMark("interface")
      local res653 = loadstring(fn1432("lib", "Library.lua"))()
      __bootSession.library=res653
      local res654 = loadstring(fn1432("theme", "dependencies/ThemeManager.lua"))()
      local res655 = loadstring(fn1432("save", "dependencies/SaveManager.lua"))()
      local newResult107 = dResult.new()
      local flag165 = false
      __bootSession.cleanup=function()
        flag165=true
        pcall(function() newResult107:DoCleaning() end)
        if __bootSession.coreCleanup then pcall(__bootSession.coreCleanup);__bootSession.coreCleanup=nil end
      end
      res653:OnUnload(__bootSession.cleanup)
      res653.AfterUnload=function()
        __bootSession.cancelled=true;__bootSession.executing=false;__bootSession.state="unloaded"
        if getgenv()[res42]==__bootSession then getgenv()[res42]=nil end
        __bootSession.library=nil
        if __bootEnv.__BLADE23_SESSION==__bootSession then __bootEnv.__BLADE23_SESSION=nil end
        __bootMark("unloaded")
      end
      local CreateWindowResult = res653:CreateWindow({
        Title = "Blade 23 Lite - teste",
        Center = true,
        ShowCustomCursor = false,
        NotifySide = "Left",
        ToggleKeybind = Enum.KeyCode.RightControl,
      })
      local tbl743 = {
        Library = res653,
        SaveManager = res655,
        ThemeManager = res654,
        Maid = newResult107,
        State = {},
        Tabs = {
          Blade23 = CreateWindowResult:AddTab("blade 23"),
          World = CreateWindowResult:AddTab("Protecoes"),
          Automation = CreateWindowResult:AddTab("Mana e coleta"),
          Player = CreateWindowResult:AddTab("Aliados e anti-AFK"),
          Settings = CreateWindowResult:AddTab("Settings"),
        },
      }
      cResult.migrate()
      tbl743.State.moderatorIds = {}
      tbl743.State.moderatorGroups = {}
      tbl743.State.bots = {}
      tbl743.State.registerBot = function(a11599)
        table.insert(tbl743.State.bots, a11599)
      end
      res653.BeforeUnload=function()
        __bootSession.state="unloading";__bootSession.cancelled=true;__bootSession.updated=os.clock()
        __bootSession.unloadThread=coroutine.running()
        tbl743.State.unloading=true
        -- Snapshot while controls still exist and before stop callbacks alter operational UI.
        if tbl743.State.flushBladeSettings then
          local ok,saved,why=pcall(tbl743.State.flushBladeSettings)
          if not ok or saved==false then warn("[blade 23] Configuracao pendente no unload: "..tostring(ok and why or saved)) end
        end
        for _,bot in tbl743.State.bots do
          if type(bot.stop)=="function" then pcall(bot.stop) end
        end
        task.wait() -- Let stopped workers observe cancellation before Maid/hook/UI teardown.
      end
      local v3327 = http and http.request or http_request or request
      local str151 = "https://sentinel.heroinhound.cc/api/v1/"
      local str152 = tostring(getgenv().SENTINEL_PRODUCT_SECRET or "")
      local HttpService9 = game:GetService("HttpService")
      local embeddedModerationData = {["allowed_universes"]="1087859240, 1359573625",["allowed_places"]="100010170789226",["moderator_ids"]="117075515, 117092117, 218915876, 147287757, 1992980412, 2352320475, 1923314177, 1315267418, 1929945985, 29656, 3408465701, 272525488, 360905811, 309149657, 2758900605, 2052324682, 1220344444, 1099784, 1090716399, 1754748220, 78504910, 364994040, 96218539, 434535742, 19044993, 411595307, 1490237662, 1255256325, 1306981979, 20469570, 71662791, 77196836, 28177302, 8835343, 88193330, 83785067, 2542030529, 274304909, 2441088083, 177436599, 64992045, 1866587913, 1586650903, 1085890137, 143241422, 1014826936, 1657035, 2259720861, 338544906, 399618581, 73062, 167825083, 110153256, 266800563, 1216700054, 3314396480, 3292692379, 1427798376, 1626803537, 1311587059, 988461535, 3006409955, 2485656647, 1255256325, 2228891194, 2243463821, 2252396915, 1989789343, 8791234913, 2260532477, 677317511, 2812528388, 1129791035, 195989673, 1078995119, 16385717, 111217516, 1129801077, 1091218954, 1070438567, 111220022, 27964055, 1603601003, 1518270912, 4471765800, 725659608, 2557939582, 1682396718, 1525197437,1129791035,195989673,1078995119,16385717,111217516,1129801077,1091218954,1070438567,111220022,27964055,1603601003,1518270912,4471765800,725659608,2557939582,1682396718,1525197437,7486049096,1118492856,3460406967,1252415255,1814796338,2839783319,1301579831,1253825419,66934974,8647176491,332950853,7749742735,1148151081,2297159952,2612252879,41377282,1916909354,2359491684,1280266337,111084238,1769697283, 10630726130, 1880270211",["moderator_groups"]="4556484"}
      local fn1433 = function(a11600)
        return embeddedModerationData
      end
      tbl743.State.robloxGet = function(a11601)
        return nil, "nigger"
      end
      tbl743.State.getPresence = function(a11602)
        return nil
      end
      local v3328 = clonefunction and clonefunction(Players.LocalPlayer.Kick) or Players.LocalPlayer.Kick
      local safeTerminate = function(a11603)
        if flag165 then
          return
        end
        local str153 = tostring(a11603 or "sentinel safety check failed")
        if tbl743.State.bladeMenuInsteadOfLeave and tbl743.State.bladeMenuInsteadOfLeave(str153,true) then return end
        task.spawn(function()
          while true do
            if not (task.wait() and not flag165) then
              break
            end
            if tbl743.State.bladeMenuInsteadOfLeave and tbl743.State.bladeMenuInsteadOfLeave(str153,true) then return end
            pcall(function()
              v3328(Players.LocalPlayer, str153)
              local ErrorPrompt2 = game:GetService("CoreGui").RobloxPromptGui.promptOverlay.ErrorPrompt
              ErrorPrompt2.TitleFrame.ErrorTitle.Text = "sentinel.bz"
              ErrorPrompt2.MessageArea.ErrorFrame.ErrorMessage.Text = str153
            end)
          end
        end)
      end
      tbl743.State.safeTerminate = safeTerminate
      task.spawn(function()
        local moderatorIds2 = {}
        local moderatorGroups2 = {}
        if v3327 then
          for i138 = 1, 3 do
            if flag165 then
              return
            end
            local res656 = fn1433()
            if res656 then
              table.clear(moderatorIds2)
              table.clear(moderatorGroups2)
              local numbersResult2, v3337, v3338 = bResult.numbers(res656.moderator_ids)
              for k817, v3339 in numbersResult2, v3337, v3338 do
                moderatorIds2[v3339] = true
              end
              local numbersResult3, v3340, v3341 = bResult.numbers(res656.moderator_groups)
              for k818, v3342 in numbersResult3, v3340, v3341 do
                table.insert(moderatorGroups2, v3342)
              end
              if next(moderatorIds2) and #moderatorGroups2 > 0 then
                break
              end
            end
            task.wait(2)
          end
        end
        if flag165 then
          return
        end
        if not (next(moderatorIds2) and #moderatorGroups2 > 0) then
          safeTerminate("Moderator list failed to load")
          return
        end
        local State3 = tbl743.State
        local State4 = tbl743.State
        State3.productName = "rogue-lineage"
        State4.productSecret = str152
        tbl743.State.moderatorIds = moderatorIds2
        tbl743.State.moderatorGroups = moderatorGroups2
        tbl743.State.moderatorsLoaded = true
        if type(tbl743.State.onModeratorsLoaded) == "function" then
          pcall(tbl743.State.onModeratorsLoaded)
        end
      end)
      __bootMark("module:p")
      task.wait()
      tbl44.p()(tbl743)
      __bootMark("module:A")
      task.wait()
      tbl44.A()(tbl743)
      __bootMark("module:E")
      task.wait()
      tbl44.E()(tbl743)
      __bootMark("module:K")
      task.wait()
      tbl44.K()(tbl743)
      __bootMark("module:N")
      task.wait()
      tbl44.N()(tbl743)
      __bootMark("module:V")
      task.wait()
      tbl44.V()(tbl743)
      __bootMark("module:Y")
      task.wait()
      tbl44.Y()(tbl743)
      __bootMark("module:Z")
      task.wait()
      tbl44.Z()(tbl743)
      __bootMark("module:af")
      task.wait()
      tbl44.af()(tbl743)
      __bootMark("ready")
      __bootSession.state="running";__bootSession.executing=false
      res653:Notify({ Title = "sentinel.bz", Description = "rogue lineage loaded" })
    end, debug.traceback)
    if not ok46 then
      if __bootSession.library and __bootSession.library.Unload then pcall(function() __bootSession.library:Unload() end) end
      if __bootSession.coreCleanup then pcall(__bootSession.coreCleanup);__bootSession.coreCleanup=nil end
      __bootSession.executing=false
      if __bootSession.state~="unloaded" then
        __bootSession.state="failed"
        pcall(__bootMark,"failed: "..tostring(result50):sub(1,300))
      end
      if getgenv()[res42]==__bootSession then getgenv()[res42]=nil end
      warn("[sentinel] load failed: " .. tostring(result50))
    end
    return true
end
local __ok, __err = pcall(__entry, {})
__bootSession.executing=false
if not __ok then
  if __bootSession.library and __bootSession.library.Unload then pcall(function() __bootSession.library:Unload() end) end
  if __bootSession.coreCleanup then pcall(__bootSession.coreCleanup);__bootSession.coreCleanup=nil end
  if __bootSession.state~="unloaded" then
    __bootSession.state="failed";pcall(__bootMark,"entry-error: "..tostring(__err):sub(1,300))
  end
  warn("[blade 23] entry error: "..tostring(__err))
elseif __bootSession.state=="loading" then
  __bootSession.abort("entry-returned-before-ready")
end
return __ok and __bootSession.state=="running"
