-- Exact shared-stash address used by the CP2.5 triad witness.
-- No owner-specific item IDs; this is a pinned runtime candidate, not a
-- guarantee that the address resolves on every build/save.
local EXPECTED=16570246047455160070ULL
local M={}
function M.resolve()
  local ok,entity=pcall(function() return Game.FindEntityByID(EntityID.new({hash=EXPECTED})) end)
  if not ok or entity==nil then return nil,"STASH_ENTITY_UNAVAILABLE" end
  local good,id=pcall(function() return tostring(entity:GetEntityID().hash):gsub("ULL$",""):gsub("UL$","") end)
  if not good or id~="16570246047455160070" then return nil,"STASH_IDENTITY_MISMATCH" end
  return entity
end
return M
