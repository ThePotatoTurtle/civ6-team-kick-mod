-- TX_TeamPanel.lua (fixture; AddUserInterfaces InGame)
include("InstanceManager")
include("TX_UIShared")

local m_MemberIM = InstanceManager:new("MemberInstance", "Root", Controls.MemberStack)

local function Refresh()
	m_MemberIM:ResetInstances()
	local me = Game.GetLocalPlayer()
	local store = TX_UI_ReadStore()
	local turnsLeft = (store ~= nil and store.ids ~= nil) and #store.ids or 0
	for _, pid in ipairs(TX_Util.SortedAlivePlayers()) do
		if pid ~= me and Players[pid]:GetTeam() == Players[me]:GetTeam() then
			local inst = m_MemberIM:GetInstance()
			inst.MemberLabel:SetText(Locale.Lookup("LOC_TX_TURNS_LEFT", turnsLeft))
			inst.ExpelButton:RegisterCallback(Mouse.eLClick, function()
				TX_UI_Request("TX_Propose", { TargetID = pid })
			end)
		end
	end
end

local function Initialize()
	Controls.Title:LocalizeAndSetText("LOC_TX_TEAM_TAB")
	Events.LoadGameViewStateDone.Add(Refresh)
	Events.PlayerTurnActivated.Add(Refresh)
	ContextPtr:SetHide(false)
end
Initialize()
