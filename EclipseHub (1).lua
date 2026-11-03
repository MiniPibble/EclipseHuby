--[[
    EclipseHub | Code Redeemer
    Redesigned UI (tabs, live console, stats, animated eclipse logo)

    Hotkey : RightShift  = hide / show the UI
    Unload : About tab > Unload, or run getgenv().EclipseHubUnload()
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local function svc(name) return cloneref(game:GetService(name)) end

local Players = svc("Players")
local ReplicatedStorage = svc("ReplicatedStorage")
local RunService = svc("RunService")
local UserInputService = svc("UserInputService")
local TweenService = svc("TweenService")
local HttpService = svc("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG (saved between sessions when the executor supports files)
----------------------------------------------------------------
local CONFIG_FILE = "eclipsehub_config.json"
local Config = {
	autoCode = true,
	autoSubmit = true,
	submitAfter = 3,
	retype = false,
	riddle = false,
}

pcall(function()
	if type(isfile) == "function" and type(readfile) == "function" and isfile(CONFIG_FILE) then
		local data = HttpService:JSONDecode(readfile(CONFIG_FILE))
		if type(data) == "table" then
			for _, key in ipairs({ "autoCode", "autoSubmit", "retype", "riddle" }) do
				if type(data[key]) == "boolean" then
					Config[key] = data[key]
				end
			end
			if type(data.submitAfter) == "number" then
				Config.submitAfter = math.max(1, math.floor(data.submitAfter))
			end
		end
	end
end)

local function saveConfig()
	if type(writefile) ~= "function" then return end
	pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
	end)
end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local State = {
	enabled = Config.autoCode,
	autoSubmit = Config.autoSubmit,
	submitAfter = Config.submitAfter,
	retype = Config.retype,
	riddle = Config.riddle,

	seen = {},
	queue = {},
	focusedBox = nil,
	lastBox = nil,
	trackedBox = nil,
	textConn = nil,
	ancestryConn = nil,
	lastText = "",

	pendingText = nil,
	pendingBox = nil,
	pendingUntil = 0,
	pendingToken = 0,

	lastLog = nil,
	captured = 0,
	redeemed = 0,
}

local Connections = {}
local Unloaded = false
local function connect(signal, fn)
	local c = signal:Connect(fn)
	Connections[#Connections + 1] = c
	return c
end

local getUpvalues = (debug and debug.getupvalues) or getupvalues
local getConns = getconnections or (debug and debug.getconnections)
local setUpvalue = (debug and debug.setupvalue) or setupvalue

-- forward declarations (assigned further down)
local pushLog, statusLog, setStats, unload

----------------------------------------------------------------
-- THEME + UI HELPERS
----------------------------------------------------------------
local Theme = {
	Base = Color3.fromRGB(8, 8, 13),
	Panel = Color3.fromRGB(12, 12, 19),
	Side = Color3.fromRGB(10, 10, 16),
	Card = Color3.fromRGB(17, 17, 26),
	CardHover = Color3.fromRGB(24, 24, 36),
	Stroke = Color3.fromRGB(34, 34, 52),
	Accent = Color3.fromRGB(139, 92, 246),
	AccentSoft = Color3.fromRGB(167, 139, 250),
	Gold = Color3.fromRGB(251, 191, 36),
	Text = Color3.fromRGB(236, 236, 246),
	Sub = Color3.fromRGB(122, 122, 145),
	Good = Color3.fromRGB(74, 222, 128),
	Bad = Color3.fromRGB(248, 113, 113),
	Off = Color3.fromRGB(40, 40, 56),
}

local Left = Enum.TextXAlignment.Left
local Center = Enum.TextXAlignment.Center

local function new(class, props, kids)
	local obj = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			obj[k] = v
		end
	end
	for _, child in ipairs(kids or {}) do
		child.Parent = obj
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function tween(obj, props, time, style, dir)
	local t = TweenService:Create(
		obj,
		TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

----------------------------------------------------------------
-- SCREEN GUI
----------------------------------------------------------------
local OLD_NAMES = { "EclipseHub", "LevithonCodeRedeemer", "ACECodeSniperUI", "AutoTypeCodesUI" }

pcall(function()
	local core = (gethui and gethui()) or game:GetService("CoreGui")
	for _, name in ipairs(OLD_NAMES) do
		local prev = core:FindFirstChild(name)
		if prev then prev:Destroy() end
	end
end)
for _, name in ipairs(OLD_NAMES) do
	local prev = PlayerGui:FindFirstChild(name)
	if prev then prev:Destroy() end
end

local Gui = new("ScreenGui", {
	Name = "EclipseHub",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
if not pcall(function() Gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end) then
	Gui.Parent = PlayerGui
end

local W, H, HEADER = 430, 290, 44

local Root = new("Frame", {
	Name = "Root",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.fromOffset(W, H),
	BackgroundTransparency = 1,
	Parent = Gui,
})
local Scale = new("UIScale", { Scale = 0.88, Parent = Root })

local Shadow = new("ImageLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 8),
	Size = UDim2.new(1, 70, 1, 70),
	BackgroundTransparency = 1,
	Image = "rbxassetid://6014261993",
	ImageColor3 = Color3.new(0, 0, 0),
	ImageTransparency = 1,
	ScaleType = Enum.ScaleType.Slice,
	SliceCenter = Rect.new(49, 49, 450, 450),
	ZIndex = 0,
	Parent = Root,
})

local Window = new("CanvasGroup", {
	Name = "Window",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Theme.Base,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	GroupTransparency = 1,
	ZIndex = 1,
	Parent = Root,
}, { corner(14) })

-- NOTE: the gradient lives on its own frame. A UIGradient directly on a
-- CanvasGroup would tint (darken) every child inside it.
new("Frame", {
	Name = "Bg",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	Parent = Window,
}, {
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(17, 14, 30), Color3.fromRGB(8, 8, 13)),
		Rotation = 90,
	}),
})

local WinStroke = new("UIStroke", {
	Color = Color3.new(1, 1, 1),
	Thickness = 1.5,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	Parent = Window,
})
local WinGrad = new("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Stroke),
		ColorSequenceKeypoint.new(0.5, Theme.Accent),
		ColorSequenceKeypoint.new(1, Theme.Stroke),
	}),
	Parent = WinStroke,
})

