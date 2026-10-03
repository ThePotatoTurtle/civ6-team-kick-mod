-- TX_UnitFlagManager.lua (fixture; ReplaceUIScript UnitFlagManager, thin wrapper)
include("UnitFlagManager")

local BASE_UpdateReligion = UnitFlag.UpdateReligion

function UnitFlag.UpdateReligion(self)
	BASE_UpdateReligion(self)
	local pUnit = self:GetUnit()
	if pUnit ~= nil and Modding.IsModActive("7d0c5f3a-2b1e-4c6d-9a8f-1e2d3c4b5a61") then
		local store = Game:GetProperty("TX_Proposals")
		if store ~= nil then
			print("[TX] flag " .. tostring(pUnit:GetID()))
		end
	end
end
