-- @harness native
-- Self-tests of the fake engine and the harness (no mod code). If these fail,
-- every other result is suspect.

test("Game properties: copy semantics and storage-rule checks", function()
	H.world{}
	local t = { a = 1, list = { 1, 2, 3 } }
	Game:SetProperty("K", t)
	t.a = 99
	H.eq(Game:GetProperty("K").a, 1, "SetProperty copies")
	local r = Game:GetProperty("K")
	r.a = 5
	H.eq(Game:GetProperty("K").a, 1, "GetProperty returns a copy")
	H.len(FAKE.propViolations, 0)
	Game:SetProperty("BAD", { [0] = 1 })
	Game:SetProperty("BAD2", { 1, nil, 3 })
	Game:SetProperty("BAD3", { flag = true })
	H.len(FAKE.propViolations, 3, "key 0, hole, boolean reported")
	FAKE.propViolations = {}
	Game:SetProperty("E", { name = "", list = {}, n = 1 })
	H.deq(Game:GetProperty("E"), { n = 1 }, "empty strings and tables do not survive the round trip")
	H.eq(FAKE.propWrites["E"], 1)
end)

test("events: Add, Remove, fire, handler errors captured", function()
	H.world{}
	local got = {}
	local function add(a, b) got[#got + 1] = a + b end
	GameEvents.TX_Test.Add(add)
	GameEvents.TX_Test.Add(function() error("boom") end)
	GameEvents.TX_Test(2, 3)
	H.deq(got, { 5 })
	H.len(FAKE.handlerErrors, 1)
	GameEvents.TX_Test.Remove(add)
	H.eq(GameEvents.TX_Test.Count(), 1)
	LuaEvents.TX_Ping.Add(function(x) got[#got + 1] = x end)
	LuaEvents.TX_Ping(7)
	H.deq(got, { 5, 7 })
	FAKE.handlerErrors = {}
end, { allowErrors = true })

test("players: IDs come unsorted, flags, kill", function()
	H.world{}
	local ids = PlayerManager.GetAliveIDs()
	H.ok(ids[1] > ids[#ids], "descending on purpose: the mod must sort")
	H.ok(Players[0]:IsHuman() and Players[0]:IsMajor() and Players[0]:IsAlive())
	H.ok(not Players[1]:IsHuman())
	H.ok(not Players[4]:IsMajor(), "city-state")
	H.ok(Players[63]:IsBarbarian())
	H.eq(PlayerManager.GetFreeCitiesPlayerID(), 62)
	H.isnil(Players[62].IsFreeCities, "IsFreeCities is UI-only")
	H.kill(3)
	H.ok(not Players[3]:IsAlive())
	H.notContains(PlayerManager.GetAliveIDs(), 3)
	H.eq(PlayerManager.GetAliveMajorsCount(), 3)
	H.eq(PlayerConfigurations[1]:GetPlayerName(), "Player 1")
	H.eq(PlayerConfigurations[1], PlayerConfigurations[1], "one config object per player")
	H.isnil(PlayerConfigurations[40])
end)

test("teams: config team vs live team, broadcast recorded", function()
	H.world{ teams = { [0] = 0, [1] = 0, [2] = 2, [3] = 2 } }
	H.eq(Players[1]:GetTeam(), 0)
	H.eq(PlayerConfigurations[1]:GetTeam(), 0)
	H.deq(FAKE.TeamMembers(0), { 0, 1 })
	-- default model "config": the live team does not change until a reload applies it
	PlayerConfigurations[1]:SetTeam(5)
	Network.BroadcastPlayerInfo(1)
	H.eq(PlayerConfigurations[1]:GetTeam(), 5)
	H.eq(Players[1]:GetTeam(), 0, "live team unchanged in the config model")
	H.len(FAKE.teamSets, 1)
	H.deq(FAKE.broadcasts, { { pid = 1, turn = 1, context = "G" } })
	FAKE.ApplyConfigTeams()
	H.eq(Players[1]:GetTeam(), 5, "after the simulated reload")
	-- model "live": both change at once
	FAKE.teamModel = "live"
	PlayerConfigurations[3]:SetTeam(7)
	H.eq(Players[3]:GetTeam(), 7)
	H.team(2, 0)
	H.eq(PlayerConfigurations[2]:GetTeam(), 0, "H.team sets both")
end)

test("diplomacy: getters, team-shared war, permanent wars", function()
	H.world{ teams = { [0] = 0, [1] = 0, [2] = 2, [3] = 3 } }
	H.ally(1, 2)
	H.friend(0, 3)
	H.ok(Players[1]:GetDiplomacy():HasAllied(2) and Players[2]:GetDiplomacy():HasAllied(1))
	H.ok(Players[3]:GetDiplomacy():HasDeclaredFriendship(0))
	H.ok(Players[0]:GetDiplomacy():HasMet(3) and not Players[0]:GetDiplomacy():HasMet(2))
	H.war(2, 0)
	H.ok(Players[2]:GetDiplomacy():IsAtWarWith(0))
	H.ok(Players[1]:GetDiplomacy():IsAtWarWith(2), "P1 shares P0's war (same team)")
	H.ok(Players[1]:GetDiplomacy():HasAllied(2), "the fake ends alliances only for the declaring pair (0 and 2)")
	FAKE.teamWars = false
	H.ok(not Players[1]:GetDiplomacy():IsAtWarWith(2), "without the team model only the pair is at war")
	FAKE.teamWars = true
	H.ok(Players[62]:GetDiplomacy():IsAtWarWith(0), "Free Cities always at war with majors")
	H.ok(not Players[62]:GetDiplomacy():IsAtWarWith(4), "but not with city-states")
	H.ok(Players[4]:GetDiplomacy():IsAtWarWith(63), "Barbarians at war with everyone")
	H.openBorders(0, 3)
	H.isnil(Players[0]:GetDiplomacy().HasOpenBordersFrom, "nil in G")
	FAKE.context = "UI"
	H.ok(Players[0]:GetDiplomacy():HasOpenBordersFrom(3))
	FAKE.context = "G"
end)

test("turn simulation order = in-game order", function()
	H.world{ players = { { id = 0, human = true }, { id = 1 }, { id = 63, kind = "BARBARIAN" } } }
	local order = {}
	GameEvents.OnPlayerTurnEnded.Add(function(p) order[#order + 1] = "end" .. p end)
	GameEvents.OnGameTurnEnded.Add(function(t) order[#order + 1] = "gte" .. t .. "@" .. Game.GetCurrentGameTurn() end)
	GameEvents.OnGameTurnStarted.Add(function(t) order[#order + 1] = "gts" .. t end)
	GameEvents.PlayerTurnStarted.Add(function(p) if p <= 1 then order[#order + 1] = "pts" .. p end end)
	GameEvents.PlayerTurnStartComplete.Add(function(p) if p <= 1 then order[#order + 1] = "psc" .. p end end)
	Events.TurnEnd.Add(function(t) order[#order + 1] = "te" .. t end)
	Events.TurnBegin.Add(function(t) order[#order + 1] = "tb" .. t end)
	H.endTurn{ act = function(p, t) if p == 1 then order[#order + 1] = "act1@" .. t end end }
	H.deq(order, { "pts1", "psc1", "act1@1", "gte1@1", "te1", "gts2", "tb2", "pts0", "psc0" })
	H.eq(Game.GetCurrentGameTurn(), 2)
	-- a second human (MP-like): all humans start after OnGameTurnStarted
	H.human(1)
	order = {}
	H.endTurn()
	H.deq(order, { "gte2@2", "te2", "gts3", "tb3", "pts0", "psc0", "pts1", "psc1" })
	H.eq(H.turns(3), 6)
end)

test("RNG deterministic, math.random and Game.GetLocalPlayer flagged in gameplay", function()
	H.world{}
	FAKE.rngSeed = 7
	local a = { Game.GetRandNum(10, "x"), Game.GetRandNum(10, "x") }
	FAKE.rngSeed = 7
	local b = { Game.GetRandNum(10, "x"), Game.GetRandNum(10, "x") }
	H.deq(a, b)
	math.random(3)
	Game.GetLocalPlayer()
	H.deq(FAKE.forbidden, { "math.random", "Game.GetLocalPlayer" })
	FAKE.forbidden = {}
	H.clean()
end)

test("notifications: send, list, find, dismiss", function()
	H.world{}
	local row = FAKE.AddType("NOTIFICATION_SELFTEST", "KIND_NOTIFICATION")
	H.eq(GameInfo.Types[row.Hash], row, "lookup by hash")
	local data = {}
	data[ParameterTypes.MESSAGE] = "m"
	local id = NotificationManager.SendNotification(1, row.Hash, data)
	H.len(H.notifs(1, "NOTIFICATION_SELFTEST"), 1)
	H.deq(NotificationManager.GetList(1), { id })
	H.eq(NotificationManager.Find(1, id):GetMessage(), "m")
	NotificationManager.Dismiss(1, id)
	H.len(NotificationManager.GetList(1), 0)
	H.throws(function() NotificationManager.SendNotification(1, 12345, {}) end, "unknown type")
end)

test("Locale: placeholders, plural forms, missing argument flagged for TX keys", function()
	H.world{}
	FAKE.SetText("LOC_TX_SELFTEST_TURNS", "{1_Name} has {2_Num : plural 1?1 turn; other?# turns;} left")
	H.eq(Locale.Lookup("LOC_TX_SELFTEST_TURNS", "Ann", 1), "Ann has 1 turn left")
	H.eq(Locale.Lookup("LOC_TX_SELFTEST_TURNS", "Ann", 3), "Ann has # turns left")
	H.eq(Locale.Lookup("LOC_UNKNOWN_KEY"), "LOC_UNKNOWN_KEY")
	H.len(FAKE.textArgErrors, 0)
	Locale.Lookup("LOC_TX_SELFTEST_TURNS", "Ann")
	H.len(FAKE.textArgErrors, 1, "a missing argument fails the test that triggered it")
	FAKE.textArgErrors = {}
	FAKE.handlerErrors = {}
end)

test("UI requests are routed to the gameplay handler", function()
	H.world{}
	local seen = {}
	GameEvents.TX_SelftestRequest.Add(function(pid, params)
		seen[#seen + 1] = { pid = pid, target = params.TargetID, ui = (UI == nil) and "nil" or "set", ctx = FAKE.context }
	end)
	FAKE_UI.Enable()
	H.eq(FAKE.context, "UI")
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, { OnStart = "TX_SelftestRequest", TargetID = 2 })
	H.deq(seen, { { pid = 0, target = 2, ui = "nil", ctx = "G" } }, "delivered at once, as gameplay")
	H.eq(FAKE.context, "UI", "UI context restored")
	H.notnil(UI)
	FAKE_UI.deferRequests = true
	UI.RequestPlayerOperation(0, PlayerOperations.EXECUTE_SCRIPT, { OnStart = "TX_SelftestRequest", TargetID = 3 })
	H.len(seen, 1, "deferred")
	H.eq(FAKE_UI.DeliverRequests(), 1)
	H.eq(seen[2].target, 3)
	H.len(FAKE_UI.requests, 2)
	H.request(1, { OnStart = "TX_SelftestRequest", TargetID = 4 })
	H.deq(seen[3], { pid = 1, target = 4, ui = "nil", ctx = "G" }, "H.request fires the same way")
	H.len(FAKE.forbidden, 0, "Game.GetLocalPlayer in UI is fine")
end)

test("fake UI: controls, instances, popups", function()
	H.world{}
	FAKE_UI.Enable()
	Controls.Title:LocalizeAndSetText("LOC_TX_NOT_DEFINED")
	H.eq(Controls.Title:GetText(), "LOC_TX_NOT_DEFINED")
	local clicked = 0
	Controls.Button:RegisterCallback(Mouse.eLClick, function() clicked = clicked + 1 end)
	Controls.Button:Click()
	H.eq(clicked, 1)
	H.ok(ContextPtr:IsHidden(), "contexts load hidden")
	ContextPtr:SetHide(false)
	H.ok(not ContextPtr:IsHidden())
	local im = InstanceManager:new("Row", "Root", Controls.Stack)
	local inst = im:GetInstance()
	inst.Button:SetText("Expel")
	H.eq(FAKE_UI.FindButton("Expel"), inst.Button)
	local dlg = PopupDialogInGame:new("TX_Confirm")
	dlg:AddText("Sure?")
	dlg:Open()
	H.len(FAKE_UI.popups, 1)
end)

test("include() resolves by file name, missing files are logged", function()
	H.world{}
	include("selftest_module")
	include("selftest_module.lua")
	H.eq(SELFTEST_MODULE_LOADS, 2, "include re-runs the file like the engine")
	H.eq(FAKE.includes[1], "tests/offline/lib/selftest_module.lua")
	include("NoSuchFile")
	H.ok(H.hasLine("include: file not found: NoSuchFile"))
end)

test("GameInfo exported from the game DB", function()
	H.needGameInfo()
	H.notnil(GameInfo.Types, "Types exported")
	local n = 0
	for row in GameInfo.Types() do
		n = n + 1
		H.eq(GameInfo.Types[row.Index], row)
	end
	H.ok(n > 0, "Types iterate")
end)