----------------------------------------------------------------
-- HEADER
----------------------------------------------------------------
local Header = new("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, HEADER),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	Active = true,
	Parent = Window,
})
new("Frame", {
	Position = UDim2.new(0, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 1),
	BackgroundColor3 = Theme.Stroke,
	BorderSizePixel = 0,
	Parent = Header,
})

-- eclipse logo (gold crescent)
local Logo = new("Frame", {
	Position = UDim2.fromOffset(14, 7),
	Size = UDim2.fromOffset(30, 30),
	BackgroundTransparency = 1,
	Parent = Header,
})
local Disc = new("Frame", {
	Position = UDim2.fromOffset(1, 1),
	Size = UDim2.fromOffset(28, 28),
	BackgroundColor3 = Theme.Gold,
	BorderSizePixel = 0,
	Parent = Logo,
}, { corner(14) })
new("UIGradient", {
	Color = ColorSequence.new(Theme.Gold, Theme.Accent),
	Rotation = 45,
	Parent = Disc,
})
local DiscCover = new("Frame", {
	Position = UDim2.fromOffset(8, 2),
	Size = UDim2.fromOffset(26, 26),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	ZIndex = 2,
	Parent = Logo,
}, { corner(13) })

new("TextLabel", {
	Position = UDim2.fromOffset(54, 5),
	Size = UDim2.fromOffset(200, 20),
	BackgroundTransparency = 1,
	Text = "EclipseHub",
	TextColor3 = Theme.Text,
	TextSize = 16,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Left,
	Parent = Header,
})
new("TextLabel", {
	Position = UDim2.fromOffset(54, 24),
	Size = UDim2.fromOffset(200, 14),
	BackgroundTransparency = 1,
	Text = "Code Redeemer",
	TextColor3 = Theme.Sub,
	TextSize = 10,
	Font = Enum.Font.Gotham,
	TextXAlignment = Left,
	Parent = Header,
})

local function headerButton(text, xOff, hoverColor)
	local btn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, xOff, 0.5, 0),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = Theme.Card,
		Text = text,
		TextColor3 = Theme.Sub,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = Header,
	}, { corner(8), stroke(Theme.Stroke, 1) })
	btn.MouseEnter:Connect(function()
		tween(btn, { BackgroundColor3 = hoverColor, TextColor3 = Theme.Text })
	end)
	btn.MouseLeave:Connect(function()
		tween(btn, { BackgroundColor3 = Theme.Card, TextColor3 = Theme.Sub })
	end)
	return btn
end

local CloseBtn = headerButton("X", -14, Theme.Bad)
local MinBtn = headerButton("-", -46, Theme.CardHover)

-- status pill
local Pill = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -84, 0.5, 0),
	Size = UDim2.fromOffset(94, 24),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0,
	Parent = Header,
}, { corner(12), stroke(Theme.Stroke, 1) })
local PillDot = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.5, 0),
	Size = UDim2.fromOffset(8, 8),
	BackgroundColor3 = Theme.Good,
	BorderSizePixel = 0,
	Parent = Pill,
}, { corner(4) })
local PillText = new("TextLabel", {
	Position = UDim2.fromOffset(24, 0),
	Size = UDim2.new(1, -28, 1, 0),
	BackgroundTransparency = 1,
	Text = "Scanning",
	TextColor3 = Theme.Text,
	TextSize = 11,
	Font = Enum.Font.GothamMedium,
	TextXAlignment = Left,
	Parent = Pill,
})

local function setPill(on)
	PillText.Text = on and "Scanning" or "Off"
	tween(PillDot, { BackgroundColor3 = on and Theme.Good or Theme.Bad })
end
setPill(State.enabled)

----------------------------------------------------------------
-- BODY: SIDEBAR + PAGES
----------------------------------------------------------------
local Body = new("Frame", {
	Position = UDim2.fromOffset(0, HEADER + 1),
	Size = UDim2.new(1, 0, 1, -(HEADER + 1)),
	BackgroundTransparency = 1,
	Parent = Window,
})

