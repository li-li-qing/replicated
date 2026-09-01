------------------------------------------------------------------------
-- Replicated DPS - Legacy Damage Review Tombstone
-- Damage Review is now owned by Team Utility:
--   services/rs_damage_review_service.lua
-- This file intentionally contains no runtime/UI/event logic.
------------------------------------------------------------------------
if ReplicatedDps ~= nil then
    ReplicatedDps.DeathReview = nil
end