local SIDE_W = 100
local Sidebar = new("Frame", {
	Size = UDim2.new(0, SIDE_W, 1, 0),
	BackgroundColor3 = Theme.Side,
	BorderSizePixel = 0,
	Parent = Body,
})
new("Frame", {
	Position = UDim2.new(1, -1, 0, 0),
	Size = UDim2.new(0, 1, 1, 0),
	BackgroundColor3 = Theme.Stroke,
	BorderSizePixel = 0,
	Parent = Sidebar,
})

local TabList = new("Frame", {
	Position = UDim2.fromOffset(10, 12),
	Size = UDim2.new(1, -20, 1, -48),
	BackgroundTransparency = 1,
	Parent = Sidebar,
}, {
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
})

new("TextLabel", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 14, 1, -10),
	Size = UDim2.new(1, -20, 0, 14),
	BackgroundTransparency = 1,
	Text = "EclipseHub v1.0",
	TextColor3 = Theme.Sub,
	TextSize = 10,
	Font = Enum.Font.Gotham,
	TextXAlignment = Left,
	Parent = Sidebar,
})

local Pages = new("Frame", {
	Position = UDim2.fromOffset(SIDE_W + 12, 12),
	Size = UDim2.new(1, -(SIDE_W + 24), 1, -24),
	BackgroundTransparency = 1,
	Parent = Body,
})

local TabButtons, PageFrames, currentTab = {}, {}, nil

local function selectTab(name)
	if currentTab == name then return end
	currentTab = name
	for tabName, t in pairs(TabButtons) do
		local active = tabName == name
		tween(t.btn, { BackgroundTransparency = active and 0 or 1 })
		tween(t.label, { TextColor3 = active and Theme.Text or Theme.Sub })
		tween(t.bar, {
			Size = active and UDim2.fromOffset(3, 16) or UDim2.fromOffset(3, 0),
			BackgroundTransparency = active and 0 or 1,
		})
		PageFrames[tabName].Visible = active
	end
end

local function addTab(name, order)
	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = Theme.Card,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		Parent = TabList,
	}, { corner(9) })
	local bar = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(3, 0),
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = btn,
	}, { corner(2) })
	local label = new("TextLabel", {
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -22, 1, 0),
		BackgroundTransparency = 1,
		Text = name,
		TextColor3 = Theme.Sub,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Left,
		Parent = btn,
	})
	TabButtons[name] = { btn = btn, label = label, bar = bar }

	btn.MouseEnter:Connect(function()
		if currentTab ~= name then
			tween(label, { TextColor3 = Theme.Text })
		end
	end)
	btn.MouseLeave:Connect(function()
		if currentTab ~= name then
			tween(label, { TextColor3 = Theme.Sub })
		end
	end)
	btn.MouseButton1Click:Connect(function()
		selectTab(name)
	end)
end

addTab("Redeemer", 1)
addTab("Console", 2)
addTab("About", 3)

----------------------------------------------------------------
-- PAGE 1: REDEEMER
----------------------------------------------------------------
local MainPage = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = Theme.Accent,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Visible = false,
	Parent = Pages,
}, {
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", { PaddingRight = UDim.new(0, 6) }),
})
PageFrames["Redeemer"] = MainPage

-- stats row
local StatsRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundTransparency = 1,
	LayoutOrder = 1,
	Parent = MainPage,
})

local function statCard(xScale, xOff, label, valueColor)
	local c = new("Frame", {
		Position = UDim2.new(xScale, xOff, 0, 0),
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundColor3 = Theme.Card,
		BorderSizePixel = 0,
		Parent = StatsRow,
	}, { corner(10), stroke(Theme.Stroke, 1) })
	new("TextLabel", {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 12),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = Theme.Sub,
		TextSize = 9,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Left,
		Parent = c,
	})
	return new("TextLabel", {
		Position = UDim2.fromOffset(12, 18),
		Size = UDim2.new(1, -24, 0, 22),
		BackgroundTransparency = 1,
		Text = "0",
		TextColor3 = valueColor,
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Left,
		Parent = c,
	})
end

local CapturedValue = statCard(0, 0, "CODES CAPTURED", Theme.AccentSoft)
local RedeemedValue = statCard(0.5, 4, "CODES REDEEMED", Theme.Good)

setStats = function()
	CapturedValue.Text = tostring(State.captured)
	RedeemedValue.Text = tostring(State.redeemed)
end

-- toggles card
local ToggleCard = new("Frame", {
	Size = UDim2.new(1, 0, 0, 152),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0,
	LayoutOrder = 2,
	Parent = MainPage,
}, {
	corner(10),
	stroke(Theme.Stroke, 1),
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 4),
	}),
})

local function toggleRow(order, label, desc, default, callback)
	local state = default
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = Theme.CardHover,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		Parent = ToggleCard,
	}, { corner(8) })

	new("TextLabel", {
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -70, 0, 16),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = Theme.Text,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Left,
		Parent = row,
	})
	new("TextLabel", {
		Position = UDim2.fromOffset(10, 19),
		Size = UDim2.new(1, -70, 0, 13),
		BackgroundTransparency = 1,
		Text = desc,
		TextColor3 = Theme.Sub,
		TextSize = 10,
		Font = Enum.Font.Gotham,
		TextXAlignment = Left,
		Parent = row,
	})

	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(36, 20),
		BackgroundColor3 = state and Theme.Accent or Theme.Off,
		BorderSizePixel = 0,
		Parent = row,
	}, { corner(10) })
	local pin = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = track,
	}, { corner(7) })

	row.MouseEnter:Connect(function()
		tween(row, { BackgroundTransparency = 0.45 })
	end)
	row.MouseLeave:Connect(function()
		tween(row, { BackgroundTransparency = 1 })
	end)
	row.MouseButton1Click:Connect(function()
		state = not state
		tween(track, { BackgroundColor3 = state and Theme.Accent or Theme.Off })
		tween(pin, { Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
		if callback then callback(state) end
	end)
end

toggleRow(1, "Auto Code", "Capture codes from game notifications", State.enabled, function(v)
	State.enabled = v
	Config.autoCode = v
	saveConfig()
	setPill(v)
	pushLog(v and "Auto Code enabled - scanning..." or "Auto Code disabled", v and Theme.Good or Theme.Bad)
end)
toggleRow(2, "Auto Submit", "Redeem automatically once captured", State.autoSubmit, function(v)
	State.autoSubmit = v
	Config.autoSubmit = v
	saveConfig()
end)
toggleRow(3, "Riddle Solver", "Experimental (setting is saved)", State.riddle, function(v)
	State.riddle = v
	Config.riddle = v
	saveConfig()
end)
toggleRow(4, "Retype Invalid", "Re-paste the code if it gets rejected", State.retype, function(v)
	State.retype = v
	Config.retype = v
	saveConfig()
end)

-- stepper card
local StepCard = new("Frame", {
	Size = UDim2.new(1, 0, 0, 42),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0,
	LayoutOrder = 3,
	Parent = MainPage,
}, { corner(10), stroke(Theme.Stroke, 1) })

new("TextLabel", {
	Position = UDim2.fromOffset(14, 6),
	Size = UDim2.new(1, -130, 0, 16),
	BackgroundTransparency = 1,
	Text = "Submit after",
	TextColor3 = Theme.Text,
	TextSize = 12,
	Font = Enum.Font.GothamMedium,
	TextXAlignment = Left,
	Parent = StepCard,
})
new("TextLabel", {
	Position = UDim2.fromOffset(14, 22),
	Size = UDim2.new(1, -130, 0, 13),
	BackgroundTransparency = 1,
	Text = "Parts collected before redeeming",
	TextColor3 = Theme.Sub,
	TextSize = 10,
	Font = Enum.Font.Gotham,
	TextXAlignment = Left,
	Parent = StepCard,
})

local Stepper = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(88, 26),
	BackgroundTransparency = 1,
	Parent = StepCard,
})

local function stepButton(text, x)
	local b = new("TextButton", {
		Position = UDim2.fromOffset(x, 0),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = Theme.CardHover,
		Text = text,
		TextColor3 = Theme.Text,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = Stepper,
	}, { corner(8), stroke(Theme.Stroke, 1) })
	b.MouseEnter:Connect(function() tween(b, { BackgroundColor3 = Theme.Accent }) end)
	b.MouseLeave:Connect(function() tween(b, { BackgroundColor3 = Theme.CardHover }) end)
	return b
end

local StepMinus = stepButton("-", 0)
local StepValue = new("TextLabel", {
	Position = UDim2.fromOffset(28, 0),
	Size = UDim2.fromOffset(32, 26),
	BackgroundTransparency = 1,
	Text = tostring(State.submitAfter),
	TextColor3 = Theme.Text,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Center,
	Parent = Stepper,
})
local StepPlus = stepButton("+", 62)

local function updateStep()
	StepValue.Text = tostring(State.submitAfter)
	Config.submitAfter = State.submitAfter
	saveConfig()
end
StepMinus.MouseButton1Click:Connect(function()
	State.submitAfter = math.max(1, State.submitAfter - 1)
	updateStep()
end)
StepPlus.MouseButton1Click:Connect(function()
	State.submitAfter = State.submitAfter + 1
	updateStep()
end)

----------------------------------------------------------------
-- PAGE 2: CONSOLE
----------------------------------------------------------------
local ConsolePage = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = Pages,
})
PageFrames["Console"] = ConsolePage

new("TextLabel", {
	Size = UDim2.new(1, -70, 0, 24),
	BackgroundTransparency = 1,
	Text = "Live Console",
	TextColor3 = Theme.Text,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Left,
	Parent = ConsolePage,
})

local ClearBtn = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 1),
	Size = UDim2.fromOffset(58, 22),
	BackgroundColor3 = Theme.Card,
	Text = "Clear",
	TextColor3 = Theme.Sub,
	TextSize = 11,
	Font = Enum.Font.GothamMedium,
	AutoButtonColor = false,
	Parent = ConsolePage,
}, { corner(8), stroke(Theme.Stroke, 1) })
ClearBtn.MouseEnter:Connect(function() tween(ClearBtn, { TextColor3 = Theme.Text, BackgroundColor3 = Theme.CardHover }) end)
ClearBtn.MouseLeave:Connect(function() tween(ClearBtn, { TextColor3 = Theme.Sub, BackgroundColor3 = Theme.Card }) end)

local LogScroll = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 30),
	Size = UDim2.new(1, 0, 1, -30),
	BackgroundColor3 = Color3.fromRGB(6, 6, 10),
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = Theme.Accent,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = ConsolePage,
}, {
	corner(10),
	stroke(Theme.Stroke, 1),
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	}),
})

local logLines, logCount = {}, 0

pushLog = function(msg, color)
	logCount = logCount + 1
	local line = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = os.date("%H:%M:%S") .. "  " .. tostring(msg),
		TextColor3 = color or Theme.Sub,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextXAlignment = Left,
		TextWrapped = true,
		LayoutOrder = logCount,
		Parent = LogScroll,
	})
	logLines[#logLines + 1] = line
	if #logLines > 80 then
		local first = table.remove(logLines, 1)
		first:Destroy()
	end
	task.delay(0.03, function()
		if LogScroll and LogScroll.Parent then
			LogScroll.CanvasPosition = Vector2.new(0, 1e6)
		end
	end)
end

ClearBtn.MouseButton1Click:Connect(function()
	for _, l in ipairs(logLines) do l:Destroy() end
	logLines = {}
end)

-- throttled status logger used by the redeemer logic
statusLog = function(msg, color)
	if not State.enabled then return end
	if msg == State.lastLog then return end
	State.lastLog = msg
	pushLog(msg, color)
end

----------------------------------------------------------------
-- PAGE 3: ABOUT
----------------------------------------------------------------
local AboutPage = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = Pages,
})
PageFrames["About"] = AboutPage

local AboutCard = new("Frame", {
	Size = UDim2.new(1, 0, 1, -46),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0,
	Parent = AboutPage,
}, { corner(10), stroke(Theme.Stroke, 1) })

new("TextLabel", {
	Position = UDim2.fromOffset(14, 10),
	Size = UDim2.new(1, -28, 0, 24),
	BackgroundTransparency = 1,
	Text = "EclipseHub",
	TextColor3 = Theme.Text,
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Left,
	Parent = AboutCard,
})
new("TextLabel", {
	Position = UDim2.fromOffset(14, 34),
	Size = UDim2.new(1, -28, 0, 14),
	BackgroundTransparency = 1,
	Text = "Code Redeemer  |  v1.0",
	TextColor3 = Theme.AccentSoft,
	TextSize = 11,
	Font = Enum.Font.GothamMedium,
	TextXAlignment = Left,
	Parent = AboutCard,
})
new("TextLabel", {
	Position = UDim2.fromOffset(14, 58),
	Size = UDim2.new(1, -28, 1, -68),
	BackgroundTransparency = 1,
	Text = "HOW IT WORKS\n"
		.. "1. Click the game's code box once.\n"
		.. "2. Keep Auto Code on.\n"
		.. "3. Codes from notifications get pasted.\n"
		.. "4. Auto Submit redeems them.\n\n"
		.. "HOTKEY: RightShift hides / shows.",
	TextColor3 = Theme.Sub,
	TextSize = 10,
	Font = Enum.Font.Gotham,
	TextXAlignment = Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Parent = AboutCard,
})

local UnloadBtn = new("TextButton", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundColor3 = Theme.Card,
	Text = "Unload EclipseHub",
	TextColor3 = Theme.Bad,
	TextSize = 12,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	Parent = AboutPage,
}, { corner(10), stroke(Theme.Stroke, 1) })
UnloadBtn.MouseEnter:Connect(function() tween(UnloadBtn, { BackgroundColor3 = Theme.Bad, TextColor3 = Color3.new(1, 1, 1) }) end)
UnloadBtn.MouseLeave:Connect(function() tween(UnloadBtn, { BackgroundColor3 = Theme.Card, TextColor3 = Theme.Bad }) end)
UnloadBtn.MouseButton1Click:Connect(function() unload() end)

selectTab("Redeemer")

----------------------------------------------------------------
-- WINDOW BEHAVIOUR: drag, minimize, close, hotkey, animation
----------------------------------------------------------------
do
	local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
	Header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = Root.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	Header.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if input == dragInput and dragging then
			local d = input.Position - dragStart
			Root.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y
			)
		end
	end)
end

local minimized = false
MinBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	tween(Root, { Size = UDim2.fromOffset(W, minimized and HEADER or H) }, 0.3)
end)

CloseBtn.MouseButton1Click:Connect(function()
	unload()
end)

connect(UserInputService.InputBegan, function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		Gui.Enabled = not Gui.Enabled
	end
end)

-- ambient animation: rotating border glow, moving eclipse, pulsing dot
do
	local t0 = os.clock()
	connect(RunService.Heartbeat, function()
		local t = os.clock() - t0
		WinGrad.Rotation = (t * 40) % 360
		DiscCover.Position = UDim2.fromOffset(8 + math.sin(t * 1.2) * 2, 2)
		if State.enabled then
			PillDot.BackgroundTransparency = 0.3 + 0.3 * math.sin(t * 3)
		else
			PillDot.BackgroundTransparency = 0
		end
	end)
end

-- open animation
tween(Scale, { Scale = 1 }, 0.5, Enum.EasingStyle.Back)
tween(Window, { GroupTransparency = 0 }, 0.35)
tween(Shadow, { ImageTransparency = 0.45 }, 0.5)

----------------------------------------------------------------
-- REDEEMER LOGIC
----------------------------------------------------------------
local function isOwnGui(x)
	local y = x
	for _ = 1, 10 do
		if not y then break end
		if y.Name == "EclipseHub" or y.Name == "SourcesHubRedeemerGui" then return true end
		y = y.Parent
	end
	return false
end

local function isVisible(x)
	local y = x
	while y do
		if y:IsA("GuiObject") and not y.Visible then return false end
		if y:IsA("ScreenGui") then return y.Enabled end
		y = y.Parent
	end
	return true
end

local function getTextBoxes(pg)
	local r = {}
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") and g.Enabled and not isOwnGui(g) then
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("TextBox") and not isOwnGui(d) then r[#r + 1] = d end
			end
		end
	end
	return r
end

local function getCodeButtons(pg)
	local r = {}
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") and g.Enabled and not isOwnGui(g) then
			for _, d in ipairs(g:GetDescendants()) do
				if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwnGui(d) then
					local n = d.Name:lower()
					local pn = (d.Parent and d.Parent.Name or ""):lower()
					if (n:find("code") or n:find("redeem") or pn:find("code") or pn:find("redeem")) and isVisible(d) then
						r[#r + 1] = d
					end
				end
			end
		end
	end
	return r
end

local function fireButton(b)
	if not b then return false end
	local methods = {}
	methods[#methods + 1] = function() b.MouseButton1Click:Fire() end
	methods[#methods + 1] = function() b.Activated:Fire() end
	if typeof(firesignal) == "function" then
		methods[#methods + 1] = function() firesignal(b.MouseButton1Click) end
		methods[#methods + 1] = function() firesignal(b.Activated) end
	end
	if typeof(getConns) == "function" then
		methods[#methods + 1] = function()
			local ok, cs = pcall(getConns, b.MouseButton1Click)
			if ok and type(cs) == "table" then
				for _, c in ipairs(cs) do pcall(function() c:Fire() end) end
			end
			local ok2, cs2 = pcall(getConns, b.Activated)
			if ok2 and type(cs2) == "table" then
				for _, c in ipairs(cs2) do pcall(function() c:Fire() end) end
			end
		end
	end
	if typeof(fireclick) == "function" then
		methods[#methods + 1] = function() fireclick(b) end
	end
	local any = false
	for _, f in ipairs(methods) do
		local ok = pcall(f)
		any = any or ok
	end
	return any
end

local function fireFocusLost(b)
	if not b then return false end
	local any = false
	if typeof(firesignal) == "function" then
		local ok = pcall(firesignal, b.FocusLost, true)
		any = any or ok
	end
	if typeof(getConns) == "function" then
		local ok, cs = pcall(getConns, b.FocusLost)
		if ok and type(cs) == "table" then
			for _, c in ipairs(cs) do
				local f
				pcall(function() f = c.Function end)
				if f and typeof(getUpvalues) == "function" and typeof(setUpvalue) == "function" then
					local uok, ups = pcall(getUpvalues, f)
					if uok and type(ups) == "table" then
						for i, v in pairs(ups) do
							if type(v) == "boolean" and v == true then
								pcall(setUpvalue, f, i, false)
							end
						end
					end
				end
				local fok = pcall(function()
					if c.Enabled ~= false then c:Fire(true) end
				end)
				any = any or fok
			end
		end
	end
	return any
end

local function submitCode(code)
	local pg = PlayerGui or LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return false, "no PlayerGui" end

	local codesGui = pg:FindFirstChild("Codes")
	if codesGui then
		if codesGui:IsA("ScreenGui") then codesGui.Enabled = true end
		local frame = codesGui:FindFirstChild("Codes") or codesGui
		if frame:IsA("GuiObject") then frame.Visible = true end
		local cur = frame
		while cur and cur ~= codesGui do
			if cur:IsA("GuiObject") then cur.Visible = true end
			cur = cur.Parent
		end

		local box
		for _, d in ipairs(frame:GetDescendants()) do
			if d:IsA("TextBox") and not isOwnGui(d) then box = d break end
		end

		local btn
		for _, d in ipairs(frame:GetDescendants()) do
			if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwnGui(d) then
				local n = d.Name:lower()
				local t = ""
				pcall(function() t = d.Text:lower() end)
				if n:find("submit") or t:find("submit") or n:find("redeem") or t:find("redeem")
					or n:find("claim") or t:find("confirm") or n:find("enter") then
					btn = d
					break
				end
			end
		end
		if not btn then
			for _, d in ipairs(frame:GetDescendants()) do
				if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwnGui(d) then
					local n = d.Name:lower()
					if not n:find("close") and not n:find("x") and not n:find("toggle") then
						btn = d
						break
					end
				end
			end
		end

		if box then
			pcall(function() box.Text = code end)
			task.wait(0.05)
			if btn then fireButton(btn) end
			fireFocusLost(box)
			return true, "submitted via PlayerGui.Codes"
		end
	end

	for _, b in ipairs(getCodeButtons(pg)) do
		fireButton(b)
		task.wait(0.05)
	end
	task.wait(0.2)

	local box
	local deadline = os.clock() + 2
	while os.clock() < deadline do
		local all = getTextBoxes(pg)
		for _, d in ipairs(all) do
			if isVisible(d) then
				local n = d.Name:lower()
				local pn = (d.Parent and d.Parent.Name or ""):lower()
				if n:find("code") or pn:find("code") or n:find("redeem") or pn:find("redeem")
					or n:find("input") or pn:find("textbox") or n:find("enter") then
					box = d
					break
				end
			end
		end
		if not box then
			for _, d in ipairs(all) do
				if isVisible(d) then box = d break end
			end
		end
		if box then break end
		task.wait(0.1)
	end
	if not box then return false, "no codebox visible" end

	pcall(function() box.Text = code end)
	task.wait(0.05)

	local btn
	local names = { "submit", "redeem", "claim", "confirm", "enter", "send", "apply", "ok", "use", "go", "check" }
	local p = box.Parent
	for _ = 1, 8 do
		if not p then break end
		for _, d in ipairs(p:GetDescendants()) do
			if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwnGui(d) and d ~= box then
				local n = d.Name:lower()
				local t = ""
				pcall(function() t = d.Text:lower() end)
				for _, sn in ipairs(names) do
					if n:find(sn) or t:find(sn) then
						if isVisible(d) then btn = d break end
					end
				end
				if btn then break end
			end
		end
		if btn then break end
		p = p.Parent
	end
	if btn then fireButton(btn) end
	fireFocusLost(box)
	return true, "submitted via dynamic search"
end

local function getActiveBox()
	for _, b in ipairs(getTextBoxes(PlayerGui)) do
		if isVisible(b) then return b end
	end
	return nil
end

-- box tracking ---------------------------------------------------
local function clearQueue()
	State.queue = {}
end

local function releaseBox()
	if State.textConn then pcall(function() State.textConn:Disconnect() end) end
	if State.ancestryConn then pcall(function() State.ancestryConn:Disconnect() end) end
	State.textConn = nil
	State.ancestryConn = nil
	State.trackedBox = nil
end

local function trackBox(box)
	if not box or State.trackedBox == box then return end
	releaseBox()
	State.trackedBox = box
	if box.Text ~= "" then State.lastText = box.Text end
	State.textConn = box:GetPropertyChangedSignal("Text"):Connect(function()
		if box.Text == "" then clearQueue() else State.lastText = box.Text end
	end)
	State.ancestryConn = box.AncestryChanged:Connect(function(_, parent)
		if not parent then
			clearQueue()
			releaseBox()
		end
	end)
end

connect(UserInputService.TextBoxFocused, function(box)
	if Unloaded then return end
	if box:IsDescendantOf(Gui) then return end
	if box ~= getActiveBox() then return end
	State.focusedBox = box
	State.lastBox = box
	trackBox(box)
	if State.enabled then statusLog("Ready", Theme.Good) end
end)

connect(UserInputService.TextBoxFocusReleased, function(box)
	if Unloaded then return end
	if box:IsDescendantOf(Gui) then return end
	local current = getActiveBox()
	if box ~= current and box ~= State.lastBox then return end

	if State.retype and (box == current or box == State.lastBox) then
		local text = box.Text ~= "" and box.Text or State.lastText
		if State.pendingText and os.clock() <= State.pendingUntil then return end
		State.pendingToken = State.pendingToken + 1
		local token = State.pendingToken
		State.pendingText = text
		State.pendingBox = box
		State.pendingUntil = os.clock() + 8
		task.delay(8, function()
			if token == State.pendingToken then
				State.pendingText = nil
				State.pendingBox = nil
				State.pendingUntil = 0
			end
		end)
	end

	if State.focusedBox == box then
		State.focusedBox = nil
		if State.enabled then
			local ok = State.lastBox and State.lastBox.Parent
			statusLog(ok and "Ready" or "Click code box first", ok and Theme.Good or Theme.Sub)
		end
	end
end)

-- retype on rejection --------------------------------------------
local function repaste(box, text)
	if not State.retype or not text or text == "" then return false end
	RunService.Heartbeat:Wait()
	local cb = getActiveBox() or box
	if not cb or not isVisible(cb) then return false end
	local ok = pcall(function() cb.Text = text end)
	if ok then
		State.lastBox = cb
		trackBox(cb)
	end
	return ok
end

local REJECT_PHRASES = {
	"invalid code", "code is invalid", "expired", "already redeemed", "already used",
	"doesn't exist", "does not exist", "not found", "rejected",
}

local function checkRejection(text, obj)
	if not State.retype or not State.pendingText then return end
	if os.clock() > State.pendingUntil then
		State.pendingText, State.pendingBox, State.pendingUntil = nil, nil, 0
		return
	end
	if obj and isOwnGui(obj) then return end
	local lower = tostring(text or ""):lower()
	local rejected = false
	for _, phrase in ipairs(REJECT_PHRASES) do
		if lower:find(phrase, 1, true) then rejected = true break end
	end
	if not rejected then return end
	local pt, pb = State.pendingText, State.pendingBox
	local ok = repaste(pb, pt)
	State.pendingText, State.pendingBox, State.pendingUntil = nil, nil, 0
	if ok then statusLog("Invalid - repasted: " .. pt, Theme.Sub) end
end

local function watchText(obj)
	if not (obj:IsA("TextLabel") or obj:IsA("TextButton")) then return end
	if isOwnGui(obj) then return end
	checkRejection(obj.Text or "", obj)
	connect(obj:GetPropertyChangedSignal("Text"), function()
		checkRejection(obj.Text or "", obj)
	end)
end

for _, obj in ipairs(PlayerGui:GetDescendants()) do watchText(obj) end
connect(PlayerGui.DescendantAdded, function(obj)
	task.wait(0.04)
	if not Unloaded then watchText(obj) end
end)

-- paste + submit -------------------------------------------------
local function pasteCode(text)
	if not text or text == "" then return end
	if not State.enabled then return end
	if State.trackedBox and not isVisible(State.trackedBox) then
		clearQueue()
		releaseBox()
	end

	local box = getActiveBox()
	State.queue[#State.queue + 1] = text
	local combined = table.concat(State.queue)
	local count = #State.queue

	if box then
		State.lastBox = box
		trackBox(box)
		local focused = UserInputService:GetFocusedTextBox() == box
		pcall(function() box.Text = combined end)
		if focused then
			pcall(function()
				local p = #combined + 1
				box.CursorPosition = p
				box.SelectionStart = p
			end)
		end
	else
		statusLog("Captured; opening UI...", Theme.Sub)
	end

	statusLog("Pasted " .. tostring(count) .. "/" .. tostring(State.submitAfter), Theme.Good)

	if count >= State.submitAfter then
		clearQueue()
		if State.autoSubmit then
			local ok, msg = submitCode(combined)
			if ok then
				State.redeemed = State.redeemed + 1
				setStats()
				statusLog("Redeemed: " .. combined, Theme.Good)
			else
				local repasted = repaste(box, combined)
				if repasted then
					statusLog("Invalid - repasted: " .. combined, Theme.Sub)
				else
					statusLog("Failed: " .. tostring(msg), Theme.Bad)
				end
			end
		end
	end
end

-- notification hook ----------------------------------------------
local function findNotifyRemote()
	if _G.PhiNotifyRemote then return _G.PhiNotifyRemote end
	local packages = ReplicatedStorage:WaitForChild("Packages", 10)
	local net = packages and packages:WaitForChild("Net", 10)
	if not net then return nil end
	local info = debug and (debug.getinfo or debug.info)
	if getgc and info and getConns then
		for _, d in ipairs(net:GetDescendants()) do
			if d:IsA("RemoteEvent") then
				local ok, cs = pcall(getConns, d.OnClientEvent)
				if ok then
					for _, c in ipairs(cs) do
						local f, fn = pcall(function() return c.Function end)
						if f and type(fn) == "function" then
							local i, inf = pcall(info, fn)
							if i and tostring(inf.short_src or inf.source or ""):find("NotificationController", 1, true) then
								return d
							end
						end
					end
				end
			end
		end
	end
	return nil
end

local function stripTags(t)
	if type(t) ~= "string" then return tostring(t) end
	return (t:gsub("<[^>]->", ""))
end

local wordBuffer = {}
local WORDS_PER_CODE = 1

local function onNotification(...)
	if not State.enabled then return end
	local text = stripTags(tostring((...) or ""))
	text = text:match("^%s*(.-)%s*$") or ""
	if text == "" or text:find("%s") then return end

	for word in text:gmatch("[%w_]+") do
		wordBuffer[#wordBuffer + 1] = word
	end
	if #wordBuffer < WORDS_PER_CODE then return end

	local parts = {}
	for i = 1, math.min(#wordBuffer, WORDS_PER_CODE) do parts[i] = wordBuffer[i] end
	wordBuffer = {}

	local captured = table.concat(parts)
	if captured == "" or State.seen[captured] then return end
	State.seen[captured] = true
	task.delay(1.25, function() State.seen[captured] = nil end)

	State.captured = State.captured + 1
	setStats()
	pasteCode(captured)
end

task.spawn(function()
	local remote = findNotifyRemote()
	if Unloaded then return end
	if remote then
		if getgenv then
			local prev = getgenv().EclipseHubNotifyConnection
			if prev then pcall(function() prev:Disconnect() end) end
		end
		local conn = connect(remote.OnClientEvent, function(...)
			pcall(onNotification, ...)
		end)
		if getgenv then getgenv().EclipseHubNotifyConnection = conn end
		pushLog("Notification hook active", Theme.Good)
	else
		pushLog("Notification remote not found (needs getconnections + debug.getinfo)", Theme.Bad)
	end
end)

----------------------------------------------------------------
-- UNLOAD
----------------------------------------------------------------
unload = function()
	if Unloaded then return end
	Unloaded = true
	for _, c in ipairs(Connections) do
		pcall(function() c:Disconnect() end)
	end
	Connections = {}
	releaseBox()
	if getgenv then
		pcall(function()
			getgenv().EclipseHubNotifyConnection = nil
			getgenv().EclipseHubUnload = nil
			getgenv().StopAura = nil
		end)
	end
	tween(Scale, { Scale = 0.9 }, 0.2)
	tween(Window, { GroupTransparency = 1 }, 0.2)
	tween(Shadow, { ImageTransparency = 1 }, 0.2)
	task.delay(0.25, function()
		if Gui then Gui:Destroy() end
	end)
end

if getgenv then
	getgenv().EclipseHubUnload = unload
	getgenv().StopAura = unload
end

pushLog("EclipseHub loaded", Theme.AccentSoft)
pushLog(State.enabled and "> scanning..." or "status: OFF", State.enabled and Theme.Good or Theme.Bad)
